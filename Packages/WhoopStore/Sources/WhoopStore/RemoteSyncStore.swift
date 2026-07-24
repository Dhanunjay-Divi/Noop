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

    public let hr: [HR]
    public let rr: [RR]
    public let events: [Event]
    public let battery: [Battery]
    public let spo2: [SpO2Raw]
    public let skinTemp: [RawScalar]
    public let respiration: [RawScalar]
    public let steps: [Step]

    public init(
        hr: [HR] = [],
        rr: [RR] = [],
        events: [Event] = [],
        battery: [Battery] = [],
        spo2: [SpO2Raw] = [],
        skinTemp: [RawScalar] = [],
        respiration: [RawScalar] = [],
        steps: [Step] = []
    ) {
        self.hr = hr; self.rr = rr; self.events = events; self.battery = battery
        self.spo2 = spo2; self.skinTemp = skinTemp; self.respiration = respiration
        self.steps = steps
    }

    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && events.isEmpty && battery.isEmpty && spo2.isEmpty &&
            skinTemp.isEmpty && respiration.isEmpty && steps.isEmpty
    }

    public var count: Int {
        hr.count + rr.count + events.count + battery.count + spo2.count +
            skinTemp.count + respiration.count + steps.count
    }
}

extension WhoopStore {
    /// Oldest pending rows per stream. A per-stream limit prevents dense HR from starving sparse
    /// battery/events, while keeping a request bounded for background URLSession work.
    public func pendingRemoteSyncStreams(
        deviceId: String,
        limitPerStream: Int = 5_000
    ) async throws -> PendingRemoteSyncStreams {
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
            return PendingRemoteSyncStreams(
                hr: hr, rr: rr, events: events, battery: battery, spo2: spo2,
                skinTemp: skinTemp, respiration: respiration, steps: steps
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
        }
    }

    /// Make every decoded row pending again. Used when the user points Noop at a different server
    /// or explicitly requests a complete replay; the destination's natural-key upserts absorb repeats.
    public func resetRemoteSyncState(deviceId: String) async throws {
        try syncWrite { db in
            for table in [
                "hrSample", "rrInterval", "event", "battery", "spo2Sample",
                "skinTempSample", "respSample", "stepSample",
            ] {
                try db.execute(
                    sql: "UPDATE \(table) SET synced = 0 WHERE deviceId = ?",
                    arguments: [deviceId]
                )
            }
        }
    }
}
