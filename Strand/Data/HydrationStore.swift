import CryptoKit
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
    case invalidDayKey
    case invalidStoredEntry
    case storeUnavailable
    case writeRejected
}

private enum HydrationEntryWriteIntent {
    case currentWrite
    case legacyCorrection
}

private enum LegacyHydrationEntrySnapshot {
    case absent
    case present([HydrationEntry])
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

    static func legacyScalarAmountML(_ value: Double) throws -> Int {
        let maximum = Double(WhoopStore.hydrationLegacyMaximumML)
        guard value.isFinite,
              value > 0,
              value <= maximum else {
            throw HydrationPersistenceError.invalidStoredEntry
        }
        let rounded = max(1, value.rounded())
        guard rounded <= maximum,
              let amountML = Int(exactly: rounded) else {
            throw HydrationPersistenceError.invalidStoredEntry
        }
        return amountML
    }

    fileprivate static func legacyScalarEntryID(
        day: String
    ) -> UUID {
        deterministicLegacyEntryID(
            kind: "scalar-v2",
            day: day,
            values: []
        )
    }

    static func isLegacyScalarEntry(
        _ entry: HydrationEntry,
        day dayKey: String
    ) -> Bool {
        entry.id == legacyScalarEntryID(
            day: dayKey
        )
    }

    /// Presentation compatibility for scalar-only rows created before their identifier became
    /// deterministic. Those builds still used represented-day noon, so a singleton row at that exact
    /// placeholder remains an older daily total rather than being presented as a confirmed drink time.
    static func isLegacyScalarPresentationEntry(
        _ entry: HydrationEntry,
        entries: [HydrationEntry],
        day dayKey: String
    ) -> Bool {
        if isLegacyScalarEntry(entry, day: dayKey) {
            return true
        }
        guard entries.count == 1,
              entries.first?.id == entry.id,
              let representedDay = legacyEntryDate(forDayKey: dayKey) else {
            return false
        }
        return entry.loggedAt == representedDay
    }

    private static func deterministicLegacyEntryID(
        kind: String,
        day: String,
        values: [Int]
    ) -> UUID {
        let material = Data(
            (
                "noop.hydration.\(kind).v1|\(day)|"
                + values.map(String.init).joined(separator: "|")
            )
                .utf8
        )
        let bytes = Array(SHA256.hash(data: material).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
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

    /// Strict `yyyy-MM-dd` validation and calendar-safe day arithmetic for explicit hydration routes.
    /// UTC is deliberate: these are already local calendar labels, so advancing their date components
    /// must not inherit a daylight-saving transition or silently resolve an invalid route to today.
    private static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func isValidDayKey(_ value: String) -> Bool {
        date(fromDayKey: value) != nil
    }

    static func trailingDayKeys(
        throughDay dayKey: String,
        days: Int
    ) -> [String]? {
        guard let end = date(fromDayKey: dayKey) else { return nil }
        let count = max(1, days)
        return (0..<count).compactMap { index in
            let offset = index - (count - 1)
            guard let date = dayCalendar.date(byAdding: .day, value: offset, to: end) else {
                return nil
            }
            return key(from: date)
        }
    }

    private static func date(fromDayKey value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else { return nil }
        let components = DateComponents(
            calendar: dayCalendar,
            timeZone: dayCalendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = dayCalendar.date(from: components),
              key(from: date) == value else { return nil }
        return date
    }

    private static func key(from date: Date) -> String {
        let components = dayCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Stable timestamp for converting one legacy scalar-only day into an editable entry.
    ///
    /// Noon in the represented local day stays inside the managed hydration contract for every real
    /// timezone (UTC-12 through UTC+14). Using `Date()` here made old days appear newly logged and could
    /// leave the generated document permanently unsyncable.
    static func legacyEntryDate(
        forDayKey value: String,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        guard value.count == 10 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            return nil
        }
        return date
    }

    /// Timestamp for a quick log routed to an explicit civil day.
    ///
    /// A log for the current local day keeps its real time. A backfilled day uses noon in that day,
    /// matching the legacy scalar migration: the actual drink time is unknown, but the entry must not
    /// be stamped into the day on which the user happened to enter it.
    static func quickLogDate(
        forDayKey value: String,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        guard let representedDay = legacyEntryDate(
            forDayKey: value,
            timeZone: timeZone
        ) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let currentDayKey = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return currentDayKey == value ? now : representedDay
    }
}

enum HydrationReadingSource: Equatable, Hashable, Sendable {
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

struct HydrationProvenanceStrings: Equatable, Sendable {
    let noopOnlyLabel: String
    let externalOnlyLabel: String
    let bothLabel: String
    let bothExplanation: String
}

struct HydrationSourceTotal: Equatable, Sendable {
    let source: HydrationReadingSource
    let valueML: Double
}

struct HydrationProvenancePresentation: Equatable, Sendable {
    let sourceLabel: String
    let explanation: String?
    let sourceTotals: [HydrationSourceTotal]
}

extension HydrationReading {
    /// Pure provenance model for the detail UI. The displayed value remains the observed maximum; when
    /// both source totals exist, the detail keeps them separate and explains why they are not summed.
    func provenance(
        strings: HydrationProvenanceStrings
    ) -> HydrationProvenancePresentation {
        switch source {
        case .noop:
            return HydrationProvenancePresentation(
                sourceLabel: strings.noopOnlyLabel,
                explanation: nil,
                sourceTotals: []
            )
        case .appleHealth:
            return HydrationProvenancePresentation(
                sourceLabel: strings.externalOnlyLabel,
                explanation: nil,
                sourceTotals: []
            )
        case .both:
            return HydrationProvenancePresentation(
                sourceLabel: strings.bothLabel,
                explanation: strings.bothExplanation,
                sourceTotals: [
                    HydrationSourceTotal(source: .noop, valueML: noopML),
                    HydrationSourceTotal(source: .appleHealth, valueML: appleHealthML),
                ]
            )
        }
    }
}

// MARK: - Per-entry model (#798) - individual logged drinks for edit/delete

/// One logged drink: a stable id, the amount (ml) and the wall-clock time it was logged. Local-only;
/// persisted in the same SQLite transaction as the daily total.
struct HydrationEntry: Identifiable, Equatable, Codable, Sendable {
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

    private func noopHydrationScalar(
        day: String,
        store: WhoopStore
    ) async throws -> Double? {
        let points = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        return points.first?.value
    }

    /// Log `amountMl` of fluid for `day` (defaults to today's local day). Reads the day's current total
    /// and upserts total + amount, so repeated taps accumulate. A non-positive amount is a no-op. Returns
    /// the new day total (ml). Additive by design — each tap is a quick-add, like the WHOOP buttons.
    /// Mirrors Android `HydrationStore.log`.
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> HydrationMutationResult {
        let now = Date()
        let dayKey = day ?? Repository.localDayKey(now)
        guard amountMl > 0,
              let loggedAt = HydrationStore.quickLogDate(
                  forDayKey: dayKey,
                  now: now
              ) else {
            return .failed
        }
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
                    try await hydrationEntriesUnserialized(day: dayKey),
                    amountMl: amountMl,
                    at: loggedAt
                )
                let next = try await store.replaceHydrationLogEntries(
                    try Self.storedHydrationEntries(entries, day: dayKey),
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
        return try await performSerializedHydrationRead { [self] in
            try await hydrationEntriesUnserialized(day: dayKey)
        }
    }

    /// Must run inside the repository hydration-operation queue. Mutations call this form directly so
    /// their read-modify-write remains one serialized operation instead of re-entering the same queue.
    private func hydrationEntriesUnserialized(
        day dayKey: String
    ) async throws -> [HydrationEntry] {
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
            let canonical = try Self.hydrationEntries(stored)
            // A process can terminate after the atomic SQLite migration commits but before the retired
            // UserDefaults payload is removed. Canonical rows prove the migration completed, so retire
            // that stale payload before returning; otherwise deleting the canonical rows could resurrect it.
            UserDefaults.standard.removeObject(
                forKey: HydrationStore.entriesKey(forDay: dayKey)
            )
            return canonical
        }
        #if DEBUG
        await runHydrationMigrationBarrierForTesting()
        #endif

        let existingScalar = try await noopHydrationScalar(
            day: dayKey,
            store: store
        )
        if let existingScalar,
           (!existingScalar.isFinite || existingScalar < 0) {
            throw HydrationPersistenceError.invalidStoredEntry
        }
        let legacy = try Self.legacyHydrationEntrySnapshot(day: dayKey)
        if case .present(let entries) = legacy {
            if !entries.isEmpty {
                let disposition =
                    try await migrateLegacyHydrationEntries(
                        entries,
                        day: dayKey,
                        store: store
                    )
                switch disposition {
                case .migrate:
                    break
                case .retire where existingScalar == 0:
                    UserDefaults.standard.removeObject(
                        forKey: HydrationStore.entriesKey(forDay: dayKey)
                    )
                    recordHydrationPersistence(
                        operation: "legacy_migration",
                        outcome: "retired"
                    )
                    return []
                case .retire, .deferForMixedDeletionState:
                    recordHydrationPersistence(
                        operation: "legacy_migration",
                        outcome: "deferred",
                        failureKind: "mixed_state"
                    )
                    return []
                case .deferForProfileConflict:
                    recordHydrationPersistence(
                        operation: "legacy_migration",
                        outcome: "deferred",
                        failureKind: "profile_conflict"
                    )
                    return []
                }
            }
            if entries.isEmpty {
                _ = try await store.replaceHydrationLogEntries(
                    [],
                    deviceId: HydrationStore.sourceId,
                    day: dayKey,
                    metricKey: HydrationStore.key
                )
            }
            UserDefaults.standard.removeObject(
                forKey: HydrationStore.entriesKey(forDay: dayKey)
            )
            return entries
        }

        // A pre-entry build may have only the scalar row. There is no timestamp-level evidence to split
        // that aggregate into drinks, so materialize one visibly identifiable imported daily total.
        // Its represented-day noon is a stable placeholder, not a claimed drink time.
        let existingTotal = existingScalar ?? 0
        guard existingTotal > 0 else { return [] }
        let migratedDuringRead = try await store.hydrationLogEntries(
            deviceId: HydrationStore.sourceId,
            day: dayKey
        )
        if !migratedDuringRead.isEmpty {
            return try Self.hydrationEntries(migratedDuringRead)
        }
        guard let representedDay = HydrationStore.legacyEntryDate(
            forDayKey: dayKey
        ) else {
            throw HydrationPersistenceError.invalidDayKey
        }
        let amountML = try HydrationStore.legacyScalarAmountML(existingTotal)
        let migrated = [
            HydrationEntry(
                id: HydrationStore.legacyScalarEntryID(
                    day: dayKey
                ),
                amountMl: amountML,
                loggedAt: representedDay
            ),
        ]
        let disposition = try await migrateLegacyHydrationEntries(
            migrated,
            day: dayKey,
            store: store
        )
        switch disposition {
        case .migrate:
            return migrated
        case .retire:
            _ = try await store.replaceHydrationLogEntries(
                [],
                deviceId: HydrationStore.sourceId,
                day: dayKey,
                metricKey: HydrationStore.key
            )
            recordHydrationPersistence(
                operation: "legacy_migration",
                outcome: "retired"
            )
            return []
        case .deferForMixedDeletionState:
            recordHydrationPersistence(
                operation: "legacy_migration",
                outcome: "deferred",
                failureKind: "mixed_state"
            )
            return []
        case .deferForProfileConflict:
            recordHydrationPersistence(
                operation: "legacy_migration",
                outcome: "deferred",
                failureKind: "profile_conflict"
            )
            return []
        }
    }

    private func migrateLegacyHydrationEntries(
        _ entries: [HydrationEntry],
        day dayKey: String,
        store: WhoopStore
    ) async throws -> ManagedHydrationLegacyDisposition {
        do {
            let disposition = try await store.adoptLegacyHydrationLogEntries(
                try Self.storedHydrationEntries(entries, day: dayKey),
                deviceId: HydrationStore.sourceId,
                day: dayKey,
                metricKey: HydrationStore.key
            )
            if disposition == .migrate {
                recordHydrationPersistence(
                    operation: "legacy_migration",
                    outcome: "saved"
                )
            }
            return disposition
        } catch {
            recordHydrationPersistence(
                operation: "legacy_migration",
                outcome: "failed",
                failureKind: AppDiagnosticsRecorder.failureKind(error)
            )
            throw error
        }
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
                    try await hydrationEntriesUnserialized(day: dayKey),
                    id: id
                )
                return await persistHydrationEntries(
                    next,
                    day: dayKey,
                    operation: "delete",
                    intent: .legacyCorrection
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
                    try await hydrationEntriesUnserialized(day: dayKey),
                    id: id,
                    amountMl: amountMl
                )
                return await persistHydrationEntries(
                    next,
                    day: dayKey,
                    operation: "update",
                    intent: .legacyCorrection
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
        operation: String,
        intent: HydrationEntryWriteIntent = .currentWrite
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
            let storedEntries = try Self.storedHydrationEntries(entries, day: dayKey)
            let total: Double?
            switch intent {
            case .currentWrite:
                total = try await store.replaceHydrationLogEntries(
                    storedEntries,
                    deviceId: HydrationStore.sourceId,
                    day: dayKey,
                    metricKey: HydrationStore.key
                )
            case .legacyCorrection:
                total = try await store.replaceHydrationLogEntriesAllowingLegacyReduction(
                    storedEntries,
                    deviceId: HydrationStore.sourceId,
                    day: dayKey,
                    metricKey: HydrationStore.key
                )
            }
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

    private static func legacyHydrationEntrySnapshot(
        day dayKey: String
    ) throws -> LegacyHydrationEntrySnapshot {
        let key = HydrationStore.entriesKey(forDay: dayKey)
        guard let object = UserDefaults.standard.object(forKey: key) else {
            return .absent
        }
        guard let data = object as? Data,
              data.count <= WhoopStore.hydrationLegacyMaximumPayloadBytes,
              let decoded = try? JSONDecoder().decode(
                  [HydrationEntry].self,
                  from: data
              ),
              decoded.count <= WhoopStore.hydrationLegacyMaximumEntryCount else {
            throw HydrationPersistenceError.invalidStoredEntry
        }
        return .present(decoded.sorted { $0.loggedAt < $1.loggedAt })
    }

    fileprivate static func hydrationEntries(
        _ stored: [HydrationLogEntry]
    ) throws -> [HydrationEntry] {
        try stored.map { entry in
            // Current limits are write-time policy. Older valid rows may exceed them and must remain
            // visible so the user can reduce or clear the day through the guarded correction path.
            guard let id = UUID(uuidString: entry.id),
                  HydrationStore.isValidDayKey(entry.day),
                  entry.amountML > 0,
                  entry.amountML <= WhoopStore.hydrationLegacyMaximumML,
                  entry.loggedAt > 0,
                  entry.loggedAt <= WhoopStore.hydrationLatestCompatibleUnixSecond else {
                throw HydrationPersistenceError.invalidStoredEntry
            }
            let loggedAt = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
            guard loggedAt.timeIntervalSince1970.isFinite else {
                throw HydrationPersistenceError.invalidStoredEntry
            }
            return HydrationEntry(
                id: id,
                amountMl: entry.amountML,
                loggedAt: loggedAt
            )
        }
    }

    fileprivate static func storedHydrationEntries(
        _ entries: [HydrationEntry],
        day dayKey: String
    ) throws -> [HydrationLogEntry] {
        try entries.map { entry in
            let seconds = entry.loggedAt.timeIntervalSince1970
            let wholeSeconds = seconds.rounded(.towardZero)
            guard seconds.isFinite,
                  seconds > 0,
                  seconds <= Double(WhoopStore.hydrationLatestCompatibleUnixSecond),
                  let loggedAt = Int(exactly: wholeSeconds),
                  loggedAt > 0,
                  loggedAt <= WhoopStore.hydrationLatestCompatibleUnixSecond else {
                throw HydrationPersistenceError.invalidStoredEntry
            }
            return HydrationLogEntry(
                id: entry.id.uuidString.lowercased(),
                day: dayKey,
                amountML: entry.amountMl,
                loggedAt: loggedAt
            )
        }
    }

    /// The last `days` local-day totals up to and including `now`, oldest first. Existing callers retain
    /// their calendar-today default; an explicitly routed detail uses the strict overload below.
    func hydrationHistory(
        days: Int = 7,
        now: Date = Date()
    ) async throws -> [(day: String, value: Double?)] {
        try await hydrationHistory(
            days: days,
            throughDay: Repository.localDayKey(now)
        )
    }

    /// Trailing local-day totals ending on one exact displayed day, oldest first. An invalid explicit day
    /// fails closed rather than falling back to today.
    func hydrationHistory(
        days: Int = 7,
        throughDay: String
    ) async throws -> [(day: String, value: Double?)] {
        let n = max(1, days)
        guard let dayKeys = HydrationStore.trailingDayKeys(
            throughDay: throughDay,
            days: n
        ),
        let fromKey = dayKeys.first,
        let toKey = dayKeys.last else {
            recordHydrationPersistence(
                operation: "history",
                outcome: "failed",
                failureKind: "invalid_day"
            )
            throw HydrationPersistenceError.invalidDayKey
        }
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
        return dayKeys.map { ($0, byDay[$0]) }
    }

    /// Hydration goal for `day`, or calendar today when omitted. An explicit historical day with no
    /// DailyMetric receives no live Effort input; it never borrows today's context.
    func hydrationGoalML(
        profileAge: Int,
        ageConfirmed: Bool,
        profileSex: String,
        sexConfirmed: Bool,
        weightKg: Double? = nil,
        weightConfirmed: Bool,
        day: String? = nil
    ) -> Int? {
        let context: DailyMetric?
        if let day {
            context = localCalendarToday?.day == day
                ? localCalendarToday
                : days.last(where: { $0.day == day })
        } else {
            context = localCalendarToday
        }
        return HydrationGoal.personalizedDailyGoalML(
            age: profileAge,
            ageConfirmed: ageConfirmed,
            sex: profileSex,
            sexConfirmed: sexConfirmed,
            weightKg: weightKg,
            weightConfirmed: weightConfirmed,
            effort: context?.strain
        )
    }
}
