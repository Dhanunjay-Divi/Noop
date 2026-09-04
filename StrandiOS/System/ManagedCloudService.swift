#if os(iOS)
import Combine
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import NoopRemoteSync
import Security
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
    }

    private static let automaticInterval: TimeInterval = 15 * 60
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

    private init(bundle: Bundle = .main) {
        configuration = Self.loadConfiguration(bundle: bundle)
        status = defaults.string(forKey: Key.lastStatus) ?? ""
        let success = defaults.double(forKey: Key.lastSuccess)
        lastSuccessAt = success > 0 ? Date(timeIntervalSince1970: success) : nil
        deletionNotBefore = defaults.string(forKey: Key.erasureNotBefore)
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
        do {
            try configureFirebaseIfNeeded()
            let phone = try Self.normalizedPhone(rawPhoneNumber)
            verificationID = try await PhoneAuthProvider.provider(auth: Auth.auth())
                .verifyPhoneNumber(phone, uiDelegate: nil)
            phase = .codeSent
            setStatus(String(localized: "A verification code was sent."))
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func verifyCode(_ rawCode: String) async {
        guard !isBusy, let verificationID else {
            setStatus(String(localized: "Request a new verification code."))
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
        } catch {
            setStatus(Self.userMessage(for: error))
        }
    }

    func enroll(repo: Repository) async {
        guard !isBusy, configuration != nil else { return }
        isBusy = true
        defer { isBusy = false }
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
        } catch {
            if Auth.auth().currentUser != nil {
                phase = .consentRequired
            }
            setStatus(Self.userMessage(for: error))
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
            AppDiagnosticsRecorder.shared.record(
                "managed_export.end",
                fields: [
                    "outcome": "completed",
                    "objects": String(manifest.exportedObjects),
                    "chunk_bytes": String(manifest.exportedChunkBytes),
                ]
            )
            return url
        } catch is CancellationError {
            if let writer { await writer.cancel() }
            setStatus(String(localized: "Cloud-history export was canceled."))
            AppDiagnosticsRecorder.shared.record(
                "managed_export.end",
                fields: ["outcome": "canceled"]
            )
            return nil
        } catch {
            if let writer { await writer.cancel() }
            setStatus(Self.userMessage(for: error))
            AppDiagnosticsRecorder.shared.record(
                "managed_export.end",
                fields: ["outcome": "failed"]
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

    @discardableResult
    func catchUpIfDue(repo: Repository) async -> Bool {
        if !firebaseConfigured {
            bootstrap()
        }
        guard phase == .enrolled,
              automatic,
              !isBusy,
              !running else { return true }
        let continuationPending = defaults.bool(
            forKey: Key.continuationPending
        )
        let lastAttempt = defaults.double(forKey: Key.lastAttempt)
        guard continuationPending
                || Date().timeIntervalSince1970 - lastAttempt >= Self.automaticInterval else {
            return true
        }
        do {
            let summary = try await sync(repo: repo, mode: .automatic)
            scheduleContinuationIfNeeded(summary)
            return !summary.hasMore
        } catch {
            setStatus(Self.userMessage(for: error))
            return false
        }
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

    // MARK: - Sync composition

    private enum SyncMode {
        case manual
        case automatic
        case exportPreparation
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
        AppDiagnosticsRecorder.shared.record("managed_sync.begin")

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
        AppDiagnosticsRecorder.shared.record(
            "managed_sync.end",
            fields: [
                "outcome": "completed",
                "uploaded_chunks": String(summary.uploadedChunks),
                "uploaded_documents": String(summary.uploadedDocuments),
                "applied_changes": String(summary.appliedChanges),
                "pruned_rows": String(summary.prunedRows),
                "continuation_pending": summary.hasMore ? "true" : "false",
            ]
        )
        if summary.appliedChanges > 0 {
            await repo.refresh()
        }
        return summary
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
        let localPruneBeforeMs = optimizePhoneStorage && mode != .exportPreparation
            ? ManagedLocalRetentionPolicy.cutoff(
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            )
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
                localPruneBeforeMs: localPruneBeforeMs,
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
        return ManagedStorageClient(configuration: configuration)
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
        deletionNotBefore = nil
        overview = nil
        installations = []
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
            policySHA256: digest
        )
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
#endif
