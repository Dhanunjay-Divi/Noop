import Foundation

public struct ManagedStorageConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let policyVersion: String
    public let policySHA256: String
    public let timeout: TimeInterval

    public init(
        baseURL: URL,
        policyVersion: String,
        policySHA256: String,
        timeout: TimeInterval = 60
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw ManagedStorageError.invalidConfiguration
        }
        guard !policyVersion.isEmpty,
              policySHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              timeout > 0 else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.policyVersion = policyVersion
        self.policySHA256 = policySHA256
        self.timeout = timeout
    }
}

public struct ManagedAuthorization: Equatable, Sendable {
    public let identityToken: String
    public let appCheckToken: String
    public let installationID: String
    public let installationToken: String

    public init(
        identityToken: String,
        appCheckToken: String,
        installationID: String,
        installationToken: String
    ) throws {
        guard !identityToken.isEmpty,
              !appCheckToken.isEmpty,
              installationID.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
                options: .regularExpression
              ) != nil,
              installationToken.range(
                of: #"^noopm_[A-Za-z0-9_-]{43}$"#,
                options: .regularExpression
              ) != nil else {
            throw ManagedStorageError.invalidAuthorization
        }
        self.identityToken = identityToken
        self.appCheckToken = appCheckToken
        self.installationID = installationID
        self.installationToken = installationToken
    }
}

public enum ManagedStoragePlatform: String, Codable, Sendable {
    case iOS = "ios"
    case android
}

public struct ManagedEnrollmentRequest: Codable, Equatable, Sendable {
    public let installationID: String
    public let installationToken: String
    public let platform: ManagedStoragePlatform
    public let enrollmentRequestID: UUID
    public let policyVersion: String
    public let policySHA256: String
    public let dataClasses: [String]
    public let deviceKeyFingerprint: String?

    public init(
        installationID: String,
        installationToken: String,
        platform: ManagedStoragePlatform,
        enrollmentRequestID: UUID,
        policyVersion: String,
        policySHA256: String,
        dataClasses: [String],
        deviceKeyFingerprint: String? = nil
    ) {
        self.installationID = installationID
        self.installationToken = installationToken
        self.platform = platform
        self.enrollmentRequestID = enrollmentRequestID
        self.policyVersion = policyVersion
        self.policySHA256 = policySHA256
        self.dataClasses = dataClasses
        self.deviceKeyFingerprint = deviceKeyFingerprint
    }
}

public struct ManagedEnrollmentResponse: Codable, Sendable {
    public struct ProductBoundary: Codable, Equatable, Sendable {
        public let accountOptional: Bool
        public let localMetricsAvailable: Bool
        public let storageOnlyEntitlement: Bool
    }

    public let created: Bool
    public let productBoundary: ProductBoundary
}

public struct ManagedStorageOverview: Equatable, Sendable {
    public let accountStatus: String
    public let planCode: String
    public let planTier: String
    public let maximumBytes: Int64?
    public let committedBytes: Int64
    public let reservedBytes: Int64
    public let installationCount: Int
    public let maximumInstallations: Int

    public init(
        accountStatus: String,
        planCode: String,
        planTier: String,
        maximumBytes: Int64?,
        committedBytes: Int64,
        reservedBytes: Int64,
        installationCount: Int,
        maximumInstallations: Int
    ) {
        self.accountStatus = accountStatus
        self.planCode = planCode
        self.planTier = planTier
        self.maximumBytes = maximumBytes
        self.committedBytes = committedBytes
        self.reservedBytes = reservedBytes
        self.installationCount = installationCount
        self.maximumInstallations = maximumInstallations
    }
}

public struct ManagedInstallation: Codable, Equatable, Sendable, Identifiable {
    public let installationID: String
    public let platform: String
    public let status: String
    public let attestationState: String
    public let registeredAt: String
    public let lastSeenAt: String
    public let revokedAt: String?
    public let current: Bool

    public var id: String { installationID }

    private enum CodingKeys: String, CodingKey {
        case installationID = "installationId"
        case platform
        case status
        case attestationState
        case registeredAt
        case lastSeenAt
        case revokedAt
        case current
    }
}

public struct ManagedSourceRegistration: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let sourceKind: String
    public let platform: ManagedStoragePlatform
    public let logicalSourceHash: String

    public init(
        sourceID: UUID,
        sourceKind: String,
        platform: ManagedStoragePlatform,
        logicalSourceHash: String
    ) {
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.platform = platform
        self.logicalSourceHash = logicalSourceHash
    }
}

public struct ManagedSourceResponse: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let sourceID: UUID
        public let sourceKind: String
    }

    public let source: Source
}

public struct ManagedChunkStreamManifest: Codable, Equatable, Sendable {
    public let streamKey: String
    public let sampleCount: Int
    public let firstEventAt: String?
    public let lastEventAt: String?
    public let encodedBytes: Int
    public let schemaRevision: Int

    public init(
        streamKey: String,
        sampleCount: Int,
        firstEventAt: String?,
        lastEventAt: String?,
        encodedBytes: Int,
        schemaRevision: Int = 1
    ) {
        self.streamKey = streamKey
        self.sampleCount = sampleCount
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.encodedBytes = encodedBytes
        self.schemaRevision = schemaRevision
    }
}

public struct ManagedChunkReservation: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let requestID: UUID
    public let sourceID: UUID
    public let dataClass: String
    public let schemaVersion: Int
    public let contentMode: String
    public let clientKeyID: UUID?
    public let eventStart: String
    public let eventEnd: String
    public let compression: String
    public let contentType: String
    public let expectedSHA256: String
    public let expectedCompressedBytes: Int
    public let expectedUncompressedBytes: Int
    public let streams: [ManagedChunkStreamManifest]

    public init(
        chunkID: UUID,
        requestID: UUID,
        sourceID: UUID,
        dataClass: String,
        eventStart: String,
        eventEnd: String,
        compression: String,
        expectedSHA256: String,
        expectedCompressedBytes: Int,
        expectedUncompressedBytes: Int,
        streams: [ManagedChunkStreamManifest],
        schemaVersion: Int = 1,
        contentMode: String = "server_readable",
        clientKeyID: UUID? = nil,
        contentType: String = "application/vnd.noop.chunk+json"
    ) {
        self.chunkID = chunkID
        self.requestID = requestID
        self.sourceID = sourceID
        self.dataClass = dataClass
        self.schemaVersion = schemaVersion
        self.contentMode = contentMode
        self.clientKeyID = clientKeyID
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.compression = compression
        self.contentType = contentType
        self.expectedSHA256 = expectedSHA256
        self.expectedCompressedBytes = expectedCompressedBytes
        self.expectedUncompressedBytes = expectedUncompressedBytes
        self.streams = streams
    }
}

public struct ManagedChunkReservationResponse: Codable, Sendable {
    public struct Chunk: Codable, Sendable {
        public let chunkID: UUID
        public let state: String
        public let objectGeneration: Int64?
        public let duplicate: Bool
    }

    public struct Upload: Codable, Sendable {
        public let grantID: UUID
        public let method: String
        public let url: URL
        public let headers: [String: String]
        public let expiresAt: String
    }

    public let chunk: Chunk
    public let upload: Upload?
}

public struct ManagedObjectUploadReceipt: Codable, Equatable, Sendable {
    public let objectGeneration: Int64
    public let objectMetageneration: Int64
    public let objectCRC32C: String

    public init(
        objectGeneration: Int64,
        objectMetageneration: Int64,
        objectCRC32C: String
    ) {
        self.objectGeneration = objectGeneration
        self.objectMetageneration = objectMetageneration
        self.objectCRC32C = objectCRC32C
    }

    private enum CodingKeys: String, CodingKey {
        case objectGeneration = "object_generation"
        case objectMetageneration = "object_metageneration"
        case objectCRC32C = "object_crc32c"
    }
}

public struct ManagedChangeFeed: Codable, Sendable {
    public struct Change: Codable, Sendable {
        public struct Chunk: Codable, Sendable {
            public let chunkID: UUID
            public let sourceID: UUID?
            public let schemaVersion: Int?
            public let contentMode: String?
            public let state: String?
            public let compression: String?
            public let contentType: String?
            public let expectedCompressedBytes: Int?
            public let expectedUncompressedBytes: Int?
            public let objectGeneration: Int64?
            public let expiresAt: String?
        }

        public struct Document: Codable, Sendable {
            public let documentKind: ManagedDocumentKind
            public let documentID: UUID
            public let revision: Int64
            public let contentMode: String
            public let clientKeyID: UUID?
            public let updatedAt: String
            public let deletedAt: String?
        }

        public let sequence: Int64
        public let resourceKind: String
        public let resourceID: UUID
        public let operation: String
        public let contentSHA256: String?
        public let dataClass: String?
        public let eventStart: String?
        public let eventEnd: String?
        public let chunk: Chunk?
        public let document: Document?
    }

    public let changes: [Change]
    public let minimumSequence: Int64
    public let highWatermark: Int64
    public let nextSequence: Int64
    public let hasMore: Bool
}

public struct ManagedRestoreRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let dataClasses: [String]
    public let documentKinds: [ManagedDocumentKind]
    public let includeDocuments: Bool
    public let start: String?
    public let end: String?

    public init(
        requestID: UUID,
        dataClasses: [String],
        documentKinds: [ManagedDocumentKind] = [],
        includeDocuments: Bool = false,
        start: String? = nil,
        end: String? = nil
    ) {
        self.requestID = requestID
        self.dataClasses = dataClasses
        self.documentKinds = documentKinds
        self.includeDocuments = includeDocuments
        self.start = start
        self.end = end
    }
}

public struct ManagedRestoreJob: Codable, Equatable, Sendable {
    public let restoreJobID: UUID
    public let status: String
    public let snapshotAt: String
    public let changeSequence: Int64
    public let selectedObjects: Int
    public let selectedBytes: Int64
    public let deliveredObjects: Int
    public let deliveredBytes: Int64
    public let expiresAt: String
    public let duplicate: Bool

    private enum CodingKeys: String, CodingKey {
        case restoreJobID = "restoreJobId"
        case status
        case snapshotAt
        case changeSequence
        case selectedObjects
        case selectedBytes
        case deliveredObjects
        case deliveredBytes
        case expiresAt
        case duplicate
    }
}

public struct ManagedRestoreResponse: Codable, Sendable {
    public let restore: ManagedRestoreJob
}

public struct ManagedRestoreCompletion: Codable, Equatable, Sendable {
    public let deliveredObjects: Int
    public let deliveredBytes: Int64

    public init(deliveredObjects: Int, deliveredBytes: Int64) {
        self.deliveredObjects = deliveredObjects
        self.deliveredBytes = deliveredBytes
    }
}

public struct ManagedAvailableChunk: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let sourceID: UUID
    public let dataClass: String
    public let schemaVersion: Int
    public let contentMode: String
    public let state: String
    public let eventStart: String
    public let eventEnd: String
    public let compression: String
    public let contentType: String
    public let expectedSHA256: String
    public let expectedCompressedBytes: Int
    public let expectedUncompressedBytes: Int
    public let objectGeneration: Int64
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunkId"
        case sourceID = "sourceId"
        case dataClass
        case schemaVersion
        case contentMode
        case state
        case eventStart
        case eventEnd
        case compression
        case contentType
        case expectedSHA256 = "expectedSha256"
        case expectedCompressedBytes
        case expectedUncompressedBytes
        case objectGeneration
        case expiresAt
    }

    public var changeMetadata: ManagedChangeFeed.Change {
        ManagedChangeFeed.Change(
            sequence: 0,
            resourceKind: "chunk",
            resourceID: chunkID,
            operation: "available",
            contentSHA256: expectedSHA256,
            dataClass: dataClass,
            eventStart: eventStart,
            eventEnd: eventEnd,
            chunk: .init(
                chunkID: chunkID,
                sourceID: sourceID,
                schemaVersion: schemaVersion,
                contentMode: contentMode,
                state: state,
                compression: compression,
                contentType: contentType,
                expectedCompressedBytes: expectedCompressedBytes,
                expectedUncompressedBytes: expectedUncompressedBytes,
                objectGeneration: objectGeneration,
                expiresAt: expiresAt
            ),
            document: nil
        )
    }
}

public struct ManagedChunkPage: Codable, Sendable {
    public struct Cursor: Codable, Equatable, Sendable {
        public let afterEventStart: String
        public let afterChunkID: UUID

        public init(afterEventStart: String, afterChunkID: UUID) {
            self.afterEventStart = afterEventStart
            self.afterChunkID = afterChunkID
        }

        private enum CodingKeys: String, CodingKey {
            case afterEventStart
            case afterChunkID = "afterChunkId"
        }
    }

    public let chunks: [ManagedAvailableChunk]
    public let nextCursor: Cursor?
}

public enum ManagedDocumentKind: String, Codable, CaseIterable, Sendable {
    case automation
    case caffeine
    case coachHistory = "coach_history"
    case coachMemory = "coach_memory"
    case cycle
    case dayOwnership = "day_ownership"
    case deviceRegistry = "device_registry"
    case dismissal
    case hydration
    case journal
    case labMarker = "lab_marker"
    case medication
    case mood
    case notificationSettings = "notification_settings"
    case nutrition
    case nutritionCatalog = "nutrition_catalog"
    case preferences
    case profile
    case strengthLog = "strength_log"
    case strengthPlan = "strength_plan"
    case userMarker = "user_marker"
    case workoutPlan = "workout_plan"
    case other
}

public enum ManagedDocumentJSONValue: Codable, Equatable, Sendable {
    case object([String: ManagedDocumentJSONValue])
    case array([ManagedDocumentJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else { throw ManagedStorageError.decoding }
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw ManagedStorageError.encoding }
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct ManagedDocumentMutation: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let documentKind: ManagedDocumentKind
    public let documentID: UUID
    public let baseRevision: Int64
    public let contentMode: String
    public let clientKeyID: UUID?
    public let payloadJSON: [String: ManagedDocumentJSONValue]?
    public let payloadCiphertextBase64: String?
    public let contentSHA256: String?
    public let updatedAt: String
    public let deleted: Bool

    public init(
        requestID: UUID,
        documentKind: ManagedDocumentKind,
        documentID: UUID,
        baseRevision: Int64,
        contentMode: String,
        clientKeyID: UUID? = nil,
        payloadJSON: [String: ManagedDocumentJSONValue]? = nil,
        payloadCiphertextBase64: String? = nil,
        contentSHA256: String? = nil,
        updatedAt: String,
        deleted: Bool = false
    ) {
        self.requestID = requestID
        self.documentKind = documentKind
        self.documentID = documentID
        self.baseRevision = baseRevision
        self.contentMode = contentMode
        self.clientKeyID = clientKeyID
        self.payloadJSON = payloadJSON
        self.payloadCiphertextBase64 = payloadCiphertextBase64
        self.contentSHA256 = contentSHA256
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

public struct ManagedDocument: Codable, Equatable, Sendable {
    public let documentKind: ManagedDocumentKind
    public let documentID: UUID
    public let revision: Int64
    public let originInstallationID: String
    public let contentMode: String
    public let clientKeyID: UUID?
    public let contentSHA256: String
    public let payloadJSON: [String: ManagedDocumentJSONValue]?
    public let payloadCiphertextBase64: String?
    public let updatedAt: String
    public let deletedAt: String?
    public let duplicate: Bool
}

public struct ManagedDocumentResponse: Codable, Sendable {
    public let document: ManagedDocument
}

public struct ManagedDocumentPage: Codable, Sendable {
    public struct Cursor: Codable, Equatable, Sendable {
        public let afterUpdatedAt: String
        public let afterDocumentKind: ManagedDocumentKind
        public let afterDocumentID: UUID

        public init(
            afterUpdatedAt: String,
            afterDocumentKind: ManagedDocumentKind,
            afterDocumentID: UUID
        ) {
            self.afterUpdatedAt = afterUpdatedAt
            self.afterDocumentKind = afterDocumentKind
            self.afterDocumentID = afterDocumentID
        }
    }

    public let documents: [ManagedDocument]
    public let nextCursor: Cursor?
}

extension ManagedDocument {
    var changeMetadata: ManagedChangeFeed.Change {
        ManagedChangeFeed.Change(
            sequence: 0,
            resourceKind: "document",
            resourceID: documentID,
            operation: deletedAt == nil ? "upsert" : "tombstone",
            contentSHA256: contentSHA256,
            dataClass: nil,
            eventStart: nil,
            eventEnd: nil,
            chunk: nil,
            document: ManagedChangeFeed.Change.Document(
                documentKind: documentKind,
                documentID: documentID,
                revision: revision,
                contentMode: contentMode,
                clientKeyID: clientKeyID,
                updatedAt: updatedAt,
                deletedAt: deletedAt
            )
        )
    }

    var pageCursor: ManagedDocumentPage.Cursor {
        ManagedDocumentPage.Cursor(
            afterUpdatedAt: updatedAt,
            afterDocumentKind: documentKind,
            afterDocumentID: documentID
        )
    }
}

public struct ManagedDownloadCapability: Codable, Sendable {
    public struct Chunk: Codable, Sendable {
        public let chunkID: UUID
        public let expectedSHA256: String
        public let compression: String
        public let contentType: String
        public let expectedUncompressedBytes: Int?
    }

    public let grantID: UUID
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let expiresAt: String
    public let chunk: Chunk
}

public enum ManagedErasureScope: String, Codable, Sendable {
    case allManagedData = "all_managed_data"
    case rawChunks = "raw_chunks"
    case derivedData = "derived_data"
    case account
}

public struct ManagedErasureRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let scope: ManagedErasureScope
    public let confirmationSHA256: String

    public init(
        requestID: UUID,
        scope: ManagedErasureScope,
        confirmationSHA256: String
    ) throws {
        guard confirmationSHA256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.requestID = requestID
        self.scope = scope
        self.confirmationSHA256 = confirmationSHA256
    }
}

public struct ManagedErasureJob: Codable, Equatable, Sendable {
    public let erasureJobID: UUID
    public let scope: ManagedErasureScope
    public let status: String
    public let objectsSelected: Int
    public let objectsDeleted: Int
    public let bytesSelected: Int64
    public let bytesDeleted: Int64
    public let databaseRowsDeleted: Int
    public let requestedAt: String
    public let notBefore: String
    public let startedAt: String?
    public let completedAt: String?
    public let verificationExpiresAt: String
    public let duplicate: Bool

    private enum CodingKeys: String, CodingKey {
        // The client's decoder already converts snake_case. Override only the acronym edge:
        // `erasure_job_id` becomes `erasureJobId`, not Swift's `erasureJobID`.
        case erasureJobID = "erasureJobId"
        case scope
        case status
        case objectsSelected
        case objectsDeleted
        case bytesSelected
        case bytesDeleted
        case databaseRowsDeleted
        case requestedAt
        case notBefore
        case startedAt
        case completedAt
        case verificationExpiresAt
        case duplicate
    }
}

public struct ManagedErasureResponse: Codable, Sendable {
    public let erasure: ManagedErasureJob
}

public enum ManagedStorageError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidAuthorization
    case invalidResponse
    case encoding
    case decoding
    case transport
    case authentication
    case notFound
    case policyChanged
    case cursorExpired(minimumSequence: Int64?)
    case quotaExceeded
    case conflict
    case server(status: Int)
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "NOOP+ is not configured in this build."
        case .invalidAuthorization:
            return "Sign in to NOOP+ again."
        case .invalidResponse:
            return "NOOP+ returned an invalid response."
        case .encoding:
            return "NOOP could not prepare the managed-storage request."
        case .decoding:
            return "NOOP could not read the managed-storage response."
        case .transport:
            return "NOOP+ could not be reached."
        case .authentication:
            return "NOOP+ authentication expired. Sign in again."
        case .notFound:
            return "The requested NOOP+ resource no longer exists."
        case .policyChanged:
            return "The NOOP+ storage policy changed. Review it before syncing."
        case .cursorExpired:
            return "This device's cloud cursor expired. A full restore is required."
        case .quotaExceeded:
            return "This NOOP+ storage allowance is full."
        case .conflict:
            return "NOOP+ rejected conflicting sync state."
        case .server:
            return "NOOP+ is temporarily unavailable."
        case .digestMismatch:
            return "A cloud object failed its integrity check."
        }
    }
}
