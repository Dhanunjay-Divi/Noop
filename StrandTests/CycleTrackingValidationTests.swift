import XCTest
@testable import Strand

final class CycleTrackingValidationTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    func testAcceptsStrictGregorianDayKeys() {
        XCTAssertTrue(Repository.isValidLocalDayKey("2026-08-11"))
        XCTAssertTrue(Repository.isValidLocalDayKey("2024-02-29"))
    }

    func testRejectsImpossibleOrNonCanonicalDayKeys() {
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-02-29"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-13-01"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-8-1"))
        XCTAssertFalse(Repository.isValidLocalDayKey("../../private"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-08-11T00:00:00Z"))
    }

    func testMenstrualCycleIsDirectlyBelowSexInProfile() throws {
        let settings = try source("Strand/Screens/SettingsView.swift")
        let sex = try XCTUnwrap(settings.range(of: "Picker(\"Sex\""))
        let cycle = try XCTUnwrap(
            settings.range(of: "menstrualCycleRow", range: sex.upperBound..<settings.endIndex))
        let weight = try XCTUnwrap(
            settings.range(of: "FormRow(label: \"Weight\"", range: sex.upperBound..<settings.endIndex))
        XCTAssertLessThan(cycle.lowerBound, weight.lowerBound)
    }

    func testCycleSetupSurvivesAnEmptyHealthHistoryAndProfileChanges() throws {
        let health = try source("Strand/Screens/HealthView.swift")
        XCTAssertTrue(health.contains("@EnvironmentObject private var profile: ProfileStore"))
        let firstRun = try XCTUnwrap(health.range(of: "private struct HealthFirstRunContent"))
        let nextTypeStart = health.range(
            of: "private struct",
            range: firstRun.upperBound..<health.endIndex
        )?.lowerBound ?? health.endIndex
        XCTAssertTrue(health[firstRun.lowerBound..<nextTypeStart].contains("SkinTempSection()"))
    }

    func testCycleRingNeverInventsALoggedDayOneMarker() throws {
        let cards = try source("Strand/Screens/SkinTempCardsView.swift")
        XCTAssertTrue(cards.contains("if hasLoggedStart"))
        XCTAssertTrue(cards.contains("CycleTimelineRing(result: currentResult, hasLoggedStart: !entries.isEmpty)"))
        XCTAssertTrue(cards.contains("CycleTimelineLegend(hasLoggedStart: !entries.isEmpty)"))
    }

    func testCycleUiHasNoPositiveFertilityPredictionClaims() throws {
        let cards = try source("Strand/Screens/SkinTempCardsView.swift").lowercased()
        for phrase in ["fertile window", "fertility window", "ovulation date",
                       "predicted ovulation", "safe-day"] {
            XCTAssertFalse(cards.contains(phrase), "Cycle UI contained prohibited phrase: \(phrase)")
        }
    }
}
