import XCTest
@testable import Strand
import WhoopStore

final class OnboardingOwnershipStepSelectionTests: XCTestCase {
    func testFirstRunUsesConciseAccountFirstSequence() {
        let steps = OnboardingWizard.onboardingSteps(
            ownershipConfigured: true
        )

        XCTAssertEqual(
            steps,
            [
                .welcome,
                .account,
                .bluetooth,
                .scan,
                .ownership,
                .profile,
                .plan,
                .done,
            ]
        )
    }

    func testUnconfiguredBuildKeepsTheSameVisibleJourney() {
        let steps = OnboardingWizard.onboardingSteps(
            ownershipConfigured: false
        )

        XCTAssertEqual(
            steps,
            OnboardingWizard.onboardingSteps(ownershipConfigured: true)
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

    func testRemovedCheckpointsRestartTheAccountFirstJourney() {
        for step in [
            OnboardingWizard.Step.what,
            .expectations,
            .wear,
            .bonded,
            .importData,
            .notifications,
            .safetyContacts,
            .appearance,
            .dailyRhythm,
        ] {
            XCTAssertEqual(restored(step), .welcome)
        }
    }

    func testTransientOwnershipBootstrapDoesNotResolveOrPersistRedirect() {
        for step in [
            OnboardingWizard.Step.bluetooth,
            .scan,
            .ownership,
            .profile,
            .plan,
            .done,
        ] {
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

    func testSignedOutAccountRedirectsEveryLaterStepToAccount() {
        for step in [
            OnboardingWizard.Step.bluetooth,
            .scan,
            .ownership,
            .profile,
            .plan,
            .done,
        ] {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .signedOut
                ),
                .account
            )
        }
    }

    func testAccountReadyAllowsBandSetupButSupplierClaimGatesProfile() {
        for step in [
            OnboardingWizard.Step.bluetooth,
            .scan,
            .ownership,
        ] {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .accountReady,
                    supplierClaimRequired: true
                ),
                step
            )
        }

        for step in [
            OnboardingWizard.Step.profile,
            .plan,
            .done,
        ] {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .accountReady,
                    supplierClaimRequired: true
                ),
                .ownership
            )
        }
    }

    func testAccountReadyWhoopPathDoesNotRequireSupplierClaim() {
        for step in [
            OnboardingWizard.Step.bluetooth,
            .scan,
            .ownership,
            .profile,
            .plan,
            .done,
        ] {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .accountReady,
                    supplierClaimRequired: false
                ),
                step
            )
        }
    }

    func testPostScanPagesRequireDurableDeviceSetupAfterRelaunch() {
        for step in [
            OnboardingWizard.Step.ownership,
            .profile,
            .plan,
            .done,
        ] {
            XCTAssertEqual(
                OnboardingWizard.ownershipDestination(
                    for: step,
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: .accountReady,
                    supplierClaimRequired: false,
                    deviceSetupComplete: false
                ),
                .scan,
                "\(step) must not trust transient pre-relaunch setup state"
            )
        }
    }

    func testUnconfiguredBuildAlsoRequiresDurableDeviceSetup() {
        XCTAssertEqual(
            OnboardingWizard.ownershipDestination(
                for: .done,
                ownershipConfigured: false,
                reconciliationComplete: false,
                phase: .unavailable,
                supplierClaimRequired: false,
                deviceSetupComplete: false
            ),
            .scan
        )
    }

    func testResolvedClaimedOwnershipPreservesActiveSteps() {
        for phase in [OwnershipServicePhase.claimed, .complete] {
            for step in OnboardingWizard.onboardingSteps(
                ownershipConfigured: true
            ) {
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

    func testUnconfiguredAccountStepContinuesWithoutReconciliation() {
        XCTAssertTrue(
            OnboardingWizard.accountStepCanContinue(
                ownershipConfigured: false,
                reconciliationComplete: false,
                phase: .unavailable
            )
        )
    }

    func testConfiguredAccountRequiresSettledReadyPhase() {
        XCTAssertFalse(
            OnboardingWizard.accountStepCanContinue(
                ownershipConfigured: true,
                reconciliationComplete: false,
                phase: .accountReady
            )
        )
        for phase in [
            OwnershipServicePhase.signedOut,
            .emailVerification,
            .termsReview,
            .registering,
            .deletionPending,
        ] {
            XCTAssertFalse(
                OnboardingWizard.accountStepCanContinue(
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: phase
                )
            )
        }
        for phase in [
            OwnershipServicePhase.accountReady,
            .possessionUnavailable,
            .claimed,
            .complete,
            .replacementRequired,
        ] {
            XCTAssertTrue(
                OnboardingWizard.accountStepCanContinue(
                    ownershipConfigured: true,
                    reconciliationComplete: true,
                    phase: phase
                )
            )
        }
    }

    func testUntouchedSeedAndImportsDoNotCompleteDeviceSetup() {
        let seed = pairedDevice(
            id: "my-whoop",
            peripheralID: nil,
            sourceKind: .liveBLE,
            status: .active
        )
        let imported = pairedDevice(
            id: "wearable-import",
            peripheralID: nil,
            sourceKind: .fileImport,
            status: .paired
        )
        let activityFile = pairedDevice(
            id: "activity-file",
            peripheralID: nil,
            sourceKind: .activityFile,
            status: .paired
        )

        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [seed, imported, activityFile],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            )
        )
    }

    func testGenericLiveBLEOnlyCompletesOptionalDeviceSetup() {
        let genericStrap = pairedDevice(
            id: "polar-h10",
            brand: "Polar",
            peripheralID: "opaque-peripheral",
            sourceKind: .liveBLE,
            status: .active
        )

        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [genericStrap],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            )
        )
        XCTAssertEqual(
            OnboardingWizard.completedDeviceSetupSource(
                in: [genericStrap],
                requiresClaimEligibleBand: false,
                supplierUsable: { _ in false }
            ),
            .liveBLE
        )
    }

    func testSupplierRegistryCommitRequiresUsableRuntimeRegistration() {
        let supplier = pairedDevice(
            id: "supplier-band",
            brand: "Supplier",
            peripheralID: "opaque-peripheral",
            sourceKind: .veepoo,
            status: .active
        )

        XCTAssertEqual(
            OnboardingWizard.completedDeviceSetupSource(
                in: [supplier],
                requiresClaimEligibleBand: true,
                supplierUsable: { $0.id == supplier.id }
            ),
            .veepoo
        )
        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [supplier],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            )
        )
        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [supplier],
                requiresClaimEligibleBand: false,
                supplierUsable: { _ in false }
            )
        )
    }

    func testActiveSupplierWinsOverOlderPairedCompatibleBandOnRestart() {
        let olderCompatibleBand = pairedDevice(
            id: "whoop-test-band",
            brand: "WHOOP",
            peripheralID: "older-compatible-peripheral",
            sourceKind: .liveBLE,
            status: .paired
        )
        let activeSupplier = pairedDevice(
            id: "supplier-band",
            brand: "Supplier",
            peripheralID: "active-supplier-peripheral",
            sourceKind: .veepoo,
            status: .active
        )

        XCTAssertEqual(
            OnboardingWizard.completedDeviceSetupSource(
                in: [olderCompatibleBand, activeSupplier],
                requiresClaimEligibleBand: true,
                supplierUsable: { $0.id == activeSupplier.id }
            ),
            .veepoo
        )
        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [olderCompatibleBand, activeSupplier],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            ),
            "An unusable active supplier row must not fall through to an older paired test band."
        )
    }

    func testUntouchedActiveSeedStillAllowsPairedCompatibleTestBand() {
        let untouchedSeed = pairedDevice(
            id: "my-whoop",
            peripheralID: nil,
            sourceKind: .liveBLE,
            status: .active
        )
        let pairedCompatibleBand = pairedDevice(
            id: "whoop-test-band",
            brand: "WHOOP",
            peripheralID: "paired-compatible-peripheral",
            sourceKind: .liveBLE,
            status: .paired
        )

        XCTAssertEqual(
            OnboardingWizard.completedDeviceSetupSource(
                in: [untouchedSeed, pairedCompatibleBand],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            ),
            .liveBLE
        )
    }

    func testCanonicalWhoopRowCompletesConfiguredBandSetup() {
        let whoop = pairedDevice(
            id: "whoop-test-band",
            brand: "WHOOP",
            peripheralID: "opaque-peripheral",
            sourceKind: .liveBLE,
            status: .active
        )

        XCTAssertEqual(
            OnboardingWizard.completedDeviceSetupSource(
                in: [whoop],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in false }
            ),
            .liveBLE
        )
    }

    func testConfiguredSetupRejectsMismatchedWhoopMetadataAndBlankIdentity() {
        let mismatched = pairedDevice(
            id: "not-a-band",
            brand: "WHOOP",
            peripheralID: "opaque-peripheral",
            sourceKind: .ftms,
            status: .active
        )
        let blankIdentity = pairedDevice(
            id: "whoop-test-band",
            brand: "WHOOP",
            peripheralID: " ",
            sourceKind: .liveBLE,
            status: .paired
        )

        XCTAssertNil(
            OnboardingWizard.completedDeviceSetupSource(
                in: [mismatched, blankIdentity],
                requiresClaimEligibleBand: true,
                supplierUsable: { _ in true }
            )
        )
    }

    func testSupplierClaimStepRequiresSettledClaim() {
        XCTAssertFalse(
            OnboardingWizard.claimStepCanContinue(
                supplierClaimRequired: true,
                claimed: false,
                reconciliationComplete: true
            )
        )
        XCTAssertFalse(
            OnboardingWizard.claimStepCanContinue(
                supplierClaimRequired: true,
                claimed: true,
                reconciliationComplete: false
            )
        )
        XCTAssertTrue(
            OnboardingWizard.claimStepCanContinue(
                supplierClaimRequired: true,
                claimed: true,
                reconciliationComplete: true
            )
        )
        XCTAssertTrue(
            OnboardingWizard.claimStepCanContinue(
                supplierClaimRequired: false,
                claimed: false,
                reconciliationComplete: false
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

    private func pairedDevice(
        id: String,
        brand: String = "Test",
        peripheralID: String?,
        sourceKind: SourceKind,
        status: DeviceStatus
    ) -> PairedDevice {
        PairedDevice(
            id: id,
            brand: brand,
            model: "Test",
            peripheralId: peripheralID,
            sourceKind: sourceKind,
            capabilities: [.hr],
            status: status,
            addedAt: 1,
            lastSeenAt: 1
        )
    }

    private func restored(
        _ step: OnboardingWizard.Step
    ) -> OnboardingWizard.Step {
        OnboardingWizard.restoredOnboardingStep(
            storedValue: step.storageValue,
            ownershipConfigured: true
        )
    }
}
