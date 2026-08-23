import Foundation
import WhoopStore

// MARK: - Local menstrual-cycle anchors

/// Period starts are intentionally isolated from strap/import/computed sources. A logged day is a
/// value-1 metric-series point; it remains on this device unless the user explicitly exports or enables
/// their own sync destination. Period starts anchor the awareness engine; optional per-day flow and
/// symptom details remain context-only and never become fertility, contraception, or diagnosis data.
enum CycleTrackingStore {
    /// Manual entries always stay separate from imported Apple Health anchors. That keeps provenance
    /// visible, lets an Apple Health deletion be reconciled without touching a date the user entered in
    /// NOOP, and prevents a later Health sync from silently overwriting a manual correction.
    static let sourceId = "noop-cycle"
    static let appleHealthSourceId = "apple-health-cycle"
    static let periodStartKey = "period_start"
    static let dailyLogKey = "daily_log_v1"
    static let loggedValue = 1.0
    static let earliestDay = "0000-01-01"
    static let latestDay = "9999-12-31"

    enum Source: String, Equatable, Sendable {
        case manual
        case appleHealth
    }

    struct Entry: Equatable, Sendable {
        let day: String
        let source: Source
    }

    enum Flow: Int, CaseIterable, Equatable, Sendable {
        case none
        case spotting
        case light
        case medium
        case heavy
    }

    enum Symptom: Int, CaseIterable, Hashable, Sendable {
        case cramps
        case headache
        case fatigue
        case bloating
        case moodChanges
        case breastTenderness
        case acne
        case nausea
        case backPain
        case cravings
    }

    struct DailyLog: Equatable, Sendable {
        let day: String
        let flow: Flow?
        let symptoms: Set<Symptom>

        init(day: String, flow: Flow?, symptoms: Set<Symptom>) {
            self.day = day
            self.flow = flow
            self.symptoms = symptoms
        }
    }

    /// One exact integer stored in the existing REAL metric cell. Bits 0...2 encode flow plus one
    /// (`0` means "not entered"); symptom flags begin at bit 3. Keeping a whole daily entry in one row
    /// makes save/delete atomic and distinguishes an explicit "no bleeding" from missing data.
    static func encode(_ log: DailyLog) -> Double? {
        guard Repository.isValidLocalDayKey(log.day) else { return nil }
        let flowCode = log.flow.map { $0.rawValue + 1 } ?? 0
        var symptomMask = 0
        for symptom in log.symptoms {
            symptomMask |= 1 << symptom.rawValue
        }
        let encoded = flowCode | (symptomMask << 3)
        return encoded == 0 ? nil : Double(encoded)
    }

    static func decode(day: String, value: Double) -> DailyLog? {
        guard Repository.isValidLocalDayKey(day),
              value.isFinite,
              value >= 0,
              value.rounded() == value,
              value <= Double(Int.max)
        else { return nil }
        let encoded = Int(value)
        let flowCode = encoded & 0b111
        guard flowCode <= Flow.heavy.rawValue + 1 else { return nil }
        let symptomMask = encoded >> 3
        let knownMask = Symptom.allCases.reduce(0) { $0 | (1 << $1.rawValue) }
        guard symptomMask & ~knownMask == 0 else { return nil }
        let flow = flowCode == 0 ? nil : Flow(rawValue: flowCode - 1)
        let symptoms = Set(Symptom.allCases.filter {
            symptomMask & (1 << $0.rawValue) != 0
        })
        guard flow != nil || !symptoms.isEmpty else { return nil }
        return DailyLog(day: day, flow: flow, symptoms: symptoms)
    }
}

extension Repository {
    /// Period-start entries, oldest first, with provenance. A manual entry wins when the same local
    /// day also exists in Apple Health; both physical rows remain isolated so deleting/reconciling one
    /// source can never delete the other.
    func periodStartEntries(from: String = CycleTrackingStore.earliestDay,
                            to: String = CycleTrackingStore.latestDay) async -> [CycleTrackingStore.Entry] {
        guard let store = await storeHandle() else { return [] }
        async let manualRead = store.metricSeries(deviceId: CycleTrackingStore.sourceId,
                                                  key: CycleTrackingStore.periodStartKey,
                                                  from: from, to: to)
        async let appleRead = store.metricSeries(deviceId: CycleTrackingStore.appleHealthSourceId,
                                                 key: CycleTrackingStore.periodStartKey,
                                                 from: from, to: to)
        let manual = (try? await manualRead) ?? []
        let apple = (try? await appleRead) ?? []

        var byDay: [String: CycleTrackingStore.Entry] = [:]
        for row in apple where row.value >= CycleTrackingStore.loggedValue {
            byDay[row.day] = .init(day: row.day, source: .appleHealth)
        }
        for row in manual where row.value >= CycleTrackingStore.loggedValue {
            byDay[row.day] = .init(day: row.day, source: .manual)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Effective period-start days, oldest first, merged across manual + Apple Health provenance.
    func periodStarts(from: String = CycleTrackingStore.earliestDay,
                      to: String = CycleTrackingStore.latestDay) async -> [String] {
        await periodStartEntries(from: from, to: to).map(\.day)
    }

    /// Log (or idempotently re-log) a local calendar day as cycle day 1.
    @discardableResult
    func logPeriodStart(day: String) async -> Bool {
        guard Self.isValidLocalDayKey(day), let store = await storeHandle() else { return false }
        do {
            _ = try await store.upsertMetricSeries(
                [MetricPoint(day: day, key: CycleTrackingStore.periodStartKey,
                             value: CycleTrackingStore.loggedValue)],
                deviceId: CycleTrackingStore.sourceId)
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    /// Remove one logged start. This is a physical row delete, not a sentinel marker.
    @discardableResult
    func deletePeriodStart(day: String) async -> Bool {
        guard Self.isValidLocalDayKey(day), let store = await storeHandle() else { return false }
        do {
            _ = try await store.deleteMetricSeriesPoint(deviceId: CycleTrackingStore.sourceId,
                                                         day: day,
                                                         key: CycleTrackingStore.periodStartKey)
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    /// Remove every start logged manually in NOOP after an explicit confirmation in the UI. Imported
    /// Apple Health anchors are deliberately untouched; they are controlled by Apple Health and the
    /// cycle-import opt-in.
    @discardableResult
    func deleteAllPeriodStarts() async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            _ = try await store.deleteMetricSeries(deviceId: CycleTrackingStore.sourceId,
                                                    key: CycleTrackingStore.periodStartKey)
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    /// Replace the imported Apple Health anchors in `[from, to]` with the exact currently-visible
    /// HealthKit set. This is idempotent, physically removes dates deleted in Health, and never touches
    /// manual NOOP entries. The caller must already have explicit cycle-awareness consent.
    @discardableResult
    func reconcileAppleHealthPeriodStarts(days: Set<String>,
                                          from: String = CycleTrackingStore.earliestDay,
                                          to: String = CycleTrackingStore.latestDay) async -> Bool {
        guard Self.isValidLocalDayKey(from) || from == CycleTrackingStore.earliestDay,
              Self.isValidLocalDayKey(to) || to == CycleTrackingStore.latestDay,
              from <= to,
              days.allSatisfy({ Self.isValidLocalDayKey($0) && $0 >= from && $0 <= to }),
              let store = await storeHandle() else { return false }
        do {
            let existing = try await store.metricSeries(
                deviceId: CycleTrackingStore.appleHealthSourceId,
                key: CycleTrackingStore.periodStartKey,
                from: from, to: to)
            let existingDays = Set(existing.map(\.day))
            var changed = false
            for day in existingDays.subtracting(days) {
                let deleted = try await store.deleteMetricSeriesPoint(
                    deviceId: CycleTrackingStore.appleHealthSourceId,
                    day: day,
                    key: CycleTrackingStore.periodStartKey)
                changed = changed || deleted > 0
            }
            let newDays = days.subtracting(existingDays)
            if !newDays.isEmpty {
                let rows = newDays.sorted().map {
                    MetricPoint(day: $0, key: CycleTrackingStore.periodStartKey,
                                value: CycleTrackingStore.loggedValue)
                }
                changed = (try await store.upsertMetricSeries(
                    rows, deviceId: CycleTrackingStore.appleHealthSourceId)) > 0 || changed
            }
            if changed { noteCycleTrackingChanged() }
            return true
        } catch {
            return false
        }
    }

    /// Purge only Apple Health-derived anchors when cycle import is turned off. Manual history stays.
    @discardableResult
    func deleteAllAppleHealthPeriodStarts() async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            let deleted = try await store.deleteMetricSeries(
                deviceId: CycleTrackingStore.appleHealthSourceId,
                key: CycleTrackingStore.periodStartKey)
            if deleted > 0 { noteCycleTrackingChanged() }
            return true
        } catch {
            return false
        }
    }

    /// Private per-day flow and symptom logs, oldest first. Corrupt or future-version rows fail closed
    /// instead of being interpreted as health information.
    func cycleDailyLogs(from: String = CycleTrackingStore.earliestDay,
                        to: String = CycleTrackingStore.latestDay) async -> [CycleTrackingStore.DailyLog] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.metricSeries(
            deviceId: CycleTrackingStore.sourceId,
            key: CycleTrackingStore.dailyLogKey,
            from: from,
            to: to
        )) ?? []
        return rows.compactMap {
            CycleTrackingStore.decode(day: $0.day, value: $0.value)
        }
    }

    /// Save one complete daily entry. Empty input physically deletes the row, so clearing a day leaves
    /// no sensitive tombstone behind.
    @discardableResult
    func saveCycleDailyLog(day: String,
                           flow: CycleTrackingStore.Flow?,
                           symptoms: Set<CycleTrackingStore.Symptom>) async -> Bool {
        guard Self.isValidLocalDayKey(day), let store = await storeHandle() else { return false }
        let log = CycleTrackingStore.DailyLog(day: day, flow: flow, symptoms: symptoms)
        do {
            if let value = CycleTrackingStore.encode(log) {
                _ = try await store.upsertMetricSeries(
                    [MetricPoint(day: day, key: CycleTrackingStore.dailyLogKey, value: value)],
                    deviceId: CycleTrackingStore.sourceId
                )
            } else {
                _ = try await store.deleteMetricSeriesPoint(
                    deviceId: CycleTrackingStore.sourceId,
                    day: day,
                    key: CycleTrackingStore.dailyLogKey
                )
            }
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteCycleDailyLog(day: String) async -> Bool {
        guard Self.isValidLocalDayKey(day), let store = await storeHandle() else { return false }
        do {
            _ = try await store.deleteMetricSeriesPoint(
                deviceId: CycleTrackingStore.sourceId,
                day: day,
                key: CycleTrackingStore.dailyLogKey
            )
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteAllCycleDailyLogs() async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            _ = try await store.deleteMetricSeries(
                deviceId: CycleTrackingStore.sourceId,
                key: CycleTrackingStore.dailyLogKey
            )
            noteCycleTrackingChanged()
            return true
        } catch {
            return false
        }
    }

    /// Strict YYYY-MM-DD validation prevents malformed or path-like user input from entering the
    /// lexicographically ranged metric store.
    nonisolated static func isValidLocalDayKey(_ day: String) -> Bool {
        guard day.count == 10,
              day[day.index(day.startIndex, offsetBy: 4)] == "-",
              day[day.index(day.startIndex, offsetBy: 7)] == "-" else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: day) else { return false }
        return formatter.string(from: parsed) == day
    }
}
