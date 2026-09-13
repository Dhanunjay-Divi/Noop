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
    /// Compatibility ceiling for retired scalar/UserDefaults hydration storage. This is intentionally
    /// much larger than the current 10 L write limit so an old day can be shown and reduced, while still
    /// rejecting corrupt integers before they reach SQLite or a lossy `Double` projection.
    public static var hydrationLegacyMaximumML: Int { 1_000_000 }

    /// Last accepted persisted hydration timestamp: 2100-12-31 23:59:59 UTC. Hydration rows are
    /// user-authored event times, so values beyond this compatibility window are corruption rather than
    /// meaningful future plans. The fixed ceiling keeps restore behavior deterministic across clock and
    /// timezone changes while preserving every supported historical row.
    public static var hydrationLatestCompatibleUnixSecond: Int { 4_133_980_799 }
}

private enum HydrationEntryLimits {
    static let maximumML = 10_000
    static let legacyMaximumML = WhoopStore.hydrationLegacyMaximumML
}

private enum HydrationEntryValidation: Equatable {
    case currentWrite
    case legacyCompatibility
}

private func validatedHydrationTotal(
    _ entries: [HydrationLogEntry],
    day: String,
    validation: HydrationEntryValidation
) throws -> Int {
    var totalML = 0
    for entry in entries {
        guard UUID(uuidString: entry.id) != nil,
              entry.day == day,
              entry.amountML > 0,
              entry.loggedAt > 0,
              entry.loggedAt <= WhoopStore.hydrationLatestCompatibleUnixSecond else {
            throw HydrationEntryStoreError.invalidEntry
        }
        let maximumML = validation == .currentWrite
            ? HydrationEntryLimits.maximumML
            : HydrationEntryLimits.legacyMaximumML
        if entry.amountML > maximumML {
            throw HydrationEntryStoreError.invalidEntry
        }
        let (nextTotal, overflow) = totalML.addingReportingOverflow(entry.amountML)
        guard !overflow else {
            throw HydrationEntryStoreError.invalidEntry
        }
        if nextTotal > maximumML {
            throw HydrationEntryStoreError.invalidEntry
        }
        totalML = nextTotal
    }
    return totalML
}

private func fetchHydrationLogEntries(
    in db: Database,
    deviceId: String,
    day: String
) throws -> [HydrationLogEntry] {
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

private func writeHydrationLogEntries(
    _ entries: [HydrationLogEntry],
    totalML: Int,
    deviceId: String,
    day: String,
    metricKey: String,
    failAfterMetricWriteForTesting: Bool = false,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO metricSeries (deviceId, day, key, value)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(deviceId, day, key) DO UPDATE SET
                value = excluded.value
            """,
        arguments: [deviceId, day, metricKey, Double(totalML)]
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
}

private func isStrictLegacyReduction(
    from current: [HydrationLogEntry],
    to replacement: [HydrationLogEntry]
) -> Bool {
    guard replacement.count <= current.count else { return false }
    let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    var changed = replacement.count < current.count

    for entry in replacement {
        guard let existing = currentByID[entry.id],
              entry.day == existing.day,
              entry.loggedAt == existing.loggedAt,
              entry.amountML <= existing.amountML else {
            return false
        }
        changed = changed || entry.amountML < existing.amountML
    }
    return changed
}

extension WhoopStore {
    public func hydrationLogEntries(
        deviceId: String,
        day: String
    ) async throws -> [HydrationLogEntry] {
        try syncRead { db in
            try fetchHydrationLogEntries(in: db, deviceId: deviceId, day: day)
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
        let totalML = try validatedHydrationTotal(
            entries,
            day: day,
            validation: .currentWrite
        )
        let total = Double(totalML)

        return try syncWrite { db in
            try writeHydrationLogEntries(
                entries,
                totalML: totalML,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                failAfterMetricWriteForTesting: failAfterMetricWriteForTesting,
                in: db
            )
            return total > 0 ? total : nil
        }
    }

    /// Moves rows created by the retired UserDefaults/scalar persistence into SQLite without applying
    /// limits that did not exist when those rows were authored. This path validates identity, day,
    /// positivity, timestamp, and integer overflow, and refuses to replace a different SQLite entry set.
    /// All user-initiated writes must continue through `replaceHydrationLogEntries`.
    @discardableResult
    public func migrateLegacyHydrationLogEntries(
        _ entries: [HydrationLogEntry],
        deviceId: String,
        day: String,
        metricKey: String
    ) async throws -> Double? {
        let totalML = try validatedHydrationTotal(
            entries,
            day: day,
            validation: .legacyCompatibility
        )
        guard !entries.isEmpty else {
            throw HydrationEntryStoreError.invalidEntry
        }
        let total = Double(totalML)

        return try syncWrite { db in
            let existing = try fetchHydrationLogEntries(
                in: db,
                deviceId: deviceId,
                day: day
            )
            if !existing.isEmpty {
                let normalizedExisting = existing.sorted {
                    ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
                }
                let normalizedIncoming = entries.sorted {
                    ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
                }
                guard normalizedExisting == normalizedIncoming else {
                    throw HydrationEntryStoreError.invalidEntry
                }
                return total
            }
            try writeHydrationLogEntries(
                entries,
                totalML: totalML,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                in: db
            )
            return total
        }
    }

    /// Applies a correction to an oversized legacy day. A replacement still above the current cap is
    /// accepted only when the persisted day is already oversized and every surviving row keeps its
    /// identity/timestamp while decreasing in amount; additions and increases remain rejected. Once the
    /// replacement reaches the current cap, the regular strict write path takes over.
    @discardableResult
    public func replaceHydrationLogEntriesAllowingLegacyReduction(
        _ entries: [HydrationLogEntry],
        deviceId: String,
        day: String,
        metricKey: String
    ) async throws -> Double? {
        let totalML = try validatedHydrationTotal(
            entries,
            day: day,
            validation: .legacyCompatibility
        )
        if totalML <= HydrationEntryLimits.maximumML {
            return try await replaceHydrationLogEntries(
                entries,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey
            )
        }
        let total = Double(totalML)

        return try syncWrite { db in
            let current = try fetchHydrationLogEntries(
                in: db,
                deviceId: deviceId,
                day: day
            )
            let currentTotalML = try validatedHydrationTotal(
                current,
                day: day,
                validation: .legacyCompatibility
            )
            guard currentTotalML > HydrationEntryLimits.maximumML,
                  totalML < currentTotalML,
                  isStrictLegacyReduction(from: current, to: entries) else {
                throw HydrationEntryStoreError.invalidEntry
            }
            try writeHydrationLogEntries(
                entries,
                totalML: totalML,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                in: db
            )
            return total
        }
    }

    #if DEBUG
    /// Seeds an intentionally unvalidated persistence state for corruption-path app tests.
    /// Production writes must continue through `replaceHydrationLogEntries`.
    public func seedHydrationPersistenceForTesting(
        _ entries: [HydrationLogEntry],
        deviceId: String,
        day: String,
        metricKey: String,
        totalML: Double
    ) async throws {
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    """,
                arguments: [deviceId, day, metricKey, totalML]
            )
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
        }
    }
    #endif
}
