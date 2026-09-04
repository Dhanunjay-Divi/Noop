import Foundation

public protocol ManagedStorageTransport: Sendable {
    func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse

    func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse

    func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt

    func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws

    func changes(
        after sequence: Int64,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed

    func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob

    func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage

    func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob

    func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability

    func download(using capability: ManagedDownloadCapability) async throws -> Data

    func putDocument(
        _ mutation: ManagedDocumentMutation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument

    func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64?,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument

    func documents(
        snapshotAt: String,
        after cursor: ManagedDocumentPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocumentPage
}

public extension ManagedStorageTransport {
    func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        throw ManagedStorageError.invalidResponse
    }

    func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage {
        throw ManagedStorageError.invalidResponse
    }

    func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        throw ManagedStorageError.invalidResponse
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
        throw ManagedStorageError.invalidResponse
    }
}

extension ManagedStorageClient: ManagedStorageTransport {}
