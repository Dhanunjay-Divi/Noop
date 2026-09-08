#if os(iOS)
import Combine
import CryptoKit
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import Security

let noopOwnershipFirebaseAppName = "noop-ownership"

struct OwnershipTermsDocument: Equatable {
    let policyVersion: String
    let locale: String
    let sha256: String
    let sourceURL: URL
    let text: String
}

struct OwnershipAccountOverview: Equatable {
    let accountState: String
    let emailVerified: Bool
    let phoneVerified: Bool
    let bandState: String
    let activeInstallations: Int
    let plan: NoopProductPlan
    let noopPlusEntitled: Bool
}

private struct OwnershipBootstrapStatus: Equatable {
    let accountState: String
    let bandState: String
    let replacementAuthorizationRequired: Bool
    let termsAcceptanceRequired: Bool
}

struct OwnershipInstallation: Identifiable, Equatable {
    let id: String
    let platform: String
    let status: String
    let current: Bool
    let registeredAt: String
    let lastSeenAt: String
}

@MainActor
final class OwnershipService: ObservableObject {
    static let shared = OwnershipService()

    @Published private(set) var phase: OwnershipServicePhase = .unavailable
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var terms: OwnershipTermsDocument?
    @Published private(set) var overview: OwnershipAccountOverview?
    @Published private(set) var installations: [OwnershipInstallation] = []

    var isAvailable: Bool { configuration != nil }
    var possessionAvailable: Bool { possessionProvider.isAvailable }
    var maskedEmail: String {
        guard let value = try? runtime().auth.currentUser?.email else { return "" }
        return Self.maskedEmail(value)
    }

    private let configuration: OwnershipConfiguration?
    private let secureStore: OwnershipSecureStore
    private let possessionProvider: any OwnershipBandPossessionProviding
    private var firebaseRuntime: OwnershipFirebaseRuntime?
    private var ownershipClient: OwnershipAPIClient?
    private var verificationID: String?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapGeneration: UInt64 = 0
    private var bootstrapBusyGeneration: UInt64?

    init(
        bundle: Bundle = .main,
        secureStore: OwnershipSecureStore = OwnershipSecureStore(),
        possessionProvider: any OwnershipBandPossessionProviding =
            UnavailableOwnershipBandPossessionProvider()
    ) {
        configuration = OwnershipConfiguration.load(bundle: bundle)
        self.secureStore = secureStore
        self.possessionProvider = possessionProvider
        phase = configuration == nil ? .unavailable : .signedOut
    }

    func bootstrap() {
        guard configuration != nil else {
            phase = .unavailable
            status = String(
                localized: "Band ownership setup is not enabled in this build."
            )
            return
        }
        guard !isBusy || bootstrapBusyGeneration != nil else { return }
        let generation = invalidateBootstrapReconciliation()
        do {
            let runtime = try runtime()
            guard let user = runtime.auth.currentUser else {
                phase = .signedOut
                return
            }
            let checkpoint = try checkpoint(for: user)
            reconcileLocal(user: user, checkpoint: checkpoint)
            isBusy = true
            bootstrapBusyGeneration = generation
            bootstrapTask = Task { [weak self] in
                await self?.reconcileRemote(
                    user: user,
                    generation: generation
                )
            }
        } catch {
            phase = Self.isSecureStorage(error)
                ? .localRecoveryRequired
                : .unavailable
            if phase == .localRecoveryRequired {
                terms = nil
                overview = nil
                installations = []
            }
            status = Self.userMessage(for: error)
        }
    }

    func createAccount(
        email rawEmail: String,
        password: String,
        confirmation: String,
        acceptedTerms: Bool
    ) async {
        guard beginBusy(operation: "ownership.identity.create") != nil else { return }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.identity.create"
        )
        var accountCreated = false
        defer { isBusy = false }
        do {
            guard acceptedTerms, let terms else {
                throw OwnershipClientError.termsRequired
            }
            let email = try Self.normalizedEmail(rawEmail)
            try Self.validatePassword(password, confirmation: confirmation)
            let runtime = try runtime()
            let result = try await runtime.auth.createUser(
                withEmail: email,
                password: password
            )
            accountCreated = true
            phase = .emailVerification
            var checkpoint = try checkpoint(for: result.user)
            try checkpoint.captureAcceptedTerms(
                policyVersion: terms.policyVersion,
                sha256: terms.sha256,
                locale: terms.locale
            )
            try save(checkpoint, for: result.user)
            try await result.user.sendEmailVerification()
            status = String(
                localized: "Check your email, verify the address, then return to continue."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            if Self.isSecureStorage(error) {
                phase = .localRecoveryRequired
            }
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: accountCreated
                    ? "partial"
                    : Self.diagnosticOutcome(error),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(error),
                    "progress": accountCreated
                        ? "identity_created"
                        : "not_created",
                ]
            )
        }
    }

    func signIn(email rawEmail: String, password: String) async {
        guard beginBusy(operation: "ownership.identity.sign_in") != nil else { return }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.identity.sign_in"
        )
        defer { isBusy = false }
        do {
            let email = try Self.normalizedEmail(rawEmail)
            guard !password.isEmpty, password.count <= 128 else {
                throw OwnershipClientError.invalidCredentials
            }
            let result = try await runtime().auth.signIn(
                withEmail: email,
                password: password
            )
            try await result.user.reload()
            let checkpoint = try checkpoint(for: result.user)
            reconcileLocal(user: result.user, checkpoint: checkpoint)
            invalidateBootstrapReconciliation()
            if result.user.isEmailVerified {
                await reconcileRemote(user: result.user)
                if status.isEmpty {
                    status = String(
                        localized: "Signed in. Continue band activation."
                    )
                }
            } else {
                status = String(
                    localized: "Verify your email address before continuing."
                )
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            if Self.isSecureStorage(error) {
                phase = .localRecoveryRequired
            }
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func resendEmailVerification() async {
        await performIdentityOperation(
            name: "ownership.identity.resend_verification"
        ) { user in
            try await user.sendEmailVerification()
            self.phase = .emailVerification
            self.status = String(
                localized: "A new verification email was requested."
            )
        }
    }

    func checkEmailVerification() async {
        await performIdentityOperation(
            name: "ownership.identity.refresh_verification"
        ) { user in
            try await user.reload()
            guard user.isEmailVerified else {
                self.phase = .emailVerification
                self.status = String(
                    localized: "Email verification is still pending."
                )
                return
            }
            var checkpoint = try self.checkpoint(for: user)
            checkpoint.stage = checkpoint.hasAcceptedTerms
                ? .accountRegistration
                : .termsReview
            try self.save(checkpoint, for: user)
            if checkpoint.hasAcceptedTerms {
                await self.reconcileRemote(user: user)
                if self.phase == .accountReady
                    || self.phase == .possessionUnavailable {
                    self.status = String(
                        localized: "Email verified. Continue band activation."
                    )
                }
            } else {
                self.phase = .termsReview
                self.status = String(
                    localized: "Email verified. Review the ownership terms."
                )
            }
        }
    }

    func sendPasswordReset(email rawEmail: String) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.identity.password_reset"
        )
        defer { isBusy = false }
        do {
            let email = try Self.normalizedEmail(rawEmail)
            try await runtime().auth.sendPasswordReset(withEmail: email)
            status = String(
                localized: "If the account can receive email, reset instructions were sent."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            status = String(
                localized: "If the account can receive email, reset instructions were sent."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func sendPhoneCode(to rawPhone: String) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.identity.phone_send"
        )
        defer { isBusy = false }
        do {
            let phone = try Self.normalizedPhone(rawPhone)
            let runtime = try runtime()
            guard runtime.auth.currentUser?.isEmailVerified == true else {
                throw OwnershipClientError.emailVerificationRequired
            }
            verificationID = try await PhoneAuthProvider.provider(
                auth: runtime.auth
            ).verifyPhoneNumber(phone, uiDelegate: nil)
            guard let verificationID else {
                throw OwnershipClientError.invalidResponse
            }
            try secureStore.writePhoneVerificationID(
                verificationID,
                scope: try accountScope()
            )
            status = String(localized: "A verification code was sent.")
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            if Self.isSecureStorage(error) {
                phase = .localRecoveryRequired
            }
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func linkPhone(code rawCode: String) async {
        await performIdentityOperation(
            name: "ownership.identity.phone_link"
        ) { user in
            let code = try Self.normalizedCode(rawCode)
            let scope = try self.accountScope()
            let identifier = try self.verificationID
                ?? self.secureStore.readPhoneVerificationID(scope: scope)
            guard let identifier else {
                throw OwnershipClientError.phoneCodeRequired
            }
            let credential = PhoneAuthProvider.provider(
                auth: try self.runtime().auth
            ).credential(
                withVerificationID: identifier,
                verificationCode: code
            )
            _ = try await user.link(with: credential)
            self.verificationID = nil
            if !self.secureStore.deletePhoneVerificationID(scope: scope) {
                AppDiagnosticsRecorder.shared.record(
                    "ownership.lifecycle",
                    fields: [
                        "phase": "phone_verification_cleanup",
                        "outcome": "deferred",
                    ]
                )
            }
            try await self.loadOverview(forceRefresh: true)
            self.status = String(localized: "Optional mobile number verified.")
        }
    }

    func loadTerms(forAccountCreation: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.terms.fetch"
        )
        defer { isBusy = false }
        do {
            let client = try client()
            let locale = Self.preferredLocale()
            let manifest = try await client.currentTerms(locale: locale)
            let document = try await client.fetchTermsDocument(manifest)
            terms = document
            phase = forAccountCreation ? .signedOut : .termsReview
            status = String(
                localized: "Review the complete ownership terms before agreeing."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            terms = nil
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func acceptTermsAndRegister() async {
        guard !isBusy else { return }
        isBusy = true
        phase = .registering
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.account.register"
        )
        defer { isBusy = false }
        do {
            guard let terms else { throw OwnershipClientError.termsRequired }
            let runtime = try runtime()
            let user = try currentUser(runtime)
            try await user.reload()
            guard user.isEmailVerified else {
                throw OwnershipClientError.emailVerificationRequired
            }
            var checkpoint = try self.checkpoint(for: user)
            try checkpoint.acceptTerms(
                policyVersion: terms.policyVersion,
                sha256: terms.sha256,
                locale: terms.locale
            )
            try save(checkpoint, for: user)
            try await completeTermsAcceptance(
                user: user,
                checkpoint: &checkpoint,
                policyVersion: terms.policyVersion,
                policySHA256: terms.sha256,
                locale: terms.locale
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: overview?.bandState == "claimed"
                    ? "resumed"
                    : "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            let reportedError = reconcileChangedTerms(error)
            phase = ownershipFailureRecoveryPhase(
                phase,
                termsChanged: Self.isTermsChanged(reportedError),
                secureStorageFailed: Self.isSecureStorage(reportedError)
            )
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    func claimBand() async {
        guard !isBusy else { return }
        guard possessionProvider.isAvailable else {
            phase = .possessionUnavailable
            status = String(
                localized: "Band confirmation is unavailable until the approved NOOP Band SDK is installed."
            )
            AppDiagnosticsRecorder.shared.record(
                "ownership.lifecycle",
                fields: ["phase": "claim", "outcome": "provider_unavailable"]
            )
            return
        }
        isBusy = true
        phase = .claiming
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.band.claim"
        )
        defer { isBusy = false }
        do {
            let user = try currentUser(try runtime())
            var checkpoint = try self.checkpoint(for: user)
            if checkpoint.stage == .claimPending {
                guard try await reconcilePendingClaim(
                    user: user,
                    checkpoint: &checkpoint
                ) == false else {
                    AppDiagnosticsRecorder.shared.endOperation(
                        diagnostic,
                        outcome: "reconciled"
                    )
                    return
                }
            }
            checkpoint.beginClaimAttempt()
            try save(checkpoint, for: user)
            let authorization = try await authorization(forceRefresh: true)
            let client = try client()
            let challenge = try await client.createChallenge(
                requestID: UUID(),
                appCheckToken: authorization.appCheckToken
            )
            let response = try await possessionProvider.response(
                for: challenge.challenge
            )
            try await client.claim(
                requestID: checkpoint.claimRequestID,
                challenge: challenge,
                possessionResponse: response,
                authorization: authorization
            )
            overview = try await client.overview(authorization: authorization)
            checkpoint.reconcileClaim(claimed: true)
            try save(checkpoint, for: user)
            phase = .claimed
            status = String(localized: "Band ownership confirmed.")
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            if let user = try? currentUser(try runtime()),
               var checkpoint = try? self.checkpoint(for: user),
               checkpoint.stage == .claimPending,
               let reconciled = try? await reconcilePendingClaim(
                   user: user,
                   checkpoint: &checkpoint
               ),
               reconciled {
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "reconciled"
                )
                return
            }
            let reportedError = reconcileChangedTerms(error)
            if case OwnershipClientError.termsChanged = reportedError {
                phase = .termsReview
            } else if Self.isSecureStorage(reportedError) {
                phase = .localRecoveryRequired
            } else {
                phase = possessionProvider.isAvailable
                    ? .accountReady
                    : .possessionUnavailable
            }
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    func authorizeReplacementPhone() async {
        guard !isBusy else { return }
        guard possessionProvider.isAvailable else {
            phase = .replacementRequired
            status = String(
                localized: "Replacement-phone authorization is ready, but physical confirmation remains locked until the approved band SDK supplies signed possession proof."
            )
            AppDiagnosticsRecorder.shared.record(
                "ownership.lifecycle",
                fields: [
                    "phase": "installation_authorize",
                    "outcome": "provider_unavailable",
                ]
            )
            return
        }
        isBusy = true
        phase = .authorizingReplacement
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.installation.authorize"
        )
        defer { isBusy = false }
        do {
            let user = try currentUser(try runtime())
            var checkpoint = try self.checkpoint(for: user)
            if checkpoint.stage == .replacementPending,
               try await reconcilePendingReplacement(
                   user: user,
                   checkpoint: &checkpoint
               ) {
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "reconciled"
                )
                return
            }
            if checkpoint.stage != .replacementRequired {
                checkpoint.requireReplacementAuthorization()
            }
            checkpoint.beginReplacementAttempt()
            try save(checkpoint, for: user)
            let authorization = try await authorization(forceRefresh: true)
            let client = try client()
            let challenge = try await client.createChallenge(
                requestID: UUID(),
                appCheckToken: authorization.appCheckToken
            )
            let response = try await possessionProvider.response(
                for: challenge.challenge
            )
            try await client.authorizeInstallation(
                requestID: checkpoint.replacementRequestID,
                challenge: challenge,
                possessionResponse: response,
                authorization: authorization
            )
            let loadedOverview = try await client.overview(
                authorization: authorization
            )
            guard loadedOverview.bandState == "claimed" else {
                throw OwnershipClientError.invalidResponse
            }
            let loadedInstallations = try await client.installations(
                authorization: authorization
            )
            checkpoint.reconcileReplacement(authorized: true)
            try save(checkpoint, for: user)
            loadedOverview.plan.persist()
            overview = loadedOverview
            installations = loadedInstallations
            phase = .complete
            status = String(
                localized: "This phone is now authorized for the ownership account."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            if let user = try? currentUser(try runtime()),
               var checkpoint = try? self.checkpoint(for: user),
               checkpoint.stage == .replacementPending,
               let reconciled = try? await reconcilePendingReplacement(
                   user: user,
                   checkpoint: &checkpoint
               ),
               reconciled {
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "reconciled"
                )
                return
            }
            let reportedError = reconcileChangedTerms(error)
            phase = Self.isTermsChanged(reportedError)
                ? .termsReview
                : (Self.isSecureStorage(reportedError)
                    ? .localRecoveryRequired
                    : .replacementRequired)
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    @discardableResult
    func selectPlan(_ plan: NoopProductPlan) async -> Bool {
        guard !isBusy else { return false }
        plan.persist()
        guard isAvailable else {
            status = plan == .noop
                ? String(localized: "NOOP selected. Core local features remain available.")
                : String(
                    localized: "NOOP+ selected for later. Payment and entitlement are not enabled."
                )
            AppDiagnosticsRecorder.shared.record(
                "ownership.plan_local",
                fields: ["selection": plan.rawValue]
            )
            return true
        }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.plan.select"
        )
        defer { isBusy = false }
        do {
            let currentUser = try currentUser(try runtime())
            var checkpoint = try self.checkpoint(for: currentUser)
            checkpoint.beginPlanSelection(plan)
            try save(checkpoint, for: currentUser)
            let client = try client()
            try await client.selectPlan(
                plan,
                requestID: checkpoint.planRequestID,
                authorization: try await authorization(forceRefresh: false)
            )
            let loadedOverview = try await client.overview(
                authorization: try await authorization(forceRefresh: false)
            )
            guard loadedOverview.plan == plan else {
                throw OwnershipClientError.invalidResponse
            }
            checkpoint.completePlanSelection(
                bandClaimed: loadedOverview.bandState == "claimed"
            )
            try save(checkpoint, for: currentUser)
            overview = loadedOverview
            phase = resolvedPhase(
                for: loadedOverview,
                checkpoint: checkpoint
            )
            status = plan == .noop
                ? String(localized: "NOOP selected. No payment is required.")
                : String(
                    localized: "NOOP+ preference saved. Payment and entitlement remain unavailable."
                )
            Self.recordPlanSelectionResolution(
                bandClaimed: loadedOverview.bandState == "claimed"
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: plan.rawValue
            )
            return true
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return false
            }
            let reportedError = reconcileChangedTerms(error)
            phase = ownershipFailureRecoveryPhase(
                phase,
                termsChanged: Self.isTermsChanged(reportedError),
                secureStorageFailed: Self.isSecureStorage(reportedError)
            )
            status = String(
                localized: "Preference saved on this phone. Open Band Account later to finish account sync."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "deferred",
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError),
                    "local_state": "saved",
                ]
            )
            return true
        }
    }

    func refreshOverview() async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.account.refresh"
        )
        defer { isBusy = false }
        do {
            try await loadOverview(forceRefresh: false)
            let user = try currentUser(try runtime())
            var checkpoint = try self.checkpoint(for: user)
            if checkpoint.stage == .planSelection {
                try await reconcilePendingPlanSelection(
                    user: user,
                    checkpoint: &checkpoint
                )
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["installation_count": String(installations.count)]
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            let reportedError = reconcileChangedTerms(error)
            phase = ownershipFailureRecoveryPhase(
                phase,
                termsChanged: Self.isTermsChanged(reportedError),
                secureStorageFailed: Self.isSecureStorage(reportedError)
            )
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    private func loadOverview(
        forceRefresh: Bool,
        generation: UInt64? = nil
    ) async throws {
        let client = try client()
        let authorization = try await authorization(forceRefresh: forceRefresh)
        async let account = client.overview(authorization: authorization)
        async let devices = client.installations(authorization: authorization)
        let loadedOverview = try await account
        let loadedInstallations = try await devices
        try checkReconciliation(generation)
        overview = loadedOverview
        installations = loadedInstallations
        let user = try currentUser(try runtime())
        var checkpoint = try self.checkpoint(for: user)
        let originalCheckpoint = checkpoint
        checkpoint.reconcileBandState(
            claimed: loadedOverview.bandState == "claimed"
        )
        if checkpoint != originalCheckpoint {
            try save(checkpoint, for: user)
        }
        phase = resolvedPhase(for: loadedOverview, checkpoint: checkpoint)
    }

    func revokeInstallation(_ installation: OwnershipInstallation) async {
        guard !installation.current, !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.installation.revoke"
        )
        defer { isBusy = false }
        do {
            try await client().revokeInstallation(
                installation.id,
                authorization: try await authorization(forceRefresh: true)
            )
            installations.removeAll { $0.id == installation.id }
            status = String(localized: "The selected phone installation was revoked.")
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func signOut() {
        guard !isBusy else { return }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.identity.sign_out"
        )
        do {
            let runtime = try runtime()
            let scope = try runtime.auth.currentUser.map {
                try accountScope(for: $0)
            }
            invalidateBootstrapReconciliation()
            try runtime.auth.signOut()
            phase = .signedOut
            terms = nil
            overview = nil
            installations = []
            verificationID = nil
            status = String(localized: "Signed out of band ownership.")
            let cleanupOutcome: String
            if let scope {
                cleanupOutcome = secureStore.deletePhoneVerificationID(
                    scope: scope
                ) ? "completed" : "deferred"
            } else {
                cleanupOutcome = "not_needed"
            }
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed",
                fields: ["cleanup_outcome": cleanupOutcome]
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    func resetLocalOwnershipSetup() {
        guard phase == .localRecoveryRequired, !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.local_security.reset"
        )
        defer { isBusy = false }
        do {
            let runtime = try runtime()
            let user = try currentUser(runtime)
            invalidateBootstrapReconciliation()
            guard secureStore.reset(scope: try accountScope(for: user)) else {
                throw OwnershipClientError.secureStorage
            }
            try runtime.auth.signOut()
            terms = nil
            overview = nil
            installations = []
            verificationID = nil
            phase = .signedOut
            status = String(
                localized: "Ownership setup was reset on this phone. Sign in to recover access."
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            phase = Self.isSecureStorage(error)
                ? .localRecoveryRequired
                : .unavailable
            status = Self.userMessage(for: error)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(error),
                fields: ["failure_kind": Self.diagnosticFailureKind(error)]
            )
        }
    }

    private func performIdentityOperation(
        name: String,
        operation: @escaping (User) async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(name)
        defer { isBusy = false }
        do {
            let user = try currentUser(try runtime())
            try await operation(user)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(error, diagnostic: diagnostic) {
                return
            }
            let reportedError = reconcileChangedTerms(error)
            phase = ownershipFailureRecoveryPhase(
                phase,
                termsChanged: Self.isTermsChanged(reportedError),
                secureStorageFailed: Self.isSecureStorage(reportedError)
            )
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    @discardableResult
    private func beginBusy(operation: String) -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        return operation
    }

    private func reconcileLocal(
        user: User,
        checkpoint: OwnershipAccountCheckpoint
    ) {
        guard user.isEmailVerified else {
            phase = .emailVerification
            return
        }
        switch checkpoint.stage {
        case .signedOut, .emailVerification, .termsReview:
            phase = .termsReview
        case .accountRegistration:
            phase = .registering
        case .accountReady:
            phase = possessionProvider.isAvailable
                ? .accountReady
                : .possessionUnavailable
        case .claimPending:
            phase = possessionProvider.isAvailable
                ? .accountReady
                : .possessionUnavailable
        case .claimed:
            phase = .claimed
        case .planSelection:
            phase = possessionProvider.isAvailable
                ? .accountReady
                : .possessionUnavailable
        case .complete:
            phase = .complete
        case .replacementRequired:
            phase = .replacementRequired
        case .replacementPending:
            phase = .authorizingReplacement
        }
    }

    private func reconcileRemote(user: User) async {
        await reconcileRemote(user: user, generation: nil)
    }

    private func reconcileRemote(
        user: User,
        generation: UInt64?
    ) async {
        guard reconciliationMayUpdateState(generation) else { return }
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "ownership.account.reconcile"
        )
        let ownsBootstrapBusy = generation.map {
            bootstrapBusyGeneration == $0
        } ?? false
        let shouldReleaseBusy: Bool
        if ownsBootstrapBusy {
            shouldReleaseBusy = true
        } else if !isBusy {
            isBusy = true
            shouldReleaseBusy = true
        } else {
            shouldReleaseBusy = false
        }
        defer {
            if shouldReleaseBusy {
                if let generation {
                    if reconciliationMayUpdateState(generation),
                       bootstrapBusyGeneration == generation {
                        bootstrapBusyGeneration = nil
                        bootstrapTask = nil
                        isBusy = false
                    }
                } else {
                    isBusy = false
                }
            }
        }
        do {
            try checkReconciliation(generation)
            try await user.reload()
            try checkReconciliation(generation)
            guard user.isEmailVerified else {
                phase = .emailVerification
                status = String(
                    localized: "Verify your email address before continuing."
                )
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "completed"
                )
                return
            }
            var checkpoint = try self.checkpoint(for: user)
            if checkpoint.stage == .emailVerification,
               checkpoint.hasAcceptedTerms {
                checkpoint.stage = .accountRegistration
                try save(checkpoint, for: user)
            }
            switch checkpoint.stage {
            case .accountRegistration:
                phase = .registering
                guard let policyVersion = checkpoint.acceptedPolicyVersion,
                      let policySHA256 = checkpoint.acceptedPolicySHA256,
                      let locale = checkpoint.acceptedLocale else {
                    throw OwnershipClientError.invalidState
                }
                try await completeTermsAcceptance(
                    user: user,
                    checkpoint: &checkpoint,
                    policyVersion: policyVersion,
                    policySHA256: policySHA256,
                    locale: locale,
                    generation: generation
                )
            case .claimPending:
                _ = try await reconcilePendingClaim(
                    user: user,
                    checkpoint: &checkpoint,
                    generation: generation
                )
            case .accountReady, .claimed, .planSelection, .complete:
                try await loadOverview(
                    forceRefresh: false,
                    generation: generation
                )
                checkpoint = try self.checkpoint(for: user)
                if checkpoint.stage == .planSelection {
                    try await reconcilePendingPlanSelection(
                        user: user,
                        checkpoint: &checkpoint,
                        generation: generation
                    )
                }
                if checkpoint.stage == .complete {
                    phase = .complete
                }
            case .replacementRequired:
                phase = .replacementRequired
                status = String(
                    localized: "This account already owns a band. Confirm it to authorize this phone."
                )
            case .replacementPending:
                _ = try await reconcilePendingReplacement(
                    user: user,
                    checkpoint: &checkpoint,
                    generation: generation
                )
            case .signedOut, .emailVerification, .termsReview:
                try await reconcileIdentityEntry(
                    user: user,
                    checkpoint: &checkpoint,
                    generation: generation
                )
            }
            try checkReconciliation(generation)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "completed"
            )
        } catch {
            if finishCanceledOperation(
                error,
                diagnostic: diagnostic,
                recoverState: reconciliationMayUpdateState(generation)
            ) {
                return
            }
            guard reconciliationMayUpdateState(generation) else {
                AppDiagnosticsRecorder.shared.endOperation(
                    diagnostic,
                    outcome: "canceled",
                    fields: ["failure_kind": "stale_reconciliation"]
                )
                return
            }
            let reportedError = reconcileChangedTerms(error)
            phase = ownershipFailureRecoveryPhase(
                phase,
                termsChanged: Self.isTermsChanged(reportedError),
                secureStorageFailed: Self.isSecureStorage(reportedError)
            )
            status = Self.userMessage(for: reportedError)
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: Self.diagnosticOutcome(reportedError),
                fields: [
                    "failure_kind": Self.diagnosticFailureKind(reportedError)
                ]
            )
        }
    }

    @discardableResult
    private func invalidateBootstrapReconciliation() -> UInt64 {
        bootstrapGeneration &+= 1
        bootstrapTask?.cancel()
        bootstrapTask = nil
        if bootstrapBusyGeneration != nil {
            bootstrapBusyGeneration = nil
            isBusy = false
        }
        return bootstrapGeneration
    }

    private func reconciliationMayUpdateState(
        _ generation: UInt64?
    ) -> Bool {
        ownershipReconciliationMayUpdateState(
            expectedGeneration: generation,
            currentGeneration: bootstrapGeneration
        )
    }

    private func checkReconciliation(_ generation: UInt64?) throws {
        try Task.checkCancellation()
        guard reconciliationMayUpdateState(generation) else {
            throw CancellationError()
        }
    }

    private func completeTermsAcceptance(
        user: User,
        checkpoint: inout OwnershipAccountCheckpoint,
        policyVersion: String,
        policySHA256: String,
        locale: String,
        generation: UInt64? = nil
    ) async throws {
        try checkReconciliation(generation)
        let client = try client()
        let authorization = try await authorization(forceRefresh: true)
        let bootstrap = try await client.bootstrap(
            authorization: authorization
        )
        try checkReconciliation(generation)
        if bootstrap.accountState == "active",
           !bootstrap.termsAcceptanceRequired {
            do {
                let loadedOverview = try await client.overview(
                    authorization: authorization
                )
                let loadedInstallations = try await client.installations(
                    authorization: authorization
                )
                try checkReconciliation(generation)
                checkpoint.completeRegistration()
                if loadedOverview.bandState == "claimed" {
                    checkpoint.reconcileClaim(claimed: true)
                }
                try save(checkpoint, for: user)
                loadedOverview.plan.persist()
                overview = loadedOverview
                installations = loadedInstallations
                terms = nil
                phase = resolvedPhase(
                    for: loadedOverview,
                    checkpoint: checkpoint
                )
                status = loadedOverview.bandState == "claimed"
                    ? String(
                        localized: "Current ownership terms accepted. Band ownership remains active."
                    )
                    : (possessionProvider.isAvailable
                        ? String(
                            localized: "Account ready. Confirm the band to finish activation."
                        )
                        : String(
                            localized: "Account ready. Band confirmation will unlock when the approved NOOP Band SDK is available."
                        ))
                AppDiagnosticsRecorder.shared.record(
                    "ownership.lifecycle",
                    fields: [
                        "phase": "terms_recovery",
                        "outcome": "registration_reconciled",
                    ]
                )
                return
            } catch let error as OwnershipClientError {
                guard error == .authentication || error == .invalidState else {
                    throw error
                }
                if bootstrap.bandState == "claimed" {
                    checkpoint.requireReplacementAuthorization()
                    try save(checkpoint, for: user)
                    overview = nil
                    installations = []
                    terms = nil
                    phase = .replacementRequired
                    status = String(
                        localized: "Current terms accepted. Confirm the claimed band to authorize this phone."
                    )
                    AppDiagnosticsRecorder.shared.record(
                        "ownership.lifecycle",
                        fields: [
                            "phase": "terms_recovery",
                            "outcome": "replacement_required",
                        ]
                    )
                    return
                }
            }
        }
        if bootstrap.accountState == "active",
           bootstrap.bandState == "claimed" {
            try await client.acceptTerms(
                requestID: checkpoint.registrationRequestID,
                policyVersion: policyVersion,
                policySHA256: policySHA256,
                locale: locale,
                authorization: authorization
            )
            try checkReconciliation(generation)
            do {
                let loadedOverview = try await client.overview(
                    authorization: authorization
                )
                let loadedInstallations = try await client.installations(
                    authorization: authorization
                )
                try checkReconciliation(generation)
                guard loadedOverview.bandState == "claimed" else {
                    throw OwnershipClientError.invalidResponse
                }
                checkpoint.completeRegistration()
                checkpoint.reconcileClaim(claimed: true)
                try save(checkpoint, for: user)
                loadedOverview.plan.persist()
                overview = loadedOverview
                installations = loadedInstallations
                terms = nil
                phase = .claimed
                status = String(
                    localized: "Current ownership terms accepted. Band ownership remains active."
                )
                AppDiagnosticsRecorder.shared.record(
                    "ownership.lifecycle",
                    fields: [
                        "phase": "terms_recovery",
                        "outcome": "installation_restored",
                    ]
                )
                return
            } catch let error as OwnershipClientError {
                guard error == .authentication || error == .invalidState else {
                    throw error
                }
                checkpoint.requireReplacementAuthorization()
                try save(checkpoint, for: user)
                overview = nil
                installations = []
                terms = nil
                phase = .replacementRequired
                status = String(
                    localized: "Current terms accepted. Confirm the claimed band to authorize this phone."
                )
                AppDiagnosticsRecorder.shared.record(
                    "ownership.lifecycle",
                    fields: [
                        "phase": "terms_recovery",
                        "outcome": "replacement_required",
                    ]
                )
                return
            }
        }

        let credential = try secureStore.installationCredential(
            scope: try accountScope(for: user)
        )
        let account = try await client.registerAccount(
            requestID: checkpoint.registrationRequestID,
            installation: credential,
            policyVersion: policyVersion,
            policySHA256: policySHA256,
            locale: locale,
            plan: NoopProductPlan.stored(),
            authorization: authorization
        )
        try checkReconciliation(generation)
        overview = account
        checkpoint.completeRegistration()
        if account.bandState == "claimed" {
            checkpoint.reconcileClaim(claimed: true)
        }
        try save(checkpoint, for: user)
        terms = nil
        phase = resolvedPhase(for: account, checkpoint: checkpoint)
        status = possessionProvider.isAvailable
            ? String(
                localized: "Account ready. Confirm the band to finish activation."
            )
            : String(
                localized: "Account ready. Band confirmation will unlock when the approved NOOP Band SDK is available."
            )
        AppDiagnosticsRecorder.shared.record(
            "ownership.lifecycle",
            fields: [
                "phase": "terms_recovery",
                "outcome": account.bandState == "claimed"
                    ? "account_restored"
                    : "account_registered",
            ]
        )
    }

    private func reconcileIdentityEntry(
        user: User,
        checkpoint: inout OwnershipAccountCheckpoint,
        generation: UInt64? = nil
    ) async throws {
        try checkReconciliation(generation)
        let authorization = try await authorization(forceRefresh: true)
        let client = try client()
        do {
            let loadedOverview = try await client.overview(
                authorization: authorization
            )
            let loadedInstallations = try await client.installations(
                authorization: authorization
            )
            try checkReconciliation(generation)
            checkpoint.reconcileBandState(
                claimed: loadedOverview.bandState == "claimed"
            )
            if loadedOverview.bandState != "claimed",
               checkpoint.stage != .accountReady {
                checkpoint.stage = .accountReady
            }
            try save(checkpoint, for: user)
            loadedOverview.plan.persist()
            overview = loadedOverview
            installations = loadedInstallations
            phase = loadedOverview.bandState == "claimed"
                ? .claimed
                : (possessionProvider.isAvailable
                    ? .accountReady
                    : .possessionUnavailable)
            status = String(
                localized: "The existing ownership authorization for this phone was restored."
            )
            return
        } catch let error as OwnershipClientError {
            switch error {
            case .authentication, .invalidState:
                break
            default:
                throw error
            }
        }

        let bootstrap = try await client.bootstrap(
            authorization: authorization
        )
        try checkReconciliation(generation)
        if bootstrap.termsAcceptanceRequired {
            if checkpoint.stage != .termsReview || checkpoint.hasAcceptedTerms {
                checkpoint.invalidateAcceptedTerms()
                try save(checkpoint, for: user)
            }
            overview = nil
            installations = []
            phase = .termsReview
            status = String(
                localized: "Review the current ownership terms before continuing."
            )
        } else if bootstrap.replacementAuthorizationRequired {
            checkpoint.requireReplacementAuthorization()
            try save(checkpoint, for: user)
            overview = nil
            installations = []
            phase = .replacementRequired
            status = String(
                localized: "This account already owns a band. Confirm it to authorize this phone."
            )
        } else {
            phase = .termsReview
            status = String(
                localized: "Signed in. Review the ownership terms to continue."
            )
        }
    }

    private func reconcilePendingClaim(
        user: User,
        checkpoint: inout OwnershipAccountCheckpoint,
        generation: UInt64? = nil
    ) async throws -> Bool {
        let loaded = try await client().overview(
            authorization: try await authorization(forceRefresh: true)
        )
        try checkReconciliation(generation)
        overview = loaded
        let claimed = loaded.bandState == "claimed"
        checkpoint.reconcileClaim(claimed: claimed)
        try save(checkpoint, for: user)
        phase = claimed
            ? .claimed
            : (possessionProvider.isAvailable
                ? .accountReady
                : .possessionUnavailable)
        status = claimed
            ? String(localized: "Band ownership confirmed.")
            : String(localized: "No completed band claim was found. Try confirmation again.")
        return claimed
    }

    private func reconcilePendingPlanSelection(
        user: User,
        checkpoint: inout OwnershipAccountCheckpoint,
        generation: UInt64? = nil
    ) async throws {
        try checkReconciliation(generation)
        guard checkpoint.stage == .planSelection,
              let pending = checkpoint.pendingPlanSelection else {
            return
        }
        let authorization = try await authorization(forceRefresh: false)
        let client = try client()
        var loaded: OwnershipAccountOverview
        if let overview {
            loaded = overview
        } else {
            loaded = try await client.overview(
                authorization: authorization
            )
            try checkReconciliation(generation)
        }
        if loaded.plan != pending {
            try await client.selectPlan(
                pending,
                requestID: checkpoint.planRequestID,
                authorization: authorization
            )
            try checkReconciliation(generation)
            loaded = try await client.overview(authorization: authorization)
            try checkReconciliation(generation)
        }
        guard loaded.plan == pending else {
            throw OwnershipClientError.invalidResponse
        }
        pending.persist()
        checkpoint.completePlanSelection(
            bandClaimed: loaded.bandState == "claimed"
        )
        try save(checkpoint, for: user)
        overview = loaded
        phase = resolvedPhase(for: loaded, checkpoint: checkpoint)
        Self.recordPlanSelectionResolution(
            bandClaimed: loaded.bandState == "claimed"
        )
    }

    private static func recordPlanSelectionResolution(bandClaimed: Bool) {
        AppDiagnosticsRecorder.shared.record(
            "ownership.lifecycle",
            fields: [
                "phase": "plan_selection",
                "outcome": bandClaimed
                    ? "flow_completed"
                    : "preference_saved",
            ]
        )
    }

    private func reconcilePendingReplacement(
        user: User,
        checkpoint: inout OwnershipAccountCheckpoint,
        generation: UInt64? = nil
    ) async throws -> Bool {
        try checkReconciliation(generation)
        let client = try client()
        let authorization = try await authorization(forceRefresh: true)
        do {
            let loadedOverview = try await client.overview(
                authorization: authorization
            )
            guard loadedOverview.bandState == "claimed" else {
                throw OwnershipClientError.invalidResponse
            }
            let loadedInstallations = try await client.installations(
                authorization: authorization
            )
            try checkReconciliation(generation)
            checkpoint.reconcileReplacement(authorized: true)
            try save(checkpoint, for: user)
            loadedOverview.plan.persist()
            overview = loadedOverview
            installations = loadedInstallations
            phase = .complete
            status = String(
                localized: "This phone is now authorized for the ownership account."
            )
            return true
        } catch let error as OwnershipClientError {
            switch error {
            case .authentication, .invalidState:
                checkpoint.reconcileReplacement(authorized: false)
                try save(checkpoint, for: user)
                phase = .replacementRequired
                status = String(
                    localized: "This account already owns a band. Confirm it to authorize this phone."
                )
                return false
            default:
                throw error
            }
        }
    }

    private func checkpoint(for user: User) throws -> OwnershipAccountCheckpoint {
        let scope = try accountScope(for: user)
        if let value = try secureStore.checkpoint(scope: scope) {
            guard value.isValid else {
                throw OwnershipClientError.secureStorage
            }
            return value
        }
        let created = OwnershipAccountCheckpoint(
            stage: user.isEmailVerified ? .termsReview : .emailVerification
        )
        try secureStore.writeCheckpoint(created, scope: scope)
        return created
    }

    private func save(
        _ checkpoint: OwnershipAccountCheckpoint,
        for user: User
    ) throws {
        guard checkpoint.isValid else {
            throw OwnershipClientError.invalidState
        }
        try secureStore.writeCheckpoint(
            checkpoint,
            scope: try accountScope(for: user)
        )
    }

    private func resolvedPhase(
        for overview: OwnershipAccountOverview,
        checkpoint: OwnershipAccountCheckpoint
    ) -> OwnershipServicePhase {
        switch checkpoint.stage {
        case .replacementRequired:
            return .replacementRequired
        case .replacementPending:
            return .authorizingReplacement
        default:
            guard overview.bandState == "claimed" else {
                return possessionProvider.isAvailable
                    ? .accountReady
                    : .possessionUnavailable
            }
            return checkpoint.stage == .complete ? .complete : .claimed
        }
    }

    private static func isTermsChanged(_ error: Error) -> Bool {
        if case OwnershipClientError.termsChanged = error {
            return true
        }
        return false
    }

    private static func isSecureStorage(_ error: Error) -> Bool {
        if case OwnershipClientError.secureStorage = error {
            return true
        }
        return false
    }

    private func reconcileChangedTerms(_ originalError: Error) -> Error {
        guard case OwnershipClientError.termsChanged = originalError else {
            return originalError
        }
        terms = nil
        do {
            let user = try currentUser(try runtime())
            var checkpoint = try self.checkpoint(for: user)
            checkpoint.invalidateAcceptedTerms()
            try save(checkpoint, for: user)
            phase = .termsReview
            return originalError
        } catch {
            return error
        }
    }

    private func authorization(forceRefresh: Bool) async throws
        -> OwnershipAuthorization {
        let runtime = try runtime()
        let user = try currentUser(runtime)
        let scope = try accountScope(for: user)
        async let identityToken = user.getIDToken(forcingRefresh: forceRefresh)
        async let appCheckToken = Self.appCheckToken(
            runtime.appCheck,
            forceRefresh: forceRefresh
        )
        let credential = try secureStore.installationCredential(scope: scope)
        return try await OwnershipAuthorization(
            identityToken: identityToken,
            appCheckToken: appCheckToken,
            installation: credential
        )
    }

    private func runtime() throws -> OwnershipFirebaseRuntime {
        if let firebaseRuntime { return firebaseRuntime }
        let config = try requiredConfiguration()
        let app: FirebaseApp
        if let existing = FirebaseApp.app(name: noopOwnershipFirebaseAppName) {
            guard existing.options.projectID == config.projectID,
                  existing.options.googleAppID == config.googleAppID else {
                throw OwnershipClientError.firebaseProjectConflict
            }
            app = existing
        } else {
            if FirebaseApp.app() == nil {
                #if DEBUG
                AppCheck.setAppCheckProviderFactory(
                    AppCheckDebugProviderFactory()
                )
                #elseif targetEnvironment(simulator)
                AppCheck.setAppCheckProviderFactory(
                    AppCheckDebugProviderFactory()
                )
                #else
                AppCheck.setAppCheckProviderFactory(
                    AppAttestProviderFactory()
                )
                #endif
            }
            let options = FirebaseOptions(
                googleAppID: config.googleAppID,
                gcmSenderID: config.gcmSenderID
            )
            options.apiKey = config.apiKey
            options.projectID = config.projectID
            options.bundleID = Bundle.main.bundleIdentifier ?? options.bundleID
            FirebaseApp.configure(
                name: noopOwnershipFirebaseAppName,
                options: options
            )
            guard let configured = FirebaseApp.app(
                name: noopOwnershipFirebaseAppName
            ) else {
                throw OwnershipClientError.invalidConfiguration
            }
            app = configured
        }
        guard let appCheck = AppCheck.appCheck(app: app) else {
            throw OwnershipClientError.invalidConfiguration
        }
        let result = OwnershipFirebaseRuntime(
            auth: Auth.auth(app: app),
            appCheck: appCheck
        )
        firebaseRuntime = result
        ManagedFirebaseApplicationDelegate.forwardPendingAPNSTokenIfPossible()
        return result
    }

    private func requiredConfiguration() throws -> OwnershipConfiguration {
        guard let configuration else {
            throw OwnershipClientError.unavailable
        }
        return configuration
    }

    private func client() throws -> OwnershipAPIClient {
        if let ownershipClient {
            return ownershipClient
        }
        let created = OwnershipAPIClient(
            configuration: try requiredConfiguration()
        )
        ownershipClient = created
        return created
    }

    private func currentUser(_ runtime: OwnershipFirebaseRuntime) throws -> User {
        guard let user = runtime.auth.currentUser else {
            throw OwnershipClientError.notSignedIn
        }
        return user
    }

    private func accountScope() throws -> String {
        try accountScope(for: try currentUser(try runtime()))
    }

    private func accountScope(for user: User) throws -> String {
        let projectID = try requiredConfiguration().projectID
        return ownershipSHA256(
            ownershipAccountScopeMaterial(
                projectID: projectID,
                subject: user.uid
            )
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
                        throwing: error ?? OwnershipClientError.authentication
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
            throw OwnershipClientError.invalidCredentials
        }
        return value
    }

    private static func validatePassword(
        _ password: String,
        confirmation: String
    ) throws {
        guard password == confirmation,
              password.count >= 12,
              password.count <= 128 else {
            throw OwnershipClientError.invalidPassword
        }
    }

    private static func normalizedPhone(_ raw: String) throws -> String {
        let compact = raw.filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }
        guard compact.range(
            of: #"^\+[1-9][0-9]{7,14}$"#,
            options: .regularExpression
        ) != nil else {
            throw OwnershipClientError.invalidPhone
        }
        return compact
    }

    private static func normalizedCode(_ raw: String) throws -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(
            of: #"^[0-9]{6}$"#,
            options: .regularExpression
        ) != nil else {
            throw OwnershipClientError.invalidCode
        }
        return code
    }

    private static func preferredLocale() -> String {
        let raw = Locale.preferredLanguages.first
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
        let candidate = raw.replacingOccurrences(of: "-", with: "_")
        guard candidate.count <= 32,
              candidate.range(
                of: #"^[A-Za-z]{2,3}([_][A-Za-z0-9]{2,8}){0,2}$"#,
                options: .regularExpression
              ) != nil else {
            return "en"
        }
        return candidate
    }

    private static func maskedEmail(_ raw: String?) -> String {
        guard let raw,
              let at = raw.firstIndex(of: "@"),
              at != raw.startIndex else {
            return ""
        }
        let domain = raw[at...]
        return String(raw[raw.startIndex]) + "***" + domain
    }

    private static func userMessage(for error: Error) -> String {
        if let error = error as? OwnershipClientError {
            switch error {
            case .unavailable, .invalidConfiguration, .firebaseProjectConflict:
                return String(
                    localized: "Band ownership setup is not available in this build."
                )
            case .invalidCredentials:
                return String(
                    localized: "Enter a valid email and password, or use password reset."
                )
            case .invalidPassword:
                return String(
                    localized: "Use matching passwords with at least 12 characters."
                )
            case .emailVerificationRequired:
                return String(
                    localized: "Verify your email address before continuing."
                )
            case .termsRequired, .termsChanged:
                return String(
                    localized: "Reload and review the current ownership terms."
                )
            case .invalidPhone:
                return String(
                    localized: "Enter a mobile number with country code."
                )
            case .invalidCode, .phoneCodeRequired:
                return String(localized: "Enter the current six-digit code.")
            case .notSignedIn, .authentication:
                return String(localized: "Sign in again to continue.")
            case .challengeInactive:
                return String(
                    localized: "That band confirmation is no longer active. Start confirmation again."
                )
            case .possessionRejected:
                return String(
                    localized: "Band confirmation was not accepted. Keep the band worn and try again."
                )
            case .alreadyClaimed:
                return String(
                    localized: "This band is not available for activation."
                )
            case .possessionUnavailable:
                return String(
                    localized: "Band confirmation is temporarily unavailable."
                )
            case .network:
                return String(
                    localized: "The ownership service could not be reached."
                )
            case .serviceUnavailable:
                return String(
                    localized: "The ownership service is temporarily unavailable."
                )
            case .invalidResponse, .invalidState, .secureStorage:
                if error == .secureStorage {
                    return String(
                        localized: "Secure ownership data on this phone could not be read. Reset this phone's setup to continue."
                    )
                }
                return String(localized: "NOOP could not safely continue ownership setup.")
            }
        }
        let code = authErrorCode(error)
        if code == .networkError {
            return String(
                localized: "The ownership service could not be reached."
            )
        }
        return String(
            localized: "NOOP could not complete that account action. Try again or reset the password."
        )
    }

    private static func diagnosticOutcome(_ error: Error) -> String {
        if error is CancellationError { return "canceled" }
        if let error = error as? OwnershipClientError {
            switch error {
            case .invalidCredentials, .invalidPassword, .invalidPhone,
                    .invalidCode, .emailVerificationRequired, .termsRequired,
                    .termsChanged, .notSignedIn, .authentication,
                    .challengeInactive, .possessionRejected, .alreadyClaimed,
                    .phoneCodeRequired:
                return "rejected"
            case .unavailable, .serviceUnavailable, .possessionUnavailable:
                return "unavailable"
            default:
                return "failed"
            }
        }
        return "failed"
    }

    private func finishCanceledOperation(
        _ error: Error,
        diagnostic: AppDiagnosticsRecorder.OperationToken,
        recoverState: Bool = true
    ) -> Bool {
        guard !ownershipFailureShouldUpdateState(error) else { return false }
        if recoverState {
            phase = ownershipCancellationRecoveryPhase(
                phase,
                possessionAvailable: possessionProvider.isAvailable
            )
        }
        AppDiagnosticsRecorder.shared.endOperation(
            diagnostic,
            outcome: "canceled",
            fields: ["failure_kind": "canceled"]
        )
        return true
    }

    private static func diagnosticFailureKind(_ error: Error) -> String {
        if error is CancellationError { return "canceled" }
        if let value = error as? OwnershipClientError {
            switch value {
            case .unavailable: return "configuration"
            case .invalidConfiguration: return "configuration"
            case .firebaseProjectConflict: return "firebase_project"
            case .invalidCredentials: return "credentials"
            case .invalidPassword: return "password_policy"
            case .emailVerificationRequired: return "email_unverified"
            case .termsRequired: return "terms_missing"
            case .termsChanged: return "terms_changed"
            case .invalidPhone: return "phone_format"
            case .invalidCode: return "code_format"
            case .phoneCodeRequired: return "verification_state"
            case .notSignedIn: return "identity_missing"
            case .authentication: return "authentication"
            case .challengeInactive: return "challenge_inactive"
            case .possessionRejected: return "possession_rejected"
            case .alreadyClaimed: return "ownership_conflict"
            case .possessionUnavailable: return "possession_provider"
            case .network: return "network"
            case .serviceUnavailable: return "service"
            case .invalidResponse: return "response_contract"
            case .invalidState: return "state"
            case .secureStorage: return "secure_storage"
            }
        }
        if let code = authErrorCode(error) {
            switch code {
            case .networkError: return "network"
            case .tooManyRequests: return "rate_limit"
            case .userDisabled: return "identity_disabled"
            case .requiresRecentLogin: return "reauthentication"
            case .emailAlreadyInUse, .credentialAlreadyInUse:
                return "identity_conflict"
            case .invalidEmail, .wrongPassword, .userNotFound,
                    .invalidCredential:
                return "credentials"
            default:
                return "identity_provider"
            }
        }
        return "unknown"
    }

    private static func authErrorCode(_ error: Error) -> AuthErrorCode? {
        let value = error as NSError
        guard value.domain == AuthErrors.domain else { return nil }
        return AuthErrorCode(rawValue: value.code)
    }

}

private func ownershipSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct OwnershipConfiguration {
    let baseURL: URL
    let termsHost: String
    let allowLocalHTTP: Bool
    let projectID: String
    let apiKey: String
    let googleAppID: String
    let gcmSenderID: String

    static func load(bundle: Bundle) -> Self? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
                return nil
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.contains("$(") ? nil : value
        }
        guard bool("NOOPOwnershipActivationEnabled", bundle: bundle),
              let api = value("NOOPOwnershipAPIURL"),
              let baseURL = URL(string: api),
              let host = value("NOOPOwnershipTermsHost")?.lowercased(),
              let projectID = value("NOOPManagedProjectID"),
              let apiKey = value("NOOPManagedAPIKey"),
              let googleAppID = value("NOOPManagedGoogleAppID"),
              let gcmSenderID = value("NOOPManagedGCMSenderID") else {
            return nil
        }
        let allowLocalHTTP = bool(
            "NOOPOwnershipAllowLocalHTTP",
            bundle: bundle
        )
        guard validBaseURL(baseURL, allowLocalHTTP: allowLocalHTTP),
              host.range(
                of: #"^[A-Za-z0-9.-]{1,253}$"#,
                options: .regularExpression
              ) != nil,
              projectID.range(
                of: #"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"#,
                options: .regularExpression
              ) != nil,
              googleAppID.range(
                of: #"^1:[0-9]+:ios:[0-9a-f]+$"#,
                options: .regularExpression
              ) != nil,
              gcmSenderID.range(
                of: #"^[0-9]{6,20}$"#,
                options: .regularExpression
              ) != nil,
              !apiKey.isEmpty else {
            return nil
        }
        return Self(
            baseURL: baseURL,
            termsHost: host,
            allowLocalHTTP: allowLocalHTTP,
            projectID: projectID,
            apiKey: apiKey,
            googleAppID: googleAppID,
            gcmSenderID: gcmSenderID
        )
    }

    private static func bool(_ key: String, bundle: Bundle) -> Bool {
        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func validBaseURL(
        _ url: URL,
        allowLocalHTTP: Bool
    ) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let host = url.host?.lowercased() else {
            return false
        }
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG && targetEnvironment(simulator)
        return allowLocalHTTP
            && url.scheme?.lowercased() == "http"
            && ["127.0.0.1", "localhost", "::1"].contains(host)
        #else
        _ = allowLocalHTTP
        return false
        #endif
    }
}

private struct OwnershipFirebaseRuntime {
    let auth: Auth
    let appCheck: AppCheck
}

private struct OwnershipAuthorization {
    let identityToken: String
    let appCheckToken: String
    let installation: OwnershipInstallationCredential
}

private struct OwnershipTermsManifest: Decodable {
    let policyVersion: String
    let locale: String
    let documentSha256: String
    let documentUri: String
}

private struct OwnershipChallengeResponse: Decodable {
    let challengeId: UUID
    let challenge: String
    let expiresAt: String
}

private final class OwnershipNoRedirectSessionDelegate:
    NSObject,
    URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }
}

private final class OwnershipAPIClient {
    private let configuration: OwnershipConfiguration
    private let redirectDelegate: OwnershipNoRedirectSessionDelegate
    private let session: URLSession
    private let decoder: JSONDecoder

    init(configuration: OwnershipConfiguration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        let redirectDelegate = OwnershipNoRedirectSessionDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: config,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func currentTerms(locale: String) async throws -> OwnershipTermsManifest {
        let encoded = locale.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? "en"
        let data = try await execute(
            path: "v1/ownership/terms/current?locale=\(encoded)",
            method: "GET",
            routeGroup: "terms_manifest"
        )
        let value = try decoder.decode(OwnershipTermsManifest.self, from: data)
        guard value.policyVersion.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil,
        value.locale.range(
            of: #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$"#,
            options: .regularExpression
        ) != nil,
        value.documentSha256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw OwnershipClientError.invalidResponse
        }
        return value
    }

    func fetchTermsDocument(
        _ manifest: OwnershipTermsManifest
    ) async throws -> OwnershipTermsDocument {
        guard let url = URL(string: manifest.documentUri),
              OwnershipEndpointPolicy.isValidTermsDocumentURL(
                  url,
                  allowedHost: configuration.termsHost
              ) else {
            throw OwnershipClientError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let started = ContinuousClock.now
        var requestRecorded = false
        do {
            let (bounded, response) = try await boundedData(
                for: request,
                maximumBytes: 512 * 1024
            )
            guard let http = response as? HTTPURLResponse else {
                recordRequest(
                    routeGroup: "terms_document",
                    method: "GET",
                    statusCode: nil,
                    started: started,
                    outcome: "failed"
                )
                requestRecorded = true
                throw OwnershipClientError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                recordRequest(
                    routeGroup: "terms_document",
                    method: "GET",
                    statusCode: http.statusCode,
                    started: started,
                    outcome: "rejected"
                )
                requestRecorded = true
                switch http.statusCode {
                case 429, 500...599:
                    throw OwnershipClientError.serviceUnavailable
                default:
                    throw OwnershipClientError.invalidResponse
                }
            }
            guard let data = bounded,
                  http.url == url,
                  ownershipSHA256(data) == manifest.documentSha256,
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty,
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters
                          .subtracting(CharacterSet.whitespacesAndNewlines)
                          .contains($0)
                  }) else {
                recordRequest(
                    routeGroup: "terms_document",
                    method: "GET",
                    statusCode: http.statusCode,
                    started: started,
                    outcome: "failed"
                )
                requestRecorded = true
                throw OwnershipClientError.invalidResponse
            }
            recordRequest(
                routeGroup: "terms_document",
                method: "GET",
                statusCode: http.statusCode,
                started: started,
                outcome: "completed"
            )
            requestRecorded = true
            return OwnershipTermsDocument(
                policyVersion: manifest.policyVersion,
                locale: manifest.locale,
                sha256: manifest.documentSha256,
                sourceURL: url,
                text: text
            )
        } catch {
            let canceled = !ownershipFailureShouldUpdateState(error)
            if !requestRecorded {
                recordRequest(
                    routeGroup: "terms_document",
                    method: "GET",
                    statusCode: nil,
                    started: started,
                    outcome: canceled ? "canceled" : "failed"
                )
            }
            if canceled { throw CancellationError() }
            if error is OwnershipClientError { throw error }
            throw OwnershipClientError.network
        }
    }

    func registerAccount(
        requestID: UUID,
        installation: OwnershipInstallationCredential,
        policyVersion: String,
        policySHA256: String,
        locale: String,
        plan: NoopProductPlan,
        authorization: OwnershipAuthorization
    ) async throws -> OwnershipAccountOverview {
        let body: [String: Any] = [
            "request_id": requestID.uuidString.lowercased(),
            "installation_id": installation.id,
            "installation_token": installation.token,
            "platform": "ios",
            "policy_version": policyVersion,
            "policy_sha256": policySHA256,
            "locale": locale,
            "plan_selection": plan.rawValue,
        ]
        let data = try await execute(
            path: "v1/ownership/account",
            method: "PUT",
            routeGroup: "account",
            authorization: authorization,
            includeInstallation: false,
            body: body
        )
        return try parseOverview(data)
    }

    func acceptTerms(
        requestID: UUID,
        policyVersion: String,
        policySHA256: String,
        locale: String,
        authorization: OwnershipAuthorization
    ) async throws {
        let data = try await execute(
            path: "v1/ownership/terms/acceptance",
            method: "PUT",
            routeGroup: "terms_acceptance",
            authorization: authorization,
            includeInstallation: false,
            body: [
                "request_id": requestID.uuidString.lowercased(),
                "policy_version": policyVersion,
                "policy_sha256": policySHA256,
                "locale": locale,
            ]
        )
        let object = try jsonObject(data)
        guard object["acceptance_state"] as? String == "accepted",
              object["policy_version"] as? String == policyVersion,
              object["locale"] as? String == locale,
              object["resumed"] is Bool else {
            throw OwnershipClientError.invalidResponse
        }
    }

    func bootstrap(
        authorization: OwnershipAuthorization
    ) async throws -> OwnershipBootstrapStatus {
        let data = try await execute(
            path: "v1/ownership/bootstrap",
            method: "GET",
            routeGroup: "bootstrap",
            authorization: authorization,
            includeInstallation: false
        )
        let object = try jsonObject(data)
        guard let accountState = object["account_state"] as? String,
              ["unregistered", "active"].contains(accountState),
              let bandState = object["band_state"] as? String,
              ["unclaimed", "claimed"].contains(bandState),
              let replacement = object[
                  "replacement_authorization_required"
              ] as? Bool,
              let termsAcceptanceRequired = object[
                  "terms_acceptance_required"
              ] as? Bool,
              replacement == (
                  accountState == "active" && bandState == "claimed"
              ),
              accountState == "active" || !termsAcceptanceRequired else {
            throw OwnershipClientError.invalidResponse
        }
        return OwnershipBootstrapStatus(
            accountState: accountState,
            bandState: bandState,
            replacementAuthorizationRequired: replacement,
            termsAcceptanceRequired: termsAcceptanceRequired
        )
    }

    func createChallenge(
        requestID: UUID,
        appCheckToken: String
    ) async throws -> OwnershipChallengeResponse {
        let data = try await execute(
            path: "v1/ownership/possession-challenges",
            method: "POST",
            routeGroup: "challenge",
            appCheckToken: appCheckToken,
            body: [
                "request_id": requestID.uuidString.lowercased(),
                "platform": "ios",
            ]
        )
        let value = try decoder.decode(OwnershipChallengeResponse.self, from: data)
        guard value.challenge.range(
            of: #"^[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil else {
            throw OwnershipClientError.invalidResponse
        }
        return value
    }

    func claim(
        requestID: UUID,
        challenge: OwnershipChallengeResponse,
        possessionResponse: String,
        authorization: OwnershipAuthorization
    ) async throws {
        guard possessionResponse.count >= 16,
              possessionResponse.count <= 16_384 else {
            throw OwnershipClientError.invalidResponse
        }
        let data = try await execute(
            path: "v1/ownership/claims",
            method: "POST",
            routeGroup: "claim",
            authorization: authorization,
            body: [
                "request_id": requestID.uuidString.lowercased(),
                "challenge_id": challenge.challengeId.uuidString.lowercased(),
                "challenge": challenge.challenge,
                "possession_response": possessionResponse,
            ]
        )
        let object = try jsonObject(data)
        guard object["band_state"] as? String == "claimed" else {
            throw OwnershipClientError.invalidResponse
        }
    }

    func authorizeInstallation(
        requestID: UUID,
        challenge: OwnershipChallengeResponse,
        possessionResponse: String,
        authorization: OwnershipAuthorization
    ) async throws {
        guard possessionResponse.count >= 16,
              possessionResponse.count <= 16_384 else {
            throw OwnershipClientError.invalidResponse
        }
        let data = try await execute(
            path: "v1/ownership/installations:authorize",
            method: "POST",
            routeGroup: "installation_authorize",
            authorization: authorization,
            includeInstallation: false,
            body: [
                "request_id": requestID.uuidString.lowercased(),
                "challenge_id": challenge.challengeId.uuidString.lowercased(),
                "challenge": challenge.challenge,
                "possession_response": possessionResponse,
                "new_installation_id": authorization.installation.id,
                "new_installation_token": authorization.installation.token,
                "new_platform": "ios",
            ]
        )
        let object = try jsonObject(data)
        guard object["installation_state"] as? String == "active",
              object["installation_id"] as? String
                == authorization.installation.id else {
            throw OwnershipClientError.invalidResponse
        }
    }

    func overview(
        authorization: OwnershipAuthorization
    ) async throws -> OwnershipAccountOverview {
        let data = try await execute(
            path: "v1/ownership/me",
            method: "GET",
            routeGroup: "overview",
            authorization: authorization
        )
        return try parseOverview(data)
    }

    func installations(
        authorization: OwnershipAuthorization
    ) async throws -> [OwnershipInstallation] {
        let data = try await execute(
            path: "v1/ownership/installations",
            method: "GET",
            routeGroup: "installations",
            authorization: authorization
        )
        let object = try jsonObject(data)
        guard let rows = object["installations"] as? [[String: Any]],
              rows.count <= 10 else {
            throw OwnershipClientError.invalidResponse
        }
        return try rows.map { row in
            guard let id = row["installation_id"] as? String,
                  id.range(
                    of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
                    options: .regularExpression
                  ) != nil,
                  let platform = row["platform"] as? String,
                  ["ios", "android"].contains(platform),
                  let status = row["status"] as? String,
                  ["active", "revoked"].contains(status),
                  let current = row["current"] as? Bool,
                  let registeredAt = row["registered_at"] as? String,
                  let lastSeenAt = row["last_seen_at"] as? String else {
                throw OwnershipClientError.invalidResponse
            }
            return OwnershipInstallation(
                id: id,
                platform: platform,
                status: status,
                current: current,
                registeredAt: registeredAt,
                lastSeenAt: lastSeenAt
            )
        }
    }

    func revokeInstallation(
        _ installationID: String,
        authorization: OwnershipAuthorization
    ) async throws {
        guard installationID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw OwnershipClientError.invalidResponse
        }
        _ = try await execute(
            path: "v1/ownership/installations/\(installationID)",
            method: "DELETE",
            routeGroup: "installation_revoke",
            authorization: authorization
        )
    }

    func selectPlan(
        _ plan: NoopProductPlan,
        requestID: UUID,
        authorization: OwnershipAuthorization
    ) async throws {
        let data = try await execute(
            path: "v1/ownership/plan-selection",
            method: "PUT",
            routeGroup: "plan",
            authorization: authorization,
            body: [
                "request_id": requestID.uuidString.lowercased(),
                "selection": plan.rawValue,
            ]
        )
        let object = try jsonObject(data)
        guard object["plan_selection"] as? String == plan.rawValue,
              object["noop_plus_entitled"] as? Bool == false,
              object["payment_state"] as? String == "unavailable" else {
            throw OwnershipClientError.invalidResponse
        }
    }

    private func parseOverview(_ data: Data) throws -> OwnershipAccountOverview {
        let object = try jsonObject(data)
        guard let accountState = object["account_state"] as? String,
              ["active", "deletion_pending", "retired"].contains(accountState),
              let emailVerified = object["email_verified"] as? Bool,
              let phoneVerified = object["phone_verified"] as? Bool,
              let bandState = object["band_state"] as? String,
              ["unclaimed", "claimed"].contains(bandState),
              let activeInstallations = object["active_installations"] as? Int,
              (0...10).contains(activeInstallations),
              let planRaw = object["plan_selection"] as? String,
              let plan = NoopProductPlan(rawValue: planRaw),
              let entitled = object["noop_plus_entitled"] as? Bool,
              entitled == false else {
            throw OwnershipClientError.invalidResponse
        }
        return OwnershipAccountOverview(
            accountState: accountState,
            emailVerified: emailVerified,
            phoneVerified: phoneVerified,
            bandState: bandState,
            activeInstallations: activeInstallations,
            plan: plan,
            noopPlusEntitled: entitled
        )
    }

    private func execute(
        path: String,
        method: String,
        routeGroup: String,
        authorization: OwnershipAuthorization? = nil,
        appCheckToken: String? = nil,
        includeInstallation: Bool = true,
        body: [String: Any]? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?
            .absoluteURL else {
            throw OwnershipClientError.invalidConfiguration
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
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
                    authorization.installation.id,
                    forHTTPHeaderField: "X-Noop-Ownership-Installation-ID"
                )
                request.setValue(
                    authorization.installation.token,
                    forHTTPHeaderField: "X-Noop-Ownership-Installation-Token"
                )
            }
        } else if let appCheckToken {
            request.setValue(
                appCheckToken,
                forHTTPHeaderField: "X-Firebase-AppCheck"
            )
        }
        if let body {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        let started = ContinuousClock.now
        var requestRecorded = false
        do {
            let (bounded, response) = try await boundedData(
                for: request,
                maximumBytes: 1024 * 1024
            )
            guard let http = response as? HTTPURLResponse else {
                recordRequest(
                    routeGroup: routeGroup,
                    method: method,
                    statusCode: nil,
                    started: started,
                    outcome: "failed"
                )
                requestRecorded = true
                throw OwnershipClientError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                recordRequest(
                    routeGroup: routeGroup,
                    method: method,
                    statusCode: http.statusCode,
                    started: started,
                    outcome: "rejected"
                )
                requestRecorded = true
                switch http.statusCode {
                case 401: throw OwnershipClientError.authentication
                case 403: throw OwnershipClientError.authentication
                case 404: throw OwnershipClientError.invalidState
                case 410:
                    switch routeGroup {
                    case "claim", "installation_authorize":
                        throw OwnershipClientError.challengeInactive
                    default:
                        throw OwnershipClientError.invalidState
                    }
                case 409:
                    switch routeGroup {
                    case "claim":
                        throw OwnershipClientError.alreadyClaimed
                    default:
                        throw OwnershipClientError.invalidState
                    }
                case 412:
                    throw [
                        "account",
                        "claim",
                        "installation_authorize",
                        "overview",
                        "terms_acceptance",
                    ].contains(routeGroup)
                        ? OwnershipClientError.termsChanged
                        : OwnershipClientError.invalidState
                case 422:
                    switch routeGroup {
                    case "claim", "installation_authorize":
                        throw OwnershipClientError.possessionRejected
                    default:
                        throw OwnershipClientError.invalidResponse
                    }
                case 429: throw OwnershipClientError.serviceUnavailable
                case 500...599: throw OwnershipClientError.serviceUnavailable
                default: throw OwnershipClientError.invalidResponse
                }
            }
            guard let data = bounded else {
                recordRequest(
                    routeGroup: routeGroup,
                    method: method,
                    statusCode: http.statusCode,
                    started: started,
                    outcome: "failed"
                )
                requestRecorded = true
                throw OwnershipClientError.invalidResponse
            }
            recordRequest(
                routeGroup: routeGroup,
                method: method,
                statusCode: http.statusCode,
                started: started,
                outcome: "completed"
            )
            requestRecorded = true
            return data
        } catch {
            let canceled = !ownershipFailureShouldUpdateState(error)
            if !requestRecorded {
                recordRequest(
                    routeGroup: routeGroup,
                    method: method,
                    statusCode: nil,
                    started: started,
                    outcome: canceled ? "canceled" : "failed"
                )
            }
            if canceled { throw CancellationError() }
            if error is OwnershipClientError { throw error }
            throw OwnershipClientError.network
        }
    }

    private func boundedData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data?, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let expectedLength = response.expectedContentLength
        guard expectedLength <= Int64(maximumBytes) else {
            return (nil, response)
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                return (nil, response)
            }
            data.append(byte)
        }
        return (data, response)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw OwnershipClientError.invalidResponse
        }
        return value
    }

    private func recordRequest(
        routeGroup: String,
        method: String,
        statusCode: Int?,
        started: ContinuousClock.Instant,
        outcome: String
    ) {
        let elapsed = started.duration(to: .now).components
        let durationMilliseconds = max(
            0,
            Int(
                min(
                    Double(Int.max),
                    Double(elapsed.seconds) * 1_000
                        + Double(elapsed.attoseconds) / 1_000_000_000_000_000
                )
            )
        )
        var fields = [
            "target": "ownership",
            "route_group": routeGroup,
            "method": method,
            "duration_ms": String(durationMilliseconds),
            "outcome": outcome,
        ]
        if let statusCode { fields["status_code"] = String(statusCode) }
        AppDiagnosticsRecorder.shared.record(
            "ownership_http.request",
            fields: fields
        )
    }
}

final class OwnershipSecureStore {
    private let service = "com.noop.band-ownership"

    fileprivate func installationCredential(
        scope: String
    ) throws -> OwnershipInstallationCredential {
        if let data = try read(account: "installation-\(scope)") {
            do {
                return try OwnershipInstallationCredential.decodePersisted(
                    data
                )
            } catch {
                throw OwnershipClientError.secureStorage
            }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw OwnershipClientError.secureStorage
        }
        let token = "noopo_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let created = OwnershipInstallationCredential(
            id: UUID().uuidString.lowercased(),
            token: token
        )
        try write(
            JSONEncoder().encode(created),
            account: "installation-\(scope)"
        )
        return created
    }

    func checkpoint(scope: String) throws -> OwnershipAccountCheckpoint? {
        guard let data = try read(account: "checkpoint-\(scope)") else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                OwnershipAccountCheckpoint.self,
                from: data
            )
        } catch {
            throw OwnershipClientError.secureStorage
        }
    }

    func writeCheckpoint(
        _ value: OwnershipAccountCheckpoint,
        scope: String
    ) throws {
        try write(
            JSONEncoder().encode(value),
            account: "checkpoint-\(scope)"
        )
    }

    func readPhoneVerificationID(scope: String) throws -> String? {
        guard let data = try read(account: "phone-verification-\(scope)") else {
            return nil
        }
        guard data.count <= 4096,
              let value = String(data: data, encoding: .utf8) else {
            throw OwnershipClientError.secureStorage
        }
        return value
    }

    func writePhoneVerificationID(_ value: String, scope: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096 else {
            throw OwnershipClientError.secureStorage
        }
        try write(
            Data(value.utf8),
            account: "phone-verification-\(scope)"
        )
    }

    @discardableResult
    func deletePhoneVerificationID(scope: String) -> Bool {
        let status = SecItemDelete(
            query(account: "phone-verification-\(scope)") as CFDictionary
        )
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func reset(scope: String) -> Bool {
        var completed = true
        for account in [
            "installation-\(scope)",
            "checkpoint-\(scope)",
            "phone-verification-\(scope)",
        ] {
            let status = SecItemDelete(
                query(account: account) as CFDictionary
            )
            if status != errSecSuccess && status != errSecItemNotFound {
                completed = false
            }
        }
        return completed
    }

    private func read(account: String) throws -> Data? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            lookup as CFDictionary,
            &item
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw OwnershipClientError.secureStorage
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let base = query(account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            base as CFDictionary,
            update as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw OwnershipClientError.secureStorage
        }
        let created = base.merging(update) { _, replacement in replacement }
        guard SecItemAdd(created as CFDictionary, nil) == errSecSuccess else {
            throw OwnershipClientError.secureStorage
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum OwnershipClientError: Error, Equatable {
    case unavailable
    case invalidConfiguration
    case firebaseProjectConflict
    case invalidCredentials
    case invalidPassword
    case emailVerificationRequired
    case termsRequired
    case termsChanged
    case invalidPhone
    case invalidCode
    case phoneCodeRequired
    case notSignedIn
    case authentication
    case challengeInactive
    case possessionRejected
    case alreadyClaimed
    case possessionUnavailable
    case network
    case serviceUnavailable
    case invalidResponse
    case invalidState
    case secureStorage
}
#endif
