import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class DaytimeStressTests: XCTestCase {

    /// Fill one local hour-of-day with `n` 1 Hz HR samples at `bpm` (UTC, tz offset 0).
    private func hourHR(_ hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        let base = hour * 3_600
        return (0..<n).map { HRSample(ts: base + $0, bpm: bpm) }
    }

    func testEmptyWhenNoHR() {
        XCTAssertEqual(DaytimeStress.analyze(hr: [], rr: []), .empty)
    }

    func testHourBelowGateIsUnscored() {
        // One waking hour with too few HR samples → present but unscored (honest gap).
        let hr = hourHR(9, bpm: 70, n: DaytimeStress.minHourHRSamples - 1)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.scored.isEmpty, "an under-gate hour must not be scored")
    }

    func testScoresMapOntoZeroToThree() {
        // Three calm hours + one tense hour (high HR). All scored values stay within 0…3.
        var hr: [HRSample] = []
        hr += hourHR(8, bpm: 62)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 61)
        hr += hourHR(11, bpm: 95)   // the spike
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.scored.isEmpty)
        for p in r.scored {
            let lvl = p.level!
            XCTAssertGreaterThanOrEqual(lvl, 0)
            XCTAssertLessThanOrEqual(lvl, 3)
        }
        // The high-HR hour must be the day's peak and read above the calm hours.
        XCTAssertEqual(r.peak?.hour, 11)
        let calm = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, calm)
    }

    func testNonWakingHoursAreExcluded() {
        // A 3 am hour (outside 06:00–22:00) is never placed on the waking timeline.
        let hr = hourHR(3, bpm: 80) + hourHR(9, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.hours.contains { $0.hour == 3 })
        XCTAssertTrue(r.hours.contains { $0.hour == 9 })
    }

    func testSustainedHighFlagsAfterThreeConsecutiveHighHours() {
        // A calm morning, then three adjacent tense afternoon hours with HRV evidence.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }   // calm baseline hours
        for h in [8, 9, 10] { rr += hourRRVariable(h, rrMs: 900, jitter: 40) }
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        for h in [13, 14, 15] { rr += hourRRVariable(h, rrMs: 900, jitter: 2) }
        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        XCTAssertTrue(r.sustainedHigh, "three trailing HIGH hours should flag sustained stress")
        XCTAssertGreaterThanOrEqual(r.sustainedRun, DaytimeStress.sustainedHours)
        XCTAssertEqual(r.hrvBackedHourCount, 6)
        XCTAssertTrue(r.scored.suffix(3).allSatisfy { $0.evidence == .heartRateAndHRV })
    }

    func testGappedHighHoursDoNotCountAsSustained() {
        // Three individually HIGH, HRV-backed hours separated by gaps are not a three-hour run.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10] {
            hr += hourHR(h, bpm: 58)
            rr += hourRRVariable(h, rrMs: 900, jitter: 40)
        }
        for h in [13, 15, 17] {
            hr += hourHR(h, bpm: 125)
            rr += hourRRVariable(h, rrMs: 900, jitter: 2)
        }

        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        let trailingElevated = r.scored.filter { [13, 15, 17].contains($0.hour) }
        XCTAssertEqual(trailingElevated.count, 3)
        XCTAssertTrue(trailingElevated.allSatisfy {
            ($0.level ?? 0) >= DaytimeStress.highBandFloor && $0.hasHRVEvidence
        })
        XCTAssertFalse(r.sustainedHigh,
                       "missing wall-clock hours must break an otherwise high, HRV-backed run")
        XCTAssertEqual(r.sustainedRun, 1, "only the latest isolated high hour belongs to the run")
    }

    func testHROnlyHighHoursRemainVisibleButCannotTriggerSustained() {
        // HR alone may draw the timeline, but it cannot justify an autonomic-stress nudge.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }
        for h in [13, 14, 15] { hr += hourHR(h, bpm: 125) }

        let r = DaytimeStress.analyze(hr: hr, rr: [])
        let trailing = Array(r.scored.suffix(3))
        XCTAssertEqual(trailing.count, 3)
        XCTAssertTrue(trailing.allSatisfy { ($0.level ?? 0) >= DaytimeStress.highBandFloor },
                      "HR-only activation should remain visible on the timeline")
        XCTAssertTrue(trailing.allSatisfy { $0.evidence == .heartRateOnly })
        XCTAssertFalse(r.sustainedHigh, "HR-only hours must never trigger the sustained suggestion")
        XCTAssertEqual(r.sustainedRun, 0)
    }

    func testFlatDayDoesNotFlagSustained() {
        // Every hour at the same HR → no hour is meaningfully elevated, no flag.
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 64) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.sustainedHigh)
        // A flat day sits around the baseline (≈1.5), not pinned high.
        if let mean = r.dayMean { XCTAssertLessThan(mean, DaytimeStress.highBandFloor) }
    }

    func testSleepHoursInTheWindowDoNotShiftTheWakingTimeline() {
        // Regression: the calm reference is built from the WAKING hours that are actually
        // scored, not the whole 24 h. The analysis window always starts at local midnight, so
        // the current day routinely carries several hours of sleep — the calmest, lowest-HR
        // stretch of the day. If those night hours leak into the reference they drag the "calm"
        // anchor far below every waking hour, inflating an ordinary calm day into sustained
        // high stress (tripping the passive Breathe nudge). So adding calm sleep hours to the
        // input must NOT change the waking timeline.
        let waking: [HRSample] = zip(6...17, [62, 64, 63, 65, 64, 63, 62, 64, 66, 63, 64, 65])
            .flatMap { hourHR($0.0, bpm: $0.1) }
        let sleep: [HRSample] = zip(0...5, [50, 51, 52, 51, 50, 53])
            .flatMap { hourHR($0.0, bpm: $0.1) }

        let wakingOnly = DaytimeStress.analyze(hr: waking, rr: [])
        let withSleep = DaytimeStress.analyze(hr: sleep + waking, rr: [])

        XCTAssertEqual(withSleep.sustainedHigh, wakingOnly.sustainedHigh,
            "sleep hours sharing the window must not change the sustained-high verdict")
        for h in 6...17 {
            guard let withLvl = withSleep.scored.first(where: { $0.hour == h })?.level,
                  let withoutLvl = wakingOnly.scored.first(where: { $0.hour == h })?.level else {
                XCTFail("waking hour \(h) should be scored in both runs"); continue
            }
            XCTAssertEqual(withLvl, withoutLvl, accuracy: 1e-9,
                "the night's sleep hours leaked into the daytime reference and shifted waking hour \(h)")
        }
        // The plain sanity check the bug violated: an ordinary calm day is not "sustained high".
        XCTAssertFalse(withSleep.sustainedHigh,
            "a calm desk day must not read as sustained high stress")
    }

    func testTimezoneOffsetShiftsWakingWindow() {
        // ts at UTC hour 4 with a +3 h offset lands at local hour 7 → inside waking hours.
        let hr = hourHR(4, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 3 * 3_600)
        XCTAssertTrue(r.hours.contains { $0.hour == 7 })
    }

    func testRMSSDLowersStressDirectionMatchesDailyScore() {
        // Same HR across hours; the hour with the LOWEST HRV (RMSSD) should read more
        // stressed — the same directionality as the daily score (HRV down = stress).
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 65) }
        // High-variability (relaxed) hours vs one low-variability (tense) hour.
        rr += hourRRVariable(8, rrMs: 900, jitter: 40)
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(10, rrMs: 900, jitter: 40)
        rr += hourRRVariable(11, rrMs: 900, jitter: 2)   // suppressed HRV
        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        let relaxed = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, relaxed)
    }

    /// R-R for one hour with a controllable beat-to-beat jitter (drives RMSSD).
    private func hourRRVariable(_ hour: Int, rrMs: Int, jitter: Int, n: Int = 60) -> [RRInterval] {
        let base = hour * 3_600
        return (0..<n).map { RRInterval(ts: base + $0 * 50, rrMs: rrMs + ($0 % 2 == 0 ? jitter : -jitter)) }
    }
}
