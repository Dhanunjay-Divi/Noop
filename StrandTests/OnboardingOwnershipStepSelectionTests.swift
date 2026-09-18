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

    func testUnconfiguredCoreModeOmitsAccountStepAndKeepsProfile() {
        let steps = OnboardingWizard.onboardingSteps(
            ownershipConfigured: false
        )

        XCTAssertFalse(steps.contains(.ownership))
        XCTAssertTrue(steps.contains(.profile))
        XCTAssertEqual(
            steps.firstIndex(of: .profile),
            steps.firstIndex(of: .bonded).map { $0 + 1 }
        )
    }

    func testUnconfiguredCoreModeResumesSavedOwnershipStepAtProfile() {
        XCTAssertEqual(
            OnboardingWizard.restoredOnboardingStep(
                storedValue: OnboardingWizard.Step.ownership.storageValue,
                ownershipConfigured: false
            ),
            .profile
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
