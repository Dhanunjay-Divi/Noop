import Foundation
import GRDB

// MARK: - v9 cache: generic long-format metric store
// The substrate for a metric explorer. Where MetricsCache / JournalWorkoutAppleCache use a
// WIDE column-per-metric layout (one table per source, typed nullable columns), this is the
// TALL/EAV counterpart: one row per (deviceId, day, key) with a single REAL `value`. Any scalar
// metric — whatever its origin — can be projected into this one table and read back uniformly by
// key, so the explorer can list/compare metrics without knowing each source's schema.
// Mirrors the established pattern exactly: Codable struct, idempotent ON CONFLICT upsert keyed by
// natural key, range-read accessors, all GRDB work via the actor's syncWrite/syncRead helpers.

/// One point in the long-format metric store. Natural key (deviceId, day, key).
public struct MetricPoint: Equatable, Codable, Sendable {
    public let day: String           // YYYY-MM-DD
    public let key: String           // metric identifier, e.g. "restingHr", "steps", "recovery"
    public let value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

/// One metric-series point with its source partition retained. Used by day-level summary surfaces that
/// need every recorded scalar for one date without issuing one query per metric key.
public struct SourcedMetricPoint: Equatable, Codable, Sendable {
    public let deviceId: String
    public let day: String
    public let key: String
    public let value: Double

    public init(deviceId: String, day: String, key: String, value: Double) {
        self.deviceId = deviceId
        self.day = day
        self.key = key
        self.value = value
    }
}

extension WhoopStore {

    // MARK: - Upsert (idempotent by natural key; latest value wins on conflict)

    /// Upsert metric points. Natural key (deviceId, day, key). Returns rows changed.
    /// Idempotent: re-upserting the same (deviceId, day, key) updates `value` in place rather than
    /// creating a duplicate.
    @discardableResult
    public func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                guard let value = Self.normalizedMetricSeriesValue(r.value, forKey: r.key) else {
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO metricSeries
                        (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    """, arguments: [deviceId, r.day, r.key, value])
                n += db.changesCount
            }
            return n
        }
    }

    /// Atomically replace importer-owned metric keys inside one inclusive day range.
    ///
    /// A plain upsert cannot remove a value that disappeared from a later export. Importers call this
    /// with the complete key set they own for the represented range, so absent values are deleted rather
    /// than surviving as stale readings. Other devices, keys, and days remain untouched.
    @discardableResult
    public func replaceMetricSeriesRange(
        _ rows: [MetricPoint],
        deviceId: String,
        from: String,
        to: String,
        managedKeys: Set<String>
    ) async throws -> Int {
        let keys = managedKeys.filter { !$0.isEmpty }.sorted()
        guard from <= to, !keys.isEmpty else { return 0 }
        let allowedKeys = Set(keys)

        return try syncWrite { db in
            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
            try db.execute(
                sql: """
                    DELETE FROM metricSeries
                    WHERE deviceId = ? AND day >= ? AND day <= ?
                      AND key IN (\(placeholders))
                    """,
                arguments: StatementArguments([deviceId, from, to] + keys)
            )
            var changed = db.changesCount

            for row in rows where row.day >= from && row.day <= to && allowedKeys.contains(row.key) {
                guard let value = Self.normalizedMetricSeriesValue(row.value, forKey: row.key) else {
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO metricSeries
                        (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    """, arguments: [deviceId, row.day, row.key, value])
                changed += db.changesCount
            }
            return changed
        }
    }

    /// `sleep_efficiency` is stored as a 0...1 fraction. Older wearable-import code projected the
    /// export's 0...100 percentage into this generic series unchanged, even though the wide sleep
    /// tables were normalized correctly. Enforce the contract at the shared persistence boundary so
    /// every current writer is safe; invalid values are omitted rather than clamped into fabricated
    /// health data.
    static func normalizedMetricSeriesValue(_ value: Double, forKey key: String) -> Double? {
        guard value.isFinite else { return nil }
        guard key == "sleep_efficiency" else { return value }
        guard value >= 0, value <= 100 else { return nil }
        return value <= 1 ? value : value / 100.0
    }

    // MARK: - Reads

    /// Points for a single `key` on days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first. Served index-only by idx_metricSeries_device_key_day.
    public func metricSeries(deviceId: String, key: String, from: String, to: String) async throws -> [MetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, key, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// Every scalar recorded on one exact local day, with source retained. The natural-key index keeps
    /// this bounded to one daily slice even when the database contains years of metric history.
    public func metricSeries(day: String) async throws -> [SourcedMetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT deviceId, day, key, value FROM metricSeries
                WHERE day = ?
                ORDER BY deviceId ASC, key ASC
                """, arguments: [day])
                .compactMap {
                    let key: String = $0["key"]
                    let stored: Double = $0["value"]
                    guard let value = Self.normalizedMetricSeriesValue(stored, forKey: key) else {
                        return nil
                    }
                    return SourcedMetricPoint(
                        deviceId: $0["deviceId"],
                        day: $0["day"],
                        key: key,
                        value: value
                    )
                }
        }
    }

    /// Distinct metric keys present for a device, sorted ascending.
    public func metricKeys(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM metricSeries
                WHERE deviceId = ?
                ORDER BY key ASC
                """, arguments: [deviceId])
        }
    }

    /// Earliest and latest day for a given metric `key`, or nil if the key has no points.
    public func metricDays(deviceId: String, key: String) async throws -> (earliest: String, latest: String)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT MIN(day) AS earliest, MAX(day) AS latest FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key]),
                let earliest: String = row["earliest"],
                let latest: String = row["latest"]
            else { return nil }
            return (earliest, latest)
        }
    }

    // MARK: - User-owned series deletion

    /// Physically delete one point identified by the metric-series natural key.
    ///
    /// Sensitive local series (for example a user-entered period start) must support a real delete
    /// rather than retaining a zero-valued tombstone that still reveals the original date.
    @discardableResult
    public func deleteMetricSeriesPoint(deviceId: String, day: String, key: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key])
            return db.changesCount
        }
    }

    /// Physically delete every point for one source/key pair after explicit user confirmation.
    @discardableResult
    public func deleteMetricSeries(deviceId: String, key: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key])
            return db.changesCount
        }
    }
}
