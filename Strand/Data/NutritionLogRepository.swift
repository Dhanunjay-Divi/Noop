import Foundation
import WhoopStore

enum NutritionLogRepositoryError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return String(localized: "NOOP could not open the private nutrition log on this device.")
        }
    }
}

struct NutritionLogDaySnapshot: Sendable {
    let entries: [NutritionEntryRow]
    let totals: NutritionDailyTotals
    let recentManualEntries: [NutritionEntryRow]
}

struct NutritionLibrarySnapshot: Sendable {
    let items: [NutritionCatalogItemRow]
}

@MainActor
extension Repository {
    /// One coherent read for the nutrition screen. The rich entries and scalar totals share the same
    /// local SQLite transaction substrate; no cloud account or network request is involved.
    func nutritionLogSnapshot(day: String) async throws -> NutritionLogDaySnapshot {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        #if DEBUG
        await AppleDemoSeeder.seedNutritionIfRequested(into: store)
        #endif
        async let entries = store.nutritionEntries(from: day, to: day)
        async let totals = store.nutritionTotals(day: day)
        async let recent = store.recentManualNutritionEntries(through: day, limit: 4)
        let snapshot = try await NutritionLogDaySnapshot(
            entries: entries,
            totals: totals,
            recentManualEntries: recent
        )
        #if DEBUG
        if AppleDemoSeeder.nutritionRequested {
            NSLog(
                "Nutrition demo snapshot day=\(day) entries=\(snapshot.entries.count) " +
                "recent=\(snapshot.recentManualEntries.count) " +
                "imported=\(snapshot.totals.importedEntryCount) " +
                "manual=\(snapshot.totals.manualEntryCount)"
            )
        }
        #endif
        return snapshot
    }

    func saveNutritionEntry(_ entry: NutritionEntryRow) async throws {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        _ = try await store.upsertNutritionEntries([entry])
    }

    func removeNutritionEntry(id: String) async throws {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        _ = try await store.deleteNutritionEntry(id: id)
    }

    func nutritionLibrarySnapshot() async throws -> NutritionLibrarySnapshot {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        return try await NutritionLibrarySnapshot(
            items: store.nutritionCatalogItems(savedOnly: true)
        )
    }

    func saveNutritionCatalogItem(_ item: NutritionCatalogItemRow) async throws {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        _ = try await store.upsertNutritionCatalogItems([item])
    }

    func removeNutritionCatalogItem(id: String) async throws {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        _ = try await store.deleteNutritionCatalogItem(id: id)
    }

    /// Cache first. Network lookup is an explicit user action and successful products are persisted
    /// before they are returned to the confirmation editor.
    func lookupNutritionBarcode(_ rawBarcode: String) async throws -> NutritionCatalogItemRow {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        if let cached = try await store.nutritionCatalogItem(barcode: rawBarcode) {
            return cached
        }
        let fetched = try await OpenFoodFactsClient.shared.product(barcode: rawBarcode)
        _ = try await store.upsertNutritionCatalogItems([fetched])
        return fetched
    }

    func markNutritionCatalogItemUsed(id: String, at timestamp: Int) async throws {
        guard let store = await storeHandle() else {
            throw NutritionLogRepositoryError.storeUnavailable
        }
        _ = try await store.markNutritionCatalogItemUsed(id: id, at: timestamp)
    }
}
