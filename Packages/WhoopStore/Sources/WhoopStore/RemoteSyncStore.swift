import Foundation
import GRDB

/// A durable, bounded snapshot of decoded rows waiting for the optional self-hosted server.
///
/// These types retain each table's natural key (including the RR `seq`) so exactly the uploaded
/// rows can be acknowledged after a 2xx response. They intentionally expose raw sensor units:
/// red/IR optical values, skin-temperature ADC, and respiration ADC are not clinical measurements.
public struct PendingRemoteSyncStreams: Sendable, Equatable {
    public struct HR: Sendable, Equatable {
        public let ts: Int
        public let bpm: Int
        public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
    }

    public struct RR: Sendable, Equatable {
        public let ts: Int
        public let rrMs: Int
        public let seq: Int
        public init(ts: Int, rrMs: Int, seq: Int) {
            self.ts = ts; self.rrMs = rrMs; self.seq = seq
        }
    }

    public struct Event: Sendable, Equatable {
        public let ts: Int
        public let kind: String
        public let payloadJSON: String
        public init(ts: Int, kind: String, payloadJSON: String) {
            self.ts = ts; self.kind = kind; self.payloadJSON = payloadJSON
        }
    }

    public struct Battery: Sendable, Equatable {
        public let ts: Int
        public let stateOfCharge: Double?
        public let millivolts: Int?
        public let charging: Bool?
        public init(ts: Int, stateOfCharge: Double?, millivolts: Int?, charging: Bool?) {
            self.ts = ts; self.stateOfCharge = stateOfCharge
            self.millivolts = millivolts; self.charging = charging
        }
    }

    public struct SpO2Raw: Sendable, Equatable {
        public let ts: Int
        public let red: Int
        public let infrared: Int
        public init(ts: Int, red: Int, infrared: Int) {
            self.ts = ts; self.red = red; self.infrared = infrared
        }
    }

    public struct RawScalar: Sendable, Equatable {
        public let ts: Int
        public let raw: Int
        public init(ts: Int, raw: Int) { self.ts = ts; self.raw = raw }
    }

    public struct Step: Sendable, Equatable {
        public let ts: Int
        public let counter: Int
        public let activityClass: Int?
        public init(ts: Int, counter: Int, activityClass: Int?) {
            self.ts = ts; self.counter = counter; self.activityClass = activityClass
        }
    }

    public struct Gravity: Sendable, Equatable {
        public let ts: Int
        public let x: Double
        public let y: Double
        public let z: Double
        public init(ts: Int, x: Double, y: Double, z: Double) {
            self.ts = ts; self.x = x; self.y = y; self.z = z
        }
    }

    public struct SleepState: Sendable, Equatable {
        public let ts: Int
        public let state: Int
        public init(ts: Int, state: Int) {
            self.ts = ts; self.state = state
        }
    }

    public struct PpgHR: Sendable, Equatable {
        public let ts: Int
        public let bpm: Double
        public let confidence: Double
        public init(ts: Int, bpm: Double, confidence: Double) {
            self.ts = ts; self.bpm = bpm; self.confidence = confidence
        }
    }

    public struct PpgWaveform: Sendable, Equatable {
        public let ts: Int
        public let samples: Data
        public init(ts: Int, samples: Data) {
            self.ts = ts; self.samples = samples
        }
    }

    public let hr: [HR]
    public let rr: [RR]
    public let events: [Event]
    public let battery: [Battery]
    public let spo2: [SpO2Raw]
    public let skinTemp: [RawScalar]
    public let respiration: [RawScalar]
    public let steps: [Step]
    public let gravity: [Gravity]
    public let sleepState: [SleepState]
    public let ppgHr: [PpgHR]
    public let ppgWaveform: [PpgWaveform]

    public init(
        hr: [HR] = [],
        rr: [RR] = [],
        events: [Event] = [],
        battery: [Battery] = [],
        spo2: [SpO2Raw] = [],
        skinTemp: [RawScalar] = [],
        respiration: [RawScalar] = [],
        steps: [Step] = [],
        gravity: [Gravity] = [],
        sleepState: [SleepState] = [],
        ppgHr: [PpgHR] = [],
        ppgWaveform: [PpgWaveform] = []
    ) {
        self.hr = hr; self.rr = rr; self.events = events; self.battery = battery
        self.spo2 = spo2; self.skinTemp = skinTemp; self.respiration = respiration
        self.steps = steps; self.gravity = gravity; self.sleepState = sleepState
        self.ppgHr = ppgHr; self.ppgWaveform = ppgWaveform
    }

    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && events.isEmpty && battery.isEmpty && spo2.isEmpty &&
            skinTemp.isEmpty && respiration.isEmpty && steps.isEmpty && gravity.isEmpty &&
            sleepState.isEmpty && ppgHr.isEmpty && ppgWaveform.isEmpty
    }

    public var count: Int {
        hr.count + rr.count + events.count + battery.count + spo2.count +
            skinTemp.count + respiration.count + steps.count + gravity.count + sleepState.count +
            ppgHr.count + ppgWaveform.count
    }
}

public struct RemoteSyncPruneResult: Sendable, Equatable {
    public let deletedRows: Int
    public let hasMoreEligibleRows: Bool

    public init(deletedRows: Int, hasMoreEligibleRows: Bool) {
        self.deletedRows = deletedRows
        self.hasMoreEligibleRows = hasMoreEligibleRows
    }
}

extension WhoopStore {
    private static let remoteSyncPendingIndexDefinitions: [
        (name: String, table: String, columns: String)
    ] = [
        ("idx_remoteSync_hr_pending", "hrSample", "deviceId, ts"),
        ("idx_remoteSync_rr_pending", "rrInterval", "deviceId, ts, rrMs, seq"),
        ("idx_remoteSync_event_pending", "event", "deviceId, ts, kind"),
        ("idx_remoteSync_battery_pending", "battery", "deviceId, ts"),
        ("idx_remoteSync_spo2_pending", "spo2Sample", "deviceId, ts"),
        ("idx_remoteSync_skin_pending", "skinTempSample", "deviceId, ts"),
        ("idx_remoteSync_resp_pending", "respSample", "deviceId, ts"),
        ("idx_remoteSync_steps_pending", "stepSample", "deviceId, ts"),
        ("idx_remoteSync_gravity_pending", "gravitySample", "deviceId, ts"),
        ("idx_remoteSync_sleep_state_pending", "sleepStateSample", "deviceId, ts"),
        ("idx_remoteSync_ppg_hr_pending", "ppgHrSample", "deviceId, ts"),
        ("idx_remoteSync_ppg_waveform_pending", "ppgWaveformSample", "deviceId, ts"),
    ]

    /// Install or remove the optional upload-outbox indexes. They are valuable only while a
    /// self-hosted destination is configured; local score and export reads use each table's primary key.
    public func configureRemoteSyncPendingIndexes(enabled: Bool) async throws {
        try syncWrite { db in
            for definition in Self.remoteSyncPendingIndexDefinitions {
                if enabled {
                    try db.execute(sql: """
                        CREATE INDEX IF NOT EXISTS \(definition.name)
                        ON \(definition.table)(\(definition.columns))
                        WHERE synced = 0
                        """)
                } else {
                    try db.execute(sql: "DROP INDEX IF EXISTS \(definition.name)")
                }
            }
        }
    }

    /// Oldest pending rows per stream. A per-stream limit prevents dense HR from starving sparse
    /// battery/events, while keeping a request bounded for background URLSession work.
    public func pendingRemoteSyncStreams(
        deviceId: String,
        limitPerStream: Int = 5_000
    ) async throws -> PendingRemoteSyncStreams {
        try await configureRemoteSyncPendingIndexes(enabled: true)
        let limit = max(1, min(limitPerStream, 25_000))
        return try syncRead { db in
            let hr = try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.HR(ts: $0["ts"], bpm: $0["bpm"])
                }
            let rr = try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, seq FROM rrInterval
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC, rrMs ASC, seq ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.RR(ts: $0["ts"], rrMs: $0["rrMs"], seq: $0["seq"])
                }
            let events = try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.Event(
                        ts: $0["ts"], kind: $0["kind"], payloadJSON: $0["payloadJSON"]
                    )
                }
            let battery = try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv, charging FROM battery
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    let chargingInt: Int? = $0["charging"]
                    return PendingRemoteSyncStreams.Battery(
                        ts: $0["ts"], stateOfCharge: $0["soc"], millivolts: $0["mv"],
                        charging: chargingInt.map { $0 != 0 }
                    )
                }
            let spo2 = try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.SpO2Raw(
                        ts: $0["ts"], red: $0["red"], infrared: $0["ir"]
                    )
                }
            let skinTemp = try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM skinTempSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.RawScalar(ts: $0["ts"], raw: $0["raw"])
                }
            let respiration = try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.RawScalar(ts: $0["ts"], raw: $0["raw"])
                }
            let steps = try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.Step(
                        ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]
                    )
                }
            let gravity = try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z FROM gravitySample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.Gravity(
                        ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]
                    )
                }
            let sleepState = try Row.fetchAll(db, sql: """
                SELECT ts, state FROM sleepStateSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.SleepState(ts: $0["ts"], state: $0["state"])
                }
            let ppgHr = try Row.fetchAll(db, sql: """
                SELECT ts, bpm, conf FROM ppgHrSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.PpgHR(
                        ts: $0["ts"], bpm: $0["bpm"], confidence: $0["conf"]
                    )
                }
            let ppgWaveform = try Row.fetchAll(db, sql: """
                SELECT ts, samples FROM ppgWaveformSample
                WHERE deviceId = ? AND synced = 0 ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit]).map {
                    PendingRemoteSyncStreams.PpgWaveform(
                        ts: $0["ts"], samples: $0["samples"]
                    )
                }
            return PendingRemoteSyncStreams(
                hr: hr, rr: rr, events: events, battery: battery, spo2: spo2,
                skinTemp: skinTemp, respiration: respiration, steps: steps,
                gravity: gravity, sleepState: sleepState, ppgHr: ppgHr,
                ppgWaveform: ppgWaveform
            )
        }
    }

    /// Acknowledge exactly one previously-read snapshot. Call this only after the server accepts
    /// the corresponding idempotent batch. Rows inserted concurrently remain pending.
    public func markRemoteSyncStreamsSynced(
        _ pending: PendingRemoteSyncStreams,
        deviceId: String
    ) async throws {
        guard !pending.isEmpty else { return }
        try syncWrite { db in
            let hr = try db.cachedStatement(sql:
                "UPDATE hrSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.hr { try hr.execute(arguments: [deviceId, row.ts]) }

            let rr = try db.cachedStatement(sql: """
                UPDATE rrInterval SET synced = 1
                WHERE deviceId = ? AND ts = ? AND rrMs = ? AND seq = ?
                """)
            for row in pending.rr {
                try rr.execute(arguments: [deviceId, row.ts, row.rrMs, row.seq])
            }

            let event = try db.cachedStatement(sql: """
                UPDATE event SET synced = 1 WHERE deviceId = ? AND ts = ? AND kind = ?
                """)
            for row in pending.events {
                try event.execute(arguments: [deviceId, row.ts, row.kind])
            }

            let battery = try db.cachedStatement(sql:
                "UPDATE battery SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.battery { try battery.execute(arguments: [deviceId, row.ts]) }

            let spo2 = try db.cachedStatement(sql:
                "UPDATE spo2Sample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.spo2 { try spo2.execute(arguments: [deviceId, row.ts]) }

            let skin = try db.cachedStatement(sql:
                "UPDATE skinTempSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.skinTemp { try skin.execute(arguments: [deviceId, row.ts]) }

            let resp = try db.cachedStatement(sql:
                "UPDATE respSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.respiration { try resp.execute(arguments: [deviceId, row.ts]) }

            let steps = try db.cachedStatement(sql:
                "UPDATE stepSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.steps { try steps.execute(arguments: [deviceId, row.ts]) }

            let gravity = try db.cachedStatement(sql:
                "UPDATE gravitySample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.gravity { try gravity.execute(arguments: [deviceId, row.ts]) }

            let sleepState = try db.cachedStatement(sql:
                "UPDATE sleepStateSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.sleepState {
                try sleepState.execute(arguments: [deviceId, row.ts])
            }

            let ppgHr = try db.cachedStatement(sql:
                "UPDATE ppgHrSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.ppgHr { try ppgHr.execute(arguments: [deviceId, row.ts]) }

            let ppgWaveform = try db.cachedStatement(sql:
                "UPDATE ppgWaveformSample SET synced = 1 WHERE deviceId = ? AND ts = ?")
            for row in pending.ppgWaveform {
                try ppgWaveform.execute(arguments: [deviceId, row.ts])
            }
        }
    }

    /// Make every decoded row pending again. Used when the user points Noop at a different server
    /// or explicitly requests a complete replay; the destination's natural-key upserts absorb repeats.
    public func resetRemoteSyncState(deviceId: String) async throws {
        try syncWrite { db in
            for table in [
                "hrSample", "rrInterval", "event", "battery", "spo2Sample",
                "skinTempSample", "respSample", "stepSample", "gravitySample",
                "sleepStateSample", "ppgHrSample", "ppgWaveformSample",
            ] {
                try db.execute(
                    sql: "UPDATE \(table) SET synced = 0 WHERE deviceId = ?",
                    arguments: [deviceId]
                )
            }
        }
    }

    /// Remove only old rows already acknowledged by the configured server. Derived daily, sleep,
    /// workout and journal records are outside this list and remain local. Bounded per-table deletes
    /// keep BLE persistence responsive while a large pre-existing history is gradually compacted.
    public func pruneAcknowledgedRemoteRows(
        deviceId: String,
        olderThan cutoff: Int,
        limitPerStream: Int = 2_000
    ) async throws -> RemoteSyncPruneResult {
        let limit = max(100, min(limitPerStream, 5_000))
        let tables = [
            "hrSample", "rrInterval", "event", "battery", "spo2Sample",
            "skinTempSample", "respSample", "stepSample", "gravitySample",
            "sleepStateSample", "ppgHrSample", "ppgWaveformSample",
        ]
        return try syncWrite { db in
            var deleted = 0
            for table in tables {
                try db.execute(sql: """
                    DELETE FROM \(table)
                    WHERE rowid IN (
                        SELECT rowid FROM \(table)
                        WHERE deviceId = ? AND synced = 1 AND ts < ?
                        ORDER BY ts ASC
                        LIMIT ?
                    )
                    """, arguments: [deviceId, cutoff, limit])
                deleted += db.changesCount
            }
            var hasMore = false
            for table in tables where !hasMore {
                hasMore = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM \(table)
                        WHERE deviceId = ? AND synced = 1 AND ts < ?
                        LIMIT 1
                    )
                    """, arguments: [deviceId, cutoff]) ?? false
            }
            return RemoteSyncPruneResult(
                deletedRows: deleted,
                hasMoreEligibleRows: hasMore
            )
        }
    }
}
