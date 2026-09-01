import Foundation
import GRDB

/// Open, cross-platform records that do not fit the WHOOP-shaped CSV files in NOOP's portable ZIP.
///
/// This is deliberately a small, versioned JSON contract rather than a database dump:
/// - every field is readable without NOOP;
/// - nullable nutrition values stay nullable;
/// - strength relationships remain normalized and lossless;
/// - Apple and Android validate the complete graph before either writes a row.
public struct PortableUserData: Codable, Equatable, Sendable {
    public static let fileName = "noop_user_data.json"
    public static let formatID = "noop.user-data"
    public static let currentSchemaVersion = 2
    public static let oldestSupportedSchemaVersion = 1
    public static let maxFileBytes = 64 << 20

    public var format: String
    public var schemaVersion: Int
    public var exportedAt: Int
    public var nutritionEntries: [NutritionEntryRow]
    public var nutritionCatalogItems: [NutritionCatalogItemRow]
    public var strengthExercises: [PortableStrengthExercise]
    public var strengthRoutines: [StrengthRoutineRow]
    public var strengthRoutineExercises: [StrengthRoutineExerciseRow]
    public var strengthSessions: [StrengthSessionRow]
    public var strengthSets: [StrengthSetRow]

    public init(
        exportedAt: Int = Int(Date().timeIntervalSince1970),
        nutritionEntries: [NutritionEntryRow],
        nutritionCatalogItems: [NutritionCatalogItemRow] = [],
        strengthExercises: [StrengthExerciseRow],
        strengthRoutines: [StrengthRoutineRow],
        strengthRoutineExercises: [StrengthRoutineExerciseRow],
        strengthSessions: [StrengthSessionRow],
        strengthSets: [StrengthSetRow]
    ) throws {
        self.format = Self.formatID
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.nutritionEntries = nutritionEntries
        self.nutritionCatalogItems = nutritionCatalogItems
        self.strengthExercises = try strengthExercises.map(PortableStrengthExercise.init)
        self.strengthRoutines = strengthRoutines
        self.strengthRoutineExercises = strengthRoutineExercises
        self.strengthSessions = strengthSessions
        self.strengthSets = strengthSets
        self = try validated()
    }

    /// Build the flat portable graph from the store's atomic routine/session snapshots.
    public init(
        exportedAt: Int = Int(Date().timeIntervalSince1970),
        nutritionEntries: [NutritionEntryRow],
        nutritionCatalogItems: [NutritionCatalogItemRow] = [],
        strengthExercises: [StrengthExerciseRow],
        strengthRoutineSnapshots: [StrengthRoutineSnapshot],
        strengthSessionSnapshots: [StrengthSessionSnapshot]
    ) throws {
        try self.init(
            exportedAt: exportedAt,
            nutritionEntries: nutritionEntries,
            nutritionCatalogItems: nutritionCatalogItems,
            strengthExercises: strengthExercises,
            strengthRoutines: strengthRoutineSnapshots.map(\.routine),
            strengthRoutineExercises: strengthRoutineSnapshots.flatMap(\.exercises),
            strengthSessions: strengthSessionSnapshots.map(\.session),
            strengthSets: strengthSessionSnapshots.flatMap(\.sets)
        )
    }

    public func encodedData() throws -> Data {
        let clean = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(clean)
    }

    public static func decode(_ data: Data) throws -> PortableUserData {
        guard data.count <= maxFileBytes else {
            throw PortableUserDataError.fileTooLarge(data.count)
        }
        do {
            return try JSONDecoder().decode(PortableUserData.self, from: data).validated()
        } catch let error as PortableUserDataError {
            throw error
        } catch {
            throw PortableUserDataError.invalidJSON(error.localizedDescription)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion
        case exportedAt
        case nutritionEntries
        case nutritionCatalogItems
        case strengthExercises
        case strengthRoutines
        case strengthRoutineExercises
        case strengthSessions
        case strengthSets
    }

    /// Schema 1 predates the food/meal catalog. Missing catalog rows decode as an empty collection;
    /// validation then upgrades the in-memory payload to the current schema before any write.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try values.decode(Int.self, forKey: .exportedAt)
        nutritionEntries = try values.decode([NutritionEntryRow].self, forKey: .nutritionEntries)
        nutritionCatalogItems = try values.decodeIfPresent(
            [NutritionCatalogItemRow].self,
            forKey: .nutritionCatalogItems
        ) ?? []
        strengthExercises = try values.decode(
            [PortableStrengthExercise].self,
            forKey: .strengthExercises
        )
        strengthRoutines = try values.decode([StrengthRoutineRow].self, forKey: .strengthRoutines)
        strengthRoutineExercises = try values.decode(
            [StrengthRoutineExerciseRow].self,
            forKey: .strengthRoutineExercises
        )
        strengthSessions = try values.decode([StrengthSessionRow].self, forKey: .strengthSessions)
        strengthSets = try values.decode([StrengthSetRow].self, forKey: .strengthSets)
    }

    public var recordCount: Int {
        nutritionEntries.count
            + nutritionCatalogItems.count
            + strengthExercises.count
            + strengthRoutines.count
            + strengthRoutineExercises.count
            + strengthSessions.count
            + strengthSets.count
    }

    public var earliestDate: Date? {
        let seconds = nutritionEntries.map(\.occurredAt) + strengthSessions.map(\.startedAt)
        return seconds.min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var latestDate: Date? {
        let seconds = nutritionEntries.map(\.occurredAt)
            + strengthSessions.map { $0.endedAt ?? $0.startedAt }
        return seconds.max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Returns a normalized, deterministically ordered copy after validating every row and relation.
    public func validated() throws -> PortableUserData {
        guard format == Self.formatID else {
            throw PortableUserDataError.unsupportedFormat(format)
        }
        guard (Self.oldestSupportedSchemaVersion...Self.currentSchemaVersion)
            .contains(schemaVersion)
        else {
            throw PortableUserDataError.unsupportedSchema(schemaVersion)
        }
        guard exportedAt > 0 else { throw PortableUserDataError.invalidExportedAt }

        let counts = [
            nutritionEntries.count,
            nutritionCatalogItems.count,
            strengthExercises.count,
            strengthRoutines.count,
            strengthRoutineExercises.count,
            strengthSessions.count,
            strengthSets.count,
        ]
        guard counts.allSatisfy({ $0 <= Self.maxRowsPerCollection }),
              counts.reduce(0, +) <= Self.maxTotalRows
        else { throw PortableUserDataError.tooManyRows }

        let cleanNutrition = try nutritionEntries.map(NutritionLogContract.validated)
        let cleanCatalog = try nutritionCatalogItems.map(NutritionCatalogContract.validated)
        let cleanExerciseRows = try strengthExercises.map { try StrengthTrainingContract.validated($0.row) }
        let cleanExercises = try cleanExerciseRows.map(PortableStrengthExercise.init)
        let cleanRoutines = try strengthRoutines.map(StrengthTrainingContract.validated)
        let cleanRoutineExercises = try strengthRoutineExercises.map(StrengthTrainingContract.validated)
        let cleanSessions = try strengthSessions.map(StrengthTrainingContract.validated)
        let cleanSets = try strengthSets.map(StrengthTrainingContract.validated)

        try Self.requireUniqueIDs(cleanNutrition.map(\.id), category: "nutritionEntries")
        try Self.requireUniqueIDs(cleanCatalog.map(\.id), category: "nutritionCatalogItems")
        let catalogBarcodes = cleanCatalog.compactMap(\.barcode)
        guard Set(catalogBarcodes).count == catalogBarcodes.count else {
            throw PortableUserDataError.duplicateID("nutritionCatalogItems.barcode")
        }
        try Self.requireUniqueIDs(cleanExercises.map(\.id), category: "strengthExercises")
        try Self.requireUniqueIDs(cleanRoutines.map(\.id), category: "strengthRoutines")
        try Self.requireUniqueIDs(cleanRoutineExercises.map(\.id), category: "strengthRoutineExercises")
        try Self.requireUniqueIDs(cleanSessions.map(\.id), category: "strengthSessions")
        try Self.requireUniqueIDs(cleanSets.map(\.id), category: "strengthSets")

        let exerciseIDs = Set(cleanExercises.map(\.id))
        let routineIDs = Set(cleanRoutines.map(\.id))
        let sessionIDs = Set(cleanSessions.map(\.id))

        var routinePositions = Set<RoutinePosition>()
        for row in cleanRoutineExercises {
            guard routineIDs.contains(row.routineId), exerciseIDs.contains(row.exerciseId) else {
                throw PortableUserDataError.brokenRelationship("strengthRoutineExercises")
            }
            guard routinePositions.insert(
                RoutinePosition(routineId: row.routineId, position: row.position)
            ).inserted else {
                throw PortableUserDataError.duplicatePosition("strengthRoutineExercises")
            }
        }
        for row in cleanSessions {
            if let routineId = row.routineId, !routineIDs.contains(routineId) {
                throw PortableUserDataError.brokenRelationship("strengthSessions")
            }
        }
        var setPositions = Set<SetPosition>()
        for row in cleanSets {
            guard sessionIDs.contains(row.sessionId), exerciseIDs.contains(row.exerciseId) else {
                throw PortableUserDataError.brokenRelationship("strengthSets")
            }
            guard setPositions.insert(
                SetPosition(
                    sessionId: row.sessionId,
                    exercisePosition: row.exercisePosition,
                    setPosition: row.setPosition
                )
            ).inserted else {
                throw PortableUserDataError.duplicatePosition("strengthSets")
            }
        }

        var clean = self
        clean.schemaVersion = Self.currentSchemaVersion
        clean.nutritionEntries = cleanNutrition.sorted {
            ($0.day, $0.occurredAt, $0.id) < ($1.day, $1.occurredAt, $1.id)
        }
        clean.nutritionCatalogItems = cleanCatalog.sorted { $0.id < $1.id }
        clean.strengthExercises = cleanExercises.sorted { $0.id < $1.id }
        clean.strengthRoutines = cleanRoutines.sorted { $0.id < $1.id }
        clean.strengthRoutineExercises = cleanRoutineExercises.sorted {
            ($0.routineId, $0.position, $0.id) < ($1.routineId, $1.position, $1.id)
        }
        clean.strengthSessions = cleanSessions.sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }
        clean.strengthSets = cleanSets.sorted {
            ($0.sessionId, $0.exercisePosition, $0.setPosition, $0.id)
                < ($1.sessionId, $1.exercisePosition, $1.setPosition, $1.id)
        }
        return clean
    }

    private static let maxRowsPerCollection = 500_000
    private static let maxTotalRows = 1_000_000

    private static func requireUniqueIDs(_ ids: [String], category: String) throws {
        guard Set(ids).count == ids.count else {
            throw PortableUserDataError.duplicateID(category)
        }
    }

    private struct RoutinePosition: Hashable {
        let routineId: String
        let position: Int
    }

    private struct SetPosition: Hashable {
        let sessionId: String
        let exercisePosition: Int
        let setPosition: Int
    }
}

/// Human-readable exercise shape. The storage-only JSON string becomes an actual JSON array.
public struct PortableStrengthExercise: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var primaryMuscle: String
    public var secondaryMuscles: [String]
    public var equipment: String
    public var movementPattern: String
    public var isCustom: Bool
    public var archivedAt: Int?
    public var createdAt: Int
    public var updatedAt: Int

    public init(_ row: StrengthExerciseRow) throws {
        guard let secondary = StrengthTrainingContract.secondaryMuscles(
            from: row.secondaryMusclesJSON
        ) else { throw PortableUserDataError.invalidSecondaryMuscles(row.id) }
        id = row.id
        name = row.name
        primaryMuscle = row.primaryMuscle
        secondaryMuscles = secondary
        equipment = row.equipment
        movementPattern = row.movementPattern
        isCustom = row.isCustom
        archivedAt = row.archivedAt
        createdAt = row.createdAt
        updatedAt = row.updatedAt
    }

    public var row: StrengthExerciseRow {
        StrengthExerciseRow(
            id: id,
            name: name,
            primaryMuscle: primaryMuscle,
            secondaryMusclesJSON: StrengthTrainingContract.encodeMuscles(secondaryMuscles),
            equipment: equipment,
            movementPattern: movementPattern,
            isCustom: isCustom,
            archivedAt: archivedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum PortableUserDataError: Error, Equatable, LocalizedError {
    case fileTooLarge(Int)
    case invalidJSON(String)
    case unsupportedFormat(String)
    case unsupportedSchema(Int)
    case invalidExportedAt
    case tooManyRows
    case duplicateID(String)
    case duplicatePosition(String)
    case brokenRelationship(String)
    case invalidSecondaryMuscles(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "NOOP user data is larger than the supported 64 MB portable-data limit."
        case .invalidJSON:
            return "NOOP user data contains invalid JSON or field types."
        case .unsupportedFormat:
            return "This file is not a supported NOOP portable-data export."
        case .unsupportedSchema(let version):
            return "This NOOP user-data schema (\(version)) is not supported by this app version."
        case .invalidExportedAt:
            return "NOOP user data has an invalid export timestamp."
        case .tooManyRows:
            return "NOOP user data exceeds the supported record limit."
        case .duplicateID(let category):
            return "NOOP user data contains duplicate identifiers in \(category)."
        case .duplicatePosition(let category):
            return "NOOP user data contains duplicate ordered positions in \(category)."
        case .brokenRelationship(let category):
            return "NOOP user data contains a broken relationship in \(category)."
        case .invalidSecondaryMuscles(let id):
            return "NOOP user data contains invalid secondary muscles for exercise \(id)."
        }
    }
}

public struct PortableUserDataImportSummary: Equatable, Sendable {
    public let nutritionEntries: Int
    public let nutritionCatalogItems: Int
    public let strengthExercises: Int
    public let strengthRoutines: Int
    public let strengthRoutineExercises: Int
    public let strengthSessions: Int
    public let strengthSets: Int

    public var total: Int {
        nutritionEntries + nutritionCatalogItems + strengthExercises + strengthRoutines
            + strengthRoutineExercises + strengthSessions + strengthSets
    }
}

extension WhoopStore {
    /// Validate the complete graph, then merge every accepted row in one SQLite transaction.
    ///
    /// Stable IDs make imports idempotent. An incoming row must be strictly newer than an existing
    /// editable row; equal timestamps keep the local copy. Existing built-in exercise definitions are
    /// never overwritten, and a portable catalog row can never take over a colliding custom exercise.
    public func importPortableUserData(
        _ payload: PortableUserData
    ) async throws -> PortableUserDataImportSummary {
        let clean = try payload.validated()
        return try syncWrite { db in
            var nutritionImported = 0
            var nutritionCatalogImported = 0
            var exercisesImported = 0
            var routinesImported = 0
            var routineExercisesImported = 0
            var sessionsImported = 0
            var setsImported = 0
            var touchedNutrition = Set<PortableNutritionCell>()

            for row in clean.nutritionEntries {
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT deviceId, day, updatedAt FROM nutritionEntry WHERE id = ?",
                    arguments: [row.id]
                ) {
                    let oldUpdatedAt: Int = existing["updatedAt"]
                    guard row.updatedAt > oldUpdatedAt else { continue }
                    touchedNutrition.insert(
                        PortableNutritionCell(
                            deviceId: existing["deviceId"],
                            day: existing["day"]
                        )
                    )
                }
                try upsertPortableNutrition(db, row: row)
                touchedNutrition.insert(
                    PortableNutritionCell(deviceId: row.deviceId, day: row.day)
                )
                nutritionImported += 1
            }

            for row in clean.nutritionCatalogItems {
                if let existingUpdatedAt = try Int.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM nutritionCatalogItem WHERE id = ?",
                    arguments: [row.id]
                ), row.updatedAt <= existingUpdatedAt {
                    continue
                }
                try upsertPortableNutritionCatalogItem(db, row: row)
                nutritionCatalogImported += 1
            }

            for portable in clean.strengthExercises {
                let row = portable.row
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT isCustom, updatedAt FROM strengthExercise WHERE id = ?",
                    arguments: [row.id]
                ) {
                    let existingIsCustom: Bool = existing["isCustom"]
                    let existingUpdatedAt: Int = existing["updatedAt"]
                    guard existingIsCustom, row.isCustom, row.updatedAt > existingUpdatedAt else {
                        continue
                    }
                }
                try upsertPortableExercise(db, row: row)
                exercisesImported += 1
            }

            let routineExercises = Dictionary(
                grouping: clean.strengthRoutineExercises,
                by: \.routineId
            )
            for routine in clean.strengthRoutines {
                if let existingUpdatedAt = try Int.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM strengthRoutine WHERE id = ?",
                    arguments: [routine.id]
                ), routine.updatedAt <= existingUpdatedAt {
                    continue
                }
                let children = routineExercises[routine.id, default: []]
                try ensurePortableExerciseIDsExist(db, ids: children.map(\.exerciseId))
                try upsertPortableRoutine(db, row: routine)
                try db.execute(
                    sql: "DELETE FROM strengthRoutineExercise WHERE routineId = ?",
                    arguments: [routine.id]
                )
                for row in children {
                    try insertPortableRoutineExercise(db, row: row)
                }
                routinesImported += 1
                routineExercisesImported += children.count
            }

            let strengthSets = Dictionary(grouping: clean.strengthSets, by: \.sessionId)
            for session in clean.strengthSessions {
                if let existingUpdatedAt = try Int.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM strengthSession WHERE id = ?",
                    arguments: [session.id]
                ), session.updatedAt <= existingUpdatedAt {
                    continue
                }
                if let routineId = session.routineId {
                    guard try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM strengthRoutine WHERE id = ?",
                        arguments: [routineId]
                    ) == 1 else {
                        throw PortableUserDataError.brokenRelationship("strengthSessions")
                    }
                }
                let children = strengthSets[session.id, default: []]
                try ensurePortableExerciseIDsExist(db, ids: children.map(\.exerciseId))
                try upsertPortableSession(db, row: session)
                try db.execute(
                    sql: "DELETE FROM strengthSet WHERE sessionId = ?",
                    arguments: [session.id]
                )
                for row in children {
                    try insertPortableSet(db, row: row)
                }
                sessionsImported += 1
                setsImported += children.count
            }

            try reprojectPortableNutrition(db, cells: touchedNutrition)
            return PortableUserDataImportSummary(
                nutritionEntries: nutritionImported,
                nutritionCatalogItems: nutritionCatalogImported,
                strengthExercises: exercisesImported,
                strengthRoutines: routinesImported,
                strengthRoutineExercises: routineExercisesImported,
                strengthSessions: sessionsImported,
                strengthSets: setsImported
            )
        }
    }
}

private func upsertPortableNutritionCatalogItem(
    _ db: Database,
    row: NutritionCatalogItemRow
) throws {
    try db.execute(sql: """
        INSERT INTO nutritionCatalogItem
            (id, kind, name, brand, barcode, servingQuantity, servingUnit, caloriesKcal,
             proteinG, carbsG, fatG, mealType, source, isSaved, lastUsedAt, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            name = excluded.name,
            brand = excluded.brand,
            barcode = excluded.barcode,
            servingQuantity = excluded.servingQuantity,
            servingUnit = excluded.servingUnit,
            caloriesKcal = excluded.caloriesKcal,
            proteinG = excluded.proteinG,
            carbsG = excluded.carbsG,
            fatG = excluded.fatG,
            mealType = excluded.mealType,
            source = excluded.source,
            isSaved = excluded.isSaved,
            lastUsedAt = excluded.lastUsedAt,
            updatedAt = excluded.updatedAt
        """, arguments: [
            row.id, row.kind, row.name, row.brand, row.barcode, row.servingQuantity,
            row.servingUnit, row.caloriesKcal, row.proteinG, row.carbsG, row.fatG,
            row.mealType, row.source, row.isSaved, row.lastUsedAt, row.createdAt, row.updatedAt,
        ])
}

private struct PortableNutritionCell: Hashable {
    let deviceId: String
    let day: String
}

private func upsertPortableNutrition(_ db: Database, row: NutritionEntryRow) throws {
    try db.execute(sql: """
        INSERT INTO nutritionEntry
            (id, deviceId, origin, day, occurredAt, mealType, label,
             caloriesKcal, proteinG, carbsG, fatG, note, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            deviceId = excluded.deviceId,
            origin = excluded.origin,
            day = excluded.day,
            occurredAt = excluded.occurredAt,
            mealType = excluded.mealType,
            label = excluded.label,
            caloriesKcal = excluded.caloriesKcal,
            proteinG = excluded.proteinG,
            carbsG = excluded.carbsG,
            fatG = excluded.fatG,
            note = excluded.note,
            updatedAt = excluded.updatedAt
        """, arguments: [
            row.id, row.deviceId, row.origin, row.day, row.occurredAt, row.mealType,
            row.label, row.caloriesKcal, row.proteinG, row.carbsG, row.fatG, row.note,
            row.createdAt, row.updatedAt,
        ])
}

private func upsertPortableExercise(_ db: Database, row: StrengthExerciseRow) throws {
    try db.execute(sql: """
        INSERT INTO strengthExercise
            (id, name, primaryMuscle, secondaryMusclesJSON, equipment, movementPattern,
             isCustom, archivedAt, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            primaryMuscle = excluded.primaryMuscle,
            secondaryMusclesJSON = excluded.secondaryMusclesJSON,
            equipment = excluded.equipment,
            movementPattern = excluded.movementPattern,
            isCustom = excluded.isCustom,
            archivedAt = excluded.archivedAt,
            updatedAt = excluded.updatedAt
        """, arguments: [
            row.id, row.name, row.primaryMuscle, row.secondaryMusclesJSON, row.equipment,
            row.movementPattern, row.isCustom, row.archivedAt, row.createdAt, row.updatedAt,
        ])
}

private func upsertPortableRoutine(_ db: Database, row: StrengthRoutineRow) throws {
    try db.execute(sql: """
        INSERT INTO strengthRoutine
            (id, name, note, scheduledWeekdaysJSON, archivedAt, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            note = excluded.note,
            scheduledWeekdaysJSON = excluded.scheduledWeekdaysJSON,
            archivedAt = excluded.archivedAt,
            updatedAt = excluded.updatedAt
        """, arguments: [
            row.id, row.name, row.note, row.scheduledWeekdaysJSON, row.archivedAt,
            row.createdAt, row.updatedAt,
        ])
}

private func upsertPortableSession(_ db: Database, row: StrengthSessionRow) throws {
    try db.execute(sql: """
        INSERT INTO strengthSession
            (id, routineId, name, startedAt, endedAt, note, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            routineId = excluded.routineId,
            name = excluded.name,
            startedAt = excluded.startedAt,
            endedAt = excluded.endedAt,
            note = excluded.note,
            updatedAt = excluded.updatedAt
        """, arguments: [
            row.id, row.routineId, row.name, row.startedAt, row.endedAt, row.note,
            row.createdAt, row.updatedAt,
        ])
}

private func insertPortableRoutineExercise(
    _ db: Database,
    row: StrengthRoutineExerciseRow
) throws {
    try db.execute(sql: """
        INSERT INTO strengthRoutineExercise
            (id, routineId, exerciseId, position, targetSets, targetRepsMin, targetRepsMax,
             targetRPE, restSeconds, note, planJSON, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            row.id, row.routineId, row.exerciseId, row.position, row.targetSets,
            row.targetRepsMin, row.targetRepsMax, row.targetRPE, row.restSeconds, row.note,
            row.planJSON, row.createdAt, row.updatedAt,
        ])
}

private func insertPortableSet(_ db: Database, row: StrengthSetRow) throws {
    try db.execute(sql: """
        INSERT INTO strengthSet
            (id, sessionId, exerciseId, exercisePosition, setPosition, setType, reps,
             loadKg, durationS, rpe, restSeconds, completedAt, note, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            row.id, row.sessionId, row.exerciseId, row.exercisePosition, row.setPosition,
            row.setType, row.reps, row.loadKg, row.durationS, row.rpe, row.restSeconds,
            row.completedAt, row.note, row.createdAt, row.updatedAt,
        ])
}

private func ensurePortableExerciseIDsExist(_ db: Database, ids: [String]) throws {
    for id in Set(ids) {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM strengthExercise WHERE id = ?",
            arguments: [id]
        ) == 1 else {
            throw PortableUserDataError.brokenRelationship("strengthExercises")
        }
    }
}

private func reprojectPortableNutrition(
    _ db: Database,
    cells: Set<PortableNutritionCell>
) throws {
    for cell in cells {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM nutritionEntry
            WHERE deviceId = ? AND day = ?
            ORDER BY occurredAt ASC, createdAt ASC, id ASC
            """, arguments: [cell.deviceId, cell.day]).map(NutritionEntryRow.decode)
        let totals = NutritionLogContract.resolvedTotals(
            entries: rows,
            day: cell.day,
            deviceId: cell.deviceId
        )
        let values = [
            (key: NutritionLogContract.caloriesKey, value: totals.caloriesKcal),
            (key: NutritionLogContract.proteinKey, value: totals.proteinG),
            (key: NutritionLogContract.carbsKey, value: totals.carbsG),
            (key: NutritionLogContract.fatKey, value: totals.fatG),
        ]
        for field in values {
            let value = field.value
            if let value {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [cell.deviceId, cell.day, field.key, value])
            } else {
                try db.execute(sql: """
                    DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key = ?
                    """, arguments: [cell.deviceId, cell.day, field.key])
            }
        }
    }
}
