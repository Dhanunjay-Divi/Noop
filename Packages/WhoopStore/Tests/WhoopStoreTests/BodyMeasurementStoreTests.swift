import XCTest
@testable import WhoopStore

final class BodyMeasurementStoreTests: XCTestCase {
    func testTimestampedMeasurementsRoundTripAndReplayIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let first = BodyMeasurementRow(measuredAt: 2_000_000_000, receivedAt: 2_000_000_010,
                                       weightKg: 78.4, bmi: 24.1, heightCm: 180,
                                       userID: 7, unit: "si", source: "bluetooth-sig-wss")
        let firstCount = try await store.upsertBodyMeasurements([first], deviceId: "weight-scale-a")
        XCTAssertEqual(firstCount, 1)

        let replay = BodyMeasurementRow(measuredAt: first.measuredAt, receivedAt: first.receivedAt + 5,
                                        weightKg: 78.3, bmi: 24.0, heightCm: 180,
                                        userID: 7, unit: "si", source: "bluetooth-sig-wss")
        _ = try await store.upsertBodyMeasurements([replay], deviceId: "weight-scale-a")
        let rows = try await store.bodyMeasurements(deviceId: "weight-scale-a", from: 0, to: Int.max)
        XCTAssertEqual(rows, [replay])

        let staleReplay = BodyMeasurementRow(measuredAt: first.measuredAt,
                                             receivedAt: first.receivedAt - 1,
                                             weightKg: 99.9,
                                             bmi: 30,
                                             heightCm: 170,
                                             userID: 7,
                                             unit: "imperial",
                                             source: "stale-replay")
        let staleCount = try await store.upsertBodyMeasurements([staleReplay], deviceId: "weight-scale-a")
        XCTAssertEqual(staleCount, 0)
        let afterStale = try await store.bodyMeasurements(deviceId: "weight-scale-a", from: 0, to: Int.max)
        XCTAssertEqual(afterStale, [replay])
    }

    func testMissingUnknownAndKnownUsersRemainDistinct() async throws {
        let store = try await WhoopStore.inMemory()
        let base = 2_000_000_000
        let rows = [
            BodyMeasurementRow(measuredAt: base, receivedAt: base, weightKg: 70,
                               bmi: nil, heightCm: nil, userID: nil, unit: "si", source: "wss"),
            BodyMeasurementRow(measuredAt: base, receivedAt: base, weightKg: 71,
                               bmi: nil, heightCm: nil, userID: 255, unit: "si", source: "wss"),
            BodyMeasurementRow(measuredAt: base, receivedAt: base, weightKg: 72,
                               bmi: nil, heightCm: nil, userID: 3, unit: "si", source: "wss"),
        ]
        _ = try await store.upsertBodyMeasurements(rows, deviceId: "weight-scale-a")

        let all = try await store.bodyMeasurements(deviceId: "weight-scale-a", from: base, to: base)
        XCTAssertEqual(all.count, 3)
        let noUser = try await store.bodyMeasurements(deviceId: "weight-scale-a", from: base, to: base,
                                                      userID: -1)
        XCTAssertEqual(noUser.map(\.userID), [nil])
        let unknown = try await store.latestBodyMeasurement(deviceId: "weight-scale-a", userID: 255)
        XCTAssertEqual(unknown?.userID, 255)
    }
}
