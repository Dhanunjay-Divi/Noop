import CryptoKit
import Foundation
import ZIPFoundation

enum FeedbackArchiveError: Error, Equatable {
    case empty
    case destinationExists
    case invalidEntryName
    case duplicateEntry
    case unknownEntry
    case privateRawEntry
    case missingRequiredEntry
    case invalidArchive
    case integrityMismatch
}

struct FeedbackArchiveManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let name: String
        let bytes: Int
        let sha256: String
    }

    let schemaVersion: Int
    let platform: String
    let appVersion: String
    let createdAt: String
    let includesUserNote: Bool
    let includesScreenshot: Bool
    let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case platform, entries
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case createdAt = "created_at"
        case includesUserNote = "includes_user_note"
        case includesScreenshot = "includes_screenshot"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct FeedbackArchivePackage: Equatable {
    let archiveURL: URL
    let archiveBytes: Int64
    let archiveSHA256: String
    let manifest: FeedbackArchiveManifest
}

enum FeedbackArchiveBuilder {
    static let manifestName = "feedback-manifest.json"
    private static let pngSignature = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ])

    private static let requiredEntryNames: Set<String> = [
        "meta.json",
        "report.txt",
    ]

    private static let allowedEntryNames: Set<String> = [
        "app-session-current.jsonl",
        "app-session-previous.jsonl",
        "apple-performance-diagnostics.jsonl",
        "meta.json",
        "report.txt",
        "screenshot.png",
        "user-note.txt",
    ]

    static func build(
        entries: [FileExport.BundleEntry],
        appVersion: String,
        destinationURL: URL,
        createdAt: Date = Date()
    ) throws -> FeedbackArchivePackage {
        guard !entries.isEmpty else { throw FeedbackArchiveError.empty }
        guard destinationURL.isFileURL else {
            throw FeedbackArchiveError.invalidArchive
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw FeedbackArchiveError.destinationExists
        }

        let validated = try validate(entries)
        let manifest = FeedbackArchiveManifest(
            schemaVersion: 1,
            platform: "ios",
            appVersion: appVersion,
            createdAt: feedbackISO8601String(createdAt),
            includesUserNote: validated.contains { $0.name == "user-note.txt" },
            includesScreenshot: validated.contains { $0.name == "screenshot.png" },
            entries: validated.map {
                FeedbackArchiveManifest.Entry(
                    name: $0.name,
                    bytes: $0.data.count,
                    sha256: FeedbackDigest.sha256($0.data)
                )
            }
        )
        let manifestData = try manifest.encoded()
        let expectedData = Dictionary(
            uniqueKeysWithValues:
                validated.map { ($0.name, $0.data) }
                + [(manifestName, manifestData)]
        )

        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        do {
            try writeArchive(
                entries: validated,
                manifestData: manifestData,
                destinationURL: destinationURL
            )
            try verifyArchive(at: destinationURL, expectedData: expectedData)

            let size = try fileSize(destinationURL)
            guard size > 0 else { throw FeedbackArchiveError.invalidArchive }
            return FeedbackArchivePackage(
                archiveURL: destinationURL,
                archiveBytes: size,
                archiveSHA256: try FeedbackDigest.sha256(fileAt: destinationURL),
                manifest: manifest
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if let archiveError = error as? FeedbackArchiveError {
                throw archiveError
            }
            throw FeedbackArchiveError.invalidArchive
        }
    }

    static func verify(
        package: FeedbackArchivePackage
    ) throws {
        let manifestData = try package.manifest.encoded()
        var expectedData: [String: Data] = [manifestName: manifestData]
        let reader: Archive
        do {
            reader = try Archive(
                url: package.archiveURL,
                accessMode: .read,
                pathEncoding: nil
            )
        } catch {
            throw FeedbackArchiveError.invalidArchive
        }

        for entry in package.manifest.entries {
            guard let archiveEntry = reader[entry.name] else {
                throw FeedbackArchiveError.integrityMismatch
            }
            let data = try extract(
                archiveEntry,
                from: reader,
                maximumBytes: entry.bytes
            )
            guard data.count == entry.bytes,
                  FeedbackDigest.sha256(data) == entry.sha256 else {
                throw FeedbackArchiveError.integrityMismatch
            }
            expectedData[entry.name] = data
        }
        try verifyArchive(at: package.archiveURL, expectedData: expectedData)
        guard try fileSize(package.archiveURL) == package.archiveBytes,
              try FeedbackDigest.sha256(fileAt: package.archiveURL)
                == package.archiveSHA256 else {
            throw FeedbackArchiveError.integrityMismatch
        }
    }

    private static func validate(
        _ entries: [FileExport.BundleEntry]
    ) throws -> [FileExport.BundleEntry] {
        var names = Set<String>()
        var foldedNames = Set<String>()
        var validated: [FileExport.BundleEntry] = []
        validated.reserveCapacity(entries.count)

        for entry in entries {
            guard validFlatName(entry.name) else {
                throw FeedbackArchiveError.invalidEntryName
            }
            let folded = entry.name.lowercased()
            guard names.insert(entry.name).inserted,
                  foldedNames.insert(folded).inserted else {
                throw FeedbackArchiveError.duplicateEntry
            }
            guard entry.name != manifestName else {
                throw FeedbackArchiveError.unknownEntry
            }
            guard !isPrivateRawEntry(entry.name) else {
                throw FeedbackArchiveError.privateRawEntry
            }
            guard allowedEntryNames.contains(entry.name) else {
                throw FeedbackArchiveError.unknownEntry
            }
            if entry.name == "screenshot.png" {
                guard entry.data.count >= pngSignature.count,
                      entry.data.prefix(pngSignature.count) == pngSignature,
                      FeedbackScreenshotSanitizer.sanitize(entry.data)
                        == entry.data else {
                    throw FeedbackArchiveError.invalidArchive
                }
            }
            validated.append(entry)
        }

        guard requiredEntryNames.isSubset(of: names) else {
            throw FeedbackArchiveError.missingRequiredEntry
        }
        return validated.sorted { $0.name < $1.name }
    }

    private static func validFlatName(_ name: String) -> Bool {
        !name.isEmpty
            && name == URL(fileURLWithPath: name).lastPathComponent
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
            && name != "."
            && name != ".."
    }

    private static func isPrivateRawEntry(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("raw-capture")
            || value.contains("health-db")
            || value.hasSuffix(".sqlite")
            || value.hasSuffix(".sqlite3")
            || value.hasSuffix(".db")
            || value.hasSuffix(".db-wal")
            || value.hasSuffix(".db-shm")
            || value.hasSuffix(".noopbak")
    }

    private static func writeArchive(
        entries: [FileExport.BundleEntry],
        manifestData: Data,
        destinationURL: URL
    ) throws {
        let writer: Archive
        do {
            writer = try Archive(
                url: destinationURL,
                accessMode: .create,
                pathEncoding: nil
            )
        } catch {
            throw FeedbackArchiveError.invalidArchive
        }
        for entry in entries {
            try add(entry.name, data: entry.data, to: writer)
        }
        try add(manifestName, data: manifestData, to: writer)
    }

    private static func add(
        _ name: String,
        data: Data,
        to archive: Archive
    ) throws {
        do {
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start >= 0, start <= end, end <= data.count else {
                    throw FeedbackArchiveError.invalidArchive
                }
                return data.subdata(in: start..<end)
            }
        } catch {
            throw FeedbackArchiveError.invalidArchive
        }
    }

    private static func verifyArchive(
        at url: URL,
        expectedData: [String: Data]
    ) throws {
        let archive: Archive
        do {
            archive = try Archive(
                url: url,
                accessMode: .read,
                pathEncoding: nil
            )
        } catch {
            throw FeedbackArchiveError.invalidArchive
        }

        let files = archive.filter { $0.type == .file }
        let paths = files.map(\.path)
        guard paths.count == Set(paths).count,
              Set(paths) == Set(expectedData.keys) else {
            throw FeedbackArchiveError.integrityMismatch
        }

        for entry in files {
            guard let expected = expectedData[entry.path] else {
                throw FeedbackArchiveError.integrityMismatch
            }
            let extracted = try extract(
                entry,
                from: archive,
                maximumBytes: expected.count
            )
            guard extracted == expected else {
                throw FeedbackArchiveError.integrityMismatch
            }
        }
    }

    private static func extract(
        _ entry: Entry,
        from archive: Archive,
        maximumBytes: Int
    ) throws -> Data {
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                guard data.count <= maximumBytes,
                      chunk.count <= maximumBytes - data.count else {
                    throw FeedbackArchiveError.integrityMismatch
                }
                data.append(chunk)
            }
        } catch {
            if let archiveError = error as? FeedbackArchiveError {
                throw archiveError
            }
            throw FeedbackArchiveError.invalidArchive
        }
        return data
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw FeedbackArchiveError.invalidArchive
        }
        return Int64(size)
    }

}

enum FeedbackDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

func feedbackISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
