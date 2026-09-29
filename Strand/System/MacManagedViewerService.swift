#if os(macOS)
import Combine
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import NoopRemoteSync
import Security
import WhoopStore

struct MacManagedHistoryContinuationSummary: Equatable {
    let batches: Int
    let appliedChanges: Int
    let hasMoreChanges: Bool
    let reachedLimit: Bool
}

@MainActor
enum MacManagedHistoryContinuationRunner {
    static func run(
        initialHasMoreChanges: Bool,
        maxBatches: Int,
        delayNanoseconds: UInt64,
        validate: () async throws -> Void,
        restoreNext: () async throws -> ManagedRestoreOnlyRunResult
    ) async throws -> MacManagedHistoryContinuationSummary {
        guard (1...512).contains(maxBatches) else {
            throw ManagedStorageError.invalidConfiguration
        }

        var batches = 0
        var appliedChanges = 0
        var hasMoreChanges = initialHasMoreChanges
        while hasMoreChanges, batches < maxBatches {
            try Task.checkCancellation()
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            try await validate()
            let result = try await restoreNext()
            batches += 1
            appliedChanges = min(
                10_000,
                appliedChanges + max(0, result.appliedChanges)
            )
            hasMoreChanges = result.hasMoreChanges
        }

        return MacManagedHistoryContinuationSummary(
            batches: batches,
            appliedChanges: appliedChanges,
            hasMoreChanges: hasMoreChanges,
            reachedLimit:
                hasMoreChanges && batches == maxBatches
        )
    }
}

@MainActor
final class MacManagedViewerService: ObservableObject {
    enum Phase: Equatable {
        case unavailable
        case signedOut
        case emailVerificationRequired
        case enrollmentRequired
        case ready
    }

    static let shared = MacManagedViewerService()

    @Published private(set) var phase: Phase
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var socialProfile: ManagedSocialProfile?
    @Published private(set) var socialFriends: [ManagedSocialFriend] = []
    @Published private(set) var socialRequests: [ManagedSocialRequest] = []
    @Published private(set) var socialFeed: [ManagedSocialFeedDay] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var historyLastUpdatedAt: Date?
    @Published private(set) var historyHasMore = false
    @Published private(set) var isHistorySyncing = false

    var isAvailable: Bool { configuration != nil }
    var isWorking: Bool { isBusy || isHistorySyncing }

    var maskedEmail: String {
        guard let email = firebaseRuntime?.auth.currentUser?.email,
              let at = email.firstIndex(of: "@"),
              at != email.startIndex else {
            return ""
        }
        return String(email[email.startIndex]) + "***" + email[at...]
    }

    private enum Key {
        static let accountAccessScopeHash =
            "managedMacViewer.accountAccessScopeHash.v1"
    }

    private static let firebaseAppName = "noop-managed-macos"

    private let defaults: UserDefaults
    private let configuration: MacManagedViewerConfiguration?
    private let credentials: MacManagedViewerCredentialStore
    private var firebaseRuntime: MacManagedFirebaseRuntime?
    private var managedClient: ManagedStorageClient?
    private var historyContinuationTask: Task<Void, Never>?
    private var historyContinuationGeneration: UInt64 = 0

    private static let historyContinuationDelayNanoseconds: UInt64 =
        250_000_000
    private static let maximumAutomaticHistoryContinuationBatches = 256

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        credentials: MacManagedViewerCredentialStore =
            MacManagedViewerCredentialStore()
    ) {
        self.defaults = defaults
        configuration = MacManagedViewerConfiguration.load(bundle: bundle)
        self.credentials = credentials
        phase = configuration == nil ? .unavailable : .signedOut
    }

    func bootstrap(repo: Repository) async {
        guard !isBusy, !isHistorySyncing else { return }
        guard configuration != nil else {
            phase = .unavailable
            status = String(
                localized:
                    "Managed Friends is not configured in this build."
            )
            return
        }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.bootstrap"
        )
        defer { isBusy = false }
        do {
            let runtime = try runtime()
            guard let user = runtime.auth.currentUser else {
                clearPresentation()
                await repo.deactivateManagedViewerStore()
                phase = .signedOut
                status = ""
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "completed",
                    fields: ["state": "signed_out"]
                )
                return
            }
            try await user.reload()
            try await reconcile(
                user: user,
                refreshIfEnrolled: true,
                repo: repo
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["state": diagnosticState]
            )
        } catch {
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func signIn(
        email rawEmail: String,
        password: String,
        repo: Repository
    ) async {
        guard !isBusy, !isHistorySyncing else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.sign_in"
        )
        defer { isBusy = false }
        do {
            let email = try Self.normalizedEmail(rawEmail)
            guard !password.isEmpty, password.count <= 128 else {
                throw MacManagedViewerError.invalidCredentials
            }
            let result = try await runtime().auth.signIn(
                withEmail: email,
                password: password
            )
            try await result.user.reload()
            try await reconcile(
                user: result.user,
                refreshIfEnrolled: true,
                repo: repo
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["state": diagnosticState]
            )
        } catch {
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func checkEmailVerification(repo: Repository) async {
        guard !isBusy, !isHistorySyncing else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.email_verification"
        )
        defer { isBusy = false }
        do {
            let user = try currentUser()
            try await user.reload()
            try await reconcile(
                user: user,
                refreshIfEnrolled: true,
                repo: repo
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["state": diagnosticState]
            )
        } catch {
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func sendPasswordReset(email rawEmail: String) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.password_reset"
        )
        defer { isBusy = false }
        do {
            let email = try Self.normalizedEmail(rawEmail)
            try await runtime().auth.sendPasswordReset(withEmail: email)
            status = String(
                localized:
                    "If the account can receive email, reset instructions were sent."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            status = String(
                localized:
                    "If the account can receive email, reset instructions were sent."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func enroll(repo: Repository) async {
        guard !isBusy,
              !isHistorySyncing,
              phase == .enrollmentRequired else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.enrollment"
        )
        defer { isBusy = false }
        do {
            let user = try currentUser()
            guard user.isEmailVerified else {
                throw MacManagedViewerError.emailVerificationRequired
            }
            let scope = try accountScope(for: user)
            let authorization = try await authorization(
                user: user,
                forceRefresh: true
            )
            let response = try await client().enrollAccount(
                platform: .macOS,
                authorization: authorization,
                requestID: try enrollmentRequestID(
                    scope: scope,
                    installationID: authorization.installationID
                )
            )
            guard response.productBoundary.accountReady,
                  response.productBoundary.edgeCollectionRequired else {
                throw ManagedStorageError.invalidResponse
            }
            defaults.set(
                scope,
                forKey: Key.accountAccessScopeHash
            )
            phase = .ready
            try await loadManagedViewer(user: user, repo: repo)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error, enrollmentFailure: true)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func refresh(repo: Repository) async {
        guard !isBusy,
              !isHistorySyncing,
              phase == .ready else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.viewer_refresh"
        )
        defer { isBusy = false }
        do {
            try await loadManagedViewer(
                user: currentUser(),
                repo: repo
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: [
                    "history_pending":
                        historyHasMore ? "present" : "absent",
                    "profile": socialProfile == nil ? "absent" : "present",
                    "friends": String(socialFriends.count),
                    "requests": String(socialRequests.count),
                    "feed_days": String(socialFeed.count),
                ]
            )
        } catch {
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    func signOut(repo: Repository) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.sign_out"
        )
        defer { isBusy = false }
        cancelHistoryContinuation()
        do {
            try runtime().auth.signOut()
            await repo.deactivateManagedViewerStore()
            clearPresentation()
            phase = configuration == nil ? .unavailable : .signedOut
            status = String(localized: "Signed out of NOOP on this Mac.")
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            await repo.deactivateManagedViewerStore()
            clearPresentation()
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    private func reconcile(
        user: User,
        refreshIfEnrolled: Bool,
        repo: Repository
    ) async throws {
        clearPresentation()
        guard user.isEmailVerified else {
            await repo.deactivateManagedViewerStore()
            phase = .emailVerificationRequired
            status = String(
                localized:
                    "Verify this email address on your phone, then check again."
            )
            return
        }
        let scope = try accountScope(for: user)
        guard hasAccountAccess(scope: scope) else {
            await repo.deactivateManagedViewerStore()
            phase = .enrollmentRequired
            status = String(localized: "Connect this Mac")
            return
        }
        phase = .ready
        if refreshIfEnrolled {
            do {
                try await loadManagedViewer(user: user, repo: repo)
            } catch ManagedStorageError.authentication,
                    ManagedStorageError.forbidden {
                await hideManagedHistory(repo: repo)
                phase = .enrollmentRequired
                status = String(
                    localized:
                        "Reconnect this Mac to restore read-only NOOP access."
                )
            }
        }
    }

    private func loadManagedViewer(
        user: User,
        repo: Repository
    ) async throws {
        let scope = try accountScope(for: user)
        let result = try await restoreManagedHistory(
            user: user,
            repo: repo
        )
        phase = .ready
        status = String(
            localized: result.hasMoreChanges
                ? "History sync"
                : "History synced"
        )
        if result.hasMoreChanges {
            scheduleHistoryContinuation(
                scope: scope,
                repo: repo
            )
        }
        do {
            _ = try await loadManagedFriends(user: user)
            lastUpdatedAt = Date()
        } catch {
            guard !Self.shouldHideManagedHistory(for: error) else {
                throw error
            }
            AppDiagnosticsRecorder.shared.record(
                "managed_macos.friends_refresh",
                fields: [
                    "outcome": "failed",
                    "failure_kind":
                        Self.diagnosticFailureKind(error),
                ]
            )
        }
    }

    private func restoreManagedHistory(
        user: User,
        repo: Repository,
        continuationGeneration: UInt64? = nil
    ) async throws -> ManagedRestoreOnlyRunResult {
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.history_restore"
        )
        do {
            let scope = try accountScope(for: user)
            guard hasAccountAccess(scope: scope) else {
                throw ManagedStorageError.invalidAuthorization
            }
            let store: WhoopStore
            do {
                store = try await repo.activateManagedViewerStore(
                    accountScopeHash: scope
                )
            } catch {
                throw MacManagedViewerError.storeUnavailable
            }
            let authorization = try await authorization(
                user: user,
                forceRefresh: false
            )
            let operationValidator:
                @Sendable () async throws -> Void = { [self] in
                    try await validateHistoryOperation(
                        scope: scope,
                        continuationGeneration: continuationGeneration
                    )
                }
            let coordinator = ManagedSyncCoordinator(
                transport: try client(),
                extractor: WhoopManagedChunkExtractor(store: store),
                state: try WhoopManagedSyncStateStore(
                    store: store,
                    accountScopeHash: scope
                ),
                restore: WhoopManagedRestoreApplier(store: store),
                operationValidator: operationValidator
            )
            let result = try await coordinator.restoreOnly(
                authorization: authorization,
                restoreDocuments: false
            )
            try await operationValidator()
            // Mounting an already-populated account can legitimately produce a
            // zero-delta restore. Always repopulate presentation caches, then
            // revalidate after the suspension before publishing account state.
            try await repo.refreshManagedViewer(
                validateBeforePublication: operationValidator
            )
            try await operationValidator()
            historyLastUpdatedAt = Date()
            historyHasMore = result.hasMoreChanges
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: [
                    "applied_changes":
                        String(min(result.appliedChanges, 10_000)),
                    "continuation":
                        result.hasMoreChanges ? "pending" : "complete",
                ]
            )
            return result
        } catch {
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                ]
            )
            throw error
        }
    }

    private func scheduleHistoryContinuation(
        scope: String,
        repo: Repository
    ) {
        guard historyHasMore,
              phase == .ready,
              historyContinuationTask == nil else { return }

        historyContinuationGeneration &+= 1
        let generation = historyContinuationGeneration
        isHistorySyncing = true
        historyContinuationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runHistoryContinuation(
                scope: scope,
                repo: repo,
                generation: generation
            )
        }
    }

    private func runHistoryContinuation(
        scope: String,
        repo: Repository,
        generation: UInt64
    ) async {
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "managed_macos.history_restore_continuation"
        )
        var outcome = "completed"
        var fields: [String: String] = [:]
        defer {
            if historyContinuationGeneration == generation {
                historyContinuationTask = nil
                isHistorySyncing = false
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: outcome,
                fields: fields
            )
        }

        do {
            guard historyContinuationGeneration == generation else {
                outcome = "canceled"
                fields = ["reason": "superseded"]
                return
            }
            let summary = try await MacManagedHistoryContinuationRunner.run(
                initialHasMoreChanges: true,
                maxBatches:
                    Self.maximumAutomaticHistoryContinuationBatches,
                delayNanoseconds:
                    Self.historyContinuationDelayNanoseconds,
                validate: { [self] in
                    guard historyContinuationGeneration == generation else {
                        throw CancellationError()
                    }
                    try validateAccountOperation(scope: scope)
                    guard phase == .ready else {
                        throw ManagedStorageError.invalidAuthorization
                    }
                },
                restoreNext: { [self] in
                    try await restoreManagedHistory(
                        user: currentUser(),
                        repo: repo,
                        continuationGeneration: generation
                    )
                }
            )
            guard historyContinuationGeneration == generation else {
                outcome = "canceled"
                fields = ["reason": "superseded"]
                return
            }
            fields = [
                "batches":
                    String(
                        min(
                            summary.batches,
                            Self.maximumAutomaticHistoryContinuationBatches
                        )
                    ),
                "applied_changes":
                    String(min(summary.appliedChanges, 10_000)),
                "continuation":
                    summary.hasMoreChanges
                        ? (
                            summary.reachedLimit
                                ? "limit_reached"
                                : "pending"
                        )
                        : "complete",
            ]
            status = String(
                localized: summary.hasMoreChanges
                    ? "History sync"
                    : "History synced"
            )
        } catch is CancellationError {
            outcome = "canceled"
        } catch {
            guard historyContinuationGeneration == generation else {
                outcome = "canceled"
                fields = ["reason": "superseded"]
                return
            }
            outcome = Self.diagnosticOutcome(error)
            fields = [
                "failure_kind": Self.diagnosticFailureKind(error),
            ]
            if Self.shouldHideManagedHistory(for: error) {
                await hideManagedHistory(repo: repo)
            }
            applyFailure(error)
        }
    }

    private func cancelHistoryContinuation() {
        historyContinuationGeneration &+= 1
        historyContinuationTask?.cancel()
        historyContinuationTask = nil
        isHistorySyncing = false
    }

    private func loadManagedFriends(user: User) async throws -> Bool {
        let authorization = try await authorization(
            user: user,
            forceRefresh: false
        )
        let managedClient = try client()
        let profile: ManagedSocialProfile
        do {
            profile = try await managedClient.socialProfile(
                authorization: authorization
            )
        } catch ManagedStorageError.notFound {
            clearSocialPresentation()
            return false
        }

        let range = Self.socialFeedRange()
        async let loadedFriends = managedClient.socialFriends(
            authorization: authorization
        )
        async let loadedRequests = managedClient.socialRequests(
            authorization: authorization
        )
        async let loadedFeed = managedClient.socialFeed(
            startDay: range.start,
            endDay: range.end,
            authorization: authorization
        )
        let (nextFriends, nextRequests, nextFeed) = try await (
            loadedFriends,
            loadedRequests,
            loadedFeed
        )
        socialProfile = profile
        socialFriends = nextFriends
        socialRequests = nextRequests
        socialFeed = nextFeed.sorted { lhs, rhs in
            if lhs.day == rhs.day {
                return lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                ) == .orderedAscending
            }
            return lhs.day > rhs.day
        }
        return true
    }

    private func authorization(
        user: User,
        forceRefresh: Bool
    ) async throws -> ManagedAuthorization {
        let runtime = try runtime()
        let scope = try accountScope(for: user)
        async let identityToken = user.getIDToken(
            forcingRefresh: forceRefresh
        )
        async let appCheckToken = Self.appCheckToken(
            runtime.appCheck,
            forceRefresh: forceRefresh
        )
        return try await ManagedAuthorization(
            identityToken: identityToken,
            appCheckToken: appCheckToken,
            installationID: ManagedAccountIdentifier.installationID(
                baseInstallationID: try credentials.installationID(),
                accountScopeHash: scope
            ),
            installationToken: try credentials.installationToken(
                accountScopeHash: scope
            )
        )
    }

    private func runtime() throws -> MacManagedFirebaseRuntime {
        if let firebaseRuntime { return firebaseRuntime }
        guard let configuration else {
            throw MacManagedViewerError.unavailable
        }
        let app: FirebaseApp
        if let existing = FirebaseApp.app(name: Self.firebaseAppName) {
            guard existing.options.projectID == configuration.projectID,
                  existing.options.googleAppID
                    == configuration.googleAppID else {
                throw MacManagedViewerError.firebaseProjectConflict
            }
            app = existing
        } else {
            #if DEBUG
            AppCheck.setAppCheckProviderFactory(
                AppCheckDebugProviderFactory()
            )
            #else
            AppCheck.setAppCheckProviderFactory(
                AppAttestProviderFactory()
            )
            #endif
            let options = FirebaseOptions(
                googleAppID: configuration.googleAppID,
                gcmSenderID: configuration.gcmSenderID
            )
            options.apiKey = configuration.apiKey
            options.projectID = configuration.projectID
            options.bundleID = Bundle.main.bundleIdentifier ?? options.bundleID
            FirebaseApp.configure(
                name: Self.firebaseAppName,
                options: options
            )
            guard let configured = FirebaseApp.app(
                name: Self.firebaseAppName
            ) else {
                throw MacManagedViewerError.unavailable
            }
            app = configured
        }
        guard let appCheck = AppCheck.appCheck(app: app) else {
            throw MacManagedViewerError.unavailable
        }
        let created = MacManagedFirebaseRuntime(
            auth: Auth.auth(app: app),
            appCheck: appCheck
        )
        firebaseRuntime = created
        return created
    }

    private func client() throws -> ManagedStorageClient {
        if let managedClient { return managedClient }
        guard let configuration else {
            throw MacManagedViewerError.unavailable
        }
        let created = ManagedStorageClient(
            configuration: configuration.storage,
            requestObserver: { diagnostic in
                var fields = [
                    "target": diagnostic.target,
                    "route_group": diagnostic.routeGroup,
                    "method": diagnostic.method,
                    "duration_ms":
                        String(diagnostic.durationMilliseconds),
                    "outcome": diagnostic.outcome,
                ]
                if let statusCode = diagnostic.statusCode {
                    fields["status_code"] = String(statusCode)
                }
                AppDiagnosticsRecorder.shared.record(
                    "managed_http.request",
                    fields: fields
                )
            }
        )
        managedClient = created
        return created
    }

    private func currentUser() throws -> User {
        guard let user = try runtime().auth.currentUser else {
            throw MacManagedViewerError.notSignedIn
        }
        return user
    }

    private func accountScope(for user: User) throws -> String {
        guard let configuration,
              try runtime().auth.tenantID == user.tenantID else {
            throw ManagedStorageError.invalidAuthorization
        }
        return try ManagedAccountScope.resolve(
            projectID: configuration.projectID,
            tenantID: user.tenantID,
            uid: user.uid,
            enrolledDataScopeHash: nil,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        ).dataScopeHash
    }

    private func hasAccountAccess(scope: String) -> Bool {
        defaults.string(forKey: Key.accountAccessScopeHash) == scope
    }

    private func validateAccountOperation(scope: String) throws {
        let user = try currentUser()
        guard hasAccountAccess(scope: scope),
              try accountScope(for: user) == scope else {
            throw ManagedStorageError.invalidAuthorization
        }
    }

    private func validateHistoryOperation(
        scope: String,
        continuationGeneration: UInt64?
    ) throws {
        try Task.checkCancellation()
        if let continuationGeneration {
            guard historyContinuationGeneration == continuationGeneration,
                  phase == .ready else {
                throw CancellationError()
            }
        }
        try validateAccountOperation(scope: scope)
    }

    private func enrollmentRequestID(
        scope: String,
        installationID: String
    ) throws -> UUID {
        return ManagedStableIdentifier.uuid(
            seed: Data(
                "noop-managed-macos-account-enrollment-v1\0"
                    .appending(scope)
                    .appending("\0")
                    .appending(installationID)
                    .utf8
            )
        )
    }

    private func clearPresentation() {
        cancelHistoryContinuation()
        clearSocialPresentation()
        historyLastUpdatedAt = nil
        historyHasMore = false
        lastUpdatedAt = nil
    }

    /// Invalidate continuation work before the store switch suspends. Otherwise
    /// an already-running continuation can remount the account store while
    /// deactivation is refreshing the local store.
    private func hideManagedHistory(repo: Repository) async {
        let wasBusy = isBusy
        isBusy = true
        defer { isBusy = wasBusy }
        clearPresentation()
        await repo.deactivateManagedViewerStore()
    }

    static func shouldHideManagedHistory(
        for error: Error
    ) -> Bool {
        if let viewer = error as? MacManagedViewerError {
            switch viewer {
            case .unavailable, .emailVerificationRequired, .notSignedIn,
                    .secureStorage, .firebaseProjectConflict:
                return true
            case .invalidCredentials, .storeUnavailable:
                return false
            }
        }
        if let storage = error as? ManagedStorageError {
            switch storage {
            case .invalidConfiguration, .invalidAuthorization,
                    .authentication, .forbidden, .policyChanged:
                return true
            default:
                return false
            }
        }
        if terminalFirebaseAuthenticationLoss(error) {
            return true
        }
        return false
    }

    static func terminalFirebaseAuthenticationLoss(
        _ error: Error
    ) -> Bool {
        let value = error as NSError
        guard value.domain == AuthErrors.domain,
              let code = AuthErrorCode(rawValue: value.code) else {
            return false
        }
        switch code {
        case .invalidUserToken, .userTokenExpired, .userDisabled,
                .userNotFound:
            return true
        default:
            return false
        }
    }

    private func clearSocialPresentation() {
        socialProfile = nil
        socialFriends = []
        socialRequests = []
        socialFeed = []
    }

    private func applyFailure(
        _ error: Error,
        enrollmentFailure: Bool = false
    ) {
        if Self.shouldHideManagedHistory(for: error) {
            clearPresentation()
        }
        if let viewerError = error as? MacManagedViewerError {
            switch viewerError {
            case .emailVerificationRequired:
                phase = .emailVerificationRequired
            case .notSignedIn:
                clearPresentation()
                phase = .signedOut
            case .unavailable, .firebaseProjectConflict:
                phase = .unavailable
            case .invalidCredentials, .secureStorage, .storeUnavailable:
                break
            }
        } else if let storage = error as? ManagedStorageError {
            switch storage {
            case .authentication, .forbidden:
                phase = .enrollmentRequired
            case .invalidConfiguration:
                phase = .unavailable
            default:
                break
            }
        } else if Self.terminalFirebaseAuthenticationLoss(error) {
            try? firebaseRuntime?.auth.signOut()
            phase = .signedOut
        }
        if enrollmentFailure, phase == .ready {
            phase = .enrollmentRequired
        }
        status = Self.userMessage(for: error)
    }

    private var diagnosticState: String {
        switch phase {
        case .unavailable: return "unavailable"
        case .signedOut: return "signed_out"
        case .emailVerificationRequired: return "verification_required"
        case .enrollmentRequired: return "enrollment_required"
        case .ready: return "ready"
        }
    }

    private static func socialFeedRange(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: String, end: String) {
        let endDate = calendar.startOfDay(for: now)
        let startDate = calendar.date(
            byAdding: .day,
            value: -6,
            to: endDate
        ) ?? endDate
        return (
            storageDay(startDate, calendar: calendar),
            storageDay(endDate, calendar: calendar)
        )
    }

    private static func storageDay(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents(
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

    private static func appCheckToken(
        _ appCheck: AppCheck,
        forceRefresh: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            appCheck.token(forcingRefresh: forceRefresh) { token, error in
                if let value = token?.token, !value.isEmpty {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(
                        throwing:
                            error ?? ManagedStorageError.authentication
                    )
                }
            }
        }
    }

    private static func normalizedEmail(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254,
              value.range(
                of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
                options: .regularExpression
              ) != nil else {
            throw MacManagedViewerError.invalidCredentials
        }
        return value
    }

    private static func userMessage(for error: Error) -> String {
        if let value = error as? MacManagedViewerError {
            switch value {
            case .unavailable, .firebaseProjectConflict:
                return String(
                    localized:
                        "Managed Friends is not available in this build."
                )
            case .invalidCredentials:
                return String(
                    localized:
                        "Enter the email and password used by your NOOP account."
                )
            case .emailVerificationRequired:
                return String(
                    localized:
                        "Verify this email address on your phone, then check again."
                )
            case .notSignedIn:
                return String(localized: "Sign in to NOOP again.")
            case .secureStorage:
                return String(
                    localized:
                        "This Mac could not securely store its viewer credential."
                )
            case .storeUnavailable:
                return String(
                    localized:
                        "NOOP could not open its local history on this Mac."
                )
            }
        }
        if let value = error as? ManagedStorageError {
            if case .server(let status, _) = value, status == 503 {
                return String(
                    localized:
                        "The managed Mac viewer is not enabled on the server yet."
                )
            }
            return value.errorDescription
                ?? String(localized: "NOOP could not update this Mac.")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return String(
                localized:
                    "NOOP could not reach the managed service. Check the connection and retry."
            )
        }
        if nsError.domain == AuthErrors.domain {
            if terminalFirebaseAuthenticationLoss(error) {
                return String(localized: "Sign in to NOOP again.")
            }
            return String(
                localized:
                    "NOOP could not sign in. Check the account details and retry."
            )
        }
        return String(localized: "NOOP could not update this Mac.")
    }

    private static func diagnosticOutcome(_ error: Error) -> String {
        if error is CancellationError { return "canceled" }
        if let refresh = error as? RepositoryRefreshError {
            switch refresh {
            case .managedViewerInactive:
                return "rejected"
            case .superseded, .storeChanged:
                return "canceled"
            case .storeUnavailable, .sourceIndexUnavailable, .readFailed:
                return "failed"
            }
        }
        if let value = error as? MacManagedViewerError {
            switch value {
            case .storeUnavailable:
                return "failed"
            default:
                return "rejected"
            }
        }
        if let storage = error as? ManagedStorageError {
            switch storage {
            case .authentication, .forbidden, .policyChanged, .conflict,
                 .documentConflict:
                return "rejected"
            default:
                return "failed"
            }
        }
        if terminalFirebaseAuthenticationLoss(error) {
            return "rejected"
        }
        return "failed"
    }

    private static func diagnosticFailureKind(_ error: Error) -> String {
        if error is CancellationError { return "canceled" }
        if let refresh = error as? RepositoryRefreshError {
            switch refresh {
            case .managedViewerInactive: return "viewer_inactive"
            case .storeUnavailable: return "store"
            case .storeChanged: return "store_changed"
            case .sourceIndexUnavailable: return "source_index"
            case .readFailed: return "store_read"
            case .superseded: return "superseded"
            }
        }
        if let value = error as? MacManagedViewerError {
            switch value {
            case .unavailable: return "configuration"
            case .invalidCredentials: return "credentials"
            case .emailVerificationRequired: return "verification"
            case .notSignedIn: return "authentication"
            case .secureStorage: return "secure_storage"
            case .storeUnavailable: return "store"
            case .firebaseProjectConflict: return "configuration_conflict"
            }
        }
        if let value = error as? ManagedStorageError {
            switch value {
            case .invalidConfiguration: return "configuration"
            case .invalidAuthorization: return "authorization"
            case .invalidResponse, .decoding: return "response"
            case .encoding: return "request_encoding"
            case .transport: return "network"
            case .authentication: return "authentication"
            case .forbidden: return "forbidden"
            case .notFound: return "not_found"
            case .policyChanged: return "policy"
            case .cursorExpired: return "cursor"
            case .quotaExceeded: return "quota"
            case .conflict: return "conflict"
            case .documentConflict: return "document_conflict"
            case .server: return "server"
            case .digestMismatch: return "integrity"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "network" }
        if nsError.domain == AuthErrors.domain {
            switch AuthErrorCode(rawValue: nsError.code) {
            case .networkError: return "network"
            case .tooManyRequests: return "rate_limit"
            case .invalidUserToken, .userTokenExpired:
                return "authentication"
            case .userDisabled: return "identity_disabled"
            case .invalidEmail, .wrongPassword, .userNotFound,
                    .invalidCredential:
                return "credentials"
            default: return "identity_provider"
            }
        }
        return "unknown"
    }
}

struct MacManagedViewerConfiguration {
    let storage: ManagedStorageConfiguration
    let projectID: String
    let apiKey: String
    let googleAppID: String
    let gcmSenderID: String

    static func load(bundle: Bundle) -> Self? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(
                forInfoDictionaryKey: key
            ) as? String else {
                return nil
            }
            let value = raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty || value.contains("$(") ? nil : value
        }

        guard let projectID = value("NOOPManagedProjectID"),
              let apiKey = value("NOOPManagedAPIKey"),
              let googleAppID = value("NOOPManagedGoogleAppID"),
              let gcmSenderID = value("NOOPManagedGCMSenderID"),
              let api = value("NOOPManagedAPIURL"),
              let baseURL = URL(string: api),
              let policyVersion = value("NOOPManagedPolicyVersion"),
              let policySHA256 = value("NOOPManagedPolicySHA256"),
              !apiKey.isEmpty,
              googleAppID.range(
                of: #"^1:[0-9]+:ios:[0-9a-f]+$"#,
                options: .regularExpression
              ) != nil,
              gcmSenderID.range(
                of: #"^[0-9]{6,20}$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        let allowLocalHTTP: Bool
        #if DEBUG
        if let flag = bundle.object(
            forInfoDictionaryKey: "NOOPManagedAllowLocalHTTP"
        ) as? NSNumber {
            allowLocalHTTP = flag.boolValue
        } else {
            allowLocalHTTP = value("NOOPManagedAllowLocalHTTP").map {
                ["1", "true", "yes"].contains($0.lowercased())
            } ?? false
        }
        #else
        allowLocalHTTP = false
        #endif
        guard let storage = try? ManagedStorageConfiguration(
            baseURL: baseURL,
            policyVersion: policyVersion,
            policySHA256: policySHA256,
            allowLocalHTTP: allowLocalHTTP
        ) else {
            return nil
        }
        return Self(
            storage: storage,
            projectID: projectID,
            apiKey: apiKey,
            googleAppID: googleAppID,
            gcmSenderID: gcmSenderID
        )
    }
}

private struct MacManagedFirebaseRuntime {
    let auth: Auth
    let appCheck: AppCheck
}

enum MacManagedViewerError: Error {
    case unavailable
    case invalidCredentials
    case emailVerificationRequired
    case notSignedIn
    case secureStorage
    case storeUnavailable
    case firebaseProjectConflict
}

struct MacManagedViewerCredentialStore {
    private static let service = "com.noop.managed-macos-viewer"
    private static let installationIDAccount = "installation-id-v1"
    private static let installationTokenPrefix = "installation-token-v1-"

    func installationID() throws -> String {
        if let existing = read(account: Self.installationIDAccount),
           existing.range(
               of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
               options: .regularExpression
           ) != nil {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        return try addOrRead(
            created,
            account: Self.installationIDAccount
        )
    }

    func installationToken(accountScopeHash: String) throws -> String {
        let account = Self.installationTokenPrefix + accountScopeHash
        if let existing = read(account: account),
           existing.range(
               of: #"^noopm_[A-Za-z0-9_-]{43}$"#,
               options: .regularExpression
           ) != nil {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw MacManagedViewerError.secureStorage
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let created = "noopm_" + encoded
        return try addOrRead(created, account: account)
    }

    private func addOrRead(
        _ value: String,
        account: String
    ) throws -> String {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem,
           let existing = read(account: account) {
            return existing
        }
        guard status == errSecSuccess else {
            throw MacManagedViewerError.secureStorage
        }
        return value
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
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
        !value.isEmpty else {
            return nil
        }
        return value
    }
}
#endif
