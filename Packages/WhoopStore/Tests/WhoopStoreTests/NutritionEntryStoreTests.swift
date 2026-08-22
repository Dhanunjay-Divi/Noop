import XCTest
import GRDB
@testable import WhoopStore

final class NutritionEntryStoreTests: XCTestCase {
    private let day1 = "2026-08-21"
    private let day2 = "2026-08-22"

    private func entry(
        id: String = UUID().uuidString,
        deviceId: String = NutritionLogContract.deviceId,
        day: String = "2026-08-22",
        occurredAt: Int = 1_777_000_000,
        mealType: String = "lunch",
        label: String? = "Lunch",
        calories: Double? = nil,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        note: String? = nil,
        updatedAt: Int = 1_777_000_100
    ) -> NutritionEntryRow {
        var row = NutritionEntryRow(
            id: id,
            origin: NutritionLogContract.manualOrigin,
            day: day,
            occurredAt: occurredAt,
            mealType: mealType,
            label: label,
            caloriesKcal: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            note: note,
            createdAt: 1_777_000_000,
            updatedAt: updatedAt
        )
        row.deviceId = deviceId
        return row
    }

    func testContractRejectsCorruptAndEmptyRows() throws {
        XCTAssertThrowsError(try NutritionLogContract.validated(
            entry(label: nil, calories: -1)
        )) { error in
            XCTAssertEqual(error as? NutritionLogContract.ValidationError,
                           .invalidNutrient(NutritionLogContract.caloriesKey))
        }
        XCTAssertThrowsError(try NutritionLogContract.validated(
            entry(label: nil)
        )) { error in
            XCTAssertEqual(error as? NutritionLogContract.ValidationError, .emptyEntry)
        }
        XCTAssertThrowsError(try NutritionLogContract.validated(
            entry(label: nil, protein: .infinity)
        ))
        XCTAssertThrowsError(try NutritionLogContract.validated(
            entry(day: "2026-02-31", calories: 100)
        ))
    }

    func testContractTrimsBoundsAndKeepsNullableNutrients() throws {
        let clean = try NutritionLogContract.validated(entry(
            label: "  \(String(repeating: "A", count: 100))\n ",
            protein: 25,
            note: "  useful note  "
        ))
        XCTAssertEqual(clean.label?.count, NutritionLogContract.maxLabelCharacters)
        XCTAssertFalse(clean.label?.contains("\n") ?? true)
        XCTAssertEqual(clean.note, "useful note")
        XCTAssertNil(clean.caloriesKcal)
        XCTAssertEqual(clean.proteinG, 25)
        XCTAssertNil(clean.carbsG)
        XCTAssertNil(clean.fatG)
    }

    func testLocaleNumbersRequireACompleteValidParse() {
        XCTAssertEqual(
            NutritionLogContract.parseUserNumber("1,200.5", locale: Locale(identifier: "en_US")),
            1_200.5
        )
        XCTAssertEqual(
            NutritionLogContract.parseUserNumber("1.200,5", locale: Locale(identifier: "de_DE")),
            1_200.5
        )
        XCTAssertEqual(
            NutritionLogContract.parseUserNumber(
                "1\u{202F}200,5", locale: Locale(identifier: "fr_FR")),
            1_200.5
        )
        XCTAssertNil(
            NutritionLogContract.parseUserNumber("12 kcal", locale: Locale(identifier: "en_US")))
        XCTAssertNil(
            NutritionLogContract.parseUserNumber("not a number", locale: Locale(identifier: "en_US")))
    }

    func testRecentMealsDeduplicateAndImportedRowsCannotRepeat() throws {
        var imported = entry(
            id: "imported", occurredAt: 1_777_000_400, mealType: "daily_total",
            label: nil, calories: 2_000
        )
        imported.origin = NutritionLogContract.csvOrigin
        let recent = NutritionLogContract.recentManualEntries(from: [
            entry(id: "older", occurredAt: 1_777_000_100, label: "Oats", calories: 400),
            entry(id: "newer", occurredAt: 1_777_000_300, label: " oats ", calories: 400),
            entry(id: "shake", occurredAt: 1_777_000_200, label: "Shake", protein: 30),
            imported,
        ], limit: 4)

        XCTAssertEqual(recent.map(\.id), ["newer", "shake"])
        let repeated = try NutritionLogContract.repeatedManualEntry(
            from: recent[0],
            id: "repeat",
            day: day2,
            occurredAt: 1_787_395_200,
            timestamp: 1_787_395_200
        )
        XCTAssertEqual(repeated.id, "repeat")
        XCTAssertEqual(repeated.origin, NutritionLogContract.manualOrigin)
        XCTAssertEqual(repeated.label, "oats")
        XCTAssertEqual(repeated.caloriesKcal, 400)
        XCTAssertThrowsError(try NutritionLogContract.repeatedManualEntry(
            from: imported,
            id: "bad-repeat",
            day: day2,
            occurredAt: 1_787_395_200,
            timestamp: 1_787_395_200
        )) { error in
            XCTAssertEqual(
                error as? NutritionLogContract.ValidationError,
                .importedEntryCannotRepeat
            )
        }
    }

    func testResolutionAndRecentsRespectTheRequestedDevice() {
        let otherDevice = "nutrition-secondary"
        let canonical = entry(id: "canonical", calories: 400)
        let secondary = entry(id: "secondary", deviceId: otherDevice, calories: 725)

        let totals = NutritionLogContract.resolvedTotals(
            entries: [canonical, secondary],
            day: day2,
            deviceId: otherDevice
        )
        XCTAssertEqual(totals.caloriesKcal, 725)
        XCTAssertEqual(totals.manualEntryCount, 1)

        let recent = NutritionLogContract.recentManualEntries(
            from: [canonical, secondary],
            limit: 4,
            deviceId: otherDevice
        )
        XCTAssertEqual(recent.map(\.id), ["secondary"])
    }

    func testMultipleMealsProjectNullableDailySums() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertNutritionEntries([
            entry(id: "breakfast", day: day2, mealType: "breakfast",
                  calories: 450, protein: 30, carbs: 55),
            entry(id: "dinner", day: day2, mealType: "dinner",
                  calories: 700, protein: 45, fat: 28),
        ])

        let rows = try await store.nutritionEntries(from: day2, to: day2)
        XCTAssertEqual(rows.map(\.id), ["breakfast", "dinner"])
        let totals = try await store.nutritionTotals(day: day2)
        XCTAssertEqual(totals.caloriesKcal, 1_150)
        XCTAssertEqual(totals.proteinG, 75)
        XCTAssertEqual(totals.carbsG, 55)
        XCTAssertEqual(totals.fatG, 28)

        let projected = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.caloriesKey,
            from: day2,
            to: day2
        )
        XCTAssertEqual(projected.first?.value, 1_150)
    }

    func testMovingEntryReprojectsOldAndNewDays() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertNutritionEntries([
            entry(id: "meal", day: day1, calories: 500),
        ])
        try await store.upsertNutritionEntries([
            entry(id: "meal", day: day2, calories: 650, updatedAt: 1_777_000_200),
        ])

        let oldEntries = try await store.nutritionEntries(from: day1, to: day1)
        let newEntries = try await store.nutritionEntries(from: day2, to: day2)
        let oldProjection = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.caloriesKey,
            from: day1,
            to: day1
        )
        let newProjection = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.caloriesKey,
            from: day2,
            to: day2
        )
        XCTAssertTrue(oldEntries.isEmpty)
        XCTAssertEqual(newEntries.count, 1)
        XCTAssertTrue(oldProjection.isEmpty)
        XCTAssertEqual(newProjection.first?.value, 650)
    }

    func testDeletingLastEntryRemovesEveryProjectedNutrient() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertNutritionEntries([
            entry(id: "meal", day: day2, calories: 500, protein: 30),
        ])
        let firstDelete = try await store.deleteNutritionEntry(id: "meal")
        let secondDelete = try await store.deleteNutritionEntry(id: "meal")
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
        for key in NutritionLogContract.nutrientKeys {
            let projected = try await store.metricSeries(
                deviceId: NutritionLogContract.deviceId,
                key: key,
                from: day2,
                to: day2
            )
            XCTAssertTrue(projected.isEmpty, "\(key) left a stale projection")
        }
    }

    func testImportedValuesWinPerNutrientWithoutDoubleCountingManualMeals() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = [
            MetricPoint(day: day2, key: NutritionLogContract.caloriesKey, value: 1_800),
            MetricPoint(day: day2, key: NutritionLogContract.proteinKey, value: 120),
        ]
        try await store.upsertImportedNutritionDays(imported, updatedAt: 1_777_000_500)
        try await store.upsertImportedNutritionDays([
            MetricPoint(day: day2, key: NutritionLogContract.caloriesKey, value: 1_900),
            MetricPoint(day: day2, key: NutritionLogContract.proteinKey, value: 125),
        ], updatedAt: 1_777_000_600)
        try await store.upsertNutritionEntries([
            entry(id: "manual-snack", day: day2, mealType: "snack",
                  calories: 200, protein: 10, carbs: 40),
        ])

        let rows = try await store.nutritionEntries(from: day2, to: day2)
        XCTAssertEqual(rows.count, 2, "re-import must update its deterministic row, not duplicate")
        XCTAssertEqual(rows.first { $0.origin == NutritionLogContract.csvOrigin }?.caloriesKcal, 1_900)
        let totals = try await store.nutritionTotals(day: day2)
        XCTAssertEqual(totals.caloriesKcal, 1_900)
        XCTAssertEqual(totals.proteinG, 125)
        XCTAssertEqual(totals.carbsG, 40, "manual value should fill a nutrient absent from import")
        XCTAssertEqual(totals.importedEntryCount, 1)
        XCTAssertEqual(totals.manualEntryCount, 1)
        XCTAssertTrue(totals.hasMixedSources)

        let projected = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.caloriesKey,
            from: day2,
            to: day2
        )
        XCTAssertEqual(projected.first?.value, 1_900)

        let removedImport = try await store.deleteNutritionEntry(
            id: NutritionLogContract.csvEntryID(day: day2))
        XCTAssertTrue(removedImport)
        let promoted = try await store.nutritionTotals(day: day2)
        XCTAssertEqual(promoted.caloriesKcal, 200)
        XCTAssertEqual(promoted.proteinG, 10)
        XCTAssertEqual(promoted.carbsG, 40)
        XCTAssertFalse(promoted.hasImportedSummary)
        XCTAssertTrue(promoted.hasManualEntries)
    }

    func testV39MigratesLegacyCsvSeriesWithoutDeletingOriginals() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v38-sleep-gravity-sparse")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES
                    ('nutrition-csv', '2026-08-22', 'calories_in', 2100),
                    ('nutrition-csv', '2026-08-22', 'protein_g', 145)
                """)
        }
        try migrator.migrate(queue)

        try await queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nutritionEntry"),
                1
            )
            XCTAssertEqual(
                try Double.fetchOne(db, sql: """
                    SELECT caloriesKcal FROM nutritionEntry
                    WHERE id = 'nutrition-csv:2026-08-22'
                    """),
                2_100
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM metricSeries
                    WHERE deviceId = 'nutrition-csv' AND day = '2026-08-22'
                    """),
                2,
                "legacy source is provenance and must remain"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM metricSeries
                    WHERE deviceId = 'nutrition-log' AND day = '2026-08-22'
                    """),
                2
            )
        }
    }
}
