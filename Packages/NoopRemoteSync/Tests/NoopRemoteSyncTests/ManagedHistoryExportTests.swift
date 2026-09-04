import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedHistoryExportTests: XCTestCase {
    func testCompleteExportPagesChunksAndDocumentsAndRefreshesAuthorization() async throws {
        let firstData = Data("first-chunk".utf8)
        let secondData = Data("second-chunk".utf8)
        let first = makeChunk(
            id: UUID(uuidString: "10000000-0000-5000-8000-000000000001")!,
            data: firstData,
            start: "2026-09-01T00:00:00Z"
        )
        let second = makeChunk(
            id: UUID(uuidString: "10000000-0000-5000-8000-000000000002")!,
            data: secondData,
            start: "2026-09-01T01:00:00Z"
        )
        let firstDocument = makeDocument(
            id: UUID(uuidString: "40000000-0000-5000-8000-000000000001")!,
            updatedAt: "2026-09-04T10:00:00Z"
        )
        let secondDocument = makeDocument(
            id: UUID(uuidString: "40000000-0000-5000-8000-000000000002")!,
            updatedAt: "2026-09-04T11:00:00Z"
        )
        let transport = ExportTransport(
            chunks: [first, second],
            chunkData: [
                first.chunkID: firstData,
                second.chunkID: secondData,
            ],
            documents: [firstDocument, secondDocument],
            forcePageSize: 1,
            failFirstChunkPageAuthentication: true
        )
        let entries = ExportEntryRecorder()
        let progress = ExportProgressRecorder()
        let authorizations = AuthorizationRecorder()

        let manifest = try await ManagedHistoryExporter(transport: transport).export(
            dataClasses: ["essential_timeseries"],
            pageSize: 25,
            authorization: { forceRefresh in
                try await authorizations.authorization(forceRefresh: forceRefresh)
            },
            progress: { value in
                await progress.append(value)
            },
            consume: { entry in
                await entries.append(entry)
            }
        )

        XCTAssertEqual(manifest.selectedObjects, 4)
        XCTAssertEqual(manifest.exportedObjects, 4)
        XCTAssertEqual(
            manifest.exportedChunkBytes,
            Int64(firstData.count + secondData.count)
        )
        XCTAssertEqual(manifest.chunks.map(\.chunkID), [first.chunkID, second.chunkID])
        XCTAssertEqual(
            manifest.documents.map(\.documentID),
            [firstDocument.documentID, secondDocument.documentID]
        )
        let recordedEntries = await entries.values()
        let completion = await transport.completedValues()
        let chunkPageStarts = await transport.chunkPageStarts()
        let documentPageStarts = await transport.documentPageStarts()
        let refreshRequests = await authorizations.refreshRequests()
        let reportedProgress = await progress.values()
        XCTAssertEqual(recordedEntries.count, 4)
        XCTAssertEqual(completion, .init(objects: 4, bytes: 23))
        XCTAssertEqual(chunkPageStarts, [nil, nil, first.chunkID])
        XCTAssertEqual(documentPageStarts, [nil, firstDocument.documentID])
        XCTAssertEqual(
            refreshRequests,
            [false, false, true, false, false, false, false, false, false]
        )
        XCTAssertEqual(reportedProgress.last?.phase, .finalizing)
        XCTAssertEqual(reportedProgress.last?.completedObjects, 4)
    }

    func testDigestMismatchFailsBeforePublishingEntryOrCompletingSnapshot() async throws {
        let expected = Data("expected".utf8)
        let chunk = makeChunk(
            id: UUID(uuidString: "20000000-0000-5000-8000-000000000001")!,
            data: expected,
            start: "2026-09-01T00:00:00Z"
        )
        let transport = ExportTransport(
            chunks: [chunk],
            chunkData: [chunk.chunkID: Data("tampered".utf8)]
        )
        let entries = ExportEntryRecorder()

        do {
            _ = try await ManagedHistoryExporter(transport: transport).export(
                dataClasses: ["essential_timeseries"],
                authorization: { _ in try Self.authorization() },
                consume: { entry in await entries.append(entry) }
            )
            XCTFail("Expected digest mismatch")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .digestMismatch)
        }

        let recordedEntries = await entries.values()
        let completion = await transport.completedValues()
        XCTAssertTrue(recordedEntries.isEmpty)
        XCTAssertNil(completion)
    }

    func testSelectedObjectCountMismatchFailsClosedWithoutCompletingSnapshot() async throws {
        let data = Data("only-chunk".utf8)
        let chunk = makeChunk(
            id: UUID(uuidString: "30000000-0000-5000-8000-000000000001")!,
            data: data,
            start: "2026-09-01T00:00:00Z"
        )
        let transport = ExportTransport(
            chunks: [chunk],
            chunkData: [chunk.chunkID: data],
            selectedObjectDelta: 1
        )

        do {
            _ = try await ManagedHistoryExporter(transport: transport).export(
                dataClasses: ["essential_timeseries"],
                authorization: { _ in try Self.authorization() },
                consume: { _ in }
            )
            XCTFail("Expected count reconciliation failure")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }

        let completion = await transport.completedValues()
        XCTAssertNil(completion)
    }

    func testManifestEncodingUsesPortableSnakeCaseKeys() throws {
        let manifest = ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: 1,
            createdAt: "2026-09-04T12:00:00.000Z",
            snapshotAt: "2026-09-04T11:59:00Z",
            changeSequence: 42,
            dataClasses: ["essential_timeseries"],
            selectedObjects: 1,
            selectedChunkBytes: 12,
            exportedObjects: 1,
            exportedChunkBytes: 12,
            chunks: [],
            documents: []
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["format_version"] as? Int, 1)
        XCTAssertEqual(object["selected_chunk_bytes"] as? Int, 12)
        XCTAssertEqual(object["exported_chunk_bytes"] as? Int, 12)
        XCTAssertNil(object["formatVersion"])
    }

    private static func authorization() throws -> ManagedAuthorization {
        try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "ios-installation",
            installationToken: "noopm_" + String(repeating: "a", count: 43)
        )
    }

    private func makeChunk(
        id: UUID,
        data: Data,
        start: String
    ) -> ManagedAvailableChunk {
        ManagedAvailableChunk(
            chunkID: id,
            sourceID: UUID(uuidString: "aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa")!,
            dataClass: "essential_timeseries",
            schemaVersion: 1,
            contentMode: "server_readable",
            state: "available",
            eventStart: start,
            eventEnd: start,
            compression: "gzip",
            contentType: "application/vnd.noop.chunk+json",
            expectedSHA256: ManagedDigest.sha256(data),
            expectedCompressedBytes: data.count,
            expectedUncompressedBytes: data.count * 2,
            objectGeneration: 1,
            expiresAt: "2026-09-05T00:00:00Z"
        )
    }

    private func makeDocument(id: UUID, updatedAt: String) -> ManagedDocument {
        ManagedDocument(
            documentKind: .journal,
            documentID: id,
            revision: 1,
            originInstallationID: "ios-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: String(repeating: "b", count: 64),
            payloadJSON: [
                "day": .string("2026-09-04"),
                "answered": .boolean(true),
            ],
            payloadCiphertextBase64: nil,
            updatedAt: updatedAt,
            deletedAt: nil,
            duplicate: false
        )
    }
}

private actor ExportEntryRecorder {
    private var entries: [ManagedHistoryExportEntry] = []

    func append(_ entry: ManagedHistoryExportEntry) {
        entries.append(entry)
    }

    func values() -> [ManagedHistoryExportEntry] {
        entries
    }
}

private actor ExportProgressRecorder {
    private var progress: [ManagedHistoryExportProgress] = []

    func append(_ value: ManagedHistoryExportProgress) {
        progress.append(value)
    }

    func values() -> [ManagedHistoryExportProgress] {
        progress
    }
}

private actor AuthorizationRecorder {
    private var requests: [Bool] = []

    func authorization(forceRefresh: Bool) throws -> ManagedAuthorization {
        requests.append(forceRefresh)
        return try ManagedAuthorization(
            identityToken: forceRefresh ? "fresh-identity" : "cached-identity",
            appCheckToken: "app-check",
            installationID: "ios-installation",
            installationToken: "noopm_" + String(repeating: "a", count: 43)
        )
    }

    func refreshRequests() -> [Bool] {
        requests
    }
}

private actor ExportTransport: ManagedStorageTransport {
    struct Completion: Equatable {
        let objects: Int
        let bytes: Int64
    }

    private let chunks: [ManagedAvailableChunk]
    private let chunkData: [UUID: Data]
    private let documentValues: [ManagedDocument]
    private let forcePageSize: Int?
    private let selectedObjectDelta: Int
    private var failFirstChunkPageAuthentication: Bool
    private var chunkStarts: [UUID?] = []
    private var documentStarts: [UUID?] = []
    private var completion: Completion?
    private let restoreID = UUID(uuidString: "50000000-0000-5000-8000-000000000001")!
    private let snapshot = "2026-09-04T12:00:00Z"

    init(
        chunks: [ManagedAvailableChunk],
        chunkData: [UUID: Data],
        documents: [ManagedDocument] = [],
        forcePageSize: Int? = nil,
        selectedObjectDelta: Int = 0,
        failFirstChunkPageAuthentication: Bool = false
    ) {
        self.chunks = chunks
        self.chunkData = chunkData
        self.documentValues = documents
        self.forcePageSize = forcePageSize
        self.selectedObjectDelta = selectedObjectDelta
        self.failFirstChunkPageAuthentication = failFirstChunkPageAuthentication
    }

    func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        throw ManagedStorageError.invalidResponse
    }

    func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse {
        throw ManagedStorageError.invalidResponse
    }

    func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt {
        throw ManagedStorageError.invalidResponse
    }

    func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws {
        throw ManagedStorageError.invalidResponse
    }

    func changes(
        after sequence: Int64,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed {
        throw ManagedStorageError.invalidResponse
    }

    func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        restore(
            status: "running",
            deliveredObjects: 0,
            deliveredBytes: 0
        )
    }

    func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage {
        chunkStarts.append(cursor?.afterChunkID)
        if failFirstChunkPageAuthentication {
            failFirstChunkPageAuthentication = false
            throw ManagedStorageError.authentication
        }
        let start = cursor.flatMap { cursor in
            chunks.firstIndex { $0.chunkID == cursor.afterChunkID }.map { $0 + 1 }
        } ?? 0
        let count = min(forcePageSize ?? limit, max(0, chunks.count - start))
        let page = Array(chunks.dropFirst(start).prefix(count))
        let hasMore = start + page.count < chunks.count
        let next = hasMore ? page.last.map {
            ManagedChunkPage.Cursor(
                afterEventStart: $0.eventStart,
                afterChunkID: $0.chunkID
            )
        } : nil
        return ManagedChunkPage(chunks: page, nextCursor: next)
    }

    func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        completion = Completion(objects: deliveredObjects, bytes: deliveredBytes)
        return restore(
            status: "completed",
            deliveredObjects: deliveredObjects,
            deliveredBytes: deliveredBytes
        )
    }

    func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability {
        guard let chunk = chunks.first(where: { $0.chunkID == chunkID }) else {
            throw ManagedStorageError.notFound
        }
        return ManagedDownloadCapability(
            grantID: UUID(),
            method: "GET",
            url: URL(string: "https://storage.googleapis.com/noop/\(chunkID)")!,
            headers: [:],
            expiresAt: "2026-09-05T00:00:00Z",
            chunk: .init(
                chunkID: chunkID,
                expectedSHA256: chunk.expectedSHA256,
                compression: chunk.compression,
                contentType: chunk.contentType,
                expectedUncompressedBytes: chunk.expectedUncompressedBytes
            )
        )
    }

    func download(using capability: ManagedDownloadCapability) async throws -> Data {
        guard let data = chunkData[capability.chunk.chunkID] else {
            throw ManagedStorageError.notFound
        }
        return data
    }

    func putDocument(
        _ mutation: ManagedDocumentMutation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        throw ManagedStorageError.invalidResponse
    }

    func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64?,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        throw ManagedStorageError.invalidResponse
    }

    func documents(
        snapshotAt: String,
        after cursor: ManagedDocumentPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocumentPage {
        documentStarts.append(cursor?.afterDocumentID)
        let start = cursor.flatMap { cursor in
            documentValues.firstIndex { $0.documentID == cursor.afterDocumentID }
                .map { $0 + 1 }
        } ?? 0
        let count = min(forcePageSize ?? limit, max(0, documentValues.count - start))
        let page = Array(documentValues.dropFirst(start).prefix(count))
        let hasMore = start + page.count < documentValues.count
        return ManagedDocumentPage(
            documents: page,
            nextCursor: hasMore ? page.last?.pageCursor : nil
        )
    }

    func completedValues() -> Completion? {
        completion
    }

    func chunkPageStarts() -> [UUID?] {
        chunkStarts
    }

    func documentPageStarts() -> [UUID?] {
        documentStarts
    }

    private func restore(
        status: String,
        deliveredObjects: Int,
        deliveredBytes: Int64
    ) -> ManagedRestoreJob {
        ManagedRestoreJob(
            restoreJobID: restoreID,
            status: status,
            snapshotAt: snapshot,
            changeSequence: 42,
            selectedObjects: chunks.count + documentValues.count + selectedObjectDelta,
            selectedBytes: Int64(chunks.reduce(0) { $0 + $1.expectedCompressedBytes }),
            deliveredObjects: deliveredObjects,
            deliveredBytes: deliveredBytes,
            expiresAt: "2026-09-05T00:00:00Z",
            duplicate: false
        )
    }
}
