import SwiftUI
import StrandDesign
import UserNotifications

@main
struct StrandApp: App {
    init() {
        AppDiagnosticsRecorder.shared.start()
        PuffinExperiment.migrateContinuousHrvOvernightDefault()
        HydrationReminders.migrateIndependentChannelsIfNeeded()
        #if DEBUG
        // DEBUG-only promo-screenshot harness: when launched with `--demo-hour <Int>`, pin the Today
        // screen to that hour's day-cycle scene + a plausible per-hour stat frame. Runs synchronously
        // here, before the first Today render. No-op (active stays nil) when the arg is absent, so
        // Release is unaffected (whole harness is `#if DEBUG`). See DemoDayHarness.swift.
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        // Foreground presentation: without a delegate, macOS suppresses a notification's banner while the
        // app is frontmost, so a reminder tested with NOOP open would show nothing. Mirrors iOS.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        _model = StateObject(wrappedValue: AppModel())
    }

    @StateObject private var model: AppModel
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The macOS shell (`RootView`)
    /// observes it and drives the sidebar selection.
    @StateObject private var router = NavRouter()
    /// #267: drives a foreground sync kick when the window becomes active (no scenePhase hook
    /// existed on macOS before this).
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (OLED Black by default; System/Pearl/Graphite remain user-selectable).
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTermsVersion = ""

    var body: some Scene {
        WindowGroup {
            ContentView(onOnboardingFinished: {
                model.refreshAgeMetricsIfProfileChanged()
            })
                .environmentObject(model)
                .environmentObject(model.ble)   // #334: Today pull-to-sync reads BLEManager (no HR churn)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                // v5 L3: the shared stress check-in nudge surface, so the Breathe screen's passive
                // card observes the SAME instance the central detector (AppModel.evaluateStress) posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .onAppear {
                    AppDiagnosticsRecorder.shared.setApplicationActive(scenePhase == .active)
                    model.setRealtimeForeground(
                        acceptedTermsVersion == Terms.currentVersion && scenePhase == .active
                    )
                    if acceptedTermsVersion == Terms.currentVersion,
                       scenePhase == .active {
                        WindDownNudge.restoreScheduleIfAuthorized()
                    }
                }
                .onChange(of: acceptedTermsVersion) { version in
                    model.setRealtimeForeground(
                        version == Terms.currentVersion && scenePhase == .active
                    )
                }
                .frame(minWidth: 1000, minHeight: 700)
                .noopAppearance(appearanceRaw)
                .chartStyle(chartStyleRaw)
                // #267: pull a reasonably fresh sync when the window comes to the foreground rather than
                // waiting for the 900s periodic timer or an incidental reconnect. Floored at 90s and never
                // clock/empty-streak-suppressed (BackfillPolicy.shouldRun's .foreground case), so this is
                // a safe no-op on rapid re-focusing. Mirrors the iOS scenePhase == .active handler.
                // Single-param form (not the two-param `{ _, phase in }`) — that overload needs macOS 14,
                // this target is macOS 13.
                .onChange(of: scenePhase) { phase in
                    AppDiagnosticsRecorder.shared.setApplicationActive(phase == .active)
                    // Dense Live/workout/session streaming is foreground-only. This does not drop the
                    // BLE connection, history sync, or the separate Continuous HRV background opt-in.
                    guard acceptedTermsVersion == Terms.currentVersion else {
                        model.setRealtimeForeground(false)
                        return
                    }
                    model.setRealtimeForeground(phase == .active)
                    if phase == .active {
                        WindDownNudge.restoreScheduleIfAuthorized()
                        model.refreshAgeMetricsIfProfileChanged()
                        model.reevaluateContextualInterventions()
                        model.ble.requestSync(.foreground)
                        Task { await FriendsService.catchUpIfDue(repo: model.repo) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar extra: glanceable live HR + a compact popover.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        }
        .menuBarExtraStyle(.window)
    }
}
