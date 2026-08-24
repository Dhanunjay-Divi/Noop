import XCTest
@testable import StrandAnalytics

/// Drives NOOP's scoring engines with extreme, degenerate and hostile physiology to find the places where
/// they fabricate, crash, or silently clamp.
///
/// WHY: unit tests here mostly assert one engine on plausible input. Nothing walked the full range of
/// inputs a real body (or a failing sensor) can produce. The two promises this suite defends are the ones
/// the whole product rests on:
///
///   1. NEVER FABRICATE. Missing input yields nil, not a number. No output may be NaN or infinite.
///   2. STAY ORDERED. If a person is measurably worse on every input, the score must not go up.
///
/// This is robustness and self-consistency testing, NOT clinical validation. It cannot tell you whether a
/// Recovery of 42 is correct for a given night - only that the engine behaves like arithmetic rather than
/// like a random number generator. Accuracy against a reference belongs to the validation programme in
/// `docs/PRODUCTION_READINESS.md`.
final class ExtremePhysiologyScenarioTests: XCTestCase {

    // MARK: - Scenario corpus

    /// A named physiological scenario. Values are the metrics the scoring path consumes.
    private struct Scenario {
        let name: String
        let hrv: Double?          // RMSSD, ms
        let rhr: Double?          // bpm
        let respRate: Double?     // breaths/min
        let sleepHours: Double?
        let skinTempDev: Double?  // °C from baseline
        let effort: Double?       // 0...100
    }

    /// Ordered from "athlete at rest" to "clearly unwell", plus sensor-failure shapes. The clinically
    /// extreme rows are deliberately outside normal life: an engine that only behaves between 40 and 70 bpm
    /// is not finished.
    private let scenarios: [Scenario] = [
        .init(name: "elite athlete, deep rest",   hrv: 145, rhr: 38, respRate: 11.0, sleepHours: 9.0,  skinTempDev: -0.1, effort: 5),
        .init(name: "healthy typical",            hrv: 58,  rhr: 58, respRate: 14.5, sleepHours: 7.6,  skinTempDev: 0.0,  effort: 45),
        .init(name: "mild sleep debt",            hrv: 44,  rhr: 63, respRate: 15.2, sleepHours: 5.5,  skinTempDev: 0.2,  effort: 62),
        .init(name: "overreached",                hrv: 26,  rhr: 71, respRate: 16.4, sleepHours: 5.0,  skinTempDev: 0.5,  effort: 88),
        .init(name: "febrile illness",            hrv: 14,  rhr: 88, respRate: 21.0, sleepHours: 4.2,  skinTempDev: 1.9,  effort: 12),
        .init(name: "severe strain + fever",      hrv: 9,   rhr: 104, respRate: 26.0, sleepHours: 3.1, skinTempDev: 2.4,  effort: 97),
        .init(name: "bradycardic extreme",        hrv: 90,  rhr: 28, respRate: 9.0,  sleepHours: 8.0,  skinTempDev: -0.6, effort: 20),
        .init(name: "tachycardic extreme",        hrv: 6,   rhr: 145, respRate: 30.0, sleepHours: 2.0, skinTempDev: 1.2,  effort: 60),
        // sensor / data-failure shapes
        .init(name: "no data at all",             hrv: nil, rhr: nil, respRate: nil, sleepHours: nil,  skinTempDev: nil,  effort: nil),
        .init(name: "HRV only",                   hrv: 55,  rhr: nil, respRate: nil, sleepHours: nil,  skinTempDev: nil,  effort: nil),
        .init(name: "sleep missing",              hrv: 50,  rhr: 60, respRate: 14.0, sleepHours: nil,  skinTempDev: 0.1,  effort: 40),
        .init(name: "zeros (bad sensor)",         hrv: 0,   rhr: 0,  respRate: 0,    sleepHours: 0,    skinTempDev: 0,    effort: 0),
        .init(name: "negatives (corrupt)",        hrv: -50, rhr: -60, respRate: -14, sleepHours: -8,   skinTempDev: -99,  effort: -30),
        .init(name: "absurdly large",             hrv: 1e6, rhr: 1e6, respRate: 1e6, sleepHours: 1e6,  skinTempDev: 1e6,  effort: 1e6),
        .init(name: "non-finite",                 hrv: .nan, rhr: .infinity, respRate: .nan, sleepHours: .infinity, skinTempDev: .nan, effort: .nan),
    ]

    // MARK: - Hydration goal

    /// Hydration is the engine with the clearest contract, so it gets the strictest sweep: every sex, a wide
    /// weight range, and every hostile effort value.
    func testHydrationGoalStaysWithinItsDocumentedBoundsForEveryInput() {
        let sexes = ["male", "female", "nonbinary", "", "unknown"]
        let weights: [Double?] = [nil, -10, 0, 1, 35, 60, 90, 150, 400, 1e6, .nan, .infinity]
        let efforts: [Double?] = [nil, -100, 0, 45, 100, 250, 1e9, .nan, .infinity, -.infinity]
        let temps: [Double?] = [nil, -5, 0, 0.5, 2.5, 40, .nan, .infinity]

        for sex in sexes {
            for weight in weights {
                for effort in efforts {
                    for temp in temps {
                        let goal = HydrationGoal.dailyGoalML(
                            sex: sex, weightKg: weight, effort: effort, skinTempDevC: temp
                        )
                        let label = "sex=\(sex) weight=\(String(describing: weight)) effort=\(String(describing: effort)) temp=\(String(describing: temp))"
                        XCTAssertTrue(goal > 0, "\(label): goal must be positive, got \(goal)")
                        XCTAssertTrue(goal < 20_000,
                                      "\(label): goal must stay physiologically sane, got \(goal) ml")
                        XCTAssertEqual(goal % 50, 0, "\(label): goal must stay rounded to 50 ml, got \(goal)")
                    }
                }
            }
        }
    }

    /// Drinking more because you worked harder is the whole point; the goal must never decrease as effort
    /// rises, and never exceed the documented cap above baseline.
    func testHydrationGoalIsMonotonicInEffort() {
        for sex in ["male", "female", "nonbinary"] {
            var previous = 0
            for effort in stride(from: 0.0, through: 100.0, by: 5.0) {
                let goal = HydrationGoal.dailyGoalML(sex: sex, weightKg: 75, effort: effort, skinTempDevC: 0)
                XCTAssertGreaterThanOrEqual(goal, previous,
                                            "\(sex): goal fell from \(previous) to \(goal) as effort rose to \(effort)")
                previous = goal
            }
            let base = HydrationGoal.dailyGoalML(sex: sex, weightKg: 75, effort: 0, skinTempDevC: 0)
            let maxed = HydrationGoal.dailyGoalML(sex: sex, weightKg: 75, effort: 100, skinTempDevC: 0)
            XCTAssertLessThanOrEqual(maxed - base, HydrationGoal.maxEffortBumpML + 50,
                                     "\(sex): effort bump exceeded its documented cap")
        }
    }

    // MARK: - Vitality / wellness age

    /// Wellness age must stay in a human range and must never be produced from nothing.
    func testVitalityNeverReturnsAnAgeItCannotSupport() {
        // No inputs at all: the engine must decline rather than invent an age.
        let empty = VitalityEngine.contributions(.init(chronoAge: 38))
        XCTAssertTrue(empty.isEmpty, "With no inputs there can be no hazard contributions.")

        for scenario in scenarios {
            var inputs = VitalityEngine.Inputs(chronoAge: 38)
            inputs.restingHR = scenario.rhr
            inputs.rmssd = scenario.hrv
            inputs.rmssdNorm = 50
            inputs.sleepHours = scenario.sleepHours
            let contributions = VitalityEngine.contributions(inputs)
            for contribution in contributions {
                XCTAssertTrue(contribution.lnHazard.isFinite,
                              "\(scenario.name): \(contribution.key) produced a non-finite log-hazard "
                              + "(\(contribution.lnHazard)); that would poison the whole age estimate.")
                XCTAssertTrue(abs(contribution.lnHazard) < 10,
                              "\(scenario.name): \(contribution.key) log-hazard \(contribution.lnHazard) is "
                              + "implausibly large; a clamp is missing.")
            }
        }
    }

    /// Sleep-duration consistency is a coefficient of variation, so it is bounded 0...1 by construction and
    /// must refuse to answer on too few nights.
    func testSleepConsistencyIsBoundedAndRefusesThinData() {
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: []))
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7.5]))
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7.5, 7.4]))
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [0, 0, 0]),
                     "All-zero nights carry no duration signal and must not score as perfectly consistent.")

        let cases: [[Double]] = [
            [7.5, 7.5, 7.5, 7.5],
            [4, 10, 5, 11, 3],
            [1, 1, 1, 12],
            Array(repeating: 8, count: 60),
            [.nan, 7, 8, 9],
            [.infinity, 7, 8, 9],
            [-5, 7, 8, 9],
            [1e9, 7, 8, 9],
        ]
        for nights in cases {
            guard let value = VitalityEngine.sleepConsistency(nightlyHours: nights) else { continue }
            XCTAssertTrue(value.isFinite, "\(nights): consistency was not finite")
            XCTAssertTrue(value >= 0 && value <= 1, "\(nights): consistency \(value) escaped 0...1")
        }
    }

    // MARK: - Recovery scoring

    /// The ordering promise: a person worse on every driver cannot score higher. This is the single most
    /// important self-consistency property of the product, because users compare today with yesterday.
    func testRecoveryScoreNeverRewardsUniformlyWorsePhysiology() {
        let hrvBase = RecoveryScorer.DriverBaseline(mean: 60, spread: 18)
        let rhrBase = RecoveryScorer.DriverBaseline(mean: 56, spread: 6)
        let respBase = RecoveryScorer.DriverBaseline(mean: 14.5, spread: 1.2)

        // Ordered best -> worst on EVERY driver simultaneously.
        let ladder: [(name: String, hrv: Double, rhr: Double, resp: Double, sleep: Double)] = [
            ("rested",     120, 45, 12.5, 96),
            ("normal",      60, 56, 14.5, 85),
            ("tired",       35, 65, 16.0, 68),
            ("very tired",  18, 78, 18.5, 50),
            ("unwell",       8, 95, 22.0, 32),
        ]

        var previous: Double?
        for rung in ladder {
            let score = RecoveryScorer.recovery(
                hrv: rung.hrv, rhr: rung.rhr, resp: rung.resp,
                hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                sleepPerf: rung.sleep
            )
            let value = try! XCTUnwrap(score, "\(rung.name): a full input set must produce a score")
            XCTAssertTrue(value.isFinite, "\(rung.name): score not finite")
            XCTAssertTrue(value >= 0 && value <= 100, "\(rung.name): score \(value) escaped 0...100")
            if let previous {
                XCTAssertLessThanOrEqual(
                    value, previous + 0.001,
                    "\(rung.name) is worse on HRV, resting HR, breathing AND sleep than the rung above, "
                    + "yet scored higher (\(value) vs \(previous))."
                )
            }
            previous = value
        }
    }

    /// The no-fabrication gate: without a usable HRV baseline the engine must return nil rather than a
    /// plausible-looking number. This is the behaviour the whole "we never make up a score" claim rests on.
    func testRecoveryRefusesToScoreWithoutAUsableBaseline() {
        let score = RecoveryScorer.recovery(
            hrv: 55, rhr: 58, resp: 14.5,
            hrvBaseline: .init(mean: 60, spread: 18),
            rhrBaseline: .init(mean: 56, spread: 6),
            respBaseline: .init(mean: 14.5, spread: 1.2),
            sleepPerf: 85,
            hrvBaselineUsable: false
        )
        XCTAssertNil(score, "With no usable HRV baseline the engine must decline, not estimate.")
    }

    /// Every scenario in the corpus, including corrupt and non-finite sensor values, must either produce a
    /// score inside 0...100 or decline. A NaN reaching the UI would render as "nan".
    func testEveryScenarioEitherScoresInRangeOrDeclines() {
        let hrvBase = RecoveryScorer.DriverBaseline(mean: 60, spread: 18)
        let rhrBase = RecoveryScorer.DriverBaseline(mean: 56, spread: 6)
        let respBase = RecoveryScorer.DriverBaseline(mean: 14.5, spread: 1.2)

        for scenario in scenarios {
            guard let hrv = scenario.hrv, let rhr = scenario.rhr else { continue }
            let score = RecoveryScorer.recovery(
                hrv: hrv, rhr: rhr, resp: scenario.respRate,
                hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                sleepPerf: scenario.sleepHours.map { min(100, max(0, $0 / 8 * 100)) },
                skinTempDev: scenario.skinTempDev
            )
            guard let score else { continue }        // declining is always acceptable
            XCTAssertTrue(score.isFinite,
                          "\(scenario.name): produced a non-finite score (\(score))")
            XCTAssertTrue(score >= 0 && score <= 100,
                          "\(scenario.name): produced \(score), outside 0...100")
        }
    }

    /// Degenerate spread is the classic divide-by-zero: an unvarying or corrupt baseline must not yield a
    /// non-finite score.
    func testRecoverySurvivesDegenerateBaselines() {
        let spreads: [Double] = [0, -1, 1e-12, .nan, .infinity, 1e9]
        for spread in spreads {
            let score = RecoveryScorer.recovery(
                hrv: 55, rhr: 58, resp: 14.5,
                hrvBaseline: .init(mean: 60, spread: spread),
                rhrBaseline: .init(mean: 56, spread: spread),
                respBaseline: .init(mean: 14.5, spread: spread),
                sleepPerf: 85
            )
            if let score {
                XCTAssertTrue(score.isFinite && score >= 0 && score <= 100,
                              "spread=\(spread) produced an out-of-range score (\(score))")
            }
        }
        for value in [Double.nan, .infinity, -.infinity, 1e9, -1e9] {
            let score = RecoveryScorer.recovery(
                hrv: value, rhr: value, resp: value,
                hrvBaseline: .init(mean: 60, spread: 18),
                rhrBaseline: .init(mean: 56, spread: 6),
                respBaseline: .init(mean: 14.5, spread: 1.2),
                sleepPerf: 85
            )
            if let score {
                XCTAssertTrue(score.isFinite && score >= 0 && score <= 100,
                              "input=\(value) produced an out-of-range score (\(score))")
            }
        }
    }

    /// The recovery band is the colour a user actually sees; it must be defined for every score and must
    /// move in one direction only.
    func testRecoveryBandIsTotalAndMonotonic() {
        var seen: [String] = []
        for score in stride(from: -50.0, through: 150.0, by: 1.0) {
            let band = RecoveryScorer.band(score)
            XCTAssertFalse(band.isEmpty, "score \(score) produced no band")
            if seen.last != band { seen.append(band) }
        }
        // Sweeping upward may only ever move red -> yellow -> green, never back.
        XCTAssertEqual(seen, ["red", "yellow", "green"],
                       "Bands must change in one direction across a rising score; saw \(seen)")
    }

    // MARK: - Stress heatmap

    /// The heatmap aggregates sparse hourly levels; empty and hostile inputs must not fabricate a grid.
    func testStressHeatmapHandlesEmptyAndHostileInput() {
        XCTAssertTrue(StressHeatmap.grid(columns: []).isEmpty, "No columns must produce no grid.")

        let hostile: [Int: Double] = [
            -5: 1.0, 0: .nan, 3: .infinity, 12: -10, 23: 99, 99: 2.0,
        ]
        let column = StressHeatmap.DayColumn(day: "2026-08-24", levels: hostile)
        let cells = StressHeatmap.grid(columns: [column])
        for cell in cells {
            XCTAssertTrue(cell.hour >= 0 && cell.hour <= 23, "cell hour \(cell.hour) out of range")
            if let level = cell.level {
                XCTAssertTrue(level.isFinite, "heatmap cell level was not finite (\(level))")
            }
        }
        for (hour, mean) in StressHeatmap.meanByHour(cells) {
            XCTAssertTrue(hour >= 0 && hour <= 23, "mean hour \(hour) out of range")
            XCTAssertTrue(mean.isFinite, "hour \(hour) mean not finite")
        }
        let summary = StressHeatmap.summary(cells)
        XCTAssertNotNil(summary, "summary must exist even for hostile input")
    }
}
