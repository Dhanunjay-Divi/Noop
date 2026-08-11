import Foundation
import GRDB

/// One precise external body measurement. `userID` preserves a standards-level user slot; nil means
/// the source did not send one. The store maps nil to its documented -1 sentinel so the natural key is
/// fully non-null and idempotent in SQLite.
public struct BodyMeasurementRow: Equatable, Codable, Sendable {
    public let measuredAt: Int
    public let receivedAt: Int
    public let weightKg: Double
    public let bmi: Double?
    public let heightCm: Double?
    public let userID: Int?
    public let unit: String
    public let source: String

    public init(measuredAt: Int,
                receivedAt: Int,
                weightKg: Double,
                bmi: Double?,
                heightCm: Double?,
                userID: Int?,
                unit: String,
                source: String) {
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.weightKg = weightKg
        self.bmi = bmi
        self.heightCm = heightCm
        self.userID = userID
        self.unit = unit
        self.source = source
    }
}

extension WhoopStore {
    /// Persist timestamped body readings under their physical/source device id. Replaying the same
    /// (device, measurement second, user slot) updates in place and never duplicates history.
    @discardableResult
    public func upsertBodyMeasurements(_ rows: [BodyMeasurementRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var changed = 0
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO bodyMeasurement
                        (deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm, userId, unit, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, measuredAt, userId) DO UPDATE SET
                        receivedAt = excluded.receivedAt,
                        weightKg = excluded.weightKg,
                        bmi = excluded.bmi,
                        heightCm = excluded.heightCm,
                        unit = excluded.unit,
                        source = excluded.source
                    WHERE excluded.receivedAt >= bodyMeasurement.receivedAt
                    """, arguments: [
                        deviceId, row.measuredAt, row.receivedAt, row.weightKg, row.bmi, row.heightCm,
                        row.userID ?? -1, row.unit, row.source,
                    ])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// Body measurements in [from, to], oldest first. `userID == nil` returns every user slot; a
    /// concrete id filters exactly that slot. Use -1 to request packets that omitted User ID.
    public func bodyMeasurements(deviceId: String, from: Int, to: Int,
                                 userID: Int? = nil) async throws -> [BodyMeasurementRow] {
        try syncRead { db in
            var arguments: StatementArguments = [deviceId, from, to]
            var userClause = ""
            if let userID {
                userClause = " AND userId = ?"
                arguments += [userID]
            }
            return try Row.fetchAll(db, sql: """
                SELECT measuredAt, receivedAt, weightKg, bmi, heightCm, userId, unit, source
                FROM bodyMeasurement
                WHERE deviceId = ? AND measuredAt >= ? AND measuredAt <= ?\(userClause)
                ORDER BY measuredAt ASC, userId ASC
                """, arguments: arguments).map(Self.decodeBodyMeasurement)
        }
    }

    public func latestBodyMeasurement(deviceId: String, userID: Int? = nil) async throws -> BodyMeasurementRow? {
        try syncRead { db in
            var arguments: StatementArguments = [deviceId]
            var userClause = ""
            if let userID {
                userClause = " AND userId = ?"
                arguments += [userID]
            }
            return try Row.fetchOne(db, sql: """
                SELECT measuredAt, receivedAt, weightKg, bmi, heightCm, userId, unit, source
                FROM bodyMeasurement
                WHERE deviceId = ?\(userClause)
                ORDER BY measuredAt DESC, receivedAt DESC
                LIMIT 1
                """, arguments: arguments).map(Self.decodeBodyMeasurement)
        }
    }

    private static func decodeBodyMeasurement(_ row: Row) -> BodyMeasurementRow {
        let storedUser: Int = row["userId"]
        return BodyMeasurementRow(
            measuredAt: row["measuredAt"],
            receivedAt: row["receivedAt"],
            weightKg: row["weightKg"],
            bmi: row["bmi"],
            heightCm: row["heightCm"],
            userID: storedUser == -1 ? nil : storedUser,
            unit: row["unit"],
            source: row["source"]
        )
    }
}
