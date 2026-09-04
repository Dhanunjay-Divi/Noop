import Foundation
import NoopRemoteSync
import ZIPFoundation

enum ManagedHistoryArchiveError: Error, Equatable {
    case invalidEntryPath
    case duplicateEntry
    case invalidArchive
    case alreadyFinalized
}

actor ManagedHistoryArchiveWriter {
    private let destinationURL: URL
    private var archive: Archive?
    private var entryPaths: Set<String> = []
    private var finalized = false

    init(destinationURL: URL) throws {
        guard destinationURL.isFileURL else {
            throw ManagedHistoryArchiveError.invalidArchive
        }
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            archive = try Archive(
                url: destinationURL,
                accessMode: .create,
                pathEncoding: nil
            )
            self.destinationURL = destinationURL
            try Self.applyProtection(to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
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
        guard entryPaths.insert(path).inserted else {
            throw ManagedHistoryArchiveError.duplicateEntry
        }
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

    private static func valid(path: String) -> Bool {
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
