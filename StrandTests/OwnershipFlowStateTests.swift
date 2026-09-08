import XCTest
@testable import Strand

final class OwnershipFlowStateTests: XCTestCase {
    func testInterruptedReconciliationLeavesProgressForActionableScreen() {
        XCTAssertEqual(
            ownershipReconciliationRecoveryPhase(.registering),
            .termsReview
        )
        XCTAssertEqual(
            ownershipReconciliationRecoveryPhase(.authorizingReplacement),
            .replacementRequired
        )

        for phase in OwnershipServicePhase.allRecoveryStableCases {
            XCTAssertEqual(
                ownershipReconciliationRecoveryPhase(phase),
                phase
            )
        }
    }

    func testChangedTermsAlwaysReturnToTermsReview() {
        for phase in OwnershipServicePhase.allCases {
            XCTAssertEqual(
                ownershipFailureRecoveryPhase(
                    phase,
                    termsChanged: true
                ),
                .termsReview
            )
        }

        for phase in OwnershipServicePhase.allCases {
            XCTAssertEqual(
                ownershipFailureRecoveryPhase(
                    phase,
                    termsChanged: false
                ),
                ownershipReconciliationRecoveryPhase(phase)
            )
        }
    }

    func testSecureStorageFailureRequiresExplicitLocalRecovery() {
        for phase in OwnershipServicePhase.allCases {
            XCTAssertEqual(
                ownershipFailureRecoveryPhase(
                    phase,
                    termsChanged: false,
                    secureStorageFailed: true
                ),
                .localRecoveryRequired
            )
        }
    }

    func testCancellationReturnsProgressToAnActionablePhase() {
        XCTAssertEqual(
            ownershipCancellationRecoveryPhase(
                .registering,
                possessionAvailable: false
            ),
            .termsReview
        )
        XCTAssertEqual(
            ownershipCancellationRecoveryPhase(
                .claiming,
                possessionAvailable: true
            ),
            .accountReady
        )
        XCTAssertEqual(
            ownershipCancellationRecoveryPhase(
                .claiming,
                possessionAvailable: false
            ),
            .possessionUnavailable
        )
        XCTAssertEqual(
            ownershipCancellationRecoveryPhase(
                .authorizingReplacement,
                possessionAvailable: true
            ),
            .replacementRequired
        )
    }

    func testCancellationDoesNotBecomeAnOwnershipFailureState() {
        XCTAssertFalse(
            ownershipFailureShouldUpdateState(CancellationError())
        )
        XCTAssertFalse(
            ownershipFailureShouldUpdateState(URLError(.cancelled))
        )
        XCTAssertTrue(
            ownershipFailureShouldUpdateState(
                OwnershipBandPossessionProviderError.rejected
            )
        )
    }

    func testOnlyCurrentBackgroundReconciliationCanMutateState() {
        XCTAssertTrue(
            ownershipReconciliationMayUpdateState(
                expectedGeneration: nil,
                currentGeneration: 8
            )
        )
        XCTAssertTrue(
            ownershipReconciliationMayUpdateState(
                expectedGeneration: 8,
                currentGeneration: 8
            )
        )
        XCTAssertFalse(
            ownershipReconciliationMayUpdateState(
                expectedGeneration: 7,
                currentGeneration: 8
            )
        )
    }

    func testEveryPostClaimOnboardingPageRequiresCurrentClaimWhenEnabled() {
        for phase in OwnershipServicePhase.allCases {
            XCTAssertEqual(
                ownershipCanAccessPostClaimOnboarding(
                    isAvailable: true,
                    phase: phase
                ),
                phase == .claimed || phase == .complete,
                "\(phase)"
            )
        }
        XCTAssertTrue(
            ownershipCanAccessPostClaimOnboarding(
                isAvailable: false,
                phase: .signedOut
            )
        )
    }

    func testOnboardingReconcilesAllPostClaimPagesAndFinalCompletion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Strand/Onboarding/OnboardingWizard.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "candidate.rawValue > Step.ownership.rawValue"
            )
        )
        XCTAssertTrue(source.contains("if !ownershipAllows(step) {"))
        XCTAssertTrue(source.contains("guard ownershipAllows(.done) else {"))
        XCTAssertTrue(source.contains("if ownershipAllows(next) {"))
        XCTAssertTrue(
            source.contains(
                ".onChange(of: ownershipService.phase) { _, _ in"
            )
        )
        XCTAssertTrue(source.contains("reconcileOwnershipRequirement()"))
    }

    func testPlanDefaultsToNoopAndRoundTrips() {
        let suite = "OwnershipFlowStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NoopProductPlan.stored(in: defaults), .noop)
        NoopProductPlan.noopPlus.persist(in: defaults)
        XCTAssertEqual(NoopProductPlan.stored(in: defaults), .noopPlus)
    }

    func testOwnershipAccountScopeSeparatesFirebaseProjectsAndSubjects() {
        let baseline = ownershipAccountScopeMaterial(
            projectID: "noop-staging",
            subject: "same-subject"
        )

        XCTAssertNotEqual(
            baseline,
            ownershipAccountScopeMaterial(
                projectID: "noop-production",
                subject: "same-subject"
            )
        )
        XCTAssertNotEqual(
            baseline,
            ownershipAccountScopeMaterial(
                projectID: "noop-staging",
                subject: "different-subject"
            )
        )
        XCTAssertNotEqual(
            ownershipAccountScopeMaterial(
                projectID: "a",
                subject: "bc"
            ),
            ownershipAccountScopeMaterial(
                projectID: "ab",
                subject: "c"
            )
        )
        XCTAssertTrue(
            String(decoding: baseline, as: UTF8.self)
                .hasPrefix("noop-ownership-account-v2\u{0}")
        )
    }

    func testPersistedInstallationCredentialFailsClosedWhenMalformed() throws {
        let valid = OwnershipInstallationCredential(
            id: "ios-installation",
            token: "noopo_" + String(repeating: "A", count: 43)
        )
        XCTAssertEqual(
            try OwnershipInstallationCredential.decodePersisted(
                JSONEncoder().encode(valid)
            ),
            valid
        )

        for data in [
            Data("not-json".utf8),
            Data(#"{"id":"bad id","token":"noopo_123"}"#.utf8),
            Data(#"{"id":"ios-installation"}"#.utf8),
        ] {
            XCTAssertThrowsError(
                try OwnershipInstallationCredential.decodePersisted(data)
            ) { error in
                XCTAssertEqual(
                    error as? OwnershipInstallationCredentialError,
                    .invalid
                )
            }
        }
    }

    func testCheckpointRequiresTermsBeforeRegistration() throws {
        var checkpoint = OwnershipAccountCheckpoint(stage: .termsReview)

        XCTAssertThrowsError(
            try checkpoint.advance(to: .accountRegistration)
        ) { error in
            XCTAssertEqual(
                error as? OwnershipAccountTransitionError,
                .termsRequired
            )
        }

        try checkpoint.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: String(repeating: "a", count: 64),
            locale: "en"
        )
        XCTAssertEqual(checkpoint.stage, .accountRegistration)
        XCTAssertTrue(checkpoint.isValid)
    }

    func testPreAccountTermsRemainAcceptedThroughEmailVerification() throws {
        var checkpoint = OwnershipAccountCheckpoint()
        let originalRequest = checkpoint.registrationRequestID

        try checkpoint.captureAcceptedTerms(
            policyVersion: "ownership-v1",
            sha256: String(repeating: "a", count: 64),
            locale: "en"
        )

        XCTAssertEqual(checkpoint.stage, .emailVerification)
        XCTAssertTrue(checkpoint.hasAcceptedTerms)
        XCTAssertNotEqual(checkpoint.registrationRequestID, originalRequest)

        checkpoint.stage = .accountRegistration
        XCTAssertTrue(checkpoint.isValid)
    }

    func testCheckpointRejectsSkippedTransitionsAndInvalidPolicy() {
        var checkpoint = OwnershipAccountCheckpoint()
        XCTAssertThrowsError(try checkpoint.advance(to: .termsReview))
        XCTAssertThrowsError(
            try checkpoint.acceptTerms(
                policyVersion: "ownership v1",
                sha256: "not-a-digest",
                locale: "en"
            )
        )
        XCTAssertThrowsError(
            try checkpoint.acceptTerms(
                policyVersion: "ownership-v1",
                sha256: String(repeating: "a", count: 64),
                locale: "not_a_valid_locale_shape"
            )
        )
    }

    func testCheckpointRejectsStructurallyImpossiblePersistedStates() throws {
        XCTAssertFalse(
            OwnershipAccountCheckpoint(
                stage: .accountRegistration
            ).isValid
        )
        XCTAssertFalse(
            OwnershipAccountCheckpoint(
                stage: .planSelection
            ).isValid
        )
        XCTAssertFalse(
            OwnershipAccountCheckpoint(
                stage: .complete,
                pendingPlanSelection: .noopPlus
            ).isValid
        )

        var staleReview = OwnershipAccountCheckpoint(stage: .termsReview)
        try staleReview.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: String(repeating: "a", count: 64),
            locale: "en"
        )
        staleReview.stage = .termsReview
        XCTAssertFalse(staleReview.isValid)
    }

    func testCheckpointEncodingContainsNoContactOrCredentialValues() throws {
        var checkpoint = OwnershipAccountCheckpoint(stage: .termsReview)
        try checkpoint.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: String(repeating: "b", count: 64),
            locale: "en"
        )
        let encoded = try JSONEncoder().encode(checkpoint)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("phone"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("challenge"))
    }

    func testUnavailablePossessionProviderFailsClosed() async {
        let provider = UnavailableOwnershipBandPossessionProvider()
        XCTAssertFalse(provider.isAvailable)
        do {
            _ = try await provider.response(for: "ephemeral-challenge")
            XCTFail("Expected unavailable provider to reject")
        } catch {
            XCTAssertEqual(
                error as? OwnershipBandPossessionProviderError,
                .unavailable
            )
        }
    }

    func testRegistrationRequestIsStableForRetryAndRotatesAfterCompletion() throws {
        var checkpoint = OwnershipAccountCheckpoint(stage: .termsReview)
        let initial = checkpoint.registrationRequestID
        let digest = String(repeating: "a", count: 64)

        try checkpoint.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: digest,
            locale: "en"
        )
        let accepted = checkpoint.registrationRequestID
        XCTAssertNotEqual(accepted, initial)

        try checkpoint.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: digest,
            locale: "en"
        )
        XCTAssertEqual(checkpoint.registrationRequestID, accepted)

        checkpoint.completeRegistration()
        XCTAssertEqual(checkpoint.stage, .accountReady)
        XCTAssertNotEqual(checkpoint.registrationRequestID, accepted)
    }

    func testChangedTermsClearPolicyAndPendingPlanCheckpoints() throws {
        var checkpoint = OwnershipAccountCheckpoint(stage: .termsReview)
        try checkpoint.acceptTerms(
            policyVersion: "ownership-v1",
            sha256: String(repeating: "a", count: 64),
            locale: "en"
        )
        let acceptedRequest = checkpoint.registrationRequestID
        let claimRequest = checkpoint.claimRequestID
        checkpoint.beginPlanSelection(.noopPlus)
        let planRequest = checkpoint.planRequestID

        checkpoint.invalidateAcceptedTerms()

        XCTAssertEqual(checkpoint.stage, .termsReview)
        XCTAssertNil(checkpoint.acceptedPolicyVersion)
        XCTAssertNil(checkpoint.acceptedPolicySHA256)
        XCTAssertNil(checkpoint.acceptedLocale)
        XCTAssertNil(checkpoint.pendingPlanSelection)
        XCTAssertNotEqual(checkpoint.registrationRequestID, acceptedRequest)
        XCTAssertEqual(checkpoint.claimRequestID, claimRequest)
        XCTAssertNotEqual(checkpoint.planRequestID, planRequest)
        XCTAssertTrue(checkpoint.isValid)
    }

    func testClaimReconciliationAlwaysRotatesAmbiguousRequest() {
        var checkpoint = OwnershipAccountCheckpoint(stage: .accountReady)
        checkpoint.beginClaimAttempt()
        let pending = checkpoint.claimRequestID

        checkpoint.reconcileClaim(claimed: false)
        XCTAssertEqual(checkpoint.stage, .accountReady)
        XCTAssertNotEqual(checkpoint.claimRequestID, pending)

        checkpoint.beginClaimAttempt()
        let secondPending = checkpoint.claimRequestID
        checkpoint.reconcileClaim(claimed: true)
        XCTAssertEqual(checkpoint.stage, .claimed)
        XCTAssertNotEqual(checkpoint.claimRequestID, secondPending)
    }

    func testAuthoritativeBandStateRepairsStaleCompletion() {
        var checkpoint = OwnershipAccountCheckpoint(stage: .complete)
        let request = checkpoint.claimRequestID

        checkpoint.reconcileBandState(claimed: false)

        XCTAssertEqual(checkpoint.stage, .accountReady)
        XCTAssertNotEqual(checkpoint.claimRequestID, request)

        checkpoint.reconcileBandState(claimed: true)
        XCTAssertEqual(checkpoint.stage, .claimed)
    }

    func testInterruptedPlanSelectionCompletesOnlyForClaimedAccount() {
        var checkpoint = OwnershipAccountCheckpoint(stage: .claimed)

        checkpoint.beginPlanSelection(.noopPlus)
        let plusRequest = checkpoint.planRequestID
        checkpoint.beginPlanSelection(.noopPlus)
        XCTAssertEqual(checkpoint.planRequestID, plusRequest)

        checkpoint.beginPlanSelection(.noop)
        XCTAssertNotEqual(checkpoint.planRequestID, plusRequest)
        let noopRequest = checkpoint.planRequestID

        checkpoint.completePlanSelection(bandClaimed: true)
        XCTAssertNil(checkpoint.pendingPlanSelection)
        XCTAssertEqual(checkpoint.stage, .complete)
        XCTAssertNotEqual(checkpoint.planRequestID, noopRequest)
    }

    func testInterruptedPlanSelectionKeepsUnclaimedAccountReady() {
        var checkpoint = OwnershipAccountCheckpoint(stage: .accountReady)

        checkpoint.beginPlanSelection(.noopPlus)
        let pendingRequest = checkpoint.planRequestID
        checkpoint.completePlanSelection(bandClaimed: false)

        XCTAssertNil(checkpoint.pendingPlanSelection)
        XCTAssertEqual(checkpoint.stage, .accountReady)
        XCTAssertNotEqual(checkpoint.planRequestID, pendingRequest)
        XCTAssertTrue(checkpoint.isValid)
    }

    func testReplacementRequestRotatesAcrossAttemptsAndReconciliation() {
        var checkpoint = OwnershipAccountCheckpoint(stage: .claimed)

        checkpoint.requireReplacementAuthorization()
        let required = checkpoint.replacementRequestID
        XCTAssertEqual(checkpoint.stage, .replacementRequired)

        checkpoint.beginReplacementAttempt()
        let pending = checkpoint.replacementRequestID
        XCTAssertEqual(checkpoint.stage, .replacementPending)
        XCTAssertNotEqual(pending, required)

        checkpoint.reconcileReplacement(authorized: false)
        let retry = checkpoint.replacementRequestID
        XCTAssertEqual(checkpoint.stage, .replacementRequired)
        XCTAssertNotEqual(retry, pending)

        checkpoint.beginReplacementAttempt()
        checkpoint.reconcileReplacement(authorized: true)
        XCTAssertEqual(checkpoint.stage, .complete)
    }

    func testCheckpointDecodesLegacyPayloadWithoutReplacementRequest() throws {
        let registration = UUID()
        let claim = UUID()
        let plan = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "stage": OwnershipAccountStage.accountReady.rawValue,
            "registrationRequestID": registration.uuidString,
            "claimRequestID": claim.uuidString,
            "planRequestID": plan.uuidString,
        ])

        let decoded = try JSONDecoder().decode(
            OwnershipAccountCheckpoint.self,
            from: data
        )

        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.registrationRequestID, registration)
        XCTAssertEqual(decoded.claimRequestID, claim)
        XCTAssertEqual(decoded.planRequestID, plan)
    }

    func testOwnershipEndpointRequiresRootPathAndSecureTransport() throws {
        XCTAssertTrue(
            OwnershipEndpointPolicy.isValidBaseURL(
                try XCTUnwrap(URL(string: "https://ownership.noop.example")),
                allowLocalHTTP: false,
                permitsLocalHTTP: false
            )
        )
        XCTAssertFalse(
            OwnershipEndpointPolicy.isValidBaseURL(
                try XCTUnwrap(URL(string: "https://ownership.noop.example/api/")),
                allowLocalHTTP: false,
                permitsLocalHTTP: false
            )
        )
        XCTAssertFalse(
            OwnershipEndpointPolicy.isValidBaseURL(
                try XCTUnwrap(URL(string: "http://ownership.noop.example")),
                allowLocalHTTP: true,
                permitsLocalHTTP: true
            )
        )
        XCTAssertTrue(
            OwnershipEndpointPolicy.isValidBaseURL(
                try XCTUnwrap(URL(string: "http://127.0.0.1:8081")),
                allowLocalHTTP: true,
                permitsLocalHTTP: true
            )
        )
    }

    func testTermsDocumentRequiresExactSecureHostWithoutDynamicComponents() throws {
        XCTAssertTrue(
            OwnershipEndpointPolicy.isValidTermsDocumentURL(
                try XCTUnwrap(
                    URL(string: "https://terms.noop.example/ownership-v1/en")
                ),
                allowedHost: "terms.noop.example"
            )
        )
        XCTAssertTrue(
            OwnershipEndpointPolicy.isValidTermsDocumentURL(
                try XCTUnwrap(
                    URL(string: "https://terms.noop.example:443/ownership-v1/en")
                ),
                allowedHost: "terms.noop.example"
            )
        )
        for candidate in [
            "https://other.example/ownership-v1/en",
            "https://terms.noop.example:8443/ownership-v1/en",
            "https://terms.noop.example/ownership-v1/en?redirect=other",
            "https://user@terms.noop.example/ownership-v1/en",
            "http://terms.noop.example/ownership-v1/en",
        ] {
            XCTAssertFalse(
                OwnershipEndpointPolicy.isValidTermsDocumentURL(
                    try XCTUnwrap(URL(string: candidate)),
                    allowedHost: "terms.noop.example"
                )
            )
        }
    }

    func testOwnershipHTTPClientDisablesRedirects() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let views = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("delegate: redirectDelegate"))
        XCTAssertTrue(
            source.contains(
                """
                willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void
                """
            )
        )
        XCTAssertTrue(source.contains("completionHandler(nil)"))
        XCTAssertTrue(source.contains("session.bytes(for: request)"))
        XCTAssertTrue(source.contains("response.expectedContentLength"))
        XCTAssertTrue(source.contains("data.count < maximumBytes"))
        XCTAssertTrue(source.contains("let (bounded, response)"))
        XCTAssertTrue(source.contains("guard let data = bounded"))
        XCTAssertTrue(source.contains("entitled == false"))
        XCTAssertTrue(source.contains("case 429, 500...599:"))
        XCTAssertFalse(source.contains("session.data(for: request)"))
        XCTAssertTrue(views.contains(".textSelection(.enabled)"))
        XCTAssertFalse(source.contains("\"server_request_id\""))
        XCTAssertTrue(source.contains("case 412:"))
        for route in [
            "account",
            "claim",
            "installation_authorize",
            "overview",
            "terms_acceptance",
        ] {
            XCTAssertTrue(source.contains("\"\(route)\""))
        }
        XCTAssertTrue(source.contains("].contains(routeGroup)"))
        XCTAssertTrue(source.contains("? OwnershipClientError.termsChanged"))
        XCTAssertTrue(source.contains("case 410:"))
        XCTAssertTrue(source.contains("OwnershipClientError.challengeInactive"))
        XCTAssertTrue(source.contains("case 422:"))
        XCTAssertTrue(source.contains("OwnershipClientError.possessionRejected"))
    }

    func testAccountCreationCheckpointPrecedesVerificationDelivery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let createStart = try XCTUnwrap(
            source.range(of: "    func createAccount(")
        )
        let createEnd = try XCTUnwrap(
            source.range(
                of: "    func signIn(",
                range: createStart.upperBound..<source.endIndex
            )
        )
        let createSource = String(
            source[createStart.lowerBound..<createEnd.lowerBound]
        )
        let phase = try XCTUnwrap(
            createSource.range(of: "phase = .emailVerification")
        )
        let checkpoint = try XCTUnwrap(
            createSource.range(of: "checkpoint.captureAcceptedTerms(")
        )
        let delivery = try XCTUnwrap(
            createSource.range(of: "result.user.sendEmailVerification()")
        )

        XCTAssertLessThan(phase.lowerBound, checkpoint.lowerBound)
        XCTAssertLessThan(checkpoint.lowerBound, delivery.lowerBound)
        XCTAssertTrue(createSource.contains(#""partial""#))
        XCTAssertTrue(createSource.contains(#""identity_created""#))
    }

    func testRemoteRegistrationUsesRecoverableProgressPhase() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let reconciliation = try XCTUnwrap(
            source.range(of: "    private func reconcileRemote(user: User)")
        )
        let registration = try XCTUnwrap(
            source.range(
                of: "            case .accountRegistration:",
                range: reconciliation.upperBound..<source.endIndex
            )
        )
        let claim = try XCTUnwrap(
            source.range(
                of: "            case .claimPending:",
                range: registration.upperBound..<source.endIndex
            )
        )
        let block = source[registration.lowerBound..<claim.lowerBound]

        XCTAssertTrue(block.contains("phase = .registering"))
        XCTAssertTrue(
            source.contains(
                "phase = ownershipFailureRecoveryPhase("
            )
        )
    }

    func testRegistrationResumeReconcilesCommittedInstallationBeforeRetry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "    private func completeTermsAcceptance(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    private func reconcileIdentityEntry(",
                range: start.upperBound..<source.endIndex
            )
        )
        let block = source[start.lowerBound..<end.lowerBound]
        let accepted = try XCTUnwrap(
            block.range(of: "!bootstrap.termsAcceptanceRequired")
        )
        let overview = try XCTUnwrap(
            block.range(
                of: "client.overview(",
                range: accepted.upperBound..<block.endIndex
            )
        )
        let registration = try XCTUnwrap(
            block.range(
                of: "client.registerAccount(",
                range: overview.upperBound..<block.endIndex
            )
        )

        XCTAssertLessThan(accepted.lowerBound, overview.lowerBound)
        XCTAssertLessThan(overview.lowerBound, registration.lowerBound)
        XCTAssertTrue(block.contains(#""registration_reconciled""#))
    }

    func testCancellationIsHandledBeforeOwnershipFailureStateMutation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let reconciliation = try XCTUnwrap(
            source.range(of: "    private func reconcileRemote(user: User)")
        )
        let helper = try XCTUnwrap(
            source.range(
                of: "    private func finishCanceledOperation(",
                range: reconciliation.upperBound..<source.endIndex
            )
        )
        let block = source[reconciliation.lowerBound..<helper.lowerBound]
        let cancellation = try XCTUnwrap(
            block.range(
                of: "if finishCanceledOperation("
            )
        )
        let recoveryMutation = try XCTUnwrap(
            block.range(
                of: "phase = ownershipFailureRecoveryPhase("
            )
        )

        XCTAssertLessThan(
            cancellation.lowerBound,
            recoveryMutation.lowerBound
        )
        XCTAssertTrue(
            source.contains("if canceled { throw CancellationError() }")
        )
        XCTAssertTrue(
            source.contains(
                "recoverState: reconciliationMayUpdateState(generation)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "guard !isBusy || bootstrapBusyGeneration != nil else { return }"
            )
        )
        XCTAssertTrue(source.contains("bootstrapBusyGeneration = generation"))
        XCTAssertTrue(source.contains("let ownsBootstrapBusy = generation.map"))
        XCTAssertTrue(
            source.contains(
                "guard reconciliationMayUpdateState(generation) else"
            )
        )
        XCTAssertTrue(
            source.contains("invalidateBootstrapReconciliation()")
        )
    }

    func testIdentityHelperHandlesCancellationBeforeFailureMutation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "    private func performIdentityOperation(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    @discardableResult",
                range: start.upperBound..<source.endIndex
            )
        )
        let block = source[start.lowerBound..<end.lowerBound]
        let cancellation = try XCTUnwrap(
            block.range(
                of: "if finishCanceledOperation(error, diagnostic: diagnostic)"
            )
        )
        let failureMutation = try XCTUnwrap(
            block.range(
                of: "let reportedError = reconcileChangedTerms(error)"
            )
        )

        XCTAssertLessThan(cancellation.lowerBound, failureMutation.lowerBound)
        XCTAssertTrue(block.contains("ownershipFailureRecoveryPhase("))
        XCTAssertTrue(
            block.contains("Self.userMessage(for: reportedError)")
        )
        XCTAssertTrue(
            block.contains("Self.diagnosticOutcome(reportedError)")
        )
        XCTAssertTrue(
            block.contains("Self.diagnosticFailureKind(reportedError)")
        )
    }

    func testTermsChangeRecoveryIsWiredIntoAccountOperations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let boundaries = [
            ("    func refreshOverview()", "    private func loadOverview("),
            (
                "    private func performIdentityOperation(",
                "    @discardableResult"
            ),
            (
                "    private func reconcileRemote(user: User)",
                "    private func completeTermsAcceptance("
            ),
        ]

        for (startMarker, endMarker) in boundaries {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(
                source.range(
                    of: endMarker,
                    range: start.upperBound..<source.endIndex
                )
            )
            let block = source[start.lowerBound..<end.lowerBound]
            XCTAssertTrue(
                block.contains(
                    "let reportedError = reconcileChangedTerms(error)"
                ),
                startMarker
            )
            XCTAssertTrue(
                block.contains("ownershipFailureRecoveryPhase("),
                startMarker
            )
            XCTAssertTrue(
                block.contains("Self.isTermsChanged(reportedError)"),
                startMarker
            )
            XCTAssertTrue(
                block.contains("Self.userMessage(for: reportedError)"),
                startMarker
            )
            XCTAssertTrue(
                block.contains("Self.diagnosticOutcome(reportedError)"),
                startMarker
            )
            XCTAssertTrue(
                block.contains("Self.diagnosticFailureKind(reportedError)"),
                startMarker
            )
        }
    }

    func testPlanSelectionConfirmsRemoteOrDefersWithoutBlockingCore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "StrandiOS/System/OwnershipService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(
                of: "    func selectPlan(_ plan: NoopProductPlan) async -> Bool"
            )
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    func refreshOverview()",
                range: start.upperBound..<source.endIndex
            )
        )
        let block = source[start.lowerBound..<end.lowerBound]
        let remoteWrite = try XCTUnwrap(
            block.range(of: "try await client.selectPlan(")
        )
        let readBack = try XCTUnwrap(
            block.range(of: "let loadedOverview = try await client.overview(")
        )
        let persisted = try XCTUnwrap(
            block.range(of: "plan.persist()")
        )
        let completion = try XCTUnwrap(
            block.range(
                of: "checkpoint.completePlanSelection(",
                range: readBack.upperBound..<block.endIndex
            )
        )
        let success = try XCTUnwrap(
            block.range(
                of: "return true",
                range: completion.upperBound..<block.endIndex
            )
        )
        let deferred = try XCTUnwrap(
            block.range(
                of: #"outcome: "deferred""#,
                range: success.upperBound..<block.endIndex
            )
        )
        let localFallback = try XCTUnwrap(
            block.range(
                of: "return true",
                range: deferred.upperBound..<block.endIndex
            )
        )

        XCTAssertTrue(block.contains("guard isAvailable else"))
        XCTAssertTrue(block.contains("let currentUser = try currentUser"))
        XCTAssertLessThan(persisted.lowerBound, remoteWrite.lowerBound)
        XCTAssertLessThan(remoteWrite.lowerBound, readBack.lowerBound)
        XCTAssertLessThan(readBack.lowerBound, completion.lowerBound)
        XCTAssertLessThan(completion.lowerBound, success.lowerBound)
        XCTAssertLessThan(success.lowerBound, deferred.lowerBound)
        XCTAssertLessThan(deferred.lowerBound, localFallback.lowerBound)
        XCTAssertTrue(
            block.contains(
                "Preference saved on this phone. Open Band Account later to finish account sync."
            )
        )
        XCTAssertTrue(block.contains("return false"))
    }
}

private extension OwnershipServicePhase {
    static let allCases: [Self] = [
        .unavailable,
        .localRecoveryRequired,
        .signedOut,
        .emailVerification,
        .termsReview,
        .registering,
        .accountReady,
        .possessionUnavailable,
        .claiming,
        .claimed,
        .complete,
        .replacementRequired,
        .authorizingReplacement,
    ]

    static let allRecoveryStableCases: [Self] = [
        .unavailable,
        .localRecoveryRequired,
        .signedOut,
        .emailVerification,
        .termsReview,
        .accountReady,
        .possessionUnavailable,
        .claiming,
        .claimed,
        .complete,
        .replacementRequired,
    ]
}
