import Foundation

/// Selects which credential a social API request carries.
///
/// The configured API key is the self-hosted server's administrator credential and is used only
/// for explicit administrative operations such as bootstrapping a profile. Member credentials are
/// separately issued, least-privilege bearer tokens for the social summary API.
public enum RemoteSocialAuthorization: Equatable, Sendable {
    case admin
    case member(token: String)
}

public struct RemoteFriendProfileCreate: Codable, Equatable, Sendable {
    public let displayName: String
    public let installationId: String
    public let dailyDeviceId: String

    public init(displayName: String, installationId: String, dailyDeviceId: String) {
        self.displayName = displayName
        self.installationId = installationId
        self.dailyDeviceId = dailyDeviceId
    }
}

public struct RemoteFriendProfile: Codable, Equatable, Sendable {
    public let profileId: UUID
    public let enrollmentId: UUID
    public let displayName: String
    public let installationId: String
    public let dailyDeviceId: String?
    public let createdAt: String
    public let updatedAt: String
    public let disabledAt: String?

    public init(
        profileId: UUID,
        enrollmentId: UUID,
        displayName: String,
        installationId: String,
        dailyDeviceId: String?,
        createdAt: String,
        updatedAt: String,
        disabledAt: String? = nil
    ) {
        self.profileId = profileId
        self.enrollmentId = enrollmentId
        self.displayName = displayName
        self.installationId = installationId
        self.dailyDeviceId = dailyDeviceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.disabledAt = disabledAt
    }
}

public struct RemoteFriendBootstrapResponse: Codable, Equatable, Sendable {
    public let profile: RemoteFriendProfile
    public let memberToken: String
    public let tokenNotice: String

    public init(profile: RemoteFriendProfile, memberToken: String, tokenNotice: String) {
        self.profile = profile
        self.memberToken = memberToken
        self.tokenNotice = tokenNotice
    }
}

public struct RemoteFriendProfileResponse: Codable, Equatable, Sendable {
    public let profile: RemoteFriendProfile
    public let privacy: String

    public init(profile: RemoteFriendProfile, privacy: String) {
        self.profile = profile
        self.privacy = privacy
    }
}

public struct RemoteFriendInviteCreate: Codable, Equatable, Sendable {
    public let expiresInHours: Int

    public init(expiresInHours: Int = 72) {
        self.expiresInHours = expiresInHours
    }
}

public struct RemoteFriendInvite: Codable, Equatable, Sendable {
    public let inviteId: UUID
    public let inviterId: UUID
    public let createdAt: String
    public let expiresAt: String
    public let redeemedAt: String?
    public let redeemedBy: UUID?
    public let revokedAt: String?

    public init(
        inviteId: UUID,
        inviterId: UUID,
        createdAt: String,
        expiresAt: String,
        redeemedAt: String? = nil,
        redeemedBy: UUID? = nil,
        revokedAt: String? = nil
    ) {
        self.inviteId = inviteId
        self.inviterId = inviterId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.redeemedAt = redeemedAt
        self.redeemedBy = redeemedBy
        self.revokedAt = revokedAt
    }
}

public struct RemoteFriendInviteResponse: Codable, Equatable, Sendable {
    public let invite: RemoteFriendInvite
    public let code: String
    public let codeNotice: String

    public init(invite: RemoteFriendInvite, code: String, codeNotice: String) {
        self.invite = invite
        self.code = code
        self.codeNotice = codeNotice
    }
}

public struct RemoteFriendInviteRedeem: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// One-step first-profile creation plus invite redemption.
///
/// This is the body for the public one-time-code capability route. The caller generates and
/// persists `enrollmentId` and `memberToken` before the first attempt, then reuses both values for
/// every retry. The server stores only the token digest and never echoes the plaintext token.
public struct RemoteFriendInviteJoin: Codable, Equatable, Sendable {
    public let code: String
    public let displayName: String
    public let installationId: String
    public let dailyDeviceId: String
    public let enrollmentId: UUID
    public let memberToken: String

    public init(
        code: String,
        displayName: String,
        installationId: String,
        dailyDeviceId: String,
        enrollmentId: UUID,
        memberToken: String
    ) {
        self.code = code
        self.displayName = displayName
        self.installationId = installationId
        self.dailyDeviceId = dailyDeviceId
        self.enrollmentId = enrollmentId
        self.memberToken = memberToken
    }
}

public enum RemoteFriendDecision: String, Codable, Equatable, Sendable {
    case accept
    case decline
}

public struct RemoteFriendRequestDecision: Codable, Equatable, Sendable {
    public let decision: RemoteFriendDecision

    public init(decision: RemoteFriendDecision) {
        self.decision = decision
    }
}

public enum RemoteFriendRequestStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case declined
    case cancelled
}

public enum RemoteFriendRequestDirection: String, Codable, Equatable, Sendable {
    case incoming
    case outgoing
}

public struct RemoteFriendIdentity: Codable, Equatable, Sendable {
    public let profileId: UUID
    public let displayName: String

    public init(profileId: UUID, displayName: String) {
        self.profileId = profileId
        self.displayName = displayName
    }
}

/// One friend request across all three response shapes.
///
/// `recipient` is present immediately after redeeming an invite; `direction` and `profile` are
/// present in the requests list; a decision response contains the core request fields only.
public struct RemoteFriendRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let inviteId: UUID
    public let inviterId: UUID
    public let requesterId: UUID
    public let status: RemoteFriendRequestStatus
    public let createdAt: String
    public let decidedAt: String?
    public let direction: RemoteFriendRequestDirection?
    public let profile: RemoteFriendIdentity?
    public let recipient: RemoteFriendIdentity?

    public init(
        requestId: UUID,
        inviteId: UUID,
        inviterId: UUID,
        requesterId: UUID,
        status: RemoteFriendRequestStatus,
        createdAt: String,
        decidedAt: String? = nil,
        direction: RemoteFriendRequestDirection? = nil,
        profile: RemoteFriendIdentity? = nil,
        recipient: RemoteFriendIdentity? = nil
    ) {
        self.requestId = requestId
        self.inviteId = inviteId
        self.inviterId = inviterId
        self.requesterId = requesterId
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.direction = direction
        self.profile = profile
        self.recipient = recipient
    }
}

public struct RemoteFriendRequestResponse: Codable, Equatable, Sendable {
    public let request: RemoteFriendRequest

    public init(request: RemoteFriendRequest) {
        self.request = request
    }
}

public struct RemoteFriendJoinRecipient: Codable, Equatable, Sendable {
    public let displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

/// The intentionally minimal pending-request receipt returned by first-time invite join.
public struct RemoteFriendInviteJoinRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let status: RemoteFriendRequestStatus
    public let createdAt: String
    public let decidedAt: String?
    public let recipient: RemoteFriendJoinRecipient

    public init(
        requestId: UUID,
        status: RemoteFriendRequestStatus,
        createdAt: String,
        decidedAt: String? = nil,
        recipient: RemoteFriendJoinRecipient
    ) {
        self.requestId = requestId
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.recipient = recipient
    }
}

public struct RemoteFriendInviteJoinResponse: Codable, Equatable, Sendable {
    public let profile: RemoteFriendProfile
    public let request: RemoteFriendInviteJoinRequest
    public let idempotentReplay: Bool
    public let tokenNotice: String

    public init(
        profile: RemoteFriendProfile,
        request: RemoteFriendInviteJoinRequest,
        idempotentReplay: Bool,
        tokenNotice: String
    ) {
        self.profile = profile
        self.request = request
        self.idempotentReplay = idempotentReplay
        self.tokenNotice = tokenNotice
    }
}

public struct RemoteFriendRequestsResponse: Codable, Equatable, Sendable {
    public let requests: [RemoteFriendRequest]

    public init(requests: [RemoteFriendRequest]) {
        self.requests = requests
    }
}

public struct RemoteFriendVisibility: Codable, Equatable, Sendable {
    public let charge: Bool
    public let effort: Bool
    public let rest: Bool
    public let sleepDuration: Bool
    public let hrv: Bool
    public let rhr: Bool

    public init(
        charge: Bool = true,
        effort: Bool = true,
        rest: Bool = true,
        sleepDuration: Bool = false,
        hrv: Bool = false,
        rhr: Bool = false
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
    }
}

/// Partial per-friend visibility update. Nil fields are omitted from JSON and left unchanged.
public struct RemoteFriendVisibilityPatch: Codable, Equatable, Sendable {
    public let charge: Bool?
    public let effort: Bool?
    public let rest: Bool?
    public let sleepDuration: Bool?
    public let hrv: Bool?
    public let rhr: Bool?

    public init(
        charge: Bool? = nil,
        effort: Bool? = nil,
        rest: Bool? = nil,
        sleepDuration: Bool? = nil,
        hrv: Bool? = nil,
        rhr: Bool? = nil
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
    }
}

public struct RemoteFriend: Codable, Equatable, Sendable {
    public let profileId: UUID
    public let displayName: String
    public let friendsSince: String
    /// Fields the current profile shares with this friend.
    public let sharing: RemoteFriendVisibility
    /// Fields this friend shares with the current profile.
    public let sharedWithMe: RemoteFriendVisibility

    public init(
        profileId: UUID,
        displayName: String,
        friendsSince: String,
        sharing: RemoteFriendVisibility,
        sharedWithMe: RemoteFriendVisibility
    ) {
        self.profileId = profileId
        self.displayName = displayName
        self.friendsSince = friendsSince
        self.sharing = sharing
        self.sharedWithMe = sharedWithMe
    }
}

public struct RemoteFriendsResponse: Codable, Equatable, Sendable {
    public let friends: [RemoteFriend]

    public init(friends: [RemoteFriend]) {
        self.friends = friends
    }
}

public struct RemoteFriendPrivacyResponse: Codable, Equatable, Sendable {
    public let friendId: UUID
    public let sharing: RemoteFriendVisibility
    public let privacy: String

    public init(friendId: UUID, sharing: RemoteFriendVisibility, privacy: String) {
        self.friendId = friendId
        self.sharing = sharing
        self.privacy = privacy
    }
}

public struct RemoteFriendDailySummary: Codable, Equatable, Sendable {
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

public struct RemoteFriendFeedDay: Codable, Equatable, Sendable {
    public let profileId: UUID
    public let displayName: String
    /// Canonical server day in `yyyy-MM-dd` form.
    public let day: String
    public let summary: RemoteFriendDailySummary

    public init(
        profileId: UUID,
        displayName: String,
        day: String,
        summary: RemoteFriendDailySummary
    ) {
        self.profileId = profileId
        self.displayName = displayName
        self.day = day
        self.summary = summary
    }
}

public struct RemoteFriendFeedUnits: Codable, Equatable, Sendable {
    public let charge: String
    public let effort: String
    public let rest: String
    public let sleepDuration: String
    public let hrv: String
    public let rhr: String

    public init(
        charge: String,
        effort: String,
        rest: String,
        sleepDuration: String,
        hrv: String,
        rhr: String
    ) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.sleepDuration = sleepDuration
        self.hrv = hrv
        self.rhr = rhr
    }
}

public struct RemoteFriendFeedResponse: Codable, Equatable, Sendable {
    public let start: String
    public let end: String
    public let days: [RemoteFriendFeedDay]
    public let units: RemoteFriendFeedUnits
    public let privacy: String

    public init(
        start: String,
        end: String,
        days: [RemoteFriendFeedDay],
        units: RemoteFriendFeedUnits,
        privacy: String
    ) {
        self.start = start
        self.end = end
        self.days = days
        self.units = units
        self.privacy = privacy
    }
}
