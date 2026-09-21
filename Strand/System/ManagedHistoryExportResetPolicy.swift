import Foundation
import NoopRemoteSync

enum ManagedHistoryExportFailureBoundary {
    case stagedState
    case localArchiveOutput
}

func managedHistoryExportNeedsReset(
    after error: Error,
    at boundary: ManagedHistoryExportFailureBoundary = .stagedState
) -> Bool {
    guard boundary == .stagedState else { return false }
    if error is ManagedHistoryExportStateError {
        return true
    }
    if let storage = error as? ManagedStorageError {
        switch storage {
        case .cursorExpired, .notFound, .conflict, .digestMismatch,
             .decoding, .invalidResponse:
            return true
        default:
            return false
        }
    }
    guard let archive = error as? ManagedHistoryArchiveError else {
        return false
    }
    switch archive {
    case .invalidEntryPath, .duplicateEntry, .conflictingEntry,
         .entryTooLarge, .invalidArchive:
        return true
    case .alreadyFinalized:
        return false
    }
}

@discardableResult
func applyManagedHistoryExportRecovery(
    after error: Error,
    at boundary: ManagedHistoryExportFailureBoundary,
    clearExport: () async -> Void
) async -> Bool {
    let needsReset = managedHistoryExportNeedsReset(
        after: error,
        at: boundary
    )
    if needsReset {
        await clearExport()
    }
    return needsReset
}

extension ManagedHistoryTransferStore {
    func validateStagedExport(
        manifest: ManagedHistoryExportManifest
    ) throws {
        let entriesRoot = exportArchiveURL
            .deletingLastPathComponent()
            .appendingPathComponent("export-entries", isDirectory: true)
            .standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: entriesRoot.path) else {
            throw ManagedHistoryExportStateError.unusableStagedArchive
        }

        var enumerationError: Error?
        let enumerator = fileManager.enumerator(
            at: entriesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        )
        guard let enumerator else {
            throw ManagedHistoryExportStateError.unusableStagedArchive
        }

        let rootPath = entriesRoot.path + "/"
        var entryPaths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard values.isRegularFile == true else { continue }
            let candidate = url.standardizedFileURL
            guard candidate.path.hasPrefix(rootPath) else {
                throw ManagedHistoryExportStateError.unusableStagedArchive
            }
            entryPaths.append(
                String(candidate.path.dropFirst(rootPath.count))
            )
        }
        if let enumerationError {
            throw enumerationError
        }

        try ManagedHistoryStagedArchiveValidator.validate(
            manifest: manifest,
            entryPaths: entryPaths,
            read: { path, maximumBytes in
                let candidate = entriesRoot
                    .appendingPathComponent(path, isDirectory: false)
                    .standardizedFileURL
                guard candidate.path.hasPrefix(rootPath),
                      fileManager.fileExists(atPath: candidate.path) else {
                    throw ManagedHistoryExportStateError
                        .unusableStagedArchive
                }
                let values = try candidate.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize == maximumBytes else {
                    throw ManagedHistoryExportStateError
                        .unusableStagedArchive
                }
                return try Data(
                    contentsOf: candidate,
                    options: [.mappedIfSafe]
                )
            }
        )
    }
}
