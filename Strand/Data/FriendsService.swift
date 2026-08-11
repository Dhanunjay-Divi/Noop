import Foundation
import Combine
import Security
import NoopRemoteSync
import StrandAnalytics
import WhoopStore

/// App-facing state for invitation-only sharing through a server the user (or their circle) operates.
///
/// The social credential is separate from the self-hosted server administrator token. It is scoped to
/// one installation, kept in this-device-only Keychain storage, and can read only filtered friend
/// summaries. A social upload contains six allowlisted daily scalars and no streams, sleep timeline,
/// workouts, journal, location, identifiers, or exports.
@MainActor
final class FriendsService: ObservableObject {
    enum SetupState: Equatable {
        case needsServer
        case needsProfile
        case ready
    }

    struct Visibility: Equatable {
        var charge: Bool
        var effort: Bool
        var rest: Bool
        var sleepDuration: Bool
        var hrv: Bool
        var rhr: Bool

        init(
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

        init(_ remote: RemoteFriendVisibility) {
            self.init(
                charge: remote.charge,
                effort: remote.effort,
                rest: remote.rest,
                sleepDuration: remote.sleepDuration,
                hrv: remote.hrv,
                rhr: remote.rhr
            )
        }

        var patch: RemoteFriendVisibilityPatch {
            RemoteFriendVisibilityPatch(
                charge: charge,
                effort: effort,
                rest: rest,
                sleepDuration: sleepDuration,
                hrv: hrv,
                rhr: rhr
            )
        }

    }

    struct Summary: Equatable {
        let day: String
        let charge: Double?
        let effort: Double?
        let rest: Double?
        let sleepMinutes: Double?
        let hrv: Double?
        let rhr: Double?
    }

    struct Friend: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let friendsSince: String
        var sharing: Visibility
        let sharedWithMe: Visibility
        let latest: Summary?
    }

    struct Request: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let direction: RemoteFriendRequestDirection
        let createdAt: String

        var isIncoming: Bool { direction == .incoming }
    }

    struct Invite: Identifiable, Equatable {
        let id: UUID
        let code: String
        let expiresAt: String
        let serverAddress: String
    }

    @Published private(set) var setupState: SetupState
    @Published private(set) var profileName: String
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var requests: [Request] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published var errorMessage: String?

    private let demoMode: Bool
    private static let automaticIntervalMs = 15 * 60 * 1_000
    private static var automaticCatchUpRunning = false

    init() {
        #if DEBUG
        demoMode = CommandLine.arguments.contains("--demo-seed")
        #else
        demoMode = false
        #endif

        #if DEBUG
        if demoMode {
            setupState = .ready
            profileName = "You"
            friends = Self.demoFriends
            requests = [
                Request(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                    displayName: "Maya",
                    direction: .incoming,
                    createdAt: "2026-07-25T12:00:00Z"
                ),
            ]
            statusMessage = "Private demo circle"
            return
        }
        #endif

        if Self.memberContext != nil {
            setupState = .ready
            profileName = FriendsPreferences.displayName
        } else if Self.pendingEnrollment != nil {
            setupState = .needsServer
            profileName = FriendsPreferences.pendingDisplayName
            statusMessage = "Finish the invitation you started"
        } else if Self.canAdminBootstrap {
            setupState = .needsProfile
            profileName = ""
        } else {
            setupState = .needsServer
            profileName = ""
        }
    }

    var serverHost: String? {
        if let context = Self.memberContext { return context.endpoint.host }
        return URL(string: RemoteSyncPreferences.endpoint)?.host
    }

    var serverAddress: String? {
        if let context = Self.memberContext { return context.endpoint.absoluteString }
        if let pending = Self.pendingEnrollment { return pending.endpoint.absoluteString }
        let configured = RemoteSyncPreferences.endpoint
        return configured.isEmpty ? nil : configured
    }

    var memberCount: Int { friends.count + 1 }

    func dismissError() { errorMessage = nil }

    /// Best-effort foreground catch-up for invited members who do not have the server administrator
    /// credential. iOS does not guarantee background execution; opening the app or Friends is the
    /// reliable trigger.
    static func catchUpIfDue(repo: Repository) async {
        #if DEBUG
        guard !CommandLine.arguments.contains("--demo-seed") else { return }
        #endif
        guard memberContext != nil, !automaticCatchUpRunning else { return }
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        guard now - FriendsPreferences.lastAutomaticAttemptMs >= automaticIntervalMs else { return }
        automaticCatchUpRunning = true
        FriendsPreferences.lastAutomaticAttemptMs = now
        defer { automaticCatchUpRunning = false }
        let service = FriendsService()
        await service.refresh(repo: repo)
    }

    /// Create the server owner's first least-privilege member profile using the already configured
    /// administrator token. The administrator credential is never copied into social storage.
    func bootstrap(displayName: String, repo: Repository) async {
        guard !demoMode else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else {
            errorMessage = "Choose a display name between 1 and 64 characters."
            return
        }
        guard let adminToken = RemoteSyncKeyStore.read(),
              let rawEndpoint = URL(string: RemoteSyncPreferences.endpoint)
        else {
            setupState = .needsServer
            errorMessage = "Set up and test your self-hosted server in Backup & Sync first."
            return
        }

        await withBusy {
            do {
                let endpoint = try Self.validatedEndpoint(rawEndpoint)
                let dailyId = RemoteSyncService.socialDailyDeviceId(for: repo.deviceId)
                let client = RemoteSyncClient(
                    configuration: try RemoteSyncConfiguration(
                        baseURL: endpoint,
                        apiKey: adminToken,
                        timeout: 30
                    )
                )
                let response = try await client.bootstrapFriendProfile(
                    RemoteFriendProfileCreate(
                        displayName: name,
                        installationId: RemoteSyncPreferences.installationId,
                        dailyDeviceId: dailyId
                    )
                )
                try Self.persist(
                    profile: response.profile,
                    memberToken: response.memberToken,
                    endpoint: endpoint,
                    fallbackDailyDeviceId: dailyId
                )
                profileName = response.profile.displayName
                setupState = .ready
                statusMessage = "Private profile ready"
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    /// Join from a visible server address and one-time code. A first-time recipient creates their
    /// scoped profile atomically with the request; an existing member redeems with their member token.
    func join(_ invite: NavRouter.FriendInvite, displayName: String, repo: Repository) async {
        guard !demoMode else {
            statusMessage = "Invite request sent"
            return
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        await withBusy {
            do {
                let endpoint = try Self.validatedEndpoint(invite.serverURL)
                let dailyId = RemoteSyncService.socialDailyDeviceId(for: repo.deviceId)

                if let context = Self.memberContext {
                    guard Self.sameOrigin(context.endpoint, endpoint) else {
                        throw FriendsError.differentServer(
                            current: context.endpoint.host ?? context.endpoint.absoluteString,
                            invited: endpoint.host ?? endpoint.absoluteString
                        )
                    }
                    let client = try Self.client(for: context)
                    _ = try await client.redeemFriendInvite(
                        code: invite.code,
                        authorization: .member(token: context.token)
                    )
                } else {
                    guard (1...64).contains(name.count) else {
                        throw FriendsError.invalidDisplayName
                    }
                    // Save the client-generated credential before the one-time request. If a response
                    // is lost, the exact enrollment can be retried without orphaning the profile.
                    let enrollment = try Self.preparePendingEnrollment(
                        endpoint: endpoint,
                        dailyDeviceId: dailyId,
                        displayName: name
                    )
                    // RemoteSyncConfiguration needs a non-empty configured key even though the join
                    // request itself is deliberately unauthenticated. This sentinel never leaves memory
                    // or becomes a request header.
                    let client = RemoteSyncClient(
                        configuration: try RemoteSyncConfiguration(
                            baseURL: endpoint,
                            apiKey: "invite-capability",
                            timeout: 30
                        )
                    )
                    let response = try await client.joinFriendInvite(
                        RemoteFriendInviteJoin(
                            code: invite.code,
                            displayName: enrollment.displayName,
                            installationId: RemoteSyncPreferences.installationId,
                            dailyDeviceId: enrollment.dailyDeviceId,
                            enrollmentId: enrollment.enrollmentId,
                            memberToken: enrollment.token
                        )
                    )
                    try Self.persist(
                        profile: response.profile,
                        memberToken: enrollment.token,
                        endpoint: endpoint,
                        fallbackDailyDeviceId: enrollment.dailyDeviceId
                    )
                    profileName = response.profile.displayName
                    setupState = .ready
                }
                statusMessage = "Request sent. Sharing starts only after acceptance."
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    func invitation(
        serverAddress: String,
        code: String
    ) -> NavRouter.FriendInvite? {
        guard let invite = NavRouter.FriendInvite(
            serverAddress: serverAddress,
            code: code
        ) else {
            errorMessage = "Enter a valid server address and invite code."
            return nil
        }
        return invite
    }

    func redeem(code: String, repo: Repository) async {
        guard !demoMode else {
            statusMessage = "Invite request sent"
            return
        }
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let context = Self.memberContext, (12...32).contains(normalized.count) else {
            errorMessage = "Enter a valid invite code after creating your private profile."
            return
        }
        await withBusy {
            do {
                let client = try Self.client(for: context)
                _ = try await client.redeemFriendInvite(
                    code: normalized,
                    authorization: .member(token: context.token)
                )
                statusMessage = "Request sent. Sharing starts only after acceptance."
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    func refresh(repo: Repository) async {
        guard !demoMode, setupState == .ready else { return }
        await withBusy {
            await reload(repo: repo)
        }
    }

    func createInvite() async -> Invite? {
        if demoMode {
            return Invite(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                code: "NOOP-DEMO-CIRCLE",
                expiresAt: "2026-07-28T12:00:00Z",
                serverAddress: "https://noop.example"
            )
        }
        guard let context = Self.memberContext else {
            errorMessage = "Create your private profile before inviting a friend."
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let client = try Self.client(for: context)
            let response = try await client.createFriendInvite(
                authorization: .member(token: context.token)
            )
            return Invite(
                id: response.invite.inviteId,
                code: response.code,
                expiresAt: response.invite.expiresAt,
                serverAddress: context.endpoint.absoluteString
            )
        } catch {
            present(error)
            return nil
        }
    }

    func decide(_ request: Request, accept: Bool, repo: Repository) async {
        #if DEBUG
        guard !demoMode else {
            requests.removeAll { $0.id == request.id }
            if accept {
                friends.append(Self.demoAcceptedFriend)
                friends.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            }
            return
        }
        #endif
        guard let context = Self.memberContext else { return }
        await withBusy {
            do {
                let client = try Self.client(for: context)
                _ = try await client.decideFriendRequest(
                    request.id,
                    decision: accept ? .accept : .decline,
                    authorization: .member(token: context.token)
                )
                statusMessage = accept ? "\(request.displayName) joined your circle." : "Request declined."
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    func updatePrivacy(friendId: UUID, visibility: Visibility, repo: Repository) async {
        if demoMode {
            guard let index = friends.firstIndex(where: { $0.id == friendId }) else { return }
            friends[index].sharing = visibility
            statusMessage = "Sharing updated"
            return
        }
        guard let context = Self.memberContext else { return }
        await withBusy {
            do {
                let client = try Self.client(for: context)
                _ = try await client.updateFriendPrivacy(
                    friendId,
                    changes: visibility.patch,
                    authorization: .member(token: context.token)
                )
                statusMessage = "Sharing updated"
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    func remove(friendId: UUID, repo: Repository) async {
        if demoMode {
            friends.removeAll { $0.id == friendId }
            return
        }
        guard let context = Self.memberContext else { return }
        await withBusy {
            do {
                let client = try Self.client(for: context)
                try await client.removeFriend(
                    friendId,
                    authorization: .member(token: context.token)
                )
                statusMessage = "Friend removed. Sharing stopped immediately."
                await reload(repo: repo)
            } catch {
                present(error)
            }
        }
    }

    func leaveAndDeleteProfile() async {
        guard !demoMode else {
            statusMessage = "Demo profile kept"
            return
        }
        guard let context = Self.memberContext else { return }
        await withBusy {
            do {
                let client = try Self.client(for: context)
                try await client.deleteFriendProfile(
                    authorization: .member(token: context.token)
                )
                FriendsMemberKeyStore.clear()
                FriendsPreferences.clearProfile()
                friends = []
                requests = []
                profileName = ""
                setupState = Self.canAdminBootstrap ? .needsProfile : .needsServer
                statusMessage = "Circle profile and server summaries deleted. Local health data was kept."
            } catch {
                present(error)
            }
        }
    }

    // MARK: - Private loading and summary upload

    private func reload(repo: Repository) async {
        guard let context = Self.memberContext else {
            setupState = Self.canAdminBootstrap ? .needsProfile : .needsServer
            return
        }
        do {
            let client = try Self.client(for: context)
            let range = Self.feedRange()
            async let remoteFriends = client.friends(
                authorization: .member(token: context.token)
            )
            async let remoteRequests = client.friendRequests(
                authorization: .member(token: context.token)
            )
            let (friendResponse, requestResponse) =
                try await (remoteFriends, remoteRequests)

            // Send only the union of fields explicitly enabled for accepted friends. The upload
            // still runs when that union (or the friend list) becomes empty: its empty per-day maps
            // are replacement tombstones that remove values shared by an earlier privacy setting.
            // A pending-only profile therefore sends no biometric values, while removing the final
            // friend or disabling the final field reliably clears the dedicated social producer.
            let allowedFields = Self.unionOfSharedFields(friendResponse.friends)
            do {
                try await uploadDailySummary(
                    repo: repo,
                    context: context,
                    allowedFields: allowedFields
                )
            } catch {
                statusMessage = "Friends loaded; your latest allowed summary could not be uploaded."
            }

            let feedResponse = try await client.friendFeed(
                startDay: range.start,
                endDay: range.end,
                authorization: .member(token: context.token)
            )

            let latestByFriend = Dictionary(
                grouping: feedResponse.days,
                by: \.profileId
            ).compactMapValues { rows in rows.max { $0.day < $1.day } }

            friends = friendResponse.friends.map { remote in
                let latest = latestByFriend[remote.profileId].map {
                    Summary(
                        day: $0.day,
                        charge: $0.summary.charge,
                        effort: $0.summary.effort,
                        rest: $0.summary.rest,
                        sleepMinutes: $0.summary.sleepDuration,
                        hrv: $0.summary.hrv,
                        rhr: $0.summary.rhr
                    )
                }
                return Friend(
                    id: remote.profileId,
                    displayName: remote.displayName,
                    friendsSince: remote.friendsSince,
                    sharing: Visibility(remote.sharing),
                    sharedWithMe: Visibility(remote.sharedWithMe),
                    latest: latest
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            requests = requestResponse.requests.compactMap { remote in
                guard remote.status == .pending,
                      let direction = remote.direction,
                      let identity = remote.profile else { return nil }
                return Request(
                    id: remote.requestId,
                    displayName: identity.displayName,
                    direction: direction,
                    createdAt: remote.createdAt
                )
            }
            .sorted { $0.createdAt > $1.createdAt }

            setupState = .ready
            if statusMessage.isEmpty {
                statusMessage = "Shared from \(context.endpoint.host ?? "your server")"
            }
        } catch {
            present(error)
        }
    }

    private func uploadDailySummary(
        repo: Repository,
        context: MemberContext,
        allowedFields: Visibility
    ) async throws {
        let catchUpDays = FriendsSummaryReplacement.days(daysBack: 30)
        guard let firstDay = catchUpDays.first,
              let lastDay = catchUpDays.last else { return }
        let range = (start: firstDay, end: lastDay)
        guard let store = await repo.storeHandle() else { throw FriendsError.storeUnavailable }
        let localId = repo.deviceId + "-noop"
        async let dailyRead = store.dailyMetrics(
            deviceId: localId,
            from: range.start,
            to: range.end
        )
        async let restRead = store.metricSeries(
            deviceId: localId,
            key: "sleep_performance",
            from: range.start,
            to: range.end
        )
        let (dailyRows, restRows) = try await (dailyRead, restRead)

        // Every day is present even when it has no selected/local values. The Friends backend treats
        // each supplied day as a full six-key replacement for this dedicated producer, so `{}` is
        // the privacy-preserving clear operation for values uploaded under an older allowlist.
        var payload = Dictionary(
            uniqueKeysWithValues: catchUpDays.map { ($0, [String: Double]()) }
        )
        for row in dailyRows {
            var values: [String: Double] = [:]
            if allowedFields.charge {
                Self.add(row.recovery, key: "recovery", range: 0...100, to: &values)
            }
            if allowedFields.effort {
                Self.add(row.strain, key: "effort", range: 0...100, to: &values)
            }
            if allowedFields.sleepDuration {
                Self.add(row.totalSleepMin, key: "total_sleep_min", range: 0...1_440, to: &values)
            }
            if allowedFields.hrv {
                Self.add(row.avgHrv, key: "avg_hrv", range: 0...500, to: &values)
            }
            if allowedFields.rhr {
                Self.add(
                    row.restingHr.map(Double.init),
                    key: "resting_hr",
                    range: 20...250,
                    to: &values
                )
            }
            payload[row.day] = values
        }
        if allowedFields.rest {
            for point in restRows where point.value.isFinite && (0...100).contains(point.value) {
                payload[point.day, default: [:]]["sleep_performance"] = point.value
            }
        }
        let source = RemoteSyncSource(
            deviceId: context.dailyDeviceId,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            platform: Self.platform,
            metadata: [
                "installation_id": RemoteSyncPreferences.installationId,
                "logical_source_id": repo.deviceId + "-noop-friends",
                "namespace": "noop_computed",
                "paired_device_id": repo.deviceId,
                "privacy": "explicit_opt_in",
                "score_provenance": "noop_transparent_algorithm",
                "algorithm_revision": [
                    NoopScoreAlgorithmRevision.charge,
                    NoopScoreAlgorithmRevision.effort,
                    NoopScoreAlgorithmRevision.rest,
                ].joined(separator: "+"),
            ]
        )
        let client = try Self.client(for: context)
        _ = try await client.upload(
            RemoteSyncEnvelope(source: source, dailyMetrics: payload)
        )
    }

    // MARK: - Configuration

    private struct MemberContext {
        let endpoint: URL
        let token: String
        let dailyDeviceId: String
    }

    private struct PendingEnrollment {
        let endpoint: URL
        let enrollmentId: UUID
        let token: String
        let dailyDeviceId: String
        let displayName: String
    }

    private static var memberContext: MemberContext? {
        guard let token = FriendsMemberKeyStore.read(),
              let endpoint = URL(string: FriendsPreferences.endpoint),
              !FriendsPreferences.profileId.isEmpty,
              !FriendsPreferences.dailyDeviceId.isEmpty else { return nil }
        return MemberContext(
            endpoint: endpoint,
            token: token,
            dailyDeviceId: FriendsPreferences.dailyDeviceId
        )
    }

    private static var pendingEnrollment: PendingEnrollment? {
        guard let token = FriendsMemberKeyStore.read(),
              let endpoint = URL(string: FriendsPreferences.pendingEndpoint),
              let enrollmentId = UUID(uuidString: FriendsPreferences.pendingEnrollmentId),
              !FriendsPreferences.pendingDailyDeviceId.isEmpty,
              !FriendsPreferences.pendingDisplayName.isEmpty else { return nil }
        return PendingEnrollment(
            endpoint: endpoint,
            enrollmentId: enrollmentId,
            token: token,
            dailyDeviceId: FriendsPreferences.pendingDailyDeviceId,
            displayName: FriendsPreferences.pendingDisplayName
        )
    }

    private static func preparePendingEnrollment(
        endpoint: URL,
        dailyDeviceId: String,
        displayName: String
    ) throws -> PendingEnrollment {
        if let pending = pendingEnrollment {
            guard sameOrigin(pending.endpoint, endpoint) else {
                throw FriendsError.pendingDifferentServer(
                    current: pending.endpoint.absoluteString,
                    invited: endpoint.absoluteString
                )
            }
            guard pending.dailyDeviceId == dailyDeviceId else {
                throw FriendsError.pendingDifferentDevice
            }
            return pending
        }

        let enrollmentId = UUID()
        let token = try newMemberToken()
        guard FriendsMemberKeyStore.save(token) else {
            throw FriendsError.keychainWrite
        }
        FriendsPreferences.pendingEndpoint = endpoint.absoluteString
        FriendsPreferences.pendingEnrollmentId = enrollmentId.uuidString.lowercased()
        FriendsPreferences.pendingDailyDeviceId = dailyDeviceId
        FriendsPreferences.pendingDisplayName = displayName
        return PendingEnrollment(
            endpoint: endpoint,
            enrollmentId: enrollmentId,
            token: token,
            dailyDeviceId: dailyDeviceId,
            displayName: displayName
        )
    }

    private static func newMemberToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FriendsError.randomCredential
        }
        let encoded = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "noop_member_\(encoded)"
    }

    private static var canAdminBootstrap: Bool {
        !RemoteSyncPreferences.endpoint.isEmpty && RemoteSyncKeyStore.hasKey
    }

    private static func persist(
        profile: RemoteFriendProfile,
        memberToken: String,
        endpoint: URL,
        fallbackDailyDeviceId: String
    ) throws {
        if FriendsMemberKeyStore.read() != memberToken,
           !FriendsMemberKeyStore.save(memberToken) {
            throw FriendsError.keychainWrite
        }
        FriendsPreferences.endpoint = endpoint.absoluteString
        FriendsPreferences.profileId = profile.profileId.uuidString.lowercased()
        FriendsPreferences.enrollmentId = profile.enrollmentId.uuidString.lowercased()
        FriendsPreferences.displayName = profile.displayName
        FriendsPreferences.dailyDeviceId = profile.dailyDeviceId ?? fallbackDailyDeviceId
        FriendsPreferences.clearPendingEnrollment()
    }

    private static func client(for context: MemberContext) throws -> RemoteSyncClient {
        RemoteSyncClient(
            configuration: try RemoteSyncConfiguration(
                baseURL: context.endpoint,
                apiKey: context.token,
                timeout: 30
            )
        )
    }

    private static func validatedEndpoint(_ url: URL) throws -> URL {
        let normalized = try RemoteSyncService.normalizedEndpoint(url.absoluteString)
        guard let result = URL(string: normalized) else { throw FriendsError.invalidServer }
        return result
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return "\(scheme)://\(host):\(port)"
        }
        return origin(lhs) == origin(rhs)
    }

    private static func feedRange(daysBack: Int = 14) -> (start: String, end: String) {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -daysBack, to: endDate) ?? endDate
        return (dayString(startDate), dayString(endDate))
    }

    private static func unionOfSharedFields(
        _ friends: [RemoteFriend]
    ) -> Visibility {
        Visibility(
            charge: friends.contains { $0.sharing.charge },
            effort: friends.contains { $0.sharing.effort },
            rest: friends.contains { $0.sharing.rest },
            sleepDuration: friends.contains { $0.sharing.sleepDuration },
            hrv: friends.contains { $0.sharing.hrv },
            rhr: friends.contains { $0.sharing.rhr }
        )
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static func add(
        _ value: Double?,
        key: String,
        range: ClosedRange<Double>,
        to values: inout [String: Double]
    ) {
        guard let value, value.isFinite, range.contains(value) else { return }
        values[key] = value
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    private func withBusy(_ operation: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        await operation()
        isBusy = false
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

/// Builds the bounded set of local calendar days whose Friends summary is replaced on each upload.
///
/// Keeping this pure makes the privacy contraction contract directly testable: every day in the
/// catch-up window must survive JSON encoding even when its replacement map is empty.
enum FriendsSummaryReplacement {
    static func days(
        daysBack: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        guard daysBack >= 0 else { return [] }
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -daysBack, to: end) else {
            return []
        }
        return (0...daysBack).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map {
                dayString($0, calendar: calendar)
            }
        }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }
}

private enum FriendsPreferences {
    private static var defaults: UserDefaults { .standard }
    private static let prefix = "friends."

    static var endpoint: String {
        get { defaults.string(forKey: prefix + "endpoint") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "endpoint") }
    }
    static var profileId: String {
        get { defaults.string(forKey: prefix + "profileId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "profileId") }
    }
    static var enrollmentId: String {
        get { defaults.string(forKey: prefix + "enrollmentId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "enrollmentId") }
    }
    static var displayName: String {
        get { defaults.string(forKey: prefix + "displayName") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "displayName") }
    }
    static var dailyDeviceId: String {
        get { defaults.string(forKey: prefix + "dailyDeviceId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "dailyDeviceId") }
    }
    static var pendingEndpoint: String {
        get { defaults.string(forKey: prefix + "pendingEndpoint") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingEndpoint") }
    }
    static var pendingEnrollmentId: String {
        get { defaults.string(forKey: prefix + "pendingEnrollmentId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingEnrollmentId") }
    }
    static var pendingDailyDeviceId: String {
        get { defaults.string(forKey: prefix + "pendingDailyDeviceId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingDailyDeviceId") }
    }
    static var pendingDisplayName: String {
        get { defaults.string(forKey: prefix + "pendingDisplayName") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingDisplayName") }
    }

    static func clearPendingEnrollment() {
        defaults.removeObject(forKey: prefix + "pendingEndpoint")
        defaults.removeObject(forKey: prefix + "pendingEnrollmentId")
        defaults.removeObject(forKey: prefix + "pendingDailyDeviceId")
        defaults.removeObject(forKey: prefix + "pendingDisplayName")
    }

    static func clearProfile() {
        defaults.removeObject(forKey: prefix + "endpoint")
        defaults.removeObject(forKey: prefix + "profileId")
        defaults.removeObject(forKey: prefix + "enrollmentId")
        defaults.removeObject(forKey: prefix + "displayName")
        defaults.removeObject(forKey: prefix + "dailyDeviceId")
        defaults.removeObject(forKey: prefix + "lastAutomaticAttemptMs")
        clearPendingEnrollment()
    }
    static var lastAutomaticAttemptMs: Int {
        get { defaults.integer(forKey: prefix + "lastAutomaticAttemptMs") }
        set { defaults.set(newValue, forKey: prefix + "lastAutomaticAttemptMs") }
    }
}

/// Least-privilege member credential. This is intentionally not the self-hosted administrator key.
private enum FriendsMemberKeyStore {
    private static let service = "com.noop.friends"
    private static let account = "member-token"
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

private enum FriendsError: LocalizedError {
    case invalidDisplayName
    case invalidServer
    case keychainWrite
    case randomCredential
    case storeUnavailable
    case differentServer(current: String, invited: String)
    case pendingDifferentServer(current: String, invited: String)
    case pendingDifferentDevice

    var errorDescription: String? {
        switch self {
        case .invalidDisplayName:
            return "Choose a display name between 1 and 64 characters."
        case .invalidServer:
            return "This invite does not contain a valid HTTPS or private-network server."
        case .keychainWrite:
            return "The private member credential could not be saved in Keychain."
        case .randomCredential:
            return "Noop could not generate a private member credential."
        case .storeUnavailable:
            return "Noop could not open the local data store."
        case .differentServer(let current, let invited):
            return "This device already belongs to \(current). The invite is for \(invited), so Noop did not switch servers."
        case .pendingDifferentServer(let current, let invited):
            return "An unfinished invitation is saved for \(current). Finish that request before joining \(invited)."
        case .pendingDifferentDevice:
            return "This unfinished invitation is bound to a different local device. Reopen it with the same band selected."
        }
    }
}

#if DEBUG
private extension FriendsService {
    static let demoFriends: [Friend] = [
        Friend(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Alex",
            friendsSince: "2026-05-10T12:00:00Z",
            sharing: Visibility(),
            sharedWithMe: Visibility(),
            latest: Summary(
                day: "2026-07-25", charge: 82, effort: 46, rest: 91,
                sleepMinutes: nil, hrv: nil, rhr: nil
            )
        ),
        Friend(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "Jordan",
            friendsSince: "2026-06-02T12:00:00Z",
            sharing: Visibility(),
            sharedWithMe: Visibility(),
            latest: Summary(
                day: "2026-07-25", charge: 64, effort: 73, rest: 76,
                sleepMinutes: nil, hrv: nil, rhr: nil
            )
        ),
        Friend(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            displayName: "Sam",
            friendsSince: "2026-06-18T12:00:00Z",
            sharing: Visibility(),
            sharedWithMe: Visibility(),
            latest: Summary(
                day: "2026-07-24", charge: 75, effort: 38, rest: 84,
                sleepMinutes: nil, hrv: nil, rhr: nil
            )
        ),
    ]

    static let demoAcceptedFriend = Friend(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        displayName: "Maya",
        friendsSince: "2026-07-25T12:00:00Z",
        sharing: Visibility(),
        sharedWithMe: Visibility(),
        latest: nil
    )
}
#endif
