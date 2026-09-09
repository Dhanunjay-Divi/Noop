//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with a card-level source badge, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics
#if os(iOS)
import UIKit
#endif

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var behavior: BehaviorStore
    // For the pull-to-sync gesture (#334): a pull kicks a manual strap history offload via ble.syncNow().
    // Observe BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it
    // would re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager
    // only publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @StateObject private var weather = TodayWeatherStore()
    @AppStorage(TodayWeatherStore.enabledKey) private var todayWeatherEnabled = false
    @State private var showWeatherDetails = false
    #endif

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.massKey) private var massUnitRaw = ""
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureUnitRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var massUnit: MassUnit { UnitPrefs.resolveMass(system: unitSystem, override: massUnitRaw) }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureUnitRaw)
    }
    /// Hydration is independently opt-in. A saved dashboard selection must not keep a dead hydration
    /// row visible after the feature is turned off.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?

    private var enabledDashboardCards: [DashboardCard] {
        Self.visibleDashboardCards(selectionRaw: dashboardCardsRaw,
                                   hydrationEnabled: hydrationEnabled)
    }

    /// Pure visibility seam shared by the view and its regression test. Hydration requires both the
    /// saved card selection and the independent feature opt-in; every other selected card is unchanged.
    static func visibleDashboardCards(selectionRaw: String,
                                      hydrationEnabled: Bool) -> [DashboardCard] {
        DashboardCardPrefs.decodeEnabled(selectionRaw)
            .filter { hydrationEnabled || $0 != .hydration }
    }

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    /// Raw resolver source ids for the three scores, keyed by recovery / strain / sleep_performance.
    /// Presentation uses Today's shared mapper so Liquid and Classic name a source consistently.
    @State private var heroProvenanceByMetric: [String: String] = [:]
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vitality: Double?           // exploreSeries("vitality").last
    @State private var ageMetricsLoadedProfileState: String?
    private var visibleFitnessAge: Double? {
        ageMetricsLoadedProfileState == profile.ageMetricStateToken ? fitnessAge : nil
    }
    private var visibleVitality: Double? {
        ageMetricsLoadedProfileState == profile.ageMetricStateToken ? vitality : nil
    }
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var importedStepsDay: Int?      // Apple Health measured steps for the selected day (preferred)
    @State private var importedActiveKcalDay: Double?  // Apple Health active component for the selected day
    @State private var importedRestingKcalDay: Double? // Apple Health basal/resting component for the selected day
    @State private var importedWeightKg: Double?    // freshest measured weight at or before selected day
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    @State private var workouts: [WorkoutRow] = [] // newest-first

    // sheets / expanders
    /// A score tap opens the full, source-aware metric dossier. A double tap (and the named VoiceOver
    /// action) opens the short "what is this / why it matters?" sheet without requiring data first.
    @State private var selectedHeroMetric: MetricDescriptor?
    @State private var explainedMetric: MetricDescriptor?
    @State private var showCustomise = false
    @State private var showSettings = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false
    @State private var showNotificationPermissionAlert = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    // #today-layout (parity with Android): the user-chosen section order, persisted under the byte-identical
    // "today.sectionOrder" key the Android TodayLayoutPrefs uses. Reordered via the Arrange sheet (native
    // drag-to-reorder rows); every section always renders (decode inserts a missing one at its default spot).
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @State private var showArrangeSheet = false
    private var sectionOrder: [TodaySection] {
        let saved = TodayLayoutPrefs.decodeOrder(sectionOrderRaw)
        #if DEBUG
        // Screenshot QA can bring the otherwise off-screen metrics grid into the first lazy-stack batch.
        // Reordering the same production sections is more deterministic than synthesizing swipe coordinates.
        if CommandLine.arguments.contains("--demo-key-metrics") {
            return [.keyMetrics] + saved.filter { $0 != .keyMetrics }
        }
        #endif
        return saved
    }
    // The Key-Metrics grid always shows the full catalog. The shared editor chooses the three-to-five
    // metrics pinned first and their order; every applicable tile keeps its compact history trace.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @State private var showKeyMetricsEditor = false
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }
    private var visibleKeyMetrics: [KeyMetric] {
        KeyMetricPrefs.catalogOrder(startingWith: enabledKeyMetrics)
    }
    /// One shared, selected-day-anchored history cache for the compact tile traces. Building this in
    /// `load()` keeps the grid body O(1), and prevents an older selected day from seeing future readings.
    @State private var keyMetricTrends: [KeyMetric: [Double]] = [:]
    /// Calibrated percentages resolved across imports and Apple Health. Raw band red/IR remains separate.
    @State private var resolvedSpo2ByDay: [String: Double] = [:]
    // Daily Action uses the same stable, day-scoped keys as BehaviorStore without observing AppModel.
    // AppStorage keeps the control reactive while the expensive planner result is cached with readiness.
    @AppStorage(BehaviorStore.dailyActionCheckInDayKey) private var dailyActionCheckInDay = ""
    @AppStorage(BehaviorStore.dailyActionCheckInValueKey) private var dailyActionCheckInValue = ""
    @State private var dailyPlanExpanded = false

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    @State private var cachedDailyActionPlan: DailyActionPlanner.Plan?
    /// The exact day currently supporting the readiness read. Kept beside the cached result so Today can
    /// stamp freshness/confidence without recomputing or implying a carried night belongs to today.
    @State private var readinessAsOfDay: String?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// Per-field carries stay separate from the whole-row vitals carry because computed recovery rows can
    /// legitimately omit SpO₂ or skin temperature. Cached once in load(), never rescanned from body.
    @State private var cachedSpo2Day: DailyMetric?
    @State private var cachedSkinTempDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load() alongside
    /// the other caches. It composes `TodayView.lastScoredRecoveryDay`, which is O(days) — exactly the scan
    /// this cache exists to keep out of body. Never resolved in body.
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    /// Fire the score-arrival cue once per logical day, only when today's own Charge resolves. Persisting
    /// the delivered day prevents tab/view reconstruction from replaying it; carried and historical scores
    /// keep their existing day-navigation selection tick instead of producing a second impact.
    @AppStorage("liquidToday.chargeLandingHapticDay") private var chargeLandingHapticDay = ""
    @State private var chargeLandingHapticTrigger = 0
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false
    /// Blocks query work until a multi-session history-write burst has been stably quiet.
    @State private var historyWriteQueryGate = false
    /// Forces one real post-sync load even if raw rows changed without advancing a query-cache revision.
    @State private var deferredQueryLoadForHistoryWrite = false
    /// The selected day currently represented by the query-backed state below. It lets a same-day refresh
    /// preserve visible values while an offload writes, while a day change still loads immediately.
    @State private var loadedQueryDayKey: String?

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    /// Raw offsets arrive every display-linked scroll update. Reference storage keeps that bookkeeping
    /// from invalidating this entire dashboard; only visible pull-state transitions remain `@State`.
    @State private var scrollTracker = LiquidTodayScrollTracker()
    @State private var pullGestureStartedAtTop: Bool?
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80
    private static let minimumRefreshPresentation: Duration = .seconds(2)

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = Color(.sRGB, red: 13 / 255, green: 14 / 255, blue: 20 / 255, opacity: 0.80)
    /// "Card transparency" (0–100, default 100): fades every liquid card surface here - the hero, the
    /// session-start row, the metric tiles and the `card` helper — in lockstep with the frosted cards.
    /// Content sits above the surface so it stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }
    /// "Background behind cards" (default ON): extend the obsidian field behind the WHOLE scroll so the
    /// Card-transparency slider reveals it under every card. The persisted key remains cross-platform.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = SkyBehindCardsPrefs.defaultEnabled
    /// Dimensional scene backdrop. Default ON. When off, Today drops to the plain canvas.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    private var spo2Day: DailyMetric? { cachedSpo2Day }
    private var skinTempDay: DailyMetric? { cachedSkinTempDay }
    /// The Charge hero's resolved state (see `cachedChargeDisplay`), read O(1) from the cache.
    private var chargeDisplay: ChargeDisplay { cachedChargeDisplay }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize - the header showed English "Today"/"Yesterday"/weekday even when the
        // system UI (tab bar etc.) was another language. "Today"/"Yesterday" go through String(localized:)
        // (matching the classic TodayView.dayNavLabel), and the weekday name is formatted in the user's
        // locale, not the en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(Locale.autoupdatingCurrent))
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    /// iOS 26 can hold the ScrollView preference at zero throughout elastic top bounce. Keep the
    /// preference path for older releases, but drive the same state machine directly from a vertical
    /// gesture that began at the top so pull-to-sync cannot silently disappear.
    private var pullRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let startedAtTop = pullGestureStartedAtTop ?? (scrollTracker.offset >= -2)
                if pullGestureStartedAtTop == nil {
                    pullGestureStartedAtTop = startedAtTop
                }
                let dx = value.translation.width
                let dy = value.translation.height
                guard startedAtTop, dy > 0, abs(dy) > abs(dx) * 1.2 else { return }
                handlePull(dy)
            }
            .onEnded { value in
                let startedAtTop = pullGestureStartedAtTop ?? (scrollTracker.offset >= -2)
                pullGestureStartedAtTop = nil
                let dx = value.translation.width
                let dy = value.translation.height
                guard startedAtTop, dy > 0, abs(dy) > abs(dx) * 1.2 else {
                    if refreshArmed { refreshArmed = false }
                    pullY = 0
                    return
                }
                // ScrollView can coalesce the final onChanged sample under load. Honor the release
                // distance itself so a clearly completed pull cannot miss the sync threshold.
                if dy >= pullThreshold, !refreshArmed {
                    refreshArmed = true
                    pullHaptic &+= 1
                }
                handlePull(0)
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Scroll-to-top on an at-root Today re-tap (#198 follow-up); default 0 so macOS/other contexts stay inert.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @Environment(\.scrollPositionReporter) private var reportScrollPosition
    private static let topAnchorID = "liquidToday.top"
    private static let bottomAnchorID = "liquidToday.bottom"
    private static let patternsAnchorID = "liquidToday.patterns"
    private static let dailyPlanAnchorID = "liquidToday.dailyPlan"
    private static let keyMetricsAnchorID = "liquidToday.keyMetrics"

    var body: some View {
        liquidBody
            // A neutral one-shot cue means "today's number has arrived." Historical-day changes already
            // have a selection tick, and a carried prior-night value is not a newly resolved Charge.
            .strandHaptic(.light, trigger: chargeLandingHapticTrigger)
            .alert("Notifications are off", isPresented: $showNotificationPermissionAlert) {
                Button("appwide.action.open_settings") { openNotificationSettings() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("appwide.notifications.effort_permission_message")
            }
    }

    private var liquidBody: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height scroll-to-top anchor (#198 follow-up): the target for an at-root Today re-tap.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a vessel filling with the pull

                // Keep the first screen immediate and defer expensive lower sections (notably the
                // raw-sample auto-workout scan) until they approach the viewport. This also lets SwiftUI
                // retire offscreen liquid canvases instead of animating the whole dashboard while scrolling.
                LazyVStack(alignment: .leading, spacing: 12) {
                    scene
                    // A raised multi-signal warning must remain visible on the default Today surface.
                    // Keep it pinned outside the reorderable section list so it cannot be moved below the
                    // fold; the leaf renders nothing while AppModel has no active warning.
                    HealthAlertBanner()
                    // #105: the live "workout in progress" card, dropped in the liquid Home rewrite. Restored
                    // here as the SAME leaf the classic TodayView renders (and Android's WorkoutInProgressCard),
                    // pinned above the reorderable block so an active manual workout is immediately visible
                    // and taps straight through to Live. Renders nothing when no workout is active.
                    ActiveWorkoutIndicatorSection()
                    // #today-layout (parity with Android): every Today section — the Charge/Effort/Rest hero
                    // and Start-session included — renders in the user's saved order. Reorder via the Arrange
                    // sheet (the header's up/down button; native drag rows); the order persists under the
                    // byte-identical "today.sectionOrder" key Android uses. A gated-off Start-session renders
                    // nothing and keeps its slot in the saved order.
                    ForEach(sectionOrder) { section in
                        switch section {
                        case .hero: heroCard
                        case .liveSession: if liveSessionsBeta { liveSessionStartRow }
                        // NEW (2026-08-22) — the three blocks that answer, in reading order: why is my
                        // score that number, what should I do about it, and is anything off. They reuse
                        // this screen's own card/glyph language and its already-loaded data, so nothing
                        // existing moved and no new plumbing was introduced.
                        case .why: whySection
                        case .target:
                            if selectedDayOffset == 0 {
                                targetSection.id(Self.dailyPlanAnchorID)
                            }
                        case .watch: watchSection
                        case .synthesis: synthesisSection
                        case .keyMetrics: keyMetricsSection.id(Self.keyMetricsAnchorID)
                        case .workouts: lastWorkoutsSection
                        case .heartRate: heartRateSection
                        case .recoveryVitals: recoveryVitalsSection
                        case .yourCards: yourCardsSection
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — the Arrange sheet moves it. Today only;
                        // the card self-hides when the reminder toggle is off (an empty branch renders
                        // nothing yet keeps its slot). Twin of Android TodayScreen's JOURNAL arm.
                        case .journal: if selectedDayOffset == 0 { JournalReminderCard() }
                        }
                    }
                    // The suggestion leaf owns the auto-detection mode and candidate gates, so mounting it
                    // here has zero empty-state footprint while making the opt-in feature reachable from
                    // the default Liquid Today screen.
                    AutoWorkoutCard()
                    dataSourcesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 30) // sit the title lower into the sky, not jammed under the status bar
                // The shell reserves the bar's layout height. Keep the same small content breathing room
                // as ScreenScaffold so the bar's upward-cast shadow never washes over the final card.
                .padding(.bottom, NoopMetrics.space4)

                // Layout-neutral end marker. The iOS tab shell reserves its measured bar height around
                // this entire root, so scrolling here must expose the true final card above that bar.
                Color.clear.frame(height: 0).id(Self.bottomAnchorID)
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .background(HistoryWriteQueryGateBridge(blocked: $historyWriteQueryGate))
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { offset in
            scrollTracker.offset = offset
            handlePull(offset)
            reportScrollPosition(offset)
        }
        // The original satin-obsidian field is a FIXED full-bleed backdrop behind the scroll content,
        // edge-to-edge under the status bar. It does not scroll, so the UI reads as glass moving over
        // physical hardware rather than wallpaper moving with the cards.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                if showDayCycleBackground {
                    ObsidianFlowBackground(compact: !skyBehindCards, intensity: 0.94)
                    .frame(maxWidth: .infinity)
                    .frame(height: skyBehindCards ? nil : 340, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
        }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(pullRefreshGesture)
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        .task(id: "\(repo.refreshSeq)-\(repo.ageMetricsSeq)-\(repo.workoutsSeq)-\(repo.deviceId)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)-\(historyWriteQueryGate)-\(profile.ageMetricStateToken)-\(dailyActionCheckInDay)-\(dailyActionCheckInValue)") {
            await load()
        }
        #if DEBUG
        // Deterministic screenshot framing only; absent in Release. Key this to the real load state rather
        // than a wall-clock guess: compact simulators can take longer than 650 ms to seed, and scrolling
        // before the cards arrive leaves the supposedly "bottom" capture stranded halfway down the page.
        .task(id: dataLoaded) {
            guard dataLoaded else { return }
            // Let the loaded card hierarchy and RootTabView's measured bar reservation complete a
            // layout pass. A single yield can still run before the preference-driven bottom padding is
            // applied, leaving a deterministic "bottom" screenshot one bar-height short on cold launch.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if CommandLine.arguments.contains("--demo-daily-plan") {
                proxy.scrollTo(Self.dailyPlanAnchorID, anchor: .top)
            } else if CommandLine.arguments.contains("--demo-key-metrics") {
                proxy.scrollTo(Self.keyMetricsAnchorID, anchor: .top)
            } else if CommandLine.arguments.contains("--demo-patterns") {
                proxy.scrollTo(Self.patternsAnchorID, anchor: .center)
            } else if CommandLine.arguments.contains("--demo-scroll-bottom") {
                // Simulator-only layout proof for the custom (non-ScreenScaffold) Today scroll.
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        #endif
        #if os(iOS)
        .task(id: todayWeatherEnabled) {
            weather.startIfEnabled(todayWeatherEnabled)
        }
        .onChange(of: weather.snapshot) { _, _ in
            updateAdaptiveHydrationContext()
        }
        #endif
        .navigationDestination(isPresented: Binding(
            get: { selectedHeroMetric != nil },
            set: { if !$0 { selectedHeroMetric = nil } }
        )) {
            if let metric = selectedHeroMetric {
                MetricDetailView(metric: metric)
            }
        }
        .sheet(item: $explainedMetric) { metric in
            MetricExplanationSheet(metric: metric)
        }
        .sheet(isPresented: $showCustomise) {
            DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(focus: .profile)
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        // #today-layout: the Arrange sheet — native drag-to-reorder rows over the same persisted order.
        .sheet(isPresented: $showArrangeSheet) {
            TodayArrangeSheet(orderRaw: $sectionOrderRaw)
        }
        // #430 parity: the Key-Metrics editor (selection + order + the Detailed-tiles switch), the same
        // sheet the classic macOS grid uses, bound to the same persisted layout string.
        .sheet(isPresented: $showKeyMetricsEditor) {
            KeyMetricsEditorSheet(layoutRaw: $keyMetricsRaw)
        }
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root Today re-tap (#198 follow-up); iOS-only — the tab shell is the only driver.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs. A plain computed property (not a LiveState-isolated leaf) — it doesn't read
    /// LiveState itself, so it's cheap to re-evaluate as part of the main body. It hands the actual
    /// visibility decision to `LiquidRefreshIndicator` below, which DOES own LiveState.
    private var liquidRefreshIndicator: some View {
        LiquidRefreshIndicator(pullY: pullY, pullThreshold: pullThreshold, refreshing: refreshing,
                               liquidHeart: liquidHeart, hasCachedContent: !repo.days.isEmpty)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        let nextPullY = max(0, y)
        // During ordinary upward scrolling the preference is negative, so both values are zero. Avoid
        // assigning the same @State value on every scroll sample; this view owns the whole dashboard and
        // a redundant write needlessly invalidates all of its cards while the finger is moving.
        if abs(nextPullY - pullY) > 0.5 { pullY = nextPullY }
        guard !refreshing else { return }
        if nextPullY >= pullThreshold, !refreshArmed {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, nextPullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                let clock = ContinuousClock()
                let earliestFinish = clock.now.advanced(by: Self.minimumRefreshPresentation)
                // #334 (iOS twin of Android #426): a pull requests a fresh strap history offload, not just
                // a UI reload. syncNow() is internally gated (connected + bonded + not-already-backfilling),
                // so a pull while disconnected or mid-offload safely no-ops. The sync status chip owns the
                // ongoing offload progress; the pull spinner stays short (the reload below).
                ble.syncNow()
                let previousSeq = repo.refreshSeq
                await repo.refresh()
                // A changed refreshSeq re-runs the keyed task above. Only an unchanged refresh needs an
                // explicit reload (for raw intraday samples that don't alter the daily cache), preventing
                // two concurrent copies of the same expensive Today load.
                if repo.refreshSeq == previousSeq { await load() }
                // Fast local refreshes used to finish while the drag was still settling, so the custom
                // indicator could disappear before a sighted user or assistive technology observed it.
                // Slow refreshes do not pay an extra delay: this is a minimum presentation deadline.
                try? await clock.sleep(until: earliestFinish)
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Scene (brand rail + day title)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Give the product a real masthead instead of leaving the wordmark floating in a large
            // decorative gap between the date and the data. The controls remain one-tap reachable,
            // while the compact lockup makes this screen unmistakably NOOP at first glance.
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                LiquidWordmark(compact: true)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    NavigationLink(value: TabRoute.calendar) {
                        Image(systemName: "calendar")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(StrandPalette.surfaceRaised.opacity(0.82)))
                            .overlay(Circle().strokeBorder(
                                StrandPalette.hairlineStrong.opacity(0.72),
                                lineWidth: 1
                            ))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("History calendar")
                    .accessibilityIdentifier("noop.today.calendar")
                    // A real profile photo can carry identity beside the wordmark. With no photo, use a
                    // quiet person glyph instead of repeating the NOOP logo twice in the same masthead.
                    Button { showSettings = true } label: {
                        if profile.hasAvatar {
                            ProfileAvatarView(imageData: profile.avatarImageData, size: 34)
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(StrandPalette.surfaceRaised.opacity(0.82)))
                                .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong.opacity(0.72), lineWidth: 1))
                                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                        }
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Profile")
                    LiquidBatteryButton()
                    // Keep page customisation in one conventional overflow instead of giving three
                    // editing actions equal visual weight beside live health controls.
                    Menu {
                        Button { showArrangeSheet = true } label: {
                            Label("Arrange sections", systemImage: "arrow.up.arrow.down")
                        }
                        Button { showCustomise = true } label: {
                            Label("Dashboard cards", systemImage: "rectangle.grid.1x2")
                        }
                        Button { showKeyMetricsEditor = true } label: {
                            Label("Key metrics", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(StrandPalette.surfaceRaised.opacity(0.82)))
                            .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong.opacity(0.72), lineWidth: 1))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Customize Today")
                }
            }

            Group {
                if dynamicTypeSize == .xxxLarge || dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        dayPickerButton
                        #if os(iOS)
                        if selectedDayOffset == 0 {
                            weatherChip
                        }
                        #endif
                    }
                } else {
                    HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                        dayPickerButton
                        Spacer(minLength: NoopMetrics.space1)
                        #if os(iOS)
                        if selectedDayOffset == 0 {
                            weatherChip
                                .padding(.bottom, 3)
                        }
                        #endif
                    }
                }
            }
            .padding(.top, NoopMetrics.space5)
            .padding(.bottom, NoopMetrics.space4)
            .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(NoopMetrics.space3)
                    .frame(minWidth: 320, minHeight: 360)
                    .liquidPopoverAdaptation()
            }
        }
    }

    private var dayPickerButton: some View {
        Button { showDayPicker = true } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(dateLine)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(selectedDayOffset == 0 ? greeting : dayTitle)
                    .font(StrandFont.rounded(30, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    #if os(iOS)
    private var weatherChip: some View {
        Button(action: handleWeatherTap) {
            HStack(spacing: 6) {
                weatherChipContent
            }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(weather.snapshot == nil
                             ? StrandPalette.textSecondary
                             : StrandPalette.chargeBright)
            .frame(width: 82, height: 34)
            .background(Capsule().fill(.white.opacity(0.055)))
            .overlay(
                Capsule().strokeBorder(
                    weather.snapshot == nil
                        ? StrandPalette.hairlineStrong.opacity(0.72)
                        : StrandPalette.chargeColor.opacity(0.34),
                    lineWidth: 0.8
                )
            )
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(weatherAccessibilityLabel)
        .accessibilityIdentifier("noop.today.weather")
        .popover(isPresented: $showWeatherDetails) {
            weatherDetails
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder private var weatherChipContent: some View {
        if weather.status == .locating {
            ProgressView()
                .controlSize(.small)
            Text("Weather")
                .lineLimit(1)
        } else if let snapshot = weather.snapshot {
            Image(systemName: snapshot.symbolName)
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            Text(weatherTemperature(snapshot.temperatureC))
                .monospacedDigit()
                .lineLimit(1)
        } else if weather.status == .denied {
            Image(systemName: "location.slash")
                .accessibilityHidden(true)
            Text("Weather")
                .lineLimit(1)
        } else {
            Image(systemName: "cloud.sun")
                .accessibilityHidden(true)
            Text("Weather")
                .lineLimit(1)
        }
    }

    @ViewBuilder private var weatherDetails: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let snapshot = weather.snapshot {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: snapshot.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.condition)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(weatherFullTemperature(snapshot.temperatureC))
                            .font(StrandFont.number(24))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text("Updated \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Button {
                    weather.refresh(requestAuthorization: false)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                Link(destination: weather.attributionURL) {
                    Label("Weather data from Apple", systemImage: "arrow.up.right")
                }
                .font(StrandFont.caption)
            } else if weather.status == .denied {
                Label("Location is off for weather", systemImage: "location.slash")
                    .font(StrandFont.headline)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .foregroundStyle(StrandPalette.accent)
            } else {
                Label("Current weather", systemImage: "cloud.sun")
                    .font(StrandFont.headline)
                Text("Uses one coarse location with Apple Weather. NOOP does not store location history.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable weather") {
                    todayWeatherEnabled = true
                    weather.enableAndRefresh()
                }
                .foregroundStyle(StrandPalette.accent)
            }
        }
        .padding(NoopMetrics.space5)
        .frame(minWidth: 270, alignment: .leading)
        .background(StrandPalette.surfaceBase)
    }

    private func handleWeatherTap() {
        if weather.snapshot != nil || weather.status == .denied {
            showWeatherDetails = true
        } else {
            todayWeatherEnabled = true
            weather.enableAndRefresh()
        }
    }

    private var weatherAccessibilityLabel: String {
        guard let snapshot = weather.snapshot else {
            return weather.status == .denied
                ? String(localized: "Weather unavailable. Location access is off.")
                : String(localized: "Enable current weather")
        }
        return "\(snapshot.condition), \(weatherFullTemperature(snapshot.temperatureC))"
    }

    private func weatherTemperature(_ celsius: Double) -> String {
        let value = temperatureUnit == .fahrenheit
            ? UnitFormatter.celsiusToFahrenheit(celsius)
            : celsius
        return "\(Int(value.rounded()))°"
    }

    private func weatherFullTemperature(_ celsius: Double) -> String {
        UnitFormatter.temperatureFromCelsius(celsius, unit: temperatureUnit, decimals: 0)
    }
    #endif

    /// Live Session entry (silent guardian, beta). It opens an explicit pre-session explanation; no
    /// realtime tracking begins until the separate Start confirmation on that screen.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("appwide.live_session.start")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.onDarkPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Text("BETA")
                            .font(StrandFont.overlineScaled(8.5)).tracking(0)
                            .foregroundStyle(StrandPalette.onDarkSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 2.5)
                            .background(Capsule().fill(.white.opacity(0.05))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)))
                    }
                    Text("appwide.live_session.start_detail")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.onDarkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(heroFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.060), .clear, .black.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.20), .white.opacity(0.055), .black.opacity(0.84)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    )
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
                    .opacity(cardOpacity)
            )
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("appwide.live_session.start_accessibility")
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            DailySignalHeader(
                readiness: readiness,
                includesCurrentWellnessSignal: selectedDayOffset == 0,
                sourceLabel: heroSourceLabel
            )

            Button { openHeroMetric("recovery") } label: {
                V2HeroArc(
                    label: String(localized: "Recovery"),
                    value: chargeDisplay.pct,
                    base: recoveryHeroTone,
                    tip: recoveryHeroTip,
                    caption: recoveryHeroCaption,
                    size: 156
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { explainHeroMetric("recovery") }
            )

            HStack(spacing: 28) {
                Button { openHeroMetric("sleep_performance") } label: {
                    V2SatelliteRing(
                        label: String(localized: "Sleep"),
                        value: restScore,
                        base: sleepHeroTone,
                        tip: sleepHeroTip,
                        size: 60
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { explainHeroMetric("sleep_performance") }
                )

                let effortValue = displayDay?.strain.map {
                    UnitFormatter.effortValue($0, scale: effortScale)
                }
                Button { openHeroMetric("strain") } label: {
                    V2SatelliteRing(
                        label: String(localized: "Effort"),
                        value: effortValue,
                        max: effortScale == .whoop ? 21 : 100,
                        base: StrandPalette.effortColor,
                        tip: StrandPalette.effortBright,
                        size: 60,
                        decimals: effortScale == .whoop ? 1 : 0
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { explainHeroMetric("strain") }
                )
            }
            .frame(maxWidth: .infinity)

            // Fitness Age is intentionally a compact long-term lane, not a fourth daily score. It only
            // appears on Today: `fitnessAge` is the latest WEEKLY estimate across history, so showing it
            // while browsing an older day would leak a future value into that day's card.
            if selectedDayOffset == 0 {
                let last7 = repo.days.suffix(7)
                Divider().overlay(StrandPalette.onDarkSecondary.opacity(0.20))
                FitnessAgeHeroRow(
                    age: visibleFitnessAge,
                    profileAge: profile.age,
                    calibrationText: fitnessCalibrationCompactCopy(
                        rhrDays: last7.compactMap { $0.restingHr }.count,
                        activityDays: last7.compactMap { $0.strain }.count,
                        hasAge: profile.ageInputConfirmed
                            && FitnessAgeEngine.supports(age: Double(profile.age)),
                        hasSex: profile.sexInputConfirmed
                            && FitnessAgeEngine.supports(sex: profile.sex)
                    ),
                    onOpen: { openHeroMetric("fitness_age") },
                    onExplain: { explainHeroMetric("fitness_age") }
                )
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .padding(.horizontal, NoopMetrics.space4)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(hex: "#070908").opacity(cardOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    recoveryHeroTone.opacity(0.16),
                                    recoveryHeroTone.opacity(0.045),
                                    .clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.07), .clear, .black.opacity(0.24)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    recoveryHeroTone.opacity(0.34),
                                    .white.opacity(0.08),
                                    .black.opacity(0.86),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
                .opacity(cardOpacity)
        )
    }

    private var recoveryHeroColors: (base: Color, tip: Color) {
        guard let score = chargeDisplay.pct else {
            return (StrandPalette.chargeColor, StrandPalette.chargeBright)
        }
        return StrandPalette.recoveryGaugeColors(score)
    }

    private var recoveryHeroTone: Color {
        recoveryHeroColors.base
    }

    private var recoveryHeroTip: Color {
        recoveryHeroColors.tip
    }

    private var recoveryHeroCaption: String {
        if let score = chargeDisplay.pct {
            return StrandPalette.recoveryState(score).localizedCapitalized
        }
        return chargeDisplay.calibrationCaption
            ?? chargeDisplay.stateLabel
    }

    private var sleepHeroTone: Color {
        guard let score = restScore else { return StrandPalette.restColor }
        if score < 50 { return StrandPalette.recovery000 }
        if score < 70 { return StrandPalette.statusWarning }
        return StrandPalette.restColor
    }

    private var sleepHeroTip: Color {
        guard let score = restScore else { return StrandPalette.restBright }
        if score < 50 { return StrandPalette.recovery030 }
        if score < 70 { return StrandPalette.recovery055 }
        return StrandPalette.restBright
    }

    private func openHeroMetric(_ key: String) {
        selectedHeroMetric = MetricCatalog.all.first { $0.key == key && $0.source == "my-whoop" }
            ?? MetricCatalog.all.first { $0.key == key }
    }

    private func explainHeroMetric(_ key: String) {
        explainedMetric = MetricCatalog.all.first { $0.key == key && $0.source == "my-whoop" }
            ?? MetricCatalog.all.first { $0.key == key }
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART RATE", trailing: "Live")
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. Make the live HR card a one-tap route into it, with a visible
            // "Full day" affordance so it's discoverable again. (This comment used to claim the Deep
            // Timeline already drew sleep + activity bands — it didn't at the time; the #979 spin-off
            // added that parity in FullDayChartView.)
            NavigationLink(value: TabRoute.fullDayChart) {
                card {
                    VStack(spacing: 10) {
                        // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                        // this card, never the whole Today. Shows the current bpm live with a rolling
                        // beat-by-beat trace; falls back to today's banked 5-minute trace when idle.
                        LiquidLiveHR(tint: liquidHeart, fallback: hrValues, animated: dataLoaded)
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Full day").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint("Opens the full-day heart rate timeline")
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(0)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { showCustomise = true } label: {
                    // #492 item 4 parity: unify the Your Cards / Key Metrics edit affordance to "EDIT" across
                    // platforms (Android #563). Reuse the localized "Edit" key, uppercased at display, so this
                    // stays translated (BEARBEITEN / MODIFIER / …) without a new literal.
                    Text(String(localized: "Edit").uppercased()).font(StrandFont.overlineScaled(11)).tracking(0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live. The independent hydration opt-in
            // also applies here, matching classic Today and preventing a disabled blank row.
            ForEach(enabledDashboardCards) { card in
                liquidCard(for: card)
            }
        }
    }

    /// One "Your cards" row for a given card type - honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(.stress, title: card.title, sub: card.subtitle,
                     value: stressText, symbol: card.icon, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(.metric("fitness_age"), title: card.title, sub: card.subtitle,
                     value: visibleFitnessAge.map(FitnessAgePresentation.value) ?? "–", symbol: card.icon,
                     tint: StrandPalette.chargeColor, frac: 0.5)
        case .vitality:
            cardLink(.metric("vitality"), title: card.title, sub: card.subtitle,
                     value: intText(visibleVitality), symbol: card.icon,
                     tint: liquidPurple, frac: frac(visibleVitality))
        case .hrv:
            cardLink(.metric("hrv"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.avgHrv, card.unit), symbol: card.icon,
                     tint: StrandPalette.metricCyan,
                     frac: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardLink(.metric("rhr"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                     symbol: card.icon, tint: StrandPalette.metricRose,
                     frac: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardLink(.metric("resp_rate"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                     symbol: card.icon, tint: StrandPalette.accent,
                     frac: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            // Route by the EXACT (key, source) the tile chose to display — WHOOP 5/MG motion estimate,
            // imported Apple Health count, or calibrated motion estimate - NOT by bare key (bare "steps"
            // resolves to apple-health and would mismatch a strap-derived value). Order-independent.
            cardLink(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), title: card.title, sub: stepsSourceCaption,
                     value: stepsText, symbol: card.icon,
                     tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            let value = liquidSpo2
            cardLink(.metricSourced(key: "spo2", source: "my-whoop"), title: card.title,
                     sub: value == nil ? card.subtitle : String(localized: "Latest available reading"),
                     value: value.map { String(format: "%.0f%%", $0) } ?? "–", symbol: card.icon,
                     tint: StrandPalette.metricCyan, frac: fracOver(value, 100))
        case .skinTemp:
            let value = liquidSkinTemperature
            cardLink(.metricSourced(key: "skin_temp", source: "my-whoop"), title: card.title,
                     sub: value == nil ? card.subtitle : String(localized: "Latest available reading"),
                     value: value.map(skinTemperatureText) ?? "–", symbol: card.icon,
                     tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            energyCardLink(card)
        case .sleep:
            cardLink(.sleep, title: card.title, sub: card.subtitle,
                     value: sleepText, symbol: card.icon,
                     tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardLink(.hydration, title: card.title, sub: card.subtitle,
                     value: hydrationGoalML.map {
                         HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                     } ?? "-",
                     symbol: card.icon, tint: StrandPalette.metricCyan,
                     frac: hydrationGoalML.map {
                         HydrationGoal.fraction(totalML: hydrationTotalML ?? 0, goalML: $0)
                     })
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(.coupled, title: card.title, sub: card.subtitle,
                     value: "", symbol: card.icon, tint: StrandPalette.chargeColor, frac: 0.6)
        }
    }

    /// One card row pushing its `TabRoute` by value — the first hop off the Today root must ride
    /// the tab's `NavigationPath` so a re-tap of the Today tab can pop it (#198; see TabRoute.swift).
    private func cardLink(_ route: TabRoute, title: String, sub: String,
                          value: String, symbol: String, tint: Color, frac: Double?) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                MetricGlyph(symbol, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(0)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                FrostedCardSurface(
                    tint: tint,
                    cornerRadius: 20,
                    washStrength: 0.60
                )
            )
        }
        .buttonStyle(LiquidPressStyle())
    }

    /// Calories need more hierarchy than a one-number dashboard row. The large number is Total only
    /// when Apple supplied BOTH components; otherwise its label says Active, Resting, or Combined
    /// estimate. The two small KPIs never borrow a value from another source to fill a gap.
    private func energyCardLink(_ card: DashboardCard) -> some View {
        let breakdown = energyBreakdown
        let metric = caloriesDetailMetric
        return NavigationLink(value: TabRoute.metricSourced(
            key: metric?.key ?? "energy_kcal", source: metric?.source ?? "my-whoop")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MetricGlyph(card.icon, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(card.title.uppercased())
                                .font(StrandFont.overlineScaled(11)).tracking(0)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Image(systemName: "info.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.metricAmber)
                                .accessibilityHidden(true)
                        }
                        Text(energyStateText)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kcalText(breakdown.headlineKcal))
                            .font(StrandFont.number(24))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Text(energyHeadlineLabel.uppercased())
                            .font(StrandFont.overlineScaled(8.5)).tracking(0)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 4)
                    energyMiniValue("ACTIVE", breakdown.activeKcal)
                    energyMiniValue("RESTING", breakdown.restingKcal)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(FrostedCardSurface(tint: StrandPalette.metricAmber,
                                           cornerRadius: 20, washStrength: 0.60))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityHint("Opens the energy breakdown, trend and explanation")
    }

    private func energyMiniValue(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(kcalText(value, includesUnit: false))
                .font(StrandFont.captionNumber)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(label)
                .font(StrandFont.overlineScaled(7.5)).tracking(0)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(minWidth: 48, alignment: .trailing)
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    /// Liquid parity with classic `effortZeroNote`: the "no cardio load yet" line shown in the synthesis
    /// card when today's Effort is ~0, so a calm day explains itself instead of a bare 0. Reuses classic's
    /// String Catalog entry verbatim — one key serves both Today screens.
    private var effortZeroNote: String? {
        guard EffortDisplay.showsZeroNote(strain: displayDay?.strain, isToday: selectedDayOffset == 0) else { return nil }
        return String(localized: "No cardio load yet. Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.")
    }

    private var synthesisSection: some View {
        VStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: todayFocusSymbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(todayFocusTone)
                            .frame(width: 34, height: 34)
                            .background(todayFocusTone.opacity(0.14), in: Circle())
                            .overlay(Circle().strokeBorder(todayFocusTone.opacity(0.28), lineWidth: 0.8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text("TODAY'S FOCUS")
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .foregroundStyle(todayFocusTone)
                            Text(todayFocusHeadline)
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        Spacer(minLength: NoopMetrics.space2)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(synthesisExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }

                    // While the baseline calibrates, the honest "N of 4 nights" progress replaces the
                    // readiness one-liner here — the same swap classic makes (`calibrationDetail ??
                    // synthesisCardDetail`), so the count the short greeting pill can't carry lands in
                    // the card and both Today screens read identically.
                    Text(chargeDisplay.calibrationDetail ?? synthLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: NoopMetrics.space2) {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(todayFocusTone)
                                .accessibilityHidden(true)
                            Text(readinessConfidenceLabel.uppercased())
                                .font(StrandFont.overlineScaled(9))
                                .tracking(0)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if let recovery = chargeDisplay.pct {
                            Text("\(Int(recovery.rounded()))% RECOVERY")
                                .font(StrandFont.overlineScaled(9))
                                .tracking(0)
                                .foregroundStyle(recoveryHeroTone)
                        } else {
                            Text(chargeDisplay.stateLabel.uppercased())
                                .font(StrandFont.overlineScaled(9))
                                .tracking(0)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    // #530 follow-up: the classic hero's "no cardio load yet" note (effortZeroNote),
                    // shown on a calm day so today's ~0 Effort explains itself instead of a bare 0.
                    if let note = effortZeroNote {
                        HStack(alignment: .top, spacing: NoopMetrics.space2) {
                            Image(systemName: "info.circle")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.effortColor)
                                .accessibilityHidden(true)
                            Text(note)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if synthesisExpanded {
                        Divider().overlay(todayFocusTone.opacity(0.24))
                        Text(ReadinessPresentation.summary(for: readiness))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: NoopMetrics.space2) {
                            Text(readinessConfidenceLabel.uppercased())
                                .font(StrandFont.overlineScaled(8)).tracking(0)
                            Text(readinessAsOfLabel)
                                .font(StrandFont.caption)
                        }
                        .foregroundStyle(StrandPalette.textTertiary)
                        if let limitation = readiness.limitations.first,
                           chargeDisplay.calibrationDetail == nil {
                            Text(ReadinessPresentation.limitation(limitation, for: readiness))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    FrostedCardSurface(
                        tint: todayFocusTone,
                        cornerRadius: NoopMetrics.cardRadius,
                        washStrength: 0.72
                    )
                )
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(todayFocusTone)
                        .frame(width: 3)
                        .padding(.vertical, 18)
                        .padding(.leading, 2)
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint(synthesisExpanded ? "Collapse today's focus" : "Expand today's focus")

            // Current-state inference only. Historical browsing intentionally omits this card: the
            // This current signal snapshot is live/latest and must never be projected onto a past day.
            if selectedDayOffset == 0, chargeDisplay.calibrationDetail == nil {
                TodaySignalPatternsCard(readiness: readiness, restScore: restScore)
                    .id(Self.patternsAnchorID)
            }
        }
    }

    private var todayFocusTone: Color {
        switch readiness.level {
        case .primed, .balanced: return StrandPalette.statusPositive
        case .strained: return StrandPalette.statusWarning
        case .rundown: return StrandPalette.recovery000
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    private var todayFocusHeadline: String {
        readinessWord ?? String(localized: "Learning your baseline")
    }

    private var todayFocusSymbol: String {
        switch readiness.level {
        case .primed: return "bolt.fill"
        case .balanced: return "checkmark"
        case .strained: return "exclamationmark"
        case .rundown: return "exclamationmark.triangle.fill"
        case .insufficient: return "waveform.path.ecg"
        }
    }

    // MARK: - WHY / TARGET / WATCH

    /// Only physiology signals that actually participate in Readiness belong under WHY. Recent-load
    /// context remains visible in the detailed Readiness card but must not look like a readiness vote.
    private var dailyPlanWhySignals: [ReadinessEngine.Signal] {
        readiness.signals.filter { ["hrv", "rhr", "respRate"].contains($0.key) }
    }

    private var dailyPlanWatchSignals: [ReadinessEngine.Signal] {
        readiness.signals.filter { $0.flag == .watch || $0.flag == .bad }
    }

    private var whySection: some View {
        let signals = dailyPlanWhySignals
        return VStack(spacing: 8) {
            sectionHead("daily_plan.why.title", trailing: ReadinessPresentation.headline(for: readiness))
            card {
                if signals.isEmpty {
                    dailyPlanEmptyRow(
                        symbol: "waveform.path.ecg",
                        text: String(localized: "daily_plan.why.unavailable")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            MetricGlyph(todayFocusSymbol, size: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ReadinessPresentation.headline(for: readiness))
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(ReadinessPresentation.summary(for: readiness))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let limitation = readiness.limitations.first {
                                    Text(ReadinessPresentation.limitation(limitation, for: readiness))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 11)
                        .accessibilityElement(children: .combine)

                        ForEach(Array(signals.enumerated()), id: \.offset) { index, signal in
                            dailyPlanDivider
                            dailyPlanSignalRow(signal)
                        }
                    }
                }
            }
        }
    }

    private var targetSection: some View {
        let plan = dailyActionPlan
        return VStack(spacing: 8) {
            sectionHead("daily_plan.target.title", trailing: dailyPlanTargetStatusKey(plan))
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("daily_plan.check_in.question")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)

                    VStack(spacing: 8) {
                        dailyPlanCheckInButton(.asUsual, label: "daily_plan.check_in.as_usual")
                        dailyPlanCheckInButton(.belowUsual, label: "daily_plan.check_in.below_usual")
                        dailyPlanCheckInButton(.painOrUnwell, label: "daily_plan.check_in.pain_unwell")
                    }

                    dailyPlanDivider
                    dailyPlanResult(plan)

                    Button {
                        withAnimation(StrandMotion.interactive) {
                            dailyPlanExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(dailyPlanExpanded
                                 ? "daily_plan.details.hide"
                                 : "daily_plan.details.show")
                                .font(StrandFont.caption)
                            Spacer()
                            Image(systemName: dailyPlanExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("daily_plan.details.hint"))

                    if dailyPlanExpanded {
                        dailyPlanEvidence(plan)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dailyPlanResult(_ plan: DailyActionPlanner.Plan) -> some View {
        switch plan.availability {
        case .checkInNeeded:
            dailyPlanStateRow(
                symbol: "checkmark.circle",
                title: "daily_plan.state.check_in.title",
                body: "daily_plan.state.check_in.body",
                tint: StrandPalette.textTertiary
            )
        case .calibrating:
            dailyPlanStateRow(
                symbol: "chart.line.uptrend.xyaxis",
                title: "daily_plan.state.calibrating.title",
                body: "daily_plan.state.calibrating.body",
                tint: StrandPalette.statusWarning,
                action: dailyPlanActionLabel(plan.action)
            )
        case .recoveryShift:
            dailyPlanStateRow(
                symbol: "figure.walk",
                title: "daily_plan.state.recovery_shift.title",
                body: "daily_plan.state.recovery_shift.body",
                tint: StrandPalette.statusWarning,
                action: dailyPlanActionLabel(plan.action)
            )
        case .stop:
            dailyPlanStateRow(
                symbol: "pause.circle.fill",
                title: "daily_plan.state.stop.title",
                body: "daily_plan.state.stop.body",
                tint: StrandPalette.statusCritical,
                action: dailyPlanActionLabel(plan.action)
            )
        case .ready:
            // S1 PARITY: Kotlin renders the CALIBRATING state row when a READY plan carries no target
            // (TodayScreen.kt, Availability.READY -> target == null). Swift used to fall through and show
            // a bare action line with no range and no explanation, so the two platforms disagreed on the
            // same input. Both planners currently gate `target` before emitting .ready, so this is a dead
            // path today - but an un-mirrored fallback is exactly how a future planner change becomes a
            // silent cross-platform divergence, which the parity constraint forbids.
            if plan.target == nil {
                dailyPlanStateRow(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "daily_plan.state.calibrating.title",
                    body: "daily_plan.state.calibrating.body",
                    tint: StrandPalette.statusWarning
                )
            } else {
            VStack(alignment: .leading, spacing: 12) {
                if let target = plan.target {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(
                            String(
                                format: String(localized: "appwide.range.format"),
                                target.lower,
                                target.upper
                            )
                        )
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                        Text(String(localized: "daily_plan.effort.scale"))
                            .font(StrandFont.overline)
                            .tracking(0)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text("daily_plan.state.ready.body")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let guidance = DailyEffortGuidance.evaluate(
                        currentEffort: cachedDisplayDay?.strain,
                        range: target
                    )
                    if guidance.state != .unavailable {
                        dailyPlanEffortProgress(guidance)
                    }
                }
                Label(dailyPlanActionLabel(plan.action),
                      systemImage: plan.action == .protectExtraSleep ? "moon.zzz.fill" : "bed.double.fill")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)

                if selectedDayOffset == 0 {
                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: strainTargetToggle(plan: plan)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("daily_plan.notification.toggle", systemImage: "bell")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("daily_plan.notification.help")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.noopSwitch)
                }
            }
            }
        }
    }

    private func strainTargetToggle(plan: DailyActionPlanner.Plan) -> Binding<Bool> {
        Binding(
            get: { behavior.strainTargetNudge },
            set: { enabled in
                guard enabled else {
                    behavior.strainTargetNudge = false
                    StrainTargetNotifier.setEnabled(false)
                    return
                }

                behavior.strainTargetNudge = false
                StrainTargetNotifier.setEnabled(true) { outcome in
                    switch outcome {
                    case .enabled:
                        behavior.strainTargetNudge = true
                        StrainTargetNotifier.onDayUpdate(
                            day: selectedDayKey,
                            dayEffort: cachedDisplayDay?.strain,
                            targetRange: plan.target,
                            enabled: true
                        )
                    case .denied:
                        behavior.strainTargetNudge = false
                        showNotificationPermissionAlert = true
                    case .off:
                        behavior.strainTargetNudge = false
                    }
                }
            }
        )
    }

    private func openNotificationSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        #else
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        #endif
        openURL(url)
    }

    private func dailyPlanEffortProgress(
        _ guidance: DailyEffortGuidance.Result
    ) -> some View {
        let current = Int((guidance.current ?? 0).rounded())
        let range = guidance.range ?? .init(lower: 0, upper: 0)
        let tint: Color = {
            switch guidance.state {
            case .inRange: return StrandPalette.statusPositive
            case .aboveRange: return StrandPalette.statusWarning
            case .belowRange: return StrandPalette.accent
            case .unavailable: return StrandPalette.textTertiary
            }
        }()
        let status: String = {
            switch guidance.state {
            case .belowRange:
                return String(
                    format: String(localized: "daily_plan.progress.below"),
                    Int(ceil(guidance.remainingToLower ?? 0))
                )
            case .inRange:
                return String(localized: "daily_plan.progress.in_range")
            case .aboveRange:
                return String(localized: "daily_plan.progress.above")
            case .unavailable:
                return ""
            }
        }()

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("daily_plan.progress.current")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text("\(current)")
                    .font(StrandFont.number(18))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let lowerX = width * CGFloat(range.lower) / 100
                let upperX = width * CGFloat(range.upper) / 100
                let markerSize: CGFloat = 12
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StrandPalette.textTertiary.opacity(0.18))
                    Capsule()
                        .fill(StrandPalette.accent.opacity(0.16))
                        .frame(width: max(4, upperX - lowerX))
                        .offset(x: lowerX)
                    Capsule()
                        .fill(tint.opacity(0.42))
                        .frame(width: max(2, width * CGFloat(guidance.progress)))
                    Circle()
                        .fill(tint)
                        .frame(width: markerSize, height: markerSize)
                        .overlay(Circle().stroke(StrandPalette.surfaceBase, lineWidth: 2))
                        .offset(
                            x: min(
                                max(0, width * CGFloat(guidance.progress) - markerSize / 2),
                                max(0, width - markerSize)
                            )
                        )
                }
            }
            .frame(height: 12)
            Text(status)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: String(localized: "daily_plan.progress.accessibility"),
                current,
                range.lower,
                range.upper
            )
        )
        .accessibilityValue(status)
    }

    private func dailyPlanCheckInButton(
        _ value: DailyActionPlanner.CheckIn,
        label: LocalizedStringKey
    ) -> some View {
        let selected = currentDailyActionCheckIn == value
        return Button {
            setDailyActionCheckIn(value)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textTertiary)
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? StrandPalette.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? StrandPalette.accent.opacity(0.45) : StrandPalette.hairline,
                            lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dailyPlanStateRow(
        symbol: String,
        title: LocalizedStringKey,
        body: LocalizedStringKey,
        tint: Color,
        action: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(body)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action {
                Label(action, systemImage: "checkmark.circle")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dailyPlanEvidence(_ plan: DailyActionPlanner.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("daily_plan.evidence.title")
                .font(StrandFont.overline)
                .tracking(0)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(Array(plan.evidence.enumerated()), id: \.offset) { _, evidence in
                Label(dailyPlanEvidenceLabel(evidence.source), systemImage: "checkmark.circle")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("daily_plan.limitation")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var watchSection: some View {
        let evaluated = readiness.signals
        let watch = dailyPlanWatchSignals
        return VStack(spacing: 8) {
            sectionHead(
                "daily_plan.watch.title",
                trailing: evaluated.isEmpty
                    ? "daily_plan.confidence.calibrating"
                    : (watch.isEmpty ? "daily_plan.watch.clear" : "daily_plan.watch.attention")
            )
            card {
                if evaluated.isEmpty {
                    dailyPlanEmptyRow(
                        symbol: "waveform.path.ecg",
                        text: String(localized: "daily_plan.watch.unavailable")
                    )
                } else if watch.isEmpty {
                    dailyPlanEmptyRow(
                        symbol: "checkmark.seal.fill",
                        text: String(localized: "daily_plan.watch.none")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(watch.enumerated()), id: \.offset) { index, signal in
                            if index > 0 { dailyPlanDivider }
                            dailyPlanSignalRow(signal)
                        }
                    }
                }
            }
        }
    }

    private var dailyPlanDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 0.5)
    }

    private func dailyPlanEmptyRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            MetricGlyph(symbol, size: 26)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func dailyPlanSignalRow(_ signal: ReadinessEngine.Signal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MetricGlyph(dailyPlanSignalSymbol(signal.key), size: 28)
            VStack(alignment: .leading, spacing: 3) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline) {
                        Text(dailyPlanSignalLabel(signal))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 8)
                        Text(dailyPlanSignalStatus(signal.flag))
                            .font(StrandFont.overlineScaled(8))
                            .foregroundStyle(dailyPlanSignalTint(signal.flag))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dailyPlanSignalLabel(signal))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(dailyPlanSignalStatus(signal.flag))
                            .font(StrandFont.overlineScaled(8))
                            .foregroundStyle(dailyPlanSignalTint(signal.flag))
                    }
                }
                Text(signal.detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = signal.evidence {
                    Text(evidence)
                        .font(StrandFont.caption.monospacedDigit())
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func dailyPlanSignalSymbol(_ key: String) -> String {
        switch key {
        case "hrv": return "waveform.path.ecg"
        case "rhr": return "heart.text.square.fill"
        case "respRate": return "lungs.fill"
        case "effortVariety": return "chart.bar.xaxis"
        default: return "chart.line.uptrend.xyaxis"
        }
    }

    private func dailyPlanSignalLabel(_ signal: ReadinessEngine.Signal) -> String {
        switch signal.key {
        case "hrv": return String(localized: "daily_plan.signal.hrv")
        case "rhr": return String(localized: "daily_plan.signal.rhr")
        case "respRate": return String(localized: "daily_plan.signal.respiration")
        case "effortVariety": return String(localized: "daily_plan.signal.variety")
        default: return signal.label
        }
    }

    private func dailyPlanSignalStatus(_ flag: ReadinessEngine.Flag) -> String {
        switch flag {
        case .good: return String(localized: "daily_plan.signal.good")
        case .neutral: return String(localized: "daily_plan.signal.neutral")
        case .watch: return String(localized: "daily_plan.signal.watch")
        case .bad: return String(localized: "daily_plan.signal.shifted")
        }
    }

    private func dailyPlanSignalTint(_ flag: ReadinessEngine.Flag) -> Color {
        switch flag {
        case .good: return StrandPalette.statusPositive
        case .neutral: return StrandPalette.textTertiary
        case .watch: return StrandPalette.statusWarning
        case .bad: return StrandPalette.statusCritical
        }
    }

    private func dailyPlanConfidenceKey(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .calibrating: return "daily_plan.confidence.calibrating"
        case .building: return "daily_plan.confidence.building"
        case .solid: return "daily_plan.confidence.solid"
        }
    }

    private func dailyPlanTargetStatusKey(_ plan: DailyActionPlanner.Plan) -> String {
        switch plan.availability {
        case .ready, .calibrating:
            return dailyPlanConfidenceKey(plan.confidence)
        case .checkInNeeded, .recoveryShift, .stop:
            return "daily_plan.target.withheld"
        }
    }

    private func dailyPlanActionLabel(_ action: DailyActionPlanner.Action) -> String {
        switch action {
        case .completeCheckIn: return String(localized: "daily_plan.action.complete_check_in")
        case .keepSleepWindow: return String(localized: "daily_plan.action.keep_sleep_window")
        case .protectExtraSleep: return String(localized: "daily_plan.action.protect_extra_sleep")
        case .chooseEasyDay: return String(localized: "daily_plan.action.choose_easy_day")
        case .stopAndAssess: return String(localized: "daily_plan.action.stop_and_assess")
        }
    }

    private func dailyPlanEvidenceLabel(_ source: DailyActionPlanner.EvidenceSource) -> String {
        switch source {
        case .selfCheck: return String(localized: "daily_plan.evidence.self_check")
        case .readinessBaseline: return String(localized: "daily_plan.evidence.readiness")
        case .personalEffortHistory: return String(localized: "daily_plan.evidence.effort_history")
        case .sleepPlan: return String(localized: "daily_plan.evidence.sleep_plan")
        }
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(0)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow(String(localized: "Heart-rate variability"), unitText(hrv, "ms"),
                         symbol: "waveform.path.ecg")
                vitalRow(String(localized: "Resting heart rate"), unitText(rhr, "bpm"),
                         symbol: "heart.text.square.fill")
                vitalRow(String(localized: "Breaths per minute"), unitText(resp, "rpm", decimals: 1),
                         symbol: "lungs.fill")
            }
        }
    }

    private func vitalRow(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            MetricGlyph(symbol, size: 28)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Key metrics grid

    private var keyMetricsSection: some View {
        // HRV / Resting HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Recovery/Strain/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHead("KEY METRICS", trailing: selectedDayOffset == 0
                    ? String(localized: "Today's snapshot")
                    : selectedLogicalDay.formatted(date: .abbreviated, time: .omitted))
                // The editor chooses metrics/order; full trend exploration stays in detail/Trends.
                Button { showKeyMetricsEditor = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Key Metrics")
            }
            // Pinned metrics lead in the user's order, followed by every remaining catalog metric.
            // Two columns keep values and long labels readable; three made the grid feel like a table.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space3), count: 2),
                spacing: NoopMetrics.space3
            ) {
                ForEach(visibleKeyMetrics) { metric in
                    ktileFor(metric, hrv: hrv, rhr: rhr)
                        .accessibilityIdentifier("noop.today.key-metric.\(metric.rawValue)")
                }
            }
            NavigationLink(value: TabRoute.metricExplorer) {
                Label("Open all metric history", systemImage: "clock.arrow.circlepath")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    /// One editor-selected Key-Metric tile: the metric's value/tint/fill exactly as the old hard-coded
    /// tiles read them (Android's descriptor map is the twin), plus the metric-catalog `key` that names
    /// its tap-through detail. Sparse weight uses the freshest real Apple Health reading at or before
    /// the selected day, while every daily signal remains selected-day scoped.
    @ViewBuilder
    private func ktileFor(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge the hero draws, not `displayDay?.recovery` raw — the tile and the
            // hero are the same number, so a carry that reached only one of them would put two answers for
            // Charge on one screen. (#543: one prior row feeds every recovery-derived read-out.) Strain below
            // stays raw, matching the Effort hero, which correctly does not carry.
            ktile(String(localized: "Recovery"), intText(chargeDisplay.pct), "%", recoveryHeroTone,
                  frac(chargeDisplay.pct), symbol: metric.icon, key: "recovery")
        case .effort:
            let display = effortScale == .whoop
                ? effortText(displayDay?.strain)
                : intText(displayDay?.strain)
            ktile(String(localized: "Effort"), display,
                  "/ \(UnitFormatter.effortScaleMax(effortScale))", StrandPalette.effortColor,
                  frac(displayDay?.strain), symbol: metric.icon, key: "strain")
        case .rest:
            ktile(String(localized: "Sleep"), intText(restScore), "%", StrandPalette.restColor,
                  frac(restScore), trend: keyMetricTrends[.rest],
                  symbol: metric.icon, key: "sleep_performance")
        case .hrv:
            ktile("HRV", intText(hrv), "ms", StrandPalette.metricCyan, nil,
                  trend: keyMetricTrends[.hrv], symbol: metric.icon, key: "hrv")
        case .restingHr:
            ktile(String(localized: "Resting HR"), intText(rhr), "bpm", StrandPalette.metricRose, nil,
                  trend: keyMetricTrends[.restingHr], symbol: metric.icon, key: "rhr")
        case .bloodOxygen:
            let spo2 = liquidSpo2
            ktile(String(localized: "Blood Oxygen"), intText(spo2), "%", StrandPalette.metricCyan, nil,
                  trend: keyMetricTrends[.bloodOxygen], symbol: metric.icon, key: "spo2")
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
            ktile(String(localized: "Respiratory"), resp.map { String(format: "%.1f", $0) } ?? "-",
                  "rpm", StrandPalette.effortColor, nil, trend: keyMetricTrends[.respiratory],
                  symbol: metric.icon, key: "resp_rate")
        case .steps:
            ktile(String(localized: "Steps"), stepsText, "", StrandPalette.chargeColor,
                  nil, trend: keyMetricTrends[.steps], symbol: metric.icon, key: stepsDetailKey,
                  detailMetric: stepsDetailMetric)
        case .weight:
            ktile(String(localized: "Weight"), importedWeightKg.map(weightText) ?? "-", "",
                  StrandPalette.metricAmber, nil, trend: keyMetricTrends[.weight],
                  symbol: metric.icon, key: "weight")
        case .calories:
            energyKTile(symbol: metric.icon)
        }
    }

    /// A dense KPI treatment for energy: one large, correctly-labelled headline plus the two smaller
    /// components. Missing values remain dashes, and a strap-only combined estimate keeps both component
    /// slots empty instead of fabricating a split. Its tap opens the matching source-specific dossier.
    private func energyKTile(symbol: String) -> some View {
        let breakdown = energyBreakdown
        let metric = caloriesDetailMetric
        let tile = VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                MetricGlyph(symbol, size: 28)
                Text(String(localized: "Calories").uppercased())
                    .font(StrandFont.overlineScaled(9.5)).tracking(0)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricAmber)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(kcalText(breakdown.headlineKcal, includesUnit: false))
                    .font(StrandFont.number(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text("kcal").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(energyHeadlineLabel.uppercased())
                .font(StrandFont.overlineScaled(7.5)).tracking(0)
                .foregroundStyle(StrandPalette.textTertiary)

            HStack(spacing: 8) {
                energyKpiMini(String(localized: "Active"), breakdown.activeKcal)
                Divider().overlay(StrandPalette.hairline).frame(height: 25)
                energyKpiMini(String(localized: "Resting"), breakdown.restingKcal)
            }

        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FrostedCardSurface(tint: StrandPalette.metricAmber,
                                       cornerRadius: 20, washStrength: 0.76))

        return Group {
            if let metric {
                NavigationLink(value: TabRoute.metricSourced(key: metric.key, source: metric.source)) {
                    tile
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens active, resting and total energy details")
            } else {
                tile
            }
        }
    }

    private func energyKpiMini(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(StrandFont.overlineScaled(7)).tracking(0)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(kcalText(value, includesUnit: false))
                .font(StrandFont.captionNumber)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ktile(_ label: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?,
                       trend: [Double]? = nil,
                       symbol: String, key: String? = nil,
                       detailMetric: MetricDescriptor? = nil) -> some View {
        let showsTrend = (trend?.count ?? 0) > 1
        let tile = VStack(
            alignment: .leading,
            spacing: showsTrend ? NoopMetrics.space1 : NoopMetrics.space2
        ) {
            keyMetricTileHeader(label, symbol: symbol, trend: trend)
            (Text(value).font(StrandFont.number(24))
                + Text(unit.isEmpty ? "" : " \(unit)").font(StrandFont.subhead))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if showsTrend, let trend {
                Sparkline(
                    values: trend,
                    gradient: Gradient(colors: [tint.opacity(0.42), tint]),
                    lineWidth: 1.8,
                    showsArea: false,
                    showsHead: true,
                    showsHover: false,
                    valueFormat: { value in
                        let formatted = Sparkline.defaultValueString(value)
                        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
                    }
                )
                .frame(height: 26)
            } else if let frac {
                // Only real bounded scores earn a progress rail. Raw vital signs use their value and
                // optional trend below; normalizing RHR/HRV/respiration to arbitrary maxima makes a
                // fuller bar look "better" when it is not a health-goal scale.
                LiquidTube(frac: frac, tint: tint, height: 7, animated: false)
                    .frame(height: 26)
                    .accessibilityHidden(true)
            } else {
                // Preserve the two-column baseline without drawing a fake zero/progress sliver or
                // connecting a single reading into a synthetic trend.
                Color.clear.frame(height: 26).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, showsTrend ? NoopMetrics.space2 : NoopMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            FrostedCardSurface(
                tint: tint,
                cornerRadius: 20,
                washStrength: 0.76
            )
        )
        // #430 parity: tap -> the metric's trend detail (the same Explore dossier its MetricRow pushes).
        // This is a ROOT Today link, so it must push a TabRoute VALUE into the tab NavigationPath; a
        // closure destination bypasses that path and prevents re-tapping Today from popping to root.
        return Group {
            if let metric = detailMetric ?? key.flatMap({ key in
                MetricCatalog.all.first(where: { $0.key == key })
            }) {
                NavigationLink(value: TabRoute.metricSourced(key: metric.key, source: metric.source)) {
                    tile
                }
                    .buttonStyle(.plain)
            } else {
                tile
            }
        }
    }

    @ViewBuilder
    private func keyMetricTileHeader(_ label: String, symbol: String, trend: [Double]?) -> some View {
        if let trend, trend.count > 1 {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    MetricGlyph(symbol, size: 28)
                    Spacer(minLength: 0)
                    trendDirectionBadge(trend)
                }
                Text(label.uppercased())
                    .font(StrandFont.overlineScaled(9.5))
                    .tracking(0)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                MetricGlyph(symbol, size: 28)
                Text(label.uppercased())
                    .font(StrandFont.overlineScaled(9.5))
                    .tracking(0)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
        }
    }

    enum KeyMetricTrendDirection: Equatable {
        case up
        case down
        case steady

        var symbol: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .steady: return "arrow.right"
            }
        }

        var spokenValue: String {
            switch self {
            case .up: return String(localized: "appwide.trend.direction.up")
            case .down: return String(localized: "appwide.trend.direction.down")
            case .steady: return String(localized: "steady")
            }
        }
    }

    /// Describes endpoint direction only, never clinical meaning. A neutral tolerance prevents tiny
    /// floating-point changes from producing a directional claim while still preserving real subtle
    /// shifts such as weight or respiratory-rate movement.
    static func keyMetricTrendDirection(_ values: [Double]) -> KeyMetricTrendDirection? {
        let finite = values.filter(\.isFinite)
        guard finite.count > 1, let first = finite.first, let last = finite.last else { return nil }
        let delta = last - first
        let scale = max(max(abs(first), abs(last)), 1)
        let tolerance = max(0.01, scale * 0.001)
        if abs(delta) <= tolerance { return .steady }
        return delta > 0 ? .up : .down
    }

    @ViewBuilder
    private func trendDirectionBadge(_ values: [Double]) -> some View {
        if let direction = Self.keyMetricTrendDirection(values) {
            HStack(spacing: 3) {
                Text("14D")
                Image(systemName: direction.symbol)
                    .font(.system(size: 8, weight: .bold))
            }
            .font(StrandFont.overlineScaled(7.5))
            .tracking(0)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 5)
            .frame(height: 20)
            .background(Capsule().fill(StrandPalette.surfaceInset.opacity(0.78)))
            .overlay(Capsule().strokeBorder(StrandPalette.hairline.opacity(0.9), lineWidth: 0.6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("14-day direction")
            .accessibilityValue(direction.spokenValue)
        }
    }

    /// Builds every compact tile trace in one pass over data already loaded for Today. Values remain
    /// sparse rather than interpolated: a missing night contributes no point, and the view requires two
    /// genuine observations before drawing a line. The inclusive window is 14 calendar days ending on
    /// the selected day, so historical navigation cannot reveal later readings.
    static func keyMetricTrendSeries(
        days: [DailyMetric],
        restSeries: [(day: String, value: Double)],
        stepEstimates: [(day: String, value: Double)],
        appleRows: [AppleDaily],
        endingAt endDay: String,
        resolvedSpo2: [(day: String, value: Double)] = [],
        windowDays: Int = 14
    ) -> [KeyMetric: [Double]] {
        guard let endDate = dayKeyParser.date(from: endDay),
              let startDate = Calendar.current.date(
                byAdding: .day,
                value: -(max(1, windowDays) - 1),
                to: endDate
              ) else {
            return [:]
        }
        let startDay = dayKeyParser.string(from: startDate)
        var byMetric: [KeyMetric: [String: Double]] = [:]

        func record(_ metric: KeyMetric, day: String, value: Double?) {
            guard day >= startDay, day <= endDay, let value, value.isFinite else { return }
            guard metric != .bloodOxygen || (value > 0 && value <= 100) else { return }
            byMetric[metric, default: [:]][day] = value
        }

        for point in restSeries {
            record(.rest, day: point.day, value: point.value)
        }

        // Calibrated motion is the lowest-priority steps source.
        for point in stepEstimates {
            record(.steps, day: point.day, value: point.value)
        }

        // The merged daily cache owns physiological history. A direct band step count replaces the
        // calibrated estimate for that day, matching `MetricCatalog.todayStepsValue`.
        for day in days {
            record(.hrv, day: day.day, value: day.avgHrv)
            record(.restingHr, day: day.day, value: day.restingHr.map(Double.init))
            record(.bloodOxygen, day: day.day, value: day.spo2Pct)
            record(.respiratory, day: day.day, value: day.respRateBpm)
            record(.steps, day: day.day, value: day.steps.map(Double.init))
        }

        // The resolver contributes only calibrated daily percentages from compatible sources. It can
        // replace a sparse cache entry, but raw band red/IR samples never enter this series.
        for point in resolvedSpo2 {
            record(.bloodOxygen, day: point.day, value: point.value)
        }

        // Apple Health is measured and therefore wins the per-day steps slot. Weight is naturally
        // sparse; it only draws once two actual weigh-ins fall inside the selected window.
        for day in appleRows {
            record(.steps, day: day.day, value: day.steps.map(Double.init))
            record(.weight, day: day.day, value: day.weightKg)
        }

        return byMetric.reduce(into: [:]) { result, entry in
            let values = entry.value
                .sorted { $0.key < $1.key }
                .map(\.value)
            if !values.isEmpty {
                result[entry.key] = values
            }
        }
    }

    // MARK: - Selected-day workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: 8) {
            sectionHead(selectedDayOffset == 0 ? "TODAY'S WORKOUTS" : "WORKOUTS",
                        trailing: selectedDayOffset == 0
                            ? sessionCountLabel(workouts.count)
                            : selectedLogicalDay.formatted(date: .abbreviated, time: .omitted))
            if !workouts.isEmpty {
                // #5 (perf): identify rows by a STABLE natural key, not the array index. With `id: \.offset`
                // every refresh that re-orders or inserts a session re-identified every row below it, so
                // SwiftUI tore down and rebuilt those cards (visible churn on pull-to-refresh). startTs +
                // source + sport is unique per session in practice (one device cannot start two sessions of
                // the same sport in the same second) and is stable across refetches.
                ForEach(workouts, id: \.workoutRowIdentity) { workout in
                    NavigationLink(value: TabRoute.workouts) { workoutCard(workout) }
                        .buttonStyle(LiquidPressStyle())
                }
            } else {
                NavigationLink(value: TabRoute.workouts) {
                    card {
                        HStack(spacing: NoopMetrics.space3) {
                            MetricGlyph("figure.run", size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selectedDayOffset == 0
                                     ? String(localized: "No workout today")
                                     : String(localized: "No workout logged that day"))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(selectedDayOffset == 0
                                     ? String(localized: "A tracked or imported session will appear here automatically.")
                                     : String(localized: "Choose another day or open Workouts to browse your log."))
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .buttonStyle(LiquidPressStyle())
            }
        }
    }

    private func sessionCountLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 session") : String(localized: "\(count) sessions")
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(workoutSub(w)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    (Text(effortText(w.strain)).font(StrandFont.number(15))
                        + Text(" EFFORT").font(StrandFont.overlineScaled(9)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 12, animated: false)
            }
        }
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: 8) {
            sectionHead("DATA SOURCES", trailing: "Provenance")
            NavigationLink(value: TabRoute.dataSources) {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                        LiquidSyncStatusRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: String, trailing: String) -> some View {
        // ObsidianFlow is adaptive — pearl in Light mode and obsidian in Dark mode — so section ink
        // must resolve with the appearance instead of assuming that an enabled scene is always dark.
        let color = StrandPalette.textSecondary
        return HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(StrandFont.overline)
                .tracking(0)
                .foregroundStyle(color)
            Spacer()
            Text(LocalizedStringKey(trailing))
                .font(StrandFont.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius)
            )
    }

    // MARK: - Data

    private static let queryCacheMaxAge: TimeInterval = 120

    static func shouldRestoreQueryCache(
        cachedKey: LiquidTodayQueryKey,
        requestKey: LiquidTodayQueryKey,
        bankedAt: Date,
        now: Date,
        isToday: Bool
    ) -> Bool {
        guard cachedKey == requestKey else { return false }
        guard isToday else { return true }
        return max(0, now.timeIntervalSince(bankedAt)) < queryCacheMaxAge
    }

    static func shouldDeferQueryLoad(isBackfilling: Bool) -> Bool { isBackfilling }

    static func canRestoreDuringHistoryWrite(
        cachedKey: LiquidTodayQueryKey,
        requestKey: LiquidTodayQueryKey
    ) -> Bool {
        cachedKey.deviceId == requestKey.deviceId
            && cachedKey.dayKey == requestKey.dayKey
            && cachedKey.profileState == requestKey.profileState
    }

    private func applyQueryCache(_ cache: LiquidTodayLoadCache) {
        restScore = cache.restScore
        heroProvenanceByMetric = cache.heroProvenanceByMetric
        stress = cache.stress
        fitnessAge = cache.fitnessAge
        vitality = cache.vitality
        ageMetricsLoadedProfileState = cache.key.profileState
        stepsEst = cache.stepsEst
        importedStepsDay = cache.importedStepsDay
        importedActiveKcalDay = cache.importedActiveKcalDay
        importedRestingKcalDay = cache.importedRestingKcalDay
        importedWeightKg = cache.importedWeightKg
        hrValues = cache.hrValues
        workouts = cache.workouts
        keyMetricTrends = cache.keyMetricTrends
        resolvedSpo2ByDay = cache.resolvedSpo2ByDay
    }

    private func markQueryDataLoaded() {
        guard !dataLoaded else { return }
        withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true }
    }

    private func load() async {
        let requestedOffset = selectedDayOffset
        let requestedDayKey = selectedDayKey
        let requestedLogicalDay = selectedLogicalDay
        let requestedAgeMetricState = profile.ageMetricStateToken
        let requestKey = LiquidTodayQueryKey(
            refreshSeq: repo.refreshSeq,
            ageMetricsSeq: repo.ageMetricsSeq,
            workoutsSeq: repo.workoutsSeq,
            deviceId: repo.deviceId,
            dayKey: requestedDayKey,
            profileState: requestedAgeMetricState
        )
        let isToday = requestedOffset == 0
        let trace = AppDiagnosticsRecorder.shared.beginOperation(
            "today.liquid.load",
            fields: ["scope": isToday ? "today" : "historical"]
        )
        var diagnosticOutcome = "cancelled"
        var diagnosticFields: [String: String] = [:]
        defer {
            AppDiagnosticsRecorder.shared.endOperation(
                trace,
                outcome: diagnosticOutcome,
                fields: diagnosticFields,
                includeResourceSnapshot: diagnosticOutcome == "full"
            )
        }

        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        guard !Task.isCancelled,
              requestKey == LiquidTodayQueryKey(
                refreshSeq: repo.refreshSeq,
                ageMetricsSeq: repo.ageMetricsSeq,
                workoutsSeq: repo.workoutsSeq,
                deviceId: repo.deviceId,
                dayKey: selectedDayKey,
                profileState: profile.ageMetricStateToken
              ) else { return }

        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        updateAdaptiveHydrationContext()
        // Always anchor to the day the UI is actually showing. Passing `day?.day` turned a missing
        // current row into nil, which asks ReadinessEngine to fall back to the newest stored row — so a
        // stale import could masquerade as today's pattern. An explicit absent key correctly yields
        // `.insufficient`.
        let readinessResult = ReadinessEngine.evaluate(days: repo.days, today: requestedDayKey)
        cachedReadiness = readinessResult
        readinessAsOfDay = readinessResult.asOfDay
        let dailyPlan = makeDailyActionPlan(readiness: readinessResult)
        cachedDailyActionPlan = dailyPlan
        #if DEBUG
        if CommandLine.arguments.contains("--demo-daily-plan") {
            NSLog(
                "Daily Plan QA availability=\(dailyPlan.availability.rawValue) " +
                "checkIn=\(currentDailyActionCheckIn.rawValue) " +
                "target=\(dailyPlan.target.map { "\($0.lower)-\($0.upper)" } ?? "none")"
            )
        }
        #endif
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? requestedDayKey
        cachedVitalsDay = isToday ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        cachedSpo2Day = isToday ? Repository.lastSpo2Day(days: repo.days, todayKey: tkey) : nil
        cachedSkinTempDay = isToday
            ? Repository.lastSkinTempDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let calNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               before: tkey,
                                               hasRecovery: day?.recovery != nil)
            : nil
        let resolvedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: tkey,
                                                         isToday: isToday,
                                                         todayScored: day?.recovery != nil,
                                                         isCalibrating: calNights != nil),
            calibrationNights: calNights,
            todayKey: tkey)
        cachedChargeDisplay = resolvedChargeDisplay
        if isToday,
           case .scored = resolvedChargeDisplay,
           chargeLandingHapticDay != tkey {
            chargeLandingHapticDay = tkey
            chargeLandingHapticTrigger += 1
        }

        if Self.shouldDeferQueryLoad(isBackfilling: historyWriteQueryGate) {
            deferredQueryLoadForHistoryWrite = true
            if let cached = repo.liquidTodayLoadCache,
               Self.canRestoreDuringHistoryWrite(cachedKey: cached.key, requestKey: requestKey) {
                applyQueryCache(cached)
                loadedQueryDayKey = requestedDayKey
                markQueryDataLoaded()
                diagnosticOutcome = "backfill_cache_restore"
                diagnosticFields = [
                    "hr_bucket_count": String(cached.hrValues.count),
                    "workout_count": String(cached.workouts.count),
                    "trend_metric_count": String(cached.keyMetricTrends.count),
                ]
            } else {
                diagnosticOutcome = "backfill_deferred"
            }
            return
        }

        let forceAfterHistoryWrite = deferredQueryLoadForHistoryWrite
        deferredQueryLoadForHistoryWrite = false

        if !forceAfterHistoryWrite,
           let cached = repo.liquidTodayLoadCache,
           Self.shouldRestoreQueryCache(
                cachedKey: cached.key,
                requestKey: requestKey,
                bankedAt: cached.bankedAt,
                now: Date(),
                isToday: isToday
           ) {
            applyQueryCache(cached)
            loadedQueryDayKey = requestedDayKey
            markQueryDataLoaded()
            diagnosticOutcome = "cache_restore"
            diagnosticFields = [
                "hr_bucket_count": String(cached.hrValues.count),
                "workout_count": String(cached.workouts.count),
                "trend_metric_count": String(cached.keyMetricTrends.count),
            ]
            return
        }

        let cal = Calendar.current
        let selectedCalendarWindow = WorkoutDateWindow.localDay(dayKey: requestedDayKey, calendar: cal)
            ?? WorkoutDateWindow.localDay(containing: requestedLogicalDay, calendar: cal)
        let from = selectedCalendarWindow.lowerBound
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = isToday
            ? Int(Date().timeIntervalSince1970)
            : selectedCalendarWindow.upperBound

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let fitProfileA = repo.exploreSeries(
            key: AgeMetricProfile.fitnessAgeKey, source: "my-whoop")
        async let vitProfileA = repo.exploreSeries(
            key: AgeMetricProfile.vitalityKey, source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let spo2A = repo.resolvedSeries(
            key: "spo2",
            source: Repository.whoopSource,
            days: max(30, requestedOffset + 15))
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows(overlappingFrom: selectedCalendarWindow.lowerBound,
                                         to: selectedCalendarWindow.upperBound)
        // Ask the same cross-source resolver the Classic Today view uses which source actually won each
        // displayed score. Limit the read to the selected-day window instead of scanning full history.
        let sourceLookback = max(2, requestedOffset + 2)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      days: sourceLookback)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      days: sourceLookback)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    days: sourceLookback)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let spo2Resolution = await spo2A
        let validSpo2Points = spo2Resolution.values.filter {
            $0.value.isFinite && $0.value > 0 && $0.value <= 100
        }
        let resolvedSpo2Local = Dictionary(
            validSpo2Points,
            uniquingKeysWith: { _, last in last })
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        let restScoreLocal = TodayView.freshRestScore(
            todayValue: restByDay[requestedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: isToday,
            todayKey: requestedDayKey)
        // Mirror StressView's source-isolated read: select one complete source before building a personal
        // baseline. Never blend strap, WHOOP export, and Apple rows into a synthetic physiology history.
        // The Today card is stricter than the detail screen's honest historical carry: if the selected day
        // is not the read's real as-of day, keep Today empty instead of relabelling an older score as current.
        // `StressModel` is a linear, in-memory pass over already-loaded value rows; keeping it on the main
        // actor also respects SourcedDailyMetric's app isolation without crossing it through an unsafe task.
        let stressRows = repo.vitalMetricRows

        // Today consumes only the selected day's imported values for its headline numbers. The same
        // already-loaded rows also feed one compact 14-day trend cache below; no extra store query is made.
        let appleRows = await appleA
        let stressModel = StressModel(sourceRows: stressRows)
        let stressLocal = stressModel?.asOfDay == requestedDayKey ? stressModel?.score : nil
        let fitProfile = (await fitProfileA).last?.value
        let vitProfile = (await vitProfileA).last?.value
        let readFitnessAge = (await fitA).last?.value
        let readVitality = (await vitA).last?.value
        let fitnessAgeLocal = profile.acceptsFitnessAge(provenance: fitProfile)
            ? readFitnessAge : nil
        let vitalityLocal = profile.acceptsVitality(provenance: vitProfile) ? readVitality : nil
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap motion estimate showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Never let the history tail pose as today's count. An exact-day row may be absent while an
        // older estimate exists; Today must stay empty until this selected day actually has a point.
        let stepsEstLocal = stepsByDay[requestedDayKey]
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        let importedStepsLocal = appleRows.filter { $0.day == requestedDayKey }.compactMap { $0.steps }.max()
        // Weight is not expected every day. Use the freshest measured Apple Health value no later than
        // the day being viewed; never borrow from a future day when navigating backwards.
        let importedWeightLocal = appleRows.filter { $0.day <= requestedDayKey && $0.weightKg != nil }
            .max(by: { $0.day < $1.day })?.weightKg
        // Keep the Apple Health components together. The derived Total is resolved later only when both
        // exist; a partial row never borrows the strap's combined estimate to complete itself.
        let selectedAppleEnergy = appleRows.last(where: { $0.day == requestedDayKey })
        let importedActiveKcalLocal = selectedAppleEnergy?.activeKcal
        let importedRestingKcalLocal = selectedAppleEnergy?.basalKcal
        var trendDays = repo.days
        if let day, !trendDays.contains(where: { $0.day == day.day }) {
            trendDays.append(day)
        }
        let keyMetricTrendsLocal = Self.keyMetricTrendSeries(
            days: trendDays,
            restSeries: restSeries,
            stepEstimates: stepsSeries,
            appleRows: appleRows,
            endingAt: requestedDayKey,
            resolvedSpo2: validSpo2Points
        )
        let hrValuesLocal = (await hrA).map { $0.bpm }
        // A row that only OVERLAPS the selected day (for example a workout begun before midnight) must
        // be visibly attributed, not look like it started today. Keep the useful overlap but stamp its
        // start day in the row; the empty state remains strictly selected-day scoped.
        let workoutsLocal = (await wkA).sorted { $0.startTs > $1.startTs }

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var provenance: [String: String] = [:]
        for (metric, resolution) in sourceResolutions {
            if let winner = resolution.points.last(where: { $0.day == requestedDayKey })?.source {
                provenance[metric] = winner
            }
        }

        guard !Task.isCancelled,
              requestKey == LiquidTodayQueryKey(
                refreshSeq: repo.refreshSeq,
                ageMetricsSeq: repo.ageMetricsSeq,
                workoutsSeq: repo.workoutsSeq,
                deviceId: repo.deviceId,
                dayKey: selectedDayKey,
                profileState: profile.ageMetricStateToken
              ) else { return }

        let cache = LiquidTodayLoadCache(
            key: requestKey,
            bankedAt: Date(),
            restScore: restScoreLocal,
            heroProvenanceByMetric: provenance,
            stress: stressLocal,
            fitnessAge: fitnessAgeLocal,
            vitality: vitalityLocal,
            stepsEst: stepsEstLocal,
            importedStepsDay: importedStepsLocal,
            importedActiveKcalDay: importedActiveKcalLocal,
            importedRestingKcalDay: importedRestingKcalLocal,
            importedWeightKg: importedWeightLocal,
            hrValues: hrValuesLocal,
            workouts: workoutsLocal,
            keyMetricTrends: keyMetricTrendsLocal,
            resolvedSpo2ByDay: resolvedSpo2Local
        )
        repo.liquidTodayLoadCache = cache
        applyQueryCache(cache)
        loadedQueryDayKey = requestedDayKey
        markQueryDataLoaded()
        diagnosticOutcome = "full"
        diagnosticFields = [
            "hr_bucket_count": String(hrValuesLocal.count),
            "workout_count": String(workoutsLocal.count),
            "trend_metric_count": String(keyMetricTrendsLocal.count),
        ]
    }

    private func updateAdaptiveHydrationContext() {
        #if os(iOS)
        let temperatureC = weather.snapshot?.temperatureC
        #else
        let temperatureC: Double? = nil
        #endif
        let isCurrentCalendarDay =
            cachedDisplayDay?.day == Repository.localDayKey(Date())
        HydrationReminders.updateAdaptiveContext(
            temperatureC: temperatureC,
            effort: selectedDayOffset == 0 && isCurrentCalendarDay ? cachedDisplayDay?.strain : nil,
            consumedML: selectedDayOffset == 0 && isCurrentCalendarDay ? hydrationTotalML : nil,
            goalML: selectedDayOffset == 0 && isCurrentCalendarDay ? hydrationGoalML : nil
        )
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: selectedDayKey)
    }

    private var currentDailyActionCheckIn: DailyActionPlanner.CheckIn {
        guard selectedDayOffset == 0 else { return .unanswered }
        #if DEBUG
        if let demo = Self.demoDailyActionCheckIn { return demo }
        #endif
        return BehaviorStore.decodeDailyActionCheckIn(
            today: selectedDayKey,
            storedDay: dailyActionCheckInDay,
            storedValue: dailyActionCheckInValue
        )
    }

    #if DEBUG
    private static var demoDailyActionCheckIn: DailyActionPlanner.CheckIn? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-daily-plan-check-in"),
              index + 1 < arguments.count else {
            return nil
        }
        return DailyActionPlanner.CheckIn(rawValue: arguments[index + 1])
    }
    #endif

    private var dailyActionPlan: DailyActionPlanner.Plan {
        cachedDailyActionPlan ?? makeDailyActionPlan(readiness: readiness)
    }

    private func makeDailyActionPlan(
        readiness: ReadinessEngine.Readiness
    ) -> DailyActionPlanner.Plan {
        DailyActionPlanner.plan(
            today: selectedDayKey,
            readiness: readiness,
            checkIn: currentDailyActionCheckIn,
            recentEffort: repo.days.map {
                DailyActionPlanner.EffortDay(day: $0.day, effort: $0.strain)
            }
        )
    }

    private func setDailyActionCheckIn(_ value: DailyActionPlanner.CheckIn) {
        guard selectedDayOffset == 0 else { return }
        dailyActionCheckInDay = selectedDayKey
        dailyActionCheckInValue = value.rawValue
        cachedDailyActionPlan = DailyActionPlanner.plan(
            today: selectedDayKey,
            readiness: readiness,
            checkIn: value,
            recentEffort: repo.days.map {
                DailyActionPlanner.EffortDay(day: $0.day, effort: $0.strain)
            }
        )
    }

    /// One card-level provenance label. Identical winners collapse to one name; mixed scores show at most
    /// two distinct winners in Charge / Effort / Rest order so the compact badge stays readable.
    private var heroSourceLabel: String? {
        Self.heroSourceLabel(
            rawSources: ["recovery", "strain", "sleep_performance"].compactMap { heroProvenanceByMetric[$0] },
            deviceId: repo.deviceId)
    }

    /// Pure aggregation seam for the Liquid hero. The existing Today mapper turns computed siblings into
    /// "On-device", the Apple Health source into "Apple Watch", and imported strap rows into
    /// "Compatible band".
    static func heroSourceLabel(rawSources: [String], deviceId: String) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for raw in rawSources {
            let label = TodayView.todayProvenanceChipLabel(
                rawSource: raw, deviceId: deviceId, appleHealthSource: Repository.appleHealthSource)
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    /// A mixed hero provenance label still includes the live band and must retain sync feedback.
    static func sourceLabelIncludesCompatibleBand(_ label: String) -> Bool {
        label.split(separator: "+").contains { component in
            component.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(WhoopModel.customerName) == .orderedSame
        }
    }

    /// A stopped transfer is not evidence of success. Only a completion timestamp that appeared or advanced
    /// after the current sync began may drive the brief green confirmation.
    static func bandSyncCompletionAdvanced(
        from startedAt: TimeInterval?,
        to completedAt: TimeInterval?
    ) -> Bool {
        guard let completedAt else { return false }
        guard let startedAt else { return true }
        return completedAt > startedAt
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return String(localized: "Aligned")
        case .balanced: return String(localized: "Within range")
        case .strained: return String(localized: "Recheck")
        case .rundown: return String(localized: "Multiple shifts")
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // #612: when still calibrating BECAUSE the strap stopped delivering nights (connected, but no new
        // night for > staleDays), say so directly instead of "still learning your baseline" - the honest
        // calibrating state with its reason attached. `stale` is always > staleDays (14), so always plural.
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from Noop Band for \(stale) days. Check that it is connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "Available recovery signals are aligned with your recent baseline.")
        case .balanced: return String(localized: "Available signals are close to your recent baseline.")
        case .strained: return String(localized: "One signal shifted. Recheck the trend and use how you feel as context.")
        case .rundown: return String(localized: "Several signals shifted together. This is a prompt to review, not a diagnosis.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

    private var readinessConfidenceLabel: String {
        switch readiness.confidence {
        case .calibrating: return String(localized: "Calibrating")
        case .building: return String(localized: "Building confidence")
        case .solid: return String(localized: "Higher confidence")
        }
    }

    private var readinessAsOfLabel: String {
        guard let day = readinessAsOfDay ?? readiness.asOfDay else {
            return String(localized: "No current daily read")
        }
        if day == selectedDayKey { return String(localized: "As of this day") }
        return String(localized: "As of \(day)")
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let salutation = h < 12 ? String(localized: "appwide.today.greeting.morning")
            : h < 17 ? String(localized: "appwide.today.greeting.afternoon")
            : String(localized: "appwide.today.greeting.evening")
        return String.localizedStringWithFormat(
            String(localized: "appwide.today.greeting_format"),
            salutation,
            profile.displayName
        )
    }

    // Measured Apple Health count first, then WHOOP 5/MG @57 motion estimate, then calibrated fallback.
    // The route and source caption below share this precedence so detail always matches the number shown.
    private var stepCount: Double? {
        MetricCatalog.todayStepsValue(imported: importedStepsDay.map(Double.init),
                                      motionDerived: displayDay?.steps.map(Double.init),
                                      calibratedEstimate: stepsEst)
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMotionDerivedSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    /// Truthful source caption for the number on the Liquid Steps card. Apple Health remains an imported
    /// pedometer count; both local strap paths are clearly labelled as motion-derived estimates.
    private var stepsSourceCaption: String {
        if importedStepsDay != nil { return String(localized: "Imported · Apple Health") }
        if displayDay?.steps != nil { return String(localized: "Motion-derived estimate · Noop Band") }
        if stepsEst != nil { return String(localized: "Motion-derived estimate · calibrated") }
        return String(localized: "No step source for this day")
    }

    private var liquidSpo2: Double? {
        displayDay?.spo2Pct
            ?? resolvedSpo2ByDay[selectedDayKey]
            ?? vitalsDay?.spo2Pct
            ?? spo2Day?.spo2Pct
            ?? (selectedDayOffset == 0
                ? resolvedSpo2ByDay.filter { $0.key <= selectedDayKey }
                    .max(by: { $0.key < $1.key })?.value
                : nil)
    }

    private var liquidSkinTemperature: Double? {
        displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC ?? skinTempDay?.skinTempDevC
    }

    private func skinTemperatureText(_ celsius: Double) -> String {
        if VitalBands.isAbsoluteSkinTemp(celsius) {
            return UnitFormatter.temperatureFromCelsius(celsius, unit: temperatureUnit, decimals: 1)
        }
        return UnitFormatter.temperatureDeltaFromCelsius(celsius, unit: temperatureUnit, decimals: 1)
    }

    private func weightText(_ kilograms: Double) -> String {
        UnitFormatter.massFromKilograms(kilograms, unit: massUnit)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    private var energyBreakdown: DailyEnergyBreakdown {
        DailyEnergyBreakdown.resolve(
            appleActiveKcal: importedActiveKcalDay,
            appleRestingKcal: importedRestingKcalDay,
            wearableCombinedKcal: displayDay?.activeKcalEst
        )
    }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayEnergyMetric(for: energyBreakdown)
    }

    private var caloriesDetailKey: String { caloriesDetailMetric?.key ?? "energy_kcal" }
    private var caloriesDetailSource: String { caloriesDetailMetric?.source ?? "my-whoop" }

    private var energyHeadlineLabel: String {
        switch energyBreakdown.coverage {
        case .completeApple:        return String(localized: "Total kcal")
        case .activeOnly:           return String(localized: "Active kcal")
        case .restingOnly:          return String(localized: "Resting kcal")
        case .combinedEstimateOnly: return String(localized: "Combined estimate")
        case .unavailable:          return String(localized: "No energy data")
        }
    }

    private var energyStateText: String {
        switch energyBreakdown.coverage {
        case .completeApple:        return String(localized: "Apple Health · active + resting")
        case .activeOnly:           return String(localized: "Partial · resting energy unavailable")
        case .restingOnly:          return String(localized: "Partial · active energy unavailable")
        case .combinedEstimateOnly: return String(localized: "NOOP combined estimate · split unavailable")
        case .unavailable:          return String(localized: "No complete energy source yet")
        }
    }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func kcalText(_ v: Double?, includesUnit: Bool = true) -> String {
        guard let v else { return "–" }
        let n = v.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
        return includesUnit ? "\(n) kcal" : n
    }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? "Calibrating" }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let startDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
        if startDay != selectedDayKey {
            parts.append(Date(timeIntervalSince1970: TimeInterval(w.startTs))
                .formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append(Date(timeIntervalSince1970: TimeInterval(w.startTs))
                .formatted(date: .omitted, time: .shortened))
        }
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(String(format: "%.1f km", dm / 1000)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        // #1013: localize the sub-header date. The old en_US_POSIX "EEEE, d MMMM" formatter forced English
        // weekday + month names regardless of the UI language. A locale-aware field template localizes both
        // the names AND the field order (e.g. fr "mercredi 4 juillet") in the user's locale.
        return selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(Locale.autoupdatingCurrent))
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil - the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

struct LiquidTodayQueryKey: Equatable {
    let refreshSeq: Int
    let ageMetricsSeq: Int
    let workoutsSeq: Int
    let deviceId: String
    let dayKey: String
    let profileState: String
}

/// Query-backed Liquid Today outputs banked on the long-lived Repository. A view re-mount can repaint
/// from memory instead of reopening the same multi-year metric series and selected-day HR window.
struct LiquidTodayLoadCache {
    let key: LiquidTodayQueryKey
    let bankedAt: Date
    let restScore: Double?
    let heroProvenanceByMetric: [String: String]
    let stress: Double?
    let fitnessAge: Double?
    let vitality: Double?
    let stepsEst: Double?
    let importedStepsDay: Int?
    let importedActiveKcalDay: Double?
    let importedRestingKcalDay: Double?
    let importedWeightKg: Double?
    let hrValues: [Double]
    let workouts: [WorkoutRow]
    let keyMetricTrends: [KeyMetric: [Double]]
    let resolvedSpo2ByDay: [String: Double]
}

// MARK: - Cross-metric pattern brief

/// Isolated leaf by design. AppModel publishes live BPM at ~1 Hz; observing it on the full Today screen
/// would invalidate the entire dashboard. This small card is the only observer, while the heavier
/// readiness snapshot is passed by value from Today's load cache.
private struct TodaySignalPatternsCard: View {
    @EnvironmentObject private var model: AppModel
    let readiness: ReadinessEngine.Readiness
    let restScore: Double?
    @State private var showDetails = false

    private var result: CrossMetricBriefEngine.Result {
        #if DEBUG
        // Screenshot/test harness only: renders the real synthesis engine's corroborated state without
        // writing fake biometrics to the user's store. Stripped from Release builds.
        if CommandLine.arguments.contains("--demo-patterns") {
            let demoReadiness = ReadinessEngine.Readiness(
                level: .rundown,
                headline: "Multiple shifts",
                summary: "Several signals shifted.",
                signals: [
                    .init(key: "hrv", label: "HRV", evidence: "52 vs 68 ms",
                          detail: "below your usual range", flag: .bad),
                    .init(key: "rhr", label: "Resting HR", evidence: "61 vs 54 bpm",
                          detail: "above your usual range", flag: .bad),
                    .init(key: "effortVariety", label: "Effort variety",
                          evidence: "Last 7 recorded days: Effort 46-52 (average 49)",
                          detail: "recorded daily Effort stayed in a narrow range", flag: .watch),
                ],
                effortVariety: 2.4
            )
            let demoVitals = IllnessSignalEngine.Result(
                score: 72,
                level: .raised,
                firedSignals: ["RHR +7", "HRV −24%", "respiration up"],
                suppressedBy: [],
                signalCount: 3,
                copy: "Unused presentation copy"
            )
            return CrossMetricBriefEngine.evaluate(
                readiness: demoReadiness,
                illness: demoVitals,
                restScore: 62
            )
        }
        #endif
        return CrossMetricBriefEngine.evaluate(
            readiness: readiness,
            // A live illness snapshot must never override the explicit-current-day freshness gate.
            // When today's readiness anchor is absent, omit it and show "Building your baseline".
            illness: readiness.level == .insufficient ? nil : model.illnessSignal,
            restScore: restScore
        )
    }

    private var tint: Color {
        switch result.state {
        case .watch: return StrandPalette.metricAmber
        case .steady: return StrandPalette.chargeColor
        case .building: return StrandPalette.restColor
        }
    }

    private var symbol: String {
        switch result.state {
        case .watch: return "waveform.path.ecg"
        case .steady: return "checkmark.circle.fill"
        case .building: return "circle.dotted"
        }
    }

    var body: some View {
        Button { showDetails = true } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(
                            LinearGradient(
                                colors: [tint.opacity(0.24), tint.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("PATTERNS TO WATCH")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(result.headline)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    if let confidence = result.findings.first?.confidence {
                        Text(confidence.label.uppercased())
                            .font(StrandFont.overlineScaled(8))
                            .tracking(0)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(tint.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.7))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }

                Text(result.summary)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let changed = result.findings.first?.evidence.first {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("appwide.pattern.what_changed")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(tint)
                        Text(changed)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(signalCountText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 0)
                    Text("Review signals")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius, washStrength: 0.9))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Patterns to watch. \(result.headline). \(result.summary)")
        .accessibilityHint("Opens the contributing signals, possible influences, and suggestions.")
        .sheet(isPresented: $showDetails) {
            SignalPatternDetailSheet(result: result)
        }
        #if DEBUG
        // Let the presenting hierarchy finish its first layout before opening the deterministic
        // screenshot sheet. Setting this synchronously from onAppear can race SwiftUI's first
        // presentation pass on a cold simulator launch.
        .task {
            if CommandLine.arguments.contains("--demo-pattern-details") {
                try? await Task.sleep(nanoseconds: 900_000_000)
                showDetails = true
            }
        }
        #endif
    }

    private var signalCountText: String {
        let count = result.checkedSignals.count
        if count == 0 { return String(localized: "Waiting for fresh signals") }
        return count == 1
            ? String(localized: "Checked 1 fresh signal")
            : String(localized: "Checked \(count) fresh signals")
    }
}

private struct SignalPatternDetailSheet: View {
    let result: CrossMetricBriefEngine.Result
    @Environment(\.dismiss) private var dismiss

    private var tint: Color {
        switch result.state {
        case .watch: return StrandPalette.metricAmber
        case .steady: return StrandPalette.chargeColor
        case .building: return StrandPalette.restColor
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // A single finding already carries this headline and summary in its evidence card.
                    // Keep the overview only for calibration/steady states or when several distinct
                    // findings need one shared frame; otherwise the sheet opened with duplicate prose.
                    if result.findings.count != 1 {
                        NoopCard(tint: tint) {
                            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                                Label(multiFindingOverviewTitle, systemImage: headerSymbol)
                                    .font(StrandFont.title2)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(multiFindingOverviewSummary)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    ForEach(result.findings) { finding in
                        findingCard(finding)
                    }

                    NoopCard(tint: StrandPalette.metricCyan) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            patternHeader("WHAT NOOP CHECKED", symbol: "checklist", tint: StrandPalette.metricCyan)
                            Text(checkedSignalsText)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider().overlay(StrandPalette.hairline)
                            Text("NOOP combines current, personal-baseline signals. It does not let Recovery vote again beside the HRV and resting-heart-rate inputs that helped create it, and one unusual reading only becomes a recheck.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Label(CrossMetricBriefEngine.disclaimer, systemImage: "shield.lefthalf.filled")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Patterns to watch")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private func findingCard(_ finding: CrossMetricBriefEngine.Finding) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(finding.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(finding.confidence.label)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Text(finding.summary)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !finding.evidence.isEmpty {
                    patternList(
                        title: String(localized: "appwide.pattern.what_changed"),
                        symbol: "waveform.path.ecg",
                        rows: finding.evidence,
                        tint: tint
                    )
                }
                patternList(
                    title: "POSSIBLE CONTRIBUTORS",
                    symbol: "questionmark.circle",
                    rows: finding.possibleContributors,
                    tint: StrandPalette.metricCyan
                )
                patternList(
                    title: "LOW-RISK NEXT STEPS",
                    symbol: "arrow.forward.circle",
                    rows: finding.safeActions,
                    tint: StrandPalette.chargeColor
                )
            }
        }
    }

    private func patternList(title: String, symbol: String, rows: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            patternHeader(title, symbol: symbol, tint: tint)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                        .accessibilityHidden(true)
                    Text(row)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func patternHeader(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(tint)
    }

    private var checkedSignalsText: String {
        result.checkedSignals.isEmpty
            ? String(localized: "Waiting for enough fresh personal data.")
            : result.checkedSignals.joined(separator: " · ")
    }

    private var multiFindingOverviewTitle: String {
        result.findings.count == 1
            ? result.headline
            : String(localized: "\(result.findings.count) patterns worth a closer look")
    }

    private var multiFindingOverviewSummary: String {
        result.findings.count == 1
            ? result.summary
            : String(localized: "Several fresh signals changed together. Review each pattern and its possible contributors before deciding what to do today.")
    }

    private var headerSymbol: String {
        switch result.state {
        case .watch: return "waveform.path.ecg"
        case .steady: return "checkmark.circle.fill"
        case .building: return "circle.dotted"
        }
    }
}

/// Non-observable scratch storage for the display-linked scroll offset. SwiftUI retains the reference
/// through `@State`, but mutating `offset` does not publish and therefore does not rebuild Today.
private final class LiquidTodayScrollTracker {
    var offset: CGFloat = 0
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    var compact = false
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        HStack(spacing: compact ? NoopMetrics.space2 : 14) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(compact ? 13 : 16, weight: .bold))
                    // The hardware field turns pearl in Light mode, so fixed white ink disappears.
                    // Dynamic neutral ink remains soft black on pearl and soft white on obsidian.
                    .foregroundStyle(compact ? StrandPalette.textSecondary : StrandPalette.textTertiary)
            }
        }
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: compact ? nil : .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). A normal tap opens the dossier; a physical
/// double tap is an optional explanation shortcut. The separate 44pt information control keeps that
/// explanation discoverable and accessible without relying on a hidden gesture.
private struct HeroScoreCell: View {

    static let vesselDiameter: CGFloat = 84

    let label: String
    let score: Double?            // on whatever scale the caller passes (nil = no data yet)
    let tint: Color
    let animated: Bool
    let onOpen: () -> Void
    let onExplain: () -> Void
    // The scale `score` is already expressed on — 100 for Charge/Rest, or the user's chosen Effort scale
    // max (100 or 21, #45) — so the vessel fill matches the displayed number.
    var maxValue: Double = 100
    // Decimal places for the displayed number. 0 keeps the whole-number scores; the WHOOP 0–21 Effort
    // scale passes 1 to match the app-wide one-decimal `effortDisplay` convention (#45).
    var decimals: Int = 0
    /// A real bounded progress value used when no score exists yet (currently baseline calibration).
    /// This fills the vessel without inventing a provisional Recovery number.
    var fillFraction: Double? = nil
    /// Honest non-score readout shown inside the vessel, e.g. "2/4" calibration nights.
    var emptyText: String = "–"
    var accessibilityValueOverride: String? = nil

    @State private var shown: Double = 0

    private var frac: Double? {
        if let fillFraction { return max(0, min(1, fillFraction)) }
        return score.map { max(0, min(1, $0 / maxValue)) }
    }

    /// Extracted so the compiler doesn't have to type-check the whole hero body as one expression
    /// (it started timing out once this file grew — the compiler's own suggested remedy).
    private var vesselLayer: some View {
        ZStack {
            LiquidVessel(value: frac, tint: tint, animated: animated)
                .frame(width: Self.vesselDiameter, height: Self.vesselDiameter)
            readout
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var readout: some View {
        if score != nil {
            CountUpNumber(value: shown, font: StrandFont.rounded(26), decimals: decimals)
        } else {
            let size: CGFloat = emptyText == "–" ? 26 : 19
            Text(emptyText).font(StrandFont.rounded(size))
        }
    }

    /// The spoken value, extracted for the same type-check reason.
    private var accessibilityValueText: String {
        if let override = accessibilityValueOverride { return override }
        guard let s = score else { return String(localized: "No data yet") }
        if decimals > 0 {
            return String(format: "%.\(decimals)f of %.0f", s, maxValue)
        }
        return String(localized: "\(Int(s.rounded())) of \(Int(maxValue.rounded()))")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 7) {
                vesselLayer
                HStack(spacing: 3) {
                    // #74: one line, shrink-to-fit rather than wrap under large Dynamic Type (mirrors
                    // the score number above) so labels never grow the hero card to two lines.
                    Text(label.uppercased()).font(StrandFont.overline).tracking(0)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.6)
                }
                // The hero card is pinned dark in both themes, so use scheme-invariant on-dark ink.
                .foregroundStyle(StrandPalette.onDarkSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first: onExplain()
                        case .second: onOpen()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(accessibilityValueText))
            .accessibilityHint("Opens the detailed trend. An About button explains the metric.")
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: Text("Explain \(label)")) { onExplain() }
            .accessibilitySortPriority(1)

            MetricInfoButton(
                title: String(localized: "About \(label)"),
                tint: tint,
                visualSize: 22,
                action: onExplain
            )
            .offset(x: 2, y: -3)
        }
        .frame(maxWidth: .infinity)
        .onAppear { rollTo(score) }
        .onChangeCompat(of: score) { v in rollTo(v) }
    }

    private func rollTo(_ v: Double?) {
        guard let v else { shown = 0; return }
        withAnimation(.easeOut(duration: 0.9)) { shown = v }   // counts up in step with the vessel filling
    }
}

/// The Daily Signal header uses the same audited readiness and illness results as the rest of Today.
/// It deliberately lives in a small AppModel-observing leaf so the live ~1 Hz heart-rate stream does not
/// invalidate the score vessels or the rest of the dashboard.
private struct DailySignalHeader: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    let readiness: ReadinessEngine.Readiness
    let includesCurrentWellnessSignal: Bool
    let sourceLabel: String?

    private var illness: IllnessSignalEngine.Result? {
        includesCurrentWellnessSignal ? model.illnessSignal : nil
    }

    private var status: DailySignalStatus {
        #if DEBUG
        if let demoStatus = Self.demoStatus { return demoStatus }
        #endif
        return DailySignalStatus.resolve(readiness: readiness, illness: illness)
    }

    #if DEBUG
    /// Deterministic visual-QA state. This changes presentation only and is not compiled into release builds.
    private static var demoStatus: DailySignalStatus? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-daily-signal"),
              arguments.indices.contains(index + 1) else { return nil }
        return DailySignalStatus(rawValue: arguments[index + 1].lowercased())
    }
    #endif

    private var tint: Color {
        switch status {
        case .steady: return StrandPalette.statusPositive
        case .watch: return StrandPalette.statusWarning
        case .alert: return DailySignalAppearance.alertTint
        case .building: return StrandPalette.onDarkTertiary
        }
    }

    private var label: String {
        switch status {
        case .steady: return String(localized: "appwide.daily_signal.status.aligned")
        case .watch: return String(localized: "appwide.daily_signal.status.recheck")
        case .alert: return String(localized: "appwide.daily_signal.status.check_in")
        case .building: return String(localized: "appwide.daily_signal.status.building")
        }
    }

    private var summary: String {
        if let illness, status == .alert || status == .watch { return illness.copy }
        return ReadinessPresentation.summary(for: readiness)
    }

    private var accessibilitySummary: String {
        let state = String.localizedStringWithFormat(
            String(localized: "appwide.a11y.state_format"),
            String(localized: "appwide.daily_signal.label"),
            label
        )
        return String.localizedStringWithFormat(
            String(localized: "appwide.a11y.state_format"),
            state,
            summary
        )
    }

    var body: some View {
        NavigationLink(value: TabRoute.health) {
            ViewThatFits(in: .horizontal) {
                wideRow
                compactRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilitySummary))
            .accessibilityHint(Text("appwide.daily_signal.a11y.hint"))
            .accessibilityIdentifier("noop.today.daily-signal")
        }
        .buttonStyle(.plain)
    }

    private var wideRow: some View {
        HStack(spacing: NoopMetrics.space2) {
            signalLabel
            Spacer(minLength: NoopMetrics.space4)
            if let sourceLabel {
                DailySignalSourceChip(text: sourceLabel)
                    .fixedSize()
            }
            V2Chip(text: label, tone: tint)
                .fixedSize()
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            signalLabel
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NoopMetrics.space2) {
                    Spacer(minLength: NoopMetrics.space2)
                    sourceChip
                    statusChip
                }

                VStack(alignment: .trailing, spacing: NoopMetrics.space2) {
                    sourceChip
                    statusChip
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var sourceChip: some View {
        if let sourceLabel {
            DailySignalSourceChip(text: sourceLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusChip: some View {
        V2Chip(text: label, tone: tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var signalLabel: some View {
        HStack(spacing: NoopMetrics.space2) {
            DailySignalWaveform(
                status: status,
                tint: tint,
                posed: motion.poseStill(reduceMotion)
            )
            Text("appwide.daily_signal.label")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.onDarkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Score provenance stays neutral at rest. During a real band-history offload, the compatible-band source gets
/// an indeterminate sweep because the protocol exposes chunks pulled but no total; a percentage would lie.
/// Completion turns the label green briefly, then returns it to the same quiet provenance treatment.
///
/// LiveState observation is isolated here so its ~1 Hz heart-rate stream never invalidates the header,
/// score vessels, or the rest of Today.
private struct DailySignalSourceChip: View {
    @EnvironmentObject private var live: LiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String

    @State private var sweep: CGFloat = 0
    @State private var presentingSync = false
    @State private var justSynced = false
    @State private var syncStartedAt: TimeInterval?
    @State private var completionTask: Task<Void, Never>?
    private static let interChunkDelayNanoseconds: UInt64 = 3_000_000_000
    private static let demoSyncing = CommandLine.arguments.contains("--demo-band-syncing")

    private var isBand: Bool {
        LiquidTodayView.sourceLabelIncludesCompatibleBand(text)
    }

    private var syncingRaw: Bool {
        isBand && (live.backfilling || Self.demoSyncing)
    }

    private var syncing: Bool { isBand && presentingSync }

    private var tone: Color {
        syncing || justSynced ? StrandPalette.statusPositive : StrandPalette.onDarkSecondary
    }

    private var accessibilityText: String {
        if syncing {
            return live.syncChunksThisSession > 0
                ? String.localizedStringWithFormat(
                    String(localized: "appwide.today.band_sync.progress_format"),
                    live.syncChunksThisSession
                )
                : String(localized: "appwide.today.band_sync.syncing")
        }
        return justSynced ? String(localized: "appwide.today.band_sync.synced") : text
    }

    var body: some View {
        Text(text.uppercased())
            .font(NoopV2.overline)
            .tracking(0)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: NoopV2.chipRadius, style: .continuous)
                        .fill(StrandPalette.onDarkSecondary.opacity(0.13))
                    if syncing && !reduceMotion {
                        GeometryReader { proxy in
                            let width = max(CGFloat(22), proxy.size.width * 0.48)
                            LinearGradient(
                                colors: [.clear, StrandPalette.statusPositive.opacity(0.30), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width)
                            .offset(x: -width + (proxy.size.width + width) * sweep)
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: NoopV2.chipRadius, style: .continuous)
                        )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: NoopV2.chipRadius, style: .continuous)
                    .stroke(StrandPalette.onDarkSecondary.opacity(0.16), lineWidth: 0.75)
            }
            .accessibilityLabel(accessibilityText)
            .onAppear {
                updateSyncPresentation()
            }
            .onChangeCompat(of: live.backfilling) { _ in
                updateSyncPresentation()
            }
            .onChangeCompat(of: text) { _ in
                updateSyncPresentation()
            }
            .onChangeCompat(of: reduceMotion) { _ in
                updateSweep()
            }
            .onDisappear {
                completionTask?.cancel()
            }
    }

    private func updateSyncPresentation() {
        completionTask?.cancel()
        if syncingRaw {
            if !presentingSync {
                syncStartedAt = live.lastSyncedAt
            }
            presentingSync = true
            justSynced = false
            updateSweep()
        } else if isBand && presentingSync {
            // A deep offload briefly drops backfilling between chunks. Keep the sweep continuous and only
            // settle after a quiet interval. A timestamp advance, not silence, decides whether this succeeded.
            completionTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.interChunkDelayNanoseconds)
                guard !Task.isCancelled else { return }
                let completed = LiquidTodayView.bandSyncCompletionAdvanced(
                    from: syncStartedAt,
                    to: live.lastSyncedAt
                )
                presentingSync = false
                justSynced = completed
                syncStartedAt = nil
                updateSweep()
                guard completed else { return }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if !Task.isCancelled { justSynced = false }
            }
        } else {
            presentingSync = false
            justSynced = false
            syncStartedAt = nil
            updateSweep()
        }
    }

    private func updateSweep() {
        withAnimation(.none) { sweep = 0 }
        guard syncing, !reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                sweep = 1
            }
        }
    }
}

/// A short intermittent ECG sweep, not a continuous frame loop. A quiet aligned signal moves once every
/// few seconds; watch/alert states repeat a little sooner. Accessibility, Quiet Motion and Low Power Mode
/// all leave the complete trace posed and still.
private struct DailySignalWaveform: View {
    let status: DailySignalStatus
    let tint: Color
    let posed: Bool

    @State private var progress: CGFloat = 1

    private var sweepSeconds: Double {
        status == .alert ? 0.55 : 0.78
    }

    private var restNanoseconds: UInt64 {
        switch status {
        case .alert: return 1_050_000_000
        case .watch: return 1_850_000_000
        case .steady: return 3_200_000_000
        case .building: return 4_000_000_000
        }
    }

    var body: some View {
        ZStack {
            DailySignalWaveformShape()
                .stroke(tint.opacity(status == .building ? 0.34 : 0.28),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            DailySignalWaveformShape()
                .trim(from: max(0, progress - 0.34), to: progress)
                .stroke(tint,
                        style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .shadow(color: tint.opacity(status == .alert ? 0.58 : 0.28), radius: 3)
        }
        .frame(width: 30, height: 17)
        .accessibilityHidden(true)
        .task(id: "\(status.rawValue)-\(posed)") {
            progress = 1
            guard !posed else { return }
            while !Task.isCancelled {
                progress = 0
                withAnimation(.linear(duration: sweepSeconds)) { progress = 1 }
                do {
                    try await Task.sleep(nanoseconds: restNanoseconds)
                } catch {
                    return
                }
            }
        }
    }
}

private struct DailySignalWaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            .init(x: 0.00, y: 0.53),
            .init(x: 0.13, y: 0.53),
            .init(x: 0.20, y: 0.39),
            .init(x: 0.27, y: 0.69),
            .init(x: 0.36, y: 0.10),
            .init(x: 0.45, y: 0.84),
            .init(x: 0.54, y: 0.47),
            .init(x: 0.65, y: 0.53),
            .init(x: 0.75, y: 0.53),
            .init(x: 0.82, y: 0.40),
            .init(x: 0.89, y: 0.53),
            .init(x: 1.00, y: 0.53),
        ]
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width,
                              y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width,
                                     y: rect.minY + point.y * rect.height))
        }
        return path
    }
}

/// The long-term lane under Daily Signal. Fitness Age is deliberately not rendered as a fourth equal
/// score: it updates weekly and estimates cardiorespiratory fitness rather than today's readiness.
private struct FitnessAgeHeroRow: View {
    let age: Double?
    let profileAge: Int
    let calibrationText: String
    let onOpen: () -> Void
    let onExplain: () -> Void

    private var valueText: String {
        age.map(FitnessAgePresentation.value) ?? String(localized: "Calibrating")
    }

    private var comparisonText: String {
        guard let age, profileAge > 0 else { return calibrationText }
        return FitnessAgePresentation.comparison(estimate: age, profileAge: profileAge)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                MetricGlyph("figure.run", size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("FITNESS AGE")
                            .font(StrandFont.overlineScaled(10))
                            .tracking(0)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("WEEKLY")
                            .font(StrandFont.overlineScaled(8))
                            .tracking(0)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(StrandPalette.chargeColor.opacity(0.14), in: Capsule())
                    }
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(valueText)
                            .font(StrandFont.number(18))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.onDarkSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(comparisonText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.onDarkSecondary.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first: onExplain()
                        case .second: onOpen()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Fitness Age")
            .accessibilityValue("\(valueText). \(comparisonText)")
            .accessibilityHint("Opens the detailed weekly trend. An About button explains the metric.")
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: Text("Explain Fitness Age")) { onExplain() }
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("noop.today.fitness-age")

            MetricInfoButton(
                title: String(localized: "About Fitness Age"),
                tint: StrandPalette.chargeColor,
                visualSize: 24,
                action: onExplain
            )
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// Pull feedback owns LiveState in an isolated leaf so live HR does not invalidate the whole dashboard.
/// A local repository refresh, a real band transfer, and its eventual outcome are intentionally separate:
/// pulling while disconnected must never claim that Noop Band is syncing.
private struct LiquidRefreshIndicator: View {
    let pullY: CGFloat
    let pullThreshold: CGFloat
    let refreshing: Bool
    let liquidHeart: Color
    let hasCachedContent: Bool

    @EnvironmentObject private var live: LiveState

    private var progress: CGFloat { min(1, max(0, pullY / pullThreshold)) }

    private enum Outcome {
        case synced
        case unavailable
        case failed
    }

    private enum Phase: Equatable {
        case idle
        case pulling
        case refreshing
        case syncing
        case synced
        case unavailable
        case failed
    }

    /// Backfill briefly falls false between chunks. Keep the transfer visible through that quiet window,
    /// then use `lastSyncedAt` rather than elapsed time to decide whether it actually completed.
    @State private var presentingBandSync = false
    @State private var syncStartedAt: TimeInterval?
    @State private var refreshStartedAt: TimeInterval?
    @State private var outcome: Outcome?
    @State private var settleTask: Task<Void, Never>?
    @State private var outcomeTask: Task<Void, Never>?
    @State private var presentationTask: Task<Void, Never>?
    @State private var presentationNow = Date().timeIntervalSince1970

    private static let interChunkDelayNanoseconds: UInt64 = 3_000_000_000
    private static let outcomeDelayNanoseconds: UInt64 = 2_000_000_000

    private var phase: Phase {
        if refreshing { return .refreshing }
        if live.backfilling || presentingBandSync {
            switch HistorySyncPresentationPolicy.state(
                isSyncing: true,
                hasCachedContent: hasCachedContent,
                startedAt: live.historySyncStartedAt,
                lastDurableProgressAt: live.historySyncLastDurableProgressAt,
                now: presentationNow
            ) {
            case .expanded, .attention:
                return .syncing
            case .hidden, .compact:
                break
            }
        }
        switch outcome {
        case .synced: return .synced
        case .unavailable: return .unavailable
        case .failed: return .failed
        case nil: return pullY > 2 ? .pulling : .idle
        }
    }

    private var visible: Bool { phase != .idle }
    private var armed: Bool { progress >= 1 }
    private var holdsOpen: Bool {
        switch phase {
        case .refreshing, .syncing, .synced, .unavailable, .failed: return true
        case .idle, .pulling: return false
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .refreshing:
            return String(localized: "appwide.today.local_refresh.refreshing")
        case .syncing:
            return String(localized: "appwide.today.band_sync.syncing")
        case .synced:
            return String(localized: "appwide.today.band_sync.synced")
        case .unavailable:
            return String(localized: "appwide.today.band_sync.unavailable")
        case .failed:
            return String(localized: "appwide.today.band_sync.failed")
        case .idle, .pulling:
            return String(localized: "Pull to sync")
        }
    }

    private var accessibilityValue: String {
        if phase == .refreshing || phase == .syncing {
            return String(localized: "In progress")
        }
        if armed { return String(localized: "Release to sync") }
        return Double(progress).formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        Group {
            if holdsOpen {
                indicatorContent
                    .padding(.vertical, 6)
                    .frame(minHeight: 72)
            } else {
                indicatorContent
                    .frame(height: min(pullY, pullThreshold * 1.15))
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.22), value: holdsOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("noop.today.pull-sync")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Pull down from the top of Today, then release to sync Noop Band.")
        .accessibilityHidden(!visible)
        .onAppear {
            refreshStartedAt = live.lastSyncedAt
            if live.backfilling {
                syncStartedAt = live.lastSyncedAt
                presentingBandSync = true
            }
            schedulePresentationClock()
        }
        .onChangeCompat(of: refreshing) { active in
            handleRefreshChange(active)
            schedulePresentationClock()
        }
        .onChangeCompat(of: live.backfilling) { active in
            handleBandSyncChange(active)
        }
        .onChangeCompat(of: live.historySyncStartedAt) { _ in
            schedulePresentationClock()
        }
        .onChangeCompat(of: live.historySyncLastDurableProgressAt) { _ in
            schedulePresentationClock()
        }
        .onChangeCompat(of: hasCachedContent) { _ in
            schedulePresentationClock()
        }
        .onDisappear {
            settleTask?.cancel()
            outcomeTask?.cancel()
            presentationTask?.cancel()
        }
    }

    private var indicatorContent: some View {
        VStack(spacing: 6) {
            if visible {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.58))
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    Circle()
                        .trim(from: 0, to: holdsOpen ? 1 : max(0.04, progress))
                        .stroke(
                            phase == .failed || phase == .unavailable
                                ? StrandPalette.statusWarning
                                : liquidHeart,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    switch phase {
                    case .refreshing, .syncing:
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    case .synced:
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(StrandPalette.statusPositive)
                    case .unavailable:
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(StrandPalette.statusWarning)
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(StrandPalette.statusWarning)
                    case .idle, .pulling:
                        Image(systemName: armed ? "arrow.down" : "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(armed ? 0 : Double(progress) * 110))
                    }
                }
                .frame(width: 42, height: 42)
                .shadow(
                    color: liquidHeart.opacity(holdsOpen || armed ? 0.34 : 0.18),
                    radius: holdsOpen || armed ? 9 : 5
                )
                .opacity(holdsOpen ? 1 : max(0.38, progress))
                .scaleEffect(holdsOpen ? 1 : 0.82 + 0.18 * progress)

                if holdsOpen || armed {
                    Text(armed && phase == .pulling
                         ? String(localized: "Release to sync")
                         : accessibilityLabel)
                    .font(StrandFont.caption)
                    .foregroundStyle(
                        phase == .failed || phase == .unavailable
                            ? StrandPalette.statusWarning
                            : StrandPalette.textSecondary
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func handleRefreshChange(_ active: Bool) {
        if active {
            outcomeTask?.cancel()
            outcome = nil
            refreshStartedAt = live.lastSyncedAt
            return
        }
        guard !live.backfilling, !presentingBandSync else { return }
        if LiquidTodayView.bandSyncCompletionAdvanced(
            from: refreshStartedAt,
            to: live.lastSyncedAt
        ) {
            showOutcome(.synced)
        } else if !live.connected || !live.bonded {
            showOutcome(.unavailable)
        } else {
            showOutcome(.failed)
        }
        refreshStartedAt = nil
    }

    private func handleBandSyncChange(_ active: Bool) {
        settleTask?.cancel()
        if active {
            outcomeTask?.cancel()
            outcome = nil
            if !presentingBandSync {
                syncStartedAt = refreshStartedAt ?? live.lastSyncedAt
            }
            presentingBandSync = true
            schedulePresentationClock()
            return
        }
        guard presentingBandSync else { return }
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.interChunkDelayNanoseconds)
            guard !Task.isCancelled else { return }
            let completed = LiquidTodayView.bandSyncCompletionAdvanced(
                from: syncStartedAt,
                to: live.lastSyncedAt
            )
            presentingBandSync = false
            syncStartedAt = nil
            refreshStartedAt = nil
            schedulePresentationClock()
            showOutcome(completed ? .synced : .failed)
        }
    }

    private func schedulePresentationClock() {
        presentationTask?.cancel()
        presentationNow = Date().timeIntervalSince1970
        guard live.backfilling || presentingBandSync,
              let startedAt = live.historySyncStartedAt else { return }

        let progressReference = live.historySyncLastDurableProgressAt ?? startedAt
        let deadlines = [
            startedAt + HistorySyncPresentationPolicy.expandedForSeconds,
            progressReference + HistorySyncDurableProgressPolicy.stalledAfterSeconds,
        ].filter { $0 > presentationNow }.sorted()
        guard !deadlines.isEmpty else { return }

        presentationTask = Task { @MainActor in
            for deadline in deadlines {
                let delay = max(0, deadline - Date().timeIntervalSince1970)
                if delay > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                }
                guard !Task.isCancelled else { return }
                presentationNow = Date().timeIntervalSince1970
            }
        }
    }

    private func showOutcome(_ next: Outcome) {
        outcomeTask?.cancel()
        outcome = next
        outcomeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.outcomeDelayNanoseconds)
            if !Task.isCancelled {
                outcome = nil
            }
        }
    }
}

/// Quick-actions "+" button. Tap → the shell's quick-action menu.
/// #today-layout: the Arrange sheet — reorder the Today sections by dragging rows (SwiftUI's native
/// `onMove`; the always-active edit mode on iOS shows the reorder handles without an Edit button). Writes
/// straight through to the persisted order, so Today re-lays-out live behind the sheet. Reset restores the
/// default order. Twin of the Android TodayLayoutEditorDialog over the byte-identical "today.sectionOrder".
private struct TodayArrangeSheet: View {
    @Binding var orderRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let order = TodayLayoutPrefs.decodeOrder(orderRaw)
        NavigationStack {
            List {
                ForEach(order) { section in
                    Text(section.title)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .onMove { from, to in
                    var next = order
                    next.move(fromOffsets: from, toOffset: to)
                    orderRaw = TodayLayoutPrefs.encode(next)
                }
            }
            .navigationTitle("Arrange Today")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Always-active edit mode: the rows carry their reorder handles immediately — hold and drag —
            // with no Edit-button dance. (macOS Lists drag-reorder natively with onMove.)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { orderRaw = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 420)
        #endif
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples, shows the current bpm live with a beat-by-beat trace, and falls back to today's banked
/// 5-minute trace when the strap isn't streaming.
private struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var animated: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    private var bigBpm: Int? {
        if let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        if isLive { return String(localized: "Live · beat by beat") }
        if fallback.count >= 2 { return String(localized: "5-minute average · since midnight") }
        return live.connected ? String(localized: "Waiting for Noop Band") : String(localized: "Noop Band not connected")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(0)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                if isLive {
                    // A gentle heartbeat dot that pulses with each incoming sample.
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(beat ? 1.35 : 0.85)
                        .opacity(beat ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .padding(.trailing, 2)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.caption))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                }
            }
            if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated)
                HStack {
                    stat(String(localized: "Min"), series.min())
                    Spacer()
                    stat(String(localized: "Avg"), series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat(String(localized: "Max"), series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect Noop Band to see live heart rate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

extension LiquidTodayView {
    /// What the strap-battery ring can honestly say, resolved from the three live signals it has.
    /// Pure + static so the truth table is testable with no strap (`LiquidBatteryDisplayTests`).
    ///
    /// The three signals are INDEPENDENT and land separately, which is the whole reason this exists:
    ///  • `connected` — the CoreBluetooth link.
    ///  • `batteryPct` — standard 0x2A19 (5/MG) or the GET_BATTERY_LEVEL response (4.0).
    ///  • `charging` — a different source entirely: the strap's BATTERY_LEVEL event (~every 8 min),
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only - battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up - Liquid parity with classic
    /// `TodayView.effortZeroNote`). Pure + static so the gate is testable with no view: the note shows
    /// ONLY for today when a strain value exists and is ~0 — a genuinely calm day reads near zero, while a
    /// no-data day shows its own ring overlay and a past day is never annotated. Liquid reads
    /// `displayDay?.strain` directly (it has no live-strain accumulator like classic's `liveTodayStrain`),
    /// which is exactly the value its Effort hero draws.
    enum EffortDisplay {
        static func showsZeroNote(strain: Double?, isToday: Bool) -> Bool {
            guard isToday, let s = strain else { return false }
            return s < 1.0
        }
    }

    /// (A3/B2, docs/bugs/2026-07-15-strap-battery-backfill-observability.md)
    enum StrapBatteryDisplay: Equatable {
        /// No link — say nothing about charge. A stale % is worse than no %.
        case offline
        /// Linked, but no charge reading has landed yet. `charging` is still knowable on its own.
        case pending(charging: Bool)
        /// A reading from the current link.
        case charge(pct: Double, charging: Bool)

        static func resolve(connected: Bool, batteryPct: Double?, charging: Bool?) -> StrapBatteryDisplay {
            guard connected else { return .offline }
            guard let pct = batteryPct else { return .pending(charging: charging == true) }
            return .charge(pct: pct, charging: charging == true)
        }

        /// A charger is drawn as a bolt inside a battery, never as a detached bolt that discards the
        /// battery context. Percentage text beside the symbol still carries the exact level.
        var symbolName: String {
            if isCharging { return "battery.100.bolt" }
            return levelSymbolName
        }

        var isCharging: Bool {
            switch self {
            case .pending(charging: true), .charge(_, charging: true):
                return true
            case .offline, .pending(charging: false), .charge(_, charging: false):
                return false
            }
        }

        /// The level silhouette stays truthful while charging; the view overlays the bolt at a size that
        /// remains legible in the compact masthead control.
        var levelSymbolName: String {
            switch self {
            case .offline, .pending(charging: false):
                return "battery.0percent"
            case .pending(charging: true):
                return "battery.100percent"
            case .charge(let pct, _):
                switch pct {
                case 87.5...: return "battery.100percent"
                case 62.5...: return "battery.75percent"
                case 37.5...: return "battery.50percent"
                case 12.5...: return "battery.25percent"
                default:      return "battery.0percent"
                }
            }
        }
    }

    /// What the Charge hero can honestly say for the selected day. Pure + static so the truth table is
    /// testable with no clock and no view (`LiquidChargeCarryTests`).
    ///
    /// See `LiquidChargeCarryTests` for the regression this closes: Liquid read `displayDay?.recovery`
    /// raw, so after the 04:00 rollover — or on any day with no scored night — Charge blanked while the
    /// Rest hero (`freshRestScore`) and the vitals (`Repository.lastVitalsDay`) carried right beside it,
    /// and the widget/watch/Live Activity (`Repository.widgetAnchor`, #911) all showed a number.
    ///
    /// The SELECTION is not re-implemented here: callers pass the row `TodayView.lastScoredRecoveryDay`
    /// picked (its #547 future-day guard included) and the caption comes from `TodayView.carriedCaption`,
    /// so the two Today screens cannot drift apart.
    enum ChargeDisplay: Equatable {
        /// The selected day scored its own Charge.
        case scored(pct: Double)
        /// No score for the selected day; showing a REAL prior night's, stamped with whose it is.
        case carried(pct: Double, caption: String)
        /// Pre-seed-gate: the baseline is still learning and owns its own "N of 4 nights" copy.
        case calibrating(nights: Int)
        /// The displayed night completed the seed window, but cannot score against itself.
        case baselineReady
        /// Nothing honest to show — no score, no prior night, and not calibrating.
        case noData

        /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
        /// prior value; the empty states draw nothing rather than a fabricated zero.
        var pct: Double? {
            switch self {
            case .scored(let p): return p
            case .carried(let p, _): return p
            case .calibrating, .baselineReady, .noData: return nil
            }
        }

        /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
        /// `fixedSize`, so it stays SHORT - the carried day's full "Last night · <date>" stamp lives in
        /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
        /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
        /// trusted wearer who simply hadn't worn the strap that night.
        var stateLabel: String {
            switch self {
            case .scored: return String(localized: "Solid")
            case .carried: return String(localized: "Last night")
            case .calibrating: return String(localized: "Calibrating")
            case .baselineReady: return String(localized: "Baseline ready")
            case .noData: return String(localized: "No data")
            }
        }

        /// The synthesis-card detail line while the baseline is forming or has just completed its seed
        /// window. Reuses classic Today's complete localized phrases so the default Liquid Today cannot
        /// drift into generic "nights" copy or call the fourth valid HRV night calibrating.
        var calibrationDetail: String? {
            let required = Baselines.minNightsSeed
            switch self {
            case .calibrating(let nights):
                return String(localized: "Learning your baseline, \(nights) of \(required) valid HRV nights.")
            case .baselineReady:
                return String(localized: "\(required) of \(required) valid HRV nights complete. The next qualifying night can produce your first Recovery.")
            default:
                return nil
            }
        }

        /// Bounded learning progress for the liquid vessel. The score remains nil: a half-filled
        /// vessel means "2 of 4 calibration nights", never a fabricated 50% Recovery.
        var calibrationFraction: Double? {
            let required = max(1, Baselines.minNightsSeed)
            switch self {
            case .calibrating(let nights):
                return Double(max(0, min(nights, required))) / Double(required)
            case .baselineReady:
                return 1
            default:
                return nil
            }
        }

        /// Complete localized hero caption. Never stitches a translated number onto an English "nights".
        var calibrationCaption: String? {
            let required = max(1, Baselines.minNightsSeed)
            switch self {
            case .calibrating(let nights):
                let completed = max(0, min(nights, required))
                return String(localized: "Valid HRV \(completed)/\(required)")
            case .baselineReady:
                return String(localized: "Baseline ready")
            default:
                return nil
            }
        }

        @MainActor
        static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                            calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
            if let pct = todayRecovery { return .scored(pct: pct) }
            // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
            // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
            if let n = calibrationNights {
                return n >= Baselines.minNightsSeed
                    ? .baselineReady
                    : .calibrating(nights: max(0, n))
            }
            // `lastScoredRecoveryDay` only ever selects a row whose recovery is non-nil, so the second bind
            // is belt-and-suspenders: a nil falls through to noData rather than fabricating a carry.
            guard let prior = priorScored, let pct = prior.recovery else { return .noData }
            return .carried(pct: pct,
                            caption: TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
        }
    }
}

/// Compact strap-battery status. Owns LiveState. Tap → Devices.
///
/// "Charge" is NOOP's physiological recovery score, so this utility deliberately says BAND and shows a
/// battery percentage. That keeps hardware charge in the masthead without conflating it with Daily Signal.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter
    private var display: LiquidTodayView.StrapBatteryDisplay {
        .resolve(connected: live.connected, batteryPct: live.batteryPct, charging: live.charging)
    }
    var body: some View {
        Button { router.openDevices() } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [StrandPalette.surfaceRaised.opacity(0.92),
                                     StrandPalette.surfaceOverlay.opacity(0.74)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [StrandPalette.hairlineStrong.opacity(0.82),
                                     StrandPalette.hairline.opacity(0.52)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                HStack(spacing: 5) {
                    batteryIcon
                    VStack(alignment: .leading, spacing: -1) {
                        Text(verbatim: "NOOP")
                            .font(.system(size: 6, weight: .bold))
                            .tracking(0)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(batteryValue)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(batteryValueColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(width: 70, height: 34)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(batteryAccessibility)
        .accessibilityIdentifier("noop.today.band-battery")
        .help("Band battery")
    }

    @ViewBuilder
    private var batteryIcon: some View {
        ZStack {
            Image(systemName: display.levelSymbolName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(batteryIconColor)
            if display.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.82), radius: 0.6)
            }
        }
        .frame(width: 16, height: 14)
    }

    private var batteryValue: String {
        switch display {
        case .charge(let pct, _):
            return "\(Int(pct.rounded()))%"
        case .pending(let charging):
            return charging ? "CHG" : "SYNC"
        case .offline:
            return "OFF"
        }
    }

    private var batteryValueColor: Color {
        switch display {
        case .charge(let pct, let charging):
            return charging ? StrandPalette.chargeColor : ringColor(pct)
        case .pending(let charging):
            return charging ? StrandPalette.chargeColor : StrandPalette.textSecondary
        case .offline:
            return StrandPalette.textTertiary
        }
    }

    private var batteryIconColor: Color {
        switch display {
        case .charge(let pct, let charging):
            return charging ? StrandPalette.chargeColor : ringColor(pct)
        case .pending(let charging):
            return charging ? StrandPalette.chargeColor : StrandPalette.textSecondary
        case .offline:
            return StrandPalette.textTertiary
        }
    }
    /// Never "Strap battery" alone for a no-reading state - that was indistinguishable from a real one.
    private var batteryAccessibility: String {
        switch display {
        case .offline:
            return String(localized: "Noop Band battery, band not connected")
        case .pending(let charging):
            return charging
                ? String(localized: "Noop Band battery charging, no reading yet")
                : String(localized: "Noop Band battery, no reading yet")
        case .charge(let pct, let charging):
            let n = Int(pct.rounded())
            return charging
                ? String(localized: "Noop Band battery \(n) percent, charging")
                : String(localized: "Noop Band battery \(n) percent")
        }
    }
    private func ringColor(_ p: Double) -> Color {
        p < 15 ? StrandPalette.statusCritical : p < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }
}

/// Strap-history sync state inside the Data Sources card. Owns LiveState; display-only.
///
/// B1 (docs/bugs/2026-07-15-strap-battery-backfill-observability.md): the v8 Liquid redesign shipped no
/// backfill indication AT ALL, so on the iOS default Today a multi-hour history recovery was completely
/// invisible — the wearer could not tell a working strap mid-drain from a dead one. The classic
/// `TodayView` has always had this (`SyncStatusChip`), as do the Mac Sleep/Intelligence screens and the
/// menu bar (`SyncingHistoryNote`); Liquid simply dropped it. Same class of regression as #992, which
/// dropped the "~X days left" runtime estimate from the row directly above this one.
///
/// The protocol does not expose a reliable total, so this never invents a percentage or ETA. It shows
/// acknowledged batches, rows durably stored, and the newest usable timestamp that has landed so the
/// wearer can distinguish a long moving backlog from a stalled spinner.
private struct LiquidSyncStatusRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.backfilling {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 4) {
                    row(
                        String(localized: "Noop Band history"),
                        value: batches,
                        tone: StrandPalette.accent
                    )
                    Text(activityDetail(now: context.date.timeIntervalSince1970))
                        .font(StrandFont.caption)
                        .foregroundStyle(activityTone(now: context.date.timeIntervalSince1970))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(persistedDetail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let ts = live.lastSyncedAt {
            row(String(localized: "Noop Band history"),
                value: String(localized: "Synced \(relativeAgo(ts)) ago"), tone: StrandPalette.textPrimary)
        }
    }

    private var batches: String {
        String.localizedStringWithFormat(
            String(localized: "appwide.today.band_sync.batches_format"),
            Int64(live.syncChunksThisSession)
        )
    }

    private func activityDetail(now: TimeInterval) -> String {
        let activity: String
        switch HistorySyncDurableProgressPolicy.activity(
            startedAt: live.historySyncStartedAt,
            lastDurableProgressAt: live.historySyncLastDurableProgressAt,
            now: now
        ) {
        case .starting:
            activity = String(localized: "appwide.today.band_sync.activity_starting")
        case .advancing:
            activity = String(localized: "appwide.today.band_sync.activity_advancing")
        case .waiting:
            activity = String(localized: "appwide.today.band_sync.activity_waiting")
        case .stalled:
            activity = String(localized: "appwide.today.band_sync.activity_stalled")
        }
        let elapsed = String.localizedStringWithFormat(
            String(localized: "appwide.today.band_sync.elapsed_format"),
            historySyncElapsedClock(startedAt: live.historySyncStartedAt, now: now)
        )
        return activity + " · " + elapsed
    }

    private func activityTone(now: TimeInterval) -> Color {
        switch HistorySyncDurableProgressPolicy.activity(
            startedAt: live.historySyncStartedAt,
            lastDurableProgressAt: live.historySyncLastDurableProgressAt,
            now: now
        ) {
        case .starting, .advancing: return StrandPalette.statusPositive
        case .waiting: return StrandPalette.statusWarning
        case .stalled: return StrandPalette.statusCritical
        }
    }

    private var persistedDetail: String {
        let progress = live.historySyncProgress
        guard let newest = progress.newestDataUnix else {
            return String.localizedStringWithFormat(
                String(localized: "appwide.today.band_sync.rows_format"),
                Int64(progress.rowsPersisted)
            )
        }
        let date = Date(timeIntervalSince1970: TimeInterval(newest))
            .formatted(.dateTime.year().month(.abbreviated).day())
        return String.localizedStringWithFormat(
            String(localized: "appwide.today.band_sync.rows_ready_format"),
            Int64(progress.rowsPersisted),
            date
        )
    }

    private func row(_ label: String, value: String, tone: Color) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.subhead).foregroundStyle(tone)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Noop Band battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · Charging" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// Reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only ever shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}

// MARK: - #5 (perf): stable row identity for workout lists
//
// `ForEach(_:id:)` needs an identity that survives a refetch. Using the array INDEX meant any re-order or
// insert re-identified every row after it, forcing SwiftUI to rebuild those cards (churn on refresh).
// startTs + source + sport is unique per session in practice and stable across refetches.
extension WorkoutRow {
    var workoutRowIdentity: String { "\(startTs)|\(source)|\(sport)" }
}
