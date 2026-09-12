import Foundation

public enum ManagedPushEnvironment: String, Codable, Sendable {
    case development
    case production
}

public enum ManagedPushTargetKind: String, Codable, Sendable {
    case token
    case fid
}

public struct ManagedPushRegistrationInfo: Codable, Equatable, Sendable {
    public let installationID: String
    public let platform: ManagedStoragePlatform
    public let environment: ManagedPushEnvironment
    public let targetKind: ManagedPushTargetKind
    public let status: String
    public let updatedAt: String
    public let duplicate: Bool

    private enum CodingKeys: String, CodingKey {
        case installationID = "installationId"
        case platform
        case environment
        case targetKind
        case status
        case updatedAt
        case duplicate
    }
}

public struct ManagedSafetyInvite: Codable, Equatable, Sendable, Identifiable {
    public let inviteID: UUID
    public let capability: String
    public let status: String
    public let createdAt: String
    public let expiresAt: String
    public let duplicate: Bool

    public var id: UUID { inviteID }

    private enum CodingKeys: String, CodingKey {
        case inviteID = "inviteId"
        case capability
        case status
        case createdAt
        case expiresAt
        case duplicate
    }
}

public struct ManagedSafetyRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestID: UUID
    public let profileID: UUID
    public let displayName: String
    public let direction: String
    public let source: String
    public let status: String
    public let createdAt: String
    public let decidedAt: String?
    public let expiresAt: String
    public let duplicate: Bool

    public var id: UUID { requestID }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case profileID = "profileId"
        case displayName
        case direction
        case source
        case status
        case createdAt
        case decidedAt
        case expiresAt
        case duplicate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        displayName = try container.decode(String.self, forKey: .displayName)
        direction = try container.decode(String.self, forKey: .direction)
        source = try container.decode(String.self, forKey: .source)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        decidedAt = try container.decodeIfPresent(String.self, forKey: .decidedAt)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate)
            ?? false
    }
}

public struct ManagedSafetyContactRequestRecord: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let accountScopeHash: String
    public let targetScopeHash: String

    public init(
        requestID: UUID,
        accountScopeHash: String,
        targetScopeHash: String
    ) {
        self.requestID = requestID
        self.accountScopeHash = accountScopeHash
        self.targetScopeHash = targetScopeHash
    }
}

public enum ManagedSafetyContactRequestPolicy {
    public static func targetScopeHash(noopID: String) throws -> String {
        guard let canonical = ManagedSocialIdentifier.canonicalNOOPID(noopID)
        else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedDigest.sha256(
            Data(
                "noop-managed-safety-contact-request-v1\0\(canonical)".utf8
            )
        )
    }

    public static func resolve(
        existing: ManagedSafetyContactRequestRecord?,
        accountScopeHash: String,
        targetScopeHash: String,
        makeRequestID: () -> UUID = { UUID() }
    ) throws -> ManagedSafetyContactRequestRecord {
        guard validDigest(accountScopeHash),
              validDigest(targetScopeHash) else {
            throw ManagedStorageError.invalidResponse
        }
        if let existing, existing.accountScopeHash == accountScopeHash {
            guard existing.targetScopeHash == targetScopeHash else {
                throw ManagedStorageError.conflict
            }
            return existing
        }
        return ManagedSafetyContactRequestRecord(
            requestID: makeRequestID(),
            accountScopeHash: accountScopeHash,
            targetScopeHash: targetScopeHash
        )
    }

    public static func shouldRetire(_ error: Error) -> Bool {
        guard let managed = error as? ManagedStorageError else {
            return false
        }
        switch managed {
        case .invalidConfiguration,
             .encoding,
             .forbidden,
             .notFound,
             .policyChanged,
             .conflict:
            return true
        case let .server(status):
            return (400..<500).contains(status)
                && ![408, 429].contains(status)
        default:
            return false
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct ManagedSafetyContact: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let role: String
    public let acceptedAt: String

    public var id: String {
        "\(profileID.uuidString.lowercased()):\(role)"
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case role
        case acceptedAt
    }
}

public struct ManagedSafetyContacts: Equatable, Sendable {
    public let contacts: [ManagedSafetyContact]
    public let deliveryCapableCount: Int
    public let minimumRequired: Int
    public let maximumAllowed: Int

    public init(
        contacts: [ManagedSafetyContact],
        deliveryCapableCount: Int,
        minimumRequired: Int,
        maximumAllowed: Int
    ) {
        self.contacts = contacts
        self.deliveryCapableCount = deliveryCapableCount
        self.minimumRequired = minimumRequired
        self.maximumAllowed = maximumAllowed
    }
}

public struct ManagedSafetyPushStatus: Codable, Equatable, Sendable {
    public let configured: Bool
    public let reached: Bool
}

public struct ManagedSafetyParticipant: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let status: String
    public let pagedAt: String
    public let respondedAt: String?
    public let push: ManagedSafetyPushStatus

    public var id: UUID { profileID }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case status
        case pagedAt
        case respondedAt
        case push
    }
}

public struct ManagedSafetyLocation: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyM: Double
    public let capturedAt: String
    public let receivedAt: String
    public let duplicate: Bool

    public init(
        sequence: Int64,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyM: Double,
        capturedAt: String,
        receivedAt: String,
        duplicate: Bool = false
    ) {
        self.sequence = sequence
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyM = horizontalAccuracyM
        self.capturedAt = capturedAt
        self.receivedAt = receivedAt
        self.duplicate = duplicate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        sequence = try container.decode(Int64.self, forKey: .sequence)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        horizontalAccuracyM = try container.decode(
            Double.self,
            forKey: .horizontalAccuracyM
        )
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        receivedAt = try container.decode(String.self, forKey: .receivedAt)
        duplicate = try container.decodeIfPresent(
            Bool.self,
            forKey: .duplicate
        ) ?? false
    }
}

public struct ManagedSafetyDelivery: Codable, Equatable, Sendable {
    public let contactsTargeted: Int
    public let contactsReached: Int
    public let installationsTargeted: Int
    public let installationsReached: Int
    public let installationsRetryable: Int?
    public let installationsTerminal: Int?
}

public struct ManagedSafetyIncident: Codable, Equatable, Sendable, Identifiable {
    public let incidentID: UUID
    public let role: String
    public let ownerProfileID: UUID
    public let ownerDisplayName: String
    public let trigger: String
    public let status: String
    public let durationHours: Int
    public let shareLocation: Bool
    public let createdAt: String
    public let expiresAt: String
    public let acknowledgedAt: String?
    public let endedAt: String?
    public let participants: [ManagedSafetyParticipant]
    public let location: ManagedSafetyLocation?
    public let delivery: ManagedSafetyDelivery?
    public let duplicate: Bool

    public var id: UUID { incidentID }

    private enum CodingKeys: String, CodingKey {
        case incidentID = "incidentId"
        case role
        case ownerProfileID = "ownerProfileId"
        case ownerDisplayName
        case trigger
        case status
        case durationHours
        case shareLocation
        case createdAt
        case expiresAt
        case acknowledgedAt
        case endedAt
        case participants
        case location
        case delivery
        case duplicate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incidentID = try container.decode(UUID.self, forKey: .incidentID)
        role = try container.decode(String.self, forKey: .role)
        ownerProfileID = try container.decode(UUID.self, forKey: .ownerProfileID)
        ownerDisplayName = try container.decode(
            String.self,
            forKey: .ownerDisplayName
        )
        trigger = try container.decode(String.self, forKey: .trigger)
        status = try container.decode(String.self, forKey: .status)
        durationHours = try container.decode(Int.self, forKey: .durationHours)
        shareLocation = try container.decode(Bool.self, forKey: .shareLocation)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        acknowledgedAt = try container.decodeIfPresent(
            String.self,
            forKey: .acknowledgedAt
        )
        endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
        participants = try container.decode(
            [ManagedSafetyParticipant].self,
            forKey: .participants
        )
        location = try container.decodeIfPresent(
            ManagedSafetyLocation.self,
            forKey: .location
        )
        delivery = try container.decodeIfPresent(
            ManagedSafetyDelivery.self,
            forKey: .delivery
        )
        duplicate = try container.decodeIfPresent(
            Bool.self,
            forKey: .duplicate
        ) ?? false
    }
}

public struct ManagedSafetyIncidentCreation: Equatable, Sendable {
    public let incident: ManagedSafetyIncident
    public let pushOutcome: String
}

public enum ManagedSafetyPushPayload {
    private static let kind = "managed_safety_incident"
    private static let schema = "1"
    private static let route = "safety"

    public static func incidentID(
        from values: [String: String],
        now: Date = Date()
    ) -> UUID? {
        validatedIncidentID(
            from: values,
            now: now,
            requiresUnexpiredDelivery: true
        )
    }

    public static func incidentIDForUserResponse(
        from userInfo: [AnyHashable: Any],
        now: Date = Date()
    ) -> UUID? {
        let keys = ["kind", "schema", "route", "expires_at", "incident_id"]
        let values = Dictionary(
            uniqueKeysWithValues: keys.compactMap { key in
                (userInfo[key] as? String).map { (key, $0) }
            }
        )
        guard values.count == keys.count else { return nil }
        return validatedIncidentID(
            from: values,
            now: now,
            requiresUnexpiredDelivery: false
        )
    }

    private static func validatedIncidentID(
        from values: [String: String],
        now: Date,
        requiresUnexpiredDelivery: Bool
    ) -> UUID? {
        guard values["kind"] == kind,
              values["schema"] == schema,
              values["route"] == route,
              let rawExpiry = values["expires_at"],
              let expiry = ManagedTimestamp.milliseconds(
                  iso8601: rawExpiry
              ),
              !requiresUnexpiredDelivery
                || expiry > Int64(
                    (now.timeIntervalSince1970 * 1_000).rounded()
                ),
              let rawIncidentID = values["incident_id"] else {
            return nil
        }
        return UUID(uuidString: rawIncidentID)
    }

    public static func incidentID(
        from userInfo: [AnyHashable: Any],
        now: Date = Date()
    ) -> UUID? {
        let keys = ["kind", "schema", "route", "expires_at", "incident_id"]
        let values = Dictionary(
            uniqueKeysWithValues: keys.compactMap { key in
                (userInfo[key] as? String).map { (key, $0) }
            }
        )
        guard values.count == keys.count else { return nil }
        return incidentID(from: values, now: now)
    }
}

public enum ManagedPushRevocationPolicy {
    public static func canFinalizeDisconnect(
        requiresRevocation: Bool,
        serverRevoked: Bool,
        providerTokenDeleted: Bool
    ) -> Bool {
        !requiresRevocation || serverRevoked || providerTokenDeleted
    }
}

public enum ManagedSafetyIdentifier {
    public static let invitePattern =
        #"^noopsafety_[A-Za-z0-9_-]{43}$"#

    public static func makeInviteCapability() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "noopsafety_"
            + Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
    }

    public static func inviteURL(capability: String) -> URL? {
        guard valid(capability) else { return nil }
        var components = URLComponents()
        components.scheme = "noop"
        components.host = "managed-safety"
        components.path = "/invite"
        components.queryItems = [
            URLQueryItem(name: "capability", value: capability),
        ]
        return components.url
    }

    public static func inviteCapability(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "noop",
              url.host?.lowercased() == "managed-safety",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == "/invite",
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "capability",
              let capability = components.queryItems?.first?.value,
              valid(capability) else {
            return nil
        }
        return capability
    }

    public static func valid(_ capability: String) -> Bool {
        capability.range(of: invitePattern, options: .regularExpression) != nil
    }
}
