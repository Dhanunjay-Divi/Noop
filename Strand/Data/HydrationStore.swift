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
// history projection (one row per local calendar day, 0 for empty days, oldest first). Apple Health water
// stays in its own source partition and is merged conservatively at read time so mirrored logs are not
// blindly added. NOOP per-tap entries remain editable and local to this device.

enum HydrationStore {
    /// Source/device id the hydration total is written under — its own local-only source so it is never
    /// confused with strap-imported or computed metrics. MUST match the Android `SOURCE_ID`.
    static let sourceId = "hydration"

    /// metricSeries key for the daily total (ml). MUST match the Android `KEY`.
    static let key = "hydration"

    /// Settings opt-in key (default OFF). The dashboard card + detail are hidden while this is false.
    /// MUST match the Android `NoopPrefs.KEY_HYDRATION_TRACKING` so the toggle reads the same on both.
    static let enabledKey = "noop.hydrationTracking"

    /// UserDefaults prefix for the per-day entry list (#798). One JSON array per local day, keyed
    /// `noop.hydrationEntries.<yyyy-MM-dd>`. Local-only, on-device, never synced - the same privacy posture
    /// as the day total. The day total in `metricSeries` stays the canonical figure the rest of the app
    /// reads (Today card, ring, 7-day history); the entry list is the editable detail behind it, kept in
    /// sync so deleting/editing an entry re-derives and re-banks the total.
    static let entriesKeyPrefix = "noop.hydrationEntries."

    /// AppStorage key for the user's custom container size (ml) (#798). Default `cupML` until set.
    static let customSizeKey = "noop.hydrationCustomSizeML"

    static func entriesKey(forDay dayKey: String) -> String { entriesKeyPrefix + dayKey }
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
/// persisted as a JSON array per local day. `Codable`/`Equatable` so the list round-trips through
/// UserDefaults and is unit-testable.
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
    func hydrationReading(day: String) async -> HydrationReading? {
        guard let store = await storeHandle() else { return nil }
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
        let noop = ((try? await noopRead) ?? []).first?.value
        let health = ((try? await healthRead) ?? []).first?.value
        let noopML = max(0, noop?.isFinite == true ? (noop ?? 0) : 0)
        let healthML = max(0, health?.isFinite == true ? (health ?? 0) : 0)
        guard noop != nil || health != nil else { return nil }
        let source: HydrationReadingSource
        if noop != nil, health != nil {
            source = .both
        } else {
            source = noop != nil ? .noop : .appleHealth
        }
        return HydrationReading(
            valueML: max(noopML, healthML),
            source: source,
            noopML: noopML,
            appleHealthML: healthML
        )
    }

    func hydrationTotal(day: String) async -> Double {
        await hydrationReading(day: day)?.valueML ?? 0
    }

    private func noopHydrationTotal(day: String, store: WhoopStore) async -> Double {
        let points = (try? await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )) ?? []
        return points.first?.value ?? 0
    }

    /// Log `amountMl` of fluid for `day` (defaults to today's local day). Reads the day's current total
    /// and upserts total + amount, so repeated taps accumulate. A non-positive amount is a no-op. Returns
    /// the new day total (ml). Additive by design — each tap is a quick-add, like the WHOOP buttons.
    /// Mirrors Android `HydrationStore.log`.
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0 else { return await hydrationTotal(day: dayKey) }
        if let logged = await logHydrationConfirmed(amountMl: amountMl, day: dayKey) {
            return logged
        }
        return await hydrationTotal(day: dayKey)
    }

    /// Confirmation-aware quick add for one-tap UI. Returns nil unless the canonical metric row was
    /// durably written, so callers never animate success or consume an action after a failed store write.
    @discardableResult
    func logHydrationConfirmed(amountMl: Int, day: String? = nil) async -> Double? {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0, let store = await storeHandle() else { return nil }
        let current = await noopHydrationTotal(day: dayKey, store: store)
        let next = current + Double(amountMl)
        do {
            let changed = try await store.upsertMetricSeries(
                [MetricPoint(day: dayKey, key: HydrationStore.key, value: next)],
                deviceId: HydrationStore.sourceId
            )
            guard changed > 0 else { return nil }
        } catch {
            return nil
        }
        // #798 - also record the per-entry row so the detail can show, edit and delete this exact drink.
        let entries = HydrationEntries.adding(Self.hydrationEntries(day: dayKey), amountMl: amountMl)
        Self.writeHydrationEntries(entries, day: dayKey)
        // #989: hydration writes never bump refreshSeq, so tell the Today card directly.
        noteHydrationChanged()
        return next
    }

    // MARK: - Per-entry edit/delete (#798)

    /// Today (or `day`)'s individual logged drinks, oldest first, as persisted in UserDefaults. Empty when
    /// nothing has been logged that day. Local-only; never synced.
    func hydrationEntries(day: String? = nil) -> [HydrationEntry] {
        Self.hydrationEntries(day: day ?? Repository.localDayKey(Date()))
    }

    /// Delete one logged entry by id, then re-derive the day total from the surviving entries and re-bank it
    /// into `metricSeries` so the ring, Today card and 7-day history all reflect the deletion. Returns the
    /// new day total (ml).
    @discardableResult
    func deleteHydrationEntry(id: UUID, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.removing(Self.hydrationEntries(day: dayKey), id: id)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Set an existing entry's amount (a non-positive amount deletes it), then re-derive + re-bank the day
    /// total. Returns the new day total (ml). Backs the "edit a logged drink / set a custom size" flow.
    @discardableResult
    func updateHydrationEntry(id: UUID, amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.updating(Self.hydrationEntries(day: dayKey), id: id, amountMl: amountMl)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Re-derive the day total from `entries` and upsert it into `metricSeries` (the canonical total). The
    /// per-entry list is the source of truth for an edited/deleted day; this keeps the rest of the app in sync.
    @discardableResult
    private func rebankHydrationTotal(entries: [HydrationEntry], day dayKey: String) async -> Double {
        let total = HydrationEntries.total(entries)
        if let store = await storeHandle() {
            _ = try? await store.upsertMetricSeries(
                [MetricPoint(day: dayKey, key: HydrationStore.key, value: total)],
                deviceId: HydrationStore.sourceId)
        }
        // #989: edits/deletes funnel through here; tell the Today card directly (see logHydration).
        noteHydrationChanged()
        return total
    }

    // MARK: - Entry persistence (UserDefaults JSON, one array per local day)

    fileprivate static func hydrationEntries(day dayKey: String) -> [HydrationEntry] {
        guard let data = UserDefaults.standard.data(forKey: HydrationStore.entriesKey(forDay: dayKey)),
              let decoded = try? JSONDecoder().decode([HydrationEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.loggedAt < $1.loggedAt }
    }

    fileprivate static func writeHydrationEntries(_ entries: [HydrationEntry], day dayKey: String) {
        let key = HydrationStore.entriesKey(forDay: dayKey)
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The last `days` local-day totals up to and including today, OLDEST first, as (day, ml) pairs — one
    /// entry per calendar day with 0 for days that have no log. Backs the 7-day mini bar history. `days`
    /// is clamped ≥ 1. Mirrors Android `HydrationStore.history` (a single ranged read projected onto the
    /// full day grid so empty days read as 0 rather than vanishing).
    func hydrationHistory(days: Int = 7, now: Date = Date()) async -> [(day: String, value: Double)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = Repository.localDayKey(from)
        let toKey = Repository.localDayKey(now)
        let byDay: [String: Double]
        if let store = await storeHandle() {
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
            let noop = Dictionary(
                ((try? await noopRead) ?? []).map { ($0.day, $0.value) },
                uniquingKeysWith: { _, last in last }
            )
            let health = Dictionary(
                ((try? await healthRead) ?? []).map { ($0.day, $0.value) },
                uniquingKeysWith: { _, last in last }
            )
            byDay = noop.merging(health) { max($0, $1) }
        } else {
            byDay = [:]
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key] ?? 0)
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
