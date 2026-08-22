import XCTest
@testable import WhoopStore

final class NutritionCatalogStoreTests: XCTestCase {
    private let now = 1_777_000_000

    private func item(
        id: String = "meal-oats",
        kind: String = NutritionCatalogContract.mealKind,
        name: String = "Overnight oats",
        barcode: String? = nil,
        source: String = NutritionCatalogContract.manualSource,
        saved: Bool = true,
        updatedAt: Int? = nil
    ) -> NutritionCatalogItemRow {
        NutritionCatalogItemRow(
            id: id,
            kind: kind,
            name: name,
            brand: "  NOOP Kitchen  ",
            barcode: barcode,
            servingQuantity: 1,
            servingUnit: "bowl",
            caloriesKcal: 420,
            proteinG: 28,
            carbsG: 52,
            fatG: 12,
            mealType: "breakfast",
            source: source,
            isSaved: saved,
            createdAt: now,
            updatedAt: updatedAt ?? now
        )
    }

    func testValidationNormalizesBarcodeAndBoundsText() throws {
        var row = item(
            id: "barcode:3017620422003",
            kind: NutritionCatalogContract.foodKind,
            name: "  Hazelnut spread\n",
            barcode: "3017-6204 22003",
            source: NutritionCatalogContract.openFoodFactsSource,
            saved: false
        )
        row.brand = String(repeating: "B", count: 200)
        let clean = try NutritionCatalogContract.validated(row)
        XCTAssertEqual(clean.name, "Hazelnut spread")
        XCTAssertEqual(clean.barcode, "3017620422003")
        XCTAssertEqual(clean.brand?.count, NutritionCatalogContract.maxBrandCharacters)
        XCTAssertEqual(
            try NutritionCatalogContract.barcodeID("3017620422003"),
            "barcode:3017620422003"
        )
        XCTAssertThrowsError(try NutritionCatalogContract.barcodeID("not-a-code"))
    }

    func testStoreSupportsSavedLibraryCacheUseAndDelete() async throws {
        let store = try await WhoopStore.inMemory()
        let saved = item()
        let cached = item(
            id: "barcode:3017620422003",
            kind: NutritionCatalogContract.foodKind,
            name: "Hazelnut spread",
            barcode: "3017620422003",
            source: NutritionCatalogContract.openFoodFactsSource,
            saved: false
        )
        let written = try await store.upsertNutritionCatalogItems([saved, cached])
        XCTAssertEqual(written, 2)

        let library = try await store.nutritionCatalogItems(savedOnly: true)
        XCTAssertEqual(library.map(\.id), [saved.id])
        let barcodeMatch = try await store.nutritionCatalogItem(barcode: "3017620422003")
        XCTAssertEqual(barcodeMatch?.id, cached.id)

        let marked = try await store.markNutritionCatalogItemUsed(id: saved.id, at: now + 100)
        XCTAssertTrue(marked)
        let used = try await store.nutritionCatalogItem(id: saved.id)
        XCTAssertEqual(used?.lastUsedAt, now + 100)
        let firstDelete = try await store.deleteNutritionCatalogItem(id: cached.id)
        let secondDelete = try await store.deleteNutritionCatalogItem(id: cached.id)
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
    }
}
