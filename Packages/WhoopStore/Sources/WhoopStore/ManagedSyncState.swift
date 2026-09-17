import Foundation
import GRDB

/// Compact local identity for one immutable managed-storage source.
public struct ManagedSyncSourceState: Equatable, Sendable {
    public let sourceID: String
    public let localSourceID: String
    public let sourceKind: String
    public let platform: String
    public let logicalSourceHash: String
    public let createdAtMs: Int64
    public let updatedAtMs: Int64

    public init(
        sourceID: String,
        localSourceID: String,
        sourceKind: String,
        platform: String,
        logicalSourceHash: String,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ) {
        self.sourceID = sourceID
        self.localSourceID = localSourceID
        self.sourceKind = sourceKind
        self.platform = platform
        self.logicalSourceHash = logicalSourceHash
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }
}

/// Progress through fixed upload windows for one source and data class.
public struct ManagedSyncCheckpointState: Equatable, Sendable {
    public let accountScopeHash: String
    public let sourceID: String
    public let dataClass: String
    public let nextWindowStartMs: Int64?
    public let repairWindowStartMs: Int64?
    public let updatedAtMs: Int64

    public init(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String,
        nextWindowStartMs: Int64?,
        repairWindowStartMs: Int64?,
        updatedAtMs: Int64
    ) {
        self.accountScopeHash = accountScopeHash
        self.sourceID = sourceID
        self.dataClass = dataClass
        self.nextWindowStartMs = nextWindowStartMs
        self.repairWindowStartMs = repairWindowStartMs
        self.updatedAtMs = updatedAtMs
    }
}

/// Durable fixed-window snapshot state, including a receipt awaiting idempotent upload completion.
public struct ManagedWindowUploadState: Equatable, Sendable {
    public let accountScopeHash: String
    public let sourceID: String
    public let dataClass: String
    public let windowStartMs: Int64
    public let windowEndMs: Int64
    public let chunkID: String
    public let rowCount: Int
    public let phase: String
    public let objectGeneration: Int64?
    public let objectMetageneration: Int64?
    public let objectCRC32C: String?
    public let snapshotGeneration: Int64
    public let validatedAtMs: Int64?
    public let localPrunedAtMs: Int64?
    public let updatedAtMs: Int64

    public init(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: String,
        rowCount: Int,
        phase: String,
        objectGeneration: Int64?,
        objectMetageneration: Int64?,
        objectCRC32C: String?,
        updatedAtMs: Int64,
        snapshotGeneration: Int64 = 0,
        validatedAtMs: Int64? = nil,
        localPrunedAtMs: Int64? = nil
    ) {
        self.accountScopeHash = accountScopeHash
        self.sourceID = sourceID
        self.dataClass = dataClass
        self.windowStartMs = windowStartMs
        self.windowEndMs = windowEndMs
        self.chunkID = chunkID
        self.rowCount = rowCount
        self.phase = phase
        self.objectGeneration = objectGeneration
        self.objectMetageneration = objectMetageneration
        self.objectCRC32C = objectCRC32C
        self.snapshotGeneration = snapshotGeneration
        self.validatedAtMs = validatedAtMs
        self.localPrunedAtMs = localPrunedAtMs
        self.updatedAtMs = updatedAtMs
    }
}

/// One locally mutated fixed window. A claim is durable across process death and advances only when
/// the first subsequent mutation arrives, so high-frequency samples do not rewrite this row.
public struct ManagedDirtyWindowState: Equatable, Sendable {
    public let localSourceID: String
    public let dataClass: String
    public let windowStartMs: Int64
    public let windowEndMs: Int64
    public let generation: Int64
    public let claimedGeneration: Int64?
    public let updatedAtMs: Int64

    public init(
        localSourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        generation: Int64,
        claimedGeneration: Int64?,
        updatedAtMs: Int64
    ) {
        self.localSourceID = localSourceID
        self.dataClass = dataClass
        self.windowStartMs = windowStartMs
        self.windowEndMs = windowEndMs
        self.generation = generation
        self.claimedGeneration = claimedGeneration
        self.updatedAtMs = updatedAtMs
    }
}

public struct ManagedLocalPruneResult: Equatable, Sendable {
    public let prunedWindows: Int
    public let deletedRows: Int

    public init(prunedWindows: Int, deletedRows: Int) {
        self.prunedWindows = prunedWindows
        self.deletedRows = deletedRows
    }
}

/// Durable receipt for one account-wide change-feed item.
public struct ManagedAppliedChangeState: Equatable, Sendable {
    public let accountScopeHash: String
    public let sequence: Int64
    public let resourceKind: String
    public let resourceID: String
    public let contentSHA256: String?
    public let appliedAtMs: Int64

    public init(
        accountScopeHash: String,
        sequence: Int64,
        resourceKind: String,
        resourceID: String,
        contentSHA256: String?,
        appliedAtMs: Int64
    ) {
        self.accountScopeHash = accountScopeHash
        self.sequence = sequence
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.contentSHA256 = contentSHA256
        self.appliedAtMs = appliedAtMs
    }
}

public struct ManagedSnapshotRestoreState: Equatable, Sendable {
    public let accountScopeHash: String
    public let requestID: String
    public let dataClasses: [String]
    public let changeFeedCapabilityVersion: Int
    public let restoreJobID: String?
    public let snapshotAt: String?
    public let changeSequence: Int64?
    public let selectedObjects: Int?
    public let selectedBytes: Int64?
    public let dataClassIndex: Int
    public let afterEventStart: String?
    public let afterChunkID: String?
    public let afterDocumentUpdatedAt: String?
    public let afterDocumentKind: String?
    public let afterDocumentID: String?
    public let documentsComplete: Bool
    public let deliveredObjects: Int
    public let deliveredBytes: Int64
    public let updatedAtMs: Int64

    public init(
        accountScopeHash: String,
        requestID: String,
        dataClasses: [String],
        changeFeedCapabilityVersion: Int = 0,
        restoreJobID: String?,
        snapshotAt: String?,
        changeSequence: Int64?,
        selectedObjects: Int?,
        selectedBytes: Int64?,
        dataClassIndex: Int,
        afterEventStart: String?,
        afterChunkID: String?,
        afterDocumentUpdatedAt: String? = nil,
        afterDocumentKind: String? = nil,
        afterDocumentID: String? = nil,
        documentsComplete: Bool = false,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        updatedAtMs: Int64
    ) {
        self.accountScopeHash = accountScopeHash
        self.requestID = requestID
        self.dataClasses = dataClasses
        self.changeFeedCapabilityVersion = changeFeedCapabilityVersion
        self.restoreJobID = restoreJobID
        self.snapshotAt = snapshotAt
        self.changeSequence = changeSequence
        self.selectedObjects = selectedObjects
        self.selectedBytes = selectedBytes
        self.dataClassIndex = dataClassIndex
        self.afterEventStart = afterEventStart
        self.afterChunkID = afterChunkID
        self.afterDocumentUpdatedAt = afterDocumentUpdatedAt
        self.afterDocumentKind = afterDocumentKind
        self.afterDocumentID = afterDocumentID
        self.documentsComplete = documentsComplete
        self.deliveredObjects = deliveredObjects
        self.deliveredBytes = deliveredBytes
        self.updatedAtMs = updatedAtMs
    }
}

extension WhoopStore {
    public func upsertManagedSyncSource(_ source: ManagedSyncSourceState) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO managedSyncSource (
                    sourceId, localSourceId, sourceKind, platform, logicalSourceHash,
                    createdAtMs, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceId) DO UPDATE SET
                    localSourceId = excluded.localSourceId,
                    sourceKind = excluded.sourceKind,
                    platform = excluded.platform,
                    logicalSourceHash = excluded.logicalSourceHash,
                    updatedAtMs = excluded.updatedAtMs
                """, arguments: [
                    source.sourceID, source.localSourceID, source.sourceKind, source.platform,
                    source.logicalSourceHash, source.createdAtMs, source.updatedAtMs,
                ])
        }
    }

    public func managedSyncSource(localSourceID: String) async throws -> ManagedSyncSourceState? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT sourceId, localSourceId, sourceKind, platform, logicalSourceHash,
                           createdAtMs, updatedAtMs
                    FROM managedSyncSource
                    WHERE localSourceId = ?
                    ORDER BY updatedAtMs DESC, sourceId ASC
                    LIMIT 1
                    """,
                arguments: [localSourceID]
            ).map {
                ManagedSyncSourceState(
                    sourceID: $0["sourceId"],
                    localSourceID: $0["localSourceId"],
                    sourceKind: $0["sourceKind"],
                    platform: $0["platform"],
                    logicalSourceHash: $0["logicalSourceHash"],
                    createdAtMs: $0["createdAtMs"],
                    updatedAtMs: $0["updatedAtMs"]
                )
            }
        }
    }

    public func managedSyncCheckpoint(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String
    ) async throws -> ManagedSyncCheckpointState? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT accountScopeHash, sourceId, dataClass, nextWindowStartMs,
                           repairWindowStartMs, updatedAtMs
                    FROM managedSyncCheckpoint
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                    """,
                arguments: [accountScopeHash, sourceID, dataClass]
            ).map {
                ManagedSyncCheckpointState(
                    accountScopeHash: $0["accountScopeHash"],
                    sourceID: $0["sourceId"],
                    dataClass: $0["dataClass"],
                    nextWindowStartMs: $0["nextWindowStartMs"],
                    repairWindowStartMs: $0["repairWindowStartMs"],
                    updatedAtMs: $0["updatedAtMs"]
                )
            }
        }
    }

    public func saveManagedSyncCheckpoint(_ checkpoint: ManagedSyncCheckpointState) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO managedSyncCheckpoint (
                    accountScopeHash, sourceId, dataClass, nextWindowStartMs,
                    repairWindowStartMs, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(accountScopeHash, sourceId, dataClass) DO UPDATE SET
                    nextWindowStartMs = excluded.nextWindowStartMs,
                    repairWindowStartMs = excluded.repairWindowStartMs,
                    updatedAtMs = excluded.updatedAtMs
                """, arguments: [
                    checkpoint.accountScopeHash, checkpoint.sourceID, checkpoint.dataClass,
                    checkpoint.nextWindowStartMs, checkpoint.repairWindowStartMs,
                    checkpoint.updatedAtMs,
                ])
        }
    }

    public func managedWindowUpload(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String,
        windowStartMs: Int64
    ) async throws -> ManagedWindowUploadState? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT accountScopeHash, sourceId, dataClass, windowStartMs, windowEndMs,
                           chunkId, rowCount, phase, objectGeneration, objectMetageneration,
                           objectCRC32C, snapshotGeneration, validatedAtMs,
                           localPrunedAtMs, updatedAtMs
                    FROM managedWindowUpload
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                      AND windowStartMs = ?
                    """,
                arguments: [accountScopeHash, sourceID, dataClass, windowStartMs]
            ).map {
                ManagedWindowUploadState(
                    accountScopeHash: $0["accountScopeHash"],
                    sourceID: $0["sourceId"],
                    dataClass: $0["dataClass"],
                    windowStartMs: $0["windowStartMs"],
                    windowEndMs: $0["windowEndMs"],
                    chunkID: $0["chunkId"],
                    rowCount: $0["rowCount"],
                    phase: $0["phase"],
                    objectGeneration: $0["objectGeneration"],
                    objectMetageneration: $0["objectMetageneration"],
                    objectCRC32C: $0["objectCRC32C"],
                    updatedAtMs: $0["updatedAtMs"],
                    snapshotGeneration: $0["snapshotGeneration"],
                    validatedAtMs: $0["validatedAtMs"],
                    localPrunedAtMs: $0["localPrunedAtMs"]
                )
            }
        }
    }

    public func saveManagedWindowUpload(_ upload: ManagedWindowUploadState) async throws {
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO managedWindowUpload (
                        accountScopeHash, sourceId, dataClass, windowStartMs, windowEndMs,
                        chunkId, rowCount, phase, objectGeneration, objectMetageneration,
                        objectCRC32C, snapshotGeneration, validatedAtMs,
                        localPrunedAtMs, updatedAtMs
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(accountScopeHash, sourceId, dataClass, windowStartMs)
                    DO UPDATE SET
                        windowEndMs = excluded.windowEndMs,
                        chunkId = excluded.chunkId,
                        rowCount = excluded.rowCount,
                        phase = excluded.phase,
                        objectGeneration = excluded.objectGeneration,
                        objectMetageneration = excluded.objectMetageneration,
                        objectCRC32C = excluded.objectCRC32C,
                        snapshotGeneration = excluded.snapshotGeneration,
                        validatedAtMs = excluded.validatedAtMs,
                        localPrunedAtMs = excluded.localPrunedAtMs,
                        updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [
                    upload.accountScopeHash, upload.sourceID, upload.dataClass,
                    upload.windowStartMs, upload.windowEndMs, upload.chunkID,
                    upload.rowCount, upload.phase, upload.objectGeneration,
                    upload.objectMetageneration, upload.objectCRC32C,
                    upload.snapshotGeneration, upload.validatedAtMs,
                    upload.localPrunedAtMs, upload.updatedAtMs,
                ]
            )
            if upload.phase == "available",
               upload.snapshotGeneration > 0,
               upload.validatedAtMs != nil,
               let localSourceID = try String.fetchOne(
                   db,
                   sql: "SELECT localSourceId FROM managedSyncSource WHERE sourceId = ?",
                   arguments: [upload.sourceID]
               ) {
                try db.execute(
                    sql: """
                        DELETE FROM managedDirtyWindow
                        WHERE localSourceId = ? AND dataClass = ? AND windowStartMs = ?
                          AND windowEndMs = ? AND generation = ?
                          AND claimedGeneration = ?
                        """,
                    arguments: [
                        localSourceID, upload.dataClass, upload.windowStartMs,
                        upload.windowEndMs + 1, upload.snapshotGeneration,
                        upload.snapshotGeneration,
                    ]
                )
            }
        }
    }

    public func claimManagedDirtyWindow(
        localSourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        updatedAtMs: Int64
    ) async throws -> ManagedDirtyWindowState {
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO managedDirtyWindow (
                        localSourceId, dataClass, windowStartMs, windowEndMs,
                        generation, claimedGeneration, updatedAtMs
                    ) VALUES (?, ?, ?, ?, 1, NULL, ?)
                    ON CONFLICT(localSourceId, dataClass, windowStartMs) DO NOTHING
                    """,
                arguments: [
                    localSourceID, dataClass, windowStartMs, windowEndMs, updatedAtMs,
                ]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT localSourceId, dataClass, windowStartMs, windowEndMs,
                           generation, claimedGeneration, updatedAtMs
                    FROM managedDirtyWindow
                    WHERE localSourceId = ? AND dataClass = ? AND windowStartMs = ?
                    """,
                arguments: [localSourceID, dataClass, windowStartMs]
            ) else {
                throw DatabaseError(
                    resultCode: .SQLITE_CORRUPT,
                    message: "managed dirty window disappeared while claiming"
                )
            }
            let storedEnd: Int64 = row["windowEndMs"]
            guard storedEnd == windowEndMs else {
                throw DatabaseError(
                    resultCode: .SQLITE_CONSTRAINT,
                    message: "managed dirty window boundary mismatch"
                )
            }
            let generation: Int64 = row["generation"]
            try db.execute(
                sql: """
                    UPDATE managedDirtyWindow
                    SET claimedGeneration = ?, updatedAtMs = ?
                    WHERE localSourceId = ? AND dataClass = ? AND windowStartMs = ?
                      AND generation = ?
                    """,
                arguments: [
                    generation, updatedAtMs, localSourceID, dataClass,
                    windowStartMs, generation,
                ]
            )
            return ManagedDirtyWindowState(
                localSourceID: localSourceID,
                dataClass: dataClass,
                windowStartMs: windowStartMs,
                windowEndMs: windowEndMs,
                generation: generation,
                claimedGeneration: generation,
                updatedAtMs: updatedAtMs
            )
        }
    }

    public func claimNextManagedDirtyWindow(
        accountScopeHash: String,
        sourceID: String,
        localSourceID: String,
        dataClass: String,
        endingAtOrBeforeMs cutoff: Int64,
        updatedAtMs: Int64
    ) async throws -> ManagedDirtyWindowState? {
        try syncWrite { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT d.localSourceId, d.dataClass, d.windowStartMs, d.windowEndMs,
                           d.generation, d.claimedGeneration, d.updatedAtMs
                    FROM managedDirtyWindow AS d
                    WHERE d.localSourceId = ? AND d.dataClass = ?
                      AND d.windowEndMs <= ?
                      AND NOT EXISTS (
                          SELECT 1 FROM managedWindowUpload AS active
                          WHERE active.accountScopeHash = ? AND active.sourceId = ?
                            AND active.dataClass = d.dataClass
                            AND active.windowStartMs = d.windowStartMs
                            AND active.phase IN (
                                'pending_completion', 'awaiting_validation'
                            )
                      )
                      AND (
                          d.claimedGeneration IS NULL
                          OR d.claimedGeneration < d.generation
                          OR NOT EXISTS (
                              SELECT 1 FROM managedWindowUpload AS claimed
                              WHERE claimed.accountScopeHash = ? AND claimed.sourceId = ?
                                AND claimed.dataClass = d.dataClass
                                AND claimed.windowStartMs = d.windowStartMs
                                AND claimed.snapshotGeneration = d.claimedGeneration
                          )
                      )
                    ORDER BY d.windowStartMs
                    LIMIT 1
                    """,
                arguments: [
                    localSourceID, dataClass, cutoff, accountScopeHash, sourceID,
                    accountScopeHash, sourceID,
                ]
            ) else {
                return nil
            }
            let start: Int64 = row["windowStartMs"]
            let generation: Int64 = row["generation"]
            try db.execute(
                sql: """
                    UPDATE managedDirtyWindow
                    SET claimedGeneration = ?, updatedAtMs = ?
                    WHERE localSourceId = ? AND dataClass = ? AND windowStartMs = ?
                      AND generation = ?
                    """,
                arguments: [
                    generation, updatedAtMs, localSourceID, dataClass, start, generation,
                ]
            )
            return ManagedDirtyWindowState(
                localSourceID: row["localSourceId"],
                dataClass: row["dataClass"],
                windowStartMs: start,
                windowEndMs: row["windowEndMs"],
                generation: generation,
                claimedGeneration: generation,
                updatedAtMs: updatedAtMs
            )
        }
    }

    @discardableResult
    public func acknowledgeManagedAvailableChunk(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: String,
        validatedAtMs: Int64
    ) async throws -> Bool {
        try syncWrite { db in
            guard let upload = try Row.fetchOne(
                db,
                sql: """
                    SELECT snapshotGeneration
                    FROM managedWindowUpload
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                      AND windowStartMs = ? AND windowEndMs = ? AND chunkId = ?
                    """,
                arguments: [
                    accountScopeHash, sourceID, dataClass, windowStartMs,
                    windowEndMs, chunkID,
                ]
            ) else {
                return false
            }
            let snapshotGeneration: Int64 = upload["snapshotGeneration"]
            try db.execute(
                sql: """
                    UPDATE managedWindowUpload
                    SET phase = 'available', objectGeneration = NULL,
                        objectMetageneration = NULL, objectCRC32C = NULL,
                        validatedAtMs = ?, updatedAtMs = ?
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                      AND windowStartMs = ? AND windowEndMs = ? AND chunkId = ?
                    """,
                arguments: [
                    validatedAtMs, validatedAtMs, accountScopeHash, sourceID,
                    dataClass, windowStartMs, windowEndMs, chunkID,
                ]
            )
            if snapshotGeneration > 0,
               let localSourceID = try String.fetchOne(
                   db,
                   sql: "SELECT localSourceId FROM managedSyncSource WHERE sourceId = ?",
                   arguments: [sourceID]
               ) {
                try db.execute(
                    sql: """
                        DELETE FROM managedDirtyWindow
                        WHERE localSourceId = ? AND dataClass = ? AND windowStartMs = ?
                          AND windowEndMs = ? AND generation = ?
                          AND claimedGeneration = ?
                        """,
                    arguments: [
                        localSourceID, dataClass, windowStartMs, windowEndMs + 1,
                        snapshotGeneration, snapshotGeneration,
                    ]
                )
            }
            return true
        }
    }

    @discardableResult
    public func markManagedWindowHydrated(
        accountScopeHash: String,
        sourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: String,
        updatedAtMs: Int64
    ) async throws -> Bool {
        try syncWrite { db in
            try db.execute(
                sql: """
                    UPDATE managedWindowUpload
                    SET localPrunedAtMs = NULL, updatedAtMs = ?
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                      AND windowStartMs = ? AND windowEndMs = ? AND chunkId = ?
                      AND phase = 'available' AND validatedAtMs IS NOT NULL
                    """,
                arguments: [
                    updatedAtMs, accountScopeHash, sourceID, dataClass,
                    windowStartMs, windowEndMs, chunkID,
                ]
            )
            return db.changesCount == 1
        }
    }

    /// Remove only exact, server-validated, unchanged sensor windows. Durable summaries and body
    /// measurements stay local. The guard and eligibility check share one SQLite write transaction,
    /// so a concurrent BLE write either lands before selection (and blocks pruning) or after commit.
    public func pruneManagedAvailableWindows(
        accountScopeHash: String,
        sourceID: String,
        localSourceID: String,
        dataClass: String,
        endingBeforeMs cutoff: Int64,
        limit: Int,
        prunedAtMs: Int64
    ) async throws -> ManagedLocalPruneResult {
        let boundedLimit = max(1, min(limit, 16))
        guard dataClass != "derived_summaries" else {
            return ManagedLocalPruneResult(prunedWindows: 0, deletedRows: 0)
        }
        return try syncWrite { db in
            let candidates = try Row.fetchAll(
                db,
                sql: """
                    SELECT windowStartMs, windowEndMs, chunkId, snapshotGeneration
                    FROM managedWindowUpload AS upload
                    WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                      AND phase = 'available' AND validatedAtMs IS NOT NULL
                      AND localPrunedAtMs IS NULL AND snapshotGeneration > 0
                      AND windowEndMs < ?
                      AND NOT EXISTS (
                          SELECT 1 FROM managedDirtyWindow AS dirty
                          WHERE dirty.localSourceId = ?
                            AND dirty.dataClass = upload.dataClass
                            AND dirty.windowStartMs = upload.windowStartMs
                      )
                    ORDER BY windowStartMs
                    LIMIT ?
                    """,
                arguments: [
                    accountScopeHash, sourceID, dataClass, cutoff,
                    localSourceID, boundedLimit,
                ]
            )
            guard !candidates.isEmpty else {
                return ManagedLocalPruneResult(prunedWindows: 0, deletedRows: 0)
            }

            try db.execute(
                sql: "INSERT OR IGNORE INTO managedPruneGuard (guardId) VALUES (1)"
            )
            var deletedRows = 0
            var prunedWindows = 0
            for candidate in candidates {
                let start: Int64 = candidate["windowStartMs"]
                let end: Int64 = candidate["windowEndMs"]
                deletedRows += try Self.pruneManagedSensorRows(
                    db: db,
                    localSourceID: localSourceID,
                    dataClass: dataClass,
                    windowStartMs: start,
                    windowEndMs: end
                )
                try db.execute(
                    sql: """
                        UPDATE managedWindowUpload
                        SET localPrunedAtMs = ?, updatedAtMs = ?
                        WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                          AND windowStartMs = ? AND windowEndMs = ? AND chunkId = ?
                          AND snapshotGeneration = ? AND phase = 'available'
                          AND validatedAtMs IS NOT NULL AND localPrunedAtMs IS NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM managedDirtyWindow
                              WHERE localSourceId = ? AND dataClass = ?
                                AND windowStartMs = ?
                          )
                        """,
                    arguments: [
                        prunedAtMs, prunedAtMs, accountScopeHash, sourceID,
                        dataClass, start, end, candidate["chunkId"] as String,
                        candidate["snapshotGeneration"] as Int64, localSourceID,
                        dataClass, start,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw DatabaseError(
                        resultCode: .SQLITE_BUSY,
                        message: "managed prune eligibility changed inside transaction"
                    )
                }
                prunedWindows += 1
            }
            try db.execute(sql: "DELETE FROM managedPruneGuard WHERE guardId = 1")
            return ManagedLocalPruneResult(
                prunedWindows: prunedWindows,
                deletedRows: deletedRows
            )
        }
    }

    private static func pruneManagedSensorRows(
        db: Database,
        localSourceID: String,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) throws -> Int {
        let secondStart = (windowStartMs + 999) / 1_000
        let secondEnd = windowEndMs / 1_000
        let tables: [(String, String)]
        switch dataClass {
        case "essential_timeseries":
            // Body measurements are durable user records, not disposable sensor detail.
            tables = [
                ("hrSample", "ts"), ("rrInterval", "ts"), ("event", "ts"),
                ("battery", "ts"), ("stepSample", "ts"), ("ppgHrSample", "ts"),
            ]
        case "raw_auxiliary":
            tables = [
                ("skinTempSample", "ts"), ("respSample", "ts"),
                ("sleepStateSample", "ts"),
            ]
        case "raw_ppg":
            tables = [("spo2Sample", "ts"), ("ppgWaveformSample", "ts")]
        case "raw_motion":
            tables = [("gravitySample", "ts"), ("rawImuSample", "ts")]
        default:
            return 0
        }
        var deleted = 0
        for (table, timestamp) in tables {
            try db.execute(
                sql: """
                    DELETE FROM \(table)
                    WHERE deviceId = ? AND \(timestamp) >= ? AND \(timestamp) <= ?
                    """,
                arguments: [localSourceID, secondStart, secondEnd]
            )
            deleted += db.changesCount
        }
        return deleted
    }

    public func managedSnapshotRestore(
        accountScopeHash: String
    ) async throws -> ManagedSnapshotRestoreState? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT accountScopeHash, requestId, dataClassesJSON,
                           changeFeedCapabilityVersion, restoreJobId,
                           snapshotAt, changeSequence, selectedObjects, selectedBytes,
                           dataClassIndex, afterEventStart, afterChunkId,
                           afterDocumentUpdatedAt, afterDocumentKind, afterDocumentId,
                           documentsComplete,
                           deliveredObjects, deliveredBytes, updatedAtMs
                    FROM managedSnapshotRestore
                    WHERE accountScopeHash = ?
                    """,
                arguments: [accountScopeHash]
            ).map { row in
                let encoded: String = row["dataClassesJSON"]
                let classes = try JSONDecoder().decode(
                    [String].self,
                    from: Data(encoded.utf8)
                )
                return ManagedSnapshotRestoreState(
                    accountScopeHash: row["accountScopeHash"],
                    requestID: row["requestId"],
                    dataClasses: classes,
                    changeFeedCapabilityVersion: row["changeFeedCapabilityVersion"],
                    restoreJobID: row["restoreJobId"],
                    snapshotAt: row["snapshotAt"],
                    changeSequence: row["changeSequence"],
                    selectedObjects: row["selectedObjects"],
                    selectedBytes: row["selectedBytes"],
                    dataClassIndex: row["dataClassIndex"],
                    afterEventStart: row["afterEventStart"],
                    afterChunkID: row["afterChunkId"],
                    afterDocumentUpdatedAt: row["afterDocumentUpdatedAt"],
                    afterDocumentKind: row["afterDocumentKind"],
                    afterDocumentID: row["afterDocumentId"],
                    documentsComplete: row["documentsComplete"],
                    deliveredObjects: row["deliveredObjects"],
                    deliveredBytes: row["deliveredBytes"],
                    updatedAtMs: row["updatedAtMs"]
                )
            }
        }
    }

    public func saveManagedSnapshotRestore(
        _ checkpoint: ManagedSnapshotRestoreState
    ) async throws {
        let encoded = try JSONEncoder().encode(checkpoint.dataClasses)
        guard let classes = String(data: encoded, encoding: .utf8) else {
            throw DatabaseError(
                resultCode: .SQLITE_MISMATCH,
                message: "managed restore data classes are not UTF-8"
            )
        }
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO managedSnapshotRestore (
                        accountScopeHash, requestId, dataClassesJSON,
                        changeFeedCapabilityVersion, restoreJobId,
                        snapshotAt, changeSequence, selectedObjects, selectedBytes,
                        dataClassIndex, afterEventStart, afterChunkId,
                        afterDocumentUpdatedAt, afterDocumentKind, afterDocumentId,
                        documentsComplete,
                        deliveredObjects, deliveredBytes, updatedAtMs
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(accountScopeHash) DO UPDATE SET
                        requestId = excluded.requestId,
                        dataClassesJSON = excluded.dataClassesJSON,
                        changeFeedCapabilityVersion =
                            excluded.changeFeedCapabilityVersion,
                        restoreJobId = excluded.restoreJobId,
                        snapshotAt = excluded.snapshotAt,
                        changeSequence = excluded.changeSequence,
                        selectedObjects = excluded.selectedObjects,
                        selectedBytes = excluded.selectedBytes,
                        dataClassIndex = excluded.dataClassIndex,
                        afterEventStart = excluded.afterEventStart,
                        afterChunkId = excluded.afterChunkId,
                        afterDocumentUpdatedAt = excluded.afterDocumentUpdatedAt,
                        afterDocumentKind = excluded.afterDocumentKind,
                        afterDocumentId = excluded.afterDocumentId,
                        documentsComplete = excluded.documentsComplete,
                        deliveredObjects = excluded.deliveredObjects,
                        deliveredBytes = excluded.deliveredBytes,
                        updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [
                    checkpoint.accountScopeHash, checkpoint.requestID, classes,
                    checkpoint.changeFeedCapabilityVersion,
                    checkpoint.restoreJobID, checkpoint.snapshotAt,
                    checkpoint.changeSequence, checkpoint.selectedObjects,
                    checkpoint.selectedBytes, checkpoint.dataClassIndex,
                    checkpoint.afterEventStart, checkpoint.afterChunkID,
                    checkpoint.afterDocumentUpdatedAt,
                    checkpoint.afterDocumentKind,
                    checkpoint.afterDocumentID,
                    checkpoint.documentsComplete,
                    checkpoint.deliveredObjects, checkpoint.deliveredBytes,
                    checkpoint.updatedAtMs,
                ]
            )
        }
    }

    public func clearManagedSnapshotRestore(accountScopeHash: String) async throws {
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM managedSnapshotRestore WHERE accountScopeHash = ?",
                arguments: [accountScopeHash]
            )
        }
    }

    public func finishManagedSnapshotRestore(
        accountScopeHash: String,
        changeSequence: Int64,
        changeFeedCapabilityVersion: Int,
        updatedAtMs: Int64
    ) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO managedChangeCursor (
                    accountScopeHash, sequence, changeFeedCapabilityVersion, updatedAtMs
                )
                VALUES (?, ?, ?, ?)
                ON CONFLICT(accountScopeHash) DO UPDATE SET
                    sequence = MAX(managedChangeCursor.sequence, excluded.sequence),
                    changeFeedCapabilityVersion = CASE
                        WHEN excluded.sequence >= managedChangeCursor.sequence
                        THEN excluded.changeFeedCapabilityVersion
                        ELSE managedChangeCursor.changeFeedCapabilityVersion
                    END,
                    updatedAtMs = CASE
                        WHEN excluded.sequence >= managedChangeCursor.sequence
                        THEN excluded.updatedAtMs
                        ELSE managedChangeCursor.updatedAtMs
                    END
                """, arguments: [
                    accountScopeHash, max(0, changeSequence),
                    max(0, changeFeedCapabilityVersion), updatedAtMs,
                ])
            try db.execute(
                sql: "DELETE FROM managedSnapshotRestore WHERE accountScopeHash = ?",
                arguments: [accountScopeHash]
            )
        }
    }

    public func managedChangeSequence(accountScopeHash: String) async throws -> Int64 {
        try syncRead { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT sequence FROM managedChangeCursor WHERE accountScopeHash = ?",
                arguments: [accountScopeHash]
            ) ?? 0
        }
    }

    public func managedChangeFeedCapabilityVersion(
        accountScopeHash: String
    ) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT changeFeedCapabilityVersion
                    FROM managedChangeCursor
                    WHERE accountScopeHash = ?
                    """,
                arguments: [accountScopeHash]
            ) ?? 0
        }
    }

    /// Advance only. A change feed is ordered, so a stale task must never move another task backward.
    public func saveManagedChangeSequence(
        _ sequence: Int64,
        accountScopeHash: String,
        updatedAtMs: Int64
    ) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO managedChangeCursor (accountScopeHash, sequence, updatedAtMs)
                VALUES (?, ?, ?)
                ON CONFLICT(accountScopeHash) DO UPDATE SET
                    sequence = MAX(managedChangeCursor.sequence, excluded.sequence),
                    updatedAtMs = CASE
                        WHEN excluded.sequence >= managedChangeCursor.sequence
                        THEN excluded.updatedAtMs
                        ELSE managedChangeCursor.updatedAtMs
                    END
                """, arguments: [accountScopeHash, max(0, sequence), updatedAtMs])
        }
    }

    public func hasManagedAppliedChange(
        accountScopeHash: String,
        sequence: Int64
    ) async throws -> Bool {
        try await managedAppliedChange(
            accountScopeHash: accountScopeHash,
            sequence: sequence
        ) != nil
    }

    public func managedAppliedChange(
        accountScopeHash: String,
        sequence: Int64
    ) async throws -> ManagedAppliedChangeState? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT accountScopeHash, sequence, resourceKind, resourceId,
                           contentSHA256, appliedAtMs
                    FROM managedAppliedChange
                    WHERE accountScopeHash = ? AND sequence = ?
                    """,
                arguments: [accountScopeHash, sequence]
            ).map {
                ManagedAppliedChangeState(
                    accountScopeHash: $0["accountScopeHash"],
                    sequence: $0["sequence"],
                    resourceKind: $0["resourceKind"],
                    resourceID: $0["resourceId"],
                    contentSHA256: $0["contentSHA256"],
                    appliedAtMs: $0["appliedAtMs"]
                )
            }
        }
    }

    public func recordManagedAppliedChange(
        _ change: ManagedAppliedChangeState,
        retainingLatest limit: Int = 512
    ) async throws {
        let boundedLimit = max(32, min(limit, 4_096))
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO managedAppliedChange (
                    accountScopeHash, sequence, resourceKind, resourceId, contentSHA256, appliedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    change.accountScopeHash, change.sequence, change.resourceKind,
                    change.resourceID, change.contentSHA256, change.appliedAtMs,
                ])
            try db.execute(sql: """
                DELETE FROM managedAppliedChange
                WHERE accountScopeHash = ?
                  AND sequence < COALESCE((
                      SELECT sequence FROM managedAppliedChange
                      WHERE accountScopeHash = ?
                      ORDER BY sequence DESC
                      LIMIT 1 OFFSET ?
                  ), 0)
                """, arguments: [
                    change.accountScopeHash, change.accountScopeHash, boundedLimit - 1,
                ])
        }
    }

    public func resetManagedChangeState(accountScopeHash: String) async throws {
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM managedAppliedChange WHERE accountScopeHash = ?",
                arguments: [accountScopeHash]
            )
            try db.execute(
                sql: "DELETE FROM managedChangeCursor WHERE accountScopeHash = ?",
                arguments: [accountScopeHash]
            )
        }
    }
}
