import NoopRemoteSync
import XCTest
import ZIPFoundation
@testable import Strand

final class ManagedHistoryArchiveWriterTests: XCTestCase {
    func testEntryEnumerationStopsAtCountLimitBeforeReadingRemainder()
        throws
    {
        var reads = 0
        let entries = AnySequence<String> {
            AnyIterator {
                guard reads < 10 else { return nil }
                reads += 1
                return "entries/\(reads).json"
            }
        }

        do {
            _ = try ManagedHistoryArchiveEntryEnumeration.paths(
                in: entries,
                maximumEntryCount: 2,
                filePath: { $0 }
            )
            XCTFail("Expected entry-count rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .invalidArchive
            )
        }
        XCTAssertEqual(reads, 3)
    }

    func testWriterStreamsEntriesAndPublishesVerifiedManifestLast() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-managed-writer-\(UUID().uuidString).zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try ManagedHistoryArchiveWriter(destinationURL: url)
        let chunk = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/chunk.json.gz",
            data: Data("compressed".utf8)
        )
        let document = ManagedHistoryExportEntry(
            kind: .document,
            path: "documents/journal/document.json",
            data: Data("{\"answer\":true}".utf8)
        )
        try await writer.add(chunk)
        try await writer.add(document)
        let manifest = manifest(objects: 2, bytes: Int64(chunk.data.count))

        let published = try await writer.finalize(manifest: manifest)
        let archive = try Archive(url: published, accessMode: .read)
        XCTAssertEqual(
            Set(archive.map(\.path)),
            Set([chunk.path, document.path, "manifest.json"])
        )
        let entry = try XCTUnwrap(archive[chunk.path])
        var extracted = Data()
        _ = try archive.extract(entry) { extracted.append($0) }
        XCTAssertEqual(extracted, chunk.data)
        XCTAssertNotNil(archive["manifest.json"])
    }

    func testWriterRejectsTraversalAndDeletesPartialArchiveOnCancel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-managed-writer-\(UUID().uuidString).zip")
        let writer = try ManagedHistoryArchiveWriter(destinationURL: url)
        do {
            try await writer.add(
                ManagedHistoryExportEntry(
                    kind: .document,
                    path: "../health.json",
                    data: Data()
                )
            )
            XCTFail("Expected traversal path rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .invalidEntryPath
            )
        }
        await writer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterResumesIdenticalEntryAndRejectsConflictingReplay() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-managed-writer-\(UUID().uuidString).zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let entry = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/chunk.json",
            data: Data("canonical".utf8)
        )
        let first = try ManagedHistoryArchiveWriter(destinationURL: url)
        try await first.add(entry)
        await first.suspendForResume()

        let resumed = try ManagedHistoryArchiveWriter(
            destinationURL: url,
            resumeExisting: true
        )
        try await resumed.add(entry)
        do {
            try await resumed.add(
                ManagedHistoryExportEntry(
                    kind: .chunk,
                    path: entry.path,
                    data: Data("different".utf8)
                )
            )
            XCTFail("Expected conflicting replay")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .conflictingEntry
            )
        }
        _ = try await resumed.finalize(
            manifest: manifest(for: entry, formatVersion: 2)
        )
    }

    func testTransferStorePublishesVerifiedExportAndClearsCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-transfer-\(UUID().uuidString)",
                isDirectory: true
            )
        let output = root.appendingPathComponent("published.zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: String(repeating: "a", count: 64),
            baseDirectoryURL: root
        )
        let entry = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/"
                + "10000000-0000-5000-8000-000000000001.json",
            data: Data("canonical".utf8)
        )
        let exportManifest = manifest(for: entry, formatVersion: 2)
        let checkpoint = ManagedHistoryExportCheckpoint(
            createdAt: exportManifest.createdAt,
            requestID: UUID(),
            restoreJobID: UUID(),
            snapshotAt: exportManifest.snapshotAt,
            changeSequence: exportManifest.changeSequence,
            expiresAt: "2026-09-19T00:00:00Z",
            dataClasses: exportManifest.dataClasses,
            pageSize: 100,
            selectedObjects: 1,
            selectedChunkBytes: Int64(entry.data.count),
            dataClassIndex: 1,
            documentsComplete: true,
            serverCompleted: true,
            exportedObjects: 1,
            exportedChunkBytes: Int64(entry.data.count),
            chunks: exportManifest.chunks
        )

        try await store.add(entry)
        try await store.add(entry)
        do {
            try await store.add(
                ManagedHistoryExportEntry(
                    kind: .chunk,
                    path: entry.path,
                    data: Data("different".utf8)
                )
            )
            XCTFail("Expected immutable staged entry")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .conflictingEntry
            )
        }
        try await store.saveExportCheckpoint(checkpoint)
        _ = try await store.finalizeExport(manifest: exportManifest)
        let published = try await store.publishExport(to: output)

        XCTAssertEqual(published, output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let storedCheckpoint = try await store.loadExportCheckpoint()
        XCTAssertNil(storedCheckpoint)
        let reader = try ManagedHistoryArchiveReader(sourceURL: output)
        let paths = try await reader.entryPaths()
        XCTAssertEqual(
            Set(paths),
            Set([entry.path, "manifest.json"])
        )
        let restoredData = try await reader.data(
            for: entry.path,
            maximumBytes: entry.data.count
        )
        XCTAssertEqual(restoredData, entry.data)
    }

    func testTransferStoreRejectsSameSizeMutationDuringAtomicFinalize()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-transfer-corrupt-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: String(repeating: "c", count: 64),
            baseDirectoryURL: root
        )
        let entry = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/"
                + "10000000-0000-5000-8000-000000000003.json",
            data: Data("canonical".utf8)
        )
        let exportManifest = manifest(for: entry, formatVersion: 2)
        try await store.add(entry)

        let stagedURL = root
            .appendingPathComponent("ManagedHistoryTransfers", isDirectory: true)
            .appendingPathComponent(String(repeating: "c", count: 64), isDirectory: true)
            .appendingPathComponent("export-entries", isDirectory: true)
            .appendingPathComponent(entry.path, isDirectory: false)
        try Data("different".utf8).write(to: stagedURL, options: [.atomic])

        do {
            _ = try await store.finalizeExport(manifest: exportManifest)
            XCTFail("Expected staged mutation rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryExportStateError,
                .unusableStagedArchive
            )
        }
    }

    func testImportStagingKeepsMatchingCheckpointAndClearsDifferentArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-import-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: String(repeating: "b", count: 64),
            baseDirectoryURL: root
        )
        let firstEntry = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/"
                + "10000000-0000-5000-8000-000000000001.json",
            data: Data("first".utf8)
        )
        let firstManifest = manifest(for: firstEntry, formatVersion: 2)
        let firstArchive = try await archive(
            entry: firstEntry,
            manifest: firstManifest,
            root: root
        )
        _ = try await store.stageImport(from: firstArchive)
        let checkpoint = ManagedHistoryImportCheckpoint(
            archiveSHA256: ManagedDigest.sha256(try firstManifest.encoded()),
            nextObjectIndex: 0
        )
        try await store.saveImportCheckpoint(checkpoint)

        _ = try await store.stageImport(from: firstArchive)
        let matching = try await store.loadImportCheckpoint()
        XCTAssertEqual(matching, checkpoint)

        let secondEntry = ManagedHistoryExportEntry(
            kind: .chunk,
            path: "chunks/essential_timeseries/"
                + "10000000-0000-5000-8000-000000000002.json",
            data: Data("second".utf8)
        )
        let secondManifest = manifest(for: secondEntry, formatVersion: 2)
        let secondArchive = try await archive(
            entry: secondEntry,
            manifest: secondManifest,
            root: root
        )
        _ = try await store.stageImport(from: secondArchive)
        let cleared = try await store.loadImportCheckpoint()
        XCTAssertNil(cleared)
    }

    func testTransferStoreRoundTripsExportCheckpointLargerThanEightMiB()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-large-checkpoint-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: String(repeating: "d", count: 64),
            baseDirectoryURL: root
        )
        let chunks = (0..<20_000).map { index in
            ManagedHistoryExportManifest.Chunk(
                path: "chunks/essential_timeseries/\(index).json",
                chunkID: UUID(),
                sourceID: UUID(),
                dataClass: "essential_timeseries",
                schemaVersion: 1,
                eventStart: "2026-09-04T11:00:00Z",
                eventEnd: "2026-09-04T11:00:00Z",
                compression: "none",
                contentType: "application/vnd.noop.chunk+json",
                sha256: String(repeating: "a", count: 64),
                compressedBytes: 1,
                uncompressedBytes: 1,
                objectGeneration: Int64(index + 1)
            )
        }
        let checkpoint = ManagedHistoryExportCheckpoint(
            createdAt: "2026-09-04T12:00:00Z",
            requestID: UUID(),
            restoreJobID: UUID(),
            snapshotAt: "2026-09-04T11:59:00Z",
            changeSequence: 42,
            expiresAt: "2026-09-19T00:00:00Z",
            dataClasses: ["essential_timeseries"],
            pageSize: 100,
            selectedObjects: chunks.count,
            selectedChunkBytes: Int64(chunks.count),
            dataClassIndex: 1,
            documentsComplete: true,
            serverCompleted: true,
            exportedObjects: chunks.count,
            exportedChunkBytes: Int64(chunks.count),
            chunks: chunks
        )
        let encoded = try checkpoint.encoded()
        XCTAssertGreaterThan(encoded.count, 8 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(
            encoded.count,
            ManagedHistoryTransferLimits.maximumExportCheckpointBytes
        )

        try await store.saveExportCheckpoint(checkpoint)
        let restored = try await store.loadExportCheckpoint()
        XCTAssertEqual(restored, checkpoint)
    }

    func testTransferStoreRejectsOversizedImportCheckpointBeforeDecode()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-import-checkpoint-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "e", count: 64)
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: account,
            baseDirectoryURL: root
        )
        let checkpointURL = transferDirectory(
            root: root,
            accountScopeHash: account
        ).appendingPathComponent("import-checkpoint.json")
        try Data(
            repeating: 0x20,
            count:
                ManagedHistoryTransferLimits.maximumImportCheckpointBytes + 1
        ).write(to: checkpointURL)

        do {
            _ = try await store.loadImportCheckpoint()
            XCTFail("Expected import checkpoint size rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .entryTooLarge
            )
        }
    }

    func testTransferStoreRejectsExportCheckpointAboveArchitecturalCeiling()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-export-checkpoint-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "f", count: 64)
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: account,
            baseDirectoryURL: root
        )
        let checkpointURL = transferDirectory(
            root: root,
            accountScopeHash: account
        ).appendingPathComponent("export-checkpoint.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: checkpointURL.path,
            contents: nil
        ))
        let handle = try FileHandle(forWritingTo: checkpointURL)
        try handle.truncate(
            atOffset: UInt64(
                ManagedHistoryTransferLimits.maximumExportCheckpointBytes + 1
            )
        )
        try handle.close()

        do {
            _ = try await store.loadExportCheckpoint()
            XCTFail("Expected export checkpoint size rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryArchiveError,
                .entryTooLarge
            )
        }
    }

    private func archive(
        entry: ManagedHistoryExportEntry,
        manifest: ManagedHistoryExportManifest,
        root: URL
    ) async throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        let writer = try ManagedHistoryArchiveWriter(destinationURL: url)
        try await writer.add(entry)
        return try await writer.finalize(manifest: manifest)
    }

    private func manifest(
        for entry: ManagedHistoryExportEntry,
        formatVersion: Int
    ) -> ManagedHistoryExportManifest {
        let id = UUID(
            uuidString: entry.path.contains("000000000002")
                ? "10000000-0000-5000-8000-000000000002"
                : "10000000-0000-5000-8000-000000000001"
        )!
        let chunk = ManagedHistoryExportManifest.Chunk(
            path: entry.path,
            chunkID: id,
            sourceID: UUID(
                uuidString: "aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa"
            )!,
            dataClass: "essential_timeseries",
            schemaVersion: 1,
            eventStart: "2026-09-04T11:00:00Z",
            eventEnd: "2026-09-04T11:00:00Z",
            compression: "none",
            contentType: "application/vnd.noop.chunk+json",
            sha256: ManagedDigest.sha256(entry.data),
            compressedBytes: entry.data.count,
            uncompressedBytes: entry.data.count,
            objectGeneration: 1
        )
        return ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: formatVersion,
            createdAt: "2026-09-04T12:00:00Z",
            snapshotAt: "2026-09-04T11:59:00Z",
            changeSequence: 42,
            dataClasses: ["essential_timeseries"],
            selectedObjects: 1,
            selectedChunkBytes: Int64(entry.data.count),
            exportedObjects: 1,
            exportedChunkBytes: Int64(entry.data.count),
            chunks: [chunk],
            documents: [],
            integrity: formatVersion == 2
                ? .init(
                    algorithm: "sha256",
                    entryCount: 1,
                    entriesSHA256:
                        ManagedHistoryArchiveIntegrity.entriesSHA256(
                            chunks: [chunk],
                            documents: []
                        )
                )
                : nil,
            snapshotCursor: formatVersion == 2
                ? .init(
                    formatVersion: 1,
                    snapshotAt: "2026-09-04T11:59:00Z",
                    changeSequence: 42
                )
                : nil
        )
    }

    private func transferDirectory(
        root: URL,
        accountScopeHash: String
    ) -> URL {
        root.appendingPathComponent(
            "ManagedHistoryTransfers",
            isDirectory: true
        ).appendingPathComponent(accountScopeHash, isDirectory: true)
    }

    private func manifest(
        objects: Int,
        bytes: Int64
    ) -> ManagedHistoryExportManifest {
        ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: 1,
            createdAt: "2026-09-04T12:00:00.000Z",
            snapshotAt: "2026-09-04T11:59:00Z",
            changeSequence: 42,
            dataClasses: ["essential_timeseries"],
            selectedObjects: objects,
            selectedChunkBytes: bytes,
            exportedObjects: objects,
            exportedChunkBytes: bytes,
            chunks: [],
            documents: []
        )
    }
}
