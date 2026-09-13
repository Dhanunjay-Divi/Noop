import XCTest
import GRDB
@testable import WhoopStore

final class AnalysisDirtySourceTests: XCTestCase {
    private func claim(
        _ deviceId: String,
        _ generation: Int64,
        _ earliest: Int64,
        _ latest: Int64? = nil
    ) -> AnalysisInputGenerationClaim {
        AnalysisInputGenerationClaim(
            deviceId: deviceId,
            generation: generation,
            earliestAffectedTs: earliest,
            latestAffectedTs: latest ?? earliest
        )
    }

    private struct ScoreTableFixture {
        let table: String
        let deviceId: String
        let insertSQL: String
        let updateSQL: String
    }

    private let fixtures: [ScoreTableFixture] = [
        .init(
            table: "hrSample",
            deviceId: "dirty-hr",
            insertSQL: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('dirty-hr', 1, 60)",
            updateSQL: "UPDATE hrSample SET bpm = 61 WHERE deviceId = 'dirty-hr'"
        ),
        .init(
            table: "ppgHrSample",
            deviceId: "dirty-ppg-hr",
            insertSQL: """
                INSERT INTO ppgHrSample (deviceId, ts, bpm, conf)
                VALUES ('dirty-ppg-hr', 2, 60, 0.9)
                """,
            updateSQL: "UPDATE ppgHrSample SET conf = 0.8 WHERE deviceId = 'dirty-ppg-hr'"
        ),
        .init(
            table: "rrInterval",
            deviceId: "dirty-rr",
            insertSQL: """
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq)
                VALUES ('dirty-rr', 3, 1000, 0)
                """,
            updateSQL: "UPDATE rrInterval SET ord = 1 WHERE deviceId = 'dirty-rr'"
        ),
        .init(
            table: "gravitySample",
            deviceId: "dirty-gravity",
            insertSQL: """
                INSERT INTO gravitySample (deviceId, ts, x, y, z)
                VALUES ('dirty-gravity', 4, 0, 0, 1)
                """,
            updateSQL: "UPDATE gravitySample SET x = 0.1 WHERE deviceId = 'dirty-gravity'"
        ),
        .init(
            table: "respSample",
            deviceId: "dirty-resp",
            insertSQL: "INSERT INTO respSample (deviceId, ts, raw) VALUES ('dirty-resp', 5, 100)",
            updateSQL: "UPDATE respSample SET raw = 101 WHERE deviceId = 'dirty-resp'"
        ),
        .init(
            table: "skinTempSample",
            deviceId: "dirty-skin",
            insertSQL: """
                INSERT INTO skinTempSample (deviceId, ts, raw)
                VALUES ('dirty-skin', 6, 900)
                """,
            updateSQL: "UPDATE skinTempSample SET raw = 901 WHERE deviceId = 'dirty-skin'"
        ),
        .init(
            table: "spo2Sample",
            deviceId: "dirty-spo2",
            insertSQL: """
                INSERT INTO spo2Sample (deviceId, ts, red, ir)
                VALUES ('dirty-spo2', 7, 10, 20)
                """,
            updateSQL: "UPDATE spo2Sample SET red = 11 WHERE deviceId = 'dirty-spo2'"
        ),
        .init(
            table: "stepSample",
            deviceId: "dirty-step",
            insertSQL: """
                INSERT INTO stepSample (deviceId, ts, counter)
                VALUES ('dirty-step', 8, 100)
                """,
            updateSQL: "UPDATE stepSample SET counter = 101 WHERE deviceId = 'dirty-step'"
        ),
        .init(
            table: "sleepStateSample",
            deviceId: "dirty-sleep-state",
            insertSQL: """
                INSERT INTO sleepStateSample (deviceId, ts, state)
                VALUES ('dirty-sleep-state', 9, 2)
                """,
            updateSQL: """
                UPDATE sleepStateSample SET state = 1
                WHERE deviceId = 'dirty-sleep-state'
                """
        ),
        .init(
            table: "event",
            deviceId: "dirty-event",
            insertSQL: """
                INSERT INTO event (deviceId, ts, kind, payloadJSON)
                VALUES ('dirty-event', 10, 'ON_WRIST', '{}')
                """,
            updateSQL: """
                UPDATE event SET payloadJSON = '{"changed":true}'
                WHERE deviceId = 'dirty-event'
                """
        ),
    ]

    func testV57SeedsExistingScoreBearingSourcesButNotTransportOnlySources() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v56-managed-hydration-document")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('legacy-hr', 1, 60)"
            )
            try db.execute(
                sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf)
                    VALUES ('legacy-ppg', 2, 60, 0.9)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv)
                    VALUES ('battery-only', 3, 90, 4000)
                    """
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('', 4, 60)"
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('   ', 5, 60)"
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 6, 60)",
                arguments: ["\t\n"]
            )
        }

        try migrator.migrate(queue)

        let dirty = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT deviceId, generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    ORDER BY deviceId
                    """
            ).map {
                (
                    deviceId: $0["deviceId"] as String,
                    generation: $0["generation"] as Int64,
                    acknowledged: $0["acknowledgedGeneration"] as Int64,
                    earliest: $0["earliestAffectedTs"] as Int64,
                    latest: $0["latestAffectedTs"] as Int64
                )
            }
        }
        XCTAssertEqual(dirty.map(\.deviceId), ["legacy-hr", "legacy-ppg"])
        XCTAssertEqual(dirty.map(\.generation), [1, 1])
        XCTAssertEqual(dirty.map(\.acknowledged), [0, 0])
        XCTAssertEqual(dirty.map(\.earliest), [1, 2])
        XCTAssertEqual(dirty.map(\.latest), [1, 2])
    }

    func testV58RepairsRecordedGenerationOnlyV57AndReplacesOldTrigger() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v56-managed-hydration-document")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('legacy-v57', 100, 60)"
            )
            try db.execute(sql: """
                CREATE TABLE analysisDirtySource (
                    deviceId TEXT NOT NULL PRIMARY KEY,
                    generation INTEGER NOT NULL,
                    acknowledgedGeneration INTEGER NOT NULL
                );
                INSERT INTO analysisDirtySource (
                    deviceId, generation, acknowledgedGeneration
                ) VALUES ('legacy-v57', 3, 3);
                CREATE TRIGGER analysis_dirty_hrSample_insert
                AFTER INSERT ON hrSample
                BEGIN
                    UPDATE analysisDirtySource
                    SET generation = generation + 10
                    WHERE deviceId = NEW.deviceId;
                END;
                INSERT INTO grdb_migrations (identifier)
                VALUES ('v57-analysis-dirty-source');
                """)
        }

        try migrator.migrate(queue)

        var repaired = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = 'legacy-v57'
                    """
            )
        }
        XCTAssertEqual(repaired?["generation"] as Int64?, 4)
        XCTAssertEqual(repaired?["acknowledgedGeneration"] as Int64?, 3)
        XCTAssertEqual(repaired?["earliestAffectedTs"] as Int64?, 100)
        XCTAssertEqual(repaired?["latestAffectedTs"] as Int64?, 100)

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('legacy-v57', 200, 61)"
            )
        }
        repaired = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = 'legacy-v57'
                    """
            )
        }
        XCTAssertEqual(repaired?["generation"] as Int64?, 5)
        XCTAssertEqual(repaired?["acknowledgedGeneration"] as Int64?, 3)
        XCTAssertEqual(repaired?["earliestAffectedTs"] as Int64?, 100)
        XCTAssertEqual(repaired?["latestAffectedTs"] as Int64?, 200)
    }

    func testV58LeavesCurrentBoundedV57StateUnchanged() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v57-analysis-dirty-source")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('bounded-v57', 100, 60)"
            )
        }
        let before = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = 'bounded-v57'
                    """
            )
        }

        try migrator.migrate(queue)

        let after = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = 'bounded-v57'
                    """
            )
        }
        XCTAssertEqual(after?["generation"] as Int64?, before?["generation"])
        XCTAssertEqual(
            after?["acknowledgedGeneration"] as Int64?,
            before?["acknowledgedGeneration"]
        )
        XCTAssertEqual(
            after?["earliestAffectedTs"] as Int64?,
            before?["earliestAffectedTs"]
        )
        XCTAssertEqual(
            after?["latestAffectedTs"] as Int64?,
            before?["latestAffectedTs"]
        )

        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('bounded-v57', 200, 61)"
            )
        }
        let triggered = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = 'bounded-v57'
                    """
            )
        }
        XCTAssertEqual(
            triggered?["generation"] as Int64?,
            (before?["generation"] as Int64?).map { $0 + 1 }
        )
        XCTAssertEqual(triggered?["earliestAffectedTs"] as Int64?, 100)
        XCTAssertEqual(triggered?["latestAffectedTs"] as Int64?, 200)
    }

    func testBlankDeviceIdsNeverCreateGenerationRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [""]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 2, 60)",
                arguments: ["   "]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 3, 60)",
                arguments: ["\t\n"]
            )
        }
        let dirtyRows = try await store.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT deviceId FROM analysisDirtySource")
        }
        XCTAssertEqual(dirtyRows, [])

        // Each side of an UPDATE is guarded independently: blank -> valid marks only the valid id,
        // while valid -> blank marks only the prior valid id.
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE hrSample SET deviceId = 'valid-source' WHERE ts = 1"
            )
        }
        var claims = try await store.pendingAnalysisInputGenerations(
            deviceIds: ["", "   ", "valid-source"]
        )
        XCTAssertEqual(claims, [
            claim("valid-source", 1, 1),
        ])
        try await store.acknowledgeAnalysisInputGenerations(claims)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE hrSample SET deviceId = '' WHERE ts = 1"
            )
        }
        claims = try await store.pendingAnalysisInputGenerations(
            deviceIds: ["", "valid-source"]
        )
        XCTAssertEqual(claims, [
            claim("valid-source", 2, 1),
        ])
        try await store.acknowledgeAnalysisInputGenerations(claims)

        try await store.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM hrSample")
        }
        claims = try await store.pendingAnalysisInputGenerations(
            deviceIds: ["", "   ", "\t\n", "valid-source"]
        )
        XCTAssertEqual(claims, [])
    }

    func testEveryScoreBearingTableAdvancesGenerationOnInsertUpdateAndDelete() async throws {
        let store = try await WhoopStore.inMemory()
        let ids = fixtures.map(\.deviceId).sorted()

        try await store.registryWriter.write { db in
            for fixture in self.fixtures {
                try db.execute(sql: fixture.insertSQL)
            }
        }
        let inserted = try await store.pendingAnalysisInputGenerations(deviceIds: ids)
        XCTAssertEqual(inserted.map(\.deviceId), ids)
        XCTAssertEqual(Set(inserted.map(\.generation)), Set([Int64(1)]))
        for (index, fixture) in fixtures.enumerated() {
            let actual = try XCTUnwrap(inserted.first { $0.deviceId == fixture.deviceId })
            XCTAssertEqual(actual.earliestAffectedTs, Int64(index + 1))
            XCTAssertEqual(actual.latestAffectedTs, Int64(index + 1))
        }
        try await store.acknowledgeAnalysisInputGenerations(inserted)

        try await store.registryWriter.write { db in
            for fixture in self.fixtures {
                try db.execute(sql: fixture.updateSQL)
            }
        }
        let updated = try await store.pendingAnalysisInputGenerations(deviceIds: ids)
        XCTAssertEqual(updated.map(\.deviceId), ids)
        XCTAssertEqual(Set(updated.map(\.generation)), Set([Int64(2)]))
        try await store.acknowledgeAnalysisInputGenerations(updated)

        try await store.registryWriter.write { db in
            for fixture in self.fixtures {
                try db.execute(
                    sql: "DELETE FROM \"\(fixture.table)\" WHERE deviceId = ?",
                    arguments: [fixture.deviceId]
                )
            }
        }
        let deleted = try await store.pendingAnalysisInputGenerations(deviceIds: ids)
        XCTAssertEqual(deleted.map(\.deviceId), ids)
        XCTAssertEqual(Set(deleted.map(\.generation)), Set([Int64(3)]))
    }

    func testTransportSyncedUpdateDoesNotMarkAnalysisDirty() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "transport-only-update"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
        }
        let inserted = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(inserted, [
            claim(id, 1, 1),
        ])
        try await store.acknowledgeAnalysisInputGenerations(inserted)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE hrSample SET synced = 1 WHERE deviceId = ?",
                arguments: [id]
            )
        }
        let transportOnly = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(transportOnly, [])
    }

    func testOuterUpsertCannotOverrideGenerationConflictHandling() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "upsert-while-dirty"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
            try db.execute(
                sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm)
                    VALUES (?, 1, 61)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET bpm = excluded.bpm
                    """,
                arguments: [id]
            )
        }

        let dirty = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(dirty, [
            claim(id, 2, 1),
        ])
        let bpm = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT bpm FROM hrSample WHERE deviceId = ? AND ts = 1",
                arguments: [id]
            )
        }
        XCTAssertEqual(bpm, 61)
    }

    func testSnapshotDoesNotMutateAndProcessDeathLeavesGenerationPending() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "crash-safe"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
        }

        let expected = [claim(id, 1, 1)]
        let first = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(first, expected)

        // Simulate force-quit/process death: no acknowledgement occurs. A new pass snapshots the same work.
        let second = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(second, expected)

        try await store.acknowledgeAnalysisInputGenerations(first)
        let clean = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(clean, [])
        let clearedBounds = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource WHERE deviceId = ?
                    """,
                arguments: [id]
            )
        }
        XCTAssertNil(clearedBounds?["earliestAffectedTs"] as Int64?)
        XCTAssertNil(clearedBounds?["latestAffectedTs"] as Int64?)
    }

    func testLaterWriteRemainsPendingAfterExactClaimAcknowledgement() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "post-snapshot"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
        }
        let first = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(first, [
            claim(id, 1, 1),
        ])

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 2, 61)",
                arguments: [id]
            )
        }
        try await store.acknowledgeAnalysisInputGenerations(first)

        let next = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(next, [
            claim(id, 2, 1, 2),
        ])
        let state = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, acknowledgedGeneration,
                           earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource WHERE deviceId = ?
                    """,
                arguments: [id]
            )
        }
        let generation: Int64? = state?["generation"]
        let acknowledgedGeneration: Int64? = state?["acknowledgedGeneration"]
        let earliestAffectedTs: Int64? = state?["earliestAffectedTs"]
        let latestAffectedTs: Int64? = state?["latestAffectedTs"]
        XCTAssertEqual(generation, 2)
        XCTAssertEqual(acknowledgedGeneration, 1)
        XCTAssertEqual(earliestAffectedTs, 1)
        XCTAssertEqual(latestAffectedTs, 2)
    }

    func testTimestampCorrectionAndSourceMoveTrackBothOldAndNewAffectedBounds() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('source-a', 100, 60)"
            )
        }
        let inserted = try await store.pendingAnalysisInputGenerations(deviceIds: ["source-a"])
        try await store.acknowledgeAnalysisInputGenerations(inserted)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE hrSample
                    SET deviceId = 'source-b', ts = 250
                    WHERE deviceId = 'source-a' AND ts = 100
                    """
            )
        }

        let movedClaims = try await store.pendingAnalysisInputGenerations(
            deviceIds: ["source-a", "source-b"]
        )
        XCTAssertEqual(
            movedClaims,
            [
                claim("source-a", 2, 100),
                claim("source-b", 1, 250),
            ]
        )

        let sourceB = try await store.pendingAnalysisInputGenerations(deviceIds: ["source-b"])
        try await store.acknowledgeAnalysisInputGenerations(sourceB)
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE hrSample SET ts = 175
                    WHERE deviceId = 'source-b' AND ts = 250
                    """
            )
        }
        let correctedClaims = try await store.pendingAnalysisInputGenerations(
            deviceIds: ["source-b"]
        )
        XCTAssertEqual(correctedClaims, [claim("source-b", 2, 175, 250)])
    }

    func testDuplicateAndStaleAcknowledgementsNeverAdvancePastClaim() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "bounded-ack"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 2, 61)",
                arguments: [id]
            )
        }

        try await store.acknowledgeAnalysisInputGenerations([
            .init(deviceId: id, generation: 1),
            .init(deviceId: id, generation: 1),
            .init(deviceId: id, generation: 99),
            .init(deviceId: "", generation: 2),
            .init(deviceId: "ignored", generation: 0),
        ])
        var pending = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(pending, [
            claim(id, 2, 1, 2),
        ])

        try await store.acknowledgeAnalysisInputGenerations(pending)
        try await store.acknowledgeAnalysisInputGenerations([
            .init(deviceId: id, generation: 1),
        ])
        pending = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(pending, [])
    }

    func testBoundedFinalizationAdvancesNewestTailThenAcknowledgesRemainder() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "bounded-progress"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 100, 60)",
                arguments: [id]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 200, 61)",
                arguments: [id]
            )
        }
        let original = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(original, [claim(id, 2, 100, 200)])

        let first = try await store.finalizeAnalysisInputGenerations(
            original,
            coverageStartTs: 151,
            coverageEndTs: 250
        )
        XCTAssertEqual(
            first,
            AnalysisInputFinalizationResult(acknowledgedCount: 0, advancedCount: 1)
        )
        let remaining = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(remaining, [claim(id, 2, 100, 150)])

        let second = try await store.finalizeAnalysisInputGenerations(
            remaining,
            coverageStartTs: 0,
            coverageEndTs: 150
        )
        XCTAssertEqual(
            second,
            AnalysisInputFinalizationResult(acknowledgedCount: 1, advancedCount: 0)
        )
        let completed = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(completed, [])
    }

    func testBoundedFinalizationNeverTrimsAConcurrentGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "concurrent-progress"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 100, 60)",
                arguments: [id]
            )
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 200, 61)",
                arguments: [id]
            )
        }
        let claimed = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 300, 62)",
                arguments: [id]
            )
        }

        let result = try await store.finalizeAnalysisInputGenerations(
            claimed,
            coverageStartTs: 151,
            coverageEndTs: 250
        )

        XCTAssertEqual(
            result,
            AnalysisInputFinalizationResult(acknowledgedCount: 0, advancedCount: 0)
        )
        let pending = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertEqual(pending, [claim(id, 3, 100, 300)])
    }

    func testScoreBearingHistoryProofStopsAtPresenceAndSupportsGlobalOwnership() async throws {
        let store = try await WhoopStore.inMemory()
        let emptyGlobal = try await store.hasScoreBearingAnalysisHistory()
        let emptySource = try await store.hasScoreBearingAnalysisHistory(deviceId: "source-a")
        XCTAssertFalse(emptyGlobal)
        XCTAssertFalse(emptySource)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO sleepStateSample (deviceId, ts, state) VALUES (?, 100, 2)",
                arguments: ["source-a"]
            )
        }

        let populatedGlobal = try await store.hasScoreBearingAnalysisHistory()
        let populatedSource = try await store.hasScoreBearingAnalysisHistory(
            deviceId: "source-a"
        )
        let absentSource = try await store.hasScoreBearingAnalysisHistory(
            deviceId: "source-b"
        )
        XCTAssertTrue(populatedGlobal)
        XCTAssertTrue(populatedSource)
        XCTAssertFalse(absentSource)
    }

    func testDeleteAllSourceDataRemovesGenerationState() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "deleted-source"
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, 1, 60)",
                arguments: [id]
            )
        }
        let pendingBeforeDelete = try await store.pendingAnalysisInputGenerations(deviceIds: [id])
        XCTAssertFalse(pendingBeforeDelete.isEmpty)
        try await store.deleteAllData(deviceId: id)

        let rowCount = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM analysisDirtySource WHERE deviceId = ?",
                arguments: [id]
            ) ?? -1
        }
        XCTAssertEqual(rowCount, 0)
    }
}
