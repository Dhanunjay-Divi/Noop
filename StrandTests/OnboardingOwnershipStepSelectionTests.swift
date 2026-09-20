import XCTest
@testable import Strand

final class OnboardingOwnershipStepSelectionTests: XCTestCase {
    func testConfiguredOwnershipIncludesAccountStepWithoutConstructingRuntimeService() {
        let steps = OnboardingWizard.onboardingSteps(
            ownershipConfigured: true
        )

        XCTAssertTrue(steps.contains(.ownership))
        XCTAssertEqual(
            steps.firstIndex(of: .ownership),
            steps.firstIndex(of: .bonded).map { $0 + 1 }
        )
        XCTAssertEqual(
            steps.firstIndex(of: .profile),
            steps.firstIndex(of: .ownership).map { $0 + 1 }
        )
    }

    func testUnconfiguredCoreModeKeepsAccountStepVisibleBeforeProfile() {
        let steps = OnboardingWizard.onboardingSteps(
            ownershipConfigured: false
        )

        XCTAssertTrue(steps.contains(.ownership))
        XCTAssertTrue(steps.contains(.profile))
        XCTAssertEqual(
            steps.firstIndex(of: .ownership),
            steps.firstIndex(of: .bonded).map { $0 + 1 }
        )
        XCTAssertEqual(
            steps.firstIndex(of: .profile),
            steps.firstIndex(of: .ownership).map { $0 + 1 }
        )
    }

    func testUnconfiguredCoreModeResumesSavedOwnershipStepExactly() {
        XCTAssertEqual(
            OnboardingWizard.restoredOnboardingStep(
                storedValue: OnboardingWizard.Step.ownership.storageValue,
                ownershipConfigured: false
            ),
            .ownership
        )
    }

    func testConfiguredOwnershipResumesSavedOwnershipStepExactly() {
        XCTAssertEqual(
            OnboardingWizard.restoredOnboardingStep(
                storedValue: OnboardingWizard.Step.ownership.storageValue,
                ownershipConfigured: true
            ),
            .ownership
        )
    }

    func testConfiguredOwnershipRestoresPostOwnershipCheckpointsBeforeReconciliation() {
        for step in OnboardingWizard.Step.allCases
        where step.rawValue > OnboardingWizard.Step.ownership.rawValue {
            XCTAssertEqual(
                OnboardingWizard.restoredOnboardingStep(
                    storedValue: step.storageValue,
                    ownershipConfigured: true
                ),
                step
            )
        }
    }

    func testTransientOwnershipBootstrapDoesNotResolveOrPersistRedirect() {
        for step in OnboardingWizard.Step.allCases
        where step.rawValue > OnboardingWizard.Step.ownership.rawValue {
            XCTAssertNil(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: false,
                    phase: .signedOut
                ),
                "\(step) must stay restored until bootstrap reconciliation settles"
            )
        }
    }

    func testResolvedUnclaimedOwnershipRedirectsPostOwnershipSteps() {
        for step in OnboardingWizard.Step.allCases
        where step.rawValue > OnboardingWizard.Step.ownership.rawValue {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .signedOut
                ),
                .ownership
            )
        }
    }

    func testResolvedClaimedOwnershipPreservesPostOwnershipSteps() {
        for phase in [OwnershipServicePhase.claimed, .complete] {
            for step in OnboardingWizard.Step.allCases
            where step.rawValue > OnboardingWizard.Step.ownership.rawValue {
                XCTAssertEqual(
                    OnboardingWizard.ownershipDestination(
                        for: step,
                        ownershipConfigured: true,
                        reconciliationComplete: true,
                        phase: phase
                    ),
                    step
                )
            }
        }
    }

    func testUnconfiguredCoreModeNeverWaitsForOwnershipReconciliation() {
        XCTAssertEqual(
            OnboardingWizard.ownershipDestination(
                for: .done,
                ownershipConfigured: false,
                reconciliationComplete: false,
                phase: .unavailable
            ),
            .done
        )
    }

    func testUnconfiguredAccountStepContinuesWithoutClaimOrReconciliation() {
        XCTAssertTrue(
            OnboardingWizard.ownershipStepCanContinue(
                ownershipConfigured: false,
                claimed: false,
                reconciliationComplete: false
            )
        )
    }

    func testUnconfiguredScanNamesTheOfflinePathExplicitly() {
        XCTAssertEqual(
            OnboardingWizard.scanCTATitle(
                ownershipConfigured: false,
                bandBonded: false
            ),
            String(localized: "appwide.onboarding.continue_without_band")
        )
        XCTAssertEqual(
            OnboardingWizard.scanCTATitle(
                ownershipConfigured: true,
                bandBonded: false
            ),
            String(localized: "Continue")
        )
        XCTAssertEqual(
            OnboardingWizard.scanCTATitle(
                ownershipConfigured: false,
                bandBonded: true
            ),
            String(localized: "Continue")
        )
    }

    func testConfiguredAccountStepRequiresSettledClaim() {
        XCTAssertFalse(
            OnboardingWizard.ownershipStepCanContinue(
                ownershipConfigured: true,
                claimed: false,
                reconciliationComplete: true
            )
        )
        XCTAssertFalse(
            OnboardingWizard.ownershipStepCanContinue(
                ownershipConfigured: true,
                claimed: true,
                reconciliationComplete: false
            )
        )
        XCTAssertTrue(
            OnboardingWizard.ownershipStepCanContinue(
                ownershipConfigured: true,
                claimed: true,
                reconciliationComplete: true
            )
        )
    }

    func testAbsentOrUnknownSavedStepStartsAtWelcome() {
        XCTAssertEqual(
            OnboardingWizard.restoredOnboardingStep(
                storedValue: nil,
                ownershipConfigured: false
            ),
            .welcome
        )
        XCTAssertEqual(
            OnboardingWizard.restoredOnboardingStep(
                storedValue: "not-a-step",
                ownershipConfigured: false
            ),
            .welcome
        )
    }
}
