#if os(iOS)
import SwiftUI
import StrandDesign
import Foundation
import Combine

/// Scroll-position scratch space for the adaptive navigation bar. Reference semantics are intentional:
/// offsets arrive for every display-linked ScrollView update, but only a real phase/state transition
/// should invalidate the five-tab shell. The screen itself reports its top marker in scroll coordinates;
/// this tracker turns that stream into direction travel with separate compact/expand thresholds.
private final class TabBarScrollTracker {
    var lastOffset: CGFloat?
    var directionalTravel: CGFloat = 0
    var lastMovementUptime: TimeInterval = 0
    var idleTask: Task<Void, Never>?

    func reset() {
        lastOffset = nil
        directionalTravel = 0
        lastMovementUptime = 0
        idleTask?.cancel()
        idleTask = nil
    }

    deinit { idleTask?.cancel() }
}

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request switches to More and pushes it in that tab's stack.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction? = Self.initialQuickAction
    /// A normal browsing destination requested from inside a quick-action sheet. The sheet must finish
    /// dismissing before the tab stack is changed or the push happens invisibly behind the modal.
    @State private var pendingMoreDestination: MoreDestination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today. DEBUG's `--demo-tab` hook lets the
    /// screenshot harness start on a real tab root (especially More) without duplicating its shell.
    @State private var selectedTab: Int = Self.initialSelectedTab
    /// Actual rendered height of the custom bar (including its own bottom breathing room). Measuring
    /// it keeps Dynamic Type and future visual changes in lockstep with the space reserved below every
    /// tab; a duplicated magic spacer inevitably drifts and hides the last card again.
    @State private var measuredTabBarHeight: CGFloat = FloatingTabBar.expandedReservedHeight
    /// The navigation chrome follows the user's vertical gesture: an upward swipe (reading farther down
    /// the page) compacts it to an icon rail; a downward swipe expands the labels again. The state is
    /// visual only — the shell keeps reserving the largest measured height so changing modes can never
    /// move the scroll endpoint or strand the final card behind the bar.
    @State private var tabBarCompact = Self.initialTabBarCompact
    /// Mutable scroll bookkeeping deliberately lives in a non-observable reference. Actual offsets change
    /// on every drag/deceleration frame; keeping them in `@State` invalidates the whole shell and hitches the
    /// scroll. `scrollMotionActive` changes only when movement begins/settles. Together with the gesture
    /// phase it pauses decorative liquid clocks for both the finger interaction AND inertial deceleration.
    @State private var tabBarScrollTracker = TabBarScrollTracker()
    @GestureState private var contentGestureActive = false
    @State private var scrollMotionActive = false
    /// A safe-area inset follows the software keyboard and can leave a custom tab bar floating halfway
    /// up the display. Native tab bars disappear while typing, so mirror that behaviour here and let the
    /// tab content use the keyboard-adjusted safe area on its own.
    @State private var keyboardVisible = false
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Self.initialTabPaths
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: IPhonePrimaryTab.allCases.count)
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }
    /// A discoverable quick finish control in the More header. The full visual selector remains in
    /// Settings; this menu changes the same shared preference without adding clutter to Today's masthead.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    private static var initialSelectedTab: Int {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--demo-more-route") { return IPhonePrimaryTab.more.rawValue }
        if let i = args.firstIndex(of: "--demo-tab"), i + 1 < args.count {
            switch args[i + 1].lowercased() {
            case "trends":  return IPhonePrimaryTab.trends.rawValue
            case "activity", "workouts": return IPhonePrimaryTab.activity.rawValue
            case "sleep":   return IPhonePrimaryTab.sleep.rawValue
            case "more":    return IPhonePrimaryTab.more.rawValue
            default:        return IPhonePrimaryTab.today.rawValue
            }
        }
        #endif
        return IPhonePrimaryTab.today.rawValue
    }

    /// Opens the production quick-action launcher directly for deterministic simulator captures.
    /// Release builds always start with the launcher closed.
    private static var initialQuickAction: QuickAction? {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-quick-actions") ? .menu : nil
        #else
        return nil
        #endif
    }

    /// Screenshot/visual-regression hook for the real compact navigation state. Production always
    /// starts expanded; the flag only avoids inventing a second mock bar just to verify the scroll-
    /// collapsed appearance in a simulator capture.
    private static var initialTabBarCompact: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-compact-tab-bar")
        #else
        return false
        #endif
    }

    /// DEBUG can start on a real pushed More destination, which verifies the production shell and
    /// persistent bottom bar together rather than taking a misleading isolated-screen screenshot.
    private static var initialTabPaths: [NavigationPath] {
        var paths = Array(repeating: NavigationPath(), count: IPhonePrimaryTab.allCases.count)
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-more-route"),
           i + 1 < args.count,
           let destination = MoreDestination.demo(named: args[i + 1]) {
            var path = NavigationPath()
            path.append(destination)
            paths[IPhonePrimaryTab.more.rawValue] = path
        }
        #endif
        return paths
    }

    /// The Today tab root, honouring the liquid/classic preference.
    @ViewBuilder private var todayTabRoot: some View {
        if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
    }

    init() {
        // Plain Titanium bar: pin the background to `surfaceBase` and clear the system
        // selection-indicator tint so there is NO gold/accent pill behind the selected
        // icon — the gold `.tint` below colours only the selected icon + label, nothing
        // is filled behind it. (UIKit derives a selection-indicator fill from the tint
        // unless it's explicitly cleared.)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(StrandPalette.surfaceBase)
        appearance.selectionIndicatorTintColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        // Keep the custom bar in the root's bottom alignment and reserve its MEASURED height in the
        // TabView itself. This is deliberately more direct than passing a safe-area inset through
        // TabView + NavigationStack: that propagation is inconsistent for nested scroll views and left
        // LiquidToday / some pushed pages unable to expose their final card above the overlay.
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                tab(todayTabRoot, "Today", "square.grid.2x2", tag: IPhonePrimaryTab.today.rawValue,
                    path: $tabPaths[IPhonePrimaryTab.today.rawValue],
                    scrollSignal: scrollTop[IPhonePrimaryTab.today.rawValue])
                    .tag(IPhonePrimaryTab.today.rawValue)
                tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis", tag: IPhonePrimaryTab.trends.rawValue,
                    path: $tabPaths[IPhonePrimaryTab.trends.rawValue],
                    scrollSignal: scrollTop[IPhonePrimaryTab.trends.rawValue])
                    .tag(IPhonePrimaryTab.trends.rawValue)
                tab(WorkoutsView(), "Workouts", "figure.run", tag: IPhonePrimaryTab.activity.rawValue,
                    path: $tabPaths[IPhonePrimaryTab.activity.rawValue],
                    scrollSignal: scrollTop[IPhonePrimaryTab.activity.rawValue])
                    .tag(IPhonePrimaryTab.activity.rawValue)
                tab(SleepView(), "Sleep", "bed.double", tag: IPhonePrimaryTab.sleep.rawValue,
                    path: $tabPaths[IPhonePrimaryTab.sleep.rawValue],
                    scrollSignal: scrollTop[IPhonePrimaryTab.sleep.rawValue])
                    .tag(IPhonePrimaryTab.sleep.rawValue)
                moreTab(path: $tabPaths[IPhonePrimaryTab.more.rawValue],
                        scrollSignal: scrollTop[IPhonePrimaryTab.more.rawValue])
                    .tag(IPhonePrimaryTab.more.rawValue)
            }
            .tint(StrandPalette.accent)
            .toolbar(.hidden, for: .tabBar)
            // Keep the page switch native and deterministic. Selection motion belongs to the floating
            // island below; animating the entire TabView also interpolates label geometry and can clip
            // neighbouring tab titles during a transition frame.
            // Tabs change through the persistent bar. A root-level horizontal drag recognizer used to
            // steal gestures from Trends' year strip (and other horizontally scrolling controls), while
            // pushed pages already need the system edge-swipe for Back. Native iOS tab bars do not require
            // page swiping, so leave horizontal gestures to the content that owns them.
            // A hard layout reservation covers every tab root and pushed destination, including custom
            // ScrollViews that do not use ScreenScaffold. Nutrition keeps its initial viewport useful by
            // expressing source precedence once, inside the totals card, instead of stacking a duplicate
            // warning card above the first actions.
            .padding(.bottom, visibleTabBarHeight)

            if !keyboardVisible {
                HStack(alignment: .bottom, spacing: 6) {
                    FloatingTabBar(selection: $selectedTab, compact: tabBarCompact, onReselect: { tag in
                        // Re-tapping the active tab refreshes that page's data (2026-07-02) and, from a
                        // subpage, pops that tab's stack back to its root (#135) — an animated pop via the
                        // path, not a rebuild. At the root the pop is skipped, so scroll position survives
                        // and the refresh doesn't double with a re-run of the root's `.task` (#198).
                        Task { await repo.refresh() }
                        tabBarCompact = false
                        if !tabPaths[tag].isEmpty {
                            tabPaths[tag] = NavigationPath()
                        } else {
                            scrollTop[tag] += 1
                        }
                    })
                    .frame(maxWidth: .infinity)

                    FloatingQuickAddButton(compact: tabBarCompact) {
                        withAnimation(Self.sheetEase) { quickAction = .menu }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, tabBarCompact ? 3 : 4)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: FloatingTabBarHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .environment(\.liquidInteractionInProgress, contentGestureActive || scrollMotionActive)
        // This observer only marks the immediate touch phase; actual bar state comes from each screen's
        // top-marker position below. Keeping the gesture simultaneous preserves charts, day swipes and
        // interactive Back, while the offset stream continues through inertial deceleration.
        .simultaneousGesture(scrollInteractionGesture)
        .onPreferenceChange(FloatingTabBarHeightPreferenceKey.self) { height in
            // Preserve the LARGEST real measurement. Compacting the visual bar must not reduce the
            // content reservation (which would shift scroll position and could hide the final card).
            guard height > measuredTabBarHeight + 0.5 else { return }
            measuredTabBarHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            tabBarCompact = false
            keyboardVisible = true
        }
        // Wait until UIKit has restored the real bottom safe area before putting the bar back. Reappearing
        // on `willHide` lays it out against the keyboard-height safe area for the whole dismissal animation,
        // which is the exact transient "tab bar floating in the middle" failure this shell must avoid.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: selectedTab) { _, _ in
            // A new destination starts with the fully labelled wayfinding state. It may compact again
            // as soon as the user resumes scrolling down that page.
            tabBarCompact = false
            resetTabBarScrollTracking()
        }
        .onAppear {
            DailyReviewNotifications.restoreScheduleIfAuthorized()
            HydrationReminders.restoreScheduleIfAuthorized()
            WindDownNudge.restoreScheduleIfAuthorized()
            SafetyContactReminders.restore()
            // Let TabView finish mounting before a cold-launch notification changes its selection.
            // Routing synchronously from onAppear can be overwritten by the tab controller's own
            // initial-selection pass on the same run loop.
            Task { @MainActor in
                await Task.yield()
                consumePendingNotificationRoute()
                consumeRequestedDestination(router.requestedDestination)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouteBridge.routeRequested)) { _ in
            consumePendingNotificationRoute()
        }
        .task {
            // AppModel owns the one cold-launch repository refresh. Wait briefly for its published cache,
            // but never start a second independent 4,000-day read from the tab shell: on larger histories
            // that duplicate work was the main source of launch and first-scroll contention.
            if !repo.loaded {
                for _ in 0..<200 {
                    if repo.loaded { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
            await RemoteSyncService.catchUpIfDue(repo: repo)
            let safetyPaging = SafetyPagingService()
            await safetyPaging.refresh()
        }
        .onChange(of: repo.refreshSeq) { _, _ in
            Task { await RemoteSyncService.catchUpIfDue(repo: repo) }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction, onDismiss: finishPendingMoreRoute) { action in
            quickActionDestination(action)
        }
        // Honour a router request. Ordinary destinations enter through More's OWN NavigationStack so
        // the persistent five-tab glass bar behaves identically whether a page was opened from the More
        // index, a dashboard card, or a deep link. Only short tasks and immersive sessions use sheets.
        .onChange(of: router.requestedDestination) { _, dest in
            consumeRequestedDestination(dest)
        }
        // Legacy Today-header requests still route to the same sheet; the persistent floating
        // button is now the primary entry point on every tab.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
        .onChange(of: router.strengthRequested) { _, requested in
            if requested {
                withAnimation(Self.sheetEase) { quickAction = .strength }
                router.strengthRequested = false
            }
        }
    }

    private var visibleTabBarHeight: CGFloat {
        keyboardVisible ? 0 : measuredTabBarHeight
    }

    /// A lightweight interaction-phase observer. It does not decide compact/expanded state and never
    /// writes per-sample `@State`; its sole job is to yield the liquid animation budget immediately,
    /// before the first scroll-offset preference arrives.
    private var scrollInteractionGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($contentGestureActive) { value, active, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dy) > abs(dx) * 1.15 { active = true }
            }
    }

    /// Receives the real ScrollView top-marker position (0 at rest; negative after advancing). Unlike
    /// finger translation this continues during deceleration and ignores non-scrolling vertical drags.
    /// Hysteresis is intentionally asymmetric: compact only after meaningful down-page progress, expand
    /// after a deliberate return gesture or whenever the page reaches its top band.
    private func reportScrollPosition(_ offset: CGFloat, for tab: Int) {
        guard tab == selectedTab, offset.isFinite else { return }
        let tracker = tabBarScrollTracker

        guard let previous = tracker.lastOffset else {
            tracker.lastOffset = offset
            if offset >= -10 { tabBarCompact = false }
            return
        }

        let delta = offset - previous
        tracker.lastOffset = offset
        guard abs(delta) >= 0.5 else { return }

        markScrollMotionActive()

        if tracker.directionalTravel * delta < 0 { tracker.directionalTravel = 0 }
        tracker.directionalTravel += delta

        if offset >= -10 {
            if tabBarCompact { tabBarCompact = false }
            tracker.directionalTravel = 0
        } else if !tabBarCompact, offset <= -36, tracker.directionalTravel <= -18 {
            tabBarCompact = true
            tracker.directionalTravel = 0
        } else if tabBarCompact, tracker.directionalTravel >= 26 {
            tabBarCompact = false
            tracker.directionalTravel = 0
        }
    }

    /// Treat the offset stream as a scroll phase: every movement postpones the idle edge. One lightweight
    /// task watches a monotonic timestamp instead of being cancelled/recreated on every deceleration frame;
    /// that keeps the animation pause cheap precisely while the user is asking the ScrollView to do work.
    private func markScrollMotionActive() {
        let tracker = tabBarScrollTracker
        tracker.lastMovementUptime = ProcessInfo.processInfo.systemUptime
        if !scrollMotionActive { scrollMotionActive = true }
        guard tracker.idleTask == nil else { return }

        tracker.idleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                guard ProcessInfo.processInfo.systemUptime - tracker.lastMovementUptime >= 0.18 else {
                    continue
                }
                scrollMotionActive = false
                tracker.idleTask = nil
                return
            }
        }
    }

    private func resetTabBarScrollTracking() {
        tabBarScrollTracker.reset()
        scrollMotionActive = false
    }

    /// Consume both live and cold-launch navigation requests. `onChange` handles taps while the shell is
    /// mounted; the matching `onAppear` call handles a widget URL received while Terms/onboarding still
    /// covered the shell, when the router value was already set before this view existed.
    private func consumeRequestedDestination(_ destination: NavRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .today:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                selectedTab = IPhonePrimaryTab.today.rawValue
            }
        case .devices:
            routeToMore(.devices)
        case .friends:
            // Social sharing remains opt-in and fully reachable without displacing the daily
            // workout workflow from primary navigation.
            routeToMore(.friends)
        case .insightsHub:
            routeToMore(.insightsHub)
        case .labBook:
            routeToMore(.labBook)
        case .fusedRecord:
            routeToMore(.fusedRecord)
        case .rhythm:
            routeToMore(.rhythm)
        case .trends:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                selectedTab = IPhonePrimaryTab.trends.rawValue
            }
        case .sleep:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                selectedTab = IPhonePrimaryTab.sleep.rawValue
            }
        case .live, .activeWorkout:
            routeToMore(.live)
        case .liveSession:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                selectedTab = IPhonePrimaryTab.today.rawValue
            }
        case .journal:
            routeToMore(.insights)
        }
        router.requestedDestination = nil
    }

    /// Consume exactly one persisted notification route. Clearing the destination stack guarantees
    /// morning lands on the Sleep root and evening on the Today root, even if that tab was last left
    /// on a pushed detail page.
    private func consumePendingNotificationRoute() {
        guard let route = NotificationRouteBridge.consumePending() else { return }
        quickAction = nil
        pendingMoreDestination = nil
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
            switch route {
            case .sleep:
                tabPaths[IPhonePrimaryTab.sleep.rawValue] = NavigationPath()
                selectedTab = IPhonePrimaryTab.sleep.rawValue
            case .today:
                tabPaths[IPhonePrimaryTab.today.rawValue] = NavigationPath()
                selectedTab = IPhonePrimaryTab.today.rawValue
            case .devices:
                routeToMore(.devices)
            case .safety:
                routeToMore(.safety)
            case .coach:
                routeToMore(.coach)
            }
        }
    }

    /// Dismiss a quick-action sheet before changing the visible tab stack. Without this handoff a
    /// request such as Live → Manage devices succeeds behind the still-presented sheet and appears dead.
    private func routeToMore(_ destination: MoreDestination) {
        if quickAction != nil {
            pendingMoreDestination = destination
            quickAction = nil
        } else {
            openMore(destination)
        }
    }

    private func finishPendingMoreRoute() {
        guard let destination = pendingMoreDestination else { return }
        pendingMoreDestination = nil
        openMore(destination)
    }

    /// Switch to More and push one destination. When the request originated on a More subpage, append
    /// to that live stack so Back returns to the origin. Requests from another primary tab deliberately
    /// start a fresh More stack. This preserves both the persistent bar and normal back-button semantics.
    private func openMore(_ destination: MoreDestination) {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
            if selectedTab == IPhonePrimaryTab.more.rawValue {
                tabPaths[IPhonePrimaryTab.more.rawValue].append(destination)
            } else {
                var path = NavigationPath()
                path.append(destination)
                tabPaths[IPhonePrimaryTab.more.rawValue] = path
            }
            selectedTab = IPhonePrimaryTab.more.rawValue
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }
            .presentationDetents([.height(398)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        case .nutrition:
            quickScreen(NutritionLogView())
        case .strength:
            quickScreen(StrengthTrainerView())
        case .hydration:
            quickScreen(HydrationView())
        case .hrv:
            quickScreen(HRVSnapshotView())
        case .intervals:
            quickScreen(IntervalTimerView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String, tag: Int,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        .environment(\.scrollPositionReporter, { offset in
            reportScrollPosition(offset, for: tag)
        })
        .toolbar(.hidden, for: .tabBar)   // we draw our own FloatingTabBar
        .tabItem { Label(title, systemImage: icon) }
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped NoopCard with hairline dividers — the same row idiom Settings/Health use.
    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refresh() },
                           topBackground: liquidScaffoldSky(),
                           trailing: { appearanceQuickMenu }) {
                moreQuickAccess
                moreSection("Insights") {
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                    MoreRow("Intelligence", "brain.head.profile", .intelligence)
                    MoreRow("Coach", "sparkles", .coach)
                    MoreRow("Insights", "lightbulb.fill", .insights)
                    MoreRow("Explore", "square.grid.2x2.fill", .explore)
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare)
                }
                moreSection("Body") {
                    // Profile is a first-class body destination, not a form hidden near the top of the
                    // much longer Settings page. It reuses SettingsView's exact ProfileStore-backed editor.
                    MoreRow("Profile", "person.crop.circle.fill", .profile)
                    MoreRow("Friends", "person.2.fill", .friends)
                    MoreRow("Devices", "applewatch.side.right", .devices)
                    MoreRow("Band", "waveform.path.ecg", .live)
                    MoreRow("Nutrition", "fork.knife", .nutrition)
                    MoreRow("Health", "heart.text.square.fill", .health)
                    MoreRow("Lab Book", "books.vertical.fill", .labBook)
                    MoreRow("Stress", "bolt.heart.fill", .stress)
                    MoreRow("Breathe", "wind", .breathe)
                    MoreRow("Intervals", "timer", .intervals)
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    MoreRow("Rhythm", "waveform.path", .rhythm)
                }
                moreSection("Data") {
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord)
                    MoreRow("Apple Health", "heart.fill", .appleHealth)
                    MoreRow("Mi Band", "figure.walk.motion", .miBand)
                    MoreRow("Data Sources", "externaldrive.fill", .dataSources)
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud", .backupSync)
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill", .shortcutsExport)
                }
                moreSection("App") {
                    // Manual personal-safety tools live above utility/settings rows so they are easy to
                    // find without masquerading as a health metric or an automatic emergency service.
                    MoreRow("Safety", "shield.lefthalf.filled", .safety)
                    // #805/#811: keep the unified Sleep Planner reachable on iPhone as well as in the
                    // macOS/iPad sidebar. It routes to SmartAlarmView, the shared planning/alarm surface.
                    //
                    // Notifications (RootView .notifications) is deliberately NOT added: that screen is
                    // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
                    // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
                    // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
                    // Automations screen instead. Its absence from the iPhone More list is correct.
                    MoreRow("Sleep Planner", "alarm.fill", .alarms)
                    MoreRow("Automations", "wand.and.stars", .automations)
                    MoreRow("Widgets", "rectangle.3.group.fill", .widgets)
                    // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
                    // just buried in Settings, so the feedback loop is one tap from the More tab.
                    MoreRow("Test Centre", "stethoscope", .testCentre)
                    MoreRow("Siri & Shortcuts", "mic.fill", .siriShortcuts)
                    MoreRow("Settings", "gearshape.fill", .settings)
                }
            }
            .toolbar(.hidden, for: .tabBar)   // we draw our own FloatingTabBar
            // The rows push MoreDestination VALUES so a re-tap of the More tab can pop them off the
            // bound path (#135/#198). Each destination keeps the per-screen wrapper the rows used to
            // apply inline (surfaceBase background, inline title bar, hidden bar background):
            // #1027 — a pushed sky-scaffold screen (Live, Workouts, Health, …) draws a full-bleed liquid
            // sky; an opaque surfaceBase nav-bar band sat over it and clipped the top on scroll. A hidden
            // bar background keeps the sky edge-to-edge. On the flat (no-sky) screens this is visually
            // identical at rest — the destination's own surfaceBase background shows through the bar.
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    // Focused fields can ask UIKit to scroll their page upward. Keep the normal
                    // edge-to-edge sky while browsing, but give the pinned Back control a real
                    // surface while the keyboard is present so scrolling titles pass behind
                    // coherent navigation chrome instead of visibly colliding with the button.
                    .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
                    .toolbarBackground(keyboardVisible ? .visible : .hidden, for: .navigationBar)
            }
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .environment(\.scrollPositionReporter, { offset in
            reportScrollPosition(offset, for: IPhonePrimaryTab.more.rawValue)
        })
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    /// The everyday utility doors, kept separate from the complete catalogue below. Four is intentional:
    /// this is a shortcut grid, not another navigation hierarchy. The pure titles/icons/order live in
    /// `MoreSectionPrefs.quickAccess`, while this shell owns only the typed navigation destinations.
    private var moreQuickAccess: some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quick Access")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("Everyday tools")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(MoreSectionPrefs.quickAccess, id: \.id) { item in
                    NavigationLink(value: quickAccessRoute(for: item.id)) {
                        MoreQuickAccessLabel(item: item)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel(Text(LocalizedStringKey(item.title)))
                    .accessibilityHint("Opens from Quick Access")
                }
            }
        }
    }

    private func quickAccessRoute(for id: String) -> MoreDestination {
        switch id {
        case "safety": return .safety
        case "profile": return .profile
        case "devices": return .devices
        case "friends": return .friends
        case "widgets": return .widgets
        default: return .settings
        }
    }

    /// Quick access belongs in More's header: it is always reachable, but it does not compete with
    /// health data or pretend to be a primary destination in the bottom navigation.
    private var appearanceQuickMenu: some View {
        let current = AppearanceMode.resolve(appearanceRaw)
        return Menu {
            Section("App appearance") {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        appearanceRaw = mode.rawValue
                    } label: {
                        HStack {
                            Label(mode.label, systemImage: mode.symbol)
                            if current == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong.opacity(0.78), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .accessibilityLabel("App appearance")
        .accessibilityValue(current.label)
        .accessibilityHint("Choose System, Light, Dark, or Black")
    }

    /// One titled, COLLAPSIBLE group in the More index (S2): the app's overline (UPPERCASE) becomes a
    /// tappable header with a disclosure chevron; tapping it expands/collapses the grouped rows card.
    /// Insights + Body default open, Data + App default collapsed (the `expandedMoreSections` seed) so the
    /// list is shorter at rest without dropping a single row. The grouped card is unchanged: a single
    /// `NoopCard` holding a `VStack(spacing: 0)` whose `MoreRow`s draw their own hairlines, clipped to the
    /// card's rounded shape so the last divider is trimmed inside the corners. Same idiom Settings/Health use.
    @ViewBuilder
    private func moreSection<Rows: View>(_ title: String,
                                         @ViewBuilder rows: @escaping () -> Rows) -> some View {
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            // Tappable overline header: the same ALL-CAPS tracked label as before, now with a trailing
            // chevron that rotates open. A plain Button (not a SwiftUI DisclosureGroup) so the header keeps
            // the exact strandOverline styling and the card layout below stays identical to before.
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    // Persist the toggle via the CSV-backed @AppStorage so the choice survives leaving and
                    // re-entering the More tab and relaunch (#860 item 2). MoreSectionPrefs owns encode/decode.
                    var open = expandedMoreSections
                    if isOpen { open.remove(title) } else { open.insert(title) }
                    expandedMoreSectionsCSV = MoreSectionPrefs.encode(open)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        // ObsidianFlowBackground is dark in Dark mode and pearl in Light mode; the
                        // dynamic token is correct on both, unlike a hard-coded on-dark label.
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse") : String(localized: "Double tap to expand")))

            if isOpen {
                // Zero internal padding so each MoreRow owns its own comfortable insets + height; the rows
                // supply their own hairline separators (drawn at the bottom of every row but the last via the
                // divider overlay) so the group reads as one continuous grouped list, matching Settings/Health.
                NoopCard(padding: 0) {
                    VStack(spacing: 0) { rows() }
                        // Clip the rows column to the card's rounded shape so the last row's bottom hairline is
                        // trimmed inside the corners (the card draws its surface in the BACKGROUND and doesn't
                        // clip content itself, so without this the final divider would run past the rounded edge).
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }

}

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome the old inline links applied lives at the single `navigationDestination(for:)`
/// registration in `moreTab`.
private enum MoreDestination: Hashable {
    case insightsHub, intelligence, coach, insights, explore, compare
    case profile, friends, devices, live, workouts, nutrition, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport
    case safety, alarms, automations, widgets, testCentre, siriShortcuts, settings

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .profile:         SettingsView(focus: .profile)
        case .friends:         FriendsView()
        case .devices:         DevicesView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .nutrition:       NutritionLogView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .safety:          SafetyCenterView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .widgets:         WidgetSettingsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .settings:        SettingsView()
        }
    }

    #if DEBUG
    /// Deterministic screenshot routing for the real More navigation stack.
    static func demo(named rawName: String) -> Self? {
        switch rawName.lowercased() {
        case "coach": return .coach
        case "profile": return .profile
        case "friends": return .friends
        case "devices": return .devices
        case "live": return .live
        case "workouts": return .workouts
        case "nutrition": return .nutrition
        case "health": return .health
        case "insights": return .insights
        case "explore": return .explore
        case "compare": return .compare
        case "settings": return .settings
        case "widgets": return .widgets
        case "safety": return .safety
        case "alarms", "sleepplanner": return .alarms
        default: return nil
        }
    }
    #endif
}

/// The visual half of one Quick Access tile, split from the shell to keep SwiftUI's type checker out of
/// the already-large RootTabView body. Navigation and scroll state remain owned by the parent stack.
private struct MoreQuickAccessLabel: View {
    let item: MoreQuickAccessItem

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: item.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceInset.opacity(0.86),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 0.8))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(item.title))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(StrandPalette.surfaceRaised.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(StrandPalette.hairlineStrong.opacity(0.8), lineWidth: 0.8))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol icon tinted `StrandPalette.accent`, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
private struct MoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let route: MoreDestination

    init(_ title: LocalizedStringKey, _ icon: String, _ route: MoreDestination) {
        self.title = title; self.icon = icon; self.route = route
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                // Pin the icon to the accent explicitly. A plain inherited tint gets re-resolved by iOS to
                // its default blue a beat after first render — so the icons flashed green→blue (#184). The
                // explicit foregroundStyle on the image overrides that; the title keeps the primary colour.
                // Dense destination lists need quieter symbols than primary feature cards. Keeping the
                // extruded plates for heroes/shortcuts restores hierarchy and prevents More from reading
                // like a wall of app icons.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StrandPalette.surfaceInset.opacity(0.86))
                    Image(systemName: icon)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 0.8)
                )
                .accessibilityHidden(true)
                .frame(width: 34, alignment: .center)
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Hairline under every row; the grouped container clips the last one's overflow so the bottom
            // edge stays clean (the divider sits inside the card's rounded corners).
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, workout, strength, nutrition, journal, hydration, hrv, breathe, intervals, live
    var id: Int { rawValue }
}

/// Compact 3x3 action launcher, matching the reference's separate floating-plus interaction.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(0)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 14
            ) {
                tile("Workout", icon: "figure.run", tint: StrandPalette.effortColor) {
                    onPick(.workout)
                }
                tile("Strength", icon: "dumbbell.fill", tint: StrandPalette.metricPurple) {
                    onPick(.strength)
                }
                tile("Meal", icon: "fork.knife", tint: StrandPalette.statusPositive) {
                    onPick(.nutrition)
                }
                tile("Journal", icon: "square.and.pencil", tint: StrandPalette.accent) {
                    onPick(.journal)
                }
                tile("Hydration", icon: "drop.fill", tint: StrandPalette.metricCyan) {
                    onPick(.hydration)
                }
                tile("HRV", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) {
                    onPick(.hrv)
                }
                tile("Breathe", icon: "wind", tint: StrandPalette.restColor) {
                    onPick(.breathe)
                }
                tile("Intervals", icon: "timer", tint: StrandPalette.statusWarning) {
                    onPick(.intervals)
                }
                tile("Live HR", icon: "heart.fill", tint: StrandPalette.metricRose) {
                    onPick(.live)
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            StrandPalette.surfaceOverlay
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    private func tile(
        _ title: LocalizedStringKey,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(StrandPalette.surfaceInset))
                    .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 0.8))
                Text(title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Floating tab bar

/// Reports the bar's real post-layout height to the shell. Using a preference keeps the bar as the
/// single source of truth for its clearance, including Dynamic Type and future style adjustments.
private struct FloatingTabBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The signature bottom bar: two frosted "glass" islands (Today·Trends / Sleep·More) with the gold
/// action button nested cleanly in the gap between them — no overlap, no glow. Real iOS 26 Liquid
/// Glass where available, a `.ultraThinMaterial` fallback below. Replaces the hidden native tab bar.
private struct FloatingTabBar: View {
    /// Reserve the expanded bar from the first layout pass. Its fixed 62pt body plus 4pt breathing room
    /// measures about 66pt; 88pt leaves an optical/touch margin and keeps the next card's rounded edge
    /// fully below the fold instead of peeking into the navigation mask at the initial scroll position.
    /// A larger Dynamic Type measurement can still raise this value, and the shell intentionally preserves
    /// that largest value when the bar compacts.
    static let expandedReservedHeight: CGFloat = 88

    @Binding var selection: Int
    /// Scroll-reactive presentation supplied by the shell. Accessibility Dynamic Type deliberately
    /// keeps labels expanded even when this is true; compact mode remains an icon-only visual choice,
    /// never a loss of VoiceOver naming or tap-target size.
    var compact = false
    /// Fires when the user taps the ALREADY-active tab (2026-07-02: re-tap should refresh).
    var onReselect: (Int) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.noopAppearanceMode) private var appearanceMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Item: Identifiable { let title: LocalizedStringKey; let icon: String; let tag: Int; var id: Int { tag } }
    private let nav = [
        Item(title: "Today", icon: "square.grid.2x2", tag: IPhonePrimaryTab.today.rawValue),
        Item(title: "Trends", icon: "chart.line.uptrend.xyaxis", tag: IPhonePrimaryTab.trends.rawValue),
        Item(title: "Workouts", icon: "figure.run", tag: IPhonePrimaryTab.activity.rawValue),
        Item(title: "Sleep", icon: "bed.double", tag: IPhonePrimaryTab.sleep.rawValue),
        Item(title: "More", icon: "ellipsis", tag: IPhonePrimaryTab.more.rawValue),
    ]

    private var visuallyCompact: Bool { compact && !dynamicTypeSize.isAccessibilitySize }
    private var navigationGlassTint: Color {
        // Dark keeps the smoked optical island. Light uses a pearl-clear lens so the page remains
        // visibly continuous under the bar instead of stacking two black layers into a grey slab.
        // Reduced Transparency receives a deliberately opaque neutral surface below.
        if reduceTransparency || colorSchemeContrast == .increased {
            return colorScheme == .dark ? .black.opacity(0.94) : .white.opacity(0.96)
        }
        if colorScheme == .dark {
            return .black.opacity(appearanceMode == .black ? 0.76 : 0.52)
        }
        return .white.opacity(0.08)
    }
    private var navigationScrim: Color {
        guard !reduceTransparency, colorSchemeContrast != .increased else { return .clear }
        if colorScheme == .dark {
            return .black.opacity(appearanceMode == .black ? 0.22 : 0.12)
        }
        return .black.opacity(0.035)
    }
    private var navigationGlassOpacity: Double {
        // Clear Glass still carries a strong milk-white optical body over a pearl canvas. Fade only
        // that material layer in Light mode (never the labels or tap targets) so the island reads as a
        // lens over the page rather than another white card. Dark and Reduced Transparency stay solid.
        reduceTransparency || colorSchemeContrast == .increased
            ? 1
            : (colorScheme == .dark ? 0.88 : 0.34)
    }
    private func navigationInk(active: Bool) -> Color {
        if colorScheme == .dark {
            return active ? .white : .white.opacity(colorSchemeContrast == .increased ? 0.82 : 0.70)
        }
        return active ? .black.opacity(0.92) : .black.opacity(colorSchemeContrast == .increased ? 0.76 : 0.62)
    }

    var body: some View {
        // One frosted glass bar with five evenly-spaced tabs. The separate circular quick-action
        // control is composed beside this island by RootTabView, so it remains app-wide.
        HStack(spacing: IPhonePrimaryTab.itemSpacing) {
            ForEach(nav) { item in tabButton(item) }
        }
        .padding(.vertical, visuallyCompact ? 2 : 6)
        .padding(.horizontal, visuallyCompact ? IPhonePrimaryTab.compactInnerHorizontalPadding : 8)
        .frame(height: visuallyCompact ? 48 : 62)
        .background {
            Capsule()
                .fill(.clear)
                .navigationGlass(in: Capsule(), tint: navigationGlassTint)
                .opacity(navigationGlassOpacity)
        }
        .background(navigationScrim, in: Capsule())
        // A quiet optical rim defines the glass without turning it into an opaque white slab.
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [
                    .white.opacity(colorScheme == .dark ? (appearanceMode == .black ? 0.16 : 0.22) : 0.58),
                    .white.opacity(colorScheme == .dark ? 0.040 : 0.13),
                    .black.opacity(colorScheme == .dark ? 0.30 : 0.065),
                ],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.075),
                radius: visuallyCompact ? 10 : 14, x: 0, y: visuallyCompact ? 4 : 7)
        // Native tab bars keep their labels compact while destination content honors Larger Text.
        // Cap only this navigation chrome so five stable destinations never truncate or overlap.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28),
                   value: visuallyCompact)
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if active {
                onReselect(item.tag)
            } else {
                selection = item.tag
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: visuallyCompact ? 19 : 18,
                                  weight: active ? .semibold : .regular))
                    // Selection gets one brief, physical lift. It communicates the tab change without
                    // turning navigation into another continuously moving part of the health dashboard.
                    .scaleEffect(active ? (visuallyCompact ? 1.04 : 1.08) : 1)
                    .offset(y: active && !visuallyCompact ? -1 : 0)
                if !visuallyCompact {
                    Text(item.title)
                        .font(StrandFont.footnote.weight(active ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .top)))
                }
            }
            .foregroundStyle(navigationInk(active: active))
            .frame(maxWidth: .infinity)
            .frame(minWidth: IPhonePrimaryTab.minimumTouchDimension)
            .frame(minHeight: IPhonePrimaryTab.minimumTouchDimension)
            // In compact mode the 44pt frame is the whole hit region. Padding outside it would make
            // five buttons overflow the 320pt geometry even though each individual frame still tests 44pt.
            .padding(.horizontal, visuallyCompact
                ? IPhonePrimaryTab.compactItemHorizontalPadding
                : 2)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.045))
                          : .clear)
                    .padding(.horizontal, visuallyCompact ? 0 : 4)
                    .padding(.vertical, visuallyCompact ? 0 : 2)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active
                                  ? (colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.075))
                                  : .clear,
                                  lineWidth: 0.6)
                    .padding(.horizontal, visuallyCompact ? 0 : 4)
                    .padding(.vertical, visuallyCompact ? 0 : 2)
            )
            .contentShape(Capsule(style: .continuous))
            .animation(NoopMotion.gated(NoopMotion.value, reduced: reduceMotion), value: active)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("noop.tab.\(item.tag)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

}

private struct FloatingQuickAddButton: View {
    var compact: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: compact ? 18 : 20, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.9))
                .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
                .background {
                    Circle()
                        .fill(.clear)
                        .navigationGlass(
                            in: Circle(),
                            tint: reduceTransparency
                                ? (colorScheme == .dark ? .black.opacity(0.96) : .white.opacity(0.98))
                                : .white.opacity(colorScheme == .dark ? 0.08 : 0.05)
                        )
                }
                .overlay(
                    Circle().strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.22)
                            : Color.black.opacity(0.10),
                        lineWidth: 0.7
                    )
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10),
                    radius: 12,
                    x: 0,
                    y: 6
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick actions")
        .accessibilityIdentifier("noop.quick-actions")
        .accessibilityHint("Opens workout, strength, meal, journal, hydration, HRV, breathing, intervals, and Live HR actions")
    }
}

// MARK: - Liquid Glass (iOS 26) with a Material fallback

private extension View {
    /// Real iOS 26 Liquid Glass where available; `.ultraThinMaterial` on iOS 17–25 — a clean
    /// blended degrade so the bar stays modern on new OSes without breaking older ones.
    @ViewBuilder func liquidGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// Navigation-specific glass. `Glass.clear` preserves the page underneath on iOS 26; older iOS
    /// versions get the closest material equivalent plus the same restrained adaptive tint.
    @ViewBuilder func navigationGlass(in shape: some Shape, tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear.tint(tint), in: shape)
        } else {
            // Tint overlays the sampled material. Putting the tint behind the material made the
            // fallback read as a flat plate, especially when Light mode used a dark tint.
            self.background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(tint))
            }
        }
    }
}
#endif
