import XCTest
@testable import Strand

@MainActor
final class MetricReviewRemindersTests: XCTestCase {
    func testEmptyMetricSelectionDoesNotCreateReminder() {
        XCTAssertNil(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 18 * 60,
                metricTitles: ["", ""]
            )
        )
    }

    func testSingleMetricReminderRoutesToTrendsWithoutEmbeddingAValue() throws {
        let spec = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 18 * 60,
                metricTitles: ["Heart rate variability"]
            )
        )

        XCTAssertEqual(spec.identifier, "metric-review-daily")
        XCTAssertEqual(spec.minuteOfDay, 18 * 60)
        XCTAssertEqual(spec.cadence, .daily)
        XCTAssertEqual(spec.route, .trends)
        XCTAssertTrue(spec.body.contains("Heart rate variability"))
        XCTAssertTrue(spec.body.localizedCaseInsensitiveContains("baseline"))
        XCTAssertNil(spec.body.rangeOfCharacter(from: .decimalDigits))
        XCTAssertFalse(spec.body.localizedCaseInsensitiveContains("score"))
    }

    func testDuplicateTitlesAreCoalescedBeforeWritingCopy() throws {
        let spec = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 7 * 60,
                metricTitles: ["Resting heart rate", "Resting heart rate", "Sleep consistency"]
            )
        )

        XCTAssertEqual(spec.body, "Review Resting heart rate and Sleep consistency in your Trends.")
    }

    func testReminderTimeIsClampedToAValidDay() throws {
        let early = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: -1,
                metricTitles: ["Steps"]
            )
        )
        let late = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 9_000,
                metricTitles: ["Steps"]
            )
        )

        XCTAssertEqual(early.minuteOfDay, 0)
        XCTAssertEqual(late.minuteOfDay, 24 * 60 - 1)
    }

    func testSeveralMetricsUseOneBoundedSummary() throws {
        let spec = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 12 * 60,
                metricTitles: ["HRV", "Resting heart rate", "Respiratory rate", "Skin temperature"]
            )
        )

        XCTAssertEqual(spec.route, .trends)
        XCTAssertTrue(spec.body.contains("HRV"))
        XCTAssertTrue(spec.body.contains("Resting heart rate"))
        XCTAssertTrue(spec.body.contains("2 more selected metrics"))
        XCTAssertFalse(spec.body.contains("Respiratory rate"))
        XCTAssertFalse(spec.body.contains("Skin temperature"))
    }

    func testSlowModelEstimatesDefaultToMonthlyReview() {
        XCTAssertEqual(
            MetricReviewReminders.recommendedCadence(
                metricID: "my-whoop:fitness_age"
            ),
            .monthly
        )
        XCTAssertEqual(
            MetricReviewReminders.recommendedCadence(
                metricID: "my-whoop:body_age"
            ),
            .monthly
        )
    }

    func testMonthlyReminderUsesItsOwnCoalescedRequest() throws {
        let spec = try XCTUnwrap(
            MetricReviewReminders.reminderSpec(
                minuteOfDay: 18 * 60,
                metricTitles: ["Fitness Age"],
                cadence: .monthly
            )
        )

        XCTAssertEqual(spec.identifier, "metric-review-monthly")
        XCTAssertEqual(spec.cadence, .monthly)
        XCTAssertEqual(spec.title, "Metric review")
        XCTAssertTrue(spec.body.contains("Fitness Age"))
    }
}
