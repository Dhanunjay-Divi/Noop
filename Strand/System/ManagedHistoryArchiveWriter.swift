import Foundation
import NoopRemoteSync
import ZIPFoundation

enum ManagedHistoryArchiveError: Error, Equatable {
    case invalidEntryPath
    case duplicateEntry
    case conflictingEntry
    case entryTooLarge
    case invalidArchive
    case alreadyFinalized
}

actor ManagedHistoryArchiveWriter {
    private let destinationURL: URL
    private var archive: Archive?
    private var entryPaths: Set<String> = []
    private var finalized = false

    init(
        destinationURL: URL,
        resumeExisting: Bool = false
    ) throws {
        guard destinationURL.isFileURL else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        do {
            if resumeExisting,
               FileManager.default.fileExists(atPath: destinationURL.path) {
                let reader = try Archive(
                    url: destinationURL,
                    accessMode: .read,
                    pathEncoding: nil
                )
                let paths = reader.filter { $0.type == .file }.map(\.path)
                guard paths.count == Set(paths).count,
                      !paths.contains("manifest.json"),
                      paths.allSatisfy(Self.valid(path:)) else {
                    throw ManagedHistoryArchiveError.invalidArchive
                }
                entryPaths = Set(paths)
                archive = try Archive(
                    url: destinationURL,
                    accessMode: .update,
                    pathEncoding: nil
                )
            } else {
                try? FileManager.default.removeItem(at: destinationURL)
                archive = try Archive(
                    url: destinationURL,
                    accessMode: .create,
                    pathEncoding: nil
                )
            }
            self.destinationURL = destinationURL
            try Self.applyProtection(to: destinationURL)
        } catch {
            if !resumeExisting {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw ManagedHistoryArchiveError.invalidArchive
        }
    }

    func add(_ entry: ManagedHistoryExportEntry) throws {
        try add(path: entry.path, data: entry.data)
    }

    func finalize(
        manifest: ManagedHistoryExportManifest
    ) throws -> URL {
        guard !finalized, archive != nil else {
            throw ManagedHistoryArchiveError.alreadyFinalized
        }
        do {
            try add(path: "manifest.json", data: manifest.encoded())
            archive = nil
            let reader = try Archive(
                url: destinationURL,
                accessMode: .read,
                pathEncoding: nil
            )
            let actual = Set(reader.filter { $0.type == .file }.map(\.path))
            guard actual == entryPaths,
                  !actual.isEmpty,
                  FileManager.default.fileExists(atPath: destinationURL.path),
                  try Self.fileSize(destinationURL) > 0 else {
                throw ManagedHistoryArchiveError.invalidArchive
            }
            try Self.applyProtection(to: destinationURL)
            finalized = true
            return destinationURL
        } catch {
            archive = nil
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func cancel() {
        archive = nil
        try? FileManager.default.removeItem(at: destinationURL)
        finalized = true
    }

    private func add(path: String, data: Data) throws {
        guard !finalized, let archive else {
            throw ManagedHistoryArchiveError.alreadyFinalized
        }
        guard Self.valid(path: path) else {
            throw ManagedHistoryArchiveError.invalidEntryPath
        }
        if entryPaths.contains(path) {
            guard let existing = archive[path] else {
                throw ManagedHistoryArchiveError.invalidArchive
            }
            var current = Data()
            _ = try archive.extract(existing) { current.append($0) }
            guard current == data else {
                throw ManagedHistoryArchiveError.conflictingEntry
            }
            return
        }
        entryPaths.insert(path)
        do {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .none
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start >= 0, start <= end, end <= data.count else {
                    throw ManagedHistoryArchiveError.invalidArchive
                }
                return data.subdata(in: start..<end)
            }
        } catch {
            entryPaths.remove(path)
            throw error
        }
    }

    func suspendForResume() {
        archive = nil
        finalized = true
    }

    fileprivate static func valid(path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber
        return value?.int64Value ?? 0
    }

    private static func applyProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }
}

actor ManagedHistoryArchiveReader {
    private static let maximumManifestBytes = 8 * 1_024 * 1_024
    private let sourceURL: URL

    init(sourceURL: URL) throws {
        guard sourceURL.isFileURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        self.sourceURL = sourceURL
    }

    func entryPaths() throws -> [String] {
        let archive = try open()
        let paths = archive.filter { $0.type == .file }.map(\.path)
        guard paths.count == Set(paths).count,
              paths.allSatisfy(ManagedHistoryArchiveWriter.valid(path:)),
              paths.contains("manifest.json") else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        return paths
    }

    func manifestData() throws -> Data {
        try data(
            for: "manifest.json",
            maximumBytes: Self.maximumManifestBytes
        )
    }

    func data(for path: String, maximumBytes: Int) throws -> Data {
        guard ManagedHistoryArchiveWriter.valid(path: path),
              maximumBytes >= 0 else {
            throw ManagedHistoryArchiveError.invalidEntryPath
        }
        let archive = try open()
        guard let entry = archive[path],
              entry.type == .file,
              entry.uncompressedSize <= UInt32(maximumBytes) else {
            if archive[path] != nil {
                throw ManagedHistoryArchiveError.entryTooLarge
            }
            throw ManagedHistoryArchiveError.invalidArchive
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard result.count <= maximumBytes - chunk.count else {
                throw ManagedHistoryArchiveError.entryTooLarge
            }
            result.append(chunk)
        }
        return result
    }

    private func open() throws -> Archive {
        do {
            return try Archive(
                url: sourceURL,
                accessMode: .read,
                pathEncoding: nil
            )
        } catch {
            throw ManagedHistoryArchiveError.invalidArchive
        }
    }
}

actor ManagedHistoryTransferStore {
    private static let maximumCheckpointBytes = 8 * 1_024 * 1_024
    private static let maximumArchiveBytes: Int64 = 32 * 1_024 * 1_024 * 1_024
    private let directoryURL: URL
    private let exportEntriesURL: URL
    let exportArchiveURL: URL
    let importArchiveURL: URL
    private let exportCheckpointURL: URL
    private let importCheckpointURL: URL

    init(
        accountScopeHash: String,
        baseDirectoryURL: URL? = nil
    ) throws {
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        let base: URL
        if let baseDirectoryURL {
            guard baseDirectoryURL.isFileURL else {
                throw ManagedHistoryArchiveError.invalidArchive
            }
            base = baseDirectoryURL
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        directoryURL = base
            .appendingPathComponent("ManagedHistoryTransfers", isDirectory: true)
            .appendingPathComponent(accountScopeHash, isDirectory: true)
        exportEntriesURL = directoryURL.appendingPathComponent(
            "export-entries",
            isDirectory: true
        )
        exportArchiveURL = directoryURL.appendingPathComponent(
            "export.zip",
            isDirectory: false
        )
        importArchiveURL = directoryURL.appendingPathComponent(
            "import.zip",
            isDirectory: false
        )
        exportCheckpointURL = directoryURL.appendingPathComponent(
            "export-checkpoint.json",
            isDirectory: false
        )
        importCheckpointURL = directoryURL.appendingPathComponent(
            "import-checkpoint.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directoryURL
        try? mutableDirectory.setResourceValues(values)
        try Self.applyProtection(to: directoryURL)
    }

    func add(_ entry: ManagedHistoryExportEntry) throws {
        let destination = try exportEntryURL(for: entry.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Self.read(
                destination,
                maximumBytes: entry.data.count
            )
            guard existing == entry.data else {
                throw ManagedHistoryArchiveError.conflictingEntry
            }
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try entry.data.write(to: destination, options: [.atomic])
        try Self.applyProtection(to: destination)
    }

    func loadExportCheckpoint() throws -> ManagedHistoryExportCheckpoint? {
        try load(
            ManagedHistoryExportCheckpoint.self,
            from: exportCheckpointURL,
            decode: ManagedHistoryExportCheckpoint.decoded
        )
    }

    func saveExportCheckpoint(
        _ checkpoint: ManagedHistoryExportCheckpoint
    ) throws {
        try save(checkpoint.encoded(), to: exportCheckpointURL)
    }

    func loadImportCheckpoint() throws -> ManagedHistoryImportCheckpoint? {
        try load(
            ManagedHistoryImportCheckpoint.self,
            from: importCheckpointURL,
            decode: ManagedHistoryImportCheckpoint.decoded
        )
    }

    func saveImportCheckpoint(
        _ checkpoint: ManagedHistoryImportCheckpoint
    ) throws {
        try save(checkpoint.encoded(), to: importCheckpointURL)
    }

    func finalizeExport(
        manifest: ManagedHistoryExportManifest
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: exportArchiveURL)
        let writer = try ManagedHistoryArchiveWriter(
            destinationURL: exportArchiveURL
        )
        do {
            for chunk in manifest.chunks {
                let data = try readExport(
                    path: chunk.path,
                    maximumBytes: chunk.compressedBytes
                )
                guard data.count == chunk.compressedBytes,
                      ManagedDigest.sha256(data) == chunk.sha256 else {
                    throw ManagedHistoryExportStateError
                        .unusableStagedArchive
                }
                try await writer.add(
                    ManagedHistoryExportEntry(
                        kind: .chunk,
                        path: chunk.path,
                        data: data
                    )
                )
            }
            for document in manifest.documents {
                let data = try readExport(
                    path: document.path,
                    maximumBytes: document.archiveBytes
                )
                guard data.count == document.archiveBytes,
                      ManagedDigest.sha256(data)
                        == document.archiveSHA256 else {
                    throw ManagedHistoryExportStateError
                        .unusableStagedArchive
                }
                try await writer.add(
                    ManagedHistoryExportEntry(
                        kind: .document,
                        path: document.path,
                        data: data
                    )
                )
            }
            return try await writer.finalize(manifest: manifest)
        } catch {
            await writer.cancel()
            throw error
        }
    }

    func stageImport(
        from sourceURL: URL
    ) async throws -> ManagedHistoryArchiveReader {
        guard sourceURL.isFileURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              try Self.fileSize(sourceURL) <= Self.maximumArchiveBytes else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        let temporaryURL = directoryURL.appendingPathComponent(
            "import-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        guard try Self.fileSize(temporaryURL) <= Self.maximumArchiveBytes else {
            throw ManagedHistoryArchiveError.entryTooLarge
        }
        try Self.applyProtection(to: temporaryURL)

        let stagedReader = try ManagedHistoryArchiveReader(
            sourceURL: temporaryURL
        )
        _ = try await stagedReader.entryPaths()
        let manifest = try ManagedHistoryExportManifest.decoded(
            from: await stagedReader.manifestData()
        )
        let archiveSHA256 = ManagedDigest.sha256(try manifest.encoded())
        if let checkpoint = try loadImportCheckpoint(),
           checkpoint.archiveSHA256 != archiveSHA256 {
            try? FileManager.default.removeItem(at: importCheckpointURL)
        }

        if FileManager.default.fileExists(atPath: importArchiveURL.path) {
            _ = try FileManager.default.replaceItemAt(
                importArchiveURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(
                at: temporaryURL,
                to: importArchiveURL
            )
        }
        try Self.applyProtection(to: importArchiveURL)
        return try ManagedHistoryArchiveReader(sourceURL: importArchiveURL)
    }

    func clearExport() {
        try? FileManager.default.removeItem(at: exportEntriesURL)
        try? FileManager.default.removeItem(at: exportArchiveURL)
        try? FileManager.default.removeItem(at: exportCheckpointURL)
    }

    func clearImport() {
        try? FileManager.default.removeItem(at: importArchiveURL)
        try? FileManager.default.removeItem(at: importCheckpointURL)
    }

    func publishExport(to temporaryURL: URL) throws -> URL {
        guard temporaryURL.isFileURL,
              FileManager.default.fileExists(atPath: exportArchiveURL.path) else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        try? FileManager.default.removeItem(at: temporaryURL)
        try FileManager.default.copyItem(
            at: exportArchiveURL,
            to: temporaryURL
        )
        try Self.applyProtection(to: temporaryURL)
        clearExport()
        return temporaryURL
    }

    private func readExport(
        path: String,
        maximumBytes: Int
    ) throws -> Data {
        try Self.read(
            exportEntryURL(for: path),
            maximumBytes: maximumBytes
        )
    }

    private func exportEntryURL(for path: String) throws -> URL {
        guard ManagedHistoryArchiveWriter.valid(path: path),
              path != "manifest.json" else {
            throw ManagedHistoryArchiveError.invalidEntryPath
        }
        let candidate = exportEntriesURL
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        let root = exportEntriesURL.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(root) else {
            throw ManagedHistoryArchiveError.invalidEntryPath
        }
        return candidate
    }

    private func load<Value>(
        _ type: Value.Type,
        from url: URL,
        decode: (Data) throws -> Value
    ) throws -> Value? {
        _ = type
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        )
        guard data.count <= Self.maximumCheckpointBytes else {
            throw ManagedHistoryArchiveError.entryTooLarge
        }
        return try decode(data)
    }

    private func save(_ data: Data, to url: URL) throws {
        guard data.count <= Self.maximumCheckpointBytes else {
            throw ManagedHistoryArchiveError.entryTooLarge
        }
        try data.write(to: url, options: [.atomic])
        try Self.applyProtection(to: url)
    }

    private static func read(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0,
              FileManager.default.fileExists(atPath: url.path),
              try fileSize(url) <= Int64(maximumBytes) else {
            throw ManagedHistoryArchiveError.entryTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw ManagedHistoryArchiveError.entryTooLarge
        }
        return data
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let value = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber
        return value?.int64Value ?? 0
    }

    private static func applyProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }
}
