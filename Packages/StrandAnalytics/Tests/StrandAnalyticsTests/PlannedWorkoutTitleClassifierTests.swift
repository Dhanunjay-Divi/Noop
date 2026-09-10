import XCTest
@testable import StrandAnalytics

final class PlannedWorkoutTitleClassifierTests: XCTestCase {
    func testRecognizesConservativeWorkoutTitles() {
        for title in [
            "Gym",
            "Morning run",
            "Strength training",
            "Yoga with Maya",
            "HIIT 45",
            "Swim",
            "Evening bike ride",
            "Spin class",
            "Trail running",
            "10K training",
        ] {
            XCTAssertTrue(
                PlannedWorkoutTitleClassifier.isWorkoutTitle(title),
                "Expected workout title: \(title)"
            )
        }
    }

    func testRecognizesWorkoutTitlesAcrossEveryLocalizedAppLanguage() {
        for title in [
            "Schwimmen",
            "Gimnasio",
            "Natation",
            "Palestra",
            "Ginásio",
            "Тренировка",
            "游泳",
            "騎行",
            "早上跑步",
            "晚间瑜伽课",
            "晚上騎行課",
        ] {
            XCTAssertTrue(
                PlannedWorkoutTitleClassifier.isWorkoutTitle(title),
                "Expected localized workout title: \(title)"
            )
        }
    }

    func testRejectsAmbiguousAndWorkTitles() {
        for title in [
            nil,
            "",
            "Training",
            "Training meeting",
            "Project run review",
            "Run payroll",
            "Run backup",
            "Spin up staging",
            "Running payroll",
            "Morning backup run",
            "Disaster recovery runbook",
            "Run errands",
            "School run",
            "Dry run",
            "Yoga workshop",
            "Team standup",
            "Bike repair",
            "Football watch party",
            "Tennis tickets",
            "Gym equipment shopping",
            "Gimnasio reunión",
            "Schwimmen Besprechung",
            "Тренировка встреча",
            "健身会议",
            "健身會議",
            "早上跑步会议",
            "晚间瑜伽研讨会",
            "晚上騎行研討會",
        ] {
            XCTAssertFalse(
                PlannedWorkoutTitleClassifier.isWorkoutTitle(title),
                "Expected non-workout title: \(title ?? "nil")"
            )
        }
    }
}
