import CoreFoundation
import Foundation
import GRDB

/// One durable, account-scoped document mutation waiting for NOOP+.
///
/// Payloads use a small cross-platform envelope instead of a database dump. Only allowlisted
/// user-authored tables are represented, and every restore validates the complete column set before
/// opening a write transaction.
public struct ManagedLocalDocumentCandidate: Equatable, Sendable {
    public let tableName: String
    public let documentKind: String
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
    let keyColumns: [String]
    let eligibility: (String) -> String

    init(
        tableName: String,
        documentKind: String,
        keyColumns: [String],
        eligibility: @escaping (String) -> String = { _ in "1" }
    ) {
        self.tableName = tableName
        self.documentKind = documentKind
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
            tableName: "dayOwnership",
            documentKind: "day_ownership",
            keyColumns: ["day"]
        ),
    ]

    static let managedPreferencesTable = "preferences"
    static let managedPreferencesKey = "global"
    static let managedPreferencesKind = "preferences"

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

        let now = "CAST(strftime('%s', 'now') AS INTEGER) * 1000"
        for spec in managedDocumentTableSpecs {
            let table = spec.tableName
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
                CREATE TRIGGER "managed_document_\(table)_insert"
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
                CREATE TRIGGER "managed_document_\(table)_delete"
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
                CREATE TRIGGER "managed_document_\(table)_update"
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
            let existing: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT payloadJSON FROM managedDocumentDirty
                    WHERE tableName = ? AND localKey = ?
                    """,
                arguments: [Self.managedPreferencesTable, Self.managedPreferencesKey]
            )
            guard existing != text else { return }
            try db.execute(sql: """
                INSERT INTO managedDocumentDirty (
                    tableName, localKey, documentKind, generation,
                    operation, updatedAtMs, payloadJSON
                ) VALUES (?, ?, ?, 1, 'upsert', ?, ?)
                ON CONFLICT(tableName, localKey) DO UPDATE SET
                    documentKind = excluded.documentKind,
                    generation = managedDocumentDirty.generation + 1,
                    operation = 'upsert',
                    updatedAtMs = excluded.updatedAtMs,
                    payloadJSON = excluded.payloadJSON
                """, arguments: [
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
        limit: Int
    ) async throws -> [ManagedLocalDocumentCandidate] {
        guard Self.validAccountScopeHash(accountScopeHash),
              (1...500).contains(limit) else {
            throw ManagedDocumentStoreError.invalidState
        }
        return try syncRead { db in
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
                WHERE (
                    state.acknowledgedGeneration IS NULL
                    OR state.acknowledgedGeneration < dirty.generation
                )
                  AND (
                    dirty.operation != 'delete'
                    OR COALESCE(state.remoteRevision, 0) > 0
                  )
                ORDER BY dirty.updatedAtMs, dirty.tableName, dirty.localKey
                LIMIT ?
                """, arguments: [accountScopeHash, limit])

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
                        tableName: tableName,
                        documentKind: documentKind,
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
                }) else {
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
                        tableName: tableName,
                        documentKind: documentKind,
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
                    tableName: tableName,
                    documentKind: documentKind,
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
                    updatedAtMs: appliedAtMs
                )
                return ManagedDocumentApplyResult(
                    changedRows: 0,
                    applied: true
                )
            }

            if deleted {
                guard let state = try Row.fetchOne(db, sql: """
                    SELECT tableName, localKey, keyJSON
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND documentKind = ?
                      AND documentId = ?
                    """, arguments: [
                        accountScopeHash, documentKind, documentID.lowercased(),
                    ]) else {
                    return ManagedDocumentApplyResult(changedRows: 0, applied: true)
                }
                let tableName: String = state["tableName"]
                let localKey: String = state["localKey"]
                guard let spec = Self.managedDocumentTableSpecs.first(where: {
                    $0.tableName == tableName && $0.documentKind == documentKind
                }) else {
                    throw ManagedDocumentStoreError.invalidState
                }
                try db.execute(
                    sql: """
                        DELETE FROM "\(tableName)"
                        WHERE \(spec.localKeySQL(row: tableName)) = ?
                        """,
                    arguments: [localKey]
                )
                let changed = db.changesCount
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
                    updatedAtMs: appliedAtMs
                )
                return ManagedDocumentApplyResult(changedRows: changed, applied: true)
            }

            guard let payloadJSON,
                  payloadJSON.count <= 1_000_000,
                  let envelope = try JSONSerialization.jsonObject(
                    with: payloadJSON
                  ) as? [String: Any],
                  (envelope["schema_version"] as? NSNumber)?.intValue == 1,
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

            let values = try columns.map { column in
                try Self.databaseValue(record[column])
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
            let localKey = try Self.localKey(
                db,
                tableName: tableName,
                spec: spec,
                key: key
            )
            let keyJSON = try Self.canonicalJSONObject(key)
            guard let keyText = String(data: keyJSON, encoding: .utf8) else {
                throw ManagedDocumentStoreError.invalidPayload
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
        updatedAtMs: Int64
    ) throws {
        let generation = try Int64.fetchOne(
            db,
            sql: """
                SELECT generation FROM managedDocumentDirty
                WHERE tableName = ? AND localKey = ?
                """,
            arguments: [tableName, localKey]
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
        let double = number.doubleValue
        guard double.isFinite else {
            throw ManagedDocumentStoreError.invalidPayload
        }
        if floor(double) == double,
           double >= Double(Int64.min),
           double <= Double(Int64.max) {
            return number.int64Value.databaseValue
        }
        return double.databaseValue
    }

    private static func localKey(
        _ db: Database,
        tableName: String,
        spec: ManagedDocumentTableSpec,
        key: [String: Any]
    ) throws -> String {
        let predicates = spec.keyColumns.map { "\"\($0)\" IS ?" }.joined(separator: " AND ")
        let values = try spec.keyColumns.map { try databaseValue(key[$0]) }
        guard let value = try String.fetchOne(
            db,
            sql: """
                SELECT \(spec.localKeySQL(row: "candidate"))
                FROM "\(tableName)" AS candidate
                WHERE \(predicates)
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
            return left.compare(right) == .orderedSame
        }
        return false
    }

    private static func validAccountScopeHash(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
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
}
