import NoopRemoteSync
import XCTest
import ZIPFoundation
@testable import Strand

final class ManagedHistoryArchiveWriterTests: XCTestCase {
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
