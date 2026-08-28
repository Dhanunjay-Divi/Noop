import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

private struct WorkoutRecoveryTrendPoint: Identifiable, Equatable {
    let startTs: Int
    let result: HeartRateRecovery.Result
    var id: Int { startTs }
}

struct ActiveZoneWeekSnapshot: Equatable {
    let minutes: ActiveZoneMinutes
    let daysWithData: Int

    static func resolve(
        moderate: [(day: String, value: Double)],
        vigorous: [(day: String, value: Double)],
        observed: [(day: String, value: Double)],
        includedDays: Set<String>
    ) -> Self? {
        func values(_ points: [(day: String, value: Double)],
                    allowZero: Bool) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: points.compactMap { point in
                guard includedDays.contains(point.day), point.value.isFinite,
                      allowZero ? point.value >= 0 : point.value > 0 else { return nil }
                return (point.day, point.value)
            })
        }
        let moderateByDay = values(moderate, allowZero: true)
        let vigorousByDay = values(vigorous, allowZero: true)
        let observedByDay = values(observed, allowZero: false)
        let completeDays = Set(moderateByDay.keys)
            .intersection(vigorousByDay.keys)
            .intersection(observedByDay.keys)
        guard !completeDays.isEmpty else { return nil }
        let moderateTotal = completeDays.reduce(0.0) { $0 + (moderateByDay[$1] ?? 0) }
        let vigorousTotal = completeDays.reduce(0.0) { $0 + (vigorousByDay[$1] ?? 0) }
        let observedTotal = completeDays.reduce(0.0) { $0 + (observedByDay[$1] ?? 0) }
        return Self(
            minutes: ActiveZoneMinutes(
                moderateMinutes: moderateTotal,
                vigorousMinutes: vigorousTotal,
                weeklyTarget: ActiveZoneMinutesCalculator.defaultWeeklyTarget,
                observedMinutes: observedTotal),
            daysWithData: completeDays.count)
    }
}

/// A half-open, calendar-aware workout window. Calendar arithmetic keeps a "day" honest across daylight
/// saving transitions, and overlap semantics include sessions that begin before midnight and finish after
/// it. This is shared by Today and the Workouts log so the two screens cannot disagree about day scope.
struct WorkoutDateWindow: Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    static func localDay(containing date: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return Self(lowerBound: Int(start.timeIntervalSince1970),
                    upperBound: Int(end.timeIntervalSince1970))
    }

    /// Resolve a persisted local `yyyy-MM-dd` key without passing through UTC. Today can deliberately
    /// surface the new calendar-day row before the 04:00 logical rollover when a just-finished night is
    /// banked there; deriving the workout window from this same key keeps every Today section on one day.
    static func localDay(dayKey: String, calendar: Calendar = .current) -> Self? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        // Stored day keys are Gregorian ISO dates regardless of the user's display calendar. Parse with
        // Gregorian semantics in the user's current time zone, then let the supplied calendar establish
        // the local midnight boundaries (which preserves DST behavior and alternate-calendar settings).
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard parts.count == 3,
              let date = gregorian.date(from: DateComponents(
                calendar: gregorian,
                timeZone: gregorian.timeZone,
                year: parts[0], month: parts[1], day: parts[2]
              )) else { return nil }
        return localDay(containing: date, calendar: calendar)
    }

    static func trailingCalendarDays(_ count: Int, endingOn date: Date = Date(),
                                     calendar: Calendar = .current) -> Self {
        let safeCount = max(1, count)
        let finalDay = calendar.startOfDay(for: date)
        let firstDay = calendar.date(byAdding: .day, value: -(safeCount - 1), to: finalDay) ?? finalDay
        let end = calendar.date(byAdding: .day, value: 1, to: finalDay)
            ?? finalDay.addingTimeInterval(86_400)
        return Self(lowerBound: Int(firstDay.timeIntervalSince1970),
                    upperBound: Int(end.timeIntervalSince1970))
    }

    /// User-picked dates are inclusive in the UI; the storage interval remains half-open internally.
    static func custom(from first: Date, through second: Date,
                       calendar: Calendar = .current) -> Self {
        let firstDay = calendar.startOfDay(for: min(first, second))
        let finalDay = calendar.startOfDay(for: max(first, second))
        let end = calendar.date(byAdding: .day, value: 1, to: finalDay)
            ?? finalDay.addingTimeInterval(86_400)
        return Self(lowerBound: Int(firstDay.timeIntervalSince1970),
                    upperBound: Int(end.timeIntervalSince1970))
    }

    func intersects(_ row: WorkoutRow) -> Bool {
        let effectiveEnd = row.endTs > row.startTs ? row.endTs : row.startTs + 1
        return row.startTs < upperBound && effectiveEnd > lowerBound
    }

    func filter(_ rows: [WorkoutRow]) -> [WorkoutRow] { rows.filter(intersects) }
}

struct WorkoutActivityCalendarSummary: Equatable {
    let countsByDay: [Date: Int]
    let activeDays: Int
    let totalMinutes: Int

    /// The calendar attributes a session to the local day it starts. A workout that only overlaps the
    /// leading boundary therefore stays outside both the header total and the visible cells.
    static func resolve(
        rows: [WorkoutRow],
        firstDay: Date,
        lastDay: Date,
        calendar: Calendar = .current
    ) -> Self {
        let lower = calendar.startOfDay(for: firstDay)
        let final = calendar.startOfDay(for: lastDay)
        let upper = calendar.date(byAdding: .day, value: 1, to: final)
            ?? final.addingTimeInterval(86_400)
        let lowerTs = Int(lower.timeIntervalSince1970)
        let upperTs = Int(upper.timeIntervalSince1970)
        let included = rows.filter { $0.startTs >= lowerTs && $0.startTs < upperTs }
        let counts = Dictionary(grouping: included) {
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval($0.startTs))
            )
        }
        .mapValues(\.count)
        let seconds = included.reduce(0.0) { total, row in
            if let duration = row.durationS, duration.isFinite, duration >= 0 {
                return total + duration
            }
            return total + Double(max(0, row.endTs - row.startTs))
        }
        return Self(
            countsByDay: counts,
            activeDays: counts.count,
            totalMinutes: Int(seconds / 60)
        )
    }
}

struct DayOverviewTarget: Identifiable {
    let date: Date
    var id: Date { Calendar.current.startOfDay(for: date) }
}

enum DailyOverviewScope: String {
    case all
    case activity

    var includesWholeDayMetrics: Bool { self == .all }
}

enum DailyOverviewPresentation {
    static func efficiencyFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return nil }
        return value <= 1 ? value : value / 100
    }

    static func efficiencyPercent(_ value: Double?) -> Double? {
        efficiencyFraction(value).map { $0 * 100 }
    }

    static func sleepScore(_ daily: DailyMetric?) -> Double? {
        guard let daily,
              let efficiency = efficiencyFraction(daily.efficiency)
        else { return nil }
        let normalized = DailyMetric(
            day: daily.day,
            totalSleepMin: daily.totalSleepMin,
            efficiency: efficiency,
            deepMin: daily.deepMin,
            remMin: daily.remMin,
            lightMin: daily.lightMin,
            disturbances: daily.disturbances,
            restingHr: daily.restingHr,
            avgHrv: daily.avgHrv,
            recovery: daily.recovery,
            strain: daily.strain,
            exerciseCount: daily.exerciseCount,
            spo2Pct: daily.spo2Pct,
            skinTempDevC: daily.skinTempDevC,
            respRateBpm: daily.respRateBpm,
            steps: daily.steps,
            activeKcalEst: daily.activeKcalEst,
            spo2Red: daily.spo2Red,
            spo2Ir: daily.spo2Ir,
            hrvMethod: daily.hrvMethod
        )
        return AnalyticsEngine.Rest.composite(daily: normalized)
    }
}

// MARK: - Workouts
//
// The activity log, instrument-grade and uniform. Built ONLY from the locked Noop
// component system (NoopMetrics / NoopCard / StatTile / SectionHeader /
// SegmentedPillControl / SourceBadge) so every card, tile and row lines up:
//
//  • a range pill (7D / 30D / 90D / 1Y / All) that filters the loaded sessions,
//  • a LazyVGrid of summary StatTiles (count / time / calories / distance / most-active),
//  • an "ACTIVITY BREAKDOWN" LazyVGrid of per-sport NoopCards - identical internal layout,
//  • an "ALL SESSIONS" NoopCard containing fixed-height rows (date · sport · dur · HR · kcal · dist · source).
//
// No custom card heights, paddings, colours or surfaces — uniformity is the bar.

struct WorkoutsView: View {
    @EnvironmentObject var repo: Repository
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
    /// Quick-action FAB or the tab) had no way to begin one from the obvious place. Injected here so the
    /// header/empty-state can start a live session and present the in-exercise view directly.
    @EnvironmentObject var model: AppModel
    @State private var showLiveWorkout = false
    @State private var showStartSport = false
    #if DEBUG
    @State private var showStrengthTrainer =
        ProcessInfo.processInfo.arguments.contains("--demo-strength-trainer")
    #else
    @State private var showStrengthTrainer = false
    #endif

    // Imperial/Metric display preference (D#103). Workout distances are stored in metres; the toggle
    // re-labels them to miles/yards. Display-only — nothing on disk changes.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    // Effort display scale (#268) — drives the effort hero's read-out. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// All loaded sessions, newest first. Seedable for previews. #797: this holds only the rows inside the
    /// currently-LOADED window (`loadedWindowDays`), not the entire history. A 1700+-workout import made
    /// the eager all-rows read + sort fire on every `refreshSeq` bump (first paint AND every backfill
    /// slice). First paint loads a bounded window; selecting a wider range than is loaded lazily pages in
    /// the rest (`expandWindow`).
    @State private var allRows: [WorkoutRow]
    @State private var loaded: Bool
    @State private var seededInitialRange = false
    @State private var range: Range = .all
    @State private var customStartDate = Calendar.current.date(
        byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State private var customEndDate = Calendar.current.startOfDay(for: Date())
    /// #797: how many trailing days of workouts are currently LOADED into `allRows`. First paint loads
    /// `Self.firstPaintWindowDays`; picking "All" (or a range wider than this) pages the full history in on
    /// demand. nil means the full history is loaded (the user expanded to "All"). Preview rows are treated
    /// as fully loaded (nil) so the preview path is unchanged.
    @State private var loadedWindowDays: Int?
    private let usesPreviewRows: Bool

    /// #797: trailing-day window the FIRST workouts read is bounded to, so first paint never sorts a
    /// multi-thousand-workout history. Comfortably covers the default range (the tightest range with ≥2
    /// sessions, almost always ≤90 days); a wider pick pages the rest in via `expandWindow`. 400 days
    /// covers the 1Y range plus headroom.
    static let firstPaintWindowDays = 400

    // iPhone (.compact) can't fit the labelled "Add workout" button beside the 5-segment range pill -
    // the button got crushed into a tall sliver (#234/#339). Stack them there; iPad/Mac keep one row.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// The labelled workout actions fit side-by-side on Mac/iPad, but need a full-width stack on
    /// compact iPhone widths. Keep the platform check here so the shared macOS target never references
    /// the iOS-only size-class environment value.
    private var usesCompactWorkoutActionLayout: Bool {
        #if os(iOS)
        hSizeClass == .compact
        #else
        false
        #endif
    }

    /// The add/edit sheet target: `.some(nil)` = add a new workout, `.some(row)` = edit `row`,
    /// `nil` = sheet closed. Wrapped in Identifiable so `.sheet(item:)` can drive presentation.
    @State private var sheet: WorkoutSheetTarget?

    /// The read-only detail screen target — a tapped session. Drives a `.sheet(item:)` separate from
    /// the add/edit sheet so a primary tap (detail) and the ••• menu (edit) never collide. (#410)
    @State private var detail: WorkoutDetailTarget?

    /// A tapped day in the activity calendar. Every cell, including an empty day, opens the same
    /// exact-day overview used by the month calendar.
    @State private var dayOverview: DayOverviewTarget?

    /// A transient one-line note shown after a manual save / relabel for a sport that already has a
    /// solid/building ActivityCost entry - "Sessions like this usually …" (#439). Auto-clears.
    @State private var postLogNote: String?

    /// #516: eligible workouts in the visible 7/30/90-day window, calculated from recorded HR. Wider
    /// workout ranges intentionally keep this trend capped at 90 days so opening a deep history never
    /// launches hundreds of raw-HR reads.
    @State private var recoveryTrend: [WorkoutRecoveryTrendPoint] = []
    @State private var activeZoneWeek: ActiveZoneWeekSnapshot?
    @State private var activeZoneLoaded = false

    // MARK: - Filters + selection (#64)

    /// Filter beyond the time range: a displayed-sport key (nil = all), an origin class (nil = all), and
    /// a free-text search over the displayed sport. Pure `WorkoutFilter` applies them after the window cut.
    @State private var sportFilter: String?
    @State private var sourceFilter: WorkoutSource?
    @State private var searchText = ""

    /// Multi-select + merge mode. `selectionMode` toggles the leading checkmarks + the toolbar strip;
    /// `selected` holds the natural keys ("startTs|sport") of the chosen rows. Only MANUAL / DETECTED rows
    /// are selectable (imported history is read-only and can never be merged or bulk-deleted).
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    /// When every selected row is a bare detected bout, the merge has no sport to keep — this drives a
    /// small confirm sheet asking the user to name the merged session.
    @State private var mergeSportPrompt: MergeSportTarget?

    /// The selection key for a row (its natural key). Stable across a reload so the checkmarks persist.
    private func selectionKey(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    /// Wraps the pending merge inputs so a `.sheet(item:)` can present the "name the merged session" prompt
    /// (used only when every selected row is detected, so there's no sport to inherit).
    private struct MergeSportTarget: Identifiable {
        let rows: [WorkoutRow]
        let id = UUID()
    }

    /// Wraps the optional edited row so `.sheet(item:)` can present add (editing == nil) or edit.
    private struct WorkoutSheetTarget: Identifiable {
        let editing: WorkoutRow?
        let id = UUID()
    }

    /// Wraps a tapped row so `.sheet(item:)` can present its detail screen.
    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }

    init(previewRows: [WorkoutRow]? = nil) {
        _allRows = State(initialValue: previewRows ?? [])
        _loaded = State(initialValue: previewRows != nil)
        // Preview-seeded rows are treated as the full history (nil window) so the preview path never pages.
        _loadedWindowDays = State(initialValue: previewRows != nil ? nil : Self.firstPaintWindowDays)
        usesPreviewRows = previewRows != nil
    }

    var body: some View {
        ScreenScaffold(title: "Workouts", subtitle: "Every session, threaded together.",
                       onRefresh: { await repo.refresh() },
                       // PERF: the column ends in the full "All Sessions" log (the breakdown grid, the
                       // zones card, and a row-per-session table). On a large imported history the eager
                       // VStack built every section + the whole table up-front; the LazyVStack path (which
                       // is byte-identical layout) builds the off-screen sections/rows on demand instead.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       topBackground: liquidScaffoldSky()) {
            if allRows.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    if loaded {
                        ScreenStateCard(
                            kind: .empty,
                            title: "No workouts yet",
                            message: "They come from your wearable and Apple Health history. Import in Data Sources to bring them in, or add one you tracked elsewhere.",
                            symbol: "figure.run"
                        )
                    } else {
                        ScreenStateCard(
                            kind: .loading,
                            title: "Loading workouts",
                            message: "Reading your saved and imported sessions."
                        )
                    }
                    if loaded {
                        if usesCompactWorkoutActionLayout {
                            VStack(spacing: NoopMetrics.rowSpacing) {
                                startLiveWorkoutButton
                                addWorkoutButton
                                strengthTrainerButton
                            }
                        } else {
                            HStack(spacing: NoopMetrics.rowSpacing) {
                                startLiveWorkoutButton
                                addWorkoutButton
                            }
                            strengthTrainerButton
                        }
                        activityCalendarSection(rows: [])
                        activeZoneSection
                    }
                }
            } else {
                // Compute the windowed rows and per-sport groups ONCE per body
                // evaluation, then thread them into every section. SwiftUI re-runs
                // `body` on hover/animation/1Hz HR ticks; the previous computed-
                // property fan-out (rows → selected range → sessions(_:), and
                // sportGroups → rows → …) rebuilt the same filters/aggregations
                // several times per render. Same windowing, same results.
                let windowRows = sessions(for: range)
                let groups = sportGroups(from: windowRows)
                let zonesSummary = WorkoutZones.summary(from: windowRows)

                if usesCompactWorkoutActionLayout {
                    VStack(spacing: NoopMetrics.rowSpacing) {
                        startLiveWorkoutButton
                        strengthTrainerButton
                    }
                } else {
                    HStack(spacing: NoopMetrics.rowSpacing) {
                        startLiveWorkoutButton
                        strengthTrainerButton
                        Spacer()
                    }
                }
                rangeBar(rows: windowRows)
                activityCalendarSection(rows: allRows)
                activeZoneSection
                if let postLogNote { postLogBanner(postLogNote) }
                if windowRows.isEmpty {
                    emptySelectedRange
                } else {
                    effortHero(rows: windowRows, selectedRange: range, groups: groups)
                    summarySection(rows: windowRows, selectedRange: range, groups: groups)
                    breakdownSection(groups: groups, rows: windowRows)
                    if let z = zonesSummary {
                        zonesSection(z, totalSessions: windowRows.count)
                    }
                    recoveryTrendSection
                    sessionsSection(rows: windowRows)
                }
            }
        }
        .task(id: "\(repo.refreshSeq)|\(repo.workoutsSeq)") {
            guard !usesPreviewRows else { return }
            // #797: read only the currently-loaded window (bounded on first paint), not the whole history.
            let r = await repo.workoutRows(days: loadedWindowDays ?? 4000)
            allRows = r
            let wasLoaded = loaded
            loaded = true
            if !wasLoaded {
                let initialRange = defaultRange(for: r)
                range = initialRange
                seededInitialRange = true
                // `.all` is wider than the bounded first-paint query. When the best initial range is
                // already All, `onChange(range)` does not fire (`.all` -> `.all`), so explicitly expand
                // here rather than labelling a 400-day subset as all time—or declaring an older history
                // empty because the first bounded page happened to contain nothing.
                if initialRange == .all { await expandWindowIfNeeded(for: .all) }
            }
        }
        .onAppear {
            // Preview-seeded rows skip `.task`; still choose a range that has data.
            if loaded && !seededInitialRange {
                range = defaultRange(for: allRows)
                seededInitialRange = true
            }
        }
        // #797: when the user picks a range wider than the bounded first-paint window (typically "All"),
        // page the full history in. A pick that fits the loaded window is a no-op. Empty selections stay
        // empty: the screen never silently widens the user's requested dates.
        .onChangeCompat(of: range) { newRange in
            Task { await expandWindowIfNeeded(for: newRange) }
        }
        .task(id: recoveryTrendInputKey) {
            await loadRecoveryTrend()
        }
        .task(id: repo.refreshSeq) {
            guard !usesPreviewRows else {
                activeZoneLoaded = true
                return
            }
            await loadActiveZoneWeek()
        }
        .sheet(item: $sheet) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                Task {
                    await repo.saveManualWorkout(row, replacing: replacing)
                    // #598: rescore the just-added workout from the strap's HR for its window NOW, so its
                    // average / peak HR, strain and calories appear immediately (from your own strap data)
                    // instead of waiting up to 15 minutes for the next analyze tick. No-ops when the strap
                    // had no HR for that window, and never overrides a value you typed yourself.
                    await model.intelligence.analyzeRecent()
                    await reload()
                    // Post-log note (#439): if this sport now has a solid/building recovery-cost
                    // entry, surface its personal-pattern sentence as a transient caption.
                    await showPostLogNote(forSport: WorkoutSource.displaySport(row.sport))
                }
            }
        }
        .sheet(item: $detail) { target in
            // These shared screens aren't hosted in a per-screen NavigationStack, so the read-only
            // detail rides its own NavigationStack inside the sheet (the Done toolbar item + iOS
            // grabber give the dismiss affordances). Mirrors HealthView presenting MetricDetailView.
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        .sheet(item: $dayOverview) { target in
            NavigationStack {
                DailyOverviewSheet(date: target.date, scope: .activity)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 760)
            #endif
        }
        // #459: the in-exercise view, presented when Start Workout is tapped here (same screen LiveView
        // shows). activeWorkout is global on AppModel, so ending it from either surface stays in sync.
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                // Inject the shared live snapshot so the in-exercise sensor readout (speed/cadence/power)
                // resolves here too, matching how LiveView presents the same screen.
                .environmentObject(model.live)
        }
        // #519: name the sport before a live session starts, then open the in-exercise view directly
        // (same direct present as the button's already-active path — no cross-view auto-present race).
        .sheet(isPresented: $showStartSport) {
            StartWorkoutSheet { name in
                model.startWorkout(sport: name)
                showLiveWorkout = true
            }
        }
        .sheet(isPresented: $showStrengthTrainer) {
            StrengthTrainerView()
                .environmentObject(repo)
        }
        // #64: name the merged session when every selected row is a bare detected bout (there's no sport
        // to inherit). Reuses the "Start a workout" named-sport picker.
        .sheet(item: $mergeSportPrompt) { target in
            StartWorkoutSheet(title: String(localized: "Name the merged session"),
                              subtitle: String(localized: "These sessions have no sport label yet. Pick one for the merged session."),
                              actionVerb: String(localized: "Merge")) { name in
                performMerge(target.rows, sport: name)
            }
        }
    }

    /// Present the read-only detail for a tapped row. The primary affordance; the ••• menu stays the
    /// secondary path for edit/relabel/delete.
    private func openDetail(_ row: WorkoutRow) { detail = WorkoutDetailTarget(row: row) }

    /// Re-read every source after a mutation so the screen reflects the new state immediately.
    /// Keeps the user's current range — only the initial load picks a default. A now-empty window remains
    /// visibly empty rather than jumping to older workouts.
    private func reload() async {
        allRows = await repo.workoutRows(days: loadedWindowDays ?? 4000)
    }

    // MARK: - Heart-rate recovery trend (#516)

    /// Apply the screen's active filter + range, capped to the latest 90 days as promised by the feature.
    private var recoveryTrendRows: [WorkoutRow] {
        let visible = sessions(for: range)
        // Anchor the cap to the newest workout INSIDE the selected range, not to today. Otherwise a
        // historical custom range truthfully contains sessions but its promised "latest 90 days within
        // this range" recovery chart is forced empty.
        guard let newest = visible.max(by: { $0.startTs < $1.startTs }) else { return [] }
        let latestNinety = WorkoutDateWindow.trailingCalendarDays(
            90, endingOn: Date(timeIntervalSince1970: TimeInterval(newest.startTs)))
        return latestNinety.filter(visible).sorted { $0.startTs < $1.startTs }
    }

    /// Stable task identity: changing the range/filter/rows or HRmax cancels and rebuilds the trend.
    private var recoveryTrendInputKey: String {
        let rows = recoveryTrendRows
        return "\(repo.refreshSeq)|\(model.profile.hrMax)|"
            + rows.map { "\($0.startTs):\($0.endTs)" }.joined(separator: ",")
    }

    private var recoveryTrendCaption: String {
        if range == .all || range == .year {
            return String(localized: "latest 90 days within \(rangeDisplayLabel(for: range))")
        }
        if range == .custom,
           WorkoutDateWindow.custom(from: customStartDate, through: customEndDate).upperBound
                - WorkoutDateWindow.custom(from: customStartDate, through: customEndDate).lowerBound
                > 90 * 86_400 {
            return String(localized: "latest 90 days within \(rangeDisplayLabel(for: range))")
        }
        return rangeDisplayLabel(for: range)
    }

    private func loadRecoveryTrend() async {
        guard !usesPreviewRows else { recoveryTrend = []; return }
        var built: [WorkoutRecoveryTrendPoint] = []
        for row in recoveryTrendRows {
            if Task.isCancelled { return }
            if let result = await repo.workoutHeartRateRecovery(
                from: row.startTs, to: row.endTs, maxHR: Double(model.profile.hrMax)) {
                built.append(WorkoutRecoveryTrendPoint(startTs: row.startTs, result: result))
            }
        }
        guard !Task.isCancelled else { return }
        recoveryTrend = built
    }

    private func loadActiveZoneWeek() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = Set((0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(Repository.dayString)
        })
        async let moderate = repo.exploreSeries(
            key: ActiveZoneMinutesCalculator.moderateSeriesKey,
            source: "my-whoop",
            days: 8)
        async let vigorous = repo.exploreSeries(
            key: ActiveZoneMinutesCalculator.vigorousSeriesKey,
            source: "my-whoop",
            days: 8)
        async let observed = repo.exploreSeries(
            key: ActiveZoneMinutesCalculator.observedSeriesKey,
            source: "my-whoop",
            days: 8)
        let snapshot = await ActiveZoneWeekSnapshot.resolve(
            moderate: moderate,
            vigorous: vigorous,
            observed: observed,
            includedDays: days)
        guard !Task.isCancelled else { return }
        activeZoneWeek = snapshot
        activeZoneLoaded = true
    }

    @ViewBuilder private var activeZoneSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(
                "appwide.workouts.active_minutes_title",
                overline: "appwide.trends.last_7_days")
            NoopCard(tint: StrandPalette.statusPositive) {
                if let summary = activeZoneWeek {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("appwide.workouts.active_minutes_guideline")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(
                            String(
                                format: String(localized: "appwide.workouts.active_minutes_progress_format"),
                                Int(summary.minutes.creditedMinutes.rounded()),
                                Int(summary.minutes.weeklyTarget.rounded()))
                        )
                        .font(StrandFont.number(30))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        GeometryReader { geometry in
                            let progress = min(
                                max(summary.minutes.targetFraction, 0),
                                1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(StrandPalette.surfaceInset)
                                Capsule()
                                    .fill(StrandPalette.statusPositive)
                                    .frame(width: geometry.size.width * progress)
                            }
                        }
                        .frame(height: 10)
                        .accessibilityHidden(true)
                        HStack(spacing: NoopMetrics.space4) {
                            activeZoneStat(
                                String(localized: "appwide.workouts.active_minutes_moderate"),
                                minutes: summary.minutes.moderateMinutes,
                                tint: StrandPalette.zone3)
                            activeZoneStat(
                                String(localized: "appwide.workouts.active_minutes_vigorous"),
                                minutes: summary.minutes.vigorousMinutes,
                                tint: StrandPalette.zone4)
                        }
                        Label {
                            Text(
                                String(
                                    format: String(
                                        localized: "appwide.workouts.active_minutes_coverage_format"),
                                    durationLabel(summary.minutes.observedMinutes * 60),
                                    summary.daysWithData)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "heart.text.square")
                                .accessibilityHidden(true)
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        Divider().overlay(StrandPalette.hairline)
                        Text("appwide.workouts.active_minutes_note")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("noop.workouts.active-minutes")
                } else if activeZoneLoaded {
                    Text("appwide.workouts.active_minutes_no_data")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(
                            String(localized: "appwide.workouts.active_minutes_title"))
                }
            }
        }
    }

    private func activeZoneStat(_ label: String, minutes: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(
                String(
                    format: String(localized: "appwide.workouts.active_minutes_value_format"),
                    Int(minutes.rounded()))
            )
                .font(StrandFont.number(18))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var recoveryTrendSection: some View {
        if !recoveryTrend.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Recovery Trend", overline: "Heart-rate recovery · \(recoveryTrendCaption)",
                              trailing: recoveryTrend.count == 1
                                ? String(localized: "1 workout")
                                : String(localized: "\(recoveryTrend.count) workouts"))
                NoopCard(tint: StrandPalette.metricRose) {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkoutRecoveryTrendChart(points: recoveryTrend)
                            .frame(height: NoopMetrics.chartHeight)
                        HStack(spacing: 16) {
                            recoveryLegend("1 min", color: StrandPalette.metricRose)
                            recoveryLegend("2 min", color: StrandPalette.metricCyan)
                            recoveryLegend("5 min", color: StrandPalette.metricPurple)
                        }
                        Divider().overlay(StrandPalette.hairline)
                        Text("Each line shows how many beats per minute your heart rate changed after exercise. Only high-intensity workouts with recorded post-workout heart rate are included.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recoveryLegend(_ label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// #797: page the FULL workout history in when the user selects a range wider than the bounded
    /// first-paint window. Idempotent: once expanded (`loadedWindowDays == nil`) it never re-reads here.
    /// Only a pick of `.all` (or a future range exceeding the loaded window) triggers the one-time full
    /// read, so the common 7D/30D/90D/1Y interactions stay on the already-loaded bounded set.
    private func expandWindowIfNeeded(for picked: Range) async {
        guard !usesPreviewRows, loadedWindowDays != nil else { return }
        // A bounded range that fits inside what's already loaded needs no wider read.
        if let pickedDays = picked.days, pickedDays <= (loadedWindowDays ?? 0) { return }
        loadedWindowDays = nil
        allRows = await repo.workoutRows(days: 4000)
    }

    // MARK: - Post-log activity-cost note (#439)

    /// After a manual save / relabel, look up whether `sport` has a solid/building ActivityCost entry
    /// (n ≥ minSessions) and, if so, show its plain-English sentence as a transient caption that
    /// auto-clears. Copy is "usually"/"personal pattern" framed (the engine's own wording) - never a
    /// law. Computes off the freshly reloaded sessions + the merged daily Charge.
    private func showPostLogNote(forSport sport: String) async {
        let costs = InsightsView.computeActivityCosts(workouts: allRows, days: repo.days)
        guard let match = costs.first(where: { $0.sport == sport }) else {
            await MainActor.run { postLogNote = nil }
            return
        }
        let sentence = match.sentence()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence } }
        // Auto-dismiss after a few seconds (transient caption, not a permanent card).
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        await MainActor.run {
            if postLogNote == sentence { withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil } }
        }
    }

    /// The transient "personal pattern" caption - an Effort-tinted frosted strip with a chart glyph.
    private func postLogBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.effortColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .strokeBorder(StrandPalette.effortColor.opacity(0.22), lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Row actions (edit · relabel · dismiss · delete)

    private func editWorkout(_ row: WorkoutRow) { sheet = WorkoutSheetTarget(editing: row) }

    private func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo.relabelDetected(row, sport: sport)
            await reload()
            await showPostLogNote(forSport: WorkoutSource.displaySport(sport))
        }
    }

    private func dismiss(_ row: WorkoutRow) {
        Task { await repo.dismissDetected(row); await reload() }
    }

    private func delete(_ row: WorkoutRow) {
        // #524: also drop any on-device GPS route stored under this session's natural key, so deleting a
        // workout doesn't leave its route orphaned in the RouteStore side-store.
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        Task { await repo.deleteWorkout(row); await reload() }
    }

    /// Common sports offered when re-labelling a detected bout (keeps the menu short and honest —
    /// the user can fine-tune via Edit afterwards).
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    // MARK: - Range control

    private func rangeBar(rows: [WorkoutRow]) -> some View {
        let caption = rangeCaption(rows: rows)
        #if os(iOS)
        let stacked = hSizeClass == .compact
        #else
        let stacked = false
        #endif
        return VStack(alignment: .leading, spacing: 8) {
            if stacked {
                // iPhone: button on its own row, the range pill full-width below — no crushed sliver.
                addWorkoutButton
                if dynamicTypeSize.isAccessibilitySize {
                    accessibleRangeMenu
                } else {
                    SegmentedPillControl(Range.allCases, selection: $range,
                                         adaptsToAvailableWidth: true) { $0.label }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    addWorkoutButton
                    Spacer()
                    SegmentedPillControl(Range.allCases, selection: $range,
                                         adaptsToAvailableWidth: true) { $0.label }
                }
            }
            if range == .custom { customRangePicker }
            filterBar
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(caption)
        }
    }

    /// Fixed trailing-30-day activity calendar. It counts persisted sessions only; an empty day is
    /// rendered as empty rather than assumed rest, and multiple sessions remain visibly distinct.
    private func activityCalendarSection(rows: [WorkoutRow]) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let dates = (0..<30).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        let startWeekday = calendar.component(.weekday, from: first)
        let leading = (startWeekday - calendar.firstWeekday + 7) % 7
        let summary = WorkoutActivityCalendarSummary.resolve(
            rows: rows,
            firstDay: first,
            lastDay: today,
            calendar: calendar
        )
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(
                "appwide.workouts.activity_calendar.title",
                overline: "appwide.trends.last_30_days",
                trailing: summary.activeDays == 1
                    ? String(localized: "appwide.workouts.activity_calendar.one_active_day")
                    : String.localizedStringWithFormat(
                        String(localized: "appwide.workouts.activity_calendar.active_days"),
                        summary.activeDays
                    )
            )
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(first.formatted(.dateTime.month(.abbreviated)))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(today.formatted(.dateTime.month(.abbreviated).year()))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                    LazyVGrid(columns: columns, spacing: 7) {
                        ForEach(
                            Array(weekdayInitials(calendar).enumerated()),
                            id: \.offset
                        ) { entry in
                            Text(entry.element)
                                .font(StrandFont.overlineScaled(9))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(0..<leading, id: \.self) { _ in
                            Color.clear.frame(height: 44)
                        }
                        ForEach(dates, id: \.self) { date in
                            activityDay(
                                date,
                                count: summary.countsByDay[
                                    calendar.startOfDay(for: date),
                                    default: 0
                                ],
                                isToday: calendar.isDate(date, inSameDayAs: today)
                            )
                        }
                    }

                    Divider().overlay(StrandPalette.hairline)

                    HStack(spacing: NoopMetrics.space4) {
                        calendarLegend("1", color: StrandPalette.chargeColor.opacity(0.75))
                        calendarLegend("2", color: StrandPalette.statusPositive)
                        calendarLegend("3+", color: StrandPalette.metricCyan)
                        Spacer(minLength: 4)
                        Text(String.localizedStringWithFormat(
                            String(localized: "appwide.workouts.active_minutes_value_format"),
                            summary.totalMinutes
                        ))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    private func activityDay(_ date: Date, count: Int, isToday: Bool) -> some View {
        let color: Color = {
            switch count {
            case 1: return StrandPalette.chargeColor.opacity(0.75)
            case 2: return StrandPalette.statusPositive
            case 3...: return StrandPalette.metricCyan
            default: return StrandPalette.surfaceInset
            }
        }()
        return Button {
            dayOverview = DayOverviewTarget(date: date)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color)
                if isToday {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(StrandPalette.textPrimary.opacity(0.9), lineWidth: 1.2)
                }
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(count > 0 ? Color.black.opacity(0.82) : StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activityDayAccessibilityLabel(date: date, count: count))
        .accessibilityHint(Text("appwide.day_overview.open_hint"))
        .accessibilityIdentifier("noop.workouts.day.\(Repository.localDayKey(date))")
    }

    private func calendarLegend(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityLabel(
            label == "3+"
                ? String(localized: "appwide.workouts.activity_calendar.three_or_more")
                : String.localizedStringWithFormat(
                    String(localized: "appwide.workouts.activity_calendar.legend_activities"),
                    label
                )
        )
    }

    private func activityDayAccessibilityLabel(date: Date, count: Int) -> String {
        let countDescription = count == 1
            ? String(localized: "appwide.workouts.activity_calendar.one_recorded_activity")
            : String.localizedStringWithFormat(
                String(localized: "appwide.workouts.activity_calendar.recorded_activities"),
                count
            )
        return String.localizedStringWithFormat(
            String(localized: "appwide.workouts.activity_calendar.day_description"),
            date.formatted(date: .long, time: .omitted),
            countDescription
        )
    }

    private func weekdayInitials(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    private var accessibleRangeMenu: some View {
        Menu {
            ForEach(Range.allCases, id: \.self) { option in
                Button {
                    range = option
                } label: {
                    if option == range {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                Text("Time range")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(range.label)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        }
        .accessibilityLabel("Time range")
        .accessibilityValue(range.label)
    }

    private var customRangePicker: some View {
        NoopCard(padding: 12, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CUSTOM DATES")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    DatePicker("From", selection: customStartBinding,
                               in: ...customEndDate, displayedComponents: .date)
                    DatePicker("To", selection: customEndBinding,
                               in: customStartDate...Date(), displayedComponents: .date)
                }
                .datePickerStyle(.compact)
                Text(rangeDisplayLabel(for: .custom))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var customStartBinding: Binding<Date> {
        Binding(get: { customStartDate }, set: { customStartDate = min($0, customEndDate) })
    }

    private var customEndBinding: Binding<Date> {
        Binding(get: { customEndDate }, set: { customEndDate = min(Date(), max($0, customStartDate)) })
    }

    /// #64: filter controls beside the range pill — a Sport menu, a Source menu, and a search field, with
    /// an "×" clear chip that appears only when a filter is active. Present on both size classes / both
    /// platforms. The predicate is the pure `WorkoutFilter`; these controls only drive its state.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                filterMenu(
                    title: sportFilter ?? String(localized: "All sports"),
                    active: sportFilter != nil,
                    a11y: String(localized: "Filter by sport")
                ) {
                    Button(String(localized: "All sports")) { sportFilter = nil }
                    Divider()
                    ForEach(availableSports, id: \.self) { s in
                        Button(s) { sportFilter = s }
                    }
                }
                filterMenu(
                    title: sourceFilter.map(Self.sourceFilterLabel) ?? String(localized: "All sources"),
                    active: sourceFilter != nil,
                    a11y: String(localized: "Filter by source")
                ) {
                    Button(String(localized: "All sources")) { sourceFilter = nil }
                    Divider()
                    ForEach(Self.sourceFilterOptions, id: \.self) { opt in
                        Button(Self.sourceFilterLabel(opt)) { sourceFilter = opt }
                    }
                }
                if filter.isActive {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            sportFilter = nil; sourceFilter = nil; searchText = ""
                        }
                    } label: {
                        Label(String(localized: "Clear"), systemImage: "xmark.circle.fill")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityLabel(String(localized: "Clear filters"))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text("Search sport").foregroundColor(StrandPalette.textSecondary)
                )
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// A pill-styled filter menu: the current selection as its label, tinted the Effort colour when a
    /// filter is active so the user can see at a glance that the list is narrowed.
    private func filterMenu<Content: View>(title: String, active: Bool, a11y: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title).font(StrandFont.footnote).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(active ? StrandPalette.effortColor : StrandPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (active ? StrandPalette.effortColor.opacity(0.14) : StrandPalette.surfaceInset),
                in: Capsule()
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(a11y)
        .accessibilityValue(title)
    }

    /// The origin classes offered in the Source filter (imported + on-device), in a stable menu order.
    private static let sourceFilterOptions: [WorkoutSource] =
        [.whoop, .apple, .detected, .manual, .lifting, .activityFile]

    /// The Source-filter menu label for an origin class (matches the row source badges).
    private static func sourceFilterLabel(_ c: WorkoutSource) -> String {
        switch c {
        case .whoop:        return String(localized: "Imported")
        case .apple:        return String(localized: "Apple")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    /// Opens the add sheet (editing == nil). Present on the populated screen and the empty state so a
    /// user with no imports can still log a session.
    private var addWorkoutButton: some View {
        NoopButton(
            "Add workout",
            systemImage: "plus",
            kind: .secondary,
            fullWidth: usesCompactWorkoutActionLayout
        ) {
            sheet = WorkoutSheetTarget(editing: nil)
        }
        .accessibilityLabel("Add a workout")
    }

    /// #459: begin (or jump back into) a live, manually-tracked workout straight from Workouts — the
    /// place people instinctively look — instead of only from the Live screen. Starts the session and
    /// presents the in-exercise view directly (no cross-view auto-present race with LiveView's sheet).
    private var startLiveWorkoutButton: some View {
        Button {
            // No active session → pick a named sport first (#519), then the sheet's onStart begins it
            // and opens the in-exercise view. Already active → jump straight back into the live view.
            if model.activeWorkout == nil { showStartSport = true }
            else { showLiveWorkout = true }
        } label: {
            HStack(spacing: NoopButtonMetrics.iconSpacing) {
                SemanticBodyIllustration(
                    .workout(systemImage: model.activeWorkout.map { sportSymbol($0.sport) } ?? "figure.run"),
                    size: 30,
                    tint: StrandPalette.effortColor,
                    isActive: model.activeWorkout != nil
                )
                Text(model.activeWorkout == nil
                     ? String(localized: "Start workout")
                     : String(localized: "View active workout"))
            }
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: usesCompactWorkoutActionLayout))
        .accessibilityLabel(model.activeWorkout == nil ? "Start a workout" : "View the active workout")
    }

    /// Detailed resistance-training log. Kept separate from generic imported workout summaries so
    /// editable exercises and sets never get flattened into one opaque workout row.
    private var strengthTrainerButton: some View {
        NoopButton(
            "Strength Trainer",
            systemImage: "dumbbell.fill",
            kind: .secondary,
            fullWidth: usesCompactWorkoutActionLayout
        ) {
            showStrengthTrainer = true
        }
        .accessibilityLabel(Text("appwide.strength.open"))
    }

    /// The active filter (#64), composed once. Sport / source / search all apply AFTER the window cut,
    /// so the effort hero, tiles, breakdown, zones and list all read one filtered set.
    private var filter: WorkoutFilter {
        WorkoutFilter(sport: sportFilter, sourceClass: sourceFilter, search: searchText)
    }

    /// Sessions inside the exact requested calendar range, then passed through the active filter.
    /// Presets end today; custom dates are inclusive. No sparse-data fallback or implicit widening.
    private func sessions(for r: Range) -> [WorkoutRow] {
        let windowed = dateWindow(for: r)?.filter(allRows) ?? allRows
        return filter.apply(windowed)
    }

    private func dateWindow(for r: Range, now: Date = Date()) -> WorkoutDateWindow? {
        switch r {
        case .week:    return .trailingCalendarDays(7, endingOn: now)
        case .month:   return .trailingCalendarDays(30, endingOn: now)
        case .quarter: return .trailingCalendarDays(90, endingOn: now)
        case .year:    return .trailingCalendarDays(365, endingOn: now)
        case .custom:  return .custom(from: customStartDate, through: customEndDate)
        case .all:     return nil
        }
    }

    /// The set of displayed-sport names present across ALL loaded rows, for the sport-filter menu.
    /// Ordered by frequency (desc) so the common sports sit at the top.
    private var availableSports: [String] {
        var counts: [String: Int] = [:]
        for r in allRows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// "N sessions · <exact range>" near the control. Appends "· filtered" (#64) when a filter narrows
    /// the list; zero stays zero so the UI never presents old history as part of a sparse selection.
    private func rangeCaption(rows: [WorkoutRow]) -> String {
        guard loaded, !allRows.isEmpty else { return "-" }
        let n = rows.count
        let suffix = filter.isActive ? String(localized: " · filtered") : ""
        let dateLabel = rangeDisplayLabel(for: range)
        return (n == 1
            ? String(localized: "1 session · \(dateLabel)")
            : String(localized: "\(n) sessions · \(dateLabel)")) + suffix
    }

    /// Pick the tightest exact, today-anchored preset that holds ≥2 sessions; otherwise show All.
    private func defaultRange(for source: [WorkoutRow]) -> Range {
        guard !source.isEmpty else { return .all }
        for r in [Range.week, .month, .quarter, .year] {
            if (dateWindow(for: r)?.filter(source).count ?? 0) >= 2 { return r }
        }
        return .all
    }

    private func rangeDisplayLabel(for r: Range) -> String {
        guard r == .custom else { return r.caption }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(customStartDate, customEndDate))
        let end = calendar.startOfDay(for: max(customStartDate, customEndDate))
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(date: .abbreviated, time: .omitted)
        }
        return String(localized: "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
    }

    private var emptySelectedRange: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                MetricGlyph("calendar.badge.minus", size: 38)
                VStack(alignment: .leading, spacing: 5) {
                    Text("No workouts in this range")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Nothing was logged during \(rangeDisplayLabel(for: range)). Choose another range, start a session, or add one manually.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Effort hero (typical effort on a flat Reset card)

    /// Design Reset hero for the windowed range: the typical session Effort on the clean flat ring
    /// (GlowRing, bloom OFF), on a flat opaque Reset card — NO scenic backdrop float — with the session
    /// count + total time alongside. The ring reads the AVERAGE per-session strain (the stored 0–100
    /// Effort axis, mirroring the Today effort ring); the headline number is shown on the user's scale.
    @ViewBuilder
    private func effortHero(rows: [WorkoutRow], selectedRange: Range, groups: [SportGroup]) -> some View {
        let strains = rows.compactMap(\.strain)
        let avgStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let totalTimeH = rows.compactMap(\.durationS).reduce(0, +) / 3600.0
        NoopCard(padding: 20, tint: StrandPalette.effortColor) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    effortHeroGauge(avgStrain: avgStrain, hasData: !strains.isEmpty)
                    effortHeroStats(rows: rows, selectedRange: selectedRange,
                                    groups: groups, totalTimeH: totalTimeH)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .center, spacing: 16) {
                    effortHeroGauge(avgStrain: avgStrain, hasData: !strains.isEmpty)
                    effortHeroStats(rows: rows, selectedRange: selectedRange,
                                    groups: groups, totalTimeH: totalTimeH)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func effortHeroGauge(avgStrain: Double, hasData: Bool) -> some View {
        // The signature liquid gauge: a filling `LiquidVessel` tinted Effort with the typical effort
        // counting up over it — the SAME hero language Today's score cells, the Sleep Rest hero and the
        // Trends headline use. The vessel fills to value/max on the user's selected Effort scale; the big
        // number is the same `effortDisplay` read-out the old ring showed.
        let diameter: CGFloat = 168
        let scaleMax: Double = effortScale == .whoop ? 21 : 100
        let displayValue = UnitFormatter.effortValue(avgStrain, scale: effortScale)
        let fraction = max(0, min(1, displayValue / scaleMax))
        VStack(spacing: 18) {
            Text("TYPICAL EFFORT")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.effortColor)
            if hasData {
                ZStack {
                    // Hero vessel → animated (this is one of the page's live gauges, like the Sleep Rest
                    // hero and the Today score cells). Reduce-Motion falls back to the static frame inside
                    // LiquidVessel itself.
                    LiquidVessel(value: fraction, tint: StrandPalette.effortColor, animated: true)
                        .frame(width: diameter, height: diameter)
                    VStack(spacing: 0) {
                        // `displayValue` is already on the selected scale (0–100 or 0–21), so the count-up
                        // interpolates it straight to one decimal — no re-scaling in the format closure.
                        CountUpText(
                            value: displayValue,
                            format: { String(format: "%.1f", $0) },
                            font: StrandFont.rounded(46),
                            color: StrandPalette.onDarkPrimary
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                        Text(effortScale == .whoop ? "of 21" : "of 100")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.onDarkSecondary)
                    }
                    .allowsHitTesting(false)   // taps fall through to the vessel → splash
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Typical effort \(UnitFormatter.effortDisplay(avgStrain, scale: effortScale))"))
            } else {
                // No strain data in the window - an empty vessel (posed, no fill) with a centred "No data",
                // the honest liquid analogue of the old empty ring.
                ZStack {
                    LiquidVessel(value: 0, tint: StrandPalette.effortColor, animated: false)
                        .frame(width: diameter, height: diameter)
                    Text("No data")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.onDarkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Typical effort, no data"))
            }
        }
    }

    @ViewBuilder
    private func effortHeroStats(rows: [WorkoutRow], selectedRange: Range,
                                 groups: [SportGroup], totalTimeH: Double) -> some View {
        let modal = modalSport(from: groups)
        let dateLabel = rangeDisplayLabel(for: selectedRange)
        VStack(alignment: .leading, spacing: 12) {
            Text("Effort · \(dateLabel)")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: NoopMetrics.gap) {
                heroCountStat(String(localized: "Sessions"), value: Double(rows.count),
                              format: { "\(Int($0.rounded()))" }, tint: StrandPalette.effortColor)
                heroStat(String(localized: "Active"), String(localized: "\(oneDecimal(totalTimeH))h"), tint: StrandPalette.textPrimary)
                heroStat(String(localized: "Top sport"), modal.count > 0 ? "\(modal.count)×" : "-",
                         tint: StrandPalette.effortBright)
            }
            Text(modal.count > 0
                 ? "Mostly \(WorkoutSource.displaySport(modal.sport)) (\(dateLabel))."
                 : "Logged sessions across \(dateLabel).")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heroStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.number(20))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hero stat whose number ticks up to its value on appear/change — the NOOP signature for a big
    /// count. Same layout as `heroStat`; used for the plain session count.
    private func heroCountStat(_ title: String, value: Double,
                               format: @escaping (Double) -> String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            CountUpText(value: value, format: format, font: StrandFont.number(20), color: tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary tiles (uniform 104pt StatTiles)

    private func summarySection(rows: [WorkoutRow], selectedRange: Range, groups: [SportGroup]) -> some View {
        let totalCount = rows.count
        let totalTimeH = rows.compactMap(\.durationS).reduce(0, +) / 3600.0
        let totalKcal = rows.compactMap(\.energyKcal).reduce(0, +)
        let totalKmRaw = rows.compactMap(\.distanceM).reduce(0, +) / 1000.0
        let modal = modalSport(from: groups)

        return LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Total Workouts",
                     value: "\(totalCount)",
                     caption: rangeDisplayLabel(for: selectedRange),
                     accent: StrandPalette.effortColor)
            StatTile(label: "Total Time",
                     value: String(localized: "\(oneDecimal(totalTimeH))h"),
                     caption: String(localized: "active"),
                     accent: StrandPalette.textPrimary)
            StatTile(label: "Total Calories",
                     value: grouped(totalKcal),
                     caption: "kcal",
                     accent: StrandPalette.metricAmber)
            StatTile(label: "Total Distance",
                     value: UnitFormatter.distanceFromKilometers(totalKmRaw, system: unitSystem),
                     caption: String(localized: "covered"),
                     accent: StrandPalette.metricCyan)
            StatTile(label: "Most Active",
                     value: modal.sport,
                     caption: modal.count > 0
                         ? (modal.count == 1 ? String(localized: "1 session") : String(localized: "\(modal.count) sessions"))
                         : nil,
                     accent: StrandPalette.textPrimary)
        }
    }

    // MARK: - Activity breakdown (per-sport NoopCards, identical layout)

    private func breakdownSection(groups: [SportGroup], rows: [WorkoutRow]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activity Breakdown",
                          overline: "By sport",
                          trailing: groups.count == 1
                              ? String(localized: "1 sport")
                              : String(localized: "\(groups.count) sports"))
            LazyVGrid(columns: breakdownColumns, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(groups) { g in
                    // This sport's own sessions, so the card can carry an HR-zone mini-bar.
                    sportCard(g, zones: WorkoutZones.summary(from: rows.filter { $0.sport == g.sport }))
                }
            }
        }
    }

    private func sportCard(_ g: SportGroup, zones: WorkoutZones.Summary?) -> some View {
        // Frosted Effort-tinted card with the sport glyph in the Effort world, an HR-zone mini-bar when
        // the sessions carry imported zones, and the bright "now" end-cap on its busiest zone.
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 12) {
                // Identical header for every card.
                HStack(spacing: 10) {
                    Image(systemName: sportIcon(g.sport))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 22, alignment: .center)
                    Text(WorkoutSource.displaySport(g.sport))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(g.count)")
                        .font(StrandFont.number(15))
                        .foregroundStyle(StrandPalette.effortBright)
                }
                if let zones { zoneMiniBar(zones) }
                Divider().overlay(StrandPalette.hairline)
                // Identical 4-up stat strip for every card.
                HStack(spacing: 0) {
                    miniStat(String(localized: "SESSIONS"), "\(g.count)")
                    miniStat(String(localized: "TIME"), String(localized: "\(oneDecimal(g.totalTimeH))h"))
                    miniStat(String(localized: "KCAL"), grouped(g.totalKcal), tint: StrandPalette.metricAmber)
                    miniStat(String(localized: "AVG/SESS"), String(localized: "\(Int(g.avgTimePerSessionMin.rounded()))m"))
                }
            }
        }
    }

    /// A slim proportional HR-zone bar for one sport's sessions — the zone colours, with the busiest
    /// zone carrying a crisp bright end-cap stroke so the card reads as a chart, not a flat strip. No glow.
    private func zoneMiniBar(_ z: WorkoutZones.Summary) -> some View {
        let busiest = z.minutes.indices.max(by: { z.minutes[$0] < z.minutes[$1] }) ?? 0
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(StrandPalette.hrZoneColor(i + 1))
                        .frame(width: max(0, CGFloat(z.minutes[i] / max(z.totalMinutes, 0.001)) * geo.size.width))
                        .overlay {
                            if i == busiest {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                            }
                        }
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z.minutes[$0 - 1] / max(z.totalMinutes, 0.001) * 100).rounded())) percent") }.joined(separator: ", "))"))
    }

    private func miniStat(_ label: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.number(15))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - HR zones (imported per-workout zone split, one card)

    private func zonesSection(_ z: WorkoutZones.Summary, totalSessions: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("HR Zones",
                          overline: "Imported zones",
                          trailing: totalSessions == 1
                              ? String(localized: "\(z.sessionsWithZones) of 1 session")
                              : String(localized: "\(z.sessionsWithZones) of \(totalSessions) sessions"))
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: 12) {
                    // Proportional stacked bar — same construction as SleepView's stage bar, with the
                    // busiest zone carrying a crisp bright end-cap stroke so it reads as a chart. No glow.
                    let busiest = z.minutes.indices.max(by: { z.minutes[$0] < z.minutes[$1] }) ?? 0
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                Rectangle()
                                    .fill(StrandPalette.hrZoneColor(i + 1))
                                    .frame(width: max(0, CGFloat(z.minutes[i] / z.totalMinutes) * geo.size.width))
                                    .overlay {
                                        if i == busiest {
                                            Rectangle()
                                                .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z.minutes[$0 - 1] / z.totalMinutes * 100).rounded())) percent") }.joined(separator: ", "))"))
                    Divider().overlay(StrandPalette.hairline)
                    // 5-up stat strip, identical rhythm to the sport cards' miniStat row.
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { i in
                            zoneStat(i + 1, minutes: z.minutes[i], total: z.totalMinutes)
                        }
                    }
                    Text("Share of imported zone time, duration-weighted across sessions (approximate).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationLabel(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - All sessions (one NoopCard, uniform fixed-height rows)

    /// Whether the compact-native session list is used. iPhone (.compact) gets full-width rows; macOS and
    /// iPad regular width keep the fixed-column table byte-identical (#64).
    private var usesCompactSessions: Bool {
        #if os(iOS)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    private func sessionsSection(rows: [WorkoutRow]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Sessions",
                              overline: "\(rangeDisplayLabel(for: range))",
                              trailing: rows.count == 1
                                ? String(localized: "1 session")
                                : String(localized: "\(rows.count) sessions"))
                selectPill(rows: rows)
            }
            if selectionMode { selectionToolbar(rows: rows) }
            NoopCard(padding: 0) {
                if usesCompactSessions {
                    // #64: full-width native rows, no horizontal scroll — the iPhone list reads like the
                    // rest of the app (Apple-Fitness x WHOOP), and the Android weight-column list. The
                    // ••• menu is visible per row + the tap-to-detail is natural, so the old hint caption
                    // (that taught the horizontal-scroll table) is gone here.
                    compactSessionsList(rows: rows)
                } else {
                    // macOS / iPad regular: the fixed-width columns total well over an iPhone's width, but
                    // these windows are wide enough to show it all, so they keep the full-width table.
                    sessionsTable(rows: rows)
                }
            }
            #if os(iOS)
            // iPad regular keeps the table's hint (byte-identical to before); the compact list drops it.
            if !usesCompactSessions {
                Text("Tap a workout for its detail · tap ••• to re-label, edit or delete it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 4)
            }
            #endif
        }
    }

    /// #64: the "Select" pill in the All-Sessions header trailing slot toggles multi-select mode. Only
    /// shown when at least one row is selectable (manual / detected); a pure-imported list has nothing to
    /// merge or bulk-delete.
    @ViewBuilder
    private func selectPill(rows: [WorkoutRow]) -> some View {
        let anySelectable = rows.contains(where: WorkoutMerge.isMergeable)
        if anySelectable {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectionMode.toggle()
                    if !selectionMode { selected.removeAll() }
                }
            } label: {
                Text(selectionMode ? String(localized: "Done") : String(localized: "Select"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(selectionMode ? StrandPalette.effortColor : StrandPalette.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        (selectionMode ? StrandPalette.effortColor.opacity(0.14)
                                       : StrandPalette.surfaceInset.opacity(0.6)),
                        in: Capsule())
            }
            .accessibilityLabel(selectionMode
                ? String(localized: "Finish selecting")
                : String(localized: "Select sessions to merge or delete"))
        }
    }

    /// #64: the Merge / Delete / Cancel strip shown above the card in selection mode. Merge needs 2+
    /// eligible rows; Delete needs 1+.
    private func selectionToolbar(rows: [WorkoutRow]) -> some View {
        let chosen = rows.filter { selected.contains(selectionKey($0)) }
        let canMerge = WorkoutMerge.canMerge(chosen)
        return HStack(spacing: 10) {
            Button {
                beginMerge(chosen)
            } label: {
                Label(String(localized: "Merge (\(chosen.count))"), systemImage: "arrow.triangle.merge")
                    .font(StrandFont.subhead)
            }
            .disabled(!canMerge)
            .foregroundStyle(canMerge ? StrandPalette.effortColor : StrandPalette.textTertiary)

            Button(role: .destructive) {
                let toDelete = chosen
                selectionMode = false; selected.removeAll()
                Task { await repo.bulkDeleteWorkouts(toDelete); await reload() }
            } label: {
                Label(String(localized: "Delete (\(chosen.count))"), systemImage: "trash")
                    .font(StrandFont.subhead)
            }
            .disabled(chosen.isEmpty)
            .foregroundStyle(chosen.isEmpty ? StrandPalette.textTertiary : StrandPalette.metricRose)

            Spacer(minLength: 0)
            Button(String(localized: "Cancel")) {
                withAnimation(.easeOut(duration: 0.15)) { selectionMode = false; selected.removeAll() }
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space3)
        .background(StrandPalette.effortColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// Start a merge: if the chosen rows carry a real sport, merge straight away; if every one is a bare
    /// detected bout, prompt the user to name the merged session first.
    private func beginMerge(_ chosen: [WorkoutRow]) {
        guard WorkoutMerge.canMerge(chosen) else { return }
        if WorkoutMerge.resolvedSport(chosen) == nil {
            mergeSportPrompt = MergeSportTarget(rows: chosen)
        } else {
            performMerge(chosen, sport: nil)
        }
    }

    /// Commit a merge through the repository (manual-row path), then rescore + reload. Leaves selection
    /// mode. Imported rows can never reach here (canMerge gates on manual/detected).
    private func performMerge(_ chosen: [WorkoutRow], sport: String?) {
        guard let merged = WorkoutMerge.merge(chosen, sport: sport) else { return }
        selectionMode = false; selected.removeAll(); mergeSportPrompt = nil
        Task {
            await repo.mergeWorkouts(chosen, into: merged)
            await model.intelligence.analyzeRecent()
            await reload()
        }
    }

    /// #64: the compact-native list — full-width NoopCard rows, alternating zebra, tap-to-detail, the
    /// existing ••• menu, and (in selection mode) a leading checkmark / lock glyph.
    @ViewBuilder
    private func compactSessionsList(rows: [WorkoutRow]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                compactSessionRow(row)
                    .background(idx % 2 == 1
                                ? StrandPalette.surfaceInset.opacity(0.4)
                                : Color.clear)
                if idx != rows.count - 1 {
                    Divider().overlay(StrandPalette.hairline.opacity(0.5))
                }
            }
        }
    }

    @ViewBuilder
    private func sessionsTable(rows: [WorkoutRow]) -> some View {
        LazyVStack(spacing: 0) {
            sessionHeaderRow
            Divider().overlay(StrandPalette.hairline)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                sessionRow(row)
                    .background(idx % 2 == 1
                                ? StrandPalette.surfaceInset.opacity(0.4)
                                : Color.clear)
                if idx != rows.count - 1 {
                    Divider().overlay(StrandPalette.hairline.opacity(0.5))
                }
            }
        }
    }

    private var sessionHeaderRow: some View {
        HStack(spacing: 0) {
            colHeader(String(localized: "DATE"), width: ColWidth.date, align: .leading)
            colHeader(String(localized: "SPORT"), width: ColWidth.sport, align: .leading)
            colHeader(String(localized: "DUR"), width: ColWidth.duration, align: .trailing)
            colHeader(String(localized: "AVG HR"), width: ColWidth.hr, align: .trailing)
            colHeader(String(localized: "KCAL"), width: ColWidth.kcal, align: .trailing)
            colHeader(String(localized: "DIST"), width: ColWidth.dist, align: .trailing)
            // #796 - per-session Effort (the stored 0-100 strain this workout contributed to the day),
            // shown on the user's selected Effort scale. Same value the Effort ring and the detail's
            // Effort card read, surfaced per row so each session's effort is visible without opening it.
            colHeader(String(localized: "EFFORT"), width: ColWidth.effort, align: .trailing)
            Spacer(minLength: 0)
            colHeader(String(localized: "SOURCE"), width: ColWidth.source, align: .trailing)
            // Empty header over the per-row "•••" actions menu column (keeps SOURCE aligned).
            Color.clear.frame(width: ColWidth.action)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(height: RowMetrics.headerHeight)
    }

    private func colHeader(_ t: String, width: CGFloat, align: Alignment) -> some View {
        Text(t).strandOverline().frame(width: width, alignment: align)
    }

    private func sessionRow(_ row: WorkoutRow) -> some View {
        let selectable = WorkoutMerge.isMergeable(row)
        let isSelected = selected.contains(selectionKey(row))
        // Same liquid press treatment as the compact row: the PRIMARY tap runs through a Button so the row
        // settles inward on press, and the inline ••• Menu still captures its own taps. The fixed-width
        // columns + uniform row height are unchanged (they live inside the Button's label).
        return Button {
            if selectionMode {
                guard selectable else { return }
                withAnimation(.easeOut(duration: 0.12)) { toggleSelection(row) }
            } else {
                openDetail(row)
            }
        } label: {
          HStack(spacing: 0) {
            // #64: leading selection glyph — only rendered in selection mode, so the default table row is
            // byte-identical. A lock replaces the checkmark on imported (read-only) rows.
            if selectionMode {
                compactSelectionGlyph(selectable: selectable, isSelected: isSelected)
                    .frame(width: 28)
                    .padding(.trailing, 4)
            }
            // Date + time
            VStack(alignment: .leading, spacing: 1) {
                Text(dateLabel(row.startTs))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(timeRangeLabel(row.startTs, row.endTs))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: ColWidth.date, alignment: .leading)

            // Sport ("detected" reads as "Activity")
            HStack(spacing: 7) {
                Image(systemName: sportIcon(row.sport))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 16)
                Text(WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: ColWidth.sport, alignment: .leading)

            cell(durationLabel(row.durationS), width: ColWidth.duration)
            cell(row.avgHr.map { "\($0)" } ?? "–", width: ColWidth.hr,
                 color: row.avgHr != nil ? StrandPalette.metricRose : nil)
            cell(row.energyKcal.map { grouped($0) } ?? "–", width: ColWidth.kcal,
                 color: row.energyKcal != nil ? StrandPalette.metricAmber : nil)
            cell(distanceLabel(row.distanceM), width: ColWidth.dist)
            // #796 - per-session Effort, on the user's scale, tinted the Effort colour when present.
            cell(Self.effortCellLabel(strain: row.strain, scale: effortScale), width: ColWidth.effort,
                 color: row.strain != nil ? StrandPalette.effortColor : nil)

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                sourceBadge(row.source)
            }
            .frame(width: ColWidth.source, alignment: .trailing)

            // The ••• column keeps its reserved width for alignment inside the button label, but the actual
            // interactive Menu is layered as a trailing overlay OUTSIDE the button (below) so it captures
            // its own taps rather than being swallowed by the row button (the DevicesView #318 idiom).
            Color.clear.frame(width: ColWidth.action)
          }
          .padding(.horizontal, NoopMetrics.cardPadding)
          .frame(height: RowMetrics.rowHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        // Visible per-row actions affordance (#1/#318): the ••• menu sits on top of the row at the trailing
        // edge (over its reserved column) so relabel/edit/dismiss stay discoverable and tappable. Hidden in
        // selection mode (the toolbar owns the actions there).
        .overlay(alignment: .trailing) {
            if !selectionMode {
                rowActionsMenu(row)
                    .frame(width: ColWidth.action, alignment: .trailing)
                    .padding(.trailing, NoopMetrics.cardPadding)
            }
        }
        .contextMenu { if !selectionMode { rowMenu(row) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens workout detail")
    }

    // MARK: - Compact session row (#64, iPhone .compact)

    /// A full-width native session row for iPhone. Line 1: sport glyph + name + per-session Effort. Line 2:
    /// a "d MMM · HH:mm–HH:mm · 45m · 388 kcal · 118 bpm" summary, nil fields omitted. Trailing: the source
    /// badge + the existing ••• actions menu. In selection mode a leading checkmark (mergeable rows) or a
    /// lock glyph (imported, read-only) replaces the tap-to-detail gesture.
    private func compactSessionRow(_ row: WorkoutRow) -> some View {
        let selectable = WorkoutMerge.isMergeable(row)
        let isSelected = selected.contains(selectionKey(row))
        // The row's PRIMARY tap runs through a Button so it earns the liquid settle-inward press
        // (LiquidPressStyle) like every other tappable liquid surface. The trailing ••• Menu is layered as
        // a trailing overlay OUTSIDE the button (below) so it captures its own taps rather than being
        // swallowed by the row button (#318). Selection-mode taps toggle instead of opening the detail.
        return Button {
            if selectionMode {
                guard selectable else { return }
                withAnimation(.easeOut(duration: 0.12)) { toggleSelection(row) }
            } else {
                openDetail(row)
            }
        } label: {
            HStack(spacing: 12) {
                if selectionMode {
                    compactSelectionGlyph(selectable: selectable, isSelected: isSelected)
                }
                Image(systemName: sportIcon(row.sport))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(WorkoutSource.displaySport(row.sport))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Self.effortCellLabel(strain: row.strain, scale: effortScale))
                            .font(StrandFont.number(15))
                            .foregroundStyle(row.strain != nil ? StrandPalette.effortColor : StrandPalette.textTertiary)
                    }
                    Text(compactRowSubtitle(row))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                sourceBadge(row.source)
                // Reserve the ••• column width inside the label; the interactive Menu is overlaid on top
                // (below) so it captures its own taps instead of being swallowed by the row button (#318).
                if !selectionMode {
                    Color.clear.frame(width: ColWidth.action)
                }
            }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        // Visible per-row ••• actions (#1/#318), layered at the trailing edge over its reserved column.
        .overlay(alignment: .trailing) {
            if !selectionMode {
                rowActionsMenu(row)
                    .frame(width: ColWidth.action, alignment: .trailing)
                    .padding(.trailing, NoopMetrics.cardPadding)
            }
        }
        .contextMenu { if !selectionMode { rowMenu(row) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactRowAccessibilityLabel(row, selectable: selectable, isSelected: isSelected))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selectionMode
            ? (selectable ? String(localized: "Double-tap to select") : String(localized: "Imported history can't be merged"))
            : String(localized: "Opens workout detail"))
    }

    /// The leading selection glyph: a filled/hollow checkmark for a mergeable row, or a lock for imported
    /// history (which can never be merged or bulk-deleted).
    @ViewBuilder
    private func compactSelectionGlyph(selectable: Bool, isSelected: Bool) -> some View {
        if selectable {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected ? StrandPalette.effortColor : StrandPalette.textTertiary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                .frame(width: 20)
                .accessibilityHidden(true)
        }
    }

    /// Toggle one row's selection (mergeable rows only).
    private func toggleSelection(_ row: WorkoutRow) {
        let key = selectionKey(row)
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    /// The compact row's second line: "d MMM · HH:mm–HH:mm · 45m · 388 kcal · 118 bpm", nil fields omitted.
    private func compactRowSubtitle(_ row: WorkoutRow) -> String {
        var parts: [String] = [dateLabel(row.startTs), timeRangeLabel(row.startTs, row.endTs)]
        if let d = durationLabelOrNil(row.durationS) { parts.append(d) }
        if let k = row.energyKcal, k > 0 { parts.append(String(localized: "\(grouped(k)) kcal")) }
        if let d = row.distanceM, d > 0 { parts.append(distanceLabel(row.distanceM)) }
        if let hr = row.avgHr { parts.append(String(localized: "\(hr) bpm")) }
        return parts.joined(separator: " · ")
    }

    /// A full-sentence a11y label for a compact row.
    private func compactRowAccessibilityLabel(_ row: WorkoutRow, selectable: Bool, isSelected: Bool) -> String {
        let effort = row.strain != nil
            ? String(localized: "Effort \(Self.effortCellLabel(strain: row.strain, scale: effortScale))")
            : String(localized: "no Effort recorded")
        let base = String(localized: "\(WorkoutSource.displaySport(row.sport)), \(compactRowSubtitle(row)), \(effort)")
        guard selectionMode else { return base }
        if !selectable { return String(localized: "\(base). Imported, can't be merged.") }
        return isSelected ? String(localized: "\(base). Selected.") : String(localized: "\(base). Not selected.")
    }

    /// The same actions as `rowMenu`, surfaced as a tappable "•••" button so they're discoverable on
    /// both macOS (no right-click needed) and iOS (no long-press needed). Borderless + hidden
    /// indicator keeps it to a bare glyph that fits the row's metric rhythm.
    private func rowActionsMenu(_ row: WorkoutRow) -> some View {
        Menu {
            rowMenu(row)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: ColWidth.action, height: RowMetrics.rowHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Right-click actions per row. A DETECTED bout can be re-labelled (becomes a real manual session
    /// that survives re-detection) or dismissed (durably hidden). A MANUAL session can be edited or
    /// deleted. Imported WHOOP / Apple rows are read-only (we never rewrite imported history).
    @ViewBuilder
    private func rowMenu(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(sport) { relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Divider()
            Button("Delete", role: .destructive) { delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            // Imported history is read-only; offer a copy-to-manual edit path that doesn't touch it.
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row)) }
        }
    }

    /// A manual-source copy of an imported row, so "Duplicate as manual" opens the add sheet pre-filled
    /// without ever mutating the imported original (the sheet saves under the strap source).
    private func asManualCopy(_ row: WorkoutRow) -> WorkoutRow {
        WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: WorkoutSource.displaySport(row.sport),
                   source: "manual", durationS: row.durationS, energyKcal: row.energyKcal,
                   avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain, distanceM: row.distanceM,
                   zonesJSON: row.zonesJSON, notes: row.notes)
    }

    /// #796 - the per-session Effort cell label: the stored 0-100 strain mapped to the user's Effort scale
    /// (the SAME `UnitFormatter.effortDisplay` every other Effort read-out routes through, so the toggle and
    /// rounding stay consistent), or "–" when the session has no captured strain. Pure + unit-testable.
    static func effortCellLabel(strain: Double?, scale: EffortScale) -> String {
        guard let strain else { return "–" }
        return UnitFormatter.effortDisplay(strain, scale: scale)
    }

    private func cell(_ text: String, width: CGFloat, color: Color? = nil) -> some View {
        Text(text)
            .font(StrandFont.number(13, weight: .regular))
            .foregroundStyle(color ?? (text == "–" ? StrandPalette.textTertiary : StrandPalette.textPrimary))
            .frame(width: width, alignment: .trailing)
    }

    /// Source badge built from the locked SourceBadge component (no custom capsule). Four origins:
    /// Whoop (import), Apple (import), Detected (on-device auto-detector — honestly labelled so a
    /// duplicate is recognisable and removable), Manual (user-logged).
    private func sourceBadge(_ source: String) -> some View {
        let (label, tint, a11y): (String, Color, String) = {
            switch WorkoutSource.classify(source) {
            case .whoop:    return (String(localized: "Imported"), StrandPalette.accent, String(localized: "Source imported wearable"))
            case .apple:    return (String(localized: "Apple"), StrandPalette.metricCyan, String(localized: "Source Apple Health"))
            case .detected: return (String(localized: "Detected"), StrandPalette.metricPurple, String(localized: "Source on-device detected"))
            case .manual:   return (String(localized: "Manual"), StrandPalette.statusWarning, String(localized: "Source manual entry"))
            case .lifting:  return (String(localized: "Lifting"), StrandPalette.zone2, String(localized: "Source imported lifting log"))
            case .activityFile: return (String(localized: "File"), StrandPalette.metricAmber, String(localized: "Source imported activity file"))
            }
        }()
        // String interpolation lifts the computed label into a LocalizedStringKey (SourceBadge's type).
        return SourceBadge("\(label)", tint: tint).accessibilityLabel(a11y)
    }

    // MARK: - Grid columns

    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]
    }
    private var breakdownColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: NoopMetrics.gap, alignment: .top)]
    }

    // MARK: - Aggregation

    private struct SportGroup: Identifiable {
        let sport: String
        let count: Int
        let totalTimeS: Double
        let totalKcal: Double
        var id: String { sport }
        var totalTimeH: Double { totalTimeS / 3600.0 }
        var avgTimePerSessionMin: Double { count > 0 ? (totalTimeS / Double(count)) / 60.0 : 0 }
    }

    /// Sessions grouped by sport, ordered by count (desc), then total time.
    /// Takes the already-windowed rows so `body` builds the groups exactly once.
    private func sportGroups(from rows: [WorkoutRow]) -> [SportGroup] {
        var bySport: [String: (count: Int, time: Double, kcal: Double)] = [:]
        for r in rows {
            var acc = bySport[r.sport] ?? (0, 0, 0)
            acc.count += 1
            acc.time += r.durationS ?? 0
            acc.kcal += r.energyKcal ?? 0
            bySport[r.sport] = acc
        }
        return bySport
            .map { SportGroup(sport: $0.key, count: $0.value.count,
                              totalTimeS: $0.value.time, totalKcal: $0.value.kcal) }
            .sorted { ($0.count, $0.totalTimeS) > ($1.count, $1.totalTimeS) }
    }

    /// The most-frequent sport (modal), derived from the already-built groups.
    private func modalSport(from groups: [SportGroup]) -> (sport: String, count: Int) {
        guard let top = groups.first else { return ("–", 0) }
        return (top.sport, top.count)
    }

    // MARK: - Range model

    private enum Range: CaseIterable, Hashable {
        case week, month, quarter, year, all, custom
        var label: String {
            switch self {
            case .week:    return String(localized: "7D")
            case .month:   return String(localized: "30D")
            case .quarter: return String(localized: "90D")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "All")
            case .custom:  return String(localized: "Custom")
            }
        }
        var caption: String {
            switch self {
            case .week:    return String(localized: "last 7 days")
            case .month:   return String(localized: "last 30 days")
            case .quarter: return String(localized: "last 90 days")
            case .year:    return String(localized: "last year")
            case .all:     return String(localized: "all time")
            case .custom:  return String(localized: "custom dates")
            }
        }
        /// Trailing-window length in days, or nil for "all".
        var days: Int? {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            case .year:    return 365
            case .all, .custom: return nil
            }
        }
    }

    // MARK: - Formatting

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "4:34 PM" where 12-hour is
    // preferred, "16:34" where 24-hour is - instead of forcing 24-hour on everyone (matches TodayView).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "HH:mm–HH:mm" when the row carries a real end, start-only otherwise (#157).
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))-\(timeLabel(end))" : timeLabel(start)
    }

    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }

    /// #64: the duration label, or nil when there's no duration to show — so the compact row's summary
    /// line can omit the field entirely rather than printing a bare "–".
    private func durationLabelOrNil(_ s: Double?) -> String? {
        guard let s, s > 0 else { return nil }
        return durationLabel(s)
    }

    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: unitSystem)
    }

    private func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    // MARK: - Sport icons

    // Sport → SF Symbol now lives in StrandDesign (`sportSymbol`) so the Today HR
    // overview annotates workouts with the same icons. Thin forwarder keeps call sites.
    private func sportIcon(_ sport: String) -> String { sportSymbol(sport) }

    // MARK: - Row + column metrics (uniform)

    private enum RowMetrics {
        static let headerHeight: CGFloat = 34
        static let rowHeight: CGFloat = 46   // every session row is exactly this tall
    }

    private enum ColWidth {
        static let date: CGFloat = 96
        static let sport: CGFloat = 160
        static let duration: CGFloat = 70
        static let hr: CGFloat = 64
        static let kcal: CGFloat = 70
        static let dist: CGFloat = 72
        static let effort: CGFloat = 64   // #796 per-session Effort column
        static let source: CGFloat = 80
        static let action: CGFloat = 36   // trailing "•••" per-row actions menu
    }
}

/// Three raw-bpm HRR lines on one shared axis (#516). Unlike Compare's normalized overlay, these values
/// share a unit and scale, so their vertical distance remains meaningful. Point marks keep a single eligible
/// workout visible even when there is not yet enough history to draw a line.
private struct WorkoutRecoveryTrendChart: View {
    let points: [WorkoutRecoveryTrendPoint]

    private struct Plot: Identifiable {
        let startTs: Int
        let interval: String
        let value: Int
        var id: String { "\(interval)@\(startTs)" }
        var date: Date { Date(timeIntervalSince1970: TimeInterval(startTs)) }
    }

    private var plots: [Plot] {
        points.flatMap { point in
            var out: [Plot] = []
            if let value = point.result.after1Minute {
                out.append(Plot(startTs: point.startTs, interval: String(localized: "1 min"), value: value))
            }
            if let value = point.result.after2Minutes {
                out.append(Plot(startTs: point.startTs, interval: String(localized: "2 min"), value: value))
            }
            if let value = point.result.after5Minutes {
                out.append(Plot(startTs: point.startTs, interval: String(localized: "5 min"), value: value))
            }
            return out
        }
    }

    var body: some View {
        let one = String(localized: "1 min")
        let two = String(localized: "2 min")
        let five = String(localized: "5 min")
        Chart(plots) { point in
            LineMark(
                x: .value("Workout", point.date),
                y: .value("Recovery", point.value)
            )
            .foregroundStyle(by: .value("Recovery interval", point.interval))
            .interpolationMethod(.catmullRom)
            PointMark(
                x: .value("Workout", point.date),
                y: .value("Recovery", point.value)
            )
            .foregroundStyle(by: .value("Recovery interval", point.interval))
            .symbolSize(28)
        }
        .chartForegroundStyleScale(
            domain: [one, two, five],
            range: [StrandPalette.metricRose, StrandPalette.metricCyan, StrandPalette.metricPurple]
        )
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let bpm = value.as(Int.self) { Text("\(bpm)") }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityLabel("Heart-rate recovery trend in beats per minute")
    }
}

struct DailyOverviewSheet: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureUnitRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    let date: Date
    let scope: DailyOverviewScope

    @State private var daily: DailyMetric?
    @State private var workouts: [WorkoutRow] = []
    @State private var trackedMetrics: [DayTrackedMetric] = []
    @State private var hydration: HydrationReading?
    @State private var journal: [JournalEntry] = []
    @State private var loading = true

    private var unitSystem: UnitSystem {
        UnitSystem(rawValue: unitSystemRaw) ?? .metric
    }

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureUnitRaw)
    }

    private var effortScale: EffortScale {
        UnitPrefs.resolveEffortScale(effortScaleRaw)
    }

    private var noData: String {
        String(localized: "appwide.day_overview.no_data")
    }

    private struct MetricItem {
        let label: LocalizedStringKey
        let value: String
        let tint: Color?
    }

    var body: some View {
        ScrollView {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text(date.formatted(date: .complete, time: .omitted))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)

                    scoreTiles
                    if scope.includesWholeDayMetrics {
                        metricSection(
                            title: "appwide.day_overview.sleep",
                            items: sleepItems
                        )
                        metricSection(
                            title: "appwide.day_overview.vitals",
                            items: vitalItems
                        )
                    }
                    metricSection(
                        title: "appwide.day_overview.activity",
                        items: activityItems
                    )
                    if scope.includesWholeDayMetrics, !supplementalItems.isEmpty {
                        metricSection(
                            title: "appwide.day_overview.more_metrics",
                            items: supplementalItems
                        )
                    }
                    if scope.includesWholeDayMetrics, !journal.isEmpty {
                        journalSection
                    }
                    sessionsSection
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.bottom, NoopMetrics.sectionGap)
            }
        }
        .navigationTitle(Text("appwide.day_overview.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("appwide.action.done") { dismiss() }
            }
        }
        .task(id: [
            scope.rawValue,
            Repository.localDayKey(date),
            String(repo.refreshSeq),
            String(repo.ageMetricsSeq),
            String(repo.workoutsSeq),
            String(repo.hydrationSeq),
        ].joined(separator: "|")) {
            await load()
        }
    }

    private var scoreTiles: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if scope.includesWholeDayMetrics {
                SectionHeader(
                    "appwide.day_overview.daily_scores",
                    overline: "appwide.day_overview.overall"
                )
            } else {
                SectionHeader(
                    "appwide.day_overview.effort",
                    overline: "appwide.day_overview.activity"
                )
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: NoopMetrics.gap)],
                spacing: NoopMetrics.gap
            ) {
                if scope.includesWholeDayMetrics {
                    StatTile(
                        label: "appwide.day_overview.recovery",
                        value: score(daily?.recovery),
                        accent: StrandPalette.chargeColor
                    )
                    StatTile(
                        label: "appwide.day_overview.sleep_score",
                        value: score(DailyOverviewPresentation.sleepScore(daily)),
                        accent: StrandPalette.restColor
                    )
                }
                StatTile(
                    label: "appwide.day_overview.effort",
                    value: daily?.strain.map {
                        UnitFormatter.effortDisplay($0, scale: effortScale)
                    } ?? noData,
                    accent: StrandPalette.effortColor
                )
            }
        }
    }

    private var sleepItems: [MetricItem] {
        [
            MetricItem(
                label: "appwide.day_overview.total_sleep",
                value: durationMinutes(daily?.totalSleepMin),
                tint: StrandPalette.restColor
            ),
            MetricItem(
                label: "appwide.day_overview.sleep_efficiency",
                value: percent(DailyOverviewPresentation.efficiencyPercent(daily?.efficiency)),
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.deep_sleep",
                value: durationMinutes(daily?.deepMin),
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.rem_sleep",
                value: durationMinutes(daily?.remMin),
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.light_sleep",
                value: durationMinutes(daily?.lightMin),
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.disturbances",
                value: daily?.disturbances.map(String.init) ?? noData,
                tint: nil
            ),
        ]
    }

    private var vitalItems: [MetricItem] {
        [
            MetricItem(
                label: "appwide.day_overview.resting_heart_rate",
                value: daily?.restingHr.map { "\($0) bpm" } ?? noData,
                tint: StrandPalette.metricRose
            ),
            MetricItem(
                label: "appwide.day_overview.hrv",
                value: daily?.avgHrv.map { "\(decimal($0)) ms" } ?? noData,
                tint: StrandPalette.metricPurple
            ),
            MetricItem(
                label: "appwide.day_overview.blood_oxygen",
                value: daily?.spo2Pct.map { "\(decimal($0))%" } ?? noData,
                tint: StrandPalette.metricCyan
            ),
            MetricItem(
                label: "appwide.day_overview.respiratory_rate",
                value: daily?.respRateBpm.map { "\(decimal($0)) br/min" } ?? noData,
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.skin_temperature",
                value: daily?.skinTempDevC.map {
                    UnitFormatter.temperatureDeltaFromCelsius(
                        $0,
                        unit: temperatureUnit,
                        decimals: 1
                    )
                } ?? noData,
                tint: StrandPalette.metricAmber
            ),
        ]
    }

    private var activityItems: [MetricItem] {
        let duration = workouts.reduce(0.0) {
            $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs)))
        }
        let calories = workouts.compactMap(\.energyKcal)
        let distances = workouts.compactMap(\.distanceM).filter { $0 > 0 }
        return [
            MetricItem(
                label: "appwide.day_overview.steps",
                value: daily?.steps.map { grouped(Double($0)) } ?? noData,
                tint: StrandPalette.statusPositive
            ),
            MetricItem(
                label: "appwide.day_overview.estimated_total_energy",
                value: daily?.activeKcalEst.map { "\(grouped($0)) kcal" } ?? noData,
                tint: StrandPalette.metricAmber
            ),
            MetricItem(
                label: "appwide.day_overview.workout_count",
                value: "\(workouts.count)",
                tint: StrandPalette.effortColor
            ),
            MetricItem(
                label: "appwide.day_overview.active_time",
                value: durationSeconds(duration),
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.workout_calories",
                value: calories.isEmpty ? noData : "\(grouped(calories.reduce(0, +))) kcal",
                tint: nil
            ),
            MetricItem(
                label: "appwide.day_overview.distance",
                value: distances.isEmpty
                    ? noData
                    : UnitFormatter.distanceFromMeters(distances.reduce(0, +), system: unitSystem),
                tint: nil
            ),
        ]
    }

    private var supplementalItems: [MetricItem] {
        var seen = Set<String>()
        var items = trackedMetrics.compactMap { metric -> MetricItem? in
            guard !Self.coreMetricKeys.contains(metric.descriptor.key) else { return nil }
            let identity = metric.descriptor.title.lowercased()
                + "\u{1F}" + metric.descriptor.unit.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return MetricItem(
                label: LocalizedStringKey(metric.descriptor.title),
                value: metric.descriptor.format(
                    metric.value,
                    system: unitSystem,
                    temperature: temperatureUnit,
                    effortScale: effortScale
                ),
                tint: metricTint(metric.descriptor.category)
            )
        }
        if let hydration {
            items.append(MetricItem(
                label: "appwide.day_overview.hydration",
                value: "\(grouped(hydration.valueML)) ml",
                tint: StrandPalette.metricCyan
            ))
        }
        return items
    }

    private func metricSection(
        title: LocalizedStringKey,
        items: [MetricItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(title)
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        metricRow(item)
                        if index < items.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func metricRow(_ item: MetricItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(item.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(item.value)
                .font(StrandFont.number(15))
                .foregroundStyle(item.tint ?? (
                    item.value == noData ? StrandPalette.textTertiary : StrandPalette.textPrimary
                ))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(
                "appwide.day_overview.sessions",
                trailing: "\(workouts.count)"
            )
            if workouts.isEmpty {
                NoopCard {
                    Text("appwide.day_overview.no_sessions")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NoopCard {
                    VStack(spacing: 0) {
                        ForEach(Array(workouts.enumerated()), id: \.offset) { index, row in
                            workoutRow(row)
                            if index < workouts.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(
                "appwide.day_overview.journal",
                trailing: "\(journal.count)"
            )
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(journal.enumerated()), id: \.element.question) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.question)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let notes = entry.notes?.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ), !notes.isEmpty {
                                    Text(notes)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(journalValue(entry))
                                .font(StrandFont.number(15))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        if index < journal.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func workoutRow(_ row: WorkoutRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: workoutIcon(row.sport))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(timeRange(row.startTs, row.endTs))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(durationSeconds(
                    row.durationS ?? Double(max(0, row.endTs - row.startTs))
                ))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let kcal = row.energyKcal {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "appwide.day_overview.calories_format"),
                            grouped(kcal)
                        )
                    )
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.metricAmber)
                }
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true
        let key = Repository.localDayKey(date)
        let window = WorkoutDateWindow.localDay(containing: date)
        if !scope.includesWholeDayMetrics {
            async let dailyRows = repo.dailyMetrics(fromDay: key, toDay: key)
            async let exactWorkouts = repo.workoutRows(
                overlappingFrom: window.lowerBound,
                to: window.upperBound
            )
            let (resolvedDaily, resolvedWorkouts) = await (dailyRows, exactWorkouts)
            daily = resolvedDaily.last(where: { $0.day == key })
            workouts = resolvedWorkouts.filter {
                Repository.localDayKey(
                    Date(timeIntervalSince1970: TimeInterval($0.startTs))
                ) == key
            }
            trackedMetrics = []
            hydration = nil
            journal = []
            loading = false
            return
        }

        async let dailyRows = repo.dailyMetrics(fromDay: key, toDay: key)
        async let exactWorkouts = repo.workoutRows(
            overlappingFrom: window.lowerBound,
            to: window.upperBound
        )
        async let exactMetrics = repo.trackedMetrics(day: key)
        async let exactHydration = repo.hydrationReading(day: key)
        async let exactJournal = repo.journalEntries(day: key)
        let (
            resolvedDaily,
            resolvedWorkouts,
            resolvedMetrics,
            resolvedHydration,
            resolvedJournal
        ) = await (
            dailyRows,
            exactWorkouts,
            exactMetrics,
            exactHydration,
            exactJournal
        )
        daily = resolvedDaily.last(where: { $0.day == key })
        workouts = resolvedWorkouts.filter {
            Repository.localDayKey(
                Date(timeIntervalSince1970: TimeInterval($0.startTs))
            ) == key
        }
        trackedMetrics = resolvedMetrics
        hydration = resolvedHydration
        journal = resolvedJournal
        loading = false
    }

    private func journalValue(_ entry: JournalEntry) -> String {
        if let value = entry.numericValue, value.isFinite {
            return String(
                format: value.rounded() == value ? "%.0f" : "%.1f",
                locale: Locale.current,
                value
            )
        }
        return entry.answeredYes
            ? String(localized: "appwide.day_overview.yes")
            : String(localized: "appwide.day_overview.no")
    }

    private func metricTint(_ category: String) -> Color? {
        switch category {
        case "Heart": return StrandPalette.metricRose
        case "Charge": return StrandPalette.chargeColor
        case "Rest": return StrandPalette.restColor
        case "Effort": return StrandPalette.effortColor
        case "Nutrition": return StrandPalette.metricAmber
        case "Mind": return StrandPalette.metricPurple
        default: return nil
        }
    }

    private func score(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? noData
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? noData
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale.current, value)
    }

    private func grouped(_ value: Double) -> String {
        Self.integerFormatter.string(from: NSNumber(value: Int(value.rounded())))
            ?? "\(Int(value.rounded()))"
    }

    private func durationMinutes(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes >= 0 else { return noData }
        return durationSeconds(minutes * 60)
    }

    private func durationSeconds(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String.localizedStringWithFormat(
                String(localized: "appwide.day_overview.duration_hours_minutes_format"),
                hours,
                minutes
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "appwide.day_overview.duration_minutes_format"),
            minutes
        )
    }

    private func timeRange(_ start: Int, _ end: Int) -> String {
        let startText = Self.timeFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(start))
        )
        guard end > start else { return startText }
        let endText = Self.timeFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(end))
        )
        return "\(startText) - \(endText)"
    }

    private func workoutIcon(_ sport: String) -> String {
        let value = sport.lowercased()
        if value.contains("run") { return "figure.run" }
        if value.contains("walk") || value.contains("hike") { return "figure.walk" }
        if value.contains("cycl") || value.contains("bike") { return "bicycle" }
        if value.contains("swim") { return "figure.pool.swim" }
        if value.contains("yoga") || value.contains("pilates") { return "figure.yoga" }
        if value.contains("strength") || value.contains("weight") || value.contains("lift") {
            return "dumbbell.fill"
        }
        return "figure.mixed.cardio"
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let coreMetricKeys: Set<String> = [
        "recovery",
        "sleep_performance",
        "sleep_score",
        "strain",
        "sleep_total_min",
        "asleep_min",
        "sleep_efficiency",
        "sleep_deep_min",
        "deep_min",
        "sleep_rem_min",
        "rem_min",
        "sleep_light_min",
        "core_min",
        "hrv",
        "rhr",
        "resting_hr",
        "spo2",
        "resp_rate",
        "skin_temp",
        "steps",
        "steps_est",
        "active_kcal",
        "energy_kcal",
        // Render the source-aware NOOP/Apple Health maximum exactly once below.
        "hydration",
    ]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
}

#if DEBUG
@MainActor
private func previewWorkoutRows() -> [WorkoutRow] {
    let now = Int(Date().timeIntervalSince1970)
    let day = 86_400
    return [
        WorkoutRow(startTs: now - day * 0 - 3600, endTs: now - day * 0,
                   sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
                   avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
                   zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil),
        WorkoutRow(startTs: now - day * 1 - 2700, endTs: now - day * 1,
                   sport: "Strength Training", source: "whoop", durationS: 2700, energyKcal: 388,
                   avgHr: 118, maxHr: 156, strain: 9.4, distanceM: nil,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 2 - 1800, endTs: now - day * 2,
                   sport: "Cycling", source: "apple_health", durationS: 1800, energyKcal: 240,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 12_800,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 3 - 1500, endTs: now - day * 3,
                   sport: "Running", source: "apple_health", durationS: 1500, energyKcal: 310,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 5_100,
                   zonesJSON: nil, notes: nil),
        WorkoutRow(startTs: now - day * 4 - 3300, endTs: now - day * 4,
                   sport: "Cycling", source: "whoop", durationS: 3300, energyKcal: 540,
                   avgHr: 134, maxHr: 162, strain: 11.8, distanceM: 24_600,
                   // Android key shape on purpose — exercises the cross-platform parser.
                   zonesJSON: #"{"zone1":20.0,"zone2":35.0,"zone3":30.0,"zone4":10.0}"#, notes: nil),
        WorkoutRow(startTs: now - day * 6 - 2400, endTs: now - day * 6,
                   sport: "Yoga", source: "whoop", durationS: 2400, energyKcal: 165,
                   avgHr: 92, maxHr: 118, strain: 5.1, distanceM: nil,
                   zonesJSON: nil, notes: nil),
    ]
}

#Preview("Workouts") {
    WorkoutsView(previewRows: previewWorkoutRows())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 940)
        .preferredColorScheme(.dark)
}

#Preview("Workouts - empty") {
    WorkoutsView(previewRows: [])
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 1040, height: 600)
        .preferredColorScheme(.dark)
}
#endif
