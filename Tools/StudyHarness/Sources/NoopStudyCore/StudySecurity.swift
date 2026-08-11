import CryptoKit
import Foundation

private struct UnsignedStudySplitLock: Codable, Equatable {
    let schemaVersion: Int
    let studyID: String
    let createdAtUTC: String
    let subjects: [LockedStudySubject]
}

public enum StudyPaths {
    public static var defaultPrivateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NOOP-Private/whoop-study", isDirectory: true)
    }

    /// The HMAC key deliberately lives outside the study directory. Changing a
    /// lock and recomputing plain checksums is therefore not enough to unseal a
    /// holdout allocation.
    public static func defaultLockKey(for privateRoot: URL) -> URL {
        privateRoot.deletingLastPathComponent()
            .appendingPathComponent(".noop-study-lock-key", isDirectory: false)
    }

    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    public static func resolveInput(_ relativePath: String, under privateRoot: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw StudyError.pathMustBeRelative(relativePath)
        }
        let root = privateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw StudyError.missingFile(relativePath)
        }
        let resolved = candidate.resolvingSymlinksInPath()
        guard isDescendant(resolved, of: root) else {
            throw StudyError.pathEscapesPrivateRoot(relativePath)
        }
        let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw StudyError.unsafeSymlink(relativePath)
        }
        try requirePrivatePermissions(resolved)
        return resolved
    }

    public static func resolveOutput(_ relativePath: String, under privateRoot: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw StudyError.pathMustBeRelative(relativePath)
        }
        let root = privateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        try ensurePrivateDirectory(parent)
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard isDescendant(resolvedParent, of: root) else {
            throw StudyError.pathEscapesPrivateRoot(relativePath)
        }
        return resolvedParent.appendingPathComponent(candidate.lastPathComponent)
    }

    public static func requirePrivatePermissions(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return
        }
        // No group or world bits. Owner read/write/execute depends on file type.
        if permissions & 0o077 != 0 {
            throw StudyError.insecurePermissions(url.path)
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}

public enum StudyManifestIO {
    public static func load(from url: URL) throws -> StudyManifest {
        do {
            let manifest = try JSONDecoder().decode(StudyManifest.self, from: Data(contentsOf: url))
            try validate(manifest)
            return manifest
        } catch let error as StudyError {
            throw error
        } catch {
            throw StudyError.malformedManifest(error.localizedDescription)
        }
    }

    public static func validate(_ manifest: StudyManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw StudyError.unsupportedSchema(manifest.schemaVersion)
        }
        guard isSafeIdentifier(manifest.studyID, maximumLength: 64, allowDot: true) else {
            throw StudyError.invalidStudyID
        }
        var ids = Set<String>()
        for subject in manifest.subjects {
            guard isSafeSubjectID(subject.subjectID) else {
                throw StudyError.invalidSubjectID(subject.subjectID)
            }
            guard ids.insert(subject.subjectID).inserted else {
                throw StudyError.duplicateSubjectID(subject.subjectID)
            }
            guard !subject.whoopExport.hasPrefix("/") else {
                throw StudyError.pathMustBeRelative(subject.whoopExport)
            }
            guard safeRelativePath(subject.whoopExport) else {
                throw StudyError.pathEscapesPrivateRoot(subject.whoopExport)
            }
            if let path = subject.noopDailyOutput, path.hasPrefix("/") {
                throw StudyError.pathMustBeRelative(path)
            }
            if let path = subject.noopDailyOutput, !safeRelativePath(path) {
                throw StudyError.pathEscapesPrivateRoot(path)
            }
        }
        for cohort in StudyCohort.allCases where !manifest.subjects.contains(where: { $0.cohort == cohort }) {
            throw StudyError.missingCohort(cohort)
        }
    }

    private static func isSafeSubjectID(_ value: String) -> Bool {
        guard !value.contains("@"), !value.contains(".") else { return false }
        return isSafeIdentifier(value, maximumLength: 40, allowDot: false)
    }

    private static func isSafeIdentifier(
        _ value: String,
        maximumLength: Int,
        allowDot: Bool
    ) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || (allowDot && scalar == ".")
        }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

public enum StudyFileDigest {
    public static func sha256(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true { throw StudyError.unsafeSymlink(url.path) }
        if values.isDirectory == true { return try directorySHA256(url) }
        guard values.isRegularFile == true else { throw StudyError.missingFile(url.path) }
        var hash = SHA256()
        try update(&hash, withFile: url, relativeName: url.lastPathComponent)
        return hex(hash.finalize())
    }

    private static func directorySHA256(_ root: URL) throws -> String {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw StudyError.missingFile(root.path)
        }
        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw StudyError.unsafeSymlink(url.path) }
            if values.isRegularFile == true {
                let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                files.append((String(url.path.dropFirst(rootPath.count)), url))
            }
        }
        var hash = SHA256()
        for file in files.sorted(by: { $0.relative < $1.relative }) {
            try update(&hash, withFile: file.url, relativeName: file.relative)
        }
        return hex(hash.finalize())
    }

    private static func update(
        _ hash: inout SHA256,
        withFile url: URL,
        relativeName: String
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        hash.update(data: Data("file\u{0}\(relativeName)\u{0}\(size)\u{0}".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum StudySplitLocker {
    public static func create(
        manifest: StudyManifest,
        privateRoot: URL,
        keyURL: URL,
        now: Date = Date()
    ) throws -> StudySplitLock {
        try StudyManifestIO.validate(manifest)
        try StudyPaths.ensurePrivateDirectory(privateRoot)
        try requireKeyOutsidePrivateRoot(keyURL, privateRoot: privateRoot)
        let key = try loadOrCreateKey(at: keyURL)

        var subjects: [LockedStudySubject] = []
        var subjectByDigest: [String: String] = [:]
        for subject in manifest.subjects.sorted(by: { $0.subjectID < $1.subjectID }) {
            let exportURL = try StudyPaths.resolveInput(subject.whoopExport, under: privateRoot)
            let digest = try StudyFileDigest.sha256(of: exportURL)
            if let first = subjectByDigest[digest] {
                throw StudyError.duplicateReferenceInput(
                    first: first,
                    second: subject.subjectID
                )
            }
            subjectByDigest[digest] = subject.subjectID
            subjects.append(LockedStudySubject(
                subjectID: subject.subjectID,
                cohort: subject.cohort,
                whoopExport: subject.whoopExport,
                whoopExportSHA256: digest
            ))
        }
        let unsigned = UnsignedStudySplitLock(
            schemaVersion: 1,
            studyID: manifest.studyID,
            createdAtUTC: iso8601.string(from: now),
            subjects: subjects
        )
        let signature = try sign(unsigned, key: key)
        return StudySplitLock(
            schemaVersion: unsigned.schemaVersion,
            studyID: unsigned.studyID,
            createdAtUTC: unsigned.createdAtUTC,
            subjects: unsigned.subjects,
            signature: signature
        )
    }

    public static func verify(
        manifest: StudyManifest,
        lock: StudySplitLock,
        privateRoot: URL,
        keyURL: URL
    ) throws {
        try StudyManifestIO.validate(manifest)
        try requireKeyOutsidePrivateRoot(keyURL, privateRoot: privateRoot)
        guard lock.schemaVersion == 1 else { throw StudyError.unsupportedSchema(lock.schemaVersion) }
        let unsigned = UnsignedStudySplitLock(
            schemaVersion: lock.schemaVersion,
            studyID: lock.studyID,
            createdAtUTC: lock.createdAtUTC,
            subjects: lock.subjects
        )
        let key = try loadExistingKey(at: keyURL)
        let expected = try sign(unsigned, key: key)
        guard constantTimeEqual(expected, lock.signature) else {
            throw StudyError.lockSignatureMismatch
        }

        let manifestSplit = manifest.subjects
            .map { ($0.subjectID, $0.cohort, $0.whoopExport) }
            .sorted { $0.0 < $1.0 }
        let lockedSplit = lock.subjects
            .map { ($0.subjectID, $0.cohort, $0.whoopExport) }
            .sorted { $0.0 < $1.0 }
        guard manifest.studyID == lock.studyID,
              manifestSplit.elementsEqual(lockedSplit, by: {
                  $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
              })
        else {
            throw StudyError.splitLockMismatch
        }

        for subject in lock.subjects {
            let exportURL = try StudyPaths.resolveInput(subject.whoopExport, under: privateRoot)
            guard try StudyFileDigest.sha256(of: exportURL) == subject.whoopExportSHA256 else {
                throw StudyError.referenceDigestMismatch(subject.subjectID)
            }
        }
    }

    public static func loadLock(from url: URL) throws -> StudySplitLock {
        do {
            return try JSONDecoder().decode(StudySplitLock.self, from: Data(contentsOf: url))
        } catch {
            throw StudyError.malformedLock(error.localizedDescription)
        }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try canonicalData(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private static func loadOrCreateKey(at url: URL) throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: url.path) {
            return try loadExistingKey(at: url)
        }
        try StudyPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return key
    }

    private static func loadExistingKey(at url: URL) throws -> SymmetricKey {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudyError.missingFile(url.path)
        }
        try StudyPaths.requirePrivatePermissions(url)
        let data = try Data(contentsOf: url)
        guard data.count == 32 else {
            throw StudyError.malformedLock("The HMAC key must contain exactly 32 bytes.")
        }
        return SymmetricKey(data: data)
    }

    private static func sign(_ lock: UnsignedStudySplitLock, key: SymmetricKey) throws -> String {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: try canonicalData(lock),
            using: key
        )
        return StudyFileDigest.hex(authentication)
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private static func requireKeyOutsidePrivateRoot(
        _ keyURL: URL,
        privateRoot: URL
    ) throws {
        let root = privateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let keyParent = keyURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let key = keyParent.appendingPathComponent(keyURL.lastPathComponent).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if key.path == root.path || key.path.hasPrefix(prefix) {
            throw StudyError.lockKeyMustBeOutsidePrivateRoot
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
