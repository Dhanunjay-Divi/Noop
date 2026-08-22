import Foundation
import GRDB

/// Cross-platform saved-food, saved-meal, and successful barcode-cache contract.
public enum NutritionCatalogContract {
    public static let foodKind = "food"
    public static let mealKind = "meal"
    public static let manualSource = "manual"
    public static let openFoodFactsSource = "open_food_facts"

    public static let maxNameCharacters = 160
    public static let maxBrandCharacters = 120
    public static let maxServingUnitCharacters = 40
    public static let maxServingQuantity = 100_000.0

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidID
        case invalidKind
        case invalidName
        case invalidBarcode
        case invalidServing
        case invalidMealType
        case invalidSource
        case invalidTimestamp
        case invalidNutrient(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Add a food or meal name."
            case .invalidBarcode:
                return "Enter a valid barcode containing 4 to 32 digits."
            case .invalidServing:
                return "Enter a valid serving amount."
            case .invalidNutrient:
                return "One nutrient value is outside the supported range."
            case .invalidID, .invalidKind, .invalidMealType, .invalidSource, .invalidTimestamp:
                return "NOOP could not validate this saved food or meal."
            }
        }
    }

    public static func normalizedBarcode(_ raw: String) -> String? {
        let compact = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard (4...32).contains(compact.count),
              compact.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        else { return nil }
        return compact
    }

    public static func barcodeID(_ barcode: String) throws -> String {
        guard let clean = normalizedBarcode(barcode) else {
            throw ValidationError.invalidBarcode
        }
        return "barcode:\(clean)"
    }

    public static func validated(_ row: NutritionCatalogItemRow) throws -> NutritionCatalogItemRow {
        var clean = row
        clean.id = clean.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.id.isEmpty, clean.id.count <= 128 else { throw ValidationError.invalidID }
        guard clean.kind == foodKind || clean.kind == mealKind else {
            throw ValidationError.invalidKind
        }

        clean.name = boundedText(clean.name, max: maxNameCharacters) ?? ""
        guard !clean.name.isEmpty else { throw ValidationError.invalidName }
        clean.brand = boundedText(clean.brand, max: maxBrandCharacters)
        clean.servingUnit = boundedText(clean.servingUnit, max: maxServingUnitCharacters)

        if let barcode = clean.barcode {
            guard let normalized = normalizedBarcode(barcode) else {
                throw ValidationError.invalidBarcode
            }
            clean.barcode = normalized
        }
        if let quantity = clean.servingQuantity {
            guard quantity.isFinite, quantity > 0, quantity <= maxServingQuantity else {
                throw ValidationError.invalidServing
            }
        }
        guard NutritionLogContract.mealTypes.contains(clean.mealType),
              clean.mealType != "daily_total"
        else { throw ValidationError.invalidMealType }
        guard clean.source == manualSource || clean.source == openFoodFactsSource else {
            throw ValidationError.invalidSource
        }
        guard clean.createdAt > 0, clean.updatedAt >= clean.createdAt,
              clean.lastUsedAt.map({ $0 > 0 }) ?? true
        else { throw ValidationError.invalidTimestamp }

        try validate(
            clean.caloriesKcal,
            key: NutritionLogContract.caloriesKey,
            maximum: NutritionLogContract.maxCaloriesPerEntry
        )
        try validate(
            clean.proteinG,
            key: NutritionLogContract.proteinKey,
            maximum: NutritionLogContract.maxMacroGramsPerEntry
        )
        try validate(
            clean.carbsG,
            key: NutritionLogContract.carbsKey,
            maximum: NutritionLogContract.maxMacroGramsPerEntry
        )
        try validate(
            clean.fatG,
            key: NutritionLogContract.fatKey,
            maximum: NutritionLogContract.maxMacroGramsPerEntry
        )
        return clean
    }

    private static func validate(_ value: Double?, key: String, maximum: Double) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0, value <= maximum else {
            throw ValidationError.invalidNutrient(key)
        }
    }

    private static func boundedText(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(max))
    }
}

public struct NutritionCatalogItemRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var servingQuantity: Double?
    public var servingUnit: String?
    public var caloriesKcal: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var mealType: String
    public var source: String
    public var isSaved: Bool
    public var lastUsedAt: Int?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String,
        kind: String,
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        servingQuantity: Double? = nil,
        servingUnit: String? = nil,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        mealType: String = "other",
        source: String,
        isSaved: Bool,
        lastUsedAt: Int? = nil,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.mealType = mealType
        self.source = source
        self.isSaved = isSaved
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> NutritionCatalogItemRow {
        NutritionCatalogItemRow(
            id: row["id"],
            kind: row["kind"],
            name: row["name"],
            brand: row["brand"],
            barcode: row["barcode"],
            servingQuantity: row["servingQuantity"],
            servingUnit: row["servingUnit"],
            caloriesKcal: row["caloriesKcal"],
            proteinG: row["proteinG"],
            carbsG: row["carbsG"],
            fatG: row["fatG"],
            mealType: row["mealType"],
            source: row["source"],
            isSaved: row["isSaved"],
            lastUsedAt: row["lastUsedAt"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }
}

extension WhoopStore {
    @discardableResult
    public func upsertNutritionCatalogItems(_ rows: [NutritionCatalogItemRow]) async throws -> Int {
        let clean = try rows.map(NutritionCatalogContract.validated)
        guard !clean.isEmpty else { return 0 }
        return try syncWrite { db in
            var written = 0
            for row in clean {
                try db.execute(sql: """
                    INSERT INTO nutritionCatalogItem
                        (id, kind, name, brand, barcode, servingQuantity, servingUnit,
                         caloriesKcal, proteinG, carbsG, fatG, mealType, source, isSaved,
                         lastUsedAt, createdAt, updatedAt)
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
                        row.id, row.kind, row.name, row.brand, row.barcode,
                        row.servingQuantity, row.servingUnit, row.caloriesKcal,
                        row.proteinG, row.carbsG, row.fatG, row.mealType, row.source,
                        row.isSaved, row.lastUsedAt, row.createdAt, row.updatedAt,
                    ])
                written += db.changesCount
            }
            return written
        }
    }

    public func nutritionCatalogItems(
        savedOnly: Bool = true,
        limit: Int = 250
    ) async throws -> [NutritionCatalogItemRow] {
        let safeLimit = min(max(limit, 1), 500_000)
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionCatalogItem
                WHERE (? = 0 OR isSaved = 1)
                ORDER BY isSaved DESC, COALESCE(lastUsedAt, 0) DESC, updatedAt DESC,
                         name COLLATE NOCASE ASC, id ASC
                LIMIT ?
                """, arguments: [savedOnly, safeLimit]).map(NutritionCatalogItemRow.decode)
        }
    }

    public func nutritionCatalogItem(id: String) async throws -> NutritionCatalogItemRow? {
        try syncRead { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM nutritionCatalogItem WHERE id = ?",
                arguments: [id]
            ).map(NutritionCatalogItemRow.decode)
        }
    }

    public func nutritionCatalogItem(barcode rawBarcode: String) async throws
        -> NutritionCatalogItemRow?
    {
        guard let barcode = NutritionCatalogContract.normalizedBarcode(rawBarcode) else {
            throw NutritionCatalogContract.ValidationError.invalidBarcode
        }
        return try syncRead { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM nutritionCatalogItem WHERE barcode = ? LIMIT 1",
                arguments: [barcode]
            ).map(NutritionCatalogItemRow.decode)
        }
    }

    @discardableResult
    public func markNutritionCatalogItemUsed(id: String, at timestamp: Int) async throws -> Bool {
        guard timestamp > 0 else {
            throw NutritionCatalogContract.ValidationError.invalidTimestamp
        }
        return try syncWrite { db in
            try db.execute(
                sql: """
                    UPDATE nutritionCatalogItem
                    SET lastUsedAt = ?, updatedAt = MAX(updatedAt, ?)
                    WHERE id = ?
                    """,
                arguments: [timestamp, timestamp, id]
            )
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func deleteNutritionCatalogItem(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM nutritionCatalogItem WHERE id = ?",
                arguments: [id]
            )
            return db.changesCount > 0
        }
    }
}
