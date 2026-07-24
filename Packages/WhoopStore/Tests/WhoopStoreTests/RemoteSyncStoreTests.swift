import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RemoteSyncStoreTests: XCTestCase {
    func testPendingRowsAreAcknowledgedOnlyWhenExplicitlyMarked() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-remote"
        try await store.upsertDevice(id: deviceId, mac: nil, name: "Test")
        _ = try await store.insert(
            Streams(
                hr: [HRSample(ts: 100, bpm: 61)],
                rr: [RRInterval(ts: 100, rrMs: 810), RRInterval(ts: 100, rrMs: 810)],
                spo2: [SpO2Sample(ts: 101, red: 17_000, ir: 16_000)],
                skinTemp: [SkinTempSample(ts: 102, raw: 3_257)],
                resp: [RespSample(ts: 103, raw: 2_900)],
                steps: [StepSample(ts: 104, counter: 512, activityClass: 1)],
                events: [
                    WhoopEvent(ts: 105, kind: "TEST(1)", payload: ["value": .int(7)]),
                ],
                battery: [BatterySample(ts: 106, soc: 74.5, mv: 4_010, charging: false)]
            ),
            deviceId: deviceId
        )

        let pending = try await store.pendingRemoteSyncStreams(
            deviceId: deviceId, limitPerStream: 100
        )
        XCTAssertEqual(pending.count, 9)
        XCTAssertEqual(pending.rr.map(\.seq), [0, 1])
        XCTAssertEqual(pending.steps.first?.activityClass, 1)
        XCTAssertEqual(pending.battery.first?.stateOfCharge, 74.5)
        XCTAssertTrue(pending.events.first?.payloadJSON.contains("\"value\":7") == true)

        // A read alone never changes delivery state.
        let readAgain = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertEqual(readAgain, pending)

        try await store.markRemoteSyncStreamsSynced(pending, deviceId: deviceId)
        let afterAck = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertTrue(afterAck.isEmpty)
    }

    func testResetMakesAcknowledgedRowsPendingForNewDestination() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-remote"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 200, bpm: 70)]),
            deviceId: deviceId
        )
        let first = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        try await store.markRemoteSyncStreamsSynced(first, deviceId: deviceId)
        let emptyAfterMark = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertTrue(emptyAfterMark.isEmpty)

        try await store.resetRemoteSyncState(deviceId: deviceId)
        let replay = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertEqual(replay.hr, [.init(ts: 200, bpm: 70)])
    }

    func testPerStreamLimitAndDeviceIsolation() async throws {
        let store = try await WhoopStore.inMemory()
        for id in ["mine", "other"] {
            try await store.upsertDevice(id: id, mac: nil, name: nil)
            _ = try await store.insert(
                Streams(hr: [
                    HRSample(ts: 1, bpm: 60), HRSample(ts: 2, bpm: 61),
                ]),
                deviceId: id
            )
        }
        let pending = try await store.pendingRemoteSyncStreams(
            deviceId: "mine", limitPerStream: 1
        )
        XCTAssertEqual(pending.hr, [.init(ts: 1, bpm: 60)])
    }

    func testDerivedReadersResumeAfterExclusiveNaturalKeys() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "derived-source"
        _ = try await store.upsertSleepSessions(
            [100, 200, 300].map {
                CachedSleepSession(
                    startTs: $0,
                    endTs: $0 + 60,
                    efficiency: nil,
                    restingHr: nil,
                    avgHrv: nil,
                    stagesJSON: nil
                )
            },
            deviceId: deviceId
        )
        _ = try await store.upsertWorkouts(
            [
                WorkoutRow(
                    startTs: 100, endTs: 160, sport: "Bike", source: "whoop",
                    durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                    strain: nil, distanceM: nil, zonesJSON: nil, notes: nil
                ),
                WorkoutRow(
                    startTs: 100, endTs: 160, sport: "Run", source: "whoop",
                    durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                    strain: nil, distanceM: nil, zonesJSON: nil, notes: nil
                ),
                WorkoutRow(
                    startTs: 200, endTs: 260, sport: "Swim", source: "manual",
                    durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                    strain: nil, distanceM: nil, zonesJSON: nil, notes: nil
                ),
            ],
            deviceId: deviceId
        )
        _ = try await store.upsertJournal(
            [
                JournalEntry(
                    day: "2026-07-23", question: "Alcohol?", answeredYes: false, notes: nil
                ),
                JournalEntry(
                    day: "2026-07-23", question: "Caffeine?", answeredYes: true, notes: nil
                ),
                JournalEntry(
                    day: "2026-07-24", question: "Caffeine?", answeredYes: false, notes: nil
                ),
            ],
            deviceId: deviceId
        )

        let sleep = try await store.remoteSyncSleepSessions(
            deviceId: deviceId,
            from: 0,
            to: 1_000,
            limit: 10,
            afterStartTs: 100
        )
        XCTAssertEqual(sleep.map(\.startTs), [200, 300])

        let workouts = try await store.remoteSyncWorkouts(
            deviceId: deviceId,
            from: 0,
            to: 1_000,
            allowedSources: Set(["whoop"]),
            limit: 10,
            afterStartTs: 100,
            afterSport: "Bike"
        )
        XCTAssertEqual(workouts.map { "\($0.startTs)|\($0.sport)" }, ["100|Run"])

        let journal = try await store.remoteSyncJournalEntries(
            deviceId: deviceId,
            from: "2026-07-01",
            to: "2026-07-31",
            limit: 10,
            afterDay: "2026-07-23",
            afterQuestion: "Alcohol?"
        )
        XCTAssertEqual(
            journal.map { "\($0.day)|\($0.question)" },
            ["2026-07-23|Caffeine?", "2026-07-24|Caffeine?"]
        )
    }
}
