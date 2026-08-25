import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Isolates WHY `detectSleep` accepts only ~2 h of a PSG-confirmed 8 h night on real wrist data.
///
/// Established before this test ran:
///   • staging is not the problem - `stageSession` covers 100% of the PSG window on all six subjects;
///   • the input is not too noisy - 98.5-99.4% of 1 Hz gravity deltas during PSG-scored sleep are below
///     `gravityStillThresholdG` (0.01 g), with medians 4-16x inside spec.
///
/// So the stillness spine had clean evidence for essentially the whole night. This test varies the one
/// remaining caller-supplied input, the overnight HR baseline, to see whether the HR confirmation stage is
/// what truncates the session.
final class SleepDetectionGateDiagnosticTests: XCTestCase {
    private struct Subject: Decodable {
        let subject: String
        let psgStart: Int
        let psgEnd: Int
        let labels: [[Int]]
        let hr: [[Int]]
        let grav: [[Double]]
    }

    func testWhichGateTruncatesTheNight() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOOP_WALCH_DIR"] else {
            throw XCTSkip("Set NOOP_WALCH_DIR")
        }
        let urls = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        func hm(_ s: Int) -> String { String(format: "%dh%02dm", s / 3600, (s % 3600) / 60) }

        print("\n=== detectSleep coverage vs supplied HR baseline ===")
        print("(PSG window is the truth; 'best' = session with most overlap)\n")
        var noBaseline: [Double] = [], withBaseline: [Double] = [], withState: [Double] = []

        for url in urls {
            let s = try JSONDecoder().decode(Subject.self, from: try Data(contentsOf: url))
            let hr = s.hr.map { HRSample(ts: $0[0], bpm: $0[1]) }
            let grav = s.grav.map { GravitySample(ts: Int($0[0]), x: $0[1], y: $0[2], z: $0[3], unit: "g") }
            let psgSpan = Double(s.psgEnd - s.psgStart)

            // The app would know this after a few nights: the median HR across the PSG-confirmed sleep window.
            let asleep = Set(s.labels.filter { $0.count == 2 && [1,2,3,4,5].contains($0[1]) }
                                     .map { $0[0] - ($0[0] % 30) })
            let sleepHRs = hr.filter { asleep.contains($0.ts - ($0.ts % 30)) }.map { Double($0.bpm) }.sorted()
            let overnightMedian = sleepHRs.isEmpty ? nil : sleepHRs[sleepHRs.count / 2]

            func coverage(_ sessions: [SleepSession]) -> Double {
                let best = sessions.map { max(0, min($0.end, s.psgEnd) - max($0.start, s.psgStart)) }.max() ?? 0
                return Double(best) / psgSpan
            }

            let a = SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: grav)
            let b = SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: grav,
                                            sleepHRBaseline: overnightMedian)
            // The band's own sleep-state channel, which a NOOP Band supplies and an HR-only wearable cannot.
            let state: [(ts: Int, state: Int)] = s.labels.compactMap { row in
                guard row.count == 2 else { return nil }
                switch row[1] {
                case 0:            return (row[0], 1)   // awake but in bed -> "still"
                case 1,2,3,4,5:    return (row[0], 2)   // asleep
                default:           return nil
                }
            }
            let c = SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: grav,
                                            bandSleepState: state, sleepHRBaseline: overnightMedian)

            noBaseline.append(coverage(a)); withBaseline.append(coverage(b)); withState.append(coverage(c))
            print(s.subject
                  + "  PSG \(hm(s.psgEnd - s.psgStart))"
                  + String(format: "  noBaseline %.0f%%", coverage(a) * 100)
                  + String(format: "  +hrBaseline(%.0f bpm) %.0f%%", overnightMedian ?? 0, coverage(b) * 100)
                  + String(format: "  +bandState %.0f%%", coverage(c) * 100))
        }

        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        print(String(format: "\nMEAN best-session coverage:  noBaseline %.0f%%   +hrBaseline %.0f%%   +bandState %.0f%%",
                     mean(noBaseline) * 100, mean(withBaseline) * 100, mean(withState) * 100))
        print("""

        Reading: if +hrBaseline lifts coverage materially, the HR confirmation stage is the truncator and \
        the real defect is cold-start (night one, no history). If only +bandState lifts it, detection is \
        structurally dependent on a band channel that HR-only wearables cannot supply, and NOOP should say \
        so rather than silently reporting a 2 h night.
        """)
    }
}
