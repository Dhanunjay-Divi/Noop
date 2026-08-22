import Foundation
import GRDB

// MARK: - Editable nutrition source of truth (v39)

/// Why one table exists in addition to `metricSeries`:
/// `metricSeries` can hold only one REAL value per (source, day, key). A useful nutrition log needs
/// several meals per day, stable edit/delete identifiers, meal time/type, labels, notes, nullable
/// nutrients, and provenance. `nutritionEntry` is that richer source of truth; the four daily sums are
/// projected into `metricSeries` under `nutrition-log` so Explore, Compare, Coach, and correlations keep
/// using the existing scalar-series substrate.
public enum NutritionLogContract {
    public static let deviceId = "nutrition-log"
    public static let manualOrigin = "manual"
    public static let csvOrigin = "nutrition-csv"

    public static let caloriesKey = "calories_in"
    public static let proteinKey = "protein_g"
    public static let carbsKey = "carbs_g"
    public static let fatKey = "fat_g"
    public static let nutrientKeys = [caloriesKey, proteinKey, carbsKey, fatKey]

    public static let maxLabelCharacters = 80
    public static let maxNoteCharacters = 500
    public static let maxCaloriesPerEntry = 20_000.0
    public static let maxMacroGramsPerEntry = 2_000.0

    /// Stable storage values shared with Android. `daily_total` is used for a CSV's one-row-per-day
    /// summary; manual UI defaults to a concrete meal or `other`.
    public static let mealTypes = [
        "breakfast", "lunch", "dinner", "snack", "other", "daily_total",
    ]

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidID
        case invalidDeviceID
        case invalidOrigin
        case invalidDay
        case invalidOccurredAt
        case invalidMealType
        case invalidCreatedAt
        case invalidNutrient(String)
        case importedEntryCannotRepeat
        case emptyEntry

        public var errorDescription: String? {
            switch self {
            case .invalidNutrient(caloriesKey):
                return "Calories must be between 0 and 20,000 kcal."
            case .invalidNutrient(proteinKey):
                return "Protein must be between 0 and 2,000 g."
            case .invalidNutrient(carbsKey):
                return "Carbs must be between 0 and 2,000 g."
            case .invalidNutrient(fatKey):
                return "Fat must be between 0 and 2,000 g."
            case .invalidNutrient:
                return "One nutrient value is outside the supported range."
            case .emptyEntry:
                return "Add a food name, note, calories, or at least one macro before saving."
            case .invalidDay, .invalidOccurredAt:
                return "Choose a valid date and time for this entry."
            case .invalidMealType:
                return "Choose a valid meal type."
            case .importedEntryCannotRepeat:
                return "Imported daily totals cannot be logged again as meals."
            case .invalidID, .invalidDeviceID, .invalidOrigin, .invalidCreatedAt:
                return "NOOP couldn’t validate this nutrition entry. Please try again."
            }
        }
    }

    /// Validate and normalize one row before it reaches SQLite. Text is trimmed and bounded; nutrient
    /// values are never coerced because silently changing food data is worse than rejecting it.
    public static func validated(_ row: NutritionEntryRow) throws -> NutritionEntryRow {
        var clean = row
        clean.id = clean.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.id.isEmpty, clean.id.count <= 128 else { throw ValidationError.invalidID }
        guard clean.deviceId == deviceId else { throw ValidationError.invalidDeviceID }
        guard clean.origin == manualOrigin || clean.origin == csvOrigin else {
            throw ValidationError.invalidOrigin
        }
        guard isValidDay(clean.day) else { throw ValidationError.invalidDay }
        guard clean.occurredAt > 0 else { throw ValidationError.invalidOccurredAt }
        guard mealTypes.contains(clean.mealType) else { throw ValidationError.invalidMealType }
        guard clean.createdAt > 0, clean.updatedAt >= clean.createdAt else {
            throw ValidationError.invalidCreatedAt
        }

        clean.label = boundedText(clean.label, max: maxLabelCharacters, singleLine: true)
        clean.note = boundedText(clean.note, max: maxNoteCharacters, singleLine: false)
        try validate(clean.caloriesKcal, key: caloriesKey, maximum: maxCaloriesPerEntry)
        try validate(clean.proteinG, key: proteinKey, maximum: maxMacroGramsPerEntry)
        try validate(clean.carbsG, key: carbsKey, maximum: maxMacroGramsPerEntry)
        try validate(clean.fatG, key: fatKey, maximum: maxMacroGramsPerEntry)

        let hasNutrient = [clean.caloriesKcal, clean.proteinG, clean.carbsG, clean.fatG]
            .contains { $0 != nil }
        guard hasNutrient || clean.label != nil || clean.note != nil else {
            throw ValidationError.emptyEntry
        }
        return clean
    }

    /// Deterministic id for the single imported daily summary. Re-importing the same day updates that
    /// row instead of duplicating it; manual rows use UUID strings.
    public static func csvEntryID(day: String) -> String { "\(csvOrigin):\(day)" }

    /// Noon UTC gives a stable instant for an imported day that has no meal time. The local day remains
    /// stored explicitly and is never recomputed from this synthetic timestamp.
    public static func importedOccurredAt(day: String) -> Int? {
        guard isValidDay(day) else { return nil }
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: pieces[0],
            month: pieces[1],
            day: pieces[2],
            hour: 12
        )
        return calendar.date(from: components).map { Int($0.timeIntervalSince1970) }
    }

    /// Resolve a day without silently adding an imported daily summary to meals that summary usually
    /// already includes. Imported values win independently per nutrient; manual sums fill only fields
    /// that the imported summary did not provide.
    public static func resolvedTotals(
        entries: [NutritionEntryRow],
        day: String,
        deviceId resolvedDeviceID: String = deviceId
    ) -> NutritionDailyTotals {
        let dayRows = entries.filter { $0.deviceId == resolvedDeviceID && $0.day == day }
        let imported = dayRows
            .filter { $0.origin == csvOrigin }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id > $1.id
            }
        let manual = dayRows.filter { $0.origin == manualOrigin }

        func importedValue(_ field: (NutritionEntryRow) -> Double?) -> Double? {
            imported.lazy.compactMap(field).first
        }
        func manualSum(_ field: (NutritionEntryRow) -> Double?) -> Double? {
            let values = manual.compactMap(field)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        func resolve(_ field: (NutritionEntryRow) -> Double?) -> Double? {
            importedValue(field) ?? manualSum(field)
        }

        return NutritionDailyTotals(
            day: day,
            caloriesKcal: resolve { $0.caloriesKcal },
            proteinG: resolve { $0.proteinG },
            carbsG: resolve { $0.carbsG },
            fatG: resolve { $0.fatG },
            importedEntryCount: imported.count,
            manualEntryCount: manual.count
        )
    }

    /// Deduplicate recent manual meals by their reusable identity. The newest occurrence wins, while
    /// notes remain attached to that newest row without making every contextual note a new template.
    public static func recentManualEntries(
        from entries: [NutritionEntryRow],
        limit: Int,
        deviceId resolvedDeviceID: String = deviceId
    ) -> [NutritionEntryRow] {
        struct Signature: Hashable {
            let mealType: String
            let label: String?
            let caloriesKcal: Double?
            let proteinG: Double?
            let carbsG: Double?
            let fatG: Double?
        }

        let safeLimit = min(max(0, limit), 20)
        guard safeLimit > 0 else { return [] }
        var seen = Set<Signature>()
        var result: [NutritionEntryRow] = []
        let sorted = entries
            .filter { $0.deviceId == resolvedDeviceID && $0.origin == manualOrigin }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id > $1.id
            }
        for row in sorted {
            let signature = Signature(
                mealType: row.mealType,
                label: row.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                caloriesKcal: row.caloriesKcal,
                proteinG: row.proteinG,
                carbsG: row.carbsG,
                fatG: row.fatG
            )
            guard seen.insert(signature).inserted else { continue }
            result.append(row)
            if result.count == safeLimit { break }
        }
        return result
    }

    /// Construct a fresh manual row from a previously entered meal. Imported summaries are never
    /// reusable templates because doing so would turn a whole-day aggregate into a single meal.
    public static func repeatedManualEntry(
        from source: NutritionEntryRow,
        id: String,
        day: String,
        occurredAt: Int,
        timestamp: Int
    ) throws -> NutritionEntryRow {
        guard source.origin == manualOrigin else {
            throw ValidationError.importedEntryCannotRepeat
        }
        return try validated(NutritionEntryRow(
            id: id,
            origin: manualOrigin,
            day: day,
            occurredAt: occurredAt,
            mealType: source.mealType,
            label: source.label,
            caloriesKcal: source.caloriesKcal,
            proteinG: source.proteinG,
            carbsG: source.carbsG,
            fatG: source.fatG,
            note: source.note,
            createdAt: timestamp,
            updatedAt: timestamp
        ))
    }

    /// Parse the complete editor value using the active locale. NumberFormatter may accept a valid
    /// numeric prefix, so the consumed range is checked to reject text such as "12 kcal".
    public static func parseUserNumber(_ raw: String, locale: Locale = .current) -> Double? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        var object: AnyObject?
        var range = NSRange(location: 0, length: (clean as NSString).length)
        do {
            try formatter.getObjectValue(&object, for: clean, range: &range)
        } catch {
            return nil
        }
        guard range.location == 0,
              range.length == (clean as NSString).length,
              let value = (object as? NSNumber)?.doubleValue,
              value.isFinite
        else { return nil }
        return value
    }

    private static func validate(_ value: Double?, key: String, maximum: Double) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0, value <= maximum else {
            throw ValidationError.invalidNutrient(key)
        }
    }

    private static func boundedText(_ value: String?, max: Int, singleLine: Bool) -> String? {
        guard var text = value else { return nil }
        if singleLine {
            text = text.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        text = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || (!singleLine && $0 == "\n") }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(max))
    }

    private static func isValidDay(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}

/// One editable meal or imported daily summary. Every nutrient is independently nullable: an entry
/// containing only protein does not fabricate zero calories/carbs/fat, and its daily projections omit
/// those absent fields.
public struct NutritionEntryRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var origin: String
    public var day: String
    public var occurredAt: Int
    public var mealType: String
    public var label: String?
    public var caloriesKcal: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var note: String?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String,
        deviceId: String = NutritionLogContract.deviceId,
        origin: String,
        day: String,
        occurredAt: Int,
        mealType: String,
        label: String? = nil,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        note: String? = nil,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.id = id
        self.deviceId = deviceId
        self.origin = origin
        self.day = day
        self.occurredAt = occurredAt
        self.mealType = mealType
        self.label = label
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> NutritionEntryRow {
        NutritionEntryRow(
            id: row["id"],
            deviceId: row["deviceId"],
            origin: row["origin"],
            day: row["day"],
            occurredAt: row["occurredAt"],
            mealType: row["mealType"],
            label: row["label"],
            caloriesKcal: row["caloriesKcal"],
            proteinG: row["proteinG"],
            carbsG: row["carbsG"],
            fatG: row["fatG"],
            note: row["note"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }
}

public struct NutritionDailyTotals: Equatable, Sendable {
    public let day: String
    public let caloriesKcal: Double?
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public let importedEntryCount: Int
    public let manualEntryCount: Int

    public var hasImportedSummary: Bool { importedEntryCount > 0 }
    public var hasManualEntries: Bool { manualEntryCount > 0 }
    public var hasMixedSources: Bool { hasImportedSummary && hasManualEntries }

    public init(
        day: String,
        caloriesKcal: Double?,
        proteinG: Double?,
        carbsG: Double?,
        fatG: Double?,
        importedEntryCount: Int = 0,
        manualEntryCount: Int = 0
    ) {
        self.day = day
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.importedEntryCount = max(0, importedEntryCount)
        self.manualEntryCount = max(0, manualEntryCount)
    }
}

extension WhoopStore {
    private struct NutritionDayCell: Hashable {
        let deviceId: String
        let day: String
    }

    /// Insert or edit entries by stable id and atomically rebuild every affected day's scalar
    /// projections. Moving an entry to another day clears/rebuilds the old day as well as the new one.
    @discardableResult
    public func upsertNutritionEntries(_ rows: [NutritionEntryRow]) async throws -> Int {
        let clean = try rows.map(NutritionLogContract.validated)
        guard !clean.isEmpty else { return 0 }
        return try syncWrite { db in
            var written = 0
            var touched = Set<NutritionDayCell>()
            for row in clean {
                if let old = try Row.fetchOne(
                    db,
                    sql: "SELECT deviceId, day FROM nutritionEntry WHERE id = ?",
                    arguments: [row.id]
                ) {
                    touched.insert(NutritionDayCell(deviceId: old["deviceId"], day: old["day"]))
                }
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
                written += db.changesCount
                touched.insert(NutritionDayCell(deviceId: row.deviceId, day: row.day))
            }
            try reprojectNutritionDays(db, cells: touched)
            return written
        }
    }

    /// Convert the importer's existing daily scalar points into one deterministic editable summary row
    /// per day. The legacy `nutrition-csv` metricSeries rows remain intact for provenance/compatibility;
    /// `nutrition-log` becomes the combined imported + manual projection.
    @discardableResult
    public func upsertImportedNutritionDays(
        _ points: [MetricPoint],
        updatedAt: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> Int {
        var grouped: [String: [String: Double]] = [:]
        for point in points where NutritionLogContract.nutrientKeys.contains(point.key) {
            grouped[point.day, default: [:]][point.key] = point.value
        }
        let rows = grouped.keys.sorted().compactMap { day -> NutritionEntryRow? in
            guard let occurredAt = NutritionLogContract.importedOccurredAt(day: day),
                  let values = grouped[day] else { return nil }
            return NutritionEntryRow(
                id: NutritionLogContract.csvEntryID(day: day),
                origin: NutritionLogContract.csvOrigin,
                day: day,
                occurredAt: occurredAt,
                mealType: "daily_total",
                caloriesKcal: values[NutritionLogContract.caloriesKey],
                proteinG: values[NutritionLogContract.proteinKey],
                carbsG: values[NutritionLogContract.carbsKey],
                fatG: values[NutritionLogContract.fatKey],
                createdAt: occurredAt,
                updatedAt: max(updatedAt, occurredAt)
            )
        }
        return try await upsertNutritionEntries(rows)
    }

    public func nutritionEntries(
        deviceId: String = NutritionLogContract.deviceId,
        from: String,
        to: String
    ) async throws -> [NutritionEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionEntry
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC, occurredAt ASC, createdAt ASC, id ASC
                """, arguments: [deviceId, from, to]).map(NutritionEntryRow.decode)
        }
    }

    public func nutritionEntry(id: String) async throws -> NutritionEntryRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nutritionEntry WHERE id = ?",
                             arguments: [id]).map(NutritionEntryRow.decode)
        }
    }

    public func nutritionTotals(
        deviceId: String = NutritionLogContract.deviceId,
        day: String
    ) async throws -> NutritionDailyTotals {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionEntry
                WHERE deviceId = ? AND day = ?
                ORDER BY occurredAt ASC, createdAt ASC, id ASC
                """, arguments: [deviceId, day]).map(NutritionEntryRow.decode)
            return NutritionLogContract.resolvedTotals(
                entries: rows,
                day: day,
                deviceId: deviceId
            )
        }
    }

    public func recentManualNutritionEntries(
        deviceId: String = NutritionLogContract.deviceId,
        through day: String,
        limit: Int = 4
    ) async throws -> [NutritionEntryRow] {
        try syncRead { db in
            let queryLimit = min(max(limit * 12, 24), 240)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionEntry
                WHERE deviceId = ? AND origin = ? AND day <= ?
                ORDER BY occurredAt DESC, updatedAt DESC, id DESC
                LIMIT ?
                """, arguments: [
                    deviceId, NutritionLogContract.manualOrigin, day, queryLimit,
                ]).map(NutritionEntryRow.decode)
            return NutritionLogContract.recentManualEntries(
                from: rows,
                limit: limit,
                deviceId: deviceId
            )
        }
    }

    @discardableResult
    public func deleteNutritionEntry(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT deviceId, day FROM nutritionEntry WHERE id = ?",
                arguments: [id]
            ) else { return false }
            let cell = NutritionDayCell(deviceId: row["deviceId"], day: row["day"])
            try db.execute(sql: "DELETE FROM nutritionEntry WHERE id = ?", arguments: [id])
            try reprojectNutritionDays(db, cells: [cell])
            return true
        }
    }

    /// Recompute each touched day from the CURRENT entries. `SUM(nullableColumn)` stays nil when no
    /// entry supplied that nutrient, so absence deletes the projected point instead of becoming zero.
    private func reprojectNutritionDays(_ db: Database, cells: Set<NutritionDayCell>) throws {
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
                        DELETE FROM metricSeries
                        WHERE deviceId = ? AND day = ? AND key = ?
                        """, arguments: [cell.deviceId, cell.day, field.key])
                }
            }
        }
    }
}
