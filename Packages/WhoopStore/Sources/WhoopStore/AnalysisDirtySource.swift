import Foundation
import GRDB

/// Durable non-biometric invalidations that require ownership-aware rescoring.
///
/// This source never represents a band or imported health source. It is always included in the
/// analysis gate so active-device, archive, and explicit day-owner changes cannot leave persisted
/// scores attributed to an obsolete source.
public enum AnalysisInputSource {
    public static let ownership = "noop.internal.analysis.ownership"
}

enum AnalysisOwnershipInvalidation {
    static func mark(
        _ db: Database,
        affectedRange explicitRange: ClosedRange<Int64>? = nil
    ) throws {
        let affectedRange = explicitRange ?? inputRange(db)
        let earliest = affectedRange?.lowerBound
        let latest = affectedRange?.upperBound
        try db.execute(
            sql: """
                INSERT INTO analysisDirtySource (
                    deviceId, generation, acknowledgedGeneration,
                    earliestAffectedTs, latestAffectedTs
                ) VALUES (?, 1, 0, ?, ?)
                ON CONFLICT(deviceId) DO UPDATE SET
                    generation = analysisDirtySource.generation + 1,
                    earliestAffectedTs = CASE
                        WHEN excluded.earliestAffectedTs IS NULL
                            THEN analysisDirtySource.earliestAffectedTs
                        WHEN analysisDirtySource.earliestAffectedTs IS NULL
                            THEN excluded.earliestAffectedTs
                        ELSE MIN(
                            analysisDirtySource.earliestAffectedTs,
                            excluded.earliestAffectedTs
                        )
                    END,
                    latestAffectedTs = CASE
                        WHEN excluded.latestAffectedTs IS NULL
                            THEN analysisDirtySource.latestAffectedTs
                        WHEN analysisDirtySource.latestAffectedTs IS NULL
                            THEN excluded.latestAffectedTs
                        ELSE MAX(
                            analysisDirtySource.latestAffectedTs,
                            excluded.latestAffectedTs
                        )
                    END
                """,
            arguments: [
                AnalysisInputSource.ownership,
                earliest,
                latest,
            ]
        )
    }

    static func dayRange(_ day: String) -> ClosedRange<Int64>? {
        guard day.count == 10 else { return nil }
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let dayOfMonth = Int(pieces[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: dayOfMonth,
            hour: 12
        )
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == dayOfMonth else {
            return nil
        }
        let timestamp = Int64(date.timeIntervalSince1970.rounded(.down))
        return timestamp...timestamp
    }

    private static func inputRange(_ db: Database) -> ClosedRange<Int64>? {
        let union = WhoopStore.analysisDirtySourceTables
            .map { #"SELECT ts FROM "\#($0)""# }
            .joined(separator: " UNION ALL ")
        guard let row = try? Row.fetchOne(
            db,
            sql: "SELECT MIN(ts) AS earliest, MAX(ts) AS latest FROM (\(union))"
        ),
        let earliest: Int64 = row["earliest"],
        let latest: Int64 = row["latest"],
        earliest >= 0,
        latest >= earliest else {
            return nil
        }
        return earliest...latest
    }
}

/// One durable scoring-input generation observed by an analysis pass.
///
/// The claim is only a snapshot. Reading it does not mutate store state, so process death before
/// acknowledgement leaves the source pending. A later score-bearing write advances the stored generation;
/// acknowledging this older claim then advances only `acknowledgedGeneration`, leaving the newer write dirty.
public struct AnalysisInputGenerationClaim: Equatable, Sendable {
    public let deviceId: String
    public let generation: Int64
    public let earliestAffectedTs: Int64?
    public let latestAffectedTs: Int64?

    public init(
        deviceId: String,
        generation: Int64,
        earliestAffectedTs: Int64? = nil,
        latestAffectedTs: Int64? = nil
    ) {
        self.deviceId = deviceId
        self.generation = generation
        self.earliestAffectedTs = earliestAffectedTs
        self.latestAffectedTs = latestAffectedTs
    }

    /// Structurally valid affected-time bounds. Missing, negative, or reversed bounds fail closed and must
    /// not be acknowledged by a bounded analysis pass.
    public var affectedTimeRange: ClosedRange<Int64>? {
        guard let earliestAffectedTs,
              let latestAffectedTs,
              earliestAffectedTs >= 0,
              latestAffectedTs >= earliestAffectedTs else {
            return nil
        }
        return earliestAffectedTs...latestAffectedTs
    }
}

public struct AnalysisInputFinalizationResult: Equatable, Sendable {
    public let acknowledgedCount: Int
    public let advancedCount: Int

    public init(acknowledgedCount: Int, advancedCount: Int) {
        self.acknowledgedCount = acknowledgedCount
        self.advancedCount = advancedCount
    }
}

extension WhoopStore {
    /// Snapshots pending analysis generations for the requested sources without clearing or leasing them.
    ///
    /// The source set is expected to be small (paired/read owners), so this is O(source count) primary-key
    /// work rather than O(history size). Repeated snapshots return the same claim until a successful pass
    /// acknowledges it.
    public func pendingAnalysisInputGenerations(
        deviceIds: [String]
    ) async throws -> [AnalysisInputGenerationClaim] {
        let ids = Self.normalizedAnalysisSourceIds(deviceIds)
        guard !ids.isEmpty else { return [] }

        return try syncRead { db in
            var claims: [AnalysisInputGenerationClaim] = []
            claims.reserveCapacity(ids.count)
            for id in ids {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT generation, earliestAffectedTs, latestAffectedTs
                        FROM analysisDirtySource
                        WHERE deviceId = ?
                          AND generation > acknowledgedGeneration
                        """,
                    arguments: [id]
                ) else { continue }
                claims.append(.init(
                    deviceId: id,
                    generation: row["generation"],
                    earliestAffectedTs: row["earliestAffectedTs"],
                    latestAffectedTs: row["latestAffectedTs"]
                ))
            }
            return claims
        }
    }

    /// Acknowledges exactly the generations completed by one fully successful analysis pass.
    ///
    /// A concurrent write can advance `generation` after the snapshot. This update still acknowledges the
    /// claimed prefix while preserving `generation > acknowledgedGeneration`, so the later write remains
    /// pending. Missing rows are benign: explicit source/account deletion removes marker state.
    public func acknowledgeAnalysisInputGenerations(
        _ claims: [AnalysisInputGenerationClaim]
    ) async throws {
        let normalized = Dictionary(
            grouping: claims.filter {
                $0.generation > 0
                    && !$0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            by: \.deviceId
        ).compactMap { deviceId, values -> AnalysisInputGenerationClaim? in
            guard let generation = values.map(\.generation).max() else { return nil }
            return .init(deviceId: deviceId, generation: generation)
        }.sorted { $0.deviceId < $1.deviceId }
        guard !normalized.isEmpty else { return }

        try Task.checkCancellation()
        try syncWrite { db in
            let acknowledge = try db.cachedStatement(sql: """
                UPDATE analysisDirtySource
                SET acknowledgedGeneration = ?,
                    earliestAffectedTs = CASE
                        WHEN generation = ? THEN NULL ELSE earliestAffectedTs
                    END,
                    latestAffectedTs = CASE
                        WHEN generation = ? THEN NULL ELSE latestAffectedTs
                    END
                WHERE deviceId = ?
                  AND generation >= ?
                  AND acknowledgedGeneration < ?
                """)
            for claim in normalized {
                try Task.checkCancellation()
                try acknowledge.execute(arguments: [
                    claim.generation,
                    claim.generation,
                    claim.generation,
                    claim.deviceId,
                    claim.generation,
                    claim.generation,
                ])
            }
            try Task.checkCancellation()
        }
    }

    /// Finalizes one bounded scoring window.
    ///
    /// A fully covered claim is acknowledged with the existing prefix semantics. A partially covered
    /// newest tail keeps the same generation pending while moving only `latestAffectedTs` behind the
    /// completed window. Tail progress requires the exact generation and exact snapshotted bounds, so a
    /// concurrent score-bearing write cannot be trimmed or acknowledged by an older pass.
    public func finalizeAnalysisInputGenerations(
        _ claims: [AnalysisInputGenerationClaim],
        coverageStartTs: Int64,
        coverageEndTs: Int64
    ) async throws -> AnalysisInputFinalizationResult {
        guard coverageStartTs >= 0, coverageStartTs <= coverageEndTs else {
            return AnalysisInputFinalizationResult(
                acknowledgedCount: 0,
                advancedCount: 0
            )
        }
        var byDevice: [String: AnalysisInputGenerationClaim] = [:]
        for claim in claims {
            let deviceId = claim.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard claim.generation > 0, !deviceId.isEmpty else { continue }
            if let existing = byDevice[deviceId], existing.generation >= claim.generation {
                continue
            }
            byDevice[deviceId] = AnalysisInputGenerationClaim(
                deviceId: deviceId,
                generation: claim.generation,
                earliestAffectedTs: claim.earliestAffectedTs,
                latestAffectedTs: claim.latestAffectedTs
            )
        }
        let normalized = byDevice.values.sorted { $0.deviceId < $1.deviceId }
        guard !normalized.isEmpty else {
            return AnalysisInputFinalizationResult(
                acknowledgedCount: 0,
                advancedCount: 0
            )
        }

        try Task.checkCancellation()
        return try syncWrite { db in
            var acknowledgedCount = 0
            var advancedCount = 0
            let acknowledge = try db.cachedStatement(sql: """
                UPDATE analysisDirtySource
                SET acknowledgedGeneration = ?,
                    earliestAffectedTs = CASE
                        WHEN generation = ? THEN NULL ELSE earliestAffectedTs
                    END,
                    latestAffectedTs = CASE
                        WHEN generation = ? THEN NULL ELSE latestAffectedTs
                    END
                WHERE deviceId = ?
                  AND generation >= ?
                  AND acknowledgedGeneration < ?
                """)
            let advance = try db.cachedStatement(sql: """
                UPDATE analysisDirtySource
                SET latestAffectedTs = ?
                WHERE deviceId = ?
                  AND generation = ?
                  AND acknowledgedGeneration < ?
                  AND earliestAffectedTs = ?
                  AND latestAffectedTs = ?
                """)

            for claim in normalized {
                try Task.checkCancellation()
                guard let affected = claim.affectedTimeRange else { continue }
                if affected.lowerBound >= coverageStartTs
                    && affected.upperBound <= coverageEndTs {
                    try acknowledge.execute(arguments: [
                        claim.generation,
                        claim.generation,
                        claim.generation,
                        claim.deviceId,
                        claim.generation,
                        claim.generation,
                    ])
                    acknowledgedCount += db.changesCount
                    continue
                }

                guard coverageStartTs > affected.lowerBound,
                      coverageStartTs <= affected.upperBound,
                      coverageEndTs >= affected.upperBound else {
                    continue
                }
                let remainingLatest = coverageStartTs - 1
                try advance.execute(arguments: [
                    remainingLatest,
                    claim.deviceId,
                    claim.generation,
                    claim.generation,
                    affected.lowerBound,
                    affected.upperBound,
                ])
                advancedCount += db.changesCount
            }
            try Task.checkCancellation()
            return AnalysisInputFinalizationResult(
                acknowledgedCount: acknowledgedCount,
                advancedCount: advancedCount
            )
        }
    }

    /// Constant-table-count proof used only to clear malformed legacy claims that cannot describe a
    /// bounded scoring window. Passing nil checks the whole store (ownership invalidation); a source id
    /// checks that source only. Each query stops at its first row and never aggregates history.
    public func hasScoreBearingAnalysisHistory(
        deviceId: String? = nil
    ) async throws -> Bool {
        let normalizedDeviceId = deviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if deviceId != nil, normalizedDeviceId?.isEmpty != false {
            return false
        }
        return try syncRead { db in
            for table in Self.analysisDirtySourceTables {
                let row: Int?
                if let normalizedDeviceId {
                    row = try Int.fetchOne(
                        db,
                        sql: """
                            SELECT 1 FROM "\(table)"
                            WHERE deviceId = ?
                            LIMIT 1
                            """,
                        arguments: [normalizedDeviceId]
                    )
                } else {
                    row = try Int.fetchOne(
                        db,
                        sql: #"SELECT 1 FROM "\#(table)" LIMIT 1"#
                    )
                }
                if row == 1 { return true }
            }
            return false
        }
    }

    #if DEBUG
    /// Seeds a deliberately malformed or legacy claim for app-level fail-closed tests.
    public func seedAnalysisInputClaimForTesting(
        _ claim: AnalysisInputGenerationClaim,
        acknowledgedGeneration: Int64 = 0
    ) async throws {
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO analysisDirtySource (
                        deviceId, generation, acknowledgedGeneration,
                        earliestAffectedTs, latestAffectedTs
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId) DO UPDATE SET
                        generation = excluded.generation,
                        acknowledgedGeneration = excluded.acknowledgedGeneration,
                        earliestAffectedTs = excluded.earliestAffectedTs,
                        latestAffectedTs = excluded.latestAffectedTs
                    """,
                arguments: [
                    claim.deviceId,
                    claim.generation,
                    acknowledgedGeneration,
                    claim.earliestAffectedTs,
                    claim.latestAffectedTs,
                ]
            )
        }
    }
    #endif

    private static func normalizedAnalysisSourceIds(_ deviceIds: [String]) -> [String] {
        Array(Set(deviceIds.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })).sorted()
    }
}
