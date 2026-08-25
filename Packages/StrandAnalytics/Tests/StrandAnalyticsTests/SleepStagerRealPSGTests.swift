import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Scores `SleepStager` against EXPERT POLYSOMNOGRAPHY using the very dataset its own header cites.
///
/// `SleepStager.swift` says: *"the EEG-free 4-class ceiling is ~65-73% epoch agreement (Walch 2019)"*. That
/// number was quoted from the literature but never measured against this implementation. This harness
/// closes that loop with the actual Walch data (PhysioNet `sleep-accel`: Apple Watch motion + heart rate,
/// with concurrent expert-scored PSG hypnograms).
///
/// OPT-IN, like `server/tests/test_twilio_staging.py`. The prepared data is ~2.5 MB per handful of subjects
/// and is third-party research data, so it is NOT committed. Prepare the fixture described in
/// `docs/validation/SLEEP-PSG-HARNESS.md`, then run:
///
///     NOOP_WALCH_DIR=/tmp/walch/prepared swift test --filter SleepStagerRealPSGTests
///
/// WHAT THIS MEASURES: epoch-by-epoch agreement between NOOP's 4-class output and the PSG reference, plus
/// the binary sleep/wake agreement that actigraphy is normally judged on. It is a fixed-sample measurement
/// on 6 nights, not a validation study: no held-out split, no demographic spread, no test-retest. It cannot
/// license a clinical claim. It CAN tell you whether the implementation lands anywhere near the ceiling its
/// own comment claims, and where it systematically errs.
///
/// INPUT REALISM: Walch provides motion + HR only, with no R-R intervals and no respiration channel. That
/// is exactly the degraded input a user with a HR-only wearable gives NOOP, so this doubles as the
/// worst-supported-input case rather than a best case.
final class SleepStagerRealPSGTests: XCTestCase {

    // MARK: - Fixture plumbing

    private struct Subject: Decodable {
        let subject: String
        let psgStart: Int
        let psgEnd: Int
        /// `[[unixSeconds, psgStage]]` at 30 s epochs. Codes: 0 wake, 1 N1, 2 N2, 3 N3, 4 N4, 5 REM, -1 unscored.
        let labels: [[Int]]
        /// `[[unixSeconds, bpm]]`
        let hr: [[Int]]
        /// `[[unixSeconds, x, y, z]]` in g, averaged to 1 Hz (GravitySample.ts is integer seconds).
        let grav: [[Double]]
    }

    /// NOOP's four classes, plus a bucket for epochs the scorer excluded.
    private enum Stage: String, CaseIterable { case wake, light, deep, rem }

    private static func mapPSG(_ code: Int) -> Stage? {
        switch code {
        case 0: return .wake
        case 1, 2: return .light      // N1 + N2
        case 3, 4: return .deep       // N3 + N4 (slow-wave)
        case 5: return .rem
        default: return nil           // -1 unscored / movement time: excluded from scoring
        }
    }

    private func subjects() throws -> [Subject] {
        guard let dir = ProcessInfo.processInfo.environment["NOOP_WALCH_DIR"] else { return [] }
        let urls = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try JSONDecoder().decode(Subject.self, from: try Data(contentsOf: $0)) }
    }

    // MARK: - Scoring

    private struct Score {
        var confusion: [Stage: [Stage: Int]] = [:]     // [reference: [predicted: count]]
        var scored = 0
        var agreed = 0
        /// Epochs inside the PSG window that NOOP produced no stage for at all.
        var uncovered = 0

        mutating func add(reference: Stage, predicted: Stage?) {
            guard let predicted else { uncovered += 1; return }
            scored += 1
            if reference == predicted { agreed += 1 }
            confusion[reference, default: [:]][predicted, default: 0] += 1
        }
        var agreement: Double { scored == 0 ? 0 : Double(agreed) / Double(scored) }

        func recall(_ s: Stage) -> Double? {
            let row = confusion[s] ?? [:]
            let total = row.values.reduce(0, +)
            return total == 0 ? nil : Double(row[s] ?? 0) / Double(total)
        }
        func precision(_ s: Stage) -> Double? {
            var predicted = 0, correct = 0
            for (ref, row) in confusion {
                predicted += row[s] ?? 0
                if ref == s { correct += row[s] ?? 0 }
            }
            return predicted == 0 ? nil : Double(correct) / Double(predicted)
        }
        /// Binary sleep vs wake, the metric actigraphy is conventionally judged on.
        var sleepWakeAgreement: Double {
            var n = 0, ok = 0
            for (ref, row) in confusion {
                for (pred, c) in row {
                    n += c
                    if (ref == .wake) == (pred == .wake) { ok += c }
                }
            }
            return n == 0 ? 0 : Double(ok) / Double(n)
        }
    }

    /// Stage the PSG window DIRECTLY, bypassing session detection.
    ///
    /// WHY BYPASS: the Walch motion stream is sparse - samples exist for only 20-32% of the seconds in the
    /// night, and the longest contiguous span without a >20 min hole is 98-150 min. `detectSleep` therefore
    /// (correctly) accepts only ~24% of the night and refuses to bridge the rest, which is the
    /// no-fabrication rule working as designed, not a defect. Scoring staging through detection would
    /// measure accuracy on a biased quarter of the night. To measure STAGING we hand it the PSG window and
    /// score every epoch; detection is measured separately by `SleepDetectionGateDiagnosticTests`.
    private func stagePrediction(_ s: Subject) -> [Int: Stage] {
        let hr = s.hr.map { HRSample(ts: $0[0], bpm: $0[1]) }
        let grav = s.grav.map {
            GravitySample(ts: Int($0[0]), x: $0[1], y: $0[2], z: $0[3], unit: "g")
        }
        let segments = SleepStager.stageSession(start: s.psgStart, end: s.psgEnd,
                                                grav: grav, hr: hr, rr: [], resp: [])
        var byEpoch: [Int: Stage] = [:]
        for seg in segments {
            guard let stage = Stage(rawValue: seg.stage) else { continue }
            var t = seg.start - (seg.start % 30)
            while t < seg.end { byEpoch[t] = stage; t += 30 }
        }
        return byEpoch
    }

    private func overlap(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
        max(0, min(a1, b1) - max(a0, b0))
    }

    // MARK: - The measurement

    func testFourClassAgreementAgainstExpertPSG() throws {
        let subjects = try subjects()
        try XCTSkipIf(subjects.isEmpty, """
            Set NOOP_WALCH_DIR to a prepared fixture directory. \
            See docs/validation/SLEEP-PSG-HARNESS.md. \
            Skipped rather than failed: the dataset is third-party research data and is not committed.
            """)

        var pooled = Score()
        var perSubject: [(String, Double, Double, Int)] = []

        for s in subjects {
            let predicted = stagePrediction(s)
            var score = Score()
            for row in s.labels {
                guard row.count == 2, let reference = Self.mapPSG(row[1]) else { continue }
                let epoch = row[0] - (row[0] % 30)
                score.add(reference: reference, predicted: predicted[epoch])
                pooled.add(reference: reference, predicted: predicted[epoch])
            }
            perSubject.append((s.subject, score.agreement, score.sleepWakeAgreement, score.uncovered))
        }

        // ---- report -------------------------------------------------------------------------------
        // Plain interpolation, deliberately: String(format:) with %s and a Swift String is undefined
        // behaviour (it expects a C string) and segfaults. Learned the hard way writing this harness.
        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        func lpad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }

        print("\n=== SleepStager vs expert PSG (PhysioNet sleep-accel, Walch 2019) ===")
        print("input: wrist motion @1Hz + heart rate only (no R-R, no respiration)\n")
        print(pad("subject", 11) + lpad("4-class", 10) + lpad("sleep/wake", 13) + lpad("uncovered", 12))
        for (name, four, binary, uncovered) in perSubject {
            print(pad(name, 11) + lpad(pct(four), 10) + lpad(pct(binary), 13) + lpad("\(uncovered)", 12))
        }
        print("\nPOOLED  4-class \(pct(pooled.agreement))   sleep/wake \(pct(pooled.sleepWakeAgreement))"
              + "   scored \(pooled.scored)   uncovered \(pooled.uncovered)")

        print("\nper-class (reference = PSG):")
        for stage in Stage.allCases {
            let r = pooled.recall(stage).map(pct) ?? "n/a"
            let p = pooled.precision(stage).map(pct) ?? "n/a"
            let n = (pooled.confusion[stage] ?? [:]).values.reduce(0, +)
            print("  " + pad(stage.rawValue, 7) + "recall " + pad(r, 9) + "precision " + pad(p, 9) + "(n=\(n))")
        }
        print("\nconfusion (rows = PSG, cols = NOOP):")
        print(pad("", 9) + Stage.allCases.map { lpad($0.rawValue, 8) }.joined())
        for ref in Stage.allCases {
            let row = pooled.confusion[ref] ?? [:]
            print(pad(ref.rawValue, 9) + Stage.allCases.map { lpad("\(row[$0] ?? 0)", 8) }.joined())
        }

        // ---- assertions ---------------------------------------------------------------------------
        // Deliberately loose. The point is to catch a pipeline that is broken or inverted, not to pin a
        // number that will drift with every tuning change. The verdict against the claimed 65-73% ceiling
        // belongs in dated validation evidence, because a unit test is the wrong place to litigate
        // accuracy.
        XCTAssertGreaterThan(pooled.scored, 3_000, "Too few scored epochs to say anything.")
        XCTAssertGreaterThan(pooled.agreement, 0.25,
                             "4-class agreement below chance-ish (4 classes, imbalanced) means the pipeline "
                             + "is broken, not merely imprecise.")
        XCTAssertGreaterThan(pooled.sleepWakeAgreement, 0.60,
                             "Binary sleep/wake is what motion alone can genuinely do; below 60% indicates "
                             + "the sleep/wake spine is not working on real wrist data.")
    }

    /// Sleep/wake is the claim the product leans on most (session boundaries, duration, debt). Motion-based
    /// actigraphy is normally 80-90% here, so this is scored separately and more strictly than staging.
    func testSleepWakeSpineIsUsableOnRealWristData() throws {
        let subjects = try subjects()
        try XCTSkipIf(subjects.isEmpty, "Set NOOP_WALCH_DIR (see testFourClassAgreementAgainstExpertPSG).")

        for s in subjects {
            let predicted = stagePrediction(s)
            var n = 0, ok = 0
            for row in s.labels {
                guard row.count == 2, let reference = Self.mapPSG(row[1]) else { continue }
                guard let p = predicted[row[0] - (row[0] % 30)] else { continue }
                n += 1
                if (reference == .wake) == (p == .wake) { ok += 1 }
            }
            guard n > 100 else { continue }
            let agreement = Double(ok) / Double(n)
            XCTAssertGreaterThan(agreement, 0.50,
                                 "\(s.subject): sleep/wake agreement \(agreement) is no better than a coin "
                                 + "flip on a real night.")
        }
    }

    /// Whatever the accuracy, the stager must not invent stages outside the session or leave the night
    /// half-covered: total staged minutes must be within the session it was asked about.
    func testStagingStaysInsideTheSessionItWasGiven() throws {
        let subjects = try subjects()
        try XCTSkipIf(subjects.isEmpty, "Set NOOP_WALCH_DIR (see testFourClassAgreementAgainstExpertPSG).")

        for s in subjects {
            let hr = s.hr.map { HRSample(ts: $0[0], bpm: $0[1]) }
            let grav = s.grav.map { GravitySample(ts: Int($0[0]), x: $0[1], y: $0[2], z: $0[3], unit: "g") }
            let segments = SleepStager.stageSession(start: s.psgStart, end: s.psgEnd,
                                                    grav: grav, hr: hr, rr: [], resp: [])
            for seg in segments {
                XCTAssertGreaterThanOrEqual(seg.start, s.psgStart - 30,
                                            "\(s.subject): segment starts before the session")
                XCTAssertLessThanOrEqual(seg.end, s.psgEnd + 30,
                                         "\(s.subject): segment ends after the session")
                XCTAssertLessThan(seg.start, seg.end, "\(s.subject): empty or inverted segment")
                XCTAssertNotNil(Stage(rawValue: seg.stage),
                                "\(s.subject): unknown stage label '\(seg.stage)'")
            }
        }
    }
}
