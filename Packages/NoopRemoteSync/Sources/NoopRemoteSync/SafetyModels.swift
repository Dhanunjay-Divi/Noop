import Foundation

public enum RemoteSafetyAuthorization: Equatable, Sendable {
    case admin
    case safety(token: String)
}

public struct RemoteSafetyProfileBootstrap: Codable, Equatable, Sendable {
    public let displayName: String
    public let installationId: String
    public let enrollmentId: UUID
    public let safetyToken: String

    public init(
        displayName: String,
        installationId: String,
        enrollmentId: UUID,
        safetyToken: String
    ) {
        self.displayName = displayName
        self.installationId = installationId
        self.enrollmentId = enrollmentId
        self.safetyToken = safetyToken
    }
}

public struct RemoteSafetyProfile: Codable, Equatable, Sendable {
    public let profileId: UUID
    public let enrollmentId: UUID
    public let displayName: String
    public let installationId: String
    public let createdAt: String
    public let updatedAt: String
    public let pagingEnabled: Bool?
}

public struct RemoteSafetyBootstrapResponse: Codable, Equatable, Sendable {
    public let profile: RemoteSafetyProfile
    public let credentialNotice: String
}

public enum RemoteSafetyContactStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case declined
    case expired
}

public enum RemoteSafetyDeliveryStatus: String, Codable, Equatable, Sendable {
    case pending
    case submitting
    case leased
    case retryWait = "retry_wait"
    case queued
    case sent
    case delivered
    case failed
    case cancelled
    case unknown
}

public struct RemoteSafetyContact: Codable, Equatable, Identifiable, Sendable {
    public let contactId: UUID
    public let displayName: String
    public let phoneE164: String
    public let status: RemoteSafetyContactStatus
    public let invitedAt: String
    public let inviteExpiresAt: String
    public let invitationProviderReference: String?
    public let invitationDeliveryStatus: RemoteSafetyDeliveryStatus
    public let invitationError: String?
    public let acceptedAt: String?
    public let declinedAt: String?
    public let createdAt: String
    public let updatedAt: String

    public var id: UUID { contactId }
}

public struct RemoteSafetyContactCreate: Codable, Equatable, Sendable {
    public let displayName: String
    public let phoneE164: String

    public init(displayName: String, phoneE164: String) {
        self.displayName = displayName
        self.phoneE164 = phoneE164
    }
}

public struct RemoteSafetyContactResponse: Codable, Equatable, Sendable {
    public let contact: RemoteSafetyContact
    public let notice: String?
}

public struct RemoteSafetyContactsResponse: Codable, Equatable, Sendable {
    public let contacts: [RemoteSafetyContact]
    public let acceptedCount: Int
    public let minimumAccepted: Int
    public let maximumContacts: Int
    public let pagingConfigured: Bool
    public let pagingEnabled: Bool?
}

public struct RemoteSafetyPageCreate: Codable, Equatable, Sendable {
    public let trigger: String

    public init(trigger: String = "manual_sos") {
        self.trigger = trigger
    }
}

public struct RemoteSafetyDelivery: Codable, Equatable, Identifiable, Sendable {
    public let deliveryId: UUID
    public let contactId: UUID
    public let contactDisplayName: String
    public let channel: String
    public let status: RemoteSafetyDeliveryStatus
    public let providerReference: String?
    public let error: String?
    public let availableAt: String?
    public let attemptCount: Int?
    public let maxAttempts: Int?
    public let lastAttemptAt: String?
    public let deliveredAt: String?
    public let terminalAt: String?
    public let createdAt: String
    public let updatedAt: String

    public var id: UUID { deliveryId }
}

public enum RemoteSafetyIncidentStatus: String, Codable, Equatable, Sendable {
    case open
    case acknowledged
    case resolved
    case cancelled
    case expired

    // Older self-hosted servers returned transport aggregates as the page status.
    case pending
    case submitted
    case partialFailure = "partial_failure"
    case failed
}

public enum RemoteSafetyResponseDecision: String, Codable, Equatable, Sendable {
    case responding
    case cannotRespond = "cannot_respond"
}

public struct RemoteSafetyResponse: Codable, Equatable, Identifiable, Sendable {
    public let contactId: UUID
    public let contactDisplayName: String
    public let decision: RemoteSafetyResponseDecision
    public let source: String
    public let respondedAt: String

    public var id: UUID { contactId }
}

public struct RemoteSafetyLocation: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double?
    public let capturedAt: String
    public let receivedAt: String
    public let idempotentReplay: Bool?
}

public struct RemoteSafetyLocationUpdate: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double?
    public let capturedAt: String

    public init(
        sequence: Int64,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double?,
        capturedAt: String
    ) {
        self.sequence = sequence
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capturedAt = capturedAt
    }
}

public struct RemoteSafetyLocationResponse: Codable, Equatable, Sendable {
    public let location: RemoteSafetyLocation
    public let retention: String
}

public struct RemoteSafetyContactSummary: Codable, Equatable, Sendable {
    public let targeted: Int
    public let reached: Int
    public let pending: Int
    public let failed: Int
    public let lastReachedAt: String?
    public let allContactsFailed: Bool

    public var isConsistent: Bool {
        guard targeted > 0,
              reached >= 0, reached <= targeted,
              pending >= 0, pending <= targeted,
              failed >= 0, failed <= targeted
        else { return false }
        let (partial, partialOverflow) = reached.addingReportingOverflow(pending)
        let (total, totalOverflow) = partial.addingReportingOverflow(failed)
        return !partialOverflow
            && !totalOverflow
            && total == targeted
            && allContactsFailed == (failed == targeted)
    }
}

public struct RemoteSafetyDispatch: Codable, Equatable, Sendable {
    public let dispatchId: UUID
    public let idempotencyKey: UUID
    public let trigger: String
    public let status: RemoteSafetyIncidentStatus
    public let createdAt: String
    public let updatedAt: String?
    public let expiresAt: String?
    public let acknowledgedAt: String?
    public let resolvedAt: String?
    public let cancelledAt: String?
    public let acknowledgedContactId: UUID?
    public let acknowledgedContactDisplayName: String?
    public let resolutionNote: String?
    public let completedAt: String?
    public let idempotentReplay: Bool
    public let deliveries: [RemoteSafetyDelivery]
    public let responses: [RemoteSafetyResponse]?
    public let deliverySummary: [String: Int]?
    public let contactSummary: RemoteSafetyContactSummary?
    public let latestLocation: RemoteSafetyLocation?

    private enum CodingKeys: String, CodingKey {
        case dispatchId
        case idempotencyKey
        case trigger
        case status
        case createdAt
        case updatedAt
        case expiresAt
        case acknowledgedAt
        case resolvedAt
        case cancelledAt
        case acknowledgedContactId
        case acknowledgedContactDisplayName
        case resolutionNote
        case completedAt
        case idempotentReplay
        case deliveries
        case responses
        case deliverySummary
        case contactSummary
        case latestLocation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dispatchId = try container.decode(UUID.self, forKey: .dispatchId)
        idempotencyKey = try container.decode(UUID.self, forKey: .idempotencyKey)
        trigger = try container.decode(String.self, forKey: .trigger)
        status = try container.decode(
            RemoteSafetyIncidentStatus.self,
            forKey: .status
        )
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        acknowledgedAt = try container.decodeIfPresent(
            String.self,
            forKey: .acknowledgedAt
        )
        resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt)
        cancelledAt = try container.decodeIfPresent(String.self, forKey: .cancelledAt)
        acknowledgedContactId = try container.decodeIfPresent(
            UUID.self,
            forKey: .acknowledgedContactId
        )
        acknowledgedContactDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .acknowledgedContactDisplayName
        )
        resolutionNote = try container.decodeIfPresent(
            String.self,
            forKey: .resolutionNote
        )
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        idempotentReplay = try container.decode(
            Bool.self,
            forKey: .idempotentReplay
        )
        deliveries = try container.decode(
            [RemoteSafetyDelivery].self,
            forKey: .deliveries
        )
        responses = try container.decodeIfPresent(
            [RemoteSafetyResponse].self,
            forKey: .responses
        )
        deliverySummary = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .deliverySummary
        )
        if let summary = try? container.decode(
            RemoteSafetyContactSummary.self,
            forKey: .contactSummary
        ), summary.isConsistent {
            contactSummary = summary
        } else {
            contactSummary = nil
        }
        latestLocation = try container.decodeIfPresent(
            RemoteSafetyLocation.self,
            forKey: .latestLocation
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dispatchId, forKey: .dispatchId)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(acknowledgedAt, forKey: .acknowledgedAt)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(cancelledAt, forKey: .cancelledAt)
        try container.encodeIfPresent(
            acknowledgedContactId,
            forKey: .acknowledgedContactId
        )
        try container.encodeIfPresent(
            acknowledgedContactDisplayName,
            forKey: .acknowledgedContactDisplayName
        )
        try container.encodeIfPresent(resolutionNote, forKey: .resolutionNote)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(idempotentReplay, forKey: .idempotentReplay)
        try container.encode(deliveries, forKey: .deliveries)
        try container.encodeIfPresent(responses, forKey: .responses)
        try container.encodeIfPresent(deliverySummary, forKey: .deliverySummary)
        try container.encodeIfPresent(contactSummary, forKey: .contactSummary)
        try container.encodeIfPresent(latestLocation, forKey: .latestLocation)
    }
}

public struct RemoteSafetyIncidentList: Codable, Equatable, Sendable {
    public let incidents: [RemoteSafetyDispatch]
}

public struct RemoteSafetyIncidentTransition: Codable, Equatable, Sendable {
    public let note: String?

    public init(note: String? = nil) {
        self.note = note
    }
}
