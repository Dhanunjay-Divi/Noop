import Foundation
import GRDB

public enum CoachStoreContract {
    public static let maxMessages = 40
    public static let maxMessageCharacters = 16_000
    public static let maxMemoryCharacters = 500
    public static let maxMemories = 50
    public static let roles: Set<String> = ["user", "assistant"]

    public enum ValidationError: Error, Equatable {
        case invalidID
        case invalidRole
        case invalidText
        case invalidTimestamp
        case tooManyMemories
    }

    public static func validated(_ row: CoachMessageRow) throws -> CoachMessageRow {
        let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128 else { throw ValidationError.invalidID }
        guard roles.contains(row.role) else { throw ValidationError.invalidRole }
        guard !text.isEmpty, text.count <= maxMessageCharacters else {
            throw ValidationError.invalidText
        }
        guard row.createdAt > 0 else { throw ValidationError.invalidTimestamp }
        return CoachMessageRow(id: id, createdAt: row.createdAt, role: row.role, text: text)
    }

    public static func validated(_ row: CoachMemoryRow) throws -> CoachMemoryRow {
        let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128 else { throw ValidationError.invalidID }
        guard !text.isEmpty, text.count <= maxMemoryCharacters else {
            throw ValidationError.invalidText
        }
        guard row.createdAt > 0, row.updatedAt >= row.createdAt else {
            throw ValidationError.invalidTimestamp
        }
        return CoachMemoryRow(
            id: id,
            text: text,
            enabled: row.enabled,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }
}

public struct CoachMessageRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let createdAt: Int64
    public let role: String
    public let text: String

    public init(id: String, createdAt: Int64, role: String, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.text = text
    }
}

public struct CoachMemoryRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let enabled: Bool
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(id: String, text: String, enabled: Bool, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.text = text
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension WhoopStore {
    /// Insert one turn and prune the transcript in the same write transaction.
    func appendCoachMessage(
        _ raw: CoachMessageRow,
        limit: Int = CoachStoreContract.maxMessages
    ) async throws {
        let row = try CoachStoreContract.validated(raw)
        let boundedLimit = min(max(1, limit), CoachStoreContract.maxMessages)
        try syncWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO coachMessage (id, createdAt, role, text)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        createdAt = excluded.createdAt,
                        role = excluded.role,
                        text = excluded.text
                    """,
                arguments: [row.id, row.createdAt, row.role, row.text]
            )
            try db.execute(
                sql: """
                    DELETE FROM coachMessage
                    WHERE id NOT IN (
                        SELECT id FROM coachMessage
                        ORDER BY createdAt DESC, id DESC
                        LIMIT ?
                    )
                    """,
                arguments: [boundedLimit]
            )
        }
    }

    /// Newest bounded window, returned oldest-first for direct chat rendering.
    func coachMessages(limit: Int = CoachStoreContract.maxMessages) async throws -> [CoachMessageRow] {
        let boundedLimit = min(max(0, limit), CoachStoreContract.maxMessages)
        guard boundedLimit > 0 else { return [] }
        return try syncRead { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, createdAt, role, text FROM (
                        SELECT id, createdAt, role, text FROM coachMessage
                        ORDER BY createdAt DESC, id DESC
                        LIMIT ?
                    )
                    ORDER BY createdAt ASC, id ASC
                    """,
                arguments: [boundedLimit]
            ).map {
                CoachMessageRow(
                    id: $0["id"],
                    createdAt: $0["createdAt"],
                    role: $0["role"],
                    text: $0["text"]
                )
            }
        }
    }

    @discardableResult
    func clearCoachMessages() async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMessage")
            return db.changesCount
        }
    }

    func upsertCoachMemory(_ raw: CoachMemoryRow) async throws {
        let row = try CoachStoreContract.validated(raw)
        try syncWrite { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM coachMemory WHERE id = ?",
                arguments: [row.id]
            ) ?? 0
            if exists == 0 {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coachMemory") ?? 0
                guard count < CoachStoreContract.maxMemories else {
                    throw CoachStoreContract.ValidationError.tooManyMemories
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO coachMemory (id, text, enabled, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text,
                        enabled = excluded.enabled,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    row.id, row.text, row.enabled ? 1 : 0, row.createdAt, row.updatedAt,
                ]
            )
        }
    }

    func coachMemories(includeDisabled: Bool = true) async throws -> [CoachMemoryRow] {
        try syncRead { db in
            let predicate = includeDisabled ? "" : "WHERE enabled = 1"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, text, enabled, createdAt, updatedAt
                    FROM coachMemory \(predicate)
                    ORDER BY updatedAt DESC, id DESC
                    """
            ).map {
                CoachMemoryRow(
                    id: $0["id"],
                    text: $0["text"],
                    enabled: ($0["enabled"] as Int) != 0,
                    createdAt: $0["createdAt"],
                    updatedAt: $0["updatedAt"]
                )
            }
        }
    }

    @discardableResult
    func deleteCoachMemory(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMemory WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
