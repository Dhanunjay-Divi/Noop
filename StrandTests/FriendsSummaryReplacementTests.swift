import XCTest
import NoopRemoteSync
@testable import Strand

final class FriendsSummaryReplacementTests: XCTestCase {
    func testCatchUpWindowContainsInclusiveEmptyReplacementForEveryDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 3,
                    day: 15,
                    hour: 12
                )
            )
        )

        let days = FriendsSummaryReplacement.days(
            daysBack: 30,
            now: now,
            calendar: calendar
        )
        let payload = Dictionary(
            uniqueKeysWithValues: days.map { ($0, [String: Double]()) }
        )

        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(days.first, "2026-02-13")
        XCTAssertEqual(days.last, "2026-03-15")
        XCTAssertEqual(payload.count, 31)
        XCTAssertTrue(payload.values.allSatisfy(\.isEmpty))
    }

    func testEmptyDailyReplacementMapsSurviveRemoteEnvelopeEncoding() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(year: 2026, month: 7, day: 25, hour: 12)
            )
        )
        let days = FriendsSummaryReplacement.days(
            daysBack: 2,
            now: now,
            calendar: calendar
        )
        let payload = Dictionary(
            uniqueKeysWithValues: days.map { ($0, [String: Double]()) }
        )
        let envelope = RemoteSyncEnvelope(
            source: RemoteSyncSource(
                deviceId: "ios:test-install:noop-friends",
                platform: "ios"
            ),
            dailyMetrics: payload
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedDaily = try XCTUnwrap(
            object["daily_metrics"] as? [String: Any]
        )

        XCTAssertEqual(Set(encodedDaily.keys), Set(days))
        for day in days {
            XCTAssertEqual((encodedDaily[day] as? [String: Any])?.count, 0)
        }
    }
}
