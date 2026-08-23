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
    public let latestLocation: RemoteSafetyLocation?
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
