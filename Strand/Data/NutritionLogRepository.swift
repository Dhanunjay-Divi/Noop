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
    let fastingGlucose: LabMarkerRow?
}

struct NutritionLibrarySnapshot: Sendable {
    let items: [NutritionCatalogItemRow]
}

enum NutritionSummaryContract {
    static let fastingGlucoseKey = "fasting_glucose"
    static let macroDotCapacity = 24

    /// Lab Book can contain several same-day readings and qualitative rows. Nutrition shows only the
    /// latest numeric fasting-glucose value that existed by the selected day, never a future result.
    static func latestFastingGlucose(
        in rows: [LabMarkerRow],
        through day: String
    ) -> LabMarkerRow? {
        rows
            .filter {
                $0.markerKey == fastingGlucoseKey
                    && $0.day <= day
                    && $0.value?.isFinite == true
            }
            .max {
                if $0.takenAt == $1.takenAt { return $0.id < $1.id }
                return $0.takenAt < $1.takenAt
            }
    }

    static func bestEffortLatestFastingGlucose(
        in rows: [LabMarkerRow]?,
        through day: String
    ) -> LabMarkerRow? {
        guard let rows else { return nil }
        return latestFastingGlucose(in: rows, through: day)
    }

    /// The compact dot fields compare logged macros with one another. They do not imply a target,
    /// recommendation, or completeness. Missing and explicit-zero values both draw no filled dots,
    /// while the adjacent value keeps those two states distinguishable.
    static func relativeMacroDotCount(
        value: Double?,
        among values: [Double?],
        capacity: Int = macroDotCapacity
    ) -> Int {
        guard capacity > 0,
              let value,
              value.isFinite,
              value > 0 else { return 0 }
        let maximum = values.compactMap { candidate -> Double? in
            guard let candidate, candidate.isFinite, candidate > 0 else { return nil }
            return candidate
        }.max() ?? 0
        guard maximum > 0 else { return 0 }
        return min(capacity, max(1, Int(ceil(value / maximum * Double(capacity)))))
    }
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
        let markerDeviceID = deviceId
        async let fastingGlucoseRows: [LabMarkerRow]? = try? await store.labMarkers(
            deviceId: markerDeviceID,
            markerKey: NutritionSummaryContract.fastingGlucoseKey
        )
        let (loadedEntries, loadedTotals, loadedRecent, glucoseRows) = try await (
            entries,
            totals,
            recent,
            fastingGlucoseRows
        )
        let snapshot = NutritionLogDaySnapshot(
            entries: loadedEntries,
            totals: loadedTotals,
            recentManualEntries: loadedRecent,
            fastingGlucose: NutritionSummaryContract.bestEffortLatestFastingGlucose(
                in: glucoseRows,
                through: day
            )
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
