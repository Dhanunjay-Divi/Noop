import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Hydration tracker — opt-in confirmed water logging
//
// The user logs water with three quick taps (Sip 30 ml / Cup 237 ml / Bottle 500 ml). The day TOTAL is
// banked in the generic metric-series tall table under a dedicated source/key — the SAME `metricSeries`
// table + `upsertMetricSeries` path every other generic daily series uses (no schema change). Because the
// table holds one row per (deviceId, day, key), a tap reads the day's running total and re-upserts
// total + amount, so the stored value IS "the sum of today's hydration logged for this local day".
//
// This is the BYTE-PARITY twin of the Android `com.noop.analytics.HydrationStore`: identical source id
// ("hydration"), identical key ("hydration"), identical additive-accumulation logic, identical 7-day
// history projection (one row per local calendar day, nil for empty days, oldest first). Apple Health water
// stays in its own source partition and is merged conservatively at read time so mirrored logs are not
// blindly added. NOOP per-tap entries remain editable and local to this device.

enum HydrationMutationResult: Equatable, Sendable {
    /// The canonical row and editable entry state were both updated. `nil` is a successful cleared day.
    case saved(totalML: Double?)
    case failed

    var succeeded: Bool {
        if case .saved = self { return true }
        return false
    }

    var totalML: Double? {
        guard case .saved(let totalML) = self else { return nil }
        return totalML
    }
}

private enum HydrationPersistenceError: Error {
    case storeUnavailable
    case writeRejected
}

enum HydrationStore {
    /// Source/device id the hydration total is written under — its own local-only source so it is never
    /// confused with strap-imported or computed metrics. MUST match the Android `SOURCE_ID`.
    static let sourceId = "hydration"

    /// metricSeries key for the daily total (ml). MUST match the Android `KEY`.
    static let key = "hydration"

    /// Settings opt-in key (default OFF). The dashboard card + detail are hidden while this is false.
    /// MUST match the Android `NoopPrefs.KEY_HYDRATION_TRACKING` so the toggle reads the same on both.
    static let enabledKey = "noop.hydrationTracking"

    /// Legacy UserDefaults prefix retained only for one-time migration. New editable entries live in
    /// SQLite and commit in the same transaction as the `metricSeries` day total.
    static let entriesKeyPrefix = "noop.hydrationEntries."

    /// AppStorage key for the user's custom container size (ml) (#798). Default `cupML` until set.
    static let customSizeKey = "noop.hydrationCustomSizeML"

    static func entriesKey(forDay dayKey: String) -> String { entriesKeyPrefix + dayKey }

    static var notLoggedText: String {
        String(localized: "appwide.hydration.not_logged")
    }

    static func confirmedTotal(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func observedTotal(_ noopML: Double?, _ appleHealthML: Double?) -> Double? {
        [confirmedTotal(noopML), confirmedTotal(appleHealthML)].compactMap { $0 }.max()
    }

    static func cardValue(
        totalML: Double?,
        goalML: Int,
        missingText: String = notLoggedText
    ) -> String {
        guard let totalML = confirmedTotal(totalML) else { return missingText }
        return HydrationGoal.cardValueString(totalML: totalML, goalML: goalML)
    }
}

enum HydrationReadingSource: Equatable, Sendable {
    case noop
    case appleHealth
    case both
}

struct HydrationReading: Equatable, Sendable {
    let valueML: Double
    let source: HydrationReadingSource
    let noopML: Double
    let appleHealthML: Double
}

// MARK: - Per-entry model (#798) - individual logged drinks for edit/delete

/// One logged drink: a stable id, the amount (ml) and the wall-clock time it was logged. Local-only;
/// persisted in the same SQLite transaction as the daily total.
struct HydrationEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var amountMl: Int
    var loggedAt: Date

    init(id: UUID = UUID(), amountMl: Int, loggedAt: Date = Date()) {
        self.id = id
        self.amountMl = amountMl
        self.loggedAt = loggedAt
    }
}

/// Pure list operations over the per-day entries (#798). Kept free of persistence/UI so the add / delete /
/// edit / total math is unit-testable in isolation. The day total is ALWAYS the sum of the (clamped to ≥ 0)
/// entry amounts, so deleting or editing an entry can only ever produce a non-negative, self-consistent total.
enum HydrationEntries {
    /// Append a new entry. A non-positive amount is rejected (returns the list unchanged) so a stray 0/negative
    /// can never enter the list, matching `logHydration`'s no-op-on-non-positive contract.
    static func adding(_ entries: [HydrationEntry], amountMl: Int, at date: Date = Date()) -> [HydrationEntry] {
        guard amountMl > 0 else { return entries }
        return entries + [HydrationEntry(amountMl: amountMl, loggedAt: date)]
    }

    /// Remove the entry with `id` (a no-op if absent).
    static func removing(_ entries: [HydrationEntry], id: UUID) -> [HydrationEntry] {
        entries.filter { $0.id != id }
    }

    /// Set an existing entry's amount. A non-positive amount removes the entry (an edit to 0 is a delete),
    /// keeping the list free of zero rows. Unknown ids are ignored.
    static func updating(_ entries: [HydrationEntry], id: UUID, amountMl: Int) -> [HydrationEntry] {
        guard amountMl > 0 else { return removing(entries, id: id) }
        return entries.map { $0.id == id ? HydrationEntry(id: $0.id, amountMl: amountMl, loggedAt: $0.loggedAt) : $0 }
    }

    /// The day total (ml) = sum of the entry amounts, each clamped ≥ 0. Always non-negative.
    static func total(_ entries: [HydrationEntry]) -> Double {
        entries.reduce(0) { $0 + Double(max(0, $1.amountMl)) }
    }
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    /// Source-aware observed total. NOOP and Apple Health can contain duplicate logs for the same drink,
    /// so they are never added blindly; the higher source total is the conservative observed lower bound.
    func hydrationReading(day: String) async throws -> HydrationReading? {
        #if DEBUG
        if hydrationReadFailureForTesting {
            recordHydrationPersistence(
                operation: "read",
                outcome: "failed",
                failureKind: "injected"
            )
            throw HydrationPersistenceError.writeRejected
        }
        #endif
        guard let store = await storeHandle() else {
            recordHydrationPersistence(
                operation: "read",
                outcome: "failed",
                failureKind: "store_unavailable"
            )
            throw HydrationPersistenceError.storeUnavailable
        }
        do {
            async let noopRead = store.metricSeries(
                deviceId: HydrationStore.sourceId,
                key: HydrationStore.key,
                from: day,
                to: day
            )
            async let healthRead = store.metricSeries(
                deviceId: Self.appleHealthSource,
                key: HydrationStore.key,
                from: day,
                to: day
            )
            let (noopRows, healthRows) = try await (noopRead, healthRead)
            let noop = HydrationStore.confirmedTotal(noopRows.first?.value)
            let health = HydrationStore.confirmedTotal(healthRows.first?.value)
            guard let observed = HydrationStore.observedTotal(noop, health) else { return nil }
            let source: HydrationReadingSource
            if noop != nil, health != nil {
                source = .both
            } else {
                source = noop != nil ? .noop : .appleHealth
            }
            return HydrationReading(
                valueML: observed,
                source: source,
                noopML: noop ?? 0,
                appleHealthML: health ?? 0
            )
        } catch {
            recordHydrationPersistence(
                operation: "read",
                outcome: "failed",
                failureKind: AppDiagnosticsRecorder.failureKind(error)
            )
            throw error
        }
    }

    func hydrationTotal(day: String) async throws -> Double? {
        try await hydrationReading(day: day)?.valueML
    }

    private func noopHydrationTotal(day: String, store: WhoopStore) async throws -> Double {
        let points = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        return HydrationStore.confirmedTotal(points.first?.value) ?? 0
    }

    /// Log `amountMl` of fluid for `day` (defaults to today's local day). Reads the day's current total
    /// and upserts total + amount, so repeated taps accumulate. A non-positive amount is a no-op. Returns
    /// the new day total (ml). Additive by design — each tap is a quick-add, like the WHOOP buttons.
    /// Mirrors Android `HydrationStore.log`.
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> HydrationMutationResult {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0 else { return .failed }
        return await performSerializedHydrationMutation { [self] in
            #if DEBUG
            if hydrationWriteFailureForTesting {
                recordHydrationPersistence(
                    operation: "add",
                    outcome: "failed",
                    failureKind: "injected"
                )
                return .failed
            }
            #endif
            guard let store = await storeHandle() else {
                recordHydrationPersistence(
                    operation: "add",
                    outcome: "failed",
                    failureKind: "store_unavailable"
                )
                return .failed
            }
            do {
                let entries = HydrationEntries.adding(
                    try await hydrationEntries(day: dayKey),
                    amountMl: amountMl
                )
                let next = try await store.replaceHydrationLogEntries(
                    Self.storedHydrationEntries(entries, day: dayKey),
                    deviceId: HydrationStore.sourceId,
                    day: dayKey,
                    metricKey: HydrationStore.key
                )
                noteHydrationChanged()
                recordHydrationPersistence(operation: "add", outcome: "saved")
                return .saved(totalML: next)
            } catch {
                recordHydrationPersistence(
                    operation: "add",
                    outcome: "failed",
                    failureKind: AppDiagnosticsRecorder.failureKind(error)
                )
                return .failed
            }
        }
    }

    /// Confirmation-aware quick add for one-tap UI. Returns nil unless the canonical metric row was
    /// durably written, so callers never animate success or consume an action after a failed store write.
    @discardableResult
    func logHydrationConfirmed(amountMl: Int, day: String? = nil) async -> Double? {
        let result = await logHydration(amountMl: amountMl, day: day)
        guard case .saved(let totalML?) = result else { return nil }
        return totalML
    }

    // MARK: - Per-entry edit/delete (#798)

    /// Today (or `day`)'s individual logged drinks, oldest first. Legacy UserDefaults rows are migrated
    /// once into SQLite before being removed, so an update cannot split the editable list from its total.
    func hydrationEntries(day: String? = nil) async throws -> [HydrationEntry] {
        let dayKey = day ?? Repository.localDayKey(Date())
        #if DEBUG
        if hydrationReadFailureForTesting {
            throw HydrationPersistenceError.writeRejected
        }
        #endif
        guard let store = await storeHandle() else {
            throw HydrationPersistenceError.storeUnavailable
        }
        let stored = try await store.hydrationLogEntries(
            deviceId: HydrationStore.sourceId,
            day: dayKey
        )
        if !stored.isEmpty {
            return Self.hydrationEntries(stored)
        }

        let legacy = Self.legacyHydrationEntries(day: dayKey)
        if !legacy.isEmpty {
            _ = try await store.replaceHydrationLogEntries(
                Self.storedHydrationEntries(legacy, day: dayKey),
                deviceId: HydrationStore.sourceId,
                day: dayKey,
                metricKey: HydrationStore.key
            )
            UserDefaults.standard.removeObject(
                forKey: HydrationStore.entriesKey(forDay: dayKey)
            )
            return legacy
        }

        // A pre-entry build may have only the scalar row. Materialize it once as an editable entry so
        // the next delete/edit cannot accidentally discard that confirmed amount.
        let existingTotal = try await noopHydrationTotal(day: dayKey, store: store)
        guard existingTotal > 0 else { return [] }
        let migrated = [
            HydrationEntry(
                amountMl: max(1, Int(existingTotal.rounded())),
                loggedAt: Date()
            ),
        ]
        _ = try await store.replaceHydrationLogEntries(
            Self.storedHydrationEntries(migrated, day: dayKey),
            deviceId: HydrationStore.sourceId,
            day: dayKey,
            metricKey: HydrationStore.key
        )
        return migrated
    }

    /// Delete one logged entry by id, then re-derive the day total from the surviving entries and re-bank it
    /// into `metricSeries` so the ring, Today card and 7-day history all reflect the deletion. Returns the
    /// new day total (ml).
    @discardableResult
    func deleteHydrationEntry(
        id: UUID,
        day: String? = nil
    ) async -> HydrationMutationResult {
        let dayKey = day ?? Repository.localDayKey(Date())
        return await performSerializedHydrationMutation { [self] in
            do {
                let next = HydrationEntries.removing(
                    try await hydrationEntries(day: dayKey),
                    id: id
                )
                return await persistHydrationEntries(
                    next,
                    day: dayKey,
                    operation: "delete"
                )
            } catch {
                recordHydrationPersistence(
                    operation: "delete",
                    outcome: "failed",
                    failureKind: AppDiagnosticsRecorder.failureKind(error)
                )
                return .failed
            }
        }
    }

    /// Set an existing entry's amount (a non-positive amount deletes it), then re-derive + re-bank the day
    /// total. Returns the new day total (ml). Backs the "edit a logged drink / set a custom size" flow.
    @discardableResult
    func updateHydrationEntry(
        id: UUID,
        amountMl: Int,
        day: String? = nil
    ) async -> HydrationMutationResult {
        let dayKey = day ?? Repository.localDayKey(Date())
        return await performSerializedHydrationMutation { [self] in
            do {
                let next = HydrationEntries.updating(
                    try await hydrationEntries(day: dayKey),
                    id: id,
                    amountMl: amountMl
                )
                return await persistHydrationEntries(
                    next,
                    day: dayKey,
                    operation: "update"
                )
            } catch {
                recordHydrationPersistence(
                    operation: "update",
                    outcome: "failed",
                    failureKind: AppDiagnosticsRecorder.failureKind(error)
                )
                return .failed
            }
        }
    }

    /// The editable rows and scalar projection commit together; the focused UI revision advances only after
    /// the transaction succeeds.
    private func persistHydrationEntries(
        _ entries: [HydrationEntry],
        day dayKey: String,
        operation: String
    ) async -> HydrationMutationResult {
        #if DEBUG
        if hydrationWriteFailureForTesting {
            recordHydrationPersistence(
                operation: operation,
                outcome: "failed",
                failureKind: "injected"
            )
            return .failed
        }
        #endif
        guard let store = await storeHandle() else {
            recordHydrationPersistence(
                operation: operation,
                outcome: "failed",
                failureKind: "store_unavailable"
            )
            return .failed
        }
        do {
            let total = try await store.replaceHydrationLogEntries(
                Self.storedHydrationEntries(entries, day: dayKey),
                deviceId: HydrationStore.sourceId,
                day: dayKey,
                metricKey: HydrationStore.key
            )
            noteHydrationChanged()
            recordHydrationPersistence(operation: operation, outcome: "saved")
            return .saved(totalML: total)
        } catch {
            recordHydrationPersistence(
                operation: operation,
                outcome: "failed",
                failureKind: AppDiagnosticsRecorder.failureKind(error)
            )
            return .failed
        }
    }

    private func recordHydrationPersistence(
        operation: String,
        outcome: String,
        failureKind: String? = nil
    ) {
        var fields = [
            "operation": operation,
            "outcome": outcome,
        ]
        if let failureKind {
            fields["failure_kind"] = failureKind
        }
        AppDiagnosticsRecorder.shared.record(
            "hydration.persistence",
            fields: fields
        )
    }

    // MARK: - Entry persistence

    fileprivate static func legacyHydrationEntries(day dayKey: String) -> [HydrationEntry] {
        guard let data = UserDefaults.standard.data(forKey: HydrationStore.entriesKey(forDay: dayKey)),
              let decoded = try? JSONDecoder().decode([HydrationEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.loggedAt < $1.loggedAt }
    }

    fileprivate static func hydrationEntries(
        _ stored: [HydrationLogEntry]
    ) -> [HydrationEntry] {
        stored.compactMap { entry in
            guard let id = UUID(uuidString: entry.id) else { return nil }
            return HydrationEntry(
                id: id,
                amountMl: entry.amountML,
                loggedAt: Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
            )
        }
    }

    fileprivate static func storedHydrationEntries(
        _ entries: [HydrationEntry],
        day dayKey: String
    ) -> [HydrationLogEntry] {
        entries.map {
            HydrationLogEntry(
                id: $0.id.uuidString.lowercased(),
                day: dayKey,
                amountML: $0.amountMl,
                loggedAt: max(1, Int($0.loggedAt.timeIntervalSince1970))
            )
        }
    }

    /// The last `days` local-day totals up to and including today, OLDEST first, as (day, ml) pairs — one
    /// entry per calendar day with nil for days that have no confirmed log. Backs the 7-day mini bar
    /// history. `days`
    /// is clamped ≥ 1. Mirrors Android `HydrationStore.history` (a single ranged read projected onto the
    /// full day grid so unlogged days remain explicit missing values rather than vanishing or becoming zero).
    func hydrationHistory(
        days: Int = 7,
        now: Date = Date()
    ) async throws -> [(day: String, value: Double?)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = Repository.localDayKey(from)
        let toKey = Repository.localDayKey(now)
        let byDay: [String: Double]
        #if DEBUG
        if hydrationReadFailureForTesting {
            recordHydrationPersistence(
                operation: "history",
                outcome: "failed",
                failureKind: "injected"
            )
            throw HydrationPersistenceError.writeRejected
        }
        #endif
        guard let store = await storeHandle() else {
            recordHydrationPersistence(
                operation: "history",
                outcome: "failed",
                failureKind: "store_unavailable"
            )
            throw HydrationPersistenceError.storeUnavailable
        }
        do {
            async let noopRead = store.metricSeries(
                deviceId: HydrationStore.sourceId,
                key: HydrationStore.key,
                from: fromKey,
                to: toKey
            )
            async let healthRead = store.metricSeries(
                deviceId: Self.appleHealthSource,
                key: HydrationStore.key,
                from: fromKey,
                to: toKey
            )
            let (noopRows, healthRows) = try await (noopRead, healthRead)
            let noop = Dictionary(
                noopRows.compactMap { row in
                    HydrationStore.confirmedTotal(row.value).map { (row.day, $0) }
                },
                uniquingKeysWith: { _, last in last }
            )
            let health = Dictionary(
                healthRows.compactMap { row in
                    HydrationStore.confirmedTotal(row.value).map { (row.day, $0) }
                },
                uniquingKeysWith: { _, last in last }
            )
            byDay = noop.merging(health) { max($0, $1) }
        } catch {
            recordHydrationPersistence(
                operation: "history",
                outcome: "failed",
                failureKind: AppDiagnosticsRecorder.failureKind(error)
            )
            throw error
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key])
        }
    }

    /// Today's hydration goal (ml). R3: metric-aware — body weight personalises the baseline (~35 ml/kg)
    /// and an elevated skin temperature adds a modest heat bump, on top of the existing Effort bump. Pure
    /// math in `HydrationGoal`; this just feeds it the live inputs (today's `strain` is NOOP's 0–100
    /// Effort, `skinTempDevC` is today's skin-temp deviation from baseline). `weightKg == nil` falls back
    /// to the sex baseline, so a profile without a weight behaves exactly as before.
    func hydrationGoalML(profileSex: String, weightKg: Double? = nil) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex,
                                  weightKg: weightKg,
                                  effort: localCalendarToday?.strain,
                                  skinTempDevC: localCalendarToday?.skinTempDevC)
    }
}
