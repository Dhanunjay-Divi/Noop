import Foundation
import GRDB

/// One editable, user-authored drink. The daily metric projection and these rows are replaced in one
/// SQLite transaction so a process interruption can never leave the visible total and edit list apart.
public struct HydrationLogEntry: Equatable, Codable, Sendable {
    public let id: String
    public let day: String
    public let amountML: Int
    public let loggedAt: Int

    public init(id: String, day: String, amountML: Int, loggedAt: Int) {
        self.id = id
        self.day = day
        self.amountML = amountML
        self.loggedAt = loggedAt
    }
}

enum HydrationEntryStoreError: Error {
    case invalidEntry
    case injectedFailure
}

extension WhoopStore {
    public func hydrationLogEntries(
        deviceId: String,
        day: String
    ) async throws -> [HydrationLogEntry] {
        try syncRead { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, day, amountML, loggedAt
                    FROM hydrationEntry
                    WHERE deviceId = ? AND day = ?
                    ORDER BY loggedAt ASC, id ASC
                    """,
                arguments: [deviceId, day]
            ).map {
                HydrationLogEntry(
                    id: $0["id"],
                    day: $0["day"],
                    amountML: $0["amountML"],
                    loggedAt: $0["loggedAt"]
                )
            }
        }
    }

    /// Atomically replaces a day's editable rows and its scalar projection. A zero total is retained as
    /// a canonical cleared-day row while the return value remains nil so UI does not invent intake.
    @discardableResult
    public func replaceHydrationLogEntries(
        _ entries: [HydrationLogEntry],
        deviceId: String,
        day: String,
        metricKey: String,
        failAfterMetricWriteForTesting: Bool = false
    ) async throws -> Double? {
        guard entries.allSatisfy({
            !$0.id.isEmpty && $0.day == day && $0.amountML > 0 && $0.loggedAt > 0
        }) else {
            throw HydrationEntryStoreError.invalidEntry
        }
        let total = entries.reduce(0.0) { $0 + Double($1.amountML) }

        return try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    """,
                arguments: [deviceId, day, metricKey, total]
            )
            #if DEBUG
            if failAfterMetricWriteForTesting {
                throw HydrationEntryStoreError.injectedFailure
            }
            #endif
            try db.execute(
                sql: "DELETE FROM hydrationEntry WHERE deviceId = ? AND day = ?",
                arguments: [deviceId, day]
            )
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO hydrationEntry
                            (id, deviceId, day, amountML, loggedAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.id,
                        deviceId,
                        entry.day,
                        entry.amountML,
                        entry.loggedAt,
                    ]
                )
            }
            return total > 0 ? total : nil
        }
    }
}
