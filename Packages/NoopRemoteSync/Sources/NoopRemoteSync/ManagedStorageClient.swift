import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ManagedStorageRequestDiagnostic: Sendable, Equatable {
    public let target: String
    public let routeGroup: String
    public let method: String
    public let statusCode: Int?
    public let durationMilliseconds: Int
    public let requestID: String?
    public let outcome: String

    public init(
        target: String,
        routeGroup: String,
        method: String,
        statusCode: Int?,
        durationMilliseconds: Int,
        requestID: String?,
        outcome: String
    ) {
        self.target = target
        self.routeGroup = routeGroup
        self.method = method
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.requestID = requestID
        self.outcome = outcome
    }
}

public actor ManagedStorageClient {
    private struct EmptyResponse: Decodable {}
    private struct AccessRequest: Encodable { let requestID: UUID }
    private struct OverviewResponse: Decodable {
        struct Account: Decodable {
            let status: String
            let planCode: String
            let displayTier: String
            let maxTotalBytes: Int64?
            let maxInstallations: Int
        }

        struct Storage: Decodable {
            struct Rule: Decodable {
                let committedBytes: Int64
                let reservedBytes: Int64
            }

            let installations: Int
            let rules: [Rule]
        }

        let account: Account
        let storage: Storage
    }
    private struct InstallationsResponse: Decodable {
        let installations: [ManagedInstallation]
    }
    private struct InstallationResponse: Decodable {
        let installation: ManagedInstallation
    }
    private struct SocialProfileResponse: Decodable {
        let profile: ManagedSocialProfile
    }
    private struct SocialLookupResponse: Decodable {
        let profile: ManagedSocialLookupProfile
    }
    private struct SocialInviteResponse: Decodable {
        let invite: ManagedSocialInvite
    }
    private struct SocialRequestResponse: Decodable {
        let request: ManagedSocialRequest
    }
    private struct SocialRequestsResponse: Decodable {
        let requests: [ManagedSocialRequest]
    }
    private struct SocialFriendsResponse: Decodable {
        let friends: [ManagedSocialFriend]
    }
    private struct SocialBlocksResponse: Decodable {
        let blocks: [ManagedSocialBlockedProfile]
    }
    private struct SocialVisibilityResponse: Decodable {
        let sharing: ManagedSocialVisibility
    }
    private struct SocialFeedResponse: Decodable {
        let start: String
        let end: String
        let days: [ManagedSocialFeedDay]
    }
    private struct SocialPokeResponse: Decodable {
        let poke: ManagedSocialPoke
    }
    private struct SocialPokeClaimsResponse: Decodable {
        let pokes: [ManagedSocialPokeClaim]
    }
    private struct SocialPokeReceiptResponse: Decodable {
        let poke: ManagedSocialPokeReceipt
    }
    private struct SocialProfileCreateRequest: Encodable {
        let requestID: UUID
        let displayName: String
    }
    private struct SocialInviteCreateRequest: Encodable {
        let requestID: UUID
        let capability: String
        let expiresInHours: Int
    }
    private struct SocialInviteRedeemRequest: Encodable {
        let requestID: UUID
        let capability: String
    }
    private struct SocialRequestCreateRequest: Encodable {
        let requestID: UUID
        let noopID: String
    }
    private struct SocialRequestDecisionRequest: Encodable {
        let decision: String
    }
    private struct SocialSummaryMutationRequest: Encodable {
        let requestID: UUID
        let summary: ManagedSocialSummary
    }
    private struct SocialPokeCreateRequest: Encodable {
        let requestID: UUID
        let recipientProfileID: UUID
    }

    private let configuration: ManagedStorageConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let requestObserver: (@Sendable (ManagedStorageRequestDiagnostic) -> Void)?

    public init(
        configuration: ManagedStorageConfiguration,
        session: URLSession? = nil,
        requestObserver: (@Sendable (ManagedStorageRequestDiagnostic) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.requestObserver = requestObserver
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = max(configuration.timeout, 120)
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func enroll(
        platform: ManagedStoragePlatform,
        dataClasses: [String],
        authorization: ManagedAuthorization,
        requestID: UUID
    ) async throws -> ManagedEnrollmentResponse {
        let body = ManagedEnrollmentRequest(
            installationID: authorization.installationID,
            installationToken: authorization.installationToken,
            platform: platform,
            enrollmentRequestID: requestID,
            policyVersion: configuration.policyVersion,
            policySHA256: configuration.policySHA256,
            dataClasses: dataClasses.sorted()
        )
        return try await send(
            path: "v1/managed/enroll",
            method: "POST",
            body: body,
            authorization: authorization,
            includeInstallation: false
        )
    }

    public func overview(
        authorization: ManagedAuthorization
    ) async throws -> ManagedStorageOverview {
        let response: OverviewResponse = try await send(
            path: "v1/managed/me",
            method: "GET",
            authorization: authorization
        )
        guard !response.account.status.isEmpty,
              !response.account.planCode.isEmpty,
              !response.account.displayTier.isEmpty,
              response.account.maxTotalBytes.map({ $0 > 0 }) ?? true,
              response.account.maxInstallations > 0,
              response.storage.installations >= 0 else {
            throw ManagedStorageError.invalidResponse
        }
        var committedBytes: Int64 = 0
        var reservedBytes: Int64 = 0
        for rule in response.storage.rules {
            guard rule.committedBytes >= 0, rule.reservedBytes >= 0 else {
                throw ManagedStorageError.invalidResponse
            }
            let committed = committedBytes.addingReportingOverflow(rule.committedBytes)
            let reserved = reservedBytes.addingReportingOverflow(rule.reservedBytes)
            guard !committed.overflow, !reserved.overflow else {
                throw ManagedStorageError.invalidResponse
            }
            committedBytes = committed.partialValue
            reservedBytes = reserved.partialValue
        }
        return ManagedStorageOverview(
            accountStatus: response.account.status,
            planCode: response.account.planCode,
            planTier: response.account.displayTier,
            maximumBytes: response.account.maxTotalBytes,
            committedBytes: committedBytes,
            reservedBytes: reservedBytes,
            installationCount: response.storage.installations,
            maximumInstallations: response.account.maxInstallations
        )
    }

    public func installations(
        authorization: ManagedAuthorization
    ) async throws -> [ManagedInstallation] {
        let response: InstallationsResponse = try await send(
            path: "v1/managed/installations",
            method: "GET",
            authorization: authorization
        )
        return response.installations
    }

    public func revokeInstallation(
        _ installationID: String,
        authorization: ManagedAuthorization
    ) async throws -> ManagedInstallation {
        guard installationID != authorization.installationID,
              installationID.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
                options: .regularExpression
              ) != nil else {
            throw ManagedStorageError.invalidAuthorization
        }
        let response: InstallationResponse = try await send(
            path: "v1/managed/installations/\(installationID)",
            method: "DELETE",
            authorization: authorization
        )
        guard response.installation.installationID == installationID else {
            throw ManagedStorageError.invalidResponse
        }
        return response.installation
    }

    public func createSocialProfile(
        displayName: String,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialProfile {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(normalized.count) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialProfileResponse = try await send(
            path: "v1/managed/social/profile",
            method: "POST",
            body: SocialProfileCreateRequest(
                requestID: requestID,
                displayName: normalized
            ),
            authorization: authorization
        )
        try Self.validate(response.profile)
        return response.profile
    }

    public func socialProfile(
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialProfile {
        let response: SocialProfileResponse = try await send(
            path: "v1/managed/social/profile",
            method: "GET",
            authorization: authorization
        )
        try Self.validate(response.profile)
        return response.profile
    }

    public func deleteSocialProfile(
        authorization: ManagedAuthorization
    ) async throws {
        try await sendWithoutResponse(
            path: "v1/managed/social/profile",
            method: "DELETE",
            authorization: authorization,
            additionalHeaders: [
                "X-Noop-Confirm": "DELETE MANAGED FRIENDS",
            ]
        )
    }

    public func updateSocialProfile(
        _ patch: ManagedSocialProfilePatch,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialProfile {
        guard patch.hasChange,
              patch.displayName.map({
                  let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  return (1...64).contains(value.count)
              }) ?? true,
              patch.quietStartMinute.map({ (0...1439).contains($0) }) ?? true,
              patch.quietEndMinute.map({ (0...1439).contains($0) }) ?? true,
              patch.timeZone.map({ !$0.isEmpty && $0.count <= 64 }) ?? true else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialProfileResponse = try await send(
            path: "v1/managed/social/profile",
            method: "PATCH",
            body: patch,
            authorization: authorization
        )
        try Self.validate(response.profile)
        return response.profile
    }

    public func rotateSocialNOOPID(
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialProfile {
        let response: SocialProfileResponse = try await send(
            path: "v1/managed/social/noop-id:rotate",
            method: "POST",
            authorization: authorization
        )
        try Self.validate(response.profile)
        return response.profile
    }

    public func lookupSocialProfile(
        noopID: String,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialLookupProfile {
        guard let canonical = ManagedSocialIdentifier.canonicalNOOPID(noopID) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialLookupResponse = try await send(
            path: "v1/managed/social/lookup?noop_id=\(Self.queryValue(canonical))",
            method: "GET",
            authorization: authorization
        )
        guard ManagedSocialIdentifier.canonicalNOOPID(response.profile.noopID)
                == response.profile.noopID,
              !response.profile.displayName.isEmpty,
              response.profile.displayName.count <= 64 else {
            throw ManagedStorageError.invalidResponse
        }
        return response.profile
    }

    public func createSocialInvite(
        capability: String,
        expiresInHours: Int = 72,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialInvite {
        guard capability.range(
            of: ManagedSocialIdentifier.invitePattern,
            options: .regularExpression
        ) != nil,
        (1...168).contains(expiresInHours) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialInviteResponse = try await send(
            path: "v1/managed/social/invites",
            method: "POST",
            body: SocialInviteCreateRequest(
                requestID: requestID,
                capability: capability,
                expiresInHours: expiresInHours
            ),
            authorization: authorization
        )
        guard response.invite.capability == capability,
              ["active", "revoked", "redeemed", "expired"].contains(
                  response.invite.status
              ),
              ManagedTimestamp.milliseconds(iso8601: response.invite.createdAt) != nil,
              ManagedTimestamp.milliseconds(iso8601: response.invite.expiresAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
        return response.invite
    }

    public func revokeSocialInvite(
        _ inviteID: UUID,
        authorization: ManagedAuthorization
    ) async throws {
        try await sendWithoutResponse(
            path: "v1/managed/social/invites/\(inviteID.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
    }

    public func redeemSocialInvite(
        capability: String,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialRequest {
        guard capability.range(
            of: ManagedSocialIdentifier.invitePattern,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialRequestResponse = try await send(
            path: "v1/managed/social/invites:redeem",
            method: "POST",
            body: SocialInviteRedeemRequest(
                requestID: requestID,
                capability: capability
            ),
            authorization: authorization
        )
        try Self.validate(response.request)
        return response.request
    }

    public func createSocialRequest(
        noopID: String,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialRequest {
        guard let canonical = ManagedSocialIdentifier.canonicalNOOPID(noopID) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialRequestResponse = try await send(
            path: "v1/managed/social/requests",
            method: "POST",
            body: SocialRequestCreateRequest(
                requestID: requestID,
                noopID: canonical
            ),
            authorization: authorization
        )
        try Self.validate(response.request)
        return response.request
    }

    public func socialRequests(
        authorization: ManagedAuthorization
    ) async throws -> [ManagedSocialRequest] {
        let response: SocialRequestsResponse = try await send(
            path: "v1/managed/social/requests",
            method: "GET",
            authorization: authorization
        )
        guard response.requests.count <= 100 else {
            throw ManagedStorageError.invalidResponse
        }
        try response.requests.forEach(Self.validate)
        return response.requests
    }

    public func decideSocialRequest(
        _ requestID: UUID,
        accept: Bool,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialRequest {
        let response: SocialRequestResponse = try await send(
            path: "v1/managed/social/requests/\(requestID.uuidString.lowercased())",
            method: "POST",
            body: SocialRequestDecisionRequest(
                decision: accept ? "accept" : "decline"
            ),
            authorization: authorization
        )
        try Self.validate(response.request)
        return response.request
    }

    public func socialFriends(
        authorization: ManagedAuthorization
    ) async throws -> [ManagedSocialFriend] {
        let response: SocialFriendsResponse = try await send(
            path: "v1/managed/social/friends",
            method: "GET",
            authorization: authorization
        )
        guard response.friends.count <= 500 else {
            throw ManagedStorageError.invalidResponse
        }
        try response.friends.forEach(Self.validate)
        return response.friends
    }

    public func updateSocialVisibility(
        friendProfileID: UUID,
        patch: ManagedSocialVisibilityPatch,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialVisibility {
        guard patch.hasChange else { throw ManagedStorageError.invalidResponse }
        let response: SocialVisibilityResponse = try await send(
            path: "v1/managed/social/friends/"
                + "\(friendProfileID.uuidString.lowercased())/privacy",
            method: "PATCH",
            body: patch,
            authorization: authorization
        )
        return response.sharing
    }

    public func removeSocialFriend(
        _ profileID: UUID,
        authorization: ManagedAuthorization
    ) async throws {
        try await sendWithoutResponse(
            path: "v1/managed/social/friends/\(profileID.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
    }

    public func blockSocialProfile(
        _ profileID: UUID,
        authorization: ManagedAuthorization
    ) async throws {
        try await sendWithoutResponse(
            path: "v1/managed/social/blocks/\(profileID.uuidString.lowercased())",
            method: "POST",
            authorization: authorization
        )
    }

    public func socialBlockedProfiles(
        authorization: ManagedAuthorization
    ) async throws -> [ManagedSocialBlockedProfile] {
        let response: SocialBlocksResponse = try await send(
            path: "v1/managed/social/blocks",
            method: "GET",
            authorization: authorization
        )
        guard response.blocks.count <= 500 else {
            throw ManagedStorageError.invalidResponse
        }
        try response.blocks.forEach(Self.validate)
        return response.blocks
    }

    public func unblockSocialProfile(
        _ profileID: UUID,
        authorization: ManagedAuthorization
    ) async throws {
        try await sendWithoutResponse(
            path: "v1/managed/social/blocks/\(profileID.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
    }

    public func putSocialSummary(
        day: String,
        summary: ManagedSocialSummary,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws {
        guard Self.isDay(day), Self.valid(summary) else {
            throw ManagedStorageError.invalidResponse
        }
        let _: EmptyResponse = try await send(
            path: "v1/managed/social/summaries/\(day)",
            method: "PUT",
            body: SocialSummaryMutationRequest(
                requestID: requestID,
                summary: summary
            ),
            authorization: authorization,
            acceptAnyJSONObject: true
        )
    }

    public func socialFeed(
        startDay: String,
        endDay: String,
        authorization: ManagedAuthorization
    ) async throws -> [ManagedSocialFeedDay] {
        guard Self.isDay(startDay), Self.isDay(endDay) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialFeedResponse = try await send(
            path: "v1/managed/social/feed?start=\(startDay)&end=\(endDay)",
            method: "GET",
            authorization: authorization
        )
        guard response.start == startDay,
              response.end == endDay,
              response.days.count <= 45_000,
              response.days.allSatisfy({
                  Self.isDay($0.day)
                      && !$0.displayName.isEmpty
                      && Self.valid($0.summary)
              }) else {
            throw ManagedStorageError.invalidResponse
        }
        return response.days
    }

    public func createSocialPoke(
        recipientProfileID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialPoke {
        let response: SocialPokeResponse = try await send(
            path: "v1/managed/social/pokes",
            method: "POST",
            body: SocialPokeCreateRequest(
                requestID: requestID,
                recipientProfileID: recipientProfileID
            ),
            authorization: authorization
        )
        guard response.poke.recipientProfileID == recipientProfileID,
              response.poke.status == "queued",
              !response.poke.recipientDisplayName.isEmpty,
              ManagedTimestamp.milliseconds(iso8601: response.poke.createdAt) != nil,
              ManagedTimestamp.milliseconds(iso8601: response.poke.expiresAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
        return response.poke
    }

    public func claimSocialPokes(
        limit: Int = 3,
        authorization: ManagedAuthorization
    ) async throws -> [ManagedSocialPokeClaim] {
        guard (1...10).contains(limit) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialPokeClaimsResponse = try await send(
            path: "v1/managed/social/pokes:claim?limit=\(limit)",
            method: "POST",
            authorization: authorization
        )
        guard response.pokes.count <= limit,
              response.pokes.allSatisfy({
                  !$0.senderDisplayName.isEmpty
                      && ManagedTimestamp.milliseconds(iso8601: $0.createdAt) != nil
                      && ManagedTimestamp.milliseconds(iso8601: $0.expiresAt) != nil
                      && ManagedTimestamp.milliseconds(
                          iso8601: $0.claimExpiresAt
                      ) != nil
              }) else {
            throw ManagedStorageError.invalidResponse
        }
        return response.pokes
    }

    public func acknowledgeSocialPoke(
        _ pokeID: UUID,
        acknowledgement: ManagedSocialPokeAcknowledgement,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSocialPokeReceipt {
        guard ["scheduled", "not_authorized", "failed"].contains(
            acknowledgement.notificationOutcome
        ),
        ["requested", "band_unavailable", "not_eligible", "failed"].contains(
            acknowledgement.hapticOutcome
        ) else {
            throw ManagedStorageError.invalidResponse
        }
        let response: SocialPokeReceiptResponse = try await send(
            path: "v1/managed/social/pokes/\(pokeID.uuidString.lowercased()):ack",
            method: "POST",
            body: acknowledgement,
            authorization: authorization
        )
        guard response.poke.pokeID == pokeID,
              response.poke.status == "acknowledged",
              response.poke.notificationOutcome
                == acknowledgement.notificationOutcome,
              response.poke.hapticOutcome == acknowledgement.hapticOutcome else {
            throw ManagedStorageError.invalidResponse
        }
        return response.poke
    }

    public func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        try await send(
            path: "v1/managed/sources",
            method: "POST",
            body: source,
            authorization: authorization
        )
    }

    public func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse {
        try await send(
            path: "v1/managed/chunks:reserve",
            method: "POST",
            body: reservation,
            authorization: authorization
        )
    }

    public func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt {
        guard capability.method.uppercased() == "PUT",
              capability.url.scheme?.lowercased() == "https",
              capability.url.host != nil,
              capability.url.user == nil,
              capability.url.password == nil else {
            throw ManagedStorageError.invalidResponse
        }
        var request = URLRequest(url: capability.url)
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.timeoutInterval = max(configuration.timeout, 120)
        for (name, value) in capability.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode),
              let generation = response.value(forHTTPHeaderField: "x-goog-generation")
                .flatMap(Int64.init),
              generation > 0,
              let metageneration = response.value(forHTTPHeaderField: "x-goog-metageneration")
                .flatMap(Int64.init),
              metageneration > 0,
              let crc32c = Self.crc32c(
                from: response.value(forHTTPHeaderField: "x-goog-hash")
              ),
              crc32c.range(
                of: #"^[A-Za-z0-9+/]{6}==$"#,
                options: .regularExpression
              ) != nil else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedObjectUploadReceipt(
            objectGeneration: generation,
            objectMetageneration: metageneration,
            objectCRC32C: crc32c
        )
    }

    public func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws {
        let _: EmptyResponse = try await send(
            path: "v1/managed/chunks/\(chunkID.uuidString.lowercased())/complete",
            method: "POST",
            body: receipt,
            authorization: authorization,
            acceptAnyJSONObject: true
        )
    }

    public func changes(
        after sequence: Int64,
        limit: Int = 200,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed {
        guard sequence >= 0, (1...500).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        return try await send(
            path: "v1/managed/changes?after_sequence=\(sequence)&limit=\(limit)",
            method: "GET",
            authorization: authorization
        )
    }

    public func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        let classes = dataClasses.sorted()
        guard !classes.isEmpty,
              Set(classes).count == classes.count,
              classes.allSatisfy({
                  $0.range(
                      of: #"^[a-z][a-z0-9_]{1,63}$"#,
                      options: .regularExpression
                  ) != nil
              }) else {
            throw ManagedStorageError.invalidConfiguration
        }
        let response: ManagedRestoreResponse = try await send(
            path: "v1/managed/restores",
            method: "POST",
            body: ManagedRestoreRequest(
                requestID: requestID,
                dataClasses: classes,
                includeDocuments: true
            ),
            authorization: authorization
        )
        if ["expired", "completed"].contains(response.restore.status) {
            throw ManagedStorageError.conflict
        }
        try Self.validate(response.restore, expectedStatus: "running")
        return response.restore
    }

    public func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage {
        guard dataClass.range(
            of: #"^[a-z][a-z0-9_]{1,63}$"#,
            options: .regularExpression
        ) != nil,
        ManagedTimestamp.milliseconds(iso8601: snapshotAt) != nil,
        (1...200).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        var query = [
            "data_class=\(Self.queryValue(dataClass))",
            "snapshot_at=\(Self.queryValue(snapshotAt))",
            "limit=\(limit)",
        ]
        if let cursor {
            guard ManagedTimestamp.milliseconds(iso8601: cursor.afterEventStart) != nil else {
                throw ManagedStorageError.invalidConfiguration
            }
            query.append(
                "after_event_start=\(Self.queryValue(cursor.afterEventStart))"
            )
            query.append(
                "after_chunk_id=\(cursor.afterChunkID.uuidString.lowercased())"
            )
        }
        let page: ManagedChunkPage = try await send(
            path: "v1/managed/chunks?\(query.joined(separator: "&"))",
            method: "GET",
            authorization: authorization
        )
        for chunk in page.chunks {
            guard chunk.dataClass == dataClass,
                  chunk.state == "available",
                  chunk.contentMode == "server_readable",
                  chunk.schemaVersion > 0,
                  chunk.expectedSHA256.range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  chunk.expectedCompressedBytes > 0,
                  chunk.expectedUncompressedBytes > 0,
                  chunk.objectGeneration > 0,
                  ManagedTimestamp.milliseconds(iso8601: chunk.eventStart) != nil,
                  ManagedTimestamp.milliseconds(iso8601: chunk.eventEnd) != nil else {
                throw ManagedStorageError.invalidResponse
            }
        }
        if let next = page.nextCursor {
            guard let last = page.chunks.last,
                  next.afterChunkID == last.chunkID,
                  next.afterEventStart == last.eventStart else {
                throw ManagedStorageError.invalidResponse
            }
        }
        return page
    }

    public func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        guard deliveredObjects >= 0, deliveredBytes >= 0 else {
            throw ManagedStorageError.invalidConfiguration
        }
        let response: ManagedRestoreResponse = try await send(
            path: "v1/managed/restores/"
                + restoreJobID.uuidString.lowercased()
                + "/complete",
            method: "POST",
            body: ManagedRestoreCompletion(
                deliveredObjects: deliveredObjects,
                deliveredBytes: deliveredBytes
            ),
            authorization: authorization
        )
        try Self.validate(response.restore, expectedStatus: "completed")
        guard response.restore.restoreJobID == restoreJobID,
              response.restore.deliveredObjects == deliveredObjects,
              response.restore.deliveredBytes == deliveredBytes else {
            throw ManagedStorageError.invalidResponse
        }
        return response.restore
    }

    public func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability {
        try await send(
            path: "v1/managed/chunks/\(chunkID.uuidString.lowercased())/download",
            method: "POST",
            body: AccessRequest(requestID: requestID),
            authorization: authorization
        )
    }

    public func download(
        using capability: ManagedDownloadCapability
    ) async throws -> Data {
        guard capability.method.uppercased() == "GET",
              capability.url.scheme?.lowercased() == "https",
              capability.url.host != nil,
              capability.url.user == nil,
              capability.url.password == nil else {
            throw ManagedStorageError.invalidResponse
        }
        var request = URLRequest(url: capability.url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(configuration.timeout, 120)
        for (name, value) in capability.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ManagedStorageError.server(status: response.statusCode)
        }
        guard ManagedDigest.sha256(data).caseInsensitiveCompare(
            capability.chunk.expectedSHA256
        ) == .orderedSame else {
            throw ManagedStorageError.digestMismatch
        }
        return data
    }

    public func putDocument(
        _ mutation: ManagedDocumentMutation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        let response: ManagedDocumentResponse = try await send(
            path: "v1/managed/documents/\(mutation.documentKind.rawValue)/"
                + mutation.documentID.uuidString.lowercased(),
            method: "PUT",
            body: mutation,
            authorization: authorization
        )
        return response.document
    }

    public func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64? = nil,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        guard revision.map({ $0 > 0 }) ?? true else {
            throw ManagedStorageError.invalidConfiguration
        }
        let query = revision.map { "?revision=\($0)" } ?? ""
        let response: ManagedDocumentResponse = try await send(
            path: "v1/managed/documents/\(kind.rawValue)/"
                + id.uuidString.lowercased() + query,
            method: "GET",
            authorization: authorization
        )
        return response.document
    }

    public func documents(
        snapshotAt: String,
        after cursor: ManagedDocumentPage.Cursor? = nil,
        limit: Int = 100,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocumentPage {
        guard ManagedTimestamp.milliseconds(iso8601: snapshotAt) != nil,
              (1...200).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        var query = [
            "include_deleted=false",
            "snapshot_at=\(Self.queryValue(snapshotAt))",
            "limit=\(limit)",
        ]
        if let cursor {
            guard ManagedTimestamp.milliseconds(
                iso8601: cursor.afterUpdatedAt
            ) != nil else {
                throw ManagedStorageError.invalidConfiguration
            }
            query.append(
                "after_updated_at=\(Self.queryValue(cursor.afterUpdatedAt))"
            )
            query.append(
                "after_document_kind=\(cursor.afterDocumentKind.rawValue)"
            )
            query.append(
                "after_document_id=\(cursor.afterDocumentID.uuidString.lowercased())"
            )
        }
        let page: ManagedDocumentPage = try await send(
            path: "v1/managed/documents?\(query.joined(separator: "&"))",
            method: "GET",
            authorization: authorization
        )
        for document in page.documents {
            guard document.revision > 0,
                  document.contentMode == "server_readable",
                  document.clientKeyID == nil,
                  document.payloadJSON != nil,
                  document.payloadCiphertextBase64 == nil,
                  document.deletedAt == nil,
                  document.contentSHA256.range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  ManagedTimestamp.milliseconds(
                      iso8601: document.updatedAt
                  ) != nil else {
                throw ManagedStorageError.invalidResponse
            }
        }
        if let next = page.nextCursor {
            guard let last = page.documents.last,
                  next == last.pageCursor else {
                throw ManagedStorageError.invalidResponse
            }
        }
        return page
    }

    public func requestErasure(
        _ request: ManagedErasureRequest,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure",
            method: "POST",
            body: request,
            authorization: authorization
        )
        return response.erasure
    }

    public func erasure(
        jobID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure/\(jobID.uuidString.lowercased())",
            method: "GET",
            authorization: authorization
        )
        return response.erasure
    }

    public func cancelErasure(
        jobID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure/\(jobID.uuidString.lowercased())/cancel",
            method: "POST",
            body: Optional<Int>.none,
            authorization: authorization
        )
        return response.erasure
    }

    func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        authorization: ManagedAuthorization,
        includeInstallation: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.scheme == configuration.baseURL.scheme,
              url.host == configuration.baseURL.host,
              url.port == configuration.baseURL.port else {
            throw ManagedStorageError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        request.setValue(
            "Bearer \(authorization.identityToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            authorization.appCheckToken,
            forHTTPHeaderField: "X-Firebase-AppCheck"
        )
        if includeInstallation {
            request.setValue(
                authorization.installationID,
                forHTTPHeaderField: "X-Noop-Installation-ID"
            )
            request.setValue(
                authorization.installationToken,
                forHTTPHeaderField: "X-Noop-Installation-Token"
            )
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw ManagedStorageError.encoding
            }
        }
        return request
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        authorization: ManagedAuthorization
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: Optional<Int>.none,
            authorization: authorization
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        authorization: ManagedAuthorization,
        includeInstallation: Bool = true,
        acceptAnyJSONObject: Bool = false
    ) async throws -> Response {
        let request = try makeRequest(
            path: path,
            method: method,
            body: body,
            authorization: authorization,
            includeInstallation: includeInstallation
        )
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response.statusCode, data: data)
        }
        if acceptAnyJSONObject, Response.self == EmptyResponse.self {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw ManagedStorageError.decoding
            }
            return EmptyResponse() as! Response
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ManagedStorageError.decoding
        }
    }

    private func sendWithoutResponse(
        path: String,
        method: String,
        authorization: ManagedAuthorization,
        additionalHeaders: [String: String] = [:]
    ) async throws {
        var request = try makeRequest(
            path: path,
            method: method,
            body: Optional<Int>.none,
            authorization: authorization,
            includeInstallation: true
        )
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response.statusCode, data: data)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                observe(
                    request,
                    response: nil,
                    startedAt: startedAt,
                    outcome: "invalid_response"
                )
                throw ManagedStorageError.invalidResponse
            }
            observe(
                request,
                response: response,
                startedAt: startedAt,
                outcome: (200..<300).contains(response.statusCode)
                    ? "completed"
                    : "rejected"
            )
            return (data, response)
        } catch let error as ManagedStorageError {
            throw error
        } catch {
            observe(
                request,
                response: nil,
                startedAt: startedAt,
                outcome: "transport_failed"
            )
            throw ManagedStorageError.transport
        }
    }

    private func observe(
        _ request: URLRequest,
        response: HTTPURLResponse?,
        startedAt: TimeInterval,
        outcome: String
    ) {
        guard let requestObserver else { return }
        let isManagedAPI = request.url.map {
            $0.scheme?.caseInsensitiveCompare(configuration.baseURL.scheme ?? "") == .orderedSame
                && $0.host?.caseInsensitiveCompare(configuration.baseURL.host ?? "") == .orderedSame
                && $0.port == configuration.baseURL.port
        } ?? false
        let routeGroup: String
        if isManagedAPI {
            let components = request.url?.pathComponents.filter { $0 != "/" } ?? []
            routeGroup = "/" + components.prefix(3).joined(separator: "/")
        } else {
            routeGroup = "object_store"
        }
        let requestID = response?
            .value(forHTTPHeaderField: "X-Noop-Request-ID")
            .flatMap { value in
                value.range(
                    of: #"^[0-9a-f]{32}$"#,
                    options: .regularExpression
                ) == nil ? nil : value
            }
        requestObserver(
            ManagedStorageRequestDiagnostic(
                target: isManagedAPI ? "managed_api" : "object_store",
                routeGroup: routeGroup,
                method: request.httpMethod?.uppercased() ?? "UNKNOWN",
                statusCode: response?.statusCode,
                durationMilliseconds: max(
                    0,
                    Int(
                        (
                            ProcessInfo.processInfo.systemUptime
                                - startedAt
                        ) * 1_000
                    )
                ),
                requestID: requestID,
                outcome: outcome
            )
        )
    }

    private static func error(for status: Int, data: Data) -> ManagedStorageError {
        switch status {
        case 401:
            return .authentication
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 409:
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("policy") { return .policyChanged }
            if text.contains("quota") || text.contains("allowance") || text.contains("maximum_bytes") {
                return .quotaExceeded
            }
            return .conflict
        case 410:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"] as? [String: Any]
            return .cursorExpired(minimumSequence: (detail?["minimum_sequence"] as? NSNumber)?.int64Value)
        default:
            return .server(status: status)
        }
    }

    private static func crc32c(from hashHeader: String?) -> String? {
        hashHeader?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("crc32c=") }
            .map { String($0.dropFirst("crc32c=".count)) }
    }

    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? ""
    }

    private static func validate(_ profile: ManagedSocialProfile) throws {
        guard !profile.displayName.isEmpty,
              profile.displayName.count <= 64,
              ManagedSocialIdentifier.canonicalNOOPID(profile.noopID)
                == profile.noopID,
              (0...1439).contains(profile.quietStartMinute),
              (0...1439).contains(profile.quietEndMinute),
              !profile.timeZone.isEmpty,
              profile.timeZone.count <= 64,
              ManagedTimestamp.milliseconds(iso8601: profile.createdAt) != nil,
              ManagedTimestamp.milliseconds(iso8601: profile.updatedAt) != nil,
              profile.badges.count <= 3,
              profile.badges.allSatisfy(Self.valid) else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func validate(_ request: ManagedSocialRequest) throws {
        guard !request.displayName.isEmpty,
              request.displayName.count <= 64,
              ["incoming", "outgoing"].contains(request.direction),
              ["noop_id", "invite"].contains(request.source),
              ["pending", "accepted", "declined"].contains(request.status),
              ManagedTimestamp.milliseconds(iso8601: request.createdAt) != nil,
              request.decidedAt.map({
                  ManagedTimestamp.milliseconds(iso8601: $0) != nil
              }) ?? true,
              ManagedTimestamp.milliseconds(iso8601: request.expiresAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func validate(_ friend: ManagedSocialFriend) throws {
        guard !friend.displayName.isEmpty,
              friend.displayName.count <= 64,
              ManagedTimestamp.milliseconds(iso8601: friend.friendsSince) != nil,
              friend.badges.count <= 3,
              friend.badges.allSatisfy(Self.valid),
              friend.latest.map({
                  isDay($0.day) && valid($0.summary)
              }) ?? true else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func validate(_ blocked: ManagedSocialBlockedProfile) throws {
        guard !blocked.displayName.isEmpty,
              blocked.displayName.count <= 64,
              ManagedTimestamp.milliseconds(iso8601: blocked.blockedAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func valid(_ badge: ManagedSocialBadge) -> Bool {
        ["connected", "steady_week", "steady_month"].contains(badge.code)
            && ManagedTimestamp.milliseconds(iso8601: badge.earnedAt) != nil
    }

    private static func valid(_ summary: ManagedSocialSummary) -> Bool {
        [
            (summary.charge, 0.0...100.0),
            (summary.effort, 0.0...100.0),
            (summary.rest, 0.0...100.0),
            (summary.sleepDuration, 0.0...2_880.0),
            (summary.hrv, 0.0...1_000.0),
            (summary.rhr, 20.0...260.0),
        ].allSatisfy { value, range in
            value.map { $0.isFinite && range.contains($0) } ?? true
        }
    }

    private static func isDay(_ value: String) -> Bool {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }

    private static func validate(
        _ restore: ManagedRestoreJob,
        expectedStatus: String
    ) throws {
        guard restore.status == expectedStatus,
              ManagedTimestamp.milliseconds(iso8601: restore.snapshotAt) != nil,
              restore.changeSequence >= 0,
              restore.selectedObjects >= 0,
              restore.selectedBytes >= 0,
              restore.deliveredObjects >= 0,
              restore.deliveredBytes >= 0,
              restore.deliveredObjects <= restore.selectedObjects,
              restore.deliveredBytes <= restore.selectedBytes,
              ManagedTimestamp.milliseconds(iso8601: restore.expiresAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
    }
}
