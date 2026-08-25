import XCTest
@testable import StrandAnalytics

/// Guards the between-person behaviour of Recovery, which every single-wearer test is blind to.
///
/// Measured on three real WHOOP exports (904 days, three unrelated wearers): NOOP compressed the wearers'
/// mean Recovery into a 1.9-point range while the reference spread them over 7.6 - a 4x compression. That is
/// structural, not a bug: HRV, resting HR and respiration are z-scored against each wearer's OWN baseline,
/// so every person's mean z is ~0 by construction and everyone lands on the same anchor.
///
/// This test does not call that wrong. It pins it, so that:
///   • nobody "fixes" the reported bias with a constant offset and believes the compression went away, and
///   • if a future change makes Recovery genuinely comparable BETWEEN people, this test fails and forces
///     that to be a deliberate, documented decision.
///
/// See docs/validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md.
final class RecoveryBetweenPersonScaleTests: XCTestCase {

    /// One synthetic wearer: a stable person whose own baseline equals their own typical values.
    private func meanScore(hrv: Double, rhr: Double, resp: Double, sleepPerf: Double) -> Double {
        // Baselines are the wearer's own typical values, which is what a settled personal baseline is.
        let score = RecoveryScorer.recovery(
            hrv: hrv, rhr: rhr, resp: resp,
            hrvBaseline: .init(mean: hrv, spread: max(hrv * 0.15, 1)),
            rhrBaseline: .init(mean: rhr, spread: max(rhr * 0.08, 1)),
            respBaseline: .init(mean: resp, spread: 1.0),
            sleepPerf: sleepPerf
        )
        return score ?? -1
    }

    func testRecoveryIsPersonalRelativeAndNotComparableBetweenPeople() {
        // Three wearers with genuinely different physiology, each sitting exactly on their own baseline.
        let athlete   = meanScore(hrv: 110, rhr: 42, resp: 12.5, sleepPerf: 0.88)
        let typical   = meanScore(hrv: 50,  rhr: 60, resp: 15.0, sleepPerf: 0.80)
        let unfit     = meanScore(hrv: 22,  rhr: 78, resp: 17.5, sleepPerf: 0.72)

        for (name, value) in [("athlete", athlete), ("typical", typical), ("unfit", unfit)] {
            XCTAssertGreaterThanOrEqual(value, 0, "\(name): engine declined on a complete input set")
        }

        // Each is ON their own baseline, so the three baseline-relative drivers contribute ~0 for all of
        // them. Any spread that remains comes from the SLEEP term, which is the one absolute driver.
        let spread = max(athlete, typical, unfit) - min(athlete, typical, unfit)
        XCTAssertLessThan(spread, 25.0, """
            Recovery spread across three physiologically different wearers who are each exactly on their own \
            baseline was \(spread) points. If this grew, Recovery has become partly absolute, which changes \
            what the number MEANS and makes it comparable between people. That may be desirable - but it \
            must be a deliberate decision, and Friends/social surfaces that show one person's Recovery \
            beside another's need revisiting at the same time. \
            See docs/validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md.
            """)

        // The residual spread should be attributable to the sleep term alone: hold it constant and the
        // three wearers must collapse onto essentially the same score.
        let sameSleep = [
            meanScore(hrv: 110, rhr: 42, resp: 12.5, sleepPerf: 0.80),
            meanScore(hrv: 50,  rhr: 60, resp: 15.0, sleepPerf: 0.80),
            meanScore(hrv: 22,  rhr: 78, resp: 17.5, sleepPerf: 0.80),
        ]
        let collapsedSpread = sameSleep.max()! - sameSleep.min()!
        XCTAssertLessThan(collapsedSpread, 1.0, """
            With the one absolute driver (sleep) held equal, three very different wearers on their own \
            baselines should score identically, confirming Recovery is purely personal-relative. Spread was \
            \(collapsedSpread).
            """)
    }

    /// The absolute sleep centre is the only driver that can bias a whole population. Three real wearers
    /// averaged 73-76% sleep performance against a 0.85 centre, so all three carried a permanent penalty.
    func testSleepTermPenalisesTypicalRealWorldSleepPerformance() {
        let atCentre = meanScore(hrv: 50, rhr: 60, resp: 15.0, sleepPerf: RecoveryScorer.sleepPerfCenter)
        let atObservedNorm = meanScore(hrv: 50, rhr: 60, resp: 15.0, sleepPerf: 0.75)
        XCTAssertLessThan(atObservedNorm, atCentre,
                          "A wearer at the observed real-world norm (~75%) should score below one at the "
                          + "hard-coded 0.85 centre; that gap is the population-wide penalty.")
        let penalty = atCentre - atObservedNorm
        XCTAssertGreaterThan(penalty, 1.0,
                             "Expected a measurable penalty from the absolute sleep centre; got \(penalty). "
                             + "If this vanished, the sleep term was made baseline-relative - update "
                             + "docs/validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md Finding D.")
        print("\nabsolute sleep-centre penalty at the observed 75% norm: \(String(format: "%.1f", penalty)) points")
    }
}
