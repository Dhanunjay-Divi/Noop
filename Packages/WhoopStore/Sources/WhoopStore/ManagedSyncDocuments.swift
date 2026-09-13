import CoreFoundation
import CryptoKit
import Foundation
import GRDB

public enum ManagedDocumentContentMode: String, Equatable, Sendable {
    case serverReadable = "server_readable"
    case clientEncrypted = "client_encrypted"
}

public enum ManagedDocumentStableIdentifier {
    public static func uuid(
        documentKind: String,
        tableName: String,
        keyJSON: Data
    ) -> UUID {
        let seed = Data(
            (
                "noop-managed-document-v1\0\(documentKind)\0"
                    + "\(tableName)\0"
            ).utf8
        ) + keyJSON
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// One durable, account-scoped document mutation waiting for NOOP+.
///
/// Payloads use a small cross-platform envelope instead of a database dump. Only allowlisted
/// user-authored tables are represented, and every restore validates the complete column set before
/// opening a write transaction.
public struct ManagedLocalDocumentCandidate: Equatable, Sendable {
    public let localProfileID: String
    public let tableName: String
    public let documentKind: String
    public let contentMode: ManagedDocumentContentMode
    public let localKey: String
    public let keyJSON: Data
    public let generation: Int64
    public let baseRevision: Int64
    public let updatedAtMs: Int64
    public let payloadJSON: Data?

    public var deleted: Bool { payloadJSON == nil }
}

public struct ManagedDocumentApplyResult: Equatable, Sendable {
    public let changedRows: Int
    public let applied: Bool

    public init(changedRows: Int, applied: Bool) {
        self.changedRows = changedRows
        self.applied = applied
    }
}

struct ManagedDocumentTableSpec {
    let tableName: String
    let documentKind: String
    let contentMode: ManagedDocumentContentMode
    let keyColumns: [String]
    let eligibility: (String) -> String

    init(
        tableName: String,
        documentKind: String,
        contentMode: ManagedDocumentContentMode = .clientEncrypted,
        keyColumns: [String],
        eligibility: @escaping (String) -> String = { _ in "1" }
    ) {
        self.tableName = tableName
        self.documentKind = documentKind
        self.contentMode = contentMode
        self.keyColumns = keyColumns
        self.eligibility = eligibility
    }

    func localKeySQL(row: String) -> String {
        keyColumns.map {
            "hex(CAST(\(row).\"\($0)\" AS BLOB))"
        }.joined(separator: " || ':' || ")
    }
}

extension WhoopStore {
    private struct ManagedHydrationProjection: Hashable {
        let deviceId: String
        let day: String
    }

    private struct ManagedDayOwnershipValue: Equatable {
        let deviceId: String
        let locked: Int64
    }

    private enum ManagedPendingDocumentOperation {
        case upsert
        case delete
    }

    private struct ManagedPendingDocumentIdentity {
        let tableName: String
        let localKey: String
        let keyJSON: String
        let generation: Int64
        let operation: ManagedPendingDocumentOperation
    }

    private static let managedHydrationTable = "hydrationEntry"
    private static let managedHydrationDevice = "hydration"
    private static let managedHydrationMetricKey = "hydration"
    private static let managedHydrationMaximumAmountML: Int64 = 10_000
    private static let managedDayOwnershipTable = "dayOwnership"
    private static let managedDayOwnershipKind = "day_ownership"
    private static let managedDayOwnershipMaximumDeviceIDBytes = 256

    static let managedDocumentTableSpecs: [ManagedDocumentTableSpec] = [
        .init(
            tableName: "journal",
            documentKind: "journal",
            keyColumns: ["deviceId", "day", "question"]
        ),
        .init(
            tableName: "labMarker",
            documentKind: "lab_marker",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "nutritionEntry",
            documentKind: "nutrition",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "nutritionCatalogItem",
            documentKind: "nutrition_catalog",
            keyColumns: ["id"],
            eligibility: { "\($0).\"isSaved\" != 0" }
        ),
        .init(
            tableName: "strengthExercise",
            documentKind: "strength_plan",
            keyColumns: ["id"],
            eligibility: {
                "(\($0).\"isCustom\" != 0"
                    + " OR \($0).\"createdAt\" != 1"
                    + " OR \($0).\"updatedAt\" != 1)"
            }
        ),
        .init(
            tableName: "strengthRoutine",
            documentKind: "strength_plan",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "strengthRoutineExercise",
            documentKind: "strength_plan",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "strengthSession",
            documentKind: "strength_log",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "strengthSet",
            documentKind: "strength_log",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "coachMessage",
            documentKind: "coach_history",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "coachMemory",
            documentKind: "coach_memory",
            keyColumns: ["id"]
        ),
        .init(
            tableName: "hydrationEntry",
            documentKind: "hydration",
            keyColumns: ["id"]
        ),
        .init(
            tableName: managedDayOwnershipTable,
            documentKind: managedDayOwnershipKind,
            contentMode: .serverReadable,
            keyColumns: ["day"]
        ),
    ]

    static let managedPreferencesTable = "preferences"
    static let managedPreferencesKey = "global"
    static let managedPreferencesKind = "preferences"
    static let managedPreferencesContentMode =
        ManagedDocumentContentMode.clientEncrypted
    private static let managedLocalProfileBindingID = 1

    static func installManagedDocumentSync(_ db: Database) throws {
        try db.create(table: "managedDocumentDirty") { t in
            t.column("tableName", .text).notNull()
            t.column("localKey", .text).notNull()
            t.column("documentKind", .text).notNull()
            t.column("generation", .integer).notNull()
            t.column("operation", .text).notNull()
            t.column("updatedAtMs", .integer).notNull()
            t.column("payloadJSON", .text)
            t.primaryKey(["tableName", "localKey"])
        }
        try db.create(
            index: "idx_managedDocumentDirty_order",
            on: "managedDocumentDirty",
            columns: ["updatedAtMs", "tableName", "localKey"]
        )
        try db.create(table: "managedDocumentState") { t in
            t.column("accountScopeHash", .text).notNull()
            t.column("tableName", .text).notNull()
            t.column("localKey", .text).notNull()
            t.column("documentKind", .text).notNull()
            t.column("documentId", .text).notNull()
            t.column("keyJSON", .text).notNull()
            t.column("acknowledgedGeneration", .integer).notNull()
            t.column("remoteRevision", .integer).notNull()
            t.column("remoteContentSHA256", .text).notNull()
            t.column("updatedAtMs", .integer).notNull()
            t.primaryKey(["accountScopeHash", "tableName", "localKey"])
        }
        try db.create(
            index: "idx_managedDocumentState_document",
            on: "managedDocumentState",
            columns: ["accountScopeHash", "documentKind", "documentId"],
            unique: true
        )
        try db.create(table: "managedDocumentApplyGuard") { t in
            t.column("guardId", .integer).primaryKey()
        }

        try installManagedDocumentTriggers(
            db,
            specs: managedDocumentTableSpecs,
            seedExisting: true
        )
    }

    static func migrateManagedDocumentAccountIsolation(_ db: Database) throws {
        try dropManagedDocumentTriggers(db, specs: managedDocumentTableSpecs)
        try db.create(table: "managedLocalProfile") { t in
            t.column("bindingId", .integer).primaryKey()
            t.column("localProfileId", .text).notNull()
            t.column("accountScopeHash", .text)
            t.column("updatedAtMs", .integer).notNull()
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO managedLocalProfile (
                bindingId, localProfileId, accountScopeHash, updatedAtMs
            )
            SELECT ?, lower(hex(randomblob(16))), NULL,
                   CAST(strftime('%s', 'now') AS INTEGER) * 1000
            """, arguments: [managedLocalProfileBindingID])

        try db.rename(
            table: "managedDocumentDirty",
            to: "managedDocumentDirtyLegacy"
        )
        try db.create(table: "managedDocumentDirty") { t in
            t.column("localProfileId", .text).notNull()
            t.column("tableName", .text).notNull()
            t.column("localKey", .text).notNull()
            t.column("documentKind", .text).notNull()
            t.column("generation", .integer).notNull()
            t.column("operation", .text).notNull()
            t.column("updatedAtMs", .integer).notNull()
            t.column("payloadJSON", .text)
            t.primaryKey(["localProfileId", "tableName", "localKey"])
        }
        try db.execute(sql: """
            INSERT INTO managedDocumentDirty (
                localProfileId, tableName, localKey, documentKind,
                generation, operation, updatedAtMs, payloadJSON
            )
            SELECT profile.localProfileId, legacy.tableName, legacy.localKey,
                   legacy.documentKind, legacy.generation, legacy.operation,
                   legacy.updatedAtMs, legacy.payloadJSON
            FROM managedDocumentDirtyLegacy AS legacy
            JOIN managedLocalProfile AS profile ON profile.bindingId = ?
            """, arguments: [managedLocalProfileBindingID])
        try db.drop(table: "managedDocumentDirtyLegacy")
        try db.create(
            index: "idx_managedDocumentDirty_order",
            on: "managedDocumentDirty",
            columns: [
                "localProfileId", "updatedAtMs", "tableName", "localKey",
            ]
        )
        try installAccountScopedManagedDocumentTriggers(
            db,
            specs: managedDocumentTableSpecs
        )
    }

    static func installManagedDocumentTriggers(
        _ db: Database,
        specs: [ManagedDocumentTableSpec],
        seedExisting: Bool
    ) throws {
        let now = "CAST(strftime('%s', 'now') AS INTEGER) * 1000"
        for spec in specs {
            let table = spec.tableName
            let tableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = ?
                    )
                    """,
                arguments: [table]
            ) ?? false
            guard tableExists else { continue }

            let newKey = spec.localKeySQL(row: "NEW")
            let oldKey = spec.localKeySQL(row: "OLD")
            let newEligible = spec.eligibility("NEW")
            let oldEligible = spec.eligibility("OLD")
            let guardAbsent = """
                NOT EXISTS (
                    SELECT 1 FROM managedDocumentApplyGuard WHERE guardId = 1
                )
                """

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_insert"
                AFTER INSERT ON "\(table)"
                BEGIN
                    \(managedDocumentDirtySQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: newKey,
                        operation: "upsert",
                        condition: "\(guardAbsent) AND (\(newEligible))",
                        nowSQL: now
                    ));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_delete"
                AFTER DELETE ON "\(table)"
                BEGIN
                    \(managedDocumentDirtySQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: oldKey,
                        operation: "delete",
                        condition: "\(guardAbsent) AND (\(oldEligible))",
                        nowSQL: now
                    ));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_update"
                AFTER UPDATE ON "\(table)"
                BEGIN
                    \(managedDocumentDirtySQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: oldKey,
                        operation: "delete",
                        condition: """
                            \(guardAbsent)
                            AND (\(oldEligible))
                            AND (NOT (\(newEligible)) OR \(oldKey) != \(newKey))
                            """,
                        nowSQL: now
                    ));
                    \(managedDocumentDirtySQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: newKey,
                        operation: "upsert",
                        condition: "\(guardAbsent) AND (\(newEligible))",
                        nowSQL: now
                    ));
                END
                """)
            guard seedExisting else { continue }
            try db.execute(sql: """
                INSERT INTO managedDocumentDirty (
                    tableName, localKey, documentKind, generation,
                    operation, updatedAtMs, payloadJSON
                )
                SELECT ?, \(spec.localKeySQL(row: "seed")), ?, 1,
                       'upsert', \(now), NULL
                FROM "\(table)" AS seed
                WHERE \(spec.eligibility("seed"))
                ON CONFLICT(tableName, localKey) DO NOTHING
                """, arguments: [table, spec.documentKind])
        }
    }

    static func installAccountScopedManagedDocumentTriggers(
        _ db: Database,
        specs: [ManagedDocumentTableSpec]
    ) throws {
        let now = "CAST(strftime('%s', 'now') AS INTEGER) * 1000"
        for spec in specs {
            let table = spec.tableName
            let tableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = ?
                    )
                    """,
                arguments: [table]
            ) ?? false
            guard tableExists else { continue }

            let newKey = spec.localKeySQL(row: "NEW")
            let oldKey = spec.localKeySQL(row: "OLD")
            let newEligible = spec.eligibility("NEW")
            let oldEligible = spec.eligibility("OLD")
            let guardAbsent = """
                NOT EXISTS (
                    SELECT 1 FROM managedDocumentApplyGuard WHERE guardId = 1
                )
                """

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_insert"
                AFTER INSERT ON "\(table)"
                BEGIN
                    \(managedDocumentMutationSQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: newKey,
                        operation: "upsert",
                        mutationCondition: newEligible,
                        guardAbsent: guardAbsent,
                        nowSQL: now
                    ));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_delete"
                AFTER DELETE ON "\(table)"
                BEGIN
                    \(managedDocumentMutationSQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: oldKey,
                        operation: "delete",
                        mutationCondition: oldEligible,
                        guardAbsent: guardAbsent,
                        nowSQL: now
                    ));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS "managed_document_\(table)_update"
                AFTER UPDATE ON "\(table)"
                BEGIN
                    \(managedDocumentMutationSQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: oldKey,
                        operation: "delete",
                        mutationCondition: """
                            (\(oldEligible))
                            AND (NOT (\(newEligible)) OR \(oldKey) != \(newKey))
                            """,
                        guardAbsent: guardAbsent,
                        nowSQL: now
                    ));
                    \(managedDocumentMutationSQL(
                        tableName: table,
                        documentKind: spec.documentKind,
                        localKeySQL: newKey,
                        operation: "upsert",
                        mutationCondition: newEligible,
                        guardAbsent: guardAbsent,
                        nowSQL: now
                    ));
                END
                """)
        }
    }

    private static func dropManagedDocumentTriggers(
        _ db: Database,
        specs: [ManagedDocumentTableSpec]
    ) throws {
        for spec in specs {
            for operation in ["insert", "delete", "update"] {
                try db.execute(
                    sql: """
                        DROP TRIGGER IF EXISTS
                        "managed_document_\(spec.tableName)_\(operation)"
                        """
                )
            }
        }
    }

    private static func managedDocumentMutationSQL(
        tableName: String,
        documentKind: String,
        localKeySQL: String,
        operation: String,
        mutationCondition: String,
        guardAbsent: String,
        nowSQL: String
    ) -> String {
        """
        DELETE FROM managedDocumentDirty
        WHERE tableName = '\(tableName)'
          AND localKey = \(localKeySQL)
          AND (\(mutationCondition))
          AND (
            NOT EXISTS (
                SELECT 1
                FROM managedLocalProfile AS active
                WHERE active.bindingId = \(managedLocalProfileBindingID)
                  AND active.accountScopeHash IS NOT NULL
                  AND active.localProfileId = active.accountScopeHash
            )
            OR localProfileId != (
                SELECT active.localProfileId
                FROM managedLocalProfile AS active
                WHERE active.bindingId = \(managedLocalProfileBindingID)
                  AND active.accountScopeHash IS NOT NULL
                  AND active.localProfileId = active.accountScopeHash
            )
          );
        INSERT INTO managedDocumentDirty (
            localProfileId, tableName, localKey, documentKind, generation,
            operation, updatedAtMs, payloadJSON
        )
        SELECT profile.localProfileId, '\(tableName)', \(localKeySQL),
               '\(documentKind)', 1, '\(operation)', \(nowSQL), NULL
        FROM managedLocalProfile AS profile
        WHERE (\(mutationCondition))
          AND \(guardAbsent)
          AND profile.bindingId = \(managedLocalProfileBindingID)
          AND profile.accountScopeHash IS NOT NULL
          AND profile.localProfileId = profile.accountScopeHash
        ON CONFLICT(localProfileId, tableName, localKey) DO UPDATE SET
            documentKind = excluded.documentKind,
            generation = managedDocumentDirty.generation + 1,
            operation = excluded.operation,
            updatedAtMs = excluded.updatedAtMs,
            payloadJSON = NULL
        """
    }

    private static func managedDocumentDirtySQL(
        tableName: String,
        documentKind: String,
        localKeySQL: String,
        operation: String,
        condition: String,
        nowSQL: String
    ) -> String {
        """
        INSERT INTO managedDocumentDirty (
            tableName, localKey, documentKind, generation,
            operation, updatedAtMs, payloadJSON
        )
        SELECT '\(tableName)', \(localKeySQL), '\(documentKind)', 1,
               '\(operation)', \(nowSQL), NULL
        WHERE \(condition)
        ON CONFLICT(tableName, localKey) DO UPDATE SET
            documentKind = excluded.documentKind,
            generation = managedDocumentDirty.generation + 1,
            operation = excluded.operation,
            updatedAtMs = excluded.updatedAtMs,
            payloadJSON = NULL
        """
    }

    public func activateManagedDocumentProfile(
        accountScopeHash: String,
        updatedAtMs: Int64
    ) async throws {
        guard Self.validAccountScopeHash(accountScopeHash),
              updatedAtMs >= 0 else {
            throw ManagedDocumentStoreError.invalidState
        }
        try syncWrite { db in
            try Self.ensureManagedLocalProfile(db, updatedAtMs: updatedAtMs)
            let current = try Row.fetchOne(
                db,
                sql: """
                    SELECT localProfileId, accountScopeHash
                    FROM managedLocalProfile
                    WHERE bindingId = ?
                    """,
                arguments: [Self.managedLocalProfileBindingID]
            )
            if let current,
               (current["localProfileId"] as String?) == accountScopeHash,
               (current["accountScopeHash"] as String?) == accountScopeHash {
                return
            }
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = ?,
                        updatedAtMs = ?
                    WHERE bindingId = ?
                    """,
                arguments: [
                    accountScopeHash,
                    accountScopeHash,
                    updatedAtMs,
                    Self.managedLocalProfileBindingID,
                ]
            )
        }
    }

    public func releaseManagedDocumentProfile(
        updatedAtMs: Int64
    ) async throws {
        guard updatedAtMs >= 0 else {
            throw ManagedDocumentStoreError.invalidState
        }
        try syncWrite { db in
            try Self.ensureManagedLocalProfile(db, updatedAtMs: updatedAtMs)
            let accountScopeHash = try String.fetchOne(
                db,
                sql: """
                    SELECT accountScopeHash
                    FROM managedLocalProfile
                    WHERE bindingId = ?
                    """,
                arguments: [Self.managedLocalProfileBindingID]
            )
            guard accountScopeHash != nil else { return }
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = NULL,
                        updatedAtMs = ?
                    WHERE bindingId = ?
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    updatedAtMs,
                    Self.managedLocalProfileBindingID,
                ]
            )
        }
    }

    private static func ensureManagedLocalProfile(
        _ db: Database,
        updatedAtMs: Int64
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO managedLocalProfile (
                    bindingId, localProfileId, accountScopeHash, updatedAtMs
                ) VALUES (?, ?, NULL, ?)
                """,
            arguments: [
                managedLocalProfileBindingID,
                UUID().uuidString.lowercased(),
                updatedAtMs,
            ]
        )
    }

    private static func requiredManagedLocalProfile(
        _ db: Database,
        accountScopeHash: String
    ) throws -> String {
        let binding = try Row.fetchOne(
            db,
            sql: """
                SELECT localProfileId, accountScopeHash
                FROM managedLocalProfile
                WHERE bindingId = ?
                """,
            arguments: [managedLocalProfileBindingID]
        )
        guard let binding,
              let localProfileID: String = binding["localProfileId"],
              (binding["accountScopeHash"] as String?) == accountScopeHash,
              localProfileID == accountScopeHash else {
            throw ManagedDocumentStoreError.invalidState
        }
        return accountScopeHash
    }

    private static func requiredManagedLocalProfile(
        _ db: Database
    ) throws -> String {
        let binding = try Row.fetchOne(
            db,
            sql: """
                SELECT localProfileId, accountScopeHash
                FROM managedLocalProfile
                WHERE bindingId = ?
                """,
            arguments: [managedLocalProfileBindingID]
        )
        guard let binding,
              let localProfileID: String = binding["localProfileId"],
              let accountScopeHash: String = binding["accountScopeHash"],
              localProfileID == accountScopeHash,
              validAccountScopeHash(accountScopeHash) else {
            throw ManagedDocumentStoreError.invalidState
        }
        return localProfileID
    }

    private static func discardConflictingDirtyProfiles(
        _ db: Database,
        tableName: String,
        localKey: String,
        localProfileID: String
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM managedDocumentDirty
                WHERE tableName = ?
                  AND localKey = ?
                  AND localProfileId != ?
                """,
            arguments: [tableName, localKey, localProfileID]
        )
    }

    /// Stages the cross-platform settings whitelist as one small virtual document. Repeated snapshots
    /// do not advance its generation, so opening the app cannot create needless cloud revisions.
    public func stageManagedPreferences(_ payload: Data, updatedAtMs: Int64) async throws {
        guard updatedAtMs >= 0,
              payload.count <= 1_000_000,
              let text = String(data: payload, encoding: .utf8),
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        try syncWrite { db in
            let localProfileID = try Self.requiredManagedLocalProfile(db)
            try Self.discardConflictingDirtyProfiles(
                db,
                tableName: Self.managedPreferencesTable,
                localKey: Self.managedPreferencesKey,
                localProfileID: localProfileID
            )
            let existing: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT payloadJSON FROM managedDocumentDirty
                    WHERE localProfileId = ?
                      AND tableName = ?
                      AND localKey = ?
                    """,
                arguments: [
                    localProfileID,
                    Self.managedPreferencesTable,
                    Self.managedPreferencesKey,
                ]
            )
            guard existing != text else { return }
            try db.execute(sql: """
                INSERT INTO managedDocumentDirty (
                    localProfileId, tableName, localKey, documentKind, generation,
                    operation, updatedAtMs, payloadJSON
                ) VALUES (?, ?, ?, ?, 1, 'upsert', ?, ?)
                ON CONFLICT(localProfileId, tableName, localKey) DO UPDATE SET
                    documentKind = excluded.documentKind,
                    generation = managedDocumentDirty.generation + 1,
                    operation = 'upsert',
                    updatedAtMs = excluded.updatedAtMs,
                    payloadJSON = excluded.payloadJSON
                """, arguments: [
                    localProfileID,
                    Self.managedPreferencesTable,
                    Self.managedPreferencesKey,
                    Self.managedPreferencesKind,
                    updatedAtMs,
                    text,
                ])
        }
    }

    public func pendingManagedDocuments(
        accountScopeHash: String,
        contentMode: ManagedDocumentContentMode,
        limit: Int
    ) async throws -> [ManagedLocalDocumentCandidate] {
        guard Self.validAccountScopeHash(accountScopeHash),
              (1...500).contains(limit) else {
            throw ManagedDocumentStoreError.invalidState
        }
        return try syncWrite { db in
            let localProfileID = try Self.requiredManagedLocalProfile(
                db,
                accountScopeHash: accountScopeHash
            )
            var modePredicates = Self.managedDocumentTableSpecs
                .filter { $0.contentMode == contentMode }
                .map { _ in "(dirty.tableName = ? AND dirty.documentKind = ?)" }
            var arguments = [
                accountScopeHash.databaseValue,
                localProfileID.databaseValue,
            ]
            for spec in Self.managedDocumentTableSpecs
                where spec.contentMode == contentMode {
                arguments.append(spec.tableName.databaseValue)
                arguments.append(spec.documentKind.databaseValue)
            }
            if Self.managedPreferencesContentMode == contentMode {
                modePredicates.append(
                    "(dirty.tableName = ? AND dirty.documentKind = ?)"
                )
                arguments.append(Self.managedPreferencesTable.databaseValue)
                arguments.append(Self.managedPreferencesKind.databaseValue)
            }
            guard !modePredicates.isEmpty else { return [] }
            arguments.append(limit.databaseValue)

            let rows = try Row.fetchAll(db, sql: """
                SELECT dirty.tableName,
                       dirty.localKey,
                       dirty.documentKind,
                       dirty.generation,
                       dirty.operation,
                       dirty.updatedAtMs,
                       dirty.payloadJSON,
                       COALESCE(state.remoteRevision, 0) AS remoteRevision
                FROM managedDocumentDirty AS dirty
                LEFT JOIN managedDocumentState AS state
                  ON state.accountScopeHash = ?
                 AND state.tableName = dirty.tableName
                 AND state.localKey = dirty.localKey
                WHERE dirty.localProfileId = ?
                  AND (
                    state.acknowledgedGeneration IS NULL
                    OR state.acknowledgedGeneration < dirty.generation
                )
                  AND (
                    dirty.operation != 'delete'
                    OR COALESCE(state.remoteRevision, 0) > 0
                  )
                  AND (
                    \(modePredicates.joined(separator: " OR "))
                  )
                ORDER BY dirty.updatedAtMs, dirty.tableName, dirty.localKey
                LIMIT ?
                """, arguments: StatementArguments(arguments))

            return try rows.map { dirty in
                let tableName: String = dirty["tableName"]
                let localKey: String = dirty["localKey"]
                let documentKind: String = dirty["documentKind"]
                let operation: String = dirty["operation"]
                let generation: Int64 = dirty["generation"]
                let updatedAtMs: Int64 = dirty["updatedAtMs"]
                let baseRevision: Int64 = dirty["remoteRevision"]

                if tableName == Self.managedPreferencesTable {
                    guard documentKind == Self.managedPreferencesKind,
                          localKey == Self.managedPreferencesKey,
                          operation == "upsert",
                          let text: String = dirty["payloadJSON"],
                          let data = text.data(using: .utf8) else {
                        throw ManagedDocumentStoreError.invalidState
                    }
                    let keyData = try Self.canonicalJSONObject([
                        "scope": Self.managedPreferencesKey,
                    ])
                    return ManagedLocalDocumentCandidate(
                        localProfileID: localProfileID,
                        tableName: tableName,
                        documentKind: documentKind,
                        contentMode: Self.managedPreferencesContentMode,
                        localKey: localKey,
                        keyJSON: keyData,
                        generation: generation,
                        baseRevision: baseRevision,
                        updatedAtMs: updatedAtMs,
                        payloadJSON: data
                    )
                }

                guard let spec = Self.managedDocumentTableSpecs.first(where: {
                    $0.tableName == tableName && $0.documentKind == documentKind
                }), spec.contentMode == contentMode else {
                    throw ManagedDocumentStoreError.invalidState
                }
                let current = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM "\(tableName)" AS candidate
                        WHERE \(spec.localKeySQL(row: "candidate")) = ?
                          AND \(spec.eligibility("candidate"))
                        """,
                    arguments: [localKey]
                )
                guard operation == "upsert", let current else {
                    let keyJSON: Data
                    if let stored: String = try String.fetchOne(
                        db,
                        sql: """
                            SELECT keyJSON FROM managedDocumentState
                            WHERE accountScopeHash = ?
                              AND tableName = ?
                              AND localKey = ?
                            """,
                        arguments: [accountScopeHash, tableName, localKey]
                    ), let data = stored.data(using: .utf8) {
                        keyJSON = data
                    } else {
                        throw ManagedDocumentStoreError.invalidState
                    }
                    return ManagedLocalDocumentCandidate(
                        localProfileID: localProfileID,
                        tableName: tableName,
                        documentKind: documentKind,
                        contentMode: spec.contentMode,
                        localKey: localKey,
                        keyJSON: keyJSON,
                        generation: generation,
                        baseRevision: baseRevision,
                        updatedAtMs: updatedAtMs,
                        payloadJSON: nil
                    )
                }

                let record = try Self.jsonRecord(current)
                let key = Dictionary(uniqueKeysWithValues: try spec.keyColumns.map { column in
                    guard let value = record[column] else {
                        throw ManagedDocumentStoreError.invalidPayload
                    }
                    return (column, value)
                })
                if tableName == Self.managedDayOwnershipTable {
                    try Self.validateManagedDayOwnership(
                        key: key,
                        record: record
                    )
                }
                let keyJSON = try Self.canonicalJSONObject(key)
                let payload = try Self.canonicalJSONObject([
                    "schema_version": 1,
                    "table": tableName,
                    "key": key,
                    "record": record,
                ])
                guard payload.count <= 1_000_000 else {
                    throw ManagedDocumentStoreError.payloadTooLarge
                }
                return ManagedLocalDocumentCandidate(
                    localProfileID: localProfileID,
                    tableName: tableName,
                    documentKind: documentKind,
                    contentMode: spec.contentMode,
                    localKey: localKey,
                    keyJSON: keyJSON,
                    generation: generation,
                    baseRevision: baseRevision,
                    updatedAtMs: updatedAtMs,
                    payloadJSON: payload
                )
            }
        }
    }

    public func acknowledgeManagedDocument(
        accountScopeHash: String,
        candidate: ManagedLocalDocumentCandidate,
        documentID: String,
        remoteRevision: Int64,
        remoteContentSHA256: String,
        acknowledgedAtMs: Int64
    ) async throws {
        guard Self.validAccountScopeHash(accountScopeHash),
              Self.validUUID(documentID),
              remoteRevision > 0,
              Self.validSHA256(remoteContentSHA256),
              acknowledgedAtMs >= 0,
              let keyJSON = String(data: candidate.keyJSON, encoding: .utf8) else {
            throw ManagedDocumentStoreError.invalidState
        }
        try syncWrite { db in
            let localProfileID = try Self.requiredManagedLocalProfile(
                db,
                accountScopeHash: accountScopeHash
            )
            guard candidate.localProfileID == localProfileID else {
                throw ManagedDocumentStoreError.invalidState
            }
            try db.execute(sql: """
                INSERT INTO managedDocumentState (
                    accountScopeHash, tableName, localKey, documentKind,
                    documentId, keyJSON, acknowledgedGeneration, remoteRevision,
                    remoteContentSHA256, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(accountScopeHash, tableName, localKey) DO UPDATE SET
                    documentKind = excluded.documentKind,
                    documentId = excluded.documentId,
                    keyJSON = excluded.keyJSON,
                    acknowledgedGeneration = MAX(
                        managedDocumentState.acknowledgedGeneration,
                        excluded.acknowledgedGeneration
                    ),
                    remoteRevision = excluded.remoteRevision,
                    remoteContentSHA256 = excluded.remoteContentSHA256,
                    updatedAtMs = excluded.updatedAtMs
                """, arguments: [
                    accountScopeHash,
                    candidate.tableName,
                    candidate.localKey,
                    candidate.documentKind,
                    documentID.lowercased(),
                    keyJSON,
                    candidate.generation,
                    remoteRevision,
                    remoteContentSHA256,
                    acknowledgedAtMs,
                ])
        }
    }

    /// Applies an already authenticated and content-verified managed document without creating an
    /// echo in the local outbox. The caller validates the deterministic document identifier first.
    public func applyManagedDocument(
        accountScopeHash: String,
        documentKind: String,
        documentID: String,
        revision: Int64,
        contentSHA256: String,
        payloadJSON: Data?,
        deleted: Bool,
        appliedAtMs: Int64
    ) async throws -> ManagedDocumentApplyResult {
        guard Self.validAccountScopeHash(accountScopeHash),
              Self.validUUID(documentID),
              revision > 0,
              Self.validSHA256(contentSHA256),
              appliedAtMs >= 0,
              deleted == (payloadJSON == nil) else {
            throw ManagedDocumentStoreError.invalidState
        }
        return try syncWrite { db in
            let localProfileID = try Self.requiredManagedLocalProfile(
                db,
                accountScopeHash: accountScopeHash
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO managedDocumentApplyGuard (guardId) VALUES (1)"
            )
            defer {
                try? db.execute(
                    sql: "DELETE FROM managedDocumentApplyGuard WHERE guardId = 1"
                )
            }

            if documentKind == Self.managedPreferencesKind {
                guard !deleted,
                      let payloadJSON,
                      payloadJSON.count <= 1_000_000,
                      let object = try JSONSerialization.jsonObject(
                          with: payloadJSON
                      ) as? [String: Any],
                      JSONSerialization.isValidJSONObject(object) else {
                    throw ManagedDocumentStoreError.invalidPayload
                }
                let keyJSON = try Self.canonicalJSONObject([
                    "scope": Self.managedPreferencesKey,
                ])
                guard let keyText = String(
                    data: keyJSON,
                    encoding: .utf8
                ) else {
                    throw ManagedDocumentStoreError.invalidPayload
                }
                try Self.discardConflictingDirtyProfiles(
                    db,
                    tableName: Self.managedPreferencesTable,
                    localKey: Self.managedPreferencesKey,
                    localProfileID: localProfileID
                )
                try Self.ensureNoUnacknowledgedLocalGeneration(
                    db,
                    accountScopeHash: accountScopeHash,
                    localProfileID: localProfileID,
                    tableName: Self.managedPreferencesTable,
                    localKey: Self.managedPreferencesKey
                )
                try Self.upsertManagedDocumentState(
                    db,
                    accountScopeHash: accountScopeHash,
                    tableName: Self.managedPreferencesTable,
                    localKey: Self.managedPreferencesKey,
                    documentKind: documentKind,
                    documentID: documentID,
                    keyJSON: keyText,
                    revision: revision,
                    contentSHA256: contentSHA256,
                    localProfileID: localProfileID,
                    updatedAtMs: appliedAtMs
                )
                return ManagedDocumentApplyResult(
                    changedRows: 0,
                    applied: true
                )
            }

            if deleted {
                let state = try Row.fetchOne(db, sql: """
                    SELECT tableName, localKey, keyJSON,
                           acknowledgedGeneration, remoteRevision,
                           remoteContentSHA256
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND documentKind = ?
                      AND documentId = ?
                    """, arguments: [
                        accountScopeHash, documentKind, documentID.lowercased(),
                    ])
                guard let state else {
                    if let pending = try Self.pendingManagedDocumentIdentity(
                        db,
                        accountScopeHash: accountScopeHash,
                        localProfileID: localProfileID,
                        documentKind: documentKind,
                        documentID: documentID
                    ) {
                        try Self.seedManagedDocumentTombstoneRevision(
                            db,
                            accountScopeHash: accountScopeHash,
                            pending: pending,
                            documentKind: documentKind,
                            documentID: documentID,
                            revision: revision,
                            contentSHA256: contentSHA256,
                            updatedAtMs: appliedAtMs
                        )
                    }
                    return ManagedDocumentApplyResult(changedRows: 0, applied: true)
                }
                let tableName: String = state["tableName"]
                let localKey: String = state["localKey"]
                let acknowledgedGeneration: Int64 =
                    state["acknowledgedGeneration"]
                let remoteRevision: Int64 = state["remoteRevision"]
                let remoteContentSHA256: String = state["remoteContentSHA256"]
                try Self.discardConflictingDirtyProfiles(
                    db,
                    tableName: tableName,
                    localKey: localKey,
                    localProfileID: localProfileID
                )
                if remoteRevision == revision,
                   remoteContentSHA256 == contentSHA256 {
                    return ManagedDocumentApplyResult(
                        changedRows: 0,
                        applied: true
                    )
                }
                if acknowledgedGeneration == 0,
                   revision > remoteRevision,
                   remoteContentSHA256 == Self.managedTombstoneSHA256(
                       documentKind: documentKind,
                       documentID: documentID,
                       revision: remoteRevision
                   ),
                   try Self.hasUnacknowledgedLocalGeneration(
                       db,
                       accountScopeHash: accountScopeHash,
                       localProfileID: localProfileID,
                       tableName: tableName,
                       localKey: localKey
                   ) {
                    try db.execute(
                        sql: """
                            UPDATE managedDocumentState
                            SET remoteRevision = ?,
                                remoteContentSHA256 = ?,
                                updatedAtMs = ?
                            WHERE accountScopeHash = ?
                              AND documentKind = ?
                              AND documentId = ?
                            """,
                        arguments: [
                            revision,
                            contentSHA256,
                            appliedAtMs,
                            accountScopeHash,
                            documentKind,
                            documentID.lowercased(),
                        ]
                    )
                    return ManagedDocumentApplyResult(
                        changedRows: 0,
                        applied: true
                    )
                }
                guard let spec = Self.managedDocumentTableSpecs.first(where: {
                    $0.tableName == tableName && $0.documentKind == documentKind
                }) else {
                    throw ManagedDocumentStoreError.invalidState
                }
                try Self.ensureNoUnacknowledgedLocalGeneration(
                    db,
                    accountScopeHash: accountScopeHash,
                    localProfileID: localProfileID,
                    tableName: tableName,
                    localKey: localKey
                )
                let hydrationProjection = tableName == Self.managedHydrationTable
                    ? try Self.storedHydrationProjection(
                        db,
                        localKey: localKey,
                        spec: spec
                    )
                    : nil
                try db.execute(
                    sql: """
                        DELETE FROM "\(tableName)"
                        WHERE \(spec.localKeySQL(row: tableName)) = ?
                    """,
                    arguments: [localKey]
                )
                let changed = db.changesCount
                if changed > 0,
                   tableName == Self.managedDayOwnershipTable,
                   let day = Self.managedDayOwnershipDay(from: localKey) {
                    try AnalysisOwnershipInvalidation.mark(
                        db,
                        affectedRange: AnalysisOwnershipInvalidation.dayRange(day)
                    )
                }
                if let hydrationProjection {
                    try Self.refreshManagedHydrationProjection(
                        db,
                        projection: hydrationProjection
                    )
                }
                try Self.upsertManagedDocumentState(
                    db,
                    accountScopeHash: accountScopeHash,
                    tableName: tableName,
                    localKey: localKey,
                    documentKind: documentKind,
                    documentID: documentID,
                    keyJSON: state["keyJSON"],
                    revision: revision,
                    contentSHA256: contentSHA256,
                    localProfileID: localProfileID,
                    updatedAtMs: appliedAtMs
                )
                return ManagedDocumentApplyResult(changedRows: changed, applied: true)
            }

            guard let payloadJSON,
                  payloadJSON.count <= 1_000_000,
                  let envelope = try JSONSerialization.jsonObject(
                    with: payloadJSON
                  ) as? [String: Any],
                  Self.exactInt64(envelope["schema_version"]) == 1,
                  let tableName = envelope["table"] as? String,
                  let key = envelope["key"] as? [String: Any],
                  let record = envelope["record"] as? [String: Any],
                  let spec = Self.managedDocumentTableSpecs.first(where: {
                      $0.tableName == tableName && $0.documentKind == documentKind
                  }),
                  Set(key.keys) == Set(spec.keyColumns) else {
                throw ManagedDocumentStoreError.invalidPayload
            }
            let columns = try Row.fetchAll(
                db,
                sql: "PRAGMA table_info(\"\(tableName)\")"
            ).compactMap { row -> String? in row["name"] }
            guard !columns.isEmpty,
                  Set(record.keys) == Set(columns),
                  spec.keyColumns.allSatisfy({
                      Self.jsonValuesEqual(key[$0], record[$0])
                  }) else {
                throw ManagedDocumentStoreError.invalidPayload
            }
            if tableName == Self.managedDayOwnershipTable {
                try Self.validateManagedDayOwnership(
                    key: key,
                    record: record
                )
            }

            let values = try columns.map { column in
                try Self.databaseValue(record[column])
            }
            let localKey = try Self.localKey(
                db,
                spec: spec,
                key: key
            )
            let keyJSON = try Self.canonicalJSONObject(key)
            guard let keyText = String(data: keyJSON, encoding: .utf8) else {
                throw ManagedDocumentStoreError.invalidPayload
            }
            let priorDayOwnership: ManagedDayOwnershipValue?
            let incomingDayOwnership: ManagedDayOwnershipValue?
            if tableName == Self.managedDayOwnershipTable,
               let day = key["day"] as? String,
               let deviceId = record["deviceId"] as? String,
               let locked = Self.exactBinaryFlag(record["locked"]) {
                priorDayOwnership = try Self.storedDayOwnership(db, day: day)
                incomingDayOwnership = ManagedDayOwnershipValue(
                    deviceId: deviceId,
                    locked: locked
                )
            } else {
                priorDayOwnership = nil
                incomingDayOwnership = nil
            }
            try Self.discardConflictingDirtyProfiles(
                db,
                tableName: tableName,
                localKey: localKey,
                localProfileID: localProfileID
            )
            try Self.ensureNoUnacknowledgedLocalGeneration(
                db,
                accountScopeHash: accountScopeHash,
                localProfileID: localProfileID,
                tableName: tableName,
                localKey: localKey
            )

            let priorHydrationProjection: ManagedHydrationProjection?
            let newHydrationProjection: ManagedHydrationProjection?
            if tableName == Self.managedHydrationTable {
                priorHydrationProjection = try Self.storedHydrationProjection(
                    db,
                    key: key
                )
                newHydrationProjection = try Self.validatedHydrationProjection(
                    record: record
                )
            } else {
                priorHydrationProjection = nil
                newHydrationProjection = nil
            }

            let quotedColumns = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count)
                .joined(separator: ", ")
            let updates = columns.filter { !spec.keyColumns.contains($0) }.map {
                "\"\($0)\" = excluded.\"\($0)\""
            }.joined(separator: ", ")
            try db.execute(
                sql: """
                    INSERT INTO "\(tableName)" (\(quotedColumns))
                    VALUES (\(placeholders))
                    ON CONFLICT(\(spec.keyColumns.map { "\"\($0)\"" }.joined(separator: ", ")))
                    DO UPDATE SET \(updates)
                """,
                arguments: StatementArguments(values)
            )
            let changed = db.changesCount
            if priorDayOwnership != incomingDayOwnership,
               let day = key["day"] as? String,
               tableName == Self.managedDayOwnershipTable {
                try AnalysisOwnershipInvalidation.mark(
                    db,
                    affectedRange: AnalysisOwnershipInvalidation.dayRange(day)
                )
            }
            for projection in Set(
                [priorHydrationProjection, newHydrationProjection].compactMap { $0 }
            ).sorted(by: {
                ($0.deviceId, $0.day) < ($1.deviceId, $1.day)
            }) {
                try Self.refreshManagedHydrationProjection(
                    db,
                    projection: projection
                )
            }
            try Self.upsertManagedDocumentState(
                db,
                accountScopeHash: accountScopeHash,
                tableName: tableName,
                localKey: localKey,
                documentKind: documentKind,
                documentID: documentID,
                keyJSON: keyText,
                revision: revision,
                contentSHA256: contentSHA256,
                localProfileID: localProfileID,
                updatedAtMs: appliedAtMs
            )
            return ManagedDocumentApplyResult(changedRows: changed, applied: true)
        }
    }

    public func managedDocumentIdentity(
        accountScopeHash: String,
        documentKind: String,
        documentID: String
    ) async throws -> (tableName: String, localKey: String)? {
        guard Self.validAccountScopeHash(accountScopeHash),
              Self.validUUID(documentID) else {
            throw ManagedDocumentStoreError.invalidState
        }
        return try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT tableName, localKey
                FROM managedDocumentState
                WHERE accountScopeHash = ?
                  AND documentKind = ?
                  AND documentId = ?
                """, arguments: [
                    accountScopeHash, documentKind, documentID.lowercased(),
                ]).map { row in
                    (tableName: row["tableName"], localKey: row["localKey"])
                }
        }
    }

    private static func pendingManagedDocumentIdentity(
        _ db: Database,
        accountScopeHash: String,
        localProfileID: String,
        documentKind: String,
        documentID: String
    ) throws -> ManagedPendingDocumentIdentity? {
        for spec in managedDocumentTableSpecs
            where spec.documentKind == documentKind
                && spec.contentMode == .serverReadable {
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT candidate.*,
                           dirty.localKey AS "__managedLocalKey",
                           dirty.generation AS "__managedGeneration"
                    FROM managedDocumentDirty AS dirty
                    JOIN "\(spec.tableName)" AS candidate
                      ON \(spec.localKeySQL(row: "candidate")) = dirty.localKey
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.localProfileId = ?
                      AND dirty.tableName = ?
                      AND dirty.documentKind = ?
                      AND dirty.operation = 'upsert'
                      AND state.documentId IS NULL
                      AND dirty.generation
                          > COALESCE(state.acknowledgedGeneration, 0)
                      AND \(spec.eligibility("candidate"))
                    ORDER BY dirty.localKey
                    """,
                arguments: [
                    accountScopeHash,
                    localProfileID,
                    spec.tableName,
                    spec.documentKind,
                ]
            )
            while let row = try rows.next() {
                let localKey: String = row["__managedLocalKey"]
                let generation: Int64 = row["__managedGeneration"]
                guard generation > 0 else {
                    throw ManagedDocumentStoreError.invalidState
                }
                var record = try jsonRecord(row)
                record.removeValue(forKey: "__managedLocalKey")
                record.removeValue(forKey: "__managedGeneration")
                let key = Dictionary(
                    uniqueKeysWithValues: try spec.keyColumns.map { column in
                        guard let value = record[column] else {
                            throw ManagedDocumentStoreError.invalidPayload
                        }
                        return (column, value)
                    }
                )
                if spec.tableName == managedDayOwnershipTable {
                    try validateManagedDayOwnership(key: key, record: record)
                }
                let keyData = try canonicalJSONObject(key)
                let expectedID = ManagedDocumentStableIdentifier.uuid(
                    documentKind: documentKind,
                    tableName: spec.tableName,
                    keyJSON: keyData
                ).uuidString.lowercased()
                guard expectedID == documentID.lowercased() else { continue }
                guard let keyJSON = String(data: keyData, encoding: .utf8) else {
                    throw ManagedDocumentStoreError.invalidPayload
                }
                return ManagedPendingDocumentIdentity(
                    tableName: spec.tableName,
                    localKey: localKey,
                    keyJSON: keyJSON,
                    generation: generation,
                    operation: .upsert
                )
            }
            if spec.tableName == managedDayOwnershipTable,
               let pendingDelete =
                   try pendingManagedDayOwnershipDeleteIdentity(
                       db,
                       accountScopeHash: accountScopeHash,
                       localProfileID: localProfileID,
                       documentKind: documentKind,
                       documentID: documentID
                   ) {
                return pendingDelete
            }
        }
        return nil
    }

    private static func pendingManagedDayOwnershipDeleteIdentity(
        _ db: Database,
        accountScopeHash: String,
        localProfileID: String,
        documentKind: String,
        documentID: String
    ) throws -> ManagedPendingDocumentIdentity? {
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT dirty.localKey, dirty.generation
                FROM managedDocumentDirty AS dirty
                LEFT JOIN managedDocumentState AS state
                  ON state.accountScopeHash = ?
                 AND state.tableName = dirty.tableName
                 AND state.localKey = dirty.localKey
                WHERE dirty.localProfileId = ?
                  AND dirty.tableName = ?
                  AND dirty.documentKind = ?
                  AND dirty.operation = 'delete'
                  AND state.documentId IS NULL
                  AND dirty.generation
                      > COALESCE(state.acknowledgedGeneration, 0)
                ORDER BY dirty.localKey
                """,
            arguments: [
                accountScopeHash,
                localProfileID,
                managedDayOwnershipTable,
                managedDayOwnershipKind,
            ]
        )
        while let row = try rows.next() {
            let localKey: String = row["localKey"]
            let generation: Int64 = row["generation"]
            guard generation > 0,
                  let keyData = try managedDayOwnershipKeyJSON(
                      from: localKey
                  ) else {
                continue
            }
            let expectedID = ManagedDocumentStableIdentifier.uuid(
                documentKind: documentKind,
                tableName: managedDayOwnershipTable,
                keyJSON: keyData
            ).uuidString.lowercased()
            guard expectedID == documentID.lowercased(),
                  let keyJSON = String(data: keyData, encoding: .utf8) else {
                continue
            }
            return ManagedPendingDocumentIdentity(
                tableName: managedDayOwnershipTable,
                localKey: localKey,
                keyJSON: keyJSON,
                generation: generation,
                operation: .delete
            )
        }
        return nil
    }

    private static func seedManagedDocumentTombstoneRevision(
        _ db: Database,
        accountScopeHash: String,
        pending: ManagedPendingDocumentIdentity,
        documentKind: String,
        documentID: String,
        revision: Int64,
        contentSHA256: String,
        updatedAtMs: Int64
    ) throws {
        guard pending.generation > 0 else {
            throw ManagedDocumentStoreError.invalidState
        }
        let existingDocumentID = try String.fetchOne(
            db,
            sql: """
                SELECT documentId
                FROM managedDocumentState
                WHERE accountScopeHash = ?
                  AND tableName = ?
                  AND localKey = ?
                """,
            arguments: [
                accountScopeHash,
                pending.tableName,
                pending.localKey,
            ]
        )
        guard existingDocumentID == nil else {
            throw ManagedDocumentStoreError.invalidState
        }
        let acknowledgedGeneration: Int64
        switch pending.operation {
        case .upsert:
            acknowledgedGeneration = 0
        case .delete:
            acknowledgedGeneration = pending.generation
        }
        try db.execute(
            sql: """
                INSERT INTO managedDocumentState (
                    accountScopeHash, tableName, localKey, documentKind,
                    documentId, keyJSON, acknowledgedGeneration, remoteRevision,
                    remoteContentSHA256, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                accountScopeHash,
                pending.tableName,
                pending.localKey,
                documentKind,
                documentID.lowercased(),
                pending.keyJSON,
                acknowledgedGeneration,
                revision,
                contentSHA256,
                updatedAtMs,
            ]
        )
    }

    private static func managedDayOwnershipKeyJSON(
        from localKey: String
    ) throws -> Data? {
        guard let day = managedDayOwnershipDay(from: localKey) else {
            return nil
        }
        return try canonicalJSONObject(["day": day])
    }

    private static func managedDayOwnershipDay(from localKey: String) -> String? {
        let encoded = Array(localKey.utf8)
        guard encoded.count == 20 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.count / 2)
        for offset in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = hexNibble(encoded[offset]),
                  let low = hexNibble(encoded[offset + 1]) else {
                return nil
            }
            bytes.append((high << 4) | low)
        }
        let data = Data(bytes)
        guard let day = String(data: data, encoding: .utf8),
              Data(day.utf8) == data,
              civilDayStartSeconds(day) != nil else {
            return nil
        }
        return day
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

    private static func managedTombstoneSHA256(
        documentKind: String,
        documentID: String,
        revision: Int64
    ) -> String {
        SHA256.hash(
            data: Data(
                (
                    "deleted:\(documentKind):"
                        + "\(documentID.lowercased()):\(revision)"
                ).utf8
            )
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasUnacknowledgedLocalGeneration(
        _ db: Database,
        accountScopeHash: String,
        localProfileID: String,
        tableName: String,
        localKey: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM managedDocumentDirty AS dirty
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.localProfileId = ?
                      AND dirty.tableName = ?
                      AND dirty.localKey = ?
                      AND dirty.generation
                          > COALESCE(state.acknowledgedGeneration, 0)
                )
                """,
            arguments: [
                accountScopeHash,
                localProfileID,
                tableName,
                localKey,
            ]
        ) ?? false
    }

    private static func ensureNoUnacknowledgedLocalGeneration(
        _ db: Database,
        accountScopeHash: String,
        localProfileID: String,
        tableName: String,
        localKey: String
    ) throws {
        guard try !hasUnacknowledgedLocalGeneration(
            db,
            accountScopeHash: accountScopeHash,
            localProfileID: localProfileID,
            tableName: tableName,
            localKey: localKey
        ) else {
            throw ManagedDocumentStoreError.unacknowledgedLocalGeneration
        }
    }

    private static func upsertManagedDocumentState(
        _ db: Database,
        accountScopeHash: String,
        tableName: String,
        localKey: String,
        documentKind: String,
        documentID: String,
        keyJSON: String,
        revision: Int64,
        contentSHA256: String,
        localProfileID: String,
        updatedAtMs: Int64
    ) throws {
        let generation = try Int64.fetchOne(
            db,
            sql: """
                SELECT generation FROM managedDocumentDirty
                WHERE localProfileId = ?
                  AND tableName = ?
                  AND localKey = ?
                """,
            arguments: [localProfileID, tableName, localKey]
        ) ?? 0
        try db.execute(sql: """
            INSERT INTO managedDocumentState (
                accountScopeHash, tableName, localKey, documentKind,
                documentId, keyJSON, acknowledgedGeneration, remoteRevision,
                remoteContentSHA256, updatedAtMs
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accountScopeHash, tableName, localKey) DO UPDATE SET
                documentKind = excluded.documentKind,
                documentId = excluded.documentId,
                keyJSON = excluded.keyJSON,
                acknowledgedGeneration = excluded.acknowledgedGeneration,
                remoteRevision = excluded.remoteRevision,
                remoteContentSHA256 = excluded.remoteContentSHA256,
                updatedAtMs = excluded.updatedAtMs
            """, arguments: [
                accountScopeHash,
                tableName,
                localKey,
                documentKind,
                documentID.lowercased(),
                keyJSON,
                generation,
                revision,
                contentSHA256,
                updatedAtMs,
            ])
    }

    private static func jsonRecord(_ row: Row) throws -> [String: Any] {
        var object: [String: Any] = [:]
        for column in row.columnNames {
            let value: DatabaseValue = row[column]
            switch value.storage {
            case .null:
                object[column] = NSNull()
            case .int64(let value):
                object[column] = value
            case .double(let value):
                guard value.isFinite else {
                    throw ManagedDocumentStoreError.invalidPayload
                }
                object[column] = value
            case .string(let value):
                object[column] = value
            case .blob:
                throw ManagedDocumentStoreError.invalidPayload
            }
        }
        return object
    }

    private static func validateManagedDayOwnership(
        key: [String: Any],
        record: [String: Any]
    ) throws {
        guard key.keys.count == 1,
              let keyDay = key["day"] as? String,
              let recordDay = record["day"] as? String,
              keyDay == recordDay,
              civilDayStartSeconds(keyDay) != nil,
              let deviceID = record["deviceId"] as? String else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        let trimmedDeviceID = deviceID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard deviceID == trimmedDeviceID,
              !deviceID.isEmpty,
              deviceID.utf8.count <= managedDayOwnershipMaximumDeviceIDBytes,
              !deviceID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              exactBinaryFlag(record["locked"]) != nil else {
            throw ManagedDocumentStoreError.invalidPayload
        }
    }

    private static func storedDayOwnership(
        _ db: Database,
        day: String
    ) throws -> ManagedDayOwnershipValue? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT deviceId, locked
                FROM dayOwnership
                WHERE day = ?
                """,
            arguments: [day]
        ).map {
            ManagedDayOwnershipValue(
                deviceId: $0["deviceId"],
                locked: $0["locked"]
            )
        }
    }

    private static func validatedHydrationProjection(
        record: [String: Any]
    ) throws -> ManagedHydrationProjection {
        guard let id = record["id"] as? String,
              validUUID(id),
              let deviceId = record["deviceId"] as? String,
              deviceId == managedHydrationDevice,
              let day = record["day"] as? String,
              let dayStart = civilDayStartSeconds(day),
              let amountML = exactInt64(record["amountML"]),
              (1...managedHydrationMaximumAmountML).contains(amountML),
              let loggedAt = exactInt64(record["loggedAt"]),
              (dayStart - 14 * 60 * 60..<dayStart + 36 * 60 * 60)
                  .contains(loggedAt) else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        return ManagedHydrationProjection(deviceId: deviceId, day: day)
    }

    private static func storedHydrationProjection(
        _ db: Database,
        key: [String: Any]
    ) throws -> ManagedHydrationProjection? {
        guard let id = key["id"] as? String, !id.isEmpty else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        return try Row.fetchOne(
            db,
            sql: """
                SELECT deviceId, day
                FROM hydrationEntry
                WHERE id = ?
                """,
            arguments: [id]
        ).map {
            try storedHydrationProjection(row: $0)
        }
    }

    private static func storedHydrationProjection(
        _ db: Database,
        localKey: String,
        spec: ManagedDocumentTableSpec
    ) throws -> ManagedHydrationProjection? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT deviceId, day
                FROM hydrationEntry AS candidate
                WHERE \(spec.localKeySQL(row: "candidate")) = ?
                """,
            arguments: [localKey]
        ).map {
            try storedHydrationProjection(row: $0)
        }
    }

    private static func storedHydrationProjection(
        row: Row
    ) throws -> ManagedHydrationProjection {
        let deviceId: String = row["deviceId"]
        let day: String = row["day"]
        guard deviceId == managedHydrationDevice,
              civilDayStartSeconds(day) != nil else {
            throw ManagedDocumentStoreError.invalidState
        }
        return ManagedHydrationProjection(deviceId: deviceId, day: day)
    }

    private static func refreshManagedHydrationProjection(
        _ db: Database,
        projection: ManagedHydrationProjection
    ) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO managedPruneGuard (guardId) VALUES (1)"
        )
        let ownsGuard = db.changesCount > 0
        defer {
            if ownsGuard {
                try? db.execute(
                    sql: "DELETE FROM managedPruneGuard WHERE guardId = 1"
                )
            }
        }

        let total = try Double.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(CAST(amountML AS REAL)), 0.0)
                FROM hydrationEntry
                WHERE deviceId = ? AND day = ?
                """,
            arguments: [projection.deviceId, projection.day]
        ) ?? 0
        guard total.isFinite, total >= 0 else {
            throw ManagedDocumentStoreError.invalidState
        }
        try db.execute(
            sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET
                    value = excluded.value
                """,
            arguments: [
                projection.deviceId,
                projection.day,
                managedHydrationMetricKey,
                total,
            ]
        )
    }

    private static func exactBinaryFlag(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? 1 : 0
        }
        guard let integer = exactInt64(value),
              integer == 0 || integer == 1 else {
            return nil
        }
        return integer
    }

    private static func exactInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        var decimal = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        guard rounded == decimal else { return nil }

        let decimalNumber = NSDecimalNumber(decimal: decimal)
        guard decimalNumber.compare(NSDecimalNumber(value: Int64.min))
                != .orderedAscending,
              decimalNumber.compare(NSDecimalNumber(value: Int64.max))
                != .orderedDescending else {
            return nil
        }
        let integer = decimalNumber.int64Value
        guard NSDecimalNumber(value: integer).compare(decimalNumber)
                == .orderedSame else {
            return nil
        }
        return integer
    }

    private static func civilDayStartSeconds(_ value: String) -> Int64? {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              (2000...2099).contains(year) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return nil
        }
        let normalized = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day else {
            return nil
        }
        return Int64(date.timeIntervalSince1970)
    }

    private static func canonicalJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func databaseValue(_ value: Any?) throws -> DatabaseValue {
        guard let value, !(value is NSNull) else { return .null }
        if let value = value as? String { return value.databaseValue }
        guard let number = value as? NSNumber else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return (number.boolValue ? Int64(1) : Int64(0)).databaseValue
        }
        var decimal = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        if rounded == decimal {
            guard let integer = exactInt64(number) else {
                throw ManagedDocumentStoreError.invalidPayload
            }
            return integer.databaseValue
        }
        let double = number.doubleValue
        guard double.isFinite else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        return double.databaseValue
    }

    private static func localKey(
        _ db: Database,
        spec: ManagedDocumentTableSpec,
        key: [String: Any]
    ) throws -> String {
        let values = try spec.keyColumns.map { try databaseValue(key[$0]) }
        guard let value = try String.fetchOne(
            db,
            sql: """
                SELECT \(spec.keyColumns.map { _ in
                    "hex(CAST(? AS BLOB))"
                }.joined(separator: " || ':' || "))
                """,
            arguments: StatementArguments(values)
        ), !value.isEmpty else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        return value
    }

    private static func jsonValuesEqual(_ left: Any?, _ right: Any?) -> Bool {
        if left is NSNull, right is NSNull { return true }
        if let left = left as? String, let right = right as? String {
            return left == right
        }
        if let left = left as? NSNumber, let right = right as? NSNumber {
            let leftIsBoolean = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBoolean = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBoolean == rightIsBoolean else { return false }
            if leftIsBoolean {
                return left.boolValue == right.boolValue
            }
            return left.decimalValue == right.decimalValue
        }
        return false
    }

    private static func validAccountScopeHash(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func managedNowMilliseconds() -> Int64 {
        max(
            0,
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        )
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func validUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

public enum ManagedDocumentStoreError: Error, Equatable {
    case invalidPayload
    case invalidState
    case payloadTooLarge
    case unacknowledgedLocalGeneration
}
