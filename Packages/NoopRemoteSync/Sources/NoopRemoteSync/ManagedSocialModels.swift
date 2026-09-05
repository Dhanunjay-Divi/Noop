import Foundation

public struct ManagedSocialBadge: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public let earnedAt: String

    public var id: String { code }

    public init(code: String, earnedAt: String) {
        self.code = code
        self.earnedAt = earnedAt
    }
}

public struct ManagedSocialProfile: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let noopID: String
    public let pokeOptIn: Bool
    public let quietStartMinute: Int
    public let quietEndMinute: Int
    public let timeZone: String
    public let createdAt: String
    public let updatedAt: String
    public let duplicate: Bool
    public let badges: [ManagedSocialBadge]

    public var id: UUID { profileID }

    public init(
        profileID: UUID,
        displayName: String,
        noopID: String,
        pokeOptIn: Bool,
        quietStartMinute: Int,
        quietEndMinute: Int,
        timeZone: String,
        createdAt: String,
        updatedAt: String,
        duplicate: Bool = false,
        badges: [ManagedSocialBadge] = []
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.noopID = noopID
        self.pokeOptIn = pokeOptIn
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
        self.timeZone = timeZone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duplicate = duplicate
        self.badges = badges
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case noopID = "noopId"
        case pokeOptIn
        case quietStartMinute
        case quietEndMinute
        case timeZone
        case createdAt
        case updatedAt
        case duplicate
        case badges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        displayName = try container.decode(String.self, forKey: .displayName)
        noopID = try container.decode(String.self, forKey: .noopID)
        pokeOptIn = try container.decode(Bool.self, forKey: .pokeOptIn)
        quietStartMinute = try container.decode(Int.self, forKey: .quietStartMinute)
        quietEndMinute = try container.decode(Int.self, forKey: .quietEndMinute)
        timeZone = try container.decode(String.self, forKey: .timeZone)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        badges = try container.decodeIfPresent(
            [ManagedSocialBadge].self,
            forKey: .badges
        ) ?? []
    }
}

public struct ManagedSocialLookupProfile: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let noopID: String
    public let isSelf: Bool

    public var id: UUID { profileID }

    public init(
        profileID: UUID,
        displayName: String,
        noopID: String,
        isSelf: Bool
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.noopID = noopID
        self.isSelf = isSelf
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case noopID = "noopId"
        case isSelf = "self"
    }
}

public struct ManagedSocialProfilePatch: Codable, Equatable, Sendable {
    public let displayName: String?
    public let pokeOptIn: Bool?
    public let quietStartMinute: Int?
    public let quietEndMinute: Int?
    public let timeZone: String?

    public init(
        displayName: String? = nil,
        pokeOptIn: Bool? = nil,
        quietStartMinute: Int? = nil,
        quietEndMinute: Int? = nil,
        timeZone: String? = nil
    ) {
        self.displayName = displayName
        self.pokeOptIn = pokeOptIn
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
        self.timeZone = timeZone
    }

    public var hasChange: Bool {
        displayName != nil
            || pokeOptIn != nil
            || quietStartMinute != nil
            || quietEndMinute != nil
            || timeZone != nil
    }
}

public struct ManagedSocialVisibility: Codable, Equatable, Sendable {
    public let charge: Bool
    public let effort: Bool
    public let rest: Bool
    public let sleepDuration: Bool
    public let hrv: Bool
    public let rhr: Bool
    public let pokeAllowed: Bool

    public init(
        charge: Bool = false,
        effort: Bool = false,
        rest: Bool = false,
        sleepDuration: Bool = false,
        hrv: Bool = false,
        rhr: Bool = false,
        pokeAllowed: Bool = false
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
        self.pokeAllowed = pokeAllowed
    }
}

public struct ManagedSocialVisibilityPatch: Codable, Equatable, Sendable {
    public let charge: Bool?
    public let effort: Bool?
    public let rest: Bool?
    public let sleepDuration: Bool?
    public let hrv: Bool?
    public let rhr: Bool?
    public let pokeAllowed: Bool?

    public init(
        charge: Bool? = nil,
        effort: Bool? = nil,
        rest: Bool? = nil,
        sleepDuration: Bool? = nil,
        hrv: Bool? = nil,
        rhr: Bool? = nil,
        pokeAllowed: Bool? = nil
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
        self.pokeAllowed = pokeAllowed
    }

    public var hasChange: Bool {
        charge != nil
            || effort != nil
            || rest != nil
            || sleepDuration != nil
            || hrv != nil
            || rhr != nil
            || pokeAllowed != nil
    }
}

public struct ManagedSocialSummary: Codable, Equatable, Sendable {
    public let charge: Double?
    public let effort: Double?
    public let rest: Double?
    public let sleepDuration: Double?
    public let hrv: Double?
    public let rhr: Double?

    public init(
        charge: Double? = nil,
        effort: Double? = nil,
        rest: Double? = nil,
        sleepDuration: Double? = nil,
        hrv: Double? = nil,
        rhr: Double? = nil
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
    }
}

public struct ManagedSocialLatestSummary: Codable, Equatable, Sendable {
    public let day: String
    public let summary: ManagedSocialSummary
}

public struct ManagedSocialFriend: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let friendsSince: String
    public let sharing: ManagedSocialVisibility
    public let sharedWithMe: ManagedSocialVisibility
    public let latest: ManagedSocialLatestSummary?
    public let badges: [ManagedSocialBadge]

    public var id: UUID { profileID }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case friendsSince
        case sharing
        case sharedWithMe
        case latest
        case badges
    }
}

public struct ManagedSocialBlockedProfile: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let blockedAt: String

    public var id: UUID { profileID }

    public init(
        profileID: UUID,
        displayName: String,
        blockedAt: String
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.blockedAt = blockedAt
    }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case blockedAt
    }
}

public struct ManagedSocialRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestID: UUID
    public let profileID: UUID
    public let displayName: String
    public let direction: String
    public let source: String
    public let status: String
    public let createdAt: String
    public let decidedAt: String?
    public let expiresAt: String
    public let duplicate: Bool?

    public var id: UUID { requestID }
    public var isIncoming: Bool { direction == "incoming" }

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
}

public struct ManagedSocialInvite: Codable, Equatable, Sendable, Identifiable {
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

public struct ManagedSocialFeedDay: Codable, Equatable, Sendable, Identifiable {
    public let profileID: UUID
    public let displayName: String
    public let day: String
    public let summary: ManagedSocialSummary

    public var id: String { "\(profileID.uuidString.lowercased())-\(day)" }

    private enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case displayName
        case day
        case summary
    }
}

public struct ManagedSocialPoke: Codable, Equatable, Sendable, Identifiable {
    public let pokeID: UUID
    public let recipientProfileID: UUID
    public let recipientDisplayName: String
    public let status: String
    public let createdAt: String
    public let expiresAt: String
    public let duplicate: Bool

    public var id: UUID { pokeID }

    private enum CodingKeys: String, CodingKey {
        case pokeID = "pokeId"
        case recipientProfileID = "recipientProfileId"
        case recipientDisplayName
        case status
        case createdAt
        case expiresAt
        case duplicate
    }
}

public struct ManagedSocialPokeClaim: Codable, Equatable, Sendable, Identifiable {
    public let pokeID: UUID
    public let claimID: UUID
    public let senderProfileID: UUID
    public let senderDisplayName: String
    public let createdAt: String
    public let expiresAt: String
    public let claimExpiresAt: String

    public var id: UUID { pokeID }

    private enum CodingKeys: String, CodingKey {
        case pokeID = "pokeId"
        case claimID = "claimId"
        case senderProfileID = "senderProfileId"
        case senderDisplayName
        case createdAt
        case expiresAt
        case claimExpiresAt
    }
}

public struct ManagedSocialPokeAcknowledgement: Codable, Equatable, Sendable {
    public let claimID: UUID
    public let notificationOutcome: String
    public let hapticOutcome: String

    public init(
        claimID: UUID,
        notificationOutcome: String,
        hapticOutcome: String
    ) {
        self.claimID = claimID
        self.notificationOutcome = notificationOutcome
        self.hapticOutcome = hapticOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case claimID = "claimId"
        case notificationOutcome
        case hapticOutcome
    }
}

public struct ManagedSocialPokeReceipt: Codable, Equatable, Sendable {
    public let pokeID: UUID
    public let status: String
    public let duplicate: Bool
    public let notificationOutcome: String
    public let hapticOutcome: String

    private enum CodingKeys: String, CodingKey {
        case pokeID = "pokeId"
        case status
        case duplicate
        case notificationOutcome
        case hapticOutcome
    }
}

public enum ManagedSocialIdentifier {
    public static let noopIDPattern =
        #"^NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$"#
    public static let invitePattern = #"^noopinvite_[A-Za-z0-9_-]{43}$"#

    public static func canonicalNOOPID(_ value: String) -> String? {
        let canonical = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return canonical.range(
            of: noopIDPattern,
            options: .regularExpression
        ) == nil ? nil : canonical
    }

    public static func profileNOOPID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "noop",
              url.host?.lowercased() == "managed-friends",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == "/profile",
              url.fragment == nil,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "noopId",
              let noopID = items[0].value else {
            return nil
        }
        return canonicalNOOPID(noopID)
    }

    public static func profileURL(noopID: String) -> URL? {
        guard let canonical = canonicalNOOPID(noopID) else { return nil }
        var components = URLComponents()
        components.scheme = "noop"
        components.host = "managed-friends"
        components.path = "/profile"
        components.queryItems = [
            URLQueryItem(name: "noopId", value: canonical),
        ]
        return components.url
    }

    public static func inviteCapability(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "noop",
              url.host?.lowercased() == "managed-friends",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.path == "/invite",
              url.fragment == nil,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "capability",
              let capability = items[0].value,
              capability.range(
                  of: invitePattern,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return capability
    }

    public static func inviteURL(capability: String) -> URL? {
        guard capability.range(
            of: invitePattern,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "noop"
        components.host = "managed-friends"
        components.path = "/invite"
        components.queryItems = [
            URLQueryItem(name: "capability", value: capability),
        ]
        return components.url
    }

    public static func makeInviteCapability() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "noopinvite_" + Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum ManagedSocialProjection {
    public static func digest(
        day: String,
        summary: ManagedSocialSummary,
        visibility: ManagedSocialVisibility
    ) -> String? {
        guard day.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let fields = [
            "managed-social-summary-v1",
            day,
            encoded(summary.charge),
            encoded(summary.effort),
            encoded(summary.rest),
            encoded(summary.sleepDuration),
            encoded(summary.hrv),
            encoded(summary.rhr),
            String(visibility.charge),
            String(visibility.effort),
            String(visibility.rest),
            String(visibility.sleepDuration),
            String(visibility.hrv),
            String(visibility.rhr),
        ]
        return ManagedDigest.sha256(Data(fields.joined(separator: "\0").utf8))
    }

    private static func encoded(_ value: Double?) -> String {
        guard let value else { return "~" }
        return String(format: "%016llx", value.bitPattern)
    }
}
