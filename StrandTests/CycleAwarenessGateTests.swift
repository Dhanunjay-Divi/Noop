import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Guards the #801 cycle-awareness profile gate. Cycle phase is read from the MENSTRUAL skin-temperature
/// shift, so the opt-in (the Health `CycleAwarenessOptInCard` and the Automations "Cycle awareness"
/// toggle) is only offered to profiles it can apply to and is NOT rendered for male profiles. Both
/// surfaces resolve their visibility through `ProfileStore.cycleAwarenessApplies`, so pinning that one
/// predicate keeps Health and Automations in lockstep and stops a male profile from enabling a feature
/// whose card it can never see.
final class CycleAwarenessGateTests: XCTestCase {

    /// Male profiles must NOT be offered the opt-in (the core of #801).
    func testMaleProfileIsExcluded() {
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "male"))
    }

    /// The profiles the menstrual-cycle read applies to (female / nonbinary) DO see the opt-in.
    func testFemaleAndNonbinaryAreIncluded() {
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "female"))
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "nonbinary"))
    }

    /// The gate is case- and whitespace-insensitive so a stored "Male"/" male " never slips through as
    /// non-male (the picker writes lowercase tokens today, but we don't want a casing change to leak it).
    func testGateNormalisesCaseAndWhitespace() {
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "Male"))
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "MALE"))
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "  male  "))
    }

    /// Fail OPEN, not closed: an unrecognised value still sees the opt-in rather than being silently
    /// excluded; only an explicit "male" is gated out.
    func testUnknownValueDefaultsToShowingTheOptIn() {
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: ""))
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "intersex"))
    }

    /// The instance accessor reflects the live `sex` field, so the views (which read
    /// `model.profile.cycleAwarenessApplies`) track a profile change.
    @MainActor
    func testInstanceAccessorTracksTheStoredSex() {
        let store = ProfileStore()
        store.sex = "male"
        XCTAssertFalse(store.cycleAwarenessApplies)
        store.sex = "female"
        XCTAssertTrue(store.cycleAwarenessApplies)
    }
}

/// Seed profile values are presentation defaults, not consent to use them in age-shaped estimates.
/// This pure gate also pins the legacy-onboarding migration without mutating global UserDefaults.
final class ProfileAgeInputConfirmationTests: XCTestCase {
    func testFreshSeedProfileIsNotConfirmed() {
        XCTAssertFalse(ProfileStore.fitnessInputsAreConfirmed(
            ageConfirmed: false, sexConfirmed: false, onboardingCompleted: false))
    }

    func testBothInputsMustBeConfirmed() {
        XCTAssertFalse(ProfileStore.fitnessInputsAreConfirmed(
            ageConfirmed: true, sexConfirmed: false, onboardingCompleted: false))
        XCTAssertFalse(ProfileStore.fitnessInputsAreConfirmed(
            ageConfirmed: false, sexConfirmed: true, onboardingCompleted: false))
        XCTAssertTrue(ProfileStore.fitnessInputsAreConfirmed(
            ageConfirmed: true, sexConfirmed: true, onboardingCompleted: false))
    }

    func testCompletedLegacyOnboardingMigratesAsConfirmed() {
        XCTAssertTrue(ProfileStore.fitnessInputsAreConfirmed(
            ageConfirmed: false, sexConfirmed: false, onboardingCompleted: true))
    }

    @MainActor
    func testFitnessAgeRowsRejectUnconfirmedSeedProfile() {
        let days = (1...4).map { i in
            DailyMetric(day: "2026-08-0\(i)", totalSleepMin: 420, efficiency: 0.9,
                        deepMin: 80, remMin: 100, lightMin: 240, disturbances: 1,
                        restingHr: 60, avgHrv: 55, recovery: nil, strain: 55,
                        exerciseCount: 1)
        }
        let rows = IntelligenceEngine.fitnessAgeRows(
            gateDays: days, age: 30, sex: "male", waistCm: 0,
            computedId: "test-noop", satKey: "2026-08-08",
            ageConfirmed: false, sexConfirmed: false)
        XCTAssertTrue(rows.isEmpty)
    }
}
