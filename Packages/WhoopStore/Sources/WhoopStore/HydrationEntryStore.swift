import CryptoKit
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

/// One consistent SQLite view of a day's editable hydration rows and their scalar projection.
/// Callers that validate the projection against the rows must use this snapshot rather than issuing
/// two reads that a managed-sync write could commit between.
public struct HydrationLogSnapshot: Equatable, Sendable {
    public let entries: [HydrationLogEntry]
    public let scalarValue: Double?
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

    /// Legacy UserDefaults hydration was one day-scoped JSON array. Bounding its decoded row count keeps
    /// recovery work deterministic while preserving more than a full day of minimum-size UI logs.
    public static var hydrationLegacyMaximumEntryCount: Int { 512 }

    /// Matches the managed-document payload ceiling and rejects corrupted preference blobs before decode.
    public static var hydrationLegacyMaximumPayloadBytes: Int { 1_000_000 }

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
    var seenIDs = Set<UUID>()
    for entry in entries {
        guard let id = UUID(uuidString: entry.id),
              seenIDs.insert(id).inserted,
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

private func exactLegacyHydrationScalarML(_ value: Double?) throws -> Int? {
    guard let value else { return nil }
    guard value.isFinite,
          value >= 0,
          value <= Double(WhoopStore.hydrationLegacyMaximumML),
          value.rounded(.towardZero) == value,
          let amountML = Int(exactly: value) else {
        throw HydrationEntryStoreError.invalidEntry
    }
    return amountML
}

private func hydrationEntryDigest(_ entries: [HydrationLogEntry]) -> String {
    var payload = Data()
    let normalized = entries.sorted {
        ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
    }
    for entry in normalized {
        for value in [
            entry.id.lowercased(),
            entry.day,
            String(entry.amountML),
            String(entry.loggedAt),
        ] {
            let bytes = Data(value.utf8)
            payload.append(Data(String(bytes.count).utf8))
            payload.append(0x3A)
            payload.append(bytes)
            payload.append(0x0A)
        }
    }
    return SHA256.hash(data: payload)
        .map { String(format: "%02x", $0) }
        .joined()
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

private func fetchHydrationLogSnapshot(
    in db: Database,
    deviceId: String,
    day: String,
    metricKey: String,
    afterEntriesRead: (() -> Void)? = nil
) throws -> HydrationLogSnapshot {
    let entries = try fetchHydrationLogEntries(
        in: db,
        deviceId: deviceId,
        day: day
    )
    afterEntriesRead?()
    let scalarValue = try Double.fetchOne(
        db,
        sql: """
            SELECT value
            FROM metricSeries
            WHERE deviceId = ? AND day = ? AND key = ?
            """,
        arguments: [deviceId, day, metricKey]
    )
    return HydrationLogSnapshot(
        entries: entries,
        scalarValue: scalarValue
    )
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
            DELETE FROM hydrationLegacyResolution
            WHERE scope = ? AND day = ?
            """,
        arguments: [deviceId, day]
    )
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

    public func hydrationLogSnapshot(
        deviceId: String,
        day: String,
        metricKey: String
    ) async throws -> HydrationLogSnapshot {
        try syncRead { db in
            try fetchHydrationLogSnapshot(
                in: db,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey
            )
        }
    }

    #if DEBUG
    func hydrationLogSnapshotForTesting(
        deviceId: String,
        day: String,
        metricKey: String,
        afterEntriesRead: @escaping @Sendable () -> Void
    ) async throws -> HydrationLogSnapshot {
        try syncRead { db in
            try fetchHydrationLogSnapshot(
                in: db,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                afterEntriesRead: afterEntriesRead
            )
        }
    }
    #endif

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

    /// Atomically classifies and adopts retired global hydration rows. A signed-in managed profile
    /// cannot claim ownerless legacy data, and the profile cannot switch between the ownership check
    /// and the SQLite write because both happen in this transaction.
    public func adoptLegacyHydrationLogEntries(
        _ entries: [HydrationLogEntry],
        alternativeRetirementEntryIDs: [String] = [],
        deviceId: String,
        day: String,
        metricKey: String
    ) async throws -> ManagedHydrationLegacyDisposition {
        let totalML = try validatedHydrationTotal(
            entries,
            day: day,
            validation: .legacyCompatibility
        )
        guard !entries.isEmpty else {
            throw HydrationEntryStoreError.invalidEntry
        }

        return try syncWrite { db in
            let entryIDGroups = [entries.map(\.id)]
                + (
                    alternativeRetirementEntryIDs.isEmpty
                        ? []
                        : [alternativeRetirementEntryIDs]
                )
            let disposition = try Self.managedHydrationLegacyDisposition(
                db,
                entryIDGroups: entryIDGroups
            )
            guard disposition == .migrate else {
                return disposition
            }
            let existingScalar = try Double.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """,
                arguments: [deviceId, day, metricKey]
            )
            let scalarML = try exactLegacyHydrationScalarML(existingScalar)
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
                guard let scalarML else {
                    throw HydrationEntryStoreError.invalidEntry
                }
                if scalarML > totalML {
                    return .reconcileHigherScalar(totalML: scalarML)
                }
                guard scalarML == totalML else {
                    throw HydrationEntryStoreError.invalidEntry
                }
                return .migrate
            }

            if let scalarML, scalarML > totalML {
                return .reconcileHigherScalar(totalML: scalarML)
            }
            try writeHydrationLogEntries(
                entries,
                totalML: totalML,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                in: db
            )
            return .migrate
        }
    }

    /// Commits one explicit resolution for a retired scalar/UserDefaults mismatch. The caller supplies the
    /// original legacy rows and the chosen replacement. Both the current scalar and managed ownership state
    /// are revalidated inside this transaction so a stale screen, remote apply, or profile change cannot
    /// overwrite newer evidence. The legacy preference is removed by the app only after `.migrate`.
    public func resolveLegacyHydrationLogEntries(
        legacyEntries: [HydrationLogEntry],
        replacementEntries: [HydrationLogEntry],
        expectedScalarML: Int,
        deviceId: String,
        day: String,
        metricKey: String,
        failAfterMetricWriteForTesting: Bool = false
    ) async throws -> ManagedHydrationLegacyDisposition {
        let legacyTotalML = try validatedHydrationTotal(
            legacyEntries,
            day: day,
            validation: .legacyCompatibility
        )
        let replacementTotalML = try validatedHydrationTotal(
            replacementEntries,
            day: day,
            validation: .legacyCompatibility
        )
        let normalizedLegacy = legacyEntries.sorted {
            ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
        }
        let normalizedReplacement = replacementEntries.sorted {
            ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
        }
        let keepsExplicitList = normalizedReplacement == normalizedLegacy
        let keepsScalarTotal = replacementEntries.count == 1
            && replacementTotalML == expectedScalarML
        let legacyDigest = hydrationEntryDigest(normalizedLegacy)
        let replacementDigest = hydrationEntryDigest(normalizedReplacement)
        guard !legacyEntries.isEmpty,
              !replacementEntries.isEmpty,
              legacyEntries.count <= Self.hydrationLegacyMaximumEntryCount,
              replacementEntries.count <= Self.hydrationLegacyMaximumEntryCount,
              expectedScalarML > legacyTotalML,
              expectedScalarML <= Self.hydrationLegacyMaximumML,
              keepsExplicitList || keepsScalarTotal else {
            throw HydrationEntryStoreError.invalidEntry
        }

        return try syncWrite { db in
            let legacyIDs = normalizedLegacy.map(\.id)
            let legacyIDSet = Set(legacyIDs)
            let replacementOnlyIDs = normalizedReplacement
                .map(\.id)
                .filter { !legacyIDSet.contains($0) }
            let entryIDGroups = [legacyIDs]
                + (
                    replacementOnlyIDs.isEmpty
                        ? []
                        : [replacementOnlyIDs]
                )
            let disposition = try Self.managedHydrationLegacyDisposition(
                db,
                entryIDGroups: entryIDGroups
            )
            guard disposition == .migrate else {
                return disposition
            }
            let currentScalar = try Double.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """,
                arguments: [deviceId, day, metricKey]
            )
            let scalarML = try exactLegacyHydrationScalarML(currentScalar)
            let existing = try fetchHydrationLogEntries(
                in: db,
                deviceId: deviceId,
                day: day
            )
            if !existing.isEmpty {
                let normalizedExisting = existing.sorted {
                    ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id)
                }
                let evidence = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT legacyDigest, replacementDigest, expectedScalarML
                        FROM hydrationLegacyResolution
                        WHERE scope = ? AND day = ?
                        """,
                    arguments: [deviceId, day]
                )
                guard normalizedExisting == normalizedReplacement,
                      let scalarML,
                      scalarML == replacementTotalML,
                      evidence?["legacyDigest"] as String? == legacyDigest,
                      evidence?["replacementDigest"] as String?
                        == replacementDigest,
                      evidence?["expectedScalarML"] as Int?
                        == expectedScalarML else {
                    throw HydrationEntryStoreError.invalidEntry
                }
                return .migrate
            }

            guard scalarML == expectedScalarML else {
                throw HydrationEntryStoreError.invalidEntry
            }
            try writeHydrationLogEntries(
                replacementEntries,
                totalML: replacementTotalML,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                failAfterMetricWriteForTesting:
                    failAfterMetricWriteForTesting,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO hydrationLegacyResolution (
                        scope, day, legacyDigest, replacementDigest,
                        expectedScalarML
                    )
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(scope, day) DO UPDATE SET
                        legacyDigest = excluded.legacyDigest,
                        replacementDigest = excluded.replacementDigest,
                        expectedScalarML = excluded.expectedScalarML
                    """,
                arguments: [
                    deviceId,
                    day,
                    legacyDigest,
                    replacementDigest,
                    expectedScalarML,
                ]
            )
            return .migrate
        }
    }

    /// Commits an explicit retired empty-list clear only after the same managed-profile and tombstone
    /// classification used by non-empty legacy rows. The scalar and absence of canonical rows are
    /// revalidated in the write transaction so an ownerless preference cannot clear a signed-in profile.
    public func clearLegacyHydrationLogEntries(
        retirementEntryID: String,
        expectedScalarML: Int?,
        deviceId: String,
        day: String,
        metricKey: String
    ) async throws -> ManagedHydrationLegacyDisposition {
        guard let retirementID = UUID(uuidString: retirementEntryID),
              expectedScalarML.map({
                  (0...Self.hydrationLegacyMaximumML).contains($0)
              }) ?? true else {
            throw HydrationEntryStoreError.invalidEntry
        }

        return try syncWrite { db in
            let disposition = try Self.managedHydrationLegacyDisposition(
                db,
                entryIDGroups: [[retirementID.uuidString.lowercased()]]
            )
            switch disposition {
            case .migrate, .retire:
                break
            case .deferForProfileConflict, .deferForMixedDeletionState:
                return disposition
            case .reconcileHigherScalar:
                throw HydrationEntryStoreError.invalidEntry
            }

            let currentScalar = try Double.fetchOne(
                db,
                sql: """
                    SELECT value
                    FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """,
                arguments: [deviceId, day, metricKey]
            )
            guard try exactLegacyHydrationScalarML(currentScalar)
                    == expectedScalarML,
                  try fetchHydrationLogEntries(
                      in: db,
                      deviceId: deviceId,
                      day: day
                  ).isEmpty else {
                throw HydrationEntryStoreError.invalidEntry
            }
            try writeHydrationLogEntries(
                [],
                totalML: 0,
                deviceId: deviceId,
                day: day,
                metricKey: metricKey,
                in: db
            )
            return disposition
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
        totalML: Double,
        suppressManagedDocumentDirtyForTesting: Bool = false
    ) async throws {
        try syncWrite { db in
            if suppressManagedDocumentDirtyForTesting {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO managedDocumentApplyGuard (guardId)
                        VALUES (1)
                        """
                )
            }
            defer {
                if suppressManagedDocumentDirtyForTesting {
                    try? db.execute(
                        sql: """
                            DELETE FROM managedDocumentApplyGuard
                            WHERE guardId = 1
                            """
                    )
                }
            }
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
