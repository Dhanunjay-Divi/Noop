import XCTest
@testable import StrandAnalytics

/// Validates `RhythmScreener` against REAL recorded cardiac rhythm, and against inputs designed to break it.
///
/// WHY THIS EXISTS: `RhythmScreener.swift` says its thresholds were "tuned only on synthetic fixtures".
/// Synthetic data cannot tell you whether a threshold survives contact with a real arrhythmia, because the
/// generator and the detector share the same assumptions. These fixtures are R-R intervals extracted from
/// PhysioNet's MIT-BIH Atrial Fibrillation Database and MIT-BIH Normal Sinus Rhythm Database
/// (`Resources/rhythm_real_rr.json`), taken from INSIDE annotated rhythm episodes.
///
/// WHAT THIS DOES NOT CLAIM: nothing here is a diagnostic evaluation, and the screener is explicitly not a
/// diagnostic tool - it emits neutral words ("looked steady", "varied a lot") and never an alarm or a
/// condition name. These tests only assert the descriptive statistics behave sanely on real physiology:
/// an irregularly-irregular rhythm must not be described as steady, a normal rhythm must not be described
/// as varied, and no input may produce a fabricated or non-finite number.
///
/// Sensitivity/specificity, held-out patients and calibration belong to the accuracy-validation programme
/// in `docs/PRODUCTION_READINESS.md`, not to a unit test.
final class RhythmScreenerRealDataTests: XCTestCase {

    // MARK: - Fixture loading

    private struct Corpus: Decodable {
        struct Record: Decodable {
            let rhythm: String
            let beats: Int
            let meanHR: Double
            let sdnn: Double
            let rmssd: Double
        }
        let records: [String: Record]
        let series: [String: [Double]]
    }

    private func corpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/rhythm_real_rr.json")
        return try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: url))
    }

    /// Screen one contiguous stretch of real beats as a single resting window.
    private func screen(_ rr: [Double]) -> RhythmScreener.WindowResult {
        let meanRR = rr.reduce(0, +) / Double(rr.count)
        var t = 0
        let ts: [Int] = rr.map { t += Int($0.rounded()); return t / 1000 }
        return RhythmScreener.screenWindow(
            .init(rrMs: rr, ts: ts, ppgIBIms: nil, motionStill: true,
                  meanHR: 60_000 / meanRR, activityActive: false)
        )
    }

    // MARK: - Real recorded rhythm

    /// Atrial fibrillation is irregularly irregular. Whatever words the product uses, it must NOT land on
    /// the "steady" end for a rhythm like this - that is the one description that would actively mislead.
    ///
    /// Scoped to AF episodes whose mean rate falls inside the screener's resting band. Rapid AF is covered
    /// by `testRapidAtrialFibrillationIsOutsideTheRestingBandAndSaysSoRatherThanGuessing`.
    func testAnnotatedAtrialFibrillationInsideTheRestingBandIsNeverDescribedAsSteady() throws {
        let corpus = try corpus()
        let afKeys = corpus.series.keys
            .filter { $0.hasPrefix("AF_") }
            .filter { key in
                guard let hr = corpus.records[key]?.meanHR else { return false }
                return hr >= RhythmScreener.restingHrMinBpm && hr <= RhythmScreener.restingHrMaxBpm
            }
            .sorted()
        XCTAssertFalse(afKeys.isEmpty, "no in-band AF fixtures; the corpus needs at least one")

        for key in afKeys {
            let rr = try XCTUnwrap(corpus.series[key])
            let result = screen(rr)
            XCTAssertNotEqual(result.label, .steady,
                              "\(key) is an annotated AF episode (RMSSD \(corpus.records[key]?.rmssd ?? 0) ms) "
                              + "but was described as steady.")
            XCTAssertNotEqual(result.label, .unreadable,
                              "\(key) has \(rr.count) clean resting beats inside the resting band; "
                              + "it should be readable.")
            if let ratio = result.sd1sd2 {
                XCTAssertTrue(ratio.isFinite && ratio > 0, "\(key) SD1:SD2 must be a positive finite number")
            }
        }
    }

    /// DOCUMENTED BLIND SPOT, pinned deliberately so it cannot be forgotten.
    ///
    /// `restingHrMaxBpm` is 110 bpm, so any window faster than that is reported `unreadable` regardless of
    /// how clean it is. Atrial fibrillation with a rapid ventricular response typically runs 110-160 bpm,
    /// which means the screener is silent on the most common salient AF presentation: two of the three real
    /// annotated AF episodes in this corpus (132 and 115 bpm) fall outside the band.
    ///
    /// The gate itself is defensible - a regularity read at 130 bpm may just be exercise the motion gate
    /// missed, and describing that as "varied" would be worse than saying nothing. What this test protects
    /// is the CURRENT, HONEST behaviour: when the rate is outside the band the screener declines rather than
    /// guessing. If the band is ever widened, this test must fail and be re-argued with real data, not
    /// quietly updated.
    ///
    /// Product decision recorded in `docs/validation/RHYTHM-REAL-DATA-FINDINGS.md`; raising the ceiling is
    /// not a unilateral code change because it would admit exercise windows for real users.
    func testRapidAtrialFibrillationIsOutsideTheRestingBandAndSaysSoRatherThanGuessing() throws {
        let corpus = try corpus()
        let rapid = corpus.series.keys
            .filter { $0.hasPrefix("AF_") }
            .filter { (corpus.records[$0]?.meanHR ?? 0) > RhythmScreener.restingHrMaxBpm }
            .sorted()
        XCTAssertFalse(rapid.isEmpty,
                       "The corpus must keep at least one rapid-AF episode so this blind spot stays visible.")

        for key in rapid {
            let rr = try XCTUnwrap(corpus.series[key])
            let result = screen(rr)
            XCTAssertEqual(result.label, .unreadable,
                           "\(key) is above restingHrMaxBpm (\(corpus.records[key]?.meanHR ?? 0) bpm); the "
                           + "screener must decline, not describe.")
            // NOT asserted: that a declined window also reports low confidence. It does not, by design -
            // gates 3 and 4 pass `confidence(for: clean.count)` through, so a 600-beat declined window
            // reports `.solid`. That is internal metadata about how much signal was present, not a claim
            // about the label, and it never reaches the user: RhythmView builds `headlineWindow` from
            // `windows.filter { $0.label != .unreadable }`, so a declined window can never become the
            // headline whose confidence pill is drawn. The invariant worth protecting is that filter, and
            // it is asserted below via the night summary's readable-window count.
            XCTAssertNil(result.sd1,
                         "\(key) was declined, so it must not publish descriptive statistics.")
            XCTAssertNil(result.normRmssd,
                         "\(key) was declined, so it must not publish a variation index.")
            XCTAssertTrue(result.poincare.isEmpty,
                          "\(key) was declined, so it must not publish a point cloud to plot.")
        }
    }

    /// The user-visible guarantee behind the note above: declined windows are never counted as readable, so
    /// a night made only of declined windows cannot present itself as an assessed night.
    func testANightOfDeclinedWindowsReportsNoReadableWindows() throws {
        let corpus = try corpus()
        let rapidKey = try XCTUnwrap(corpus.series.keys.first {
            $0.hasPrefix("AF_") && (corpus.records[$0]?.meanHR ?? 0) > RhythmScreener.restingHrMaxBpm
        })
        let rr = try XCTUnwrap(corpus.series[rapidKey])
        let night = RhythmScreener.summarizeNight([screen(rr), screen(rr), screen(rr)])
        XCTAssertEqual(night.readableWindows, 0,
                       "Every window was declined, so none may be counted as readable.")
        XCTAssertEqual(night.overall, .unreadable,
                       "A night with nothing readable must summarise as unreadable.")
        XCTAssertFalse(night.variationRecurred,
                       "Nothing was read, so variation cannot be said to have recurred.")
    }

    /// The mirror assertion: normal sinus rhythm must not be described as having varied a lot, or the
    /// screener would cry wolf on healthy nights.
    func testAnnotatedNormalSinusRhythmIsNeverDescribedAsVaried() throws {
        let corpus = try corpus()
        let normalKeys = corpus.series.keys.filter { !$0.hasPrefix("AF_") }.sorted()
        XCTAssertFalse(normalKeys.isEmpty, "normal-rhythm fixtures missing")

        for key in normalKeys {
            let rr = try XCTUnwrap(corpus.series[key])
            let result = screen(rr)
            XCTAssertNotEqual(result.label, .varied,
                              "\(key) is annotated normal sinus rhythm (RMSSD \(corpus.records[key]?.rmssd ?? 0) ms) "
                              + "but was described as varied.")
        }
    }

    /// The corpus separates cleanly on RMSSD (AF >= 128 ms, normal <= 57 ms), so the screener should place
    /// every AF window at a higher beat-to-beat variation index than every normal window. If this fails the
    /// thresholds are not merely mistuned - the ordering itself is wrong.
    func testRealAtrialFibrillationRanksAboveNormalOnBeatToBeatVariation() throws {
        let corpus = try corpus()
        var af: [Double] = [], normal: [Double] = []
        for (key, rr) in corpus.series {
            guard let n = screen(rr).normRmssd else { continue }
            if key.hasPrefix("AF_") { af.append(n) } else { normal.append(n) }
        }
        let worstAF = try XCTUnwrap(af.min())
        let worstNormal = try XCTUnwrap(normal.max())
        XCTAssertGreaterThan(worstAF, worstNormal,
                             "Lowest AF normalised RMSSD (\(worstAF)) must exceed the highest normal one "
                             + "(\(worstNormal)); the two populations do not overlap in the source data.")
    }

    /// Statistics must be reproducible: the same beats screened twice give the same answer. A screener that
    /// drifts cannot be validated, and users would see a label change with no new data.
    func testScreeningRealDataIsDeterministic() throws {
        let corpus = try corpus()
        for (_, rr) in corpus.series.sorted(by: { $0.key < $1.key }) {
            let a = screen(rr), b = screen(rr)
            XCTAssertEqual(a.label, b.label)
            XCTAssertEqual(a.sd1, b.sd1)
            XCTAssertEqual(a.sd2, b.sd2)
            XCTAssertEqual(a.normRmssd, b.normRmssd)
            XCTAssertEqual(a.ectopicFraction, b.ectopicFraction)
        }
    }

    // MARK: - Inputs designed to break it

    /// Nothing may return a NaN or an infinity. In a product whose promise is "we never show a number we
    /// had to make up", a non-finite statistic is the worst possible leak: it formats as "nan" on screen.
    func testPathologicalInputsNeverProduceNonFiniteStatistics() {
        let cases: [(String, [Double])] = [
            ("empty",                    []),
            ("single beat",              [800]),
            ("two beats",                [800, 810]),
            ("all identical",            Array(repeating: 800, count: 300)),
            ("extreme bradycardia",      Array(repeating: 2_400, count: 300)),        // 25 bpm
            ("extreme tachycardia",      Array(repeating: 250, count: 300)),          // 240 bpm
            ("bigeminy (every 2nd PVC)", (0..<300).map { $0 % 2 == 0 ? 620.0 : 1_060.0 }),
            ("asystolic gap",            Array(repeating: 850, count: 150) + [8_000] + Array(repeating: 850, count: 150)),
            ("alternating extremes",     (0..<300).map { $0 % 2 == 0 ? 300.0 : 2_500.0 }),
            ("zero",                     Array(repeating: 0, count: 120)),
            ("negative",                 Array(repeating: -800, count: 120)),
            ("NaN injected",             Array(repeating: 800, count: 100) + [Double.nan] + Array(repeating: 800, count: 100)),
            ("infinity injected",        Array(repeating: 800, count: 100) + [Double.infinity] + Array(repeating: 800, count: 100)),
            ("huge",                     Array(repeating: 1e9, count: 120)),
        ]

        for (name, rr) in cases {
            let meanRR = rr.isEmpty ? 800 : max(1, rr.filter { $0.isFinite }.reduce(0, +) / Double(max(1, rr.filter { $0.isFinite }.count)))
            let result = RhythmScreener.screenWindow(
                .init(rrMs: rr, ts: [], ppgIBIms: nil, motionStill: true,
                      meanHR: 60_000 / meanRR, activityActive: false)
            )
            for (stat, value) in [("sd1", result.sd1), ("sd2", result.sd2), ("sd1sd2", result.sd1sd2),
                                  ("normRmssd", result.normRmssd), ("turningPointRate", result.turningPointRate),
                                  ("ectopicFraction", result.ectopicFraction)] {
                if let value {
                    XCTAssertTrue(value.isFinite, "\(name): \(stat) was not finite (\(value))")
                }
            }
            for point in result.poincare {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite, "\(name): Poincaré point not finite")
            }
            XCTAssertGreaterThanOrEqual(result.nBeats, 0, "\(name): negative beat count")
        }
    }

    /// Too little data must read "couldn't read" rather than a confident-looking label off a handful of
    /// beats. This is the no-fabrication promise applied to rhythm.
    func testTooFewBeatsIsUnreadableRatherThanConfident() {
        for count in [0, 1, 5, 20, RhythmScreener.windowMinBeats - 1] {
            let rr = Array(repeating: 850.0, count: max(0, count))
            let result = RhythmScreener.screenWindow(
                .init(rrMs: rr, ts: [], ppgIBIms: nil, motionStill: true,
                      meanHR: 70, activityActive: false)
            )
            XCTAssertEqual(result.label, .unreadable,
                           "\(count) beats is below windowMinBeats (\(RhythmScreener.windowMinBeats)) "
                           + "and must not produce a rhythm description.")
            XCTAssertNotEqual(result.confidence, .solid, "\(count) beats must never read as solid confidence.")
        }
    }

    /// Confidence must earn itself: only a window with at least `solidBeats` may claim to be solid.
    func testSolidConfidenceRequiresTheDocumentedBeatCount() throws {
        let corpus = try corpus()
        let rr = try XCTUnwrap(corpus.series.values.first { $0.count >= RhythmScreener.solidBeats })
        let short = Array(rr.prefix(RhythmScreener.windowMinBeats + 5))
        XCTAssertNotEqual(screen(short).confidence, .solid,
                          "A window just over the minimum must not claim solid confidence.")
        let long = Array(rr.prefix(RhythmScreener.solidBeats + 20))
        XCTAssertEqual(screen(long).nBeats > 0, true)
    }

    /// A night is only summarised as recurring variation when variation actually recurs across windows -
    /// one odd window during a night must not colour the whole night.
    func testASingleVariedWindowDoesNotMakeTheWholeNightVaried() throws {
        let corpus = try corpus()
        let afRR = try XCTUnwrap(corpus.series.first { $0.key.hasPrefix("AF_") }?.value)
        let normalRR = try XCTUnwrap(corpus.series.first { !$0.key.hasPrefix("AF_") }?.value)

        let windows = [screen(normalRR), screen(normalRR), screen(normalRR), screen(afRR)]
        let night = RhythmScreener.summarizeNight(windows)
        XCTAssertFalse(night.variationRecurred,
                       "One varied window out of four must not be reported as recurring variation.")
        XCTAssertEqual(night.readableWindows, windows.filter { $0.label != .unreadable }.count)
    }
}
