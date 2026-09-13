import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view, rebuilt on the locked Noop component system so every
// surface, height and gap is identical: one SegmentedPillControl for the range,
// a hero recovery ChartCard, a uniform grid of HRV / Resting HR / Day Strain
// ChartCards (all NoopMetrics.chartHeight tall), and the whole history as a
// recovery YearHeatStrip in a NoopCard. No hand-sized cards anywhere.

struct TrendsView: View {
    enum LoadFailure: Equatable, Sendable {
        case trends
        case weeklyDigest
    }

    enum LoadPolicy {
        static let productionTimeoutNanoseconds: UInt64 = 12_000_000_000
        static let demoTimeoutNanoseconds: UInt64 = 75_000_000

        static func timeoutNanoseconds(
            arguments: [String] = CommandLine.arguments,
            retryGeneration: Int = 0
        ) -> UInt64 {
            arguments.contains("--demo-trends-timeout") && retryGeneration == 0
                ? demoTimeoutNanoseconds
                : productionTimeoutNanoseconds
        }
    }

    private enum LoadRaceResult<Value: Sendable>: Sendable {
        case value(Value?)
        case timedOut
        case canceled
    }

    @EnvironmentObject var repo: Repository
    @Environment(\.pushTabRoute) private var pushTabRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
    enum Range: Int, CaseIterable, Identifiable, Sendable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:    return String(localized: "W")
            case .month:   return String(localized: "M")
            case .quarter: return String(localized: "3M")
            case .half:    return String(localized: "6M")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "ALL")
            }
        }
        /// Trailing-day window, or nil for "all history".
        var days: Int? { self == .all ? nil : rawValue }

        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    @State private var range: Range = .quarter

    // #436 — shareable offline trends report (PDF over a date range). The sheet owns its
    // own range picker; this just presents it with the loaded history.
    @State private var showingReport = false

    /// Rest's per-day series, keyed by "yyyy-MM-dd". Rest is the sleep_performance COMPOSITE (the same
    /// number the Today Rest score + the Sleep Rest-detail plot, #614 follow-up) — NOT raw efficiency,
    /// which read differently under the same "Rest" label and made the Trends Rest graph disagree with
    /// the Today Rest score (#732). sleep_performance is a metricSeries, not a DailyMetric field, so load
    /// it once (mirroring TodayView's restScore source) and key by day for `resolve` below.
    @State private var sleepPerfByDay: [String: Double] = [:]
    @State private var sleepPerfLoaded = false
    @State private var sleepPerfRevision = 0

    /// Immutable, background-built data for the selected range. Keeping this
    /// separate from SwiftUI's body guarantees the header can paint before a
    /// multi-year history is filtered and converted into chart points.
    @State private var trendsSnapshot: TrendsSnapshot?
    @State private var weeklyDigestPresentation: WeeklyDigestPresentation?
    @State private var loadFailure: LoadFailure?
    @State private var retryGeneration = 0

    // #710 — browse previous weeks in the Week-in-review digest. 0 = the week containing today; each step
    // back is one Mon–Sun week earlier. Clamped so it never runs past the earliest day we hold (see
    // `weekAnchorDay` / `stepWeek`). The Trends RANGE control below is independent of this — it scopes the
    // long-form charts; this only moves the weekly digest at the top.
    @State private var weekOffset = 0
    /// Set once the landing week has been resolved (or the user has stepped), so the automatic choice
    /// never fights manual navigation.
    @State private var hasChosenLandingWeek = false

    // Effort display scale (#268) — routes the Effort small-multiple's numbers + unit. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    // Trend chart style (line vs bar) — display-only; flips every trend card between the gradient line
    // and value-ramp bars. Read here at the screen root so a Settings change re-renders on return.
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let chartDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = utc
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
    private static let rangeDateFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.timeZone = utc
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()
    private nonisolated static func date(_ day: String) -> Date? {
        guard let (year, month, dayOfMonth) = WeeklyDigestEngine.parseYMD(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: dayOfMonth)
        )
    }
    private func date(_ day: String) -> Date? { Self.date(day) }

    // MARK: Background presentation snapshot
    //
    // days(for:) / points each re-filter the full multi-year `repo.days` array,
    // and the subviews used to fan out to them many times per render (caption +
    // widened + windowPoints, ×4 metrics). `resolve(_:)` walks the widening order
    // ONCE per metric (the smallest range ≥ selected whose window holds ≥1 point,
    // else ALL), captures that window's points and its effective range, then
    // derives the caption / widened flag from those — so a single body evaluation
    // filters each metric's window once instead of dozens of times. Identical
    // results to the old per-helper (effectiveRange / windowPoints / caption /
    // widened) computation.
    struct ResolvedMetric: Sendable {
        let points: [TrendPoint]
        let effective: Range
        let widened: Bool
    }

    struct TrendsSnapshot: Sendable {
        let recovery: ResolvedMetric
        let hrv: ResolvedMetric
        let rhr: ResolvedMetric
        let strain: ResolvedMetric
        let rest: ResolvedMetric
        let minWeekOffset: Int
    }

    private struct WeeklyDigestPresentation: Sendable {
        let sourceKey: String
        let weekOffset: Int
        let digest: WeeklyDigest
    }

    nonisolated static func buildSnapshot(
        days: [DailyMetric],
        range: Range,
        sleepPerfByDay: [String: Double],
        todayKey: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> TrendsSnapshot? {
        guard
            let recovery = resolve(
                days: days,
                selected: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: { $0.recovery }
            ),
            let hrv = resolve(
                days: days,
                selected: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: { $0.avgHrv }
            ),
            let rhr = resolve(
                days: days,
                selected: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: { $0.restingHr.map(Double.init) }
            ),
            let strain = resolve(
                days: days,
                selected: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: { $0.strain }
            ),
            let rest = resolve(
                days: days,
                selected: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: { sleepPerfByDay[$0.day] }
            ),
            let minimumOffset = minWeekOffset(
                days: days,
                todayKey: todayKey,
                shouldCancel: shouldCancel
            )
        else {
            return nil
        }
        return TrendsSnapshot(
            recovery: recovery,
            hrv: hrv,
            rhr: rhr,
            strain: strain,
            rest: rest,
            minWeekOffset: minimumOffset
        )
    }

    private nonisolated static func resolve(
        days: [DailyMetric],
        selected: Range,
        todayKey: String,
        shouldCancel: @Sendable () -> Bool,
        value: @Sendable (DailyMetric) -> Double?
    ) -> ResolvedMetric? {
        // Find the smallest range ≥ selected whose window has ≥1 point, keeping
        // that window's points so we don't re-filter to read them back.
        for range in selected.widening {
            guard let pts = points(
                days: days,
                range: range,
                todayKey: todayKey,
                shouldCancel: shouldCancel,
                value: value
            ) else {
                return nil
            }
            if !pts.isEmpty {
                return ResolvedMetric(
                    points: pts,
                    effective: range,
                    widened: range != selected
                )
            }
        }
        // No range held data: fall back to ALL (matches effectiveRange()).
        guard let pts = points(
            days: days,
            range: .all,
            todayKey: todayKey,
            shouldCancel: shouldCancel,
            value: value
        ) else {
            return nil
        }
        return ResolvedMetric(
            points: pts,
            effective: .all,
            widened: .all != selected
        )
    }

    private nonisolated static func points(
        days: [DailyMetric],
        range: Range,
        todayKey: String,
        shouldCancel: @Sendable () -> Bool,
        value: @Sendable (DailyMetric) -> Double?
    ) -> [TrendPoint]? {
        guard !shouldCancel() else { return nil }
        let cutoff = range.days.map {
            WeeklyDigestEngine.addDays(todayKey, -($0 - 1))
        }
        var result: [TrendPoint] = []
        result.reserveCapacity(days.count)
        for (index, day) in days.enumerated() {
            if index.isMultiple(of: 256), shouldCancel() {
                return nil
            }
            guard cutoff.map({ day.day >= $0 }) ?? true,
                  let metricValue = value(day),
                  let metricDate = date(day.day) else {
                continue
            }
            result.append(TrendPoint(date: metricDate, value: metricValue))
        }
        return shouldCancel() ? nil : result
    }

    private nonisolated static func minWeekOffset(
        days: [DailyMetric],
        todayKey: String,
        shouldCancel: @Sendable () -> Bool
    ) -> Int? {
        guard !shouldCancel() else { return nil }
        guard
            let earliest = days.first?.day,
            let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
            let currentMonday = WeeklyDigestEngine.mondayOfWeek(containing: todayKey)
        else { return 0 }

        var offset = 0
        var monday = currentMonday
        while monday > earliestMonday && offset > -520 {
            guard !shouldCancel() else { return nil }
            monday = WeeklyDigestEngine.addDays(monday, -7)
            offset -= 1
        }
        return offset
    }

    private nonisolated static func awaitWorker<Value: Sendable>(
        _ worker: Task<Value?, Never>,
        timeoutNanoseconds: UInt64
    ) async -> LoadRaceResult<Value> {
        await withTaskCancellationHandler {
            await withTaskGroup(
                of: LoadRaceResult<Value>.self,
                returning: LoadRaceResult<Value>.self
            ) { group in
                group.addTask {
                    .value(await worker.value)
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return .canceled
                    }
                    return .timedOut
                }

                guard let first = await group.next() else {
                    worker.cancel()
                    return .canceled
                }
                switch first {
                case .timedOut, .canceled:
                    worker.cancel()
                case .value:
                    break
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            worker.cancel()
        }
    }

    /// A padded value range for a series so the line isn't flat against the axis.
    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    private func mean(_ pts: [TrendPoint]) -> Double? {
        guard !pts.isEmpty else { return nil }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    /// The window's trend as a signed mean-of-recent-half minus mean-of-earlier-half. Drives a
    /// TrendChip so the card reads its direction at a glance, like Today's deltas. nil for a window
    /// too short to split. `higherIsBetter == nil` (e.g. Effort) keeps the chip neutral.
    private func periodChange(_ pts: [TrendPoint]) -> Double? {
        guard pts.count >= 4 else { return nil }
        let mid = pts.count / 2
        let earlier = pts.prefix(mid).map(\.value)
        let recent = pts.suffix(pts.count - mid).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        let e = earlier.reduce(0, +) / Double(earlier.count)
        let r = recent.reduce(0, +) / Double(recent.count)
        return r - e
    }

    /// A TrendChip for a window's period change, coloured green/rose by whether the move is good for
    /// THIS metric (`higherIsBetter`); neutral when direction has no valence or the change is flat.
    @ViewBuilder
    private func changeChip(_ pts: [TrendPoint], higherIsBetter: Bool?, fmt: @escaping (Double) -> String) -> some View {
        if let d = periodChange(pts), abs(d) > 0.0001 {
            let sign = d >= 0 ? "+" : "−"
            let color: Color = {
                guard let better = higherIsBetter else { return StrandPalette.textTertiary }
                return (d > 0) == better ? StrandPalette.statusPositive : StrandPalette.metricRose
            }()
            TrendChip(text: "\(sign)\(fmt(abs(d)))", color: color)
        }
    }

    /// Friendly selected-window label used by the selector and card subtitles.
    private var rangeSubtitle: String {
        rangeSubtitle(for: range)
    }

    private func rangeSubtitle(for range: Range) -> String {
        switch range {
        case .week:    return String(localized: "appwide.trends.last_7_days")
        case .month:   return String(localized: "appwide.trends.last_30_days")
        case .quarter: return String(localized: "appwide.trends.last_3_months")
        case .half:    return String(localized: "appwide.trends.last_6_months")
        case .year:    return String(localized: "appwide.trends.last_year")
        case .all:     return String(localized: "appwide.trends.all_history")
        }
    }

    private func chartSubtitle(_ metric: ResolvedMetric) -> String {
        let window = rangeSubtitle(for: metric.effective)
        guard let span = dateSpan(for: metric.effective) else {
            return window
        }
        return "\(window) · \(span)"
    }

    /// Exact calendar dates represented by a range. Finite ranges end on the phone's current local day;
    /// All History spans the first through last stored row. Day keys are parsed and formatted in UTC so
    /// a date-only value never shifts backward in western time zones.
    private func dateSpan(for range: Range) -> String? {
        let start: Date
        let end: Date
        if let count = range.days {
            guard let currentDay = date(Repository.localDayKey(Date())),
                  let firstDay = Self.utcCalendar.date(
                    byAdding: .day,
                    value: -(count - 1),
                    to: currentDay
                  ) else { return nil }
            start = firstDay
            end = currentDay
        } else {
            guard let firstDay = repo.days.first.flatMap({ date($0.day) }),
                  let lastDay = repo.days.last.flatMap({ date($0.day) }) else { return nil }
            start = firstDay
            end = lastDay
        }
        return Self.rangeDateFormatter.string(from: start, to: end)
    }

    private var historyTaskIdentity: String {
        [
            String(repo.refreshSeq),
            String(repo.days.count),
            repo.days.first?.day ?? "none",
            repo.days.last?.day ?? "none",
            String(retryGeneration),
        ].joined(separator: "|")
    }

    private var trendsTaskIdentity: String {
        [
            historyTaskIdentity,
            String(range.rawValue),
            String(sleepPerfRevision),
            sleepPerfLoaded ? "ready" : "loading",
        ].joined(separator: "|")
    }

    private var weeklyDigestTaskIdentity: String {
        [
            historyTaskIdentity,
            String(weekOffset),
            effortScaleRaw,
            hasChosenLandingWeek ? "chosen" : "landing",
            String(trendsSnapshot?.minWeekOffset ?? 1),
            String(retryGeneration),
        ].joined(separator: "|")
    }

    private func weeklyDigestSourceKey(offset: Int) -> String {
        [historyTaskIdentity, String(offset), effortScaleRaw].joined(separator: "|")
    }

    var body: some View {
        // The liquid metric cards now tap through to their MetricDetailView (matching Today's card
        // taps + Explore's rows). On iOS each tab already supplies a NavigationStack, so those pushes
        // land in the ambient stack. On macOS the .trends detail pane has NO enclosing NavigationStack
        // (RootView), so — exactly like MetricExplorerView (#753) — wrap the scaffold in one here so the
        // pushes get Back chrome instead of hanging. The SAME shared scaffold renders on both.
        #if os(macOS)
        // Register the value routes at THIS stack's root; on iOS the tab shell's stack registers
        // them instead (once per stack — a double registration double-pushes, #38).
        NavigationStack { scaffold.tabRouteDestinations() }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       onRefresh: { await repo.refresh() },
                       lazy: true,
                       topBackground: liquidScaffoldSky()) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your wearable export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else if loadFailure == .trends {
                trendsFailureCard
            } else if let snapshot = trendsSnapshot {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    // The main card list ripples in once on appear (Reduce-Motion safe).
                    Group {
                        // Week-in-review digest (#208) with prev/next week browsing (#710) — self-hides
                        // only when NO week in history has data. Past weeks render in the same format.
                        weeklyDigestNav
                            .staggeredAppear(index: 0)
                        // The Charge / Effort / Rest trio, presented in NOOP's pip language.
                        rangeBar(recovery: snapshot.recovery)
                            .staggeredAppear(index: 1)
                        selectedRangeSummary(
                            charge: snapshot.recovery,
                            effort: snapshot.strain,
                            rest: snapshot.rest
                        )
                            .staggeredAppear(index: 2)
                        heroRecovery(recovery: snapshot.recovery)
                            .staggeredAppear(index: 3)
                        smallMultiples(
                            hrv: snapshot.hrv,
                            rhr: snapshot.rhr,
                            strain: snapshot.strain
                        )
                            .staggeredAppear(index: 4)
                        yearStrip
                            .staggeredAppear(index: 5)
                        exportReportRow
                            .staggeredAppear(index: 6)
                    }
                }
            } else {
                trendsLoadingSkeleton
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
        }
        // #732 — load the resolved sleep_performance series so Rest plots the SAME composite the Today
        // Rest score uses (not raw efficiency). The presentation snapshot waits for this read, so it never
        // flashes a false "missing Sleep" row while the local series is still arriving.
        .task(id: historyTaskIdentity) {
            loadFailure = nil
            sleepPerfLoaded = false
            guard !Task.isCancelled else { return }
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            guard !Task.isCancelled else { return }
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            sleepPerfRevision &+= 1
            sleepPerfLoaded = true
        }
        .task(id: trendsTaskIdentity) {
            await loadTrendsSnapshot()
        }
        .task(id: weeklyDigestTaskIdentity) {
            await loadWeeklyDigest()
        }
    }

    private func loadTrendsSnapshot() async {
        trendsSnapshot = nil
        guard !repo.days.isEmpty, sleepPerfLoaded else { return }

        // Give SwiftUI one turn to paint the static skeleton before starting CPU work.
        await Task.yield()
        guard !Task.isCancelled else { return }

        let requestIdentity = trendsTaskIdentity
        let inputDays = repo.days
        let inputRange = range
        let inputSleep = sleepPerfByDay
        let todayKey = Repository.localDayKey(Date())
        let timeoutNanoseconds = LoadPolicy.timeoutNanoseconds(
            retryGeneration: retryGeneration
        )
        let forceDemoTimeout = CommandLine.arguments.contains("--demo-trends-timeout")
            && retryGeneration == 0
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation("trends.aggregate_prepare")
        var outcome = "completed"
        defer {
            AppDiagnosticsRecorder.shared.endOperation(diagnostic, outcome: outcome)
        }

        let worker = Task.detached(priority: .userInitiated) {
            if forceDemoTimeout {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return Optional<TrendsSnapshot>.none }
            return Self.buildSnapshot(
                days: inputDays,
                range: inputRange,
                sleepPerfByDay: inputSleep,
                todayKey: todayKey,
                shouldCancel: { Task.isCancelled }
            )
        }
        let race = await Self.awaitWorker(
            worker,
            timeoutNanoseconds: timeoutNanoseconds
        )

        guard !Task.isCancelled else {
            outcome = "canceled"
            return
        }
        guard requestIdentity == trendsTaskIdentity else {
            outcome = "superseded"
            return
        }
        let prepared: TrendsSnapshot?
        switch race {
        case .value(let value):
            prepared = value
        case .timedOut:
            outcome = "timed_out"
            loadFailure = .trends
            return
        case .canceled:
            outcome = "canceled"
            return
        }
        guard let prepared else {
            outcome = "canceled"
            return
        }
        trendsSnapshot = prepared
    }

    private func loadWeeklyDigest() async {
        guard let snapshot = trendsSnapshot, !repo.days.isEmpty else {
            weeklyDigestPresentation = nil
            return
        }

        let requestedSourceKey = weeklyDigestSourceKey(offset: weekOffset)
        if hasChosenLandingWeek,
           weeklyDigestPresentation?.sourceKey == requestedSourceKey {
            return
        }

        weeklyDigestPresentation = nil
        await Task.yield()
        guard !Task.isCancelled else { return }

        let requestIdentity = weeklyDigestTaskIdentity
        let inputDays = repo.days
        let initialOffset = weekOffset
        let chooseLandingWeek = !hasChosenLandingWeek
        let minimumOffset = snapshot.minWeekOffset
        let todayKey = Repository.localDayKey(Date())
        let effortFactor = UnitPrefs.currentEffortDisplayFactor()
        let historyIdentity = historyTaskIdentity
        let effortScaleIdentity = effortScaleRaw
        let timeoutNanoseconds = LoadPolicy.timeoutNanoseconds(
            retryGeneration: retryGeneration
        )
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation("trends.weekly_digest_prepare")
        var outcome = "completed"
        defer {
            AppDiagnosticsRecorder.shared.endOperation(diagnostic, outcome: outcome)
        }

        let worker = Task.detached(priority: .userInitiated) {
            var resolvedOffset = initialOffset
            if chooseLandingWeek {
                let floor = max(minimumOffset, -8)
                var candidate = 0
                while candidate >= floor, !Task.isCancelled {
                    let anchor = WeeklyDigestEngine.addDays(todayKey, candidate * 7)
                    let candidateDigest = WeeklyDigestSource.digest(
                        from: inputDays,
                        anchorDay: anchor,
                        effortDisplayFactor: effortFactor
                    )
                    guard !Task.isCancelled else {
                        return Optional<WeeklyDigestPresentation>.none
                    }
                    if !candidateDigest.isEmpty {
                        resolvedOffset = candidate
                        break
                    }
                    candidate -= 1
                }
            }
            guard !Task.isCancelled else {
                return Optional<WeeklyDigestPresentation>.none
            }
            let anchor = WeeklyDigestEngine.addDays(todayKey, resolvedOffset * 7)
            let digest = WeeklyDigestSource.digest(
                from: inputDays,
                anchorDay: anchor,
                effortDisplayFactor: effortFactor
            )
            guard !Task.isCancelled else {
                return Optional<WeeklyDigestPresentation>.none
            }
            let sourceKey = [
                historyIdentity,
                String(resolvedOffset),
                effortScaleIdentity,
            ].joined(separator: "|")
            return WeeklyDigestPresentation(
                sourceKey: sourceKey,
                weekOffset: resolvedOffset,
                digest: digest
            )
        }
        let race = await Self.awaitWorker(
            worker,
            timeoutNanoseconds: timeoutNanoseconds
        )

        guard !Task.isCancelled else {
            outcome = "canceled"
            return
        }
        guard requestIdentity == weeklyDigestTaskIdentity else {
            outcome = "superseded"
            return
        }
        let prepared: WeeklyDigestPresentation?
        switch race {
        case .value(let value):
            prepared = value
        case .timedOut:
            outcome = "timed_out"
            loadFailure = .weeklyDigest
            return
        case .canceled:
            outcome = "canceled"
            return
        }
        guard let prepared else {
            outcome = "canceled"
            return
        }
        hasChosenLandingWeek = true
        weekOffset = prepared.weekOffset
        weeklyDigestPresentation = prepared
    }

    private func retryTrends() {
        loadFailure = nil
        trendsSnapshot = nil
        weeklyDigestPresentation = nil
        retryGeneration &+= 1
    }

    private var trendsFailureCard: some View {
        ScreenStateCard(
            kind: .error,
            title: "appwide.trends.load_failed_title",
            message: "appwide.trends.load_failed_body",
            actionTitle: "appwide.trends.retry",
            action: retryTrends
        )
        .accessibilityIdentifier("noop.trends.failure")
    }

    private var trendsLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            trendsSkeletonCard(chartHeight: 132)
            trendsSkeletonCard(chartHeight: NoopMetrics.chartHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
        .accessibilityValue(Text("Loading your history…"))
        .accessibilityIdentifier("noop.trends.loading")
    }

    private var weeklyDigestLoadingSkeleton: some View {
        trendsSkeletonCard(chartHeight: 156)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading"))
            .accessibilityValue(Text("Loading your history…"))
            .accessibilityIdentifier("noop.trends.weekly-digest-loading")
    }

    private func trendsSkeletonCard(chartHeight: CGFloat) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Capsule()
                    .fill(StrandPalette.textTertiary.opacity(0.18))
                    .frame(width: 116, height: NoopMetrics.space2)
                Capsule()
                    .fill(StrandPalette.textTertiary.opacity(0.12))
                    .frame(width: 176, height: NoopMetrics.space3)
                RoundedRectangle(
                    cornerRadius: NoopMetrics.space2,
                    style: .continuous
                )
                .fill(StrandPalette.surfaceInset.opacity(0.72))
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Week-in-review digest with prev/next week browsing (#710)

    /// Joins two ALREADY-localized fragments for a VoiceOver hint. Kept as a helper so no string literal
    /// sits inside an accessibility modifier: the i18n audit rightly treats literals there as
    /// un-extracted copy, and a bare interpolation would also become a phantom catalog key.
    private func descriptorScopeHint(_ descriptor: String, _ scope: String) -> String {
        [descriptor, scope].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Move the digest one week earlier (-1) or later (+1), clamped to [minWeekOffset, 0] — never into a
    /// future week, never past the earliest week we hold.
    private func stepWeek(_ delta: Int) {
        hasChosenLandingWeek = true          // the user is driving now; don't re-home the digest
        let next = weekOffset + delta
        let minimumOffset = trendsSnapshot?.minWeekOffset ?? 0
        weekOffset = max(minimumOffset, min(0, next))
        weeklyDigestPresentation = nil
    }

    /// The week-in-review digest for the selected week, with prev/next chevrons in its header. The digest
    /// for `weekAnchorDay` is built straight from the shared `WeeklyDigestSource` (the same builder the
    /// standalone WeeklyDigestCard uses) so past weeks render in the identical format. The whole block
    /// self-hides only when there's no data in ANY week (an all-empty history), matching the old card.
    @ViewBuilder
    private var weeklyDigestNav: some View {
        // Only hide the navigation entirely when the WHOLE history is empty — an empty PAST week still
        // shows the header + chevrons so the user can step to a week that does hold data.
        if repo.days.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                weekNavBar
                if let presentation = weeklyDigestPresentation,
                   presentation.weekOffset == weekOffset,
                   presentation.digest.isEmpty {
                    // This particular week had no readings — keep the chevrons above so the user can move on.
                    DataPendingNote(
                        title: "No readings this week",
                        message: "Step to another week with the arrows above to see its review.")
                } else if let presentation = weeklyDigestPresentation,
                          presentation.weekOffset == weekOffset {
                    WeeklyDigestContent(
                        digest: presentation.digest,
                        compact: true,
                        importedRestAvailable: WeeklyDigestSource.hasImportedRestScore(
                            repo.importedSleep,
                            anchorDay: WeeklyDigestEngine.addDays(
                                Repository.localDayKey(Date()),
                                presentation.weekOffset * 7
                            )
                        )
                    )
                } else if loadFailure == .weeklyDigest {
                    ScreenStateCard(
                        kind: .error,
                        title: "appwide.trends.weekly_digest_failed_title",
                        message: "appwide.trends.weekly_digest_failed_body",
                        actionTitle: "appwide.trends.retry",
                        action: retryTrends
                    )
                    .accessibilityIdentifier("noop.trends.weekly-digest-failure")
                } else {
                    weeklyDigestLoadingSkeleton
                }
            }
        }
    }

    /// Prev/next week stepper. Back is clamped at the earliest week we hold; forward is clamped at this
    /// week (no future weeks). Mirrors the FullDayChartView day stepper's flat accent chevrons (#597).
    private var weekNavBar: some View {
        let atOldest = weekOffset <= (trendsSnapshot?.minWeekOffset ?? 0)
        let atNewest = weekOffset >= 0
        return HStack(spacing: NoopMetrics.cardInnerSpacing) {
            Button { stepWeek(-1) } label: {
                Image(systemName: "chevron.left").font(StrandFont.headline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                atOldest
                    ? StrandPalette.textTertiary
                    : StrandPalette.accent
            )
            .disabled(atOldest)
            .accessibilityLabel("Previous week")

            Spacer()
            VStack(spacing: 2) {
                Text(weekOffset == 0 ? String(localized: "This week") : weekOffsetLabel)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Week in review")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()

            Button { stepWeek(1) } label: {
                Image(systemName: "chevron.right").font(StrandFont.headline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                atNewest
                    ? StrandPalette.textTertiary
                    : StrandPalette.accent
            )
            .disabled(atNewest)
            .accessibilityLabel("Next week")
        }
        .padding(.horizontal, NoopMetrics.space1)
        .accessibilityElement(children: .contain)
    }

    /// "Last week" for -1, else the count of weeks back ("3 weeks ago") for the stepper's centre label.
    private var weekOffsetLabel: String {
        let n = -weekOffset
        if n == 1 { return String(localized: "Last week") }
        return String(localized: "\(n) weeks ago")
    }

    // MARK: Week in Review — the Charge / Effort / Rest trio in pip language

    /// The three daily scores as NOOP pip rows over the resolved window: Charge (recovery, 0–100),
    /// Effort (strain, shown on the WHOOP 0–21 scale per the unit toggle) and Rest (sleep_performance
    /// composite, 0–100 — the same metric the Today Rest score shows, #732). Each value ticks up via
    /// `CountUpText`; the segmented `PipBar` cascades on appear. Self-
    /// hides when none of the three carry a window mean, so an empty history shows nothing here.
    @ViewBuilder
    private func selectedRangeSummary(charge: ResolvedMetric, effort: ResolvedMetric, rest: ResolvedMetric) -> some View {
        let chargeAvg = mean(charge.points)
        let effortAvg = mean(effort.points)   // stored 0–100 internal Effort scale
        let restAvg = mean(rest.points)
        if chargeAvg != nil || effortAvg != nil || restAvg != nil {
            NoopCard(tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    rangeSummaryHeader
                    if let v = chargeAvg {
                        pipScoreRow(label: "Recovery", value: v, range: 0...100,
                                    tint: StrandPalette.chargeColor, frac: v / 100,
                                    descriptor: String(localized: "appwide.trends.recovery_descriptor"),
                                    scope: metricCoverage(charge),
                                    scopeWarning: charge.widened,
                                    unit: "/ 100",
                                    format: { "\(Int($0.rounded()))" })
                    }
                    if let v = effortAvg {
                        // Effort is stored 0–100 but reads on the WHOOP 0–21 scale per the unit toggle:
                        // convert the displayed number + bar position to the user's chosen Effort scale so
                        // the pip fill and the count-up value agree (both on the same scale).
                        let display = UnitFormatter.effortValue(v, scale: effortScale)
                        let maxV = UnitFormatter.effortValue(100, scale: effortScale)
                        // On the 0–21 WHOOP scale Effort reads to one decimal (e.g. "9.0"); on the 0–100
                        // scale it's a whole number — match `effortScaleMax` so the count-up format agrees.
                        let oneDecimal = effortScale == .whoop
                        // The vessel fills off the stored 0–100 internal scale (v), so it agrees with the
                        // Charge/Rest vessels regardless of the displayed Effort unit.
                        pipScoreRow(label: "Effort", value: display, range: 0...maxV,
                                    tint: StrandPalette.effortColor, frac: v / 100,
                                    descriptor: String(localized: "appwide.trends.effort_descriptor"),
                                    scope: metricCoverage(effort),
                                    scopeWarning: effort.widened,
                                    unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                                    format: { oneDecimal ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" })
                    }
                    if let v = restAvg {
                        pipScoreRow(label: "Sleep", value: v, range: 0...100,
                                    tint: StrandPalette.restColor, frac: v / 100,
                                    descriptor: String(localized: "appwide.trends.sleep_descriptor"),
                                    scope: metricCoverage(rest),
                                    scopeWarning: rest.widened,
                                    unit: "/ 100",
                                    format: { "\(Int($0.rounded()))" })
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var rangeSummaryHeader: some View {
        Group {
            if dynamicTypeSize == .xxxLarge || dynamicTypeSize.isAccessibilitySize {
                rangeSummaryHeaderStacked
            } else {
                ViewThatFits(in: .horizontal) {
                    rangeSummaryHeaderWide
                    rangeSummaryHeaderStacked
                }
            }
        }
    }

    private var rangeSummaryHeaderWide: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("appwide.trends.metric_trio").strandOverline()
                Text("appwide.trends.range_averages")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: NoopMetrics.space2)
            Text(rangeSubtitle)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var rangeSummaryHeaderStacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("appwide.trends.metric_trio").strandOverline()
            Text("appwide.trends.range_averages")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(rangeSubtitle)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// One pip row matching `PipBarRow`'s layout, but with the value driven by `CountUpText` so the big
    /// number ticks up. UPPERCASE label + a small liquid vessel (the score as a fill) beside the big white
    /// count-up value, over the segmented count-up bar. `frac` (0…1) is the score on the shared 0–100
    /// internal scale so the three vessels read against the same fill — a small liquid accent on a single
    /// headline metric, exactly where it reads well (not on a chart).
    private func pipScoreRow(label: LocalizedStringKey, value: Double, range: ClosedRange<Double>,
                             tint: Color, frac: Double, descriptor: String,
                             scope: String, scopeWarning: Bool, unit: String,
                             format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(descriptor)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(scope)
                    .font(StrandFont.caption)
                    .foregroundStyle(scopeWarning
                                     ? StrandPalette.statusWarning
                                     : StrandPalette.textTertiary)
            }
            HStack(spacing: NoopMetrics.space3) {
                // Static (posed) vessel — a small liquid gauge, not a live 60fps canvas, so the three
                // in this card cost a single cached frame each (same call as Today's small vessels).
                LiquidVessel(value: max(0, min(1, frac)), tint: tint, animated: false)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("appwide.trends.average_label")
                    .font(StrandFont.overline)
                    .tracking(0)
                    .foregroundStyle(StrandPalette.textTertiary)
                CountUpText(value: value, format: format,
                            font: StrandFont.number(30, weight: .bold),
                            color: StrandPalette.textPrimary)
                Text(unit)
                    .font(StrandFont.number(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            PipBar(value: value, range: range, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(
            String(
                format: String(localized: "appwide.trends.average_value_a11y_format"),
                format(value),
                unit
            )
        ))
        .accessibilityHint(Text(descriptorScopeHint(descriptor, scope)))
    }

    // MARK: Export trends report (#436)

    /// A footer entry that opens the shareable-report sheet. Flat WHOOP card with a blue accent
    /// action - the icon, label and "Export" CTA all read in the accent (blue) world, no gold.
    private var exportReportRow: some View {
        NoopCard(tint: StrandPalette.accent) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "doc.richtext")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Export trends report").strandOverline()
                    Text("A shareable one-page PDF of recovery, sleep, HRV, resting HR and strain over a range, saved on your \(Platform.deviceNoun).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                // The card's call-to-action — routed through the unified button system (secondary kind:
                // a quiet raised capsule that reads as the card action, not the one primary on the page).
                NoopButton("Export", systemImage: "square.and.arrow.up", kind: .secondary) {
                    showingReport = true
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Range control

    private func rangeBar(recovery: ResolvedMetric) -> some View {
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            SegmentedPillControl(
                Range.allCases,
                selection: $range,
                adaptsToAvailableWidth: true
            ) { $0.label }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                    Text(rangeSubtitle)
                        .strandOverline()
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("noop.trends.range-label")
                    Spacer(minLength: NoopMetrics.space2)
                    if let span = dateSpan(for: range) {
                        Text(span)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("noop.trends.range-dates")
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(rangeSubtitle)
                        .strandOverline()
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("noop.trends.range-label")
                    if let span = dateSpan(for: range) {
                        Text(span)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityIdentifier("noop.trends.range-dates")
                    }
                }
            }
            Text(recoveryCoverage(recovery))
                .font(StrandFont.footnote)
                .foregroundStyle(recovery.widened
                                 ? StrandPalette.statusWarning
                                 : StrandPalette.textTertiary)
                .accessibilityIdentifier("noop.trends.range-coverage")
        }
    }

    /// Explains the relationship between a calendar window and its one-per-day Recovery scores. This
    /// deliberately avoids "readings": the underlying sensor stream can contain thousands of samples,
    /// while this screen averages at most one settled Recovery score for each calendar day.
    private func recoveryCoverage(_ metric: ResolvedMetric) -> String {
        let count = metric.points.count
        if count == 0 {
            return String(localized: "appwide.trends.recovery_no_scores")
        }
        if metric.widened {
            return String.localizedStringWithFormat(
                String(localized: "appwide.trends.recovery_older_coverage_format"),
                count
            )
        }
        if let total = metric.effective.days {
            return String.localizedStringWithFormat(
                String(localized: "appwide.trends.recovery_coverage_format"),
                count,
                total
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "appwide.trends.recovery_history_coverage_format"),
            count
        )
    }

    private func metricCoverage(_ metric: ResolvedMetric) -> String {
        guard !metric.points.isEmpty else {
            return String(localized: "appwide.trends.recovery_no_scores")
        }
        return String.localizedStringWithFormat(
            String(localized: "appwide.trends.average_scope_format"),
            metric.points.count
        )
    }

    // MARK: Hero — recovery over time

    @ViewBuilder
    private func heroRecovery(recovery: ResolvedMetric) -> some View {
        let pts = recovery.points
        let avg = mean(pts)
        // Charge world — the WHOOP recovery value scale (red→yellow→green) drawn as a crisp flat line
        // with a bright "now" cap. No glow.
        let card = ChartCard(
            title: "Recovery",
            subtitle: chartSubtitle(recovery),
            trailing: avg.map {
                String.localizedStringWithFormat(
                    String(localized: "appwide.trends.average_format"),
                    "\(Int($0.rounded()))"
                )
            },
            height: NoopMetrics.chartHeight,
            tint: StrandPalette.chargeColor,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts,
                              gradient: StrandPalette.recoveryGradient,
                              // Lift the ceiling ~6% so a near-100 peak and the now-cap halo
                              // clear the top gridline, matching the padded small multiples.
                              valueRange: 0...106,
                              tip: StrandPalette.chargeBright,
                              valueFormat: { "\(Int($0.rounded()))" },
                              accessibilityLabel: String(localized: "Recovery trend"),
                              accessibilityIdentifier: "noop.trends.recovery.chart",
                              tapAction: { pushTabRoute(.metric("recovery")) })
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack {
                        ChartFooter([
                            ("Latest", pts.last.map {
                                "\(Int($0.value.rounded())) · \(Self.chartDateFormatter.string(from: $0.date))"
                            } ?? StrandFormat.missing),
                            ("Avg", avg.map { "\(Int($0.rounded()))" } ?? StrandFormat.missing),
                            (
                                "Peak",
                                pts.map(\.value).max().map { "\(Int($0.rounded()))" } ??
                                    StrandFormat.missing
                            ),
                            (
                                "Low",
                                pts.map(\.value).min().map { "\(Int($0.rounded()))" } ??
                                    StrandFormat.missing
                            ),
                        ])
                        changeChip(pts, higherIsBetter: true, fmt: { "\(Int($0.rounded()))" })
                    }
                }
            }
        )
        // Tap the hero to open the full Charge (recovery) metric detail — matching Today's card taps.
        // LiquidPressStyle gives the physical settle-inward on press (the liquid tap language). The card's
        // own rich labels (title + chart series + footer stats) are surfaced by the link's button element,
        // with a hint that a tap opens the detail.
        NavigationLink(value: TabRoute.metric("recovery")) { card }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint(Text(String(localized: "Opens the full Recovery metric.")))
    }

    // MARK: Small multiples — HRV / Resting HR / Day Strain

    private func smallMultiples(hrv: ResolvedMetric, rhr: ResolvedMetric, strain: ResolvedMetric) -> some View {
        let cols = [GridItem(.adaptive(minimum: 320), spacing: NoopMetrics.gap)]
        let hrvPts = hrv.points
        let rhrPts = rhr.points
        let strainPts = strain.points

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // No trailing window label — the range bar's overline already states it.
            SectionHeader("Daily signals", overline: "Trends")
            LazyVGrid(columns: cols, alignment: .leading, spacing: NoopMetrics.gap) {
                // HRV / Resting HR are Charge sub-signals → the Charge (green) card world, each line
                // keeping its established metric hue for legibility. Effort is the WHOOP blue strain world.
                metricChart(
                    title: "Heart rate variability", unit: "ms",
                    accessibilityTitle: String(localized: "Heart rate variability"),
                    metricKey: "hrv",
                    resolved: hrv,
                    gradient: gradient(StrandPalette.metricPurple),
                    tip: StrandPalette.metricPurple,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: true,
                    range: valueRange(hrvPts, fallback: 20...120),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    title: "Resting heart rate", unit: "bpm",
                    accessibilityTitle: String(localized: "Resting heart rate"),
                    metricKey: "rhr",
                    resolved: rhr,
                    gradient: gradient(StrandPalette.metricRose),
                    tip: StrandPalette.metricRose,
                    tint: StrandPalette.chargeColor,
                    higherIsBetter: false,
                    range: valueRange(rhrPts, fallback: 40...80),
                    fmt: { "\(Int($0.rounded()))" }
                )
                metricChart(
                    // Plotted points + range stay on the stored 0–100 scale (line shape unchanged); only the
                    // displayed numbers + unit follow the Effort-scale toggle, converted inside `fmt`. (#268)
                    title: "Effort", unit: "/ \(UnitFormatter.effortScaleMax(effortScale))",
                    accessibilityTitle: String(localized: "Effort"),
                    metricKey: "strain",
                    resolved: strain,
                    // WHOOP: Effort/Strain is always BLUE — a deep→bright blue line, not the amber ramp.
                    gradient: gradient(StrandPalette.effortColor),
                    tip: StrandPalette.effortColor,
                    tint: StrandPalette.effortColor,
                    higherIsBetter: nil,
                    range: valueRange(strainPts, fallback: 0...100),
                    fmt: { UnitFormatter.effortDisplay($0, scale: effortScale) }
                )
            }
        }
    }

    @ViewBuilder
    private func metricChart(
        title: LocalizedStringKey, unit: String,
        // Plain-string series name for VoiceOver (the `title` is a LocalizedStringKey and can't be
        // re-read as a String); supplied by callers so the line announces e.g. "HRV trend".
        accessibilityTitle: String,
        // MetricCatalog key this small-multiple taps through to (its full MetricDetailView).
        metricKey: String,
        resolved: ResolvedMetric,
        subtitle: String? = nil,
        gradient: Gradient,
        tip: Color,
        tint: Color,
        higherIsBetter: Bool?,
        range: ClosedRange<Double>,
        fmt: @escaping (Double) -> String
    ) -> some View {
        let pts = resolved.points
        let avg = mean(pts)
        let card = ChartCard(
            title: title,
            subtitle: subtitle ?? chartSubtitle(resolved),
            trailing: avg.map {
                String.localizedStringWithFormat(
                    String(localized: "appwide.trends.average_format"),
                    fmt($0)
                )
            },
            height: NoopMetrics.chartHeight,
            tint: tint,
            chart: {
                if pts.count >= 2 {
                    glowChart(points: pts, gradient: gradient, valueRange: range,
                              tip: tip, valueFormat: { "\(fmt($0)) \(unit)" },
                              accessibilityLabel: String(localized: "\(accessibilityTitle) trend"),
                              accessibilityIdentifier: "noop.trends.\(metricKey).chart",
                              tapAction: { pushTabRoute(.metric(metricKey)) })
                } else {
                    sparsePlaceholder
                }
            },
            footer: {
                HStack {
                    ChartFooter([
                        ("Latest", pts.last.map {
                            "\(fmt($0.value)) · \(Self.chartDateFormatter.string(from: $0.date))"
                        } ?? StrandFormat.missing),
                        // Plain "MEAN" to match the bare MIN/MAX columns; the unit moves into
                        // the value (e.g. "58 ms") so uppercasing can't render a shouty "MEAN MS".
                        ("Mean", avg.map { "\(fmt($0)) \(unit)" } ?? StrandFormat.missing),
                        ("Min", pts.map(\.value).min().map(fmt) ?? StrandFormat.missing),
                        ("Max", pts.map(\.value).max().map(fmt) ?? StrandFormat.missing),
                    ])
                    changeChip(pts, higherIsBetter: higherIsBetter, fmt: fmt)
                }
            }
        )
        // Each small-multiple taps through to its own metric detail (like Today's cards / Explore's rows),
        // with the liquid press settle. The chart itself is left uncluttered — no vessel over it (task).
        NavigationLink(value: TabRoute.metric(metricKey)) { card }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint(Text(String(localized: "Opens the full \(accessibilityTitle) metric.")))
    }

    // MARK: Year heat-strip

    private var yearStrip: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        let recent = repo.days.suffix(stripDays)
        let recoveryDays: [RecoveryDay] = recent.compactMap { d in
            guard let dt = date(d.day) else { return nil }
            return RecoveryDay(date: dt, score: d.recovery)
        }
        let title = (range == .all && repo.days.count > 365) ? String(localized: "Recovery (all history)") : String(localized: "Recovery (past year)")
        return NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("\(title)", overline: "Calendar", trailing: String(localized: "\(recoveryDays.filter { $0.score != nil }.count) days"))
                if recoveryDays.isEmpty {
                    sparsePlaceholder.frame(height: 120)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        YearHeatStrip(days: recoveryDays).padding(.vertical, NoopMetrics.space1 / 2)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space2) {
            Text("Depleted").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 8)
                .clipShape(Capsule())
            Text("Peaked").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
        }
    }

    // MARK: Shared bits

    /// Single-color gradient (for metric lines that aren't a value ramp).
    private func gradient(_ color: Color) -> Gradient {
        Gradient(stops: [
            .init(color: color.opacity(0.55), location: 0.0),
            .init(color: color, location: 1.0),
        ])
    }

    /// A domain-tinted `TrendChart` with a crisp flat line and a bright end-cap dot at the latest
    /// point. WHOOP-flat: no underglow blur layer — the single crisp line carries the data and the
    /// fill contrast does the rest. The "now" end-cap is a small dot pinned to the final sample.
    /// Pure presentation: it forwards every value to the locked `TrendChart` unchanged.
    @ViewBuilder
    private func glowChart(points pts: [TrendPoint], gradient: Gradient, valueRange: ClosedRange<Double>,
                           tip: Color, valueFormat: @escaping (Double) -> String,
                           accessibilityLabel: String,
                           accessibilityIdentifier: String,
                           tapAction: @escaping () -> Void) -> some View {
        // One crisp, interactive line + area — flat, no blurred glow copy underneath (WHOOP language).
        // The "now" end-cap is drawn INSIDE this chart (nowCapColor) so it's mapped by the chart's own
        // scales and lands on the line — the previous sibling overlay guessed the plot insets and
        // floated the dot left/below the curve (#458).
        TrendChart(points: pts, gradient: gradient, valueRange: valueRange,
                   showsArea: true,
                   showsBars: TrendChartStyle(rawValue: trendChartStyleRaw) == .bar,
                   height: NoopMetrics.chartHeight, valueFormat: valueFormat,
                   accessibilityLabel: accessibilityLabel,
                   accessibilityIdentifier: accessibilityIdentifier,
                   tapAction: tapAction,
                   nowCapColor: tip)
    }

    private var sparsePlaceholder: some View {
        Text("Not enough data for this window.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
