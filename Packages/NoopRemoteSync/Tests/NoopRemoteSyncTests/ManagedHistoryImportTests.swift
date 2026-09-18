import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedHistoryImportTests: XCTestCase {
    func testValidV2ArchiveImportsEveryChunkAndReportsIntegrityIdentity() async throws {
        let fixture = try makeFixture(bpms: [68, 72])
        let restore = ImportRestoreRecorder()

        let summary = try await importFixture(
            fixture,
            restore: restore
        )

        XCTAssertEqual(summary.importedObjects, 2)
        XCTAssertEqual(summary.importedChunkBytes, fixture.manifest.exportedChunkBytes)
        XCTAssertFalse(summary.resumed)
        XCTAssertEqual(
            summary.archiveSHA256,
            ManagedDigest.sha256(try fixture.manifest.encoded())
        )
        let applied = await restore.appliedChunkIDs()
        XCTAssertEqual(applied, fixture.manifest.chunks.map(\.chunkID))
    }

    func testCorruptLaterEntryFailsBeforeAnyLocalMutation() async throws {
        var fixture = try makeFixture(bpms: [68, 72])
        let corruptPath = fixture.manifest.chunks[1].path
        fixture.entries[corruptPath] = Data("corrupt".utf8)
        let restore = ImportRestoreRecorder()

        do {
            _ = try await importFixture(fixture, restore: restore)
            XCTFail("Expected archive integrity failure")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .digestMismatch)
        }

        let applied = await restore.appliedChunkIDs()
        let calls = await restore.applyCalls()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testImportResumesAfterDurableCheckpointAndCompletedReplayIsIdempotent() async throws {
        let fixture = try makeFixture(bpms: [68, 72])
        let restore = ImportRestoreRecorder()
        let checkpoints = ImportCheckpointRecorder()

        do {
            _ = try await importFixture(
                fixture,
                restore: restore,
                saveCheckpoint: { value in
                    try await checkpoints.saveAndInterruptAfterFirst(value)
                }
            )
            XCTFail("Expected interruption")
        } catch {
            XCTAssertTrue(error is ImportTestInterruption)
        }

        let storedCheckpoint = await checkpoints.latest()
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        let firstCalls = await restore.applyCalls()
        XCTAssertEqual(checkpoint.nextObjectIndex, 1)
        XCTAssertEqual(firstCalls, 1)

        let resumed = try await importFixture(
            fixture,
            resumeFrom: checkpoint,
            restore: restore,
            saveCheckpoint: { value in await checkpoints.save(value) }
        )
        XCTAssertTrue(resumed.resumed)
        let resumedCalls = await restore.applyCalls()
        let applied = await restore.appliedChunkIDs()
        XCTAssertEqual(resumedCalls, 2)
        XCTAssertEqual(applied, fixture.manifest.chunks.map(\.chunkID))

        let storedCompleted = await checkpoints.latest()
        let completed = try XCTUnwrap(storedCompleted)
        XCTAssertTrue(completed.completed)
        _ = try await importFixture(
            fixture,
            resumeFrom: completed,
            restore: restore
        )
        let replayCalls = await restore.applyCalls()
        XCTAssertEqual(replayCalls, 2)
    }

    func testCheckpointFromDifferentArchiveFailsWithConflict() async throws {
        let first = try makeFixture(bpms: [68, 72])
        let second = try makeFixture(bpms: [68, 73])
        let checkpoint = ManagedHistoryImportCheckpoint(
            archiveSHA256: ManagedDigest.sha256(try first.manifest.encoded())
        )
        let restore = ImportRestoreRecorder()

        do {
            _ = try await importFixture(
                second,
                resumeFrom: checkpoint,
                restore: restore
            )
            XCTFail("Expected checkpoint conflict")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .conflict)
        }
        let calls = await restore.applyCalls()
        XCTAssertEqual(calls, 0)
    }

    func testLegacyV1ManifestRemainsImportable() async throws {
        let fixture = try makeFixture(bpms: [68], formatVersion: 1)
        let restore = ImportRestoreRecorder()

        let summary = try await importFixture(
            fixture,
            restore: restore
        )

        XCTAssertEqual(summary.importedObjects, 1)
        let calls = await restore.applyCalls()
        XCTAssertEqual(calls, 1)
    }

    private func importFixture(
        _ fixture: ImportFixture,
        resumeFrom: ManagedHistoryImportCheckpoint? = nil,
        restore: any ManagedRestoreApplying,
        saveCheckpoint: ManagedHistoryImporter.CheckpointConsumer? = nil
    ) async throws -> ManagedHistoryImportSummary {
        try await ManagedHistoryImporter().importArchive(
            manifestData: try fixture.manifest.encoded(),
            entryPaths: Array(fixture.entries.keys) + ["manifest.json"],
            resumeFrom: resumeFrom,
            restore: restore,
            saveCheckpoint: saveCheckpoint,
            read: { path, maximumBytes in
                guard let data = fixture.entries[path],
                      data.count <= maximumBytes else {
                    throw ManagedStorageError.invalidResponse
                }
                return data
            }
        )
    }

    private func makeFixture(
        bpms: [Int64],
        formatVersion: Int = 2
    ) throws -> ImportFixture {
        let sourceID = UUID(
            uuidString: "fe5d19f4-b8ea-4c97-9c3f-e6532f083883"
        )!
        var records: [ManagedHistoryExportManifest.Chunk] = []
        var entries: [String: Data] = [:]
        for (index, bpm) in bpms.enumerated() {
            let start = Int64(1_788_436_800_000 + index * 3_600_000)
            let prepared = try XCTUnwrap(
                ManagedPreparedChunk.prepare(
                    sourceID: sourceID,
                    dataClass: "essential_timeseries",
                    eventStartMs: start,
                    eventEndMs: start + 999,
                    streams: [
                        ManagedChunkStreamPayload(
                            streamKey: "heart_rate",
                            columns: [
                                "event_at_ms",
                                "bpm",
                                "quality",
                                "provenance",
                            ],
                            rows: [[
                                .integer(start),
                                .integer(bpm),
                                .null,
                                .string("sensor"),
                            ]]
                        ),
                    ]
                )
            )
            let path = "chunks/essential_timeseries/"
                + prepared.payload.chunkID.uuidString.lowercased()
                + ".json"
            entries[path] = prepared.uncompressed
            records.append(
                ManagedHistoryExportManifest.Chunk(
                    path: path,
                    chunkID: prepared.payload.chunkID,
                    sourceID: prepared.payload.sourceID,
                    dataClass: prepared.payload.dataClass,
                    schemaVersion: prepared.payload.schemaVersion,
                    eventStart: ManagedTimestamp.iso8601(milliseconds: start),
                    eventEnd: ManagedTimestamp.iso8601(
                        milliseconds: start + 999
                    ),
                    compression: "none",
                    contentType: "application/vnd.noop.chunk+json",
                    sha256: ManagedDigest.sha256(prepared.uncompressed),
                    compressedBytes: prepared.uncompressed.count,
                    uncompressedBytes: prepared.uncompressed.count,
                    objectGeneration: 1
                )
            )
        }
        let bytes = records.reduce(Int64(0)) {
            $0 + Int64($1.compressedBytes)
        }
        let integrity = formatVersion == 2
            ? ManagedHistoryExportManifest.Integrity(
                algorithm: "sha256",
                entryCount: records.count,
                entriesSHA256: ManagedHistoryArchiveIntegrity.entriesSHA256(
                    chunks: records,
                    documents: []
                )
            )
            : nil
        let cursor = formatVersion == 2
            ? ManagedHistoryExportManifest.SnapshotCursor(
                formatVersion: 1,
                snapshotAt: "2026-09-04T11:59:00Z",
                changeSequence: 42
            )
            : nil
        let manifest = ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: formatVersion,
            createdAt: "2026-09-04T12:00:00Z",
            snapshotAt: "2026-09-04T11:59:00Z",
            changeSequence: 42,
            dataClasses: ["essential_timeseries"],
            selectedObjects: records.count,
            selectedChunkBytes: bytes,
            exportedObjects: records.count,
            exportedChunkBytes: bytes,
            chunks: records,
            documents: [],
            integrity: integrity,
            snapshotCursor: cursor
        )
        return ImportFixture(manifest: manifest, entries: entries)
    }
}

private struct ImportFixture {
    let manifest: ManagedHistoryExportManifest
    var entries: [String: Data]
}

private enum ImportTestInterruption: Error {
    case afterFirstObject
}

private actor ImportCheckpointRecorder {
    private var checkpoint: ManagedHistoryImportCheckpoint?
    private var shouldInterrupt = true

    func saveAndInterruptAfterFirst(
        _ value: ManagedHistoryImportCheckpoint
    ) throws {
        checkpoint = value
        if shouldInterrupt, value.nextObjectIndex == 1 {
            shouldInterrupt = false
            throw ImportTestInterruption.afterFirstObject
        }
    }

    func save(_ value: ManagedHistoryImportCheckpoint) {
        checkpoint = value
    }

    func latest() -> ManagedHistoryImportCheckpoint? {
        checkpoint
    }
}

private actor ImportRestoreRecorder: ManagedRestoreApplying {
    private var chunkIDs: [UUID] = []
    private var calls = 0

    func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws {
        _ = change
        calls += 1
        if !chunkIDs.contains(chunk.chunkID) {
            chunkIDs.append(chunk.chunkID)
        }
    }

    func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws {
        _ = chunk
        _ = source
    }

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        _ = document
        _ = change
        calls += 1
    }

    func appliedChunkIDs() -> [UUID] {
        chunkIDs
    }

    func applyCalls() -> Int {
        calls
    }
}
