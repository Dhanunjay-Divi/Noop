#if os(iOS)
import SwiftUI
import StrandDesign
import Foundation
import Combine

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request switches to More and pushes it in that tab's stack.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
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
    @State private var measuredTabBarHeight: CGFloat = 0
    /// The navigation chrome follows the user's vertical gesture: an upward swipe (reading farther down
    /// the page) compacts it to an icon rail; a downward swipe expands the labels again. The state is
    /// visual only — the shell keeps reserving the largest measured height so changing modes can never
    /// move the scroll endpoint or strand the final card behind the bar.
    @State private var tabBarCompact = Self.initialTabBarCompact
    @State private var tabBarDragStarted = false
    @State private var tabBarDragLastTranslation = CGSize.zero
    @State private var tabBarDragAccumulator: CGFloat = 0
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
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 4)
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }
    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    private static var initialSelectedTab: Int {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--demo-more-route") { return 3 }
        if let i = args.firstIndex(of: "--demo-tab"), i + 1 < args.count {
            switch args[i + 1].lowercased() {
            case "trends": return 1
            case "sleep":  return 2
            case "more":   return 3
            default:       return 0
            }
        }
        #endif
        return 0
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
        var paths = Array(repeating: NavigationPath(), count: 4)
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-more-route"),
           i + 1 < args.count,
           let destination = MoreDestination.demo(named: args[i + 1]) {
            var path = NavigationPath()
            path.append(destination)
            paths[3] = path
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
                tab(todayTabRoot, "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
                tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
                tab(SleepView(), "Sleep", "bed.double", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
                moreTab(path: $tabPaths[3], scrollSignal: scrollTop[3]).tag(3)
            }
            .tint(StrandPalette.accent)
            .toolbar(.hidden, for: .tabBar)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
            // Tabs change through the persistent bar. A root-level horizontal drag recognizer used to
            // steal gestures from Trends' year strip (and other horizontally scrolling controls), while
            // pushed pages already need the system edge-swipe for Back. Native iOS tab bars do not require
            // page swiping, so leave horizontal gestures to the content that owns them.
            // A hard layout reservation (rather than a content-only spacer) covers every tab root and
            // every pushed destination, including custom ScrollViews that do not use ScreenScaffold.
            .padding(.bottom, visibleTabBarHeight)

            if !keyboardVisible {
                FloatingTabBar(selection: $selectedTab, compact: tabBarCompact, onReselect: { tag in
                    // Re-tapping the active tab refreshes that page's data (2026-07-02) and, from a
                    // subpage, pops that tab's stack back to its root (#135) — an animated pop via the
                    // path, not a rebuild. At the root the pop is skipped, so scroll position survives
                    // and the refresh doesn't double with a re-run of the root's `.task` (#198).
                    Task { await repo.refresh() }
                    tabBarCompact = false
                    if !tabPaths[tag].isEmpty {
                        tabPaths[tag] = NavigationPath()   // on a subpage: animated pop back to the root
                    } else {
                        scrollTop[tag] += 1                // already at root: scroll to the top (#198 follow-up)
                    }
                })
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
        // Observe the same finger gesture as the nested ScrollViews without taking ownership of it.
        // Horizontal charts/day swipes are ignored; a small directional accumulator provides a dead
        // zone so tiny reversals and scroll bounce do not make the bar flicker between sizes.
        .simultaneousGesture(adaptiveTabBarGesture)
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
            resetTabBarDragTracking()
        }
        .onAppear {
            DailyReviewNotifications.restoreScheduleIfAuthorized()
            HydrationReminders.restoreScheduleIfAuthorized()
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
            await repo.refresh()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
            await RemoteSyncService.catchUpIfDue(repo: repo)
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
        // the persistent four-tab glass bar behaves identically whether a page was opened from the More
        // index, a dashboard card, or a deep link. Only short tasks and immersive sessions use sheets.
        .onChange(of: router.requestedDestination) { _, dest in
            consumeRequestedDestination(dest)
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
    }

    private var visibleTabBarHeight: CGFloat {
        keyboardVisible ? 0 : measuredTabBarHeight
    }

    /// Finger-direction policy for the adaptive bar. Negative Y means the finger moved upward and the
    /// page is advancing; positive Y means the user is returning toward the top. Requiring vertical
    /// dominance protects Trends charts, the Today day-swipe, and the system Back gesture.
    private var adaptiveTabBarGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let prior = tabBarDragStarted ? tabBarDragLastTranslation : .zero
                let dx = value.translation.width - prior.width
                let dy = value.translation.height - prior.height
                tabBarDragStarted = true
                tabBarDragLastTranslation = value.translation

                guard !keyboardVisible,
                      abs(dy) > abs(dx) * 1.15,
                      abs(dy) > 0.5 else { return }

                // A real reversal starts a fresh decision rather than making the user first cancel all
                // travel accumulated in the previous direction.
                if tabBarDragAccumulator * dy < 0 { tabBarDragAccumulator = 0 }
                tabBarDragAccumulator += dy

                if tabBarDragAccumulator <= -14, !tabBarCompact {
                    tabBarCompact = true
                    tabBarDragAccumulator = 0
                } else if tabBarDragAccumulator >= 10, tabBarCompact {
                    tabBarCompact = false
                    tabBarDragAccumulator = 0
                }
            }
            .onEnded { _ in resetTabBarDragTracking() }
    }

    private func resetTabBarDragTracking() {
        tabBarDragStarted = false
        tabBarDragLastTranslation = .zero
        tabBarDragAccumulator = 0
    }

    /// Consume both live and cold-launch navigation requests. `onChange` handles taps while the shell is
    /// mounted; the matching `onAppear` call handles a widget URL received while Terms/onboarding still
    /// covered the shell, when the router value was already set before this view existed.
    private func consumeRequestedDestination(_ destination: NavRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .today:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
        case .devices:
            routeToMore(.devices)
        case .friends:
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
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
        case .sleep:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 2 }
        case .live, .activeWorkout:
            routeToMore(.live)
        case .liveSession:
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
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
                tabPaths[2] = NavigationPath()
                selectedTab = 2
            case .today:
                tabPaths[0] = NavigationPath()
                selectedTab = 0
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
            if selectedTab == 3 {
                tabPaths[3].append(destination)
            } else {
                var path = NavigationPath()
                path.append(destination)
                tabPaths[3] = path
            }
            selectedTab = 3
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
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
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

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
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
                           topBackground: liquidScaffoldSky()) {
                moreFixedSection("Circle") {
                    MoreRow("Friends", "person.2.fill", .friends)
                }
                moreSection("Insights") {
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                    MoreRow("Intelligence", "brain.head.profile", .intelligence)
                    MoreRow("Coach", "sparkles", .coach)
                    MoreRow("Insights", "lightbulb.fill", .insights)
                    MoreRow("Explore", "square.grid.2x2.fill", .explore)
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare)
                }
                moreSection("Body") {
                    MoreRow("Devices", "applewatch.side.right", .devices)
                    MoreRow("Band", "waveform.path.ecg", .live)
                    MoreRow("Workouts", "figure.run", .workouts)
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
                    // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single
                    // "Alarms" sidebar entry (RootView .smartAlarm) but the regression dropped the row
                    // from the iPhone More list, leaving Alarms unreachable on iPhone. Restore it here
                    // (route to SmartAlarmView, the cross-platform iOS/macOS surface).
                    //
                    // Notifications (RootView .notifications) is deliberately NOT added: that screen is
                    // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
                    // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
                    // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
                    // Automations screen instead. Its absence from the iPhone More list is correct.
                    MoreRow("Alarms", "alarm.fill", .alarms)
                    MoreRow("Automations", "wand.and.stars", .automations)
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
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
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

    /// The private Circle is a single primary destination, so it stays visible instead of consuming
    /// another persisted disclosure state. This also leaves the cross-platform MoreSectionPrefs
    /// Insights/Body default unchanged.
    private func moreFixedSection<Rows: View>(
        _ title: String,
        @ViewBuilder rows: @escaping () -> Rows
    ) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            NoopCard(padding: 0) {
                VStack(spacing: 0) { rows() }
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: NoopMetrics.cardRadius,
                            style: .continuous
                        )
                    )
            }
        }
    }
}

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome the old inline links applied lives at the single `navigationDestination(for:)`
/// registration in `moreTab`.
private enum MoreDestination: Hashable {
    case friends, insightsHub, intelligence, coach, insights, explore, compare
    case devices, live, workouts, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport
    case alarms, automations, testCentre, siriShortcuts, settings

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .friends:         FriendsView()
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .devices:         DevicesView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
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
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .settings:        SettingsView()
        }
    }

    #if DEBUG
    /// Deterministic screenshot routing for the real More navigation stack.
    static func demo(named rawName: String) -> Self? {
        switch rawName.lowercased() {
        case "friends": return .friends
        case "devices": return .devices
        case "live": return .live
        case "workouts": return .workouts
        case "health": return .health
        case "insights": return .insights
        case "explore": return .explore
        case "compare": return .compare
        case "settings": return .settings
        default: return nil
        }
    }
    #endif
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
                DepthGlyph(icon, size: 36)
                    .frame(width: 38, alignment: .center)
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
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
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
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor,
                    illustration: .workout(systemImage: "figure.run")) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
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

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color,
                     illustration: SemanticBodyKind? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                if let illustration {
                    SemanticBodyIllustration(illustration, size: 38, tint: tint)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(StrandPalette.surfaceInset))
                }
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Item: Identifiable { let title: LocalizedStringKey; let icon: String; let tag: Int; var id: Int { tag } }
    private let nav = [Item(title: "Today", icon: "square.grid.2x2", tag: 0),
                       Item(title: "Trends", icon: "chart.line.uptrend.xyaxis", tag: 1),
                       Item(title: "Sleep", icon: "bed.double", tag: 2),
                       Item(title: "More", icon: "ellipsis", tag: 3)]

    private var visuallyCompact: Bool { compact && !dynamicTypeSize.isAccessibilitySize }
    private var navigationGlassTint: Color {
        // Dark keeps the smoked optical island. Light uses a pearl-clear lens so the page remains
        // visibly continuous under the bar instead of stacking two black layers into a grey slab.
        // Reduced Transparency receives a deliberately opaque neutral surface below.
        if reduceTransparency {
            return colorScheme == .dark ? .black.opacity(0.94) : .white.opacity(0.96)
        }
        return colorScheme == .dark ? .black.opacity(0.64) : .white.opacity(0.08)
    }
    private var navigationScrim: Color {
        guard !reduceTransparency else { return .clear }
        return colorScheme == .dark ? .black.opacity(0.18) : .black.opacity(0.035)
    }
    private var navigationGlassOpacity: Double {
        // Clear Glass still carries a strong milk-white optical body over a pearl canvas. Fade only
        // that material layer in Light mode (never the labels or tap targets) so the island reads as a
        // lens over the page rather than another white card. Dark and Reduced Transparency stay solid.
        reduceTransparency || colorScheme == .dark ? 1 : 0.68
    }
    private func navigationInk(active: Bool) -> Color {
        if colorScheme == .dark {
            return active ? .white : .white.opacity(0.68)
        }
        return active ? .black.opacity(0.90) : .black.opacity(0.56)
    }

    var body: some View {
        // One frosted glass bar, four evenly-spaced tabs. The quick-action "+" now lives in the
        // top-right of each screen's header (balancing the profile avatar on the left).
        HStack(spacing: 2) {
            tabButton(nav[0])
            tabButton(nav[1])
            tabButton(nav[2])
            tabButton(nav[3])
        }
        .padding(.vertical, visuallyCompact ? 2 : 6)
        .padding(.horizontal, visuallyCompact ? 7 : 8)
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
                    .white.opacity(colorScheme == .dark ? 0.24 : 0.74),
                    .white.opacity(colorScheme == .dark ? 0.045 : 0.20),
                    .black.opacity(colorScheme == .dark ? 0.32 : 0.08),
                ],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10),
                radius: visuallyCompact ? 11 : 16, x: 0, y: visuallyCompact ? 5 : 8)
        // The compact state also narrows the island, not just its height. Four 44pt hit regions still
        // fit comfortably inside the 56pt side insets on every supported iPhone width.
        .padding(.horizontal, visuallyCompact ? 56 : 18)
        .padding(.bottom, visuallyCompact ? 3 : 4)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28),
                   value: visuallyCompact)
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if active {
                onReselect(item.tag)
            } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selection = item.tag }
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
            .frame(minHeight: 44)
            .padding(.horizontal, visuallyCompact ? 3 : 2)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? (colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.055))
                          : .clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active
                                  ? (colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.075))
                                  : .clear,
                                  lineWidth: 0.6)
            )
            .contentShape(Capsule(style: .continuous))
            .animation(NoopMotion.gated(NoopMotion.value, reduced: reduceMotion), value: active)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
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
