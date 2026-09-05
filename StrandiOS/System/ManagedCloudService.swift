#if os(iOS)
import Combine
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import NoopRemoteSync
import Security
import UserNotifications
import WhoopStore

@MainActor
final class ManagedCloudService: ObservableObject {
    enum Phase: Equatable {
        case unavailable
        case signedOut
        case codeSent
        case consentRequired
        case enrolled
        case deletionScheduled
    }

    struct SyncSummary: Equatable {
        let uploadedChunks: Int
        let uploadedBytes: Int
        let uploadedDocuments: Int
        let appliedChanges: Int
        let hasMore: Bool
        let prunedWindows: Int
        let prunedRows: Int
    }

    static let shared = ManagedCloudService()

    @Published private(set) var phase: Phase = .unavailable
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var deletionNotBefore: String?
    @Published private(set) var overview: ManagedStorageOverview?
    @Published private(set) var installations: [ManagedInstallation] = []
    @Published private(set) var socialProfile: ManagedSocialProfile?
    @Published private(set) var socialFriends: [ManagedSocialFriend] = []
    @Published private(set) var socialBlockedProfiles: [ManagedSocialBlockedProfile] = []
    @Published private(set) var socialRequests: [ManagedSocialRequest] = []
    @Published private(set) var socialFeed: [ManagedSocialFeedDay] = []
    @Published private(set) var socialLookup: ManagedSocialLookupProfile?
    @Published private(set) var socialInvite: ManagedSocialInvite?
    @Published private(set) var socialStatus = ""
    @Published private(set) var pendingSocialInviteCapability: String?
    @Published private(set) var pendingSocialNOOPID: String?

    var isAvailable: Bool { configuration != nil }
    var isEnrolled: Bool {
        phase == .enrolled || phase == .deletionScheduled
    }
    var automatic: Bool {
        get { defaults.bool(forKey: Key.automatic) }
        set {
            defaults.set(newValue && phase == .enrolled, forKey: Key.automatic)
            objectWillChange.send()
        }
    }
    var optimizePhoneStorage: Bool {
        get { defaults.bool(forKey: Key.optimizePhoneStorage) }
        set {
            defaults.set(
                newValue && phase == .enrolled,
                forKey: Key.optimizePhoneStorage
            )
            objectWillChange.send()
        }
    }
    var maskedPhoneNumber: String {
        Self.maskedPhone(Auth.auth().currentUser?.phoneNumber)
    }

    private enum Key {
        static let enrolledScopeHash = "managedCloud.enrolledScopeHash.v1"
        static let enrolledPolicy = "managedCloud.enrolledPolicy.v1"
        static let automatic = "managedCloud.automatic.v1"
        static let optimizePhoneStorage = "managedCloud.optimizePhoneStorage.v1"
        static let lastAttempt = "managedCloud.lastAttempt.v1"
        static let lastSuccess = "managedCloud.lastSuccess.v1"
        static let lastStatus = "managedCloud.lastStatus.v1"
        static let continuationPending = "managedCloud.continuationPending.v1"
        static let enrollmentRequestID = "managedCloud.enrollmentRequestID.v1"
        static let erasureJobID = "managedCloud.erasureJobID.v1"
        static let erasureNotBefore = "managedCloud.erasureNotBefore.v1"
        static let socialProfileRequestID = "managedCloud.social.profileRequestID.v1"
        static let socialInviteRequestID = "managedCloud.social.inviteRequestID.v1"
        static let socialSummaryDigests = "managedCloud.social.summaryDigests.v1"
        static let socialSummaryScope = "managedCloud.social.summaryScope.v1"
        static let socialLastAttempt = "managedCloud.social.lastAttempt.v1"
        static let socialDeliveryReceipts = "managedCloud.social.deliveryReceipts.v1"
        static let socialEnabled = "managedCloud.social.enabled.v1"
        static let socialPendingNOOPID = "managedCloud.social.pendingNoopID.v1"
    }

    private static let automaticInterval: TimeInterval = 15 * 60
    private static let socialAutomaticInterval: TimeInterval = 5 * 60
    private static let enrollmentDataClasses = ManagedSyncCoordinator.chunkDataClasses
    private static let accountDeletionConfirmation = Data(
        "delete-noop-plus-managed-account-v1".utf8
    )

    private let defaults = UserDefaults.standard
    private let configuration: ManagedStorageConfiguration?
    private var firebaseConfigured = false
    private var verificationID: String?
    private var deletionVerificationID: String?
    private var running = false
    private var socialRunning = false
    private var socialPokeHaptic: (() -> Bool)?

    private init(bundle: Bundle = .main) {
        configuration = Self.loadConfiguration(bundle: bundle)
        status = defaults.string(forKey: Key.lastStatus) ?? ""
        let success = defaults.double(forKey: Key.lastSuccess)
        lastSuccessAt = success > 0 ? Date(timeIntervalSince1970: success) : nil
        deletionNotBefore = defaults.string(forKey: Key.erasureNotBefore)
        pendingSocialInviteCapability =
            ManagedCloudPendingSocialInviteSecret.value()
        pendingSocialNOOPID = defaults.string(
            forKey: Key.socialPendingNOOPID
        ).flatMap(ManagedSocialIdentifier.canonicalNOOPID)
        phase = configuration == nil ? .unavailable : .signedOut
    }

    func bootstrap() {
        guard configuration != nil else {
            phase = .unavailable
            return
        }
        do {
            try configureFirebaseIfNeeded()
            if deletionDeadlineHasPassed() {
                completeLocalDeletionHandoff()
                return
            }
            reconcileAuthenticatedState()
        } catch {
            phase = .unavailable
            setStatus(Self.userMessage(for: error))
        }
    }

    func sendCode(to rawPhoneNumber: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_auth.send_code"
        )
        do {
            try configureFirebaseIfNeeded()
            let phone = try Self.normalizedPhone(rawPhoneNumber)
            try Self.configureDebugPhoneVerification(for: phone)
            verificationID = try await PhoneAuthProvider.provider(auth: Auth.auth())
                .verifyPhoneNumber(phone, uiDelegate: nil)
            phase = .codeSent
            setStatus(String(localized: "A verification code was sent."))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            setStatus(Self.userMessage(for: error))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOperationOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ]
            )
        }
    }

    func verifyCode(_ rawCode: String) async {
        guard !isBusy else { return }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_auth.verify_code"
        )
        guard let verificationID else {
            setStatus(String(localized: "Request a new verification code."))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "rejected",
                fields: ["failure_kind": "verification_state"]
            )
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let code = try Self.normalizedCode(rawCode)
            let credential = PhoneAuthProvider.provider(auth: Auth.auth()).credential(
                withVerificationID: verificationID,
                verificationCode: code
            )
            _ = try await Auth.auth().signIn(with: credential)
            self.verificationID = nil
            reconcileAuthenticatedState()
            if phase == .consentRequired {
                setStatus(
                    String(localized:
                        "Phone verified. Review what NOOP+ will store before allowing upload."
                    )
                )
            } else {
                setStatus(String(localized: "Signed in to NOOP+."))
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            setStatus(Self.userMessage(for: error))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOperationOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ]
            )
        }
    }

    func enroll(repo: Repository) async {
        guard !isBusy, configuration != nil else { return }
        isBusy = true
        defer { isBusy = false }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_enrollment"
        )
        do {
            let client = try client()
            let authorization = try await authorization(forceRefresh: true)
            let response = try await client.enroll(
                platform: .iOS,
                dataClasses: Self.enrollmentDataClasses,
                authorization: authorization,
                requestID: enrollmentRequestID()
            )
            guard response.productBoundary.accountOptional,
                  response.productBoundary.localMetricsAvailable,
                  response.productBoundary.storageOnlyEntitlement else {
                throw ManagedStorageError.invalidResponse
            }
            let scope = try accountScopeHash()
            defaults.set(scope, forKey: Key.enrolledScopeHash)
            defaults.set(configuration?.policyVersion, forKey: Key.enrolledPolicy)
            defaults.set(true, forKey: Key.automatic)
            defaults.removeObject(forKey: Key.enrollmentRequestID)
            phase = .enrolled
            setStatus(
                String(localized:
                    "NOOP+ cloud backup is on. Your local NOOP features remain account-free."
                )
            )
            let summary = try await sync(repo: repo, mode: .manual)
            scheduleContinuationIfNeeded(summary)
            try await refreshOverviewData()
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if Auth.auth().currentUser != nil {
                phase = .consentRequired
            }
            setStatus(Self.userMessage(for: error))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOperationOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ],
                includeResourceSnapshot: true
            )
        }
    }

    func syncNow(repo: Repository) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let summary = try await sync(repo: repo, mode: .manual)
            scheduleContinuationIfNeeded(summary)
            try await refreshOverviewData()
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func exportCompleteCloudHistory(repo: Repository) async -> URL? {
        guard !isBusy, phase == .enrolled else { return nil }
        isBusy = true
        defer { isBusy = false }
        var writer: ManagedHistoryArchiveWriter?
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation("managed_export")
        do {
            for pass in 1...Self.maximumExportPreparationPasses {
                try Task.checkCancellation()
                setStatus(
                    String(localized:
                        "Preparing current phone data for export (pass \(pass))…"
                    )
                )
                let summary = try await sync(
                    repo: repo,
                    mode: .exportPreparation
                )
                if !summary.hasMore { break }
                guard pass < Self.maximumExportPreparationPasses else {
                    throw ManagedCloudError.exportPreparationIncomplete
                }
                await Task.yield()
            }

            let archiveWriter = try ManagedHistoryArchiveWriter(
                destinationURL: Self.managedHistoryExportURL()
            )
            writer = archiveWriter
            let exporter = ManagedHistoryExporter(transport: try client())
            let manifest = try await exporter.export(
                authorization: { [self] forceRefresh in
                    try await authorization(forceRefresh: forceRefresh)
                },
                progress: { [weak self] value in
                    await self?.setExportStatus(value)
                },
                consume: { entry in
                    try await archiveWriter.add(entry)
                }
            )
            let url = try await archiveWriter.finalize(manifest: manifest)
            writer = nil
            setStatus(
                String(localized:
                    "Complete cloud history is ready. Choose where to save the sensitive archive."
                )
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: [
                    "objects": String(manifest.exportedObjects),
                    "chunk_bytes": String(manifest.exportedChunkBytes),
                ],
                includeResourceSnapshot: true
            )
            return url
        } catch is CancellationError {
            if let writer { await writer.cancel() }
            setStatus(String(localized: "Cloud-history export was canceled."))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "canceled",
                includeResourceSnapshot: true
            )
            return nil
        } catch {
            if let writer { await writer.cancel() }
            setStatus(Self.userMessage(for: error))
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "failed",
                fields: [
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ],
                includeResourceSnapshot: true
            )
            return nil
        }
    }

    func refreshOverview() async {
        guard !isBusy, phase == .enrolled else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await refreshOverviewData()
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func revokeInstallation(_ installationID: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let revoked = try await client().revokeInstallation(
                installationID,
                authorization: try await authorization(forceRefresh: true)
            )
            installations = installations.map {
                $0.installationID == revoked.installationID ? revoked : $0
            }
            setStatus(String(localized: "The selected NOOP+ device was revoked."))
            try await refreshOverviewData()
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    // MARK: - Managed Friends

    func configureSocialPokeHaptic(_ action: @escaping () -> Bool) {
        socialPokeHaptic = action
    }

    @discardableResult
    func stageSocialProfileLink(_ url: URL) -> Bool {
        guard let noopID = ManagedSocialIdentifier.profileNOOPID(from: url) else {
            return false
        }
        defaults.set(noopID, forKey: Key.socialPendingNOOPID)
        pendingSocialNOOPID = noopID
        AppDiagnosticsRecorder.shared.record(
            "managed_social.profile_link_staged",
            fields: [
                "outcome": "accepted",
                "persistence": "preferences",
            ]
        )
        return true
    }

    func clearPendingSocialProfileLink() {
        defaults.removeObject(forKey: Key.socialPendingNOOPID)
        pendingSocialNOOPID = nil
    }

    func clearPendingSocialInvite() {
        ManagedCloudPendingSocialInviteSecret.clear()
        pendingSocialInviteCapability = nil
    }

    @discardableResult
    func stageSocialInviteLink(_ url: URL) -> Bool {
        guard let capability = ManagedSocialIdentifier.inviteCapability(
            from: url
        ),
        ManagedCloudPendingSocialInviteSecret.store(capability) else {
            return false
        }
        pendingSocialInviteCapability = capability
        AppDiagnosticsRecorder.shared.record(
            "managed_social.invite_link_staged",
            fields: [
                "outcome": "accepted",
                "persistence": "keychain",
            ]
        )
        return true
    }

    func socialProfileURL(_ profile: ManagedSocialProfile) -> URL? {
        ManagedSocialIdentifier.profileURL(noopID: profile.noopID)
    }

    func socialInviteURL(_ invite: ManagedSocialInvite) -> URL? {
        guard invite.status == "active" else { return nil }
        return ManagedSocialIdentifier.inviteURL(
            capability: invite.capability
        )
    }

    func createSocialProfile(displayName: String, repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("profile_create") {
            let profile = try await client().createSocialProfile(
                displayName: displayName,
                requestID: socialRequestID(for: Key.socialProfileRequestID),
                authorization: try await authorization(forceRefresh: true)
            )
            defaults.removeObject(forKey: Key.socialProfileRequestID)
            defaults.set(true, forKey: Key.socialEnabled)
            socialProfile = profile
            socialStatus = String(
                localized: "Your private NOOP ID is ready. Nothing is shared until you accept a friend and choose details."
            )
            try await refreshSocialData(repo: repo, deliverPokes: true)
        }
    }

    func refreshSocial(repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("refresh") {
            try await refreshSocialData(repo: repo, deliverPokes: true)
        }
    }

    func updateSocialProfile(
        displayName: String? = nil,
        pokeOptIn: Bool? = nil,
        quietStartMinute: Int? = nil,
        quietEndMinute: Int? = nil,
        repo: Repository
    ) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("profile_update") {
            if pokeOptIn == true {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
            let patch = ManagedSocialProfilePatch(
                displayName: displayName,
                pokeOptIn: pokeOptIn,
                quietStartMinute: quietStartMinute,
                quietEndMinute: quietEndMinute,
                timeZone: TimeZone.current.identifier
            )
            socialProfile = try await client().updateSocialProfile(
                patch,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = pokeOptIn == true
                ? String(localized: "Pokes are on. Quiet hours and each friend's permission still apply.")
                : String(localized: "NOOP Friends settings updated.")
            try await refreshSocialData(repo: repo, deliverPokes: true)
        }
    }

    func rotateSocialNOOPID(repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("noop_id_rotate") {
            socialProfile = try await client().rotateSocialNOOPID(
                authorization: try await authorization(forceRefresh: true)
            )
            socialLookup = nil
            socialStatus = String(
                localized: "Your old NOOP ID no longer accepts new requests."
            )
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func lookupSocialProfile(noopID: String) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("lookup") {
            socialLookup = try await client().lookupSocialProfile(
                noopID: noopID,
                authorization: try await authorization(forceRefresh: false)
            )
            socialStatus = socialLookup?.isSelf == true
                ? String(localized: "That is your own NOOP ID.")
                : String(localized: "Exact NOOP ID found. Sending a request still requires confirmation.")
        }
    }

    func clearSocialLookup() {
        socialLookup = nil
    }

    func sendSocialRequest(noopID: String, repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("request_create") {
            _ = try await client().createSocialRequest(
                noopID: noopID,
                requestID: UUID(),
                authorization: try await authorization(forceRefresh: true)
            )
            socialLookup = nil
            socialStatus = String(
                localized: "Friend request sent. Sharing starts only after acceptance."
            )
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func createSocialInvite() async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("invite_create") {
            let scope = try accountScopeHash()
            let managedClient = try client()
            let auth = try await authorization(forceRefresh: true)
            var capability = try ManagedCloudSocialInviteSecret.value(
                accountScopeHash: scope
            )
            var invite = try await managedClient.createSocialInvite(
                capability: capability,
                requestID: socialRequestID(for: Key.socialInviteRequestID),
                authorization: auth
            )
            if invite.status != "active" {
                try ManagedCloudSocialInviteSecret.clear(
                    accountScopeHash: scope
                )
                defaults.removeObject(forKey: Key.socialInviteRequestID)
                capability = try ManagedCloudSocialInviteSecret.value(
                    accountScopeHash: scope
                )
                invite = try await managedClient.createSocialInvite(
                    capability: capability,
                    requestID: socialRequestID(
                        for: Key.socialInviteRequestID
                    ),
                    authorization: auth
                )
            }
            guard invite.status == "active" else {
                throw ManagedStorageError.invalidResponse
            }
            socialInvite = invite
            socialStatus = String(
                localized: "Invitation ready. It expires within 72 hours and creates a request, not an automatic friendship."
            )
        }
    }

    func revokeSocialInvite() async {
        guard beginSocialAction(), let invite = socialInvite else { return }
        defer { endSocialAction() }
        await runSocialOperation("invite_revoke") {
            try await client().revokeSocialInvite(
                invite.inviteID,
                authorization: try await authorization(forceRefresh: true)
            )
            try? ManagedCloudSocialInviteSecret.clear(
                accountScopeHash: accountScopeHash()
            )
            defaults.removeObject(forKey: Key.socialInviteRequestID)
            socialInvite = nil
            socialStatus = String(localized: "Invitation revoked.")
        }
    }

    func redeemPendingSocialInvite(repo: Repository) async {
        guard beginSocialAction(),
              let capability = pendingSocialInviteCapability else { return }
        defer { endSocialAction() }
        await runSocialOperation("invite_redeem") {
            let requestID = ManagedStableIdentifier.uuid(
                seed: Data(
                    "noop-managed-social-redeem-v1\0\(try accountScopeHash())\0\(capability)"
                        .utf8
                )
            )
            _ = try await client().redeemSocialInvite(
                capability: capability,
                requestID: requestID,
                authorization: try await authorization(forceRefresh: true)
            )
            clearPendingSocialInvite()
            socialStatus = String(
                localized: "Friend request sent from the invitation. Sharing starts only after acceptance."
            )
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func decideSocialRequest(
        _ requestID: UUID,
        accept: Bool,
        repo: Repository
    ) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("request_decide") {
            _ = try await client().decideSocialRequest(
                requestID,
                accept: accept,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = accept
                ? String(localized: "Friend accepted. Choose exactly what they can see.")
                : String(localized: "Friend request declined.")
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func updateSocialVisibility(
        friendProfileID: UUID,
        patch: ManagedSocialVisibilityPatch,
        repo: Repository
    ) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("privacy_update") {
            _ = try await client().updateSocialVisibility(
                friendProfileID: friendProfileID,
                patch: patch,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = String(localized: "Sharing choices updated.")
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func removeSocialFriend(_ profileID: UUID, repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("friend_remove") {
            try await client().removeSocialFriend(
                profileID,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = String(localized: "Friend removed. Sharing stopped in both directions.")
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func blockSocialProfile(_ profileID: UUID, repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("profile_block") {
            try await client().blockSocialProfile(
                profileID,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = String(
                localized: "Profile blocked. Requests, sharing, and pending pokes were removed."
            )
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func unblockSocialProfile(_ profileID: UUID, repo: Repository) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("profile_unblock") {
            try await client().unblockSocialProfile(
                profileID,
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = String(
                localized: "Profile unblocked. A new friend request is still required."
            )
            try await refreshSocialData(repo: repo, deliverPokes: false)
        }
    }

    func deleteSocialProfile() async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("profile_delete") {
            try await client().deleteSocialProfile(
                authorization: try await authorization(forceRefresh: true)
            )
            clearSocialState()
            socialStatus = String(
                localized: "Managed Friends was deleted. NOOP+ backup and on-device data are unchanged."
            )
        }
    }

    func sendSocialPoke(to profileID: UUID) async {
        guard beginSocialAction() else { return }
        defer { endSocialAction() }
        await runSocialOperation("poke_send") {
            _ = try await client().createSocialPoke(
                recipientProfileID: profileID,
                requestID: UUID(),
                authorization: try await authorization(forceRefresh: true)
            )
            socialStatus = String(localized: "Poke queued.")
        }
    }

    @discardableResult
    func catchUpIfDue(repo: Repository) async -> Bool {
        if !firebaseConfigured {
            bootstrap()
        }
        guard phase == .enrolled,
              !isBusy,
              !running,
              !socialRunning,
              automatic || defaults.bool(forKey: Key.socialEnabled)
        else { return true }
        let continuationPending = defaults.bool(
            forKey: Key.continuationPending
        )
        let lastAttempt = defaults.double(forKey: Key.lastAttempt)
        let now = Date().timeIntervalSince1970
        var completed = true
        if automatic
            && (
                continuationPending
                    || now - lastAttempt >= Self.automaticInterval
            ) {
            do {
                let summary = try await sync(repo: repo, mode: .automatic)
                scheduleContinuationIfNeeded(summary)
                completed = !summary.hasMore
            } catch {
                setStatus(Self.userMessage(for: error))
                completed = false
            }
        }
        let socialLastAttempt = defaults.double(forKey: Key.socialLastAttempt)
        if defaults.bool(forKey: Key.socialEnabled),
           now - socialLastAttempt >= Self.socialAutomaticInterval {
            defaults.set(now, forKey: Key.socialLastAttempt)
            do {
                try await refreshSocialData(repo: repo, deliverPokes: true)
            } catch {
                AppDiagnosticsRecorder.shared.record(
                    "managed_social.catch_up",
                    fields: [
                        "outcome": "failed",
                        "failure_kind": Self.diagnosticSyncFailureKind(error),
                    ]
                )
                completed = false
            }
        }
        return completed
    }

    func disconnect() {
        do {
            try configureFirebaseIfNeeded()
            try Auth.auth().signOut()
        } catch {
            setStatus(Self.userMessage(for: error))
            return
        }
        verificationID = nil
        deletionVerificationID = nil
        defaults.set(false, forKey: Key.automatic)
        defaults.removeObject(forKey: Key.continuationPending)
        overview = nil
        installations = []
        clearSocialPresentation()
        phase = .signedOut
        setStatus(
            String(localized:
                "NOOP+ is disconnected on this iPhone. Local data and cloud data were not deleted."
            )
        )
    }

    func sendDeletionCode() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try configureFirebaseIfNeeded()
            guard let phone = Auth.auth().currentUser?.phoneNumber else {
                throw ManagedCloudError.notSignedIn
            }
            try Self.configureDebugPhoneVerification(for: phone)
            deletionVerificationID = try await PhoneAuthProvider.provider(auth: Auth.auth())
                .verifyPhoneNumber(phone, uiDelegate: nil)
            setStatus(
                String(localized:
                    "A fresh verification code was sent to \(Self.maskedPhone(phone))."
                )
            )
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func requestAccountDeletion(code rawCode: String) async {
        guard !isBusy, let deletionVerificationID else {
            setStatus(
                String(localized: "Send a fresh verification code before deleting NOOP+.")
            )
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let user = try currentUser()
            let credential = PhoneAuthProvider.provider(auth: Auth.auth()).credential(
                withVerificationID: deletionVerificationID,
                verificationCode: try Self.normalizedCode(rawCode)
            )
            _ = try await user.reauthenticate(with: credential)
            self.deletionVerificationID = nil

            let request = try ManagedErasureRequest(
                requestID: UUID(),
                scope: .account,
                confirmationSHA256: ManagedDigest.sha256(Self.accountDeletionConfirmation)
            )
            let job = try await client().requestErasure(
                request,
                authorization: try await authorization(forceRefresh: true)
            )
            defaults.set(job.erasureJobID.uuidString.lowercased(), forKey: Key.erasureJobID)
            defaults.set(job.notBefore, forKey: Key.erasureNotBefore)
            defaults.set(false, forKey: Key.automatic)
            deletionNotBefore = job.notBefore
            phase = .deletionScheduled
            setStatus(
                String(localized:
                    "NOOP+ account deletion is scheduled after the 24-hour cooling-off period."
                )
            )
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func refreshDeletionStatus() async {
        guard !isBusy,
              let rawID = defaults.string(forKey: Key.erasureJobID),
              let jobID = UUID(uuidString: rawID) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let job = try await client().erasure(
                jobID: jobID,
                authorization: try await authorization(forceRefresh: false)
            )
            deletionNotBefore = job.notBefore
            defaults.set(job.notBefore, forKey: Key.erasureNotBefore)
            if job.status == "completed" {
                completeLocalErasureState()
            } else if job.status == "canceled" {
                restoreAfterCanceledErasure()
            } else {
                phase = .deletionScheduled
                setStatus(
                    String(localized:
                        "NOOP+ account deletion status: \(Self.erasureStatus(job.status))."
                    )
                )
            }
        } catch ManagedStorageError.notFound {
            completeLocalErasureState()
        } catch {
            if deletionDeadlineHasPassed() {
                completeLocalDeletionHandoff()
            } else {
                setStatus(Self.userMessage(for: error))
            }
        }
    }

    func cancelAccountDeletion() async {
        guard !isBusy,
              let rawID = defaults.string(forKey: Key.erasureJobID),
              let jobID = UUID(uuidString: rawID) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let job = try await client().cancelErasure(
                jobID: jobID,
                authorization: try await authorization(forceRefresh: true)
            )
            guard job.status == "canceled" else {
                throw ManagedStorageError.invalidResponse
            }
            restoreAfterCanceledErasure()
            try await refreshOverviewData()
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    private func beginSocialAction() -> Bool {
        guard phase == .enrolled, !isBusy, !socialRunning else { return false }
        isBusy = true
        return true
    }

    private func endSocialAction() {
        isBusy = false
    }

    private func runSocialOperation(
        _ operation: String,
        body: () async throws -> Void
    ) async {
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_social",
            fields: ["operation": operation]
        )
        do {
            try await body()
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["operation": operation]
            )
        } catch {
            socialStatus = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: error is CancellationError ? "canceled" : "failed",
                fields: [
                    "operation": operation,
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ]
            )
        }
    }

    private func refreshSocialData(
        repo: Repository,
        deliverPokes: Bool
    ) async throws {
        guard phase == .enrolled else { throw ManagedCloudError.consentRequired }
        guard !socialRunning else { return }
        socialRunning = true
        defer { socialRunning = false }

        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_social_refresh",
            fields: ["delivery": deliverPokes ? "enabled" : "disabled"]
        )
        do {
            let managedClient = try client()
            let auth = try await authorization(forceRefresh: false)
            let profile: ManagedSocialProfile
            do {
                profile = try await managedClient.socialProfile(
                    authorization: auth
                )
            } catch ManagedStorageError.notFound {
                defaults.set(false, forKey: Key.socialEnabled)
                socialProfile = nil
                socialFriends = []
                socialBlockedProfiles = []
                socialRequests = []
                socialFeed = []
                socialLookup = nil
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "completed",
                    fields: [
                        "profile": "absent",
                        "friends": "0",
                        "blocks": "0",
                        "requests": "0",
                        "summaries_uploaded": "0",
                        "pokes_claimed": "0",
                    ]
                )
                return
            }

            defaults.set(true, forKey: Key.socialEnabled)
            async let loadedFriends = managedClient.socialFriends(
                authorization: auth
            )
            async let loadedBlocks = managedClient.socialBlockedProfiles(
                authorization: auth
            )
            async let loadedRequests = managedClient.socialRequests(
                authorization: auth
            )
            let (friends, blockedProfiles, requests) = try await (
                loadedFriends,
                loadedBlocks,
                loadedRequests
            )
            let feedDays = Self.socialSummaryDays(daysBack: 6)
            var feed: [ManagedSocialFeedDay] = []
            var feedOutcome = "empty_range"
            if let startDay = feedDays.first,
               let endDay = feedDays.last {
                do {
                    feed = try await managedClient.socialFeed(
                        startDay: startDay,
                        endDay: endDay,
                        authorization: auth
                    )
                    feedOutcome = "completed"
                } catch {
                    if error is CancellationError {
                        throw error
                    }
                    feedOutcome = "failed"
                    AppDiagnosticsRecorder.shared.record(
                        "managed_social.feed",
                        fields: [
                            "outcome": "failed",
                            "failure_kind": Self.diagnosticSyncFailureKind(error),
                        ]
                    )
                }
            }
            socialProfile = profile
            socialFriends = friends
            socialBlockedProfiles = blockedProfiles
            socialRequests = requests
            socialFeed = feed

            let summariesUploaded = try await uploadChangedSocialSummaries(
                repo: repo,
                friends: friends,
                client: managedClient,
                authorization: auth
            )
            if summariesUploaded > 0 {
                socialProfile = try await managedClient.socialProfile(
                    authorization: auth
                )
            }
            let pokesClaimed = deliverPokes
                ? try await deliverSocialPokes(
                    client: managedClient,
                    authorization: auth
                )
                : 0
            if socialStatus.isEmpty {
                socialStatus = String(
                    localized: "Managed Friends is up to date."
                )
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: [
                    "profile": "active",
                    "friends": String(friends.count),
                    "blocks": String(blockedProfiles.count),
                    "requests": String(requests.count),
                    "feed_rows": String(feed.count),
                    "feed_outcome": feedOutcome,
                    "summaries_uploaded": String(summariesUploaded),
                    "pokes_claimed": String(pokesClaimed),
                ]
            )
        } catch {
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: error is CancellationError ? "canceled" : "failed",
                fields: [
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ]
            )
            throw error
        }
    }

    private func uploadChangedSocialSummaries(
        repo: Repository,
        friends: [ManagedSocialFriend],
        client: ManagedStorageClient,
        authorization: ManagedAuthorization
    ) async throws -> Int {
        guard let store = await repo.storeHandle() else {
            throw ManagedCloudError.storeUnavailable
        }
        let days = Self.socialSummaryDays()
        guard let firstDay = days.first, let lastDay = days.last else { return 0 }
        var dailyByDay = Dictionary(
            uniqueKeysWithValues: days.map {
                ($0, ManagedSocialSummary())
            }
        )
        let allowed = Self.socialVisibilityUnion(friends)
        var sourceIDs = [repo.deviceId + "-noop"]
        let canonicalID = Repository.whoopSource + "-noop"
        if !sourceIDs.contains(canonicalID) {
            sourceIDs.append(canonicalID)
        }
        for sourceID in sourceIDs {
            let dailyRows = try await store.dailyMetrics(
                deviceId: sourceID,
                from: firstDay,
                to: lastDay
            )
            for row in dailyRows {
                guard let current = dailyByDay[row.day] else { continue }
                dailyByDay[row.day] = ManagedSocialSummary(
                    charge: current.charge ?? (
                        allowed.charge
                            ? Self.socialValue(row.recovery, in: 0...100)
                            : nil
                    ),
                    effort: current.effort ?? (
                        allowed.effort
                            ? Self.socialValue(row.strain, in: 0...100)
                            : nil
                    ),
                    rest: current.rest,
                    sleepDuration: current.sleepDuration ?? (
                        allowed.sleepDuration
                            ? Self.socialValue(
                                row.totalSleepMin,
                                in: 0...1_440
                            )
                            : nil
                    ),
                    hrv: current.hrv ?? (
                        allowed.hrv
                            ? Self.socialValue(row.avgHrv, in: 0...500)
                            : nil
                    ),
                    rhr: current.rhr ?? (
                        allowed.rhr
                            ? Self.socialValue(
                                row.restingHr.map(Double.init),
                                in: 20...250
                            )
                            : nil
                    )
                )
            }
            if allowed.rest {
                let restRows = try await store.metricSeries(
                    deviceId: sourceID,
                    key: "sleep_performance",
                    from: firstDay,
                    to: lastDay
                )
                for point in restRows {
                    guard let current = dailyByDay[point.day] else { continue }
                    dailyByDay[point.day] = ManagedSocialSummary(
                        charge: current.charge,
                        effort: current.effort,
                        rest: current.rest ?? Self.socialValue(
                            point.value,
                            in: 0...100
                        ),
                        sleepDuration: current.sleepDuration,
                        hrv: current.hrv,
                        rhr: current.rhr
                    )
                }
            }
        }

        let scope = try accountScopeHash()
        if defaults.string(forKey: Key.socialSummaryScope) != scope {
            defaults.set(scope, forKey: Key.socialSummaryScope)
            defaults.removeObject(forKey: Key.socialSummaryDigests)
        }
        var digests = defaults.dictionary(
            forKey: Key.socialSummaryDigests
        ) as? [String: String] ?? [:]
        var uploaded = 0
        for day in days {
            try Task.checkCancellation()
            let summary = dailyByDay[day] ?? ManagedSocialSummary()
            let digest = try Self.socialSummaryDigest(
                day: day,
                summary: summary,
                visibility: allowed
            )
            if digests[day] == digest { continue }
            if digests[day] == nil, !Self.hasSocialValue(summary) {
                continue
            }
            let requestID = ManagedStableIdentifier.uuid(
                seed: Data(
                    "noop-managed-social-summary-v1\0\(scope)\0\(day)\0\(digest)"
                        .utf8
                )
            )
            try await client.putSocialSummary(
                day: day,
                summary: summary,
                requestID: requestID,
                authorization: authorization
            )
            digests[day] = digest
            uploaded += 1
            let retained = Set(days)
            digests = digests.filter { retained.contains($0.key) }
            defaults.set(digests, forKey: Key.socialSummaryDigests)
        }
        return uploaded
    }

    private func deliverSocialPokes(
        client: ManagedStorageClient,
        authorization: ManagedAuthorization
    ) async throws -> Int {
        let claims = try await client.claimSocialPokes(
            limit: 3,
            authorization: authorization
        )
        for claim in claims {
            try Task.checkCancellation()
            let existing = socialDeliveryReceipt(for: claim.pokeID)
            let notificationOutcome: String
            let hapticOutcome: String
            if let existing {
                notificationOutcome = existing.notificationOutcome
                hapticOutcome = existing.hapticOutcome
            } else {
                notificationOutcome = await scheduleSocialPokeNotification(
                    pokeID: claim.pokeID
                )
                hapticOutcome = socialPokeHaptic?() == true
                    ? "requested"
                    : "band_unavailable"
                storeSocialDeliveryReceipt(
                    pokeID: claim.pokeID,
                    notificationOutcome: notificationOutcome,
                    hapticOutcome: hapticOutcome
                )
            }
            _ = try await client.acknowledgeSocialPoke(
                claim.pokeID,
                acknowledgement: ManagedSocialPokeAcknowledgement(
                    claimID: claim.claimID,
                    notificationOutcome: notificationOutcome,
                    hapticOutcome: hapticOutcome
                ),
                authorization: authorization
            )
        }
        if !claims.isEmpty {
            let scheduled = claims.filter {
                socialDeliveryReceipt(for: $0.pokeID)?.notificationOutcome
                    == "scheduled"
            }.count
            let haptics = claims.filter {
                socialDeliveryReceipt(for: $0.pokeID)?.hapticOutcome
                    == "requested"
            }.count
            AppDiagnosticsRecorder.shared.record(
                "managed_social.poke_delivery",
                fields: [
                    "claimed": String(claims.count),
                    "notifications_scheduled": String(scheduled),
                    "haptics_requested": String(haptics),
                ]
            )
        }
        return claims.count
    }

    private func scheduleSocialPokeNotification(pokeID: UUID) async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral]
            .contains(settings.authorizationStatus) else {
            LocalNotificationLifecycle.suppressed(
                identifier: "managed-poke",
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return "not_authorized"
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "A friend sent a poke")
        content.body = String(localized: "Open NOOP when you have a moment.")
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.userInfo = [
            NotificationRouteBridge.userInfoKey:
                NoopNotificationRoute.friends.rawValue,
        ]
        content.applyProminence(.standard)
        let request = UNNotificationRequest(
            identifier: "managed-poke-\(pokeID.uuidString.lowercased())",
            content: content,
            trigger: nil
        )
        do {
            try await LocalNotificationLifecycle.schedule(request, on: center)
            return "scheduled"
        } catch {
            return "failed"
        }
    }

    private struct SocialDeliveryReceipt: Codable {
        let pokeID: UUID
        let notificationOutcome: String
        let hapticOutcome: String
        let recordedAt: Date
    }

    private func socialDeliveryReceipt(
        for pokeID: UUID
    ) -> SocialDeliveryReceipt? {
        socialDeliveryReceipts().first { $0.pokeID == pokeID }
    }

    private func storeSocialDeliveryReceipt(
        pokeID: UUID,
        notificationOutcome: String,
        hapticOutcome: String
    ) {
        var receipts = socialDeliveryReceipts().filter {
            $0.pokeID != pokeID
        }
        receipts.append(
            SocialDeliveryReceipt(
                pokeID: pokeID,
                notificationOutcome: notificationOutcome,
                hapticOutcome: hapticOutcome,
                recordedAt: Date()
            )
        )
        receipts = Array(receipts.suffix(64))
        if let data = try? JSONEncoder().encode(receipts) {
            defaults.set(data, forKey: Key.socialDeliveryReceipts)
        }
    }

    private func socialDeliveryReceipts() -> [SocialDeliveryReceipt] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let data = defaults.data(forKey: Key.socialDeliveryReceipts),
              let decoded = try? JSONDecoder().decode(
                  [SocialDeliveryReceipt].self,
                  from: data
              ) else {
            return []
        }
        return Array(decoded.filter { $0.recordedAt >= cutoff }.suffix(64))
    }

    private func socialRequestID(for key: String) -> UUID {
        if let raw = defaults.string(forKey: key),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = UUID()
        defaults.set(created.uuidString.lowercased(), forKey: key)
        return created
    }

    private static func socialVisibilityUnion(
        _ friends: [ManagedSocialFriend]
    ) -> ManagedSocialVisibility {
        ManagedSocialVisibility(
            charge: friends.contains { $0.sharing.charge },
            effort: friends.contains { $0.sharing.effort },
            rest: friends.contains { $0.sharing.rest },
            sleepDuration: friends.contains { $0.sharing.sleepDuration },
            hrv: friends.contains { $0.sharing.hrv },
            rhr: friends.contains { $0.sharing.rhr },
            pokeAllowed: friends.contains { $0.sharing.pokeAllowed }
        )
    }

    private static func socialSummaryDays(
        daysBack: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(
            byAdding: .day,
            value: -max(0, daysBack),
            to: end
        ) else {
            return []
        }
        return (0...max(0, daysBack)).compactMap { offset in
            calendar.date(
                byAdding: .day,
                value: offset,
                to: start
            ).map(Self.socialDayString)
        }
    }

    private static func socialDayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static func socialValue(
        _ value: Double?,
        in range: ClosedRange<Double>
    ) -> Double? {
        guard let value, value.isFinite, range.contains(value) else {
            return nil
        }
        return value
    }

    private static func hasSocialValue(_ summary: ManagedSocialSummary) -> Bool {
        summary.charge != nil
            || summary.effort != nil
            || summary.rest != nil
            || summary.sleepDuration != nil
            || summary.hrv != nil
            || summary.rhr != nil
    }

    private static func socialSummaryDigest(
        day: String,
        summary: ManagedSocialSummary,
        visibility: ManagedSocialVisibility
    ) throws -> String {
        guard let digest = ManagedSocialProjection.digest(
            day: day,
            summary: summary,
            visibility: visibility
        ) else {
            throw ManagedStorageError.invalidResponse
        }
        return digest
    }

    // MARK: - Sync composition

    private enum SyncMode {
        case manual
        case automatic
        case exportPreparation

        var diagnosticName: String {
            switch self {
            case .manual: return "manual"
            case .automatic: return "automatic"
            case .exportPreparation: return "export_preparation"
            }
        }
    }

    private func sync(repo: Repository, mode: SyncMode) async throws -> SyncSummary {
        guard phase == .enrolled else { throw ManagedCloudError.consentRequired }
        guard !running else { return SyncSummary(
            uploadedChunks: 0,
            uploadedBytes: 0,
            uploadedDocuments: 0,
            appliedChanges: 0,
            hasMore: defaults.bool(forKey: Key.continuationPending),
            prunedWindows: 0,
            prunedRows: 0
        ) }
        guard let store = await repo.storeHandle() else {
            throw ManagedCloudError.storeUnavailable
        }

        running = true
        defer { running = false }
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastAttempt)
        switch mode {
        case .manual:
            setStatus(String(localized: "Syncing NOOP+…"))
        case .automatic:
            setStatus(String(localized: "Updating NOOP+ in the background…"))
        case .exportPreparation:
            setStatus(String(localized: "Finishing current phone backup before export…"))
        }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_sync",
            fields: ["mode": mode.diagnosticName]
        )
        do {
            let scopeHash = try accountScopeHash()
            let summary = try await ManagedAuthenticationRetry.run(
                authorization: { [self] forceRefresh in
                    if forceRefresh {
                        AppDiagnosticsRecorder.shared.record(
                            "managed_sync.auth_refresh",
                            fields: ["reason": "server_rejected_cached_token"]
                        )
                    }
                    return try await authorization(forceRefresh: forceRefresh)
                },
                operation: { [self] authorization in
                    try await syncPass(
                        repo: repo,
                        store: store,
                        mode: mode,
                        scopeHash: scopeHash,
                        authorization: authorization
                    )
                }
            )

            let now = Date()
            defaults.set(now.timeIntervalSince1970, forKey: Key.lastSuccess)
            defaults.set(summary.hasMore, forKey: Key.continuationPending)
            lastSuccessAt = now
            if summary.hasMore {
                setStatus(String(localized: "NOOP+ backup is continuing in the background."))
            } else if summary.uploadedChunks == 0
                && summary.uploadedDocuments == 0
                && summary.appliedChanges == 0
                && summary.prunedRows == 0 {
                setStatus(String(localized: "NOOP+ is up to date."))
            } else {
                let changes = Self.localizedSyncChanges(summary)
                setStatus(String(localized: "NOOP+ updated \(changes)."))
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: [
                    "mode": mode.diagnosticName,
                    "uploaded_chunks": String(summary.uploadedChunks),
                    "uploaded_documents": String(summary.uploadedDocuments),
                    "applied_changes": String(summary.appliedChanges),
                    "pruned_rows": String(summary.prunedRows),
                    "continuation_pending": summary.hasMore ? "true" : "false",
                ],
                includeResourceSnapshot: true
            )
            if summary.appliedChanges > 0 {
                await repo.refresh()
            }
            return summary
        } catch {
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: error is CancellationError ? "canceled" : "failed",
                fields: [
                    "mode": mode.diagnosticName,
                    "failure_kind": Self.diagnosticSyncFailureKind(error),
                ],
                includeResourceSnapshot: true
            )
            throw error
        }
    }

    /// Stable, privacy-safe failure category for the shake report. Associated response text, account
    /// scope, installation ids, phone details, request payloads and authorization values never enter it.
    private static func diagnosticSyncFailureKind(_ error: Error) -> String {
        if error is CancellationError { return "canceled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "network_offline"
            case .timedOut:
                return "network_timeout"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "network_unreachable"
            default:
                return "network_transport"
            }
        }
        if let storage = error as? ManagedStorageError {
            switch storage {
            case .invalidConfiguration:
                return "configuration"
            case .invalidAuthorization, .authentication:
                return "authentication"
            case .forbidden:
                return "forbidden"
            case .invalidResponse, .decoding:
                return "invalid_response"
            case .encoding:
                return "local_encoding"
            case .transport:
                return "network_transport"
            case .notFound:
                return "not_found"
            case .policyChanged:
                return "policy_changed"
            case .cursorExpired:
                return "cursor_expired"
            case .quotaExceeded:
                return "quota_exceeded"
            case .conflict:
                return "conflict"
            case .server(let status):
                return status >= 500 ? "server_5xx" : "server_rejected"
            case .digestMismatch:
                return "integrity"
            }
        }
        if let cloud = error as? ManagedCloudError {
            switch cloud {
            case .notSignedIn:
                return "authentication"
            case .consentRequired:
                return "consent"
            case .storeUnavailable:
                return "local_store"
            case .firebaseProjectConflict:
                return "configuration"
            case .exportPreparationIncomplete:
                return "continuation_required"
            case .invalidPhone, .invalidCode:
                return "input"
            }
        }
        return "other"
    }

    private static func diagnosticOperationOutcome(_ error: Error) -> String {
        switch diagnosticSyncFailureKind(error) {
        case "input", "authentication", "forbidden", "consent",
             "policy_changed", "quota_exceeded", "conflict", "server_rejected":
            return "rejected"
        case "canceled":
            return "canceled"
        default:
            return "failed"
        }
    }

    private func syncPass(
        repo: Repository,
        store: WhoopStore,
        mode: SyncMode,
        scopeHash: String,
        authorization: ManagedAuthorization
    ) async throws -> SyncSummary {
        let state = try WhoopManagedSyncStateStore(
            store: store,
            accountScopeHash: scopeHash
        )
        if let settings = BackupSettings.encode(
            BackupSettings.snapshot(from: defaults)
        ) {
            try await store.stageManagedPreferences(
                settings,
                updatedAtMs: Int64(
                    (Date().timeIntervalSince1970 * 1_000).rounded(.down)
                )
            )
        }
        let documents = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: scopeHash,
            preferencesDefaults: defaults
        )
        let coordinator = ManagedSyncCoordinator(
            transport: try client(),
            extractor: WhoopManagedChunkExtractor(store: store),
            state: state,
            restore: WhoopManagedRestoreApplier(
                store: store,
                documentRestore: documents
            ),
            documents: documents
        )
        let sources = try await sourceDescriptors(
            repo: repo,
            store: store,
            installationID: authorization.installationID
        )

        var uploadedChunks = 0
        var uploadedBytes = 0
        var uploadedDocuments = 0
        var appliedChanges = 0
        var hasMore = false
        var prunedWindows = 0
        var prunedRows = 0
        let localPruneNowMs = optimizePhoneStorage && mode != .exportPreparation
            ? Int64(Date().timeIntervalSince1970 * 1_000)
            : nil
        let limits: (
            forward: Int,
            dirty: Int,
            changes: Int,
            snapshotObjects: Int,
            snapshotBytes: Int,
            documents: Int,
            prune: Int
        )
        switch mode {
        case .manual:
            limits = (8, 8, 4, 32, 64 * 1_024 * 1_024, 32, 8)
        case .automatic:
            limits = (2, 2, 1, 16, 32 * 1_024 * 1_024, 8, 2)
        case .exportPreparation:
            limits = (100, 100, 20, 200, 256 * 1_024 * 1_024, 100, 0)
        }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let result = try await coordinator.sync(
                source: source,
                authorization: authorization,
                dataClasses: Self.enrollmentDataClasses,
                maxForwardWindowsPerClass: limits.forward,
                maxDirtyWindowsPerClass: limits.dirty,
                maxChangePages: index == 0 ? limits.changes : 0,
                changePageSize: 100,
                maxSnapshotRestoreObjects: limits.snapshotObjects,
                maxSnapshotRestoreBytes: limits.snapshotBytes,
                maxDocumentUploads: index == 0 ? limits.documents : 0,
                localPruneNowMs: localPruneNowMs,
                maxPruneWindowsPerClass: limits.prune
            )
            uploadedChunks += result.uploadedChunks
            uploadedBytes += result.uploadedBytes
            uploadedDocuments += result.uploadedDocuments
            appliedChanges += result.appliedChanges
            hasMore = hasMore || result.hasMoreWork
            prunedWindows += result.prunedWindows
            prunedRows += result.prunedRows
        }
        return SyncSummary(
            uploadedChunks: uploadedChunks,
            uploadedBytes: uploadedBytes,
            uploadedDocuments: uploadedDocuments,
            appliedChanges: appliedChanges,
            hasMore: hasMore,
            prunedWindows: prunedWindows,
            prunedRows: prunedRows
        )
    }

    private func sourceDescriptors(
        repo: Repository,
        store: WhoopStore,
        installationID: String
    ) async throws -> [ManagedSourceDescriptor] {
        let paired = try await store.pairedDeviceIdsForRemoteSync()
            .filter { !$0.hasPrefix("noop-plus-") }
        var physical: [String] = []
        for source in [repo.deviceId] + paired + [Repository.whoopSource]
        where !source.isEmpty && !source.hasPrefix("noop-plus-") && !physical.contains(source) {
            physical.append(source)
        }

        var candidates: [(String, String)] = physical.map { ($0, "live_ble") }
        for source in physical where !source.hasSuffix("-noop") {
            candidates.append((source + "-noop", "noop_computed"))
        }
        candidates.append((Repository.appleHealthSource, "apple_health"))
        candidates.append((Repository.activityFileSource, "activity_file"))

        var seen: Set<String> = []
        return try candidates.compactMap { localID, kind in
            guard seen.insert(localID).inserted else { return nil }
            return try ManagedSourceDescriptor(
                localSourceID: localID,
                sourceKind: kind,
                platform: .iOS,
                installationID: installationID
            )
        }
    }

    // MARK: - Identity and configuration

    private func refreshOverviewData() async throws {
        let client = try client()
        let authorization = try await authorization(forceRefresh: false)
        async let loadedOverview = client.overview(authorization: authorization)
        async let loadedInstallations = client.installations(
            authorization: authorization
        )
        overview = try await loadedOverview
        installations = try await loadedInstallations
    }

    private func client() throws -> ManagedStorageClient {
        guard let configuration else { throw ManagedStorageError.invalidConfiguration }
        return ManagedStorageClient(
            configuration: configuration,
            requestObserver: { diagnostic in
                var fields = [
                    "target": diagnostic.target,
                    "route_group": diagnostic.routeGroup,
                    "method": diagnostic.method,
                    "duration_ms": String(diagnostic.durationMilliseconds),
                    "outcome": diagnostic.outcome,
                ]
                if let status = diagnostic.statusCode {
                    fields["status_code"] = String(status)
                }
                if let requestID = diagnostic.requestID {
                    fields["server_request_id"] = requestID
                }
                AppDiagnosticsRecorder.shared.record(
                    "managed_http.request",
                    fields: fields
                )
            }
        )
    }

    private func authorization(forceRefresh: Bool) async throws -> ManagedAuthorization {
        try configureFirebaseIfNeeded()
        let user = try currentUser()
        let scopeHash = accountScopeHash(for: user)
        async let identityToken = user.getIDToken(forcingRefresh: forceRefresh)
        async let appCheckToken = Self.appCheckToken(forceRefresh: forceRefresh)
        return try await ManagedAuthorization(
            identityToken: identityToken,
            appCheckToken: appCheckToken,
            installationID: ManagedAccountIdentifier.installationID(
                baseInstallationID: ManagedCloudInstallationID.value(),
                accountScopeHash: scopeHash
            ),
            installationToken: ManagedCloudInstallationToken.value(
                accountScopeHash: scopeHash
            )
        )
    }

    private func currentUser() throws -> User {
        guard let user = Auth.auth().currentUser else { throw ManagedCloudError.notSignedIn }
        return user
    }

    private func accountScopeHash() throws -> String {
        accountScopeHash(for: try currentUser())
    }

    private func accountScopeHash(for user: User) -> String {
        ManagedDigest.sha256(Data("noop-managed-account-v1\0\(user.uid)".utf8))
    }

    private func enrollmentRequestID() -> UUID {
        if let raw = defaults.string(forKey: Key.enrollmentRequestID),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let requestID = UUID()
        defaults.set(
            requestID.uuidString.lowercased(),
            forKey: Key.enrollmentRequestID
        )
        return requestID
    }

    private func reconcileAuthenticatedState() {
        guard Auth.auth().currentUser != nil else {
            phase = .signedOut
            return
        }
        let scope = try? accountScopeHash()
        let enrolled = scope == defaults.string(forKey: Key.enrolledScopeHash)
            && configuration?.policyVersion == defaults.string(forKey: Key.enrolledPolicy)
        if enrolled,
           defaults.string(forKey: Key.erasureJobID) != nil {
            phase = .deletionScheduled
        } else {
            phase = enrolled ? .enrolled : .consentRequired
        }
    }

    private func clearEnrollment() {
        defaults.removeObject(forKey: Key.enrolledScopeHash)
        defaults.removeObject(forKey: Key.enrolledPolicy)
        defaults.removeObject(forKey: Key.automatic)
        defaults.removeObject(forKey: Key.optimizePhoneStorage)
        defaults.removeObject(forKey: Key.continuationPending)
        defaults.removeObject(forKey: Key.enrollmentRequestID)
        defaults.removeObject(forKey: Key.erasureJobID)
        defaults.removeObject(forKey: Key.erasureNotBefore)
        defaults.removeObject(forKey: Key.socialProfileRequestID)
        defaults.removeObject(forKey: Key.socialInviteRequestID)
        defaults.removeObject(forKey: Key.socialSummaryDigests)
        defaults.removeObject(forKey: Key.socialSummaryScope)
        defaults.removeObject(forKey: Key.socialLastAttempt)
        defaults.removeObject(forKey: Key.socialDeliveryReceipts)
        defaults.removeObject(forKey: Key.socialEnabled)
        defaults.removeObject(forKey: Key.socialPendingNOOPID)
        ManagedCloudSocialInviteSecret.clearAll()
        deletionNotBefore = nil
        overview = nil
        installations = []
        clearSocialPresentation()
    }

    private func clearSocialPresentation() {
        socialProfile = nil
        socialFriends = []
        socialBlockedProfiles = []
        socialRequests = []
        socialFeed = []
        socialLookup = nil
        socialInvite = nil
        clearPendingSocialInvite()
        clearPendingSocialProfileLink()
        socialStatus = ""
    }

    private func clearSocialState() {
        defaults.removeObject(forKey: Key.socialProfileRequestID)
        defaults.removeObject(forKey: Key.socialInviteRequestID)
        defaults.removeObject(forKey: Key.socialSummaryDigests)
        defaults.removeObject(forKey: Key.socialSummaryScope)
        defaults.removeObject(forKey: Key.socialLastAttempt)
        defaults.removeObject(forKey: Key.socialDeliveryReceipts)
        defaults.removeObject(forKey: Key.socialEnabled)
        defaults.removeObject(forKey: Key.socialPendingNOOPID)
        ManagedCloudSocialInviteSecret.clearAll()
        clearSocialPresentation()
    }

    private func completeLocalErasureState() {
        try? Auth.auth().signOut()
        clearEnrollment()
        phase = .signedOut
        setStatus(
            String(localized:
                "NOOP+ cloud account deletion completed. Local NOOP data remains on this iPhone."
            )
        )
    }

    private func completeLocalDeletionHandoff() {
        try? Auth.auth().signOut()
        clearEnrollment()
        phase = .signedOut
        setStatus(
            String(localized:
                "NOOP+ account deletion is processing in the cloud. Local NOOP data remains on this iPhone."
            )
        )
    }

    private func deletionDeadlineHasPassed(now: Date = Date()) -> Bool {
        guard let value = defaults.string(forKey: Key.erasureNotBefore) else {
            return false
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let deadline = fractional.date(from: value)
                ?? standard.date(from: value) else {
            return false
        }
        return deadline <= now
    }

    private func restoreAfterCanceledErasure() {
        defaults.removeObject(forKey: Key.erasureJobID)
        defaults.removeObject(forKey: Key.erasureNotBefore)
        defaults.set(true, forKey: Key.automatic)
        deletionNotBefore = nil
        phase = .enrolled
        setStatus(String(localized: "NOOP+ account deletion was canceled."))
    }

    private func configureFirebaseIfNeeded() throws {
        guard !firebaseConfigured else { return }
        guard let configuration else { throw ManagedStorageError.invalidConfiguration }
        let values = try Self.firebaseValues()

        if let existing = FirebaseApp.app() {
            guard existing.options.projectID == values.projectID else {
                throw ManagedCloudError.firebaseProjectConflict
            }
        } else {
            #if DEBUG
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #elseif targetEnvironment(simulator)
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #else
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
            #endif
            let options = FirebaseOptions(
                googleAppID: values.googleAppID,
                gcmSenderID: values.gcmSenderID
            )
            options.apiKey = values.apiKey
            options.projectID = values.projectID
            options.bundleID = Bundle.main.bundleIdentifier ?? options.bundleID
            FirebaseApp.configure(options: options)
        }
        _ = configuration
        firebaseConfigured = true
    }

    private struct FirebaseValues {
        let projectID: String
        let apiKey: String
        let googleAppID: String
        let gcmSenderID: String
    }

    private static func firebaseValues(bundle: Bundle = .main) throws -> FirebaseValues {
        func value(_ key: String) throws -> String {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
                throw ManagedStorageError.invalidConfiguration
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("$(") else {
                throw ManagedStorageError.invalidConfiguration
            }
            return trimmed
        }
        return FirebaseValues(
            projectID: try value("NOOPManagedProjectID"),
            apiKey: try value("NOOPManagedAPIKey"),
            googleAppID: try value("NOOPManagedGoogleAppID"),
            gcmSenderID: try value("NOOPManagedGCMSenderID")
        )
    }

    private static func loadConfiguration(bundle: Bundle) -> ManagedStorageConfiguration? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
        }
        guard let api = value("NOOPManagedAPIURL"),
              let url = URL(string: api),
              let version = value("NOOPManagedPolicyVersion"),
              let digest = value("NOOPManagedPolicySHA256"),
              (try? firebaseValues(bundle: bundle)) != nil else {
            return nil
        }
        return try? ManagedStorageConfiguration(
            baseURL: url,
            policyVersion: version,
            policySHA256: digest,
            allowLocalHTTP: debugManagedFlag(
                "NOOPManagedAllowLocalHTTP",
                bundle: bundle
            )
        )
    }

    private static func debugManagedFlag(
        _ key: String,
        bundle: Bundle = .main
    ) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        #else
        _ = key
        _ = bundle
        return false
        #endif
    }

    private static func configureDebugPhoneVerification(
        for phone: String,
        bundle: Bundle = .main
    ) throws {
        #if DEBUG && targetEnvironment(simulator)
        guard debugManagedFlag(
            "NOOPManagedDisablePhoneAppVerification",
            bundle: bundle
        ) else {
            return
        }
        guard let raw = bundle.object(
            forInfoDictionaryKey: "NOOPManagedTestPhone"
        ) as? String,
              try normalizedPhone(raw) == phone else {
            throw ManagedCloudError.invalidPhone
        }
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #else
        _ = phone
        _ = bundle
        #endif
    }

    private static func appCheckToken(forceRefresh: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            AppCheck.appCheck().token(forcingRefresh: forceRefresh) { token, error in
                if let token {
                    continuation.resume(returning: token.token)
                } else {
                    continuation.resume(
                        throwing: error ?? ManagedStorageError.authentication
                    )
                }
            }
        }
    }

    private func setStatus(_ value: String) {
        status = value
        defaults.set(value, forKey: Key.lastStatus)
    }

    private func setExportStatus(_ progress: ManagedHistoryExportProgress) {
        switch progress.phase {
        case .preparing:
            setStatus(String(localized: "Creating a consistent cloud-history snapshot…"))
        case .chunks:
            let bytes = ByteCountFormatter.string(
                fromByteCount: progress.completedChunkBytes,
                countStyle: .file
            )
            let total = ByteCountFormatter.string(
                fromByteCount: progress.totalChunkBytes,
                countStyle: .file
            )
            setStatus(
                String(localized:
                    "Exporting cloud history: \(progress.completedObjects) of \(progress.totalObjects) objects, \(bytes) of \(total)."
                )
            )
        case .documents:
            setStatus(
                String(localized:
                    "Exporting personal records: \(progress.completedObjects) of \(progress.totalObjects) objects."
                )
            )
        case .finalizing:
            setStatus(
                String(localized:
                    "Verifying \(progress.completedObjects) exported objects and finalizing the archive…"
                )
            )
        }
    }

    private func scheduleContinuationIfNeeded(_ summary: SyncSummary) {
        guard summary.hasMore else { return }
        BackgroundSyncScheduler.scheduleNext(afterSuccess: false)
    }

    private static func localizedSyncChanges(_ summary: SyncSummary) -> String {
        var values: [String] = []
        if summary.uploadedChunks == 1 {
            values.append(String(localized: "1 backup chunk"))
        } else if summary.uploadedChunks > 1 {
            values.append(
                String(localized: "\(summary.uploadedChunks) backup chunks")
            )
        }
        if summary.uploadedDocuments == 1 {
            values.append(String(localized: "1 personal record"))
        } else if summary.uploadedDocuments > 1 {
            values.append(
                String(localized: "\(summary.uploadedDocuments) personal records")
            )
        }
        if summary.appliedChanges == 1 {
            values.append(String(localized: "1 restored change"))
        } else if summary.appliedChanges > 1 {
            values.append(
                String(localized: "\(summary.appliedChanges) restored changes")
            )
        }
        if summary.prunedRows == 1 {
            values.append(String(localized: "1 validated sensor row freed"))
        } else if summary.prunedRows > 1 {
            values.append(
                String(localized: "\(summary.prunedRows) validated sensor rows freed")
            )
        }
        return ListFormatter.localizedString(byJoining: values)
    }

    private static func erasureStatus(_ status: String) -> String {
        switch status {
        case "queued": return String(localized: "queued")
        case "cooling_off": return String(localized: "cooling off")
        case "running": return String(localized: "running")
        case "verifying": return String(localized: "verifying")
        case "completed": return String(localized: "completed")
        case "failed": return String(localized: "failed")
        case "canceled": return String(localized: "canceled")
        default: return String(localized: "pending")
        }
    }

    private static func normalizedPhone(_ raw: String) throws -> String {
        let phone = raw.filter { !$0.isWhitespace && !"()-.".contains($0) }
        guard phone.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else {
            throw ManagedCloudError.invalidPhone
        }
        return phone
    }

    private static func normalizedCode(_ raw: String) throws -> String {
        let code = raw.filter(\.isNumber)
        guard (4...8).contains(code.count) else { throw ManagedCloudError.invalidCode }
        return code
    }

    private static func maskedPhone(_ phone: String?) -> String {
        guard let phone, phone.count >= 4 else {
            return String(localized: "your phone")
        }
        return "••••\(phone.suffix(4))"
    }

    private static func userMessage(for error: Error) -> String {
        if let managed = error as? ManagedStorageError {
            switch managed {
            case .invalidConfiguration:
                return String(localized: "NOOP+ is not configured in this build.")
            case .invalidAuthorization:
                return String(localized: "Sign in to NOOP+ again.")
            case .invalidResponse:
                return String(localized: "NOOP+ returned an invalid response.")
            case .encoding:
                return String(
                    localized: "NOOP could not prepare the managed-storage request."
                )
            case .decoding:
                return String(
                    localized: "NOOP could not read the managed-storage response."
                )
            case .transport:
                return String(localized: "NOOP+ could not be reached.")
            case .authentication:
                return String(
                    localized: "NOOP+ authentication expired. Sign in again."
                )
            case .forbidden:
                return String(
                    localized: "That action is not allowed by the current Friends permissions or quiet hours."
                )
            case .notFound:
                return String(
                    localized: "The requested NOOP+ resource no longer exists."
                )
            case .policyChanged:
                return String(
                    localized: "The NOOP+ storage policy changed. Review it before syncing."
                )
            case .cursorExpired:
                return String(
                    localized: "This device's cloud cursor expired. A full restore is required."
                )
            case .quotaExceeded:
                return String(localized: "This NOOP+ storage allowance is full.")
            case .conflict:
                return String(localized: "NOOP+ rejected conflicting sync state.")
            case .server:
                return String(localized: "NOOP+ is temporarily unavailable.")
            case .digestMismatch:
                return String(localized: "A cloud object failed its integrity check.")
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(localized: "NOOP+ could not complete that request. Try again.")
    }

    private static let maximumExportPreparationPasses = 256

    private static func managedHistoryExportURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "noop-managed-history-\(formatter.string(from: now)).zip",
            isDirectory: false
        )
    }
}

private enum ManagedCloudError: LocalizedError {
    case invalidPhone
    case invalidCode
    case notSignedIn
    case consentRequired
    case storeUnavailable
    case firebaseProjectConflict
    case exportPreparationIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidPhone:
            return String(
                localized: "Enter a phone number with country code, for example +1 555 123 4567."
            )
        case .invalidCode:
            return String(localized: "Enter the verification code from the text message.")
        case .notSignedIn:
            return String(localized: "Sign in to NOOP+ again.")
        case .consentRequired:
            return String(localized: "Review and allow NOOP+ cloud backup before syncing.")
        case .storeUnavailable:
            return String(localized: "NOOP could not open the local data store.")
        case .firebaseProjectConflict:
            return String(
                localized: "This build contains conflicting NOOP+ identity configuration."
            )
        case .exportPreparationIncomplete:
            return String(
                localized: "NOOP safely paused after a large backup catch-up. Keep the app open, sync again, then retry the complete cloud-history export."
            )
        }
    }
}

private enum ManagedCloudInstallationID {
    private static let service = "com.noop.managed-cloud"
    private static let account = "installation-id-v1"

    static func value() throws -> String {
        if let existing = read() { return existing }
        let created = UUID().uuidString.lowercased()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(created.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = read() {
            return existing
        }
        guard status == errSecSuccess else { throw ManagedStorageError.invalidAuthorization }
        return created
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private enum ManagedCloudInstallationToken {
    private static let service = "com.noop.managed-cloud"
    private static let accountPrefix = "installation-token-v1-"

    static func value(accountScopeHash: String) throws -> String {
        let account = accountPrefix + accountScopeHash
        if let existing = read(account: account) { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ManagedStorageError.invalidAuthorization
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let created = "noopm_" + encoded
        guard created.range(
            of: #"^noopm_[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidAuthorization
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(created.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = read(account: account) {
            return existing
        }
        guard status == errSecSuccess else {
            throw ManagedStorageError.invalidAuthorization
        }
        return created
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              value.range(
                of: #"^noopm_[A-Za-z0-9_-]{43}$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }
}

private enum ManagedCloudSocialInviteSecret {
    private static let service = "com.noop.managed-social-invite"
    private static let accountPrefix = "capability-v1-"

    static func value(accountScopeHash: String) throws -> String {
        let account = accountPrefix + accountScopeHash
        if let existing = read(account: account) { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw ManagedStorageError.invalidAuthorization
        }
        let capability = "noopinvite_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard capability.range(
            of: ManagedSocialIdentifier.invitePattern,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidAuthorization
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(capability.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = read(account: account) {
            return existing
        }
        guard status == errSecSuccess else {
            throw ManagedStorageError.invalidAuthorization
        }
        return capability
    }

    static func clear(accountScopeHash: String) throws {
        let status = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: accountPrefix + accountScopeHash,
            ] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ManagedStorageError.invalidAuthorization
        }
    }

    static func clearAll() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary
        )
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &item
        ) == errSecSuccess,
        let data = item as? Data,
        let value = String(data: data, encoding: .utf8),
        value.range(
            of: ManagedSocialIdentifier.invitePattern,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return value
    }
}

private enum ManagedCloudPendingSocialInviteSecret {
    private static let service = "com.noop.managed-social-pending-invite"
    private static let account = "capability-v1"

    static func value() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              value.range(
                  of: ManagedSocialIdentifier.invitePattern,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    @discardableResult
    static func store(_ capability: String) -> Bool {
        guard capability.range(
            of: ManagedSocialIdentifier.invitePattern,
            options: .regularExpression
        ) != nil else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: Data(capability.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else {
            return false
        }
        return SecItemAdd(
            query.merging(update) { _, replacement in replacement }
                as CFDictionary,
            nil
        ) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary
        )
    }
}
#endif
