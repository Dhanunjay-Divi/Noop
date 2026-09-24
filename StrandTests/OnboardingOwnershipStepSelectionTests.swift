import XCTest
@testable import Strand
import WhoopStore

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
                deviceSetupComplete: false
            ),
            String(localized: "appwide.onboarding.continue_without_band")
        )
        XCTAssertEqual(
            OnboardingWizard.scanCTATitle(
                ownershipConfigured: true,
                deviceSetupComplete: false
            ),
            String(localized: "Continue")
        )
        XCTAssertEqual(
            OnboardingWizard.scanCTATitle(
                ownershipConfigured: false,
                deviceSetupComplete: true
            ),
            String(localized: "Continue")
        )
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
}
