import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Diagnoses WHERE the sleep pipeline loses the night on real wrist data: detection or staging.
/// Opt-in, same cache as `SleepStagerRealPSGTests`.
final class SleepStagerCoverageDiagnosticTests: XCTestCase {
    private struct Subject: Decodable {
        let subject: String
        let psgStart: Int
        let psgEnd: Int
        let labels: [[Int]]
        let hr: [[Int]]
        let grav: [[Double]]
    }

    func testWhereTheNightIsLost() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOOP_WALCH_DIR"] else {
            throw XCTSkip("Set NOOP_WALCH_DIR")
        }
        let urls = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        func hm(_ seconds: Int) -> String {
            String(format: "%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
        }

        print("\n=== where does the night go? (detection vs staging) ===")
        for url in urls {
            let s = try JSONDecoder().decode(Subject.self, from: try Data(contentsOf: url))
            let hr = s.hr.map { HRSample(ts: $0[0], bpm: $0[1]) }
            let grav = s.grav.map { GravitySample(ts: Int($0[0]), x: $0[1], y: $0[2], z: $0[3], unit: "g") }
            let psgSpan = s.psgEnd - s.psgStart

            let sessions = SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: grav)
            let detectedTotal = sessions.reduce(0) { $0 + ($1.end - $1.start) }

            // Stage the PSG window directly: isolates staging coverage from detection.
            let direct = SleepStager.stageSession(start: s.psgStart, end: s.psgEnd,
                                                  grav: grav, hr: hr, rr: [], resp: [])
            let directCovered = direct.reduce(0) { $0 + ($1.end - $1.start) }

            print("\n\(s.subject)  PSG window \(hm(psgSpan))  hr=\(hr.count) grav=\(grav.count)")
            print("  detectSleep -> \(sessions.count) session(s), total \(hm(detectedTotal))")
            for (i, ses) in sessions.enumerated() {
                let ov = max(0, min(ses.end, s.psgEnd) - max(ses.start, s.psgStart))
                print("    [\(i)] \(hm(ses.end - ses.start))  overlap with PSG \(hm(ov))  stages=\(ses.stages.count)")
            }
            print("  stageSession(PSG window) -> \(direct.count) segment(s) covering \(hm(directCovered))"
                  + " of \(hm(psgSpan))"
                  + String(format: "  (%.0f%%)", psgSpan == 0 ? 0 : Double(directCovered) / Double(psgSpan) * 100))
            var byStage: [String: Int] = [:]
            for seg in direct { byStage[seg.stage, default: 0] += seg.end - seg.start }
            print("    " + byStage.sorted { $0.key < $1.key }.map { "\($0.key) \(hm($0.value))" }.joined(separator: "  "))
        }
    }
}
