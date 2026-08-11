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

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    // For the pull-to-sync gesture (#334): a pull kicks a manual strap history offload via ble.syncNow().
    // Observe BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it
    // would re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager
    // only publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
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
    @State private var importedStepsDay: Int?      // Apple Health steps for the selected day (middle tier)
    @State private var importedActiveKcalDay: Double?  // #616: Apple Health active energy for the day (calorie fallback)
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

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    // #today-layout (parity with Android): the user-chosen section order, persisted under the byte-identical
    // "today.sectionOrder" key the Android TodayLayoutPrefs uses. Reordered via the Arrange sheet (native
    // drag-to-reorder rows); every section always renders (decode inserts a missing one at its default spot).
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @State private var showArrangeSheet = false
    private var sectionOrder: [TodaySection] { TodayLayoutPrefs.decodeOrder(sectionOrderRaw) }
    // #430 parity: the Key-Metrics grid honours the SAME editor selection/order + Detailed-tiles switch as
    // Android (byte-identical @AppStorage keys). `kSparks` holds the trailing-14-day series the detailed
    // tiles graph (keyed by metric-catalog key), filled by the loader alongside everything else.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    /// The detailed graphs' trailing window — 2 days / 1 week / 2 weeks (shared key with Android). The
    /// loader banks a day-keyed 14-day superset; render filters down, so a window change applies instantly.
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @State private var showKeyMetricsEditor = false
    @State private var kSparks: [String: [(String, Double)]] = [:]
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load() alongside
    /// the other caches. It composes `TodayView.lastScoredRecoveryDay`, which is O(days) — exactly the scan
    /// this cache exists to keep out of body. Never resolved in body.
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = Color(.sRGB, red: 13 / 255, green: 14 / 255, blue: 20 / 255, opacity: 0.80)
    /// "Card transparency" (0–100, default 100): fades every liquid card surface here — the hero, the
    /// session-start row, the metric tiles and the `card` helper — in lockstep with the frosted cards.
    /// Content sits above the surface so it stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }
    /// "Background behind cards" (default ON): extend the obsidian field behind the WHOLE scroll so the
    /// Card-transparency slider reveals it under every card. The persisted key remains cross-platform.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
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
        // #1013: these must localize — the header showed English "Today"/"Yesterday"/weekday even when the
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
    private static let topAnchorID = "liquidToday.top"
    private static let bottomAnchorID = "liquidToday.bottom"
    private static let patternsAnchorID = "liquidToday.patterns"

    var body: some View {
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

                VStack(alignment: .leading, spacing: 12) {
                    scene
                    // A raised illness/strain warning must remain visible on the default Today surface.
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
                        case .synthesis: synthesisSection
                        case .keyMetrics: keyMetricsSection
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
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
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
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)-\(profile.ageMetricStateToken)") {
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
            if CommandLine.arguments.contains("--demo-patterns") {
                proxy.scrollTo(Self.patternsAnchorID, anchor: .center)
            } else if CommandLine.arguments.contains("--demo-scroll-bottom") {
                // Simulator-only layout proof for the custom (non-ScreenScaffold) Today scroll.
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
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
                SettingsView()
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
                               liquidHeart: liquidHeart)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        if pullY >= pullThreshold, !refreshArmed {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                // #334 (iOS twin of Android #426): a pull requests a fresh strap history offload, not just
                // a UI reload. syncNow() is internally gated (connected + bonded + not-already-backfilling),
                // so a pull while disconnected or mid-offload safely no-ops. The sync status chip owns the
                // ongoing offload progress; the pull spinner stays short (the reload below).
                ble.syncNow()
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
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
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 34)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                    // #today-layout: opens the Arrange sheet (drag rows to reorder the Today sections).
                    Button { showArrangeSheet = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(StrandPalette.surfaceRaised.opacity(0.82)))
                            .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong.opacity(0.72), lineWidth: 1))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Arrange Today sections")
                }
            }

            Button { showDayPicker = true } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(dayTitle)
                        .font(StrandFont.rounded(34))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(dateLine)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    /// One-tap Live Session start (silent guardian, beta) — sits directly under the hero scores, the
    /// Charge its band is gated on. Same translucent chrome as the hero card so it reads as part of the
    /// sky scene, quiet by design.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                // The session-start row shares the hero card's pinned-dark `heroFill`, so its text/chevron
                // use the on-dark tokens — textPrimary/Secondary/Tertiary flip to dark ink in Light mode and
                // went dark-on-near-black here too (#1013).
                Text("Start session")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(.white.opacity(0.05))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.onDarkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
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
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Recovery.")
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                    .accessibilityHidden(true)
                Text("DAILY SIGNAL")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                Spacer(minLength: NoopMetrics.space2)
                if let sourceLabel = heroSourceLabel {
                    SourceBadge("\(sourceLabel)", tint: StrandPalette.onDarkSecondary)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityLabel(Text("Source: \(sourceLabel)"))
                }
            }

            HStack(alignment: .top, spacing: NoopMetrics.space1) {
                // #543 carry: an unscored today shows the last scored night's REAL Charge (labelled as prior by
                // the state pill) rather than an empty vessel, matching the classic Today, the widget/watch/Live
                // Activity (`Repository.widgetAnchor`) and Android. Effort deliberately does NOT carry — it is
                // today's own accumulation, so yesterday's number would be a false statement, not a stale one.
                HeroScoreCell(label: String(localized: "Recovery"), score: chargeDisplay.pct, tint: StrandPalette.chargeColor,
                              animated: dataLoaded,
                              onOpen: { openHeroMetric("recovery") },
                              onExplain: { explainHeroMetric("recovery") },
                              fillFraction: chargeDisplay.calibrationFraction,
                              emptyText: chargeDisplay.calibrationCompactText ?? "–",
                              accessibilityValueOverride: chargeDisplay.calibrationDetail)
                // #45: the hero Effort must honour the user's Effort scale like every other Effort read-out.
                HeroScoreCell(label: String(localized: "Effort"),
                              score: displayDay?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) },
                              tint: StrandPalette.effortColor, animated: dataLoaded,
                              onOpen: { openHeroMetric("strain") },
                              onExplain: { explainHeroMetric("strain") },
                              maxValue: effortScale == .whoop ? 21 : 100,
                              decimals: effortScale == .whoop ? 1 : 0)
                HeroScoreCell(label: String(localized: "Sleep"), score: restScore, tint: StrandPalette.restColor,
                              animated: dataLoaded,
                              onOpen: { openHeroMetric("sleep_performance") },
                              onExplain: { explainHeroMetric("sleep_performance") })
            }

            // Fitness Age is intentionally a compact long-term lane, not a fourth daily score. It only
            // appears on Today: `fitnessAge` is the latest WEEKLY estimate across history, so showing it
            // while browsing an older day would leak a future value into that day's card.
            if selectedDayOffset == 0 {
                Divider().overlay(StrandPalette.onDarkSecondary.opacity(0.20))
                FitnessAgeHeroRow(
                    age: visibleFitnessAge,
                    profileAge: profile.age,
                    onOpen: { openHeroMetric("fitness_age") },
                    onExplain: { explainHeroMetric("fitness_age") }
                )
            }
        }
        .padding(.vertical, NoopMetrics.space4)
        .padding(.horizontal, NoopMetrics.space3)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(heroFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    StrandPalette.chargeColor.opacity(0.045),
                                    StrandPalette.effortColor.opacity(0.025),
                                    StrandPalette.restColor.opacity(0.045),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.055), .clear, .black.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.22), .white.opacity(0.06), .black.opacity(0.86)],
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
                Text("YOUR CARDS").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { showCustomise = true } label: {
                    // #492 item 4 parity: unify the Your Cards / Key Metrics edit affordance to "EDIT" across
                    // platforms (Android #563). Reuse the localized "Edit" key, uppercased at display, so this
                    // stays translated (BEARBEITEN / MODIFIER / …) without a new literal.
                    Text(String(localized: "Edit").uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
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

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
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
                     value: unitText(visibleFitnessAge, card.unit), symbol: card.icon,
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
            // Route by the EXACT (key, source) the tile chose to display — measured my-whoop, imported
            // apple-health, or the my-whoop estimate — NOT by bare key (bare "steps" resolves to
            // apple-health and would mismatch a WHOOP-measured value). Order-independent.
            cardLink(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), title: card.title, sub: card.subtitle,
                     value: stepsText, symbol: card.icon,
                     tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // Not wired to a real read yet — render EMPTY (not half-full) so it doesn't imply a reading.
            cardLink(.metric("spo2"), title: card.title, sub: card.subtitle,
                     value: "–", symbol: card.icon, tint: StrandPalette.metricCyan, frac: nil)
        case .skinTemp:
            cardLink(.metric("skin_temp"), title: card.title, sub: card.subtitle,
                     value: "–", symbol: card.icon, tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            // #616: show the resolved imported-first value and route to the matching detail source, like
            // the Steps card — was a "–" placeholder wired to the imported-only detail.
            cardLink(.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource), title: card.title, sub: card.subtitle,
                     value: intText(caloriesCount), symbol: card.icon,
                     tint: StrandPalette.metricAmber, frac: fracOver(caloriesCount, 800))
        case .sleep:
            cardLink(.sleep, title: card.title, sub: card.subtitle,
                     value: sleepText, symbol: card.icon,
                     tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardLink(.hydration, title: card.title, sub: card.subtitle,
                     value: hydrationGoalML.map {
                         HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                     } ?? "—",
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
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
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
                card {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .frame(width: 34, height: 34)
                            .background(StrandPalette.chargeColor.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text("DAILY BRIEF")
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text(greeting)
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
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: NoopMetrics.space2) {
                        if let word = readinessWord {
                            Text(word)
                                .font(StrandFont.caption.weight(.bold))
                                .foregroundStyle(StrandPalette.chargeColor)
                                .padding(.horizontal, NoopMetrics.space3)
                                .padding(.vertical, NoopMetrics.space2)
                                .background(Capsule().fill(StrandPalette.chargeColor.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1)))
                        }
                        HStack(spacing: NoopMetrics.space1) {
                            Circle().fill(StrandPalette.chargeColor).frame(width: 6, height: 6)
                            Text(chargeDisplay.stateLabel)
                                .font(StrandFont.caption.weight(.bold))
                                .foregroundStyle(StrandPalette.chargeColor)
                        }
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1))
                        Spacer(minLength: 0)
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
                        Divider().overlay(StrandPalette.hairline)
                        Text(LocalizedStringKey(readiness.summary))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityHint(synthesisExpanded ? "Collapse daily brief" : "Expand daily brief")

            // Current-state inference only. Historical browsing intentionally omits this card: the
            // illness snapshot is live/latest and must never be projected backward onto a past day.
            if selectedDayOffset == 0 {
                TodaySignalPatternsCard(readiness: readiness, restScore: restScore)
                    .id(Self.patternsAnchorID)
            }
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
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(1.6)
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

    /// The chosen detailed-graph window's oldest day key (2 days / 1 week / 2 weeks ending on the
    /// selected day). The loader banks a 14-day superset; render filters down so a window change in the
    /// editor applies instantly, no reload.
    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 2 || keyMetricsWindowDays == 7) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    /// A metric's spark values inside the chosen window, oldest → newest.
    private func windowedSpark(_ key: String) -> [Double] {
        let cutoff = sparkWindowCutoffKey
        return (kSparks[key] ?? []).filter { $0.0 >= cutoff }.map { $0.1 }
    }

    /// The Key-Metrics header's trailing label for the chosen detailed-graph window (Android twin).
    private var trendWindowLabel: String {
        switch keyMetricsWindowDays {
        case 2: return String(localized: "2-day trend")
        case 7: return String(localized: "7-day trend")
        default: return String(localized: "14-day trend")
        }
    }

    private var keyMetricsSection: some View {
        // HRV / Resting HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Recovery/Strain/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHead("KEY METRICS", trailing: trendWindowLabel)
                // #430 parity: the SAME editor the classic grid uses — selection + order + Detailed tiles.
                Button { showKeyMetricsEditor = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Key Metrics")
            }
            // #430 parity: the grid honours the Key-Metrics editor (selection + order, all ten metrics)
            // instead of a hard-coded six — the bespoke Sleep-hours ktile gives way to the shared REST
            // score tile, aligning the liquid grid with the classic macOS grid and Android.
            // Two columns give values, units and trends enough room to breathe on a phone. Three columns
            // made long labels and five-digit values compete for the same narrow sliver, which looked
            // like a diagnostic table rather than a premium daily dashboard.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space3), count: 2),
                spacing: NoopMetrics.space3
            ) {
                ForEach(enabledKeyMetrics) { metric in
                    ktileFor(metric, hrv: hrv, rhr: rhr)
                }
            }
            NavigationLink(value: TabRoute.metricExplorer) {
                Text("Show all metrics").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity).padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    /// One editor-selected Key-Metric tile: the metric's value/tint/fill exactly as the old hard-coded
    /// tiles read them (Android's descriptor map is the twin), plus the metric-catalog `key` that names
    /// both its 14-day spark series and its tap-through detail. Weight has no liquid value source yet —
    /// its tile reads "—" but still taps through to the weight trend detail (which has its own series).
    @ViewBuilder
    private func ktileFor(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge the hero draws, not `displayDay?.recovery` raw — the tile and the
            // hero are the same number, so a carry that reached only one of them would put two answers for
            // Charge on one screen. (#543: one prior row feeds every recovery-derived read-out.) Strain below
            // stays raw, matching the Effort hero, which correctly does not carry.
            ktile(String(localized: "Recovery"), intText(chargeDisplay.pct), "%", StrandPalette.chargeColor,
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
                  frac(restScore), symbol: metric.icon, key: "sleep_performance")
        case .hrv:
            ktile("HRV", intText(hrv), "ms", StrandPalette.metricCyan, nil,
                  symbol: metric.icon, key: "hrv")
        case .restingHr:
            ktile(String(localized: "Resting HR"), intText(rhr), "bpm", StrandPalette.metricRose, nil,
                  symbol: metric.icon, key: "rhr")
        case .bloodOxygen:
            let spo2 = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            ktile(String(localized: "Blood Oxygen"), intText(spo2), "%", StrandPalette.metricCyan, nil,
                  symbol: metric.icon, key: "spo2")
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
            ktile(String(localized: "Respiratory"), resp.map { String(format: "%.1f", $0) } ?? "—",
                  "rpm", StrandPalette.accent, nil, symbol: metric.icon, key: "resp_rate")
        case .steps:
            ktile(String(localized: "Steps"), stepsText, "", StrandPalette.chargeColor,
                  nil, symbol: metric.icon, key: stepsDetailKey,
                  detailMetric: stepsDetailMetric)
        case .weight:
            ktile(String(localized: "Weight"), "—", "", StrandPalette.metricAmber, nil,
                  symbol: metric.icon, key: "weight")
        case .calories:
            // #616: imported-first value (imported ?: activeKcalEst) + route the tap to the matching
            // detail source, so the number, its sparkline and the chart it opens all agree.
            ktile(String(localized: "Calories"), intText(caloriesCount), "kcal", StrandPalette.metricAmber,
                  nil, symbol: metric.icon, key: "energy_kcal",
                  detailMetric: caloriesDetailMetric)
        }
    }

    private func ktile(_ label: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?,
                       symbol: String, key: String? = nil,
                       detailMetric: MetricDescriptor? = nil) -> some View {
        let tile = VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                MetricGlyph(symbol, size: 28)
                Text(label.uppercased())
                    .font(StrandFont.overlineScaled(9.5))
                    .tracking(1.1)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            (Text(value).font(StrandFont.number(24))
                + Text(unit.isEmpty ? "" : " \(unit)").font(StrandFont.subhead))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let frac {
                // Only real bounded scores earn a progress rail. Raw vital signs use their value and
                // optional trend below; normalizing RHR/HRV/respiration to arbitrary maxima makes a
                // fuller bar look "better" when it is not a health-goal scale.
                LiquidTube(frac: frac, tint: tint, height: 7, animated: false)
                    .accessibilityHidden(true)
            } else {
                // Preserve the two-column baseline without drawing a fake zero/progress sliver.
                Color.clear.frame(height: 7).accessibilityHidden(true)
            }
            // #430 parity: DETAILED tiles grow the trend graph under the bar, tinted to the metric and
            // windowed to the editor's 2-day / 1-week / 2-week choice (the Android twin). A metric with no
            // windowed series keeps a clear placeholder of the same height so every tile in a detailed row
            // stays equal-height with its bars aligned.
            if keyMetricsDetailed {
                let spark = key.map { windowedSpark($0) } ?? []
                if spark.count >= 2 {
                    Sparkline(values: spark,
                              gradient: Gradient(colors: [tint.opacity(0.5), tint]))
                        .frame(height: 22)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: 22).padding(.top, 6)
                }
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Last workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: 8) {
            sectionHead("LAST WORKOUTS", trailing: "\(workouts.count) total")
            if let w = workouts.first {
                NavigationLink(value: TabRoute.workouts) { workoutCard(w) }
                    .buttonStyle(LiquidPressStyle())
            } else {
                card {
                    Text("No workouts yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
                .tracking(1.6)
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
                FrostedCardSurface(cornerRadius: 22)
            )
    }

    // MARK: - Data

    private func load() async {
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        // Always anchor to the day the UI is actually showing. Passing `day?.day` turned a missing
        // current row into nil, which asks ReadinessEngine to fall back to the newest stored row — so a
        // stale import could masquerade as today's pattern. An explicit absent key correctly yields
        // `.insufficient`.
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: selectedDayKey)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        cachedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: tkey,
                                                         isToday: selectedDayOffset == 0,
                                                         todayScored: day?.recovery != nil,
                                                         isCalibrating: calNights != nil),
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let fitProfileA = repo.exploreSeries(
            key: AgeMetricProfile.fitnessAgeKey, source: "my-whoop")
        async let vitProfileA = repo.exploreSeries(
            key: AgeMetricProfile.vitalityKey, source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()
        // Ask the same cross-source resolver the Classic Today view uses which source actually won each
        // displayed score. Limit the read to the selected-day window instead of scanning full history.
        let sourceDayKey = selectedDayKey
        let sourceLookback = max(2, selectedDayOffset + 2)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      days: sourceLookback)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      days: sourceLookback)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    days: sourceLookback)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days

        // #430 parity: the day-keyed series the DETAILED Key-Metrics tiles graph — a trailing CALENDAR
        // window ending on the selected day (not the last-N stored rows, which on an old import showed
        // months-old data as a fresh trend, issue #23). The loader banks the 14-day SUPERSET; the chosen
        // 2-day/1-week/2-week window filters at render (windowedSpark), so a picker change applies without
        // a reload. Keys mirror the metric catalog so a tile's graph, its tap-through detail and Android's
        // Window all read the same signal. Rest reuses the already-loaded sleep_performance series.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -13, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        // #616: imported-first calorie spark (the day's imported Apple active energy ?: NOOP's on-device
        // estimate) over the window, so a Health-Connect / Apple-only calorie user gets a trend too —
        // matching the imported-first VALUE. Union of imported days + strap-row days. Mirrors Android's
        // caloriesSpark (windowed caloriesByDay).
        let appleRowsForSpark = await appleA
        var winImportedKcal: [String: Double] = [:]
        for r in appleRowsForSpark where r.day >= sparkCutoff && r.day <= selectedDayKey {
            if let k = r.activeKcal { winImportedKcal[r.day] = max(winImportedKcal[r.day] ?? 0, k) }
        }
        var winOnDeviceKcal: [String: Double] = [:]
        for r in sparkRows { if let k = r.activeKcalEst { winOnDeviceKcal[r.day] = k } }
        let energyKcalSpark: [(String, Double)] = Set(winImportedKcal.keys).union(winOnDeviceKcal.keys).sorted()
            .compactMap { day in (winImportedKcal[day] ?? winOnDeviceKcal[day]).map { (day, $0) } }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            // #616: the Calories tile drew no trend line — this dict had no matching entry, so windowedSpark
            // returned []. Bank the imported-first calorie series (built above) so the sparkline matches the
            // tile's imported-first number and a Health-Connect / Apple-only user gets a trend.
            "energy_kcal": energyKcalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
        ]
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        let fitProfile = (await fitProfileA).last?.value
        let vitProfile = (await vitProfileA).last?.value
        fitnessAge = profile.acceptsFitnessAge(provenance: fitProfile)
            ? (await fitA).last?.value : nil   // history-wide latest banked (not day-scoped)
        vitality = profile.acceptsVitality(provenance: vitProfile) ? (await vitA).last?.value : nil
        ageMetricsLoadedProfileState = profile.ageMetricStateToken
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        // #616: same-day imported active energy — the calorie fallback when the strap banked no on-device
        // HR estimate for the day, so the tile/card/detail agree (imported-first, mirrors steps).
        importedActiveKcalDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()
        hrValues = (await hrA).map { $0.bpm }
        workouts = await wkA

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var provenance: [String: String] = [:]
        for (metric, resolution) in sourceResolutions {
            if let winner = resolution.points.last(where: { $0.day == sourceDayKey })?.source {
                provenance[metric] = winner
            }
        }
        heroProvenanceByMetric = provenance

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: selectedDayKey)
    }

    /// One card-level provenance label. Identical winners collapse to one name; mixed scores show at most
    /// two distinct winners in Charge / Effort / Rest order so the compact badge stays readable.
    private var heroSourceLabel: String? {
        Self.heroSourceLabel(
            rawSources: ["recovery", "strain", "sleep_performance"].compactMap { heroProvenanceByMetric[$0] },
            deviceId: repo.deviceId)
    }

    /// Pure aggregation seam for the Liquid hero. The existing Today mapper turns computed siblings into
    /// "On-device", the Apple Health source into "Apple Watch", and imported strap rows into "Whoop".
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

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return String(localized: "Push")
        case .balanced: return String(localized: "Maintain")
        case .strained, .rundown: return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // #612: when still calibrating BECAUSE the strap stopped delivering nights (connected, but no new
        // night for > staleDays), say so directly instead of "still learning your baseline" — the honest
        // calibrating state with its reason attached. `stale` is always > staleDays (14), so always plural.
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from your strap for \(stale) days. Check it's connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "You're primed. A hard session should land well today.")
        case .balanced: return String(localized: "You're in a good spot for training.")
        case .strained: return String(localized: "Signals are down a touch. Keep it easy today.")
        case .rundown: return String(localized: "Several recovery signals are down. Prioritise rest today.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
    }

    // Measured strap count ?: imported Apple Health count ?: motion estimate — the same precedence the
    // detail routing follows below, so the tapped-through source always matches the number shown (#377).
    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    // #616: calories resolved IMPORTED-FIRST (the day's imported Apple active energy — the figure these
    // surfaces already showed — else NOOP's on-device HR estimate `activeKcalEst`) — one number across the
    // tile, card and the detail it taps to. Mirrors the steps precedence above.
    private var caloriesCount: Double? {
        importedActiveKcalDay ?? displayDay?.activeKcalEst
    }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayCaloriesMetric(hasImportedKcal: importedActiveKcalDay != nil,
                                          hasOnDeviceKcal: displayDay?.activeKcalEst != nil)
    }

    private var caloriesDetailKey: String { caloriesDetailMetric?.key ?? "energy_kcal" }
    private var caloriesDetailSource: String { caloriesDetailMetric?.source ?? "my-whoop" }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

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
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
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
                headline: "Run down",
                summary: "Several signals shifted.",
                signals: [
                    .init(key: "hrv", label: "HRV", evidence: "52 vs 68 ms",
                          detail: "below your usual range", flag: .bad),
                    .init(key: "rhr", label: "Resting HR", evidence: "61 vs 54 bpm",
                          detail: "above your usual range", flag: .bad),
                    .init(key: "acwr", label: "Recent-load ratio", evidence: "7d 14.8 / 28d 9.5",
                          detail: "7-day mean is 1.56x the 28-day mean", flag: .neutral),
                ],
                acwr: 1.56,
                monotony: nil
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
                            .tracking(0.8)
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
                        title: "SIGNALS",
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 7) {
                ZStack {
                    LiquidVessel(value: frac, tint: tint, animated: animated)
                        .frame(width: Self.vesselDiameter, height: Self.vesselDiameter)
                    Group {
                        if score != nil {
                            CountUpNumber(value: shown, font: StrandFont.rounded(26), decimals: decimals)
                        } else {
                            Text(emptyText).font(StrandFont.rounded(emptyText == "–" ? 26 : 19))
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsHitTesting(false)
                }
                HStack(spacing: 3) {
                    // #74: one line, shrink-to-fit rather than wrap under large Dynamic Type (mirrors
                    // the score number above) so labels never grow the hero card to two lines.
                    Text(label.uppercased()).font(StrandFont.overline).tracking(1.6)
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
            .accessibilityValue(Text(accessibilityValueOverride ?? score.map {
                decimals > 0 ? String(format: "%.\(decimals)f of %.0f", $0, maxValue)
                    : String(localized: "\(Int($0.rounded())) of \(Int(maxValue.rounded()))")
            } ?? String(localized: "No data yet")))
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

/// The long-term lane under Daily Signal. Fitness Age is deliberately not rendered as a fourth equal
/// score: it updates weekly and estimates cardiorespiratory fitness rather than today's readiness.
private struct FitnessAgeHeroRow: View {
    let age: Double?
    let profileAge: Int
    let onOpen: () -> Void
    let onExplain: () -> Void

    private var valueText: String {
        age.map { "\(Int($0.rounded())) yrs" } ?? String(localized: "Calibrating")
    }

    private var comparisonText: String {
        guard let age, profileAge > 0 else {
            return String(localized: "Weekly fitness comparison · not biological age")
        }
        let delta = Double(profileAge) - age
        let years = Int(abs(delta).rounded())
        if years == 0 { return String(localized: "About the same as your profile age") }
        if delta > 0 {
            return years == 1
                ? String(localized: "1 year younger than your profile age")
                : String(localized: "\(years) years younger than your profile age")
        }
        return years == 1
            ? String(localized: "1 year older than your profile age")
            : String(localized: "\(years) years older than your profile age")
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NoopMetrics.space3) {
                MetricGlyph("figure.run", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("FITNESS AGE")
                            .font(StrandFont.overlineScaled(10))
                            .tracking(1.3)
                        Text("WEEKLY")
                            .font(StrandFont.overlineScaled(8))
                            .tracking(0.9)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(StrandPalette.chargeColor.opacity(0.14), in: Capsule())
                    }
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    Text(comparisonText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.onDarkSecondary.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(valueText)
                    .font(StrandFont.number(18))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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
            .accessibilityLabel("Fitness Age")
            .accessibilityValue("\(valueText). \(comparisonText)")
            .accessibilityHint("Opens the detailed weekly trend. An About button explains the metric.")
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: Text("Explain Fitness Age")) { onExplain() }
            .accessibilitySortPriority(1)

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

/// The liquid pull-to-refresh vessel + a "Syncing…" label. Owns LiveState (isolated leaf, per the file's
/// convention — see `LiquidLiveHR`) so a live-HR notify doesn't re-render the whole Today, but the vessel
/// still knows about an ONGOING strap backfill.
///
/// Visibility used to be driven only by the local `refreshing` flag, which flips false ~350ms after the
/// pull releases (once the local repo reload + a short "let the fill read as done" delay complete) — but
/// `ble.syncNow()` kicks off a real BLE history offload that can run far longer than that. The vessel was
/// disappearing while the strap was still mid-sync, with no feedback beyond the easy-to-miss header
/// `SyncStatusChip`. `syncing` now also holds it (and the label) up while `live.backfilling` is true, so
/// releasing the pull and watching it go away actually means the sync finished.
private struct LiquidRefreshIndicator: View {
    let pullY: CGFloat
    let pullThreshold: CGFloat
    let refreshing: Bool
    let liquidHeart: Color

    @EnvironmentObject private var live: LiveState

    private var progress: CGFloat { min(1, max(0, pullY / pullThreshold)) }

    /// The RAW "a sync is happening" signal. `live.backfilling` toggles false→true between EVERY offload
    /// chunk (`exitBackfilling` at each HISTORY_END → auto-continue re-kick → `beginBackfill`), with a real
    /// BLE round-trip gap in between. A deep backlog is now up to ~24 chunks in ONE connection (#594 raised
    /// the auto-continue cap 6→24), so binding the vessel straight to this strobes it in/out on every chunk
    /// boundary. The MenuBar header pins a constant height for exactly this reason (see MenuBarContent).
    private var syncingRaw: Bool { refreshing || live.backfilling }

    /// Debounced visibility that drives the body: goes true INSTANTLY, but only goes false after riding out
    /// [hideDelay] with no new chunk — so a brief per-chunk `backfilling` gap can't flicker the vessel.
    @State private var syncing = false
    @State private var hideTask: Task<Void, Never>?
    private static let hideDelaySeconds: UInt64 = 3   // comfortably longer than an inter-chunk gap

    var body: some View {
        ZStack {
            if syncing {
                VStack(spacing: 6) {
                    LiquidVessel(value: 0.6, tint: liquidHeart, animated: true)
                        .frame(width: 34, height: 34)
                    Text("Syncing…")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if pullY > 2 {
                LiquidVessel(value: progress, tint: liquidHeart, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: syncing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: syncing)
        .onAppear { syncing = syncingRaw }
        .onChangeCompat(of: syncingRaw) { raw in
            hideTask?.cancel()
            if raw {
                syncing = true                       // a sync (or pull) is active — show at once
            } else {
                // Might just be the gap between two chunks — wait it out; a new chunk cancels this.
                hideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.hideDelaySeconds * 1_000_000_000)
                    if !Task.isCancelled { syncing = false }
                }
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

private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(StrandPalette.surfaceRaised.opacity(0.82)))
                .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong.opacity(0.72), lineWidth: 1))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Quick actions")
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
        return live.connected ? String(localized: "Waiting for the strap") : String(localized: "Strap not connected")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(1.6)
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
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
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
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only — battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up — Liquid parity with classic
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
        /// Nothing honest to show — no score, no prior night, and not calibrating.
        case noData

        /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
        /// prior value; the empty states draw nothing rather than a fabricated zero.
        var pct: Double? {
            switch self {
            case .scored(let p): return p
            case .carried(let p, _): return p
            case .calibrating, .noData: return nil
            }
        }

        /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
        /// `fixedSize`, so it stays SHORT — the carried day's full "Last night · <date>" stamp lives in
        /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
        /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
        /// trusted wearer who simply hadn't worn the strap that night.
        var stateLabel: String {
            switch self {
            case .scored: return String(localized: "Solid")
            case .carried: return String(localized: "Last night")
            case .calibrating: return String(localized: "Calibrating")
            case .noData: return String(localized: "No data")
            }
        }

        /// The synthesis-card detail line while the baseline is still forming — the same "N of
        /// `Baselines.minNightsSeed` nights" progress classic `TodayView.calibrationDetail` surfaces, so a
        /// wearer in their first few nights reads identical calibration copy on both Today screens (before
        /// this, Liquid dropped the count and showed a bare "Calibrating"). Non-nil ONLY for `.calibrating`:
        /// the compact greeting pill stays short ("Calibrating") because it shares a `fixedSize` row with
        /// the greeting, so the count lives here in the card, exactly as classic keeps it out of its
        /// `ScoreStatePill`. Reuses classic's String Catalog key verbatim — one entry serves both screens.
        var calibrationDetail: String? {
            guard case .calibrating(let nights) = self else { return nil }
            return String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights.")
        }

        /// Bounded learning progress for the liquid vessel. The score remains nil: a half-filled
        /// vessel means "2 of 4 calibration nights", never a fabricated 50% Recovery.
        var calibrationFraction: Double? {
            guard case .calibrating(let nights) = self else { return nil }
            let required = max(1, Baselines.minNightsSeed)
            return Double(max(0, min(nights, required))) / Double(required)
        }

        var calibrationCompactText: String? {
            guard case .calibrating(let nights) = self else { return nil }
            let required = max(1, Baselines.minNightsSeed)
            return "\(max(0, min(nights, required)))/\(required)"
        }

        @MainActor
        static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                            calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
            if let pct = todayRecovery { return .scored(pct: pct) }
            // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
            // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
            if let n = calibrationNights { return .calibrating(nights: n) }
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
                        Text("BAND")
                            .font(.system(size: 6, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(StrandPalette.textSecondary)
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
        .help("Band battery")
    }

    @ViewBuilder
    private var batteryIcon: some View {
        switch display {
        case .charge(let pct, let charging):
            Image(systemName: charging ? "bolt.fill" : batterySymbol(pct))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(charging ? StrandPalette.chargeColor : ringColor(pct))
        case .pending(let charging):
            Image(systemName: charging ? "bolt.fill" : "battery.0percent")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(charging ? StrandPalette.chargeColor : StrandPalette.textSecondary)
        case .offline:
            Image(systemName: "battery.0percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var batteryValue: String {
        switch display {
        case .charge(let pct, _):
            return "\(Int(pct.rounded()))%"
        case .pending(let charging):
            return charging ? "CHG" : "—%"
        case .offline:
            return "—%"
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

    private func batterySymbol(_ pct: Double) -> String {
        switch pct {
        case 87.5...: return "battery.100percent"
        case 62.5...: return "battery.75percent"
        case 37.5...: return "battery.50percent"
        case 12.5...: return "battery.25percent"
        default:      return "battery.0percent"
        }
    }
    /// Never "Strap battery" alone for a no-reading state — that was indistinguishable from a real one.
    private var batteryAccessibility: String {
        switch display {
        case .offline:
            return String(localized: "Strap battery, strap not connected")
        case .pending(let charging):
            return charging
                ? String(localized: "Strap battery charging, no reading yet")
                : String(localized: "Strap battery, no reading yet")
        case .charge(let pct, let charging):
            let n = Int(pct.rounded())
            return charging
                ? String(localized: "Strap battery \(n) percent, charging")
                : String(localized: "Strap battery \(n) percent")
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
/// Deliberately scoped to what LiveState can honestly answer: THAT a drain is running, how many chunks
/// it has pulled, and when one last completed. It does NOT yet say "~15h behind" — that needs the
/// persisted data frontier (max HR ts) compared against `strapRange.newestUnix`, and the frontier is a
/// Repository read that LiveState does not carry. That remains open in B1.
private struct LiquidSyncStatusRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.backfilling {
            row(String(localized: "Strap history"), value: chunks, tone: StrandPalette.accent)
        } else if let ts = live.lastSyncedAt {
            row(String(localized: "Strap history"),
                value: String(localized: "Synced \(relativeAgo(ts)) ago"), tone: StrandPalette.textPrimary)
        }
    }

    /// "Syncing…" alone reads as a spinner that might be stuck; the chunk count is the cheapest available
    /// proof that the drain is actually moving. Suppressed at zero — a session that has pulled nothing yet
    /// should not claim "0 chunks pulled" as if that were progress.
    private var chunks: String {
        live.syncChunksThisSession > 0
            ? String(localized: "Syncing… \(live.syncChunksThisSession) chunks")
            : String(localized: "Syncing…")
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
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
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
