import Foundation
import XCTest
@testable import StrandImport

final class WearableExportProductionParserTests: XCTestCase {
    private struct ExactJournalRow: Hashable {
        let cycleStart: Date?
        let tzOffsetMin: Int
        let question: String?
        let answer: String?
        let notes: String?
    }

    private struct JournalKey: Hashable {
        let day: String
        let question: String
    }

    /// Opt-in only: raw health archives remain outside the repository. Set this environment variable
    /// to a local export ZIP to exercise the same ZIP + CSV parser used by production.
    func testProductionArchiveIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOP_WEARABLE_EXPORT_ARCHIVE"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Set NOOP_WEARABLE_EXPORT_ARCHIVE to a private wearable-export archive")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return XCTFail("NOOP_WEARABLE_EXPORT_ARCHIVE does not exist")
        }

        let result = try WhoopExportImporter().import(from: URL(fileURLWithPath: path))
        XCTAssertFalse(result.cycles.isEmpty)
        XCTAssertFalse(result.sleeps.isEmpty)
        XCTAssertEqual(
            result.summary.recordCount,
            result.cycles.count + result.sleeps.count + result.workouts.count + result.journal.count
        )

        var exactRows = Set<ExactJournalRow>()
        for row in result.journal {
            XCTAssertTrue(exactRows.insert(ExactJournalRow(
                cycleStart: row.cycleStart,
                tzOffsetMin: row.tzOffsetMin,
                question: row.question,
                answer: row.answer,
                notes: row.notes
            )).inserted, "production parser returned an exact duplicate journal row")
        }

        var wakeDayByStart: [Int: String] = [:]
        for cycle in result.cycles {
            guard let start = cycle.cycleStart,
                  let day = WhoopDayKeying.wakeDayKey(
                    wake: cycle.wakeOnset,
                    end: cycle.cycleEnd,
                    start: cycle.cycleStart,
                    tzOffsetMin: cycle.tzOffsetMin
                  )
            else { continue }
            wakeDayByStart[Int(start.timeIntervalSince1970)] = day
        }

        var answersByKey: [JournalKey: Set<Bool>] = [:]
        for row in result.journal {
            guard let cycleStart = row.cycleStart,
                  let question = row.question,
                  let answer = journalBoolean(row.answer)
            else { continue }
            let day = wakeDayByStart[Int(cycleStart.timeIntervalSince1970)]
                ?? WhoopDayKeying.wakeDayKey(
                    wake: nil,
                    end: nil,
                    start: cycleStart,
                    tzOffsetMin: row.tzOffsetMin
                )
            guard let day else { continue }
            answersByKey[JournalKey(day: day, question: question), default: []]
                .insert(answer)
        }
        XCTAssertFalse(
            answersByKey.values.contains { $0.count > 1 },
            "production parser retained contradictory true/false answers for one day/question"
        )
    }

    private func journalBoolean(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "y": return true
        case "false", "no", "0", "n": return false
        default: return nil
        }
    }
}
