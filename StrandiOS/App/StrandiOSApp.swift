#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import UserNotifications
import WidgetKit

/// iOS entry point. Unlike the macOS app (which adds a `MenuBarExtra` scene), iOS uses a single
/// `WindowGroup`; the glanceable menu-bar role is filled by the Home/Lock-Screen widget instead.
///
/// The iOS shell is `RootTabView` (a `TabView`), NOT the macOS `ContentView`. `ContentView` embeds
/// `RootView()` — the `NavigationSplitView` sidebar shell — and `RootView.swift` is excluded from the
/// iOS target in `project.yml` (the sidebar has no iPhone analogue), so `ContentView` cannot compile
/// on iOS. The first-run onboarding/pairing wizard, the Terms acknowledgment gate, and the post-update
/// "What's New" sheet that `ContentView` layers on are reproduced here as `iOSRootView`, wrapped around
/// `RootTabView` so the iOS app keeps the same gating without depending on the macOS-only shell.
@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    /// The phone→watch link. Built + activated here so the watch app actually receives snapshots on a
    /// real device; without an owner that pushes it, the watch only ever shows placeholder data.
    @StateObject private var watch = WatchSessionBridge()
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The iOS shell (`RootTabView`)
    /// observes it and presents the Devices manager.
    @StateObject private var router = NavRouter()
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (OLED Black by default; Settings and More write the same persisted value).
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTermsVersion = ""

    /// #3 (perf): one-time, device-tier Smooth-mode default (constrained hardware starts posed).
    /// Idempotent and never overrides a user choice — see QuietMotionPrefs.applyDeviceTierDefaultIfNeeded.
    private static let _quietMotionTierDefault: Void = QuietMotionPrefs.applyDeviceTierDefaultIfNeeded()
    /// ActivityKit owns Lock Screen + Dynamic Island as one Live Activity surface. Observe both privacy
    /// choices at the root so disabling it ends the pill immediately and daily scores are included only
    /// after a separate explicit opt-in.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    @AppStorage(UnitPrefs.liveActivityChargeKey) private var liveActivityShowsCharge = true
    @AppStorage(UnitPrefs.liveActivityEffortKey) private var liveActivityShowsEffort = true

    init() {
        _ = Self._quietMotionTierDefault
        // 9.2 data-truth migration: clear a legacy Shortcuts file that may contain WHOOP @57 motion
        // ticks in the Apple Health Steps column. Do this synchronously before constructing stores,
        // BLE sources, or any async reader; future writes use the HR-only fixed-column contract.
        _ = ShortcutHealthExport.migrateLegacyFileIfNeeded()
        PuffinExperiment.migrateContinuousHrvOvernightDefault()
        HydrationReminders.migrateIndependentChannelsIfNeeded()
        #if DEBUG
        // DEBUG-only promo-screenshot harness: when launched with `--demo-hour <Int>`, pin Today to that
        // hour's day-cycle scene + a per-hour stat frame. No-op (active stays nil) when the arg is absent.
        // MUST live here, not in StrandApp.swift — that is the macOS @main and is excluded from the iOS
        // target, so the hook there never runs on iOS.
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        // Debug-only canary: trips if the App Group entitlement is missing on this target before any
        // silent no-op (PendingIntents, WidgetSnapshot.publish, Live Activity) can mask the issue as
        // "the widget doesn't show anything yet." No-op in Release.
        WidgetSnapshot.assertGroupProvisioned()
        // #510: register the scheduled debug auto-export's BGTask handler BEFORE launch finishes — iOS
        // only delivers a background task whose identifier was registered at launch AND listed in the
        // target's BGTaskSchedulerPermittedIdentifiers (project.yml). Without this the overnight drop
        // never fires; the macOS timer, foreground catch-up, and "Run now" already work without it.
        ScheduledDebugExport.register()
        // Foreground presentation: without a delegate, iOS suppresses a notification's banner while the app
        // is open, so a user testing the wind-down reminder with NOOP foregrounded sees nothing. Register
        // before the first scene so any early-fired notification is presented.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let bridge = HealthKitBridge(
            repo: model.repo,
            profile: model.profile,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        )
        _health = StateObject(wrappedValue: bridge)
        model.healthWriteBack = { [weak bridge] in
            await bridge?.writeBackAfterNewData()
        }
        bridge.cycleAnchorsChanged = { [weak model] in
            await model?.refreshV5Signals()
        }
        bridge.dataProjectionChanged = { [weak bridge, weak model] in
            guard let model else { return }
            await model.refreshAfterAppleHealthSync(
                authorized: bridge?.auth == .authorized)
        }
        // HealthKit may relaunch a terminated app in the background to deliver an observer update,
        // before a SwiftUI scene becomes active. Install observers at this process-launch boundary for
        // returning users only. The bridge checks NOOP's prior explicit-consent marker and never opens a
        // permission sheet, so a fresh install still reaches the in-app rationale first.
        bridge.registerObserversAtLaunchIfPreviouslyRequested()
        // Register the general maintenance refresh while launch is still in progress. This is an
        // opportunistic iOS wake, not a timer: CoreBluetooth restoration and HealthKit observers remain
        // the primary background paths, and every foreground still performs the authoritative catch-up.
        // The injected operation preserves each feature's existing privacy gate: Health reads require a
        // prior explicit grant, self-hosted upload remains opt-in, and Friends needs an enrolled member.
        BackgroundSyncScheduler.register { [weak model, weak bridge] in
            guard UserDefaults.standard.string(forKey: "noop.acceptedTermsVersion")
                    == Terms.currentVersion,
                  let model,
                  let bridge,
                  await model.repo.storeHandle() != nil else { return false }

            // If CoreBluetooth already restored/retained a bonded link, ask for the same rate-limited
            // historical offload as the 15-minute connected timer. This never starts dense Live HR and
            // is a no-op while disconnected, busy, recently synced, or backed off after empty history.
            let strapSyncCompleted = await model.ble.requestSyncAndWait(.periodic)
            guard !Task.isCancelled else { return false }
            model.ble.pruneRaw()

            bridge.refreshAuthIfPreviouslyGranted() // status-only; never opens the permission sheet
            if bridge.auth == .authorized {
                _ = await bridge.sync(days: 2)
            }
            guard !Task.isCancelled else { return false }

            // A first/full self-hosted replay can be large and belongs in a foreground/manual run. Normal
            // incremental delivery is bounded, cursor-backed, and only runs when the user enabled it.
            if !RemoteSyncPreferences.needsFullReplay,
               !RemoteSyncPreferences.replayInProgress {
                await RemoteSyncService.catchUpIfDue(repo: model.repo)
            }
            guard !Task.isCancelled else { return false }

            await FriendsService.catchUpIfDue(repo: model.repo)
            guard !Task.isCancelled else { return false }
            await WidgetSnapshot.publish(from: model)
            return strapSyncCompleted && !Task.isCancelled
        }
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .environmentObject(model)
                .onAppear {
                    model.setRealtimeForeground(
                        acceptedTermsVersion == Terms.currentVersion && scenePhase == .active
                    )
                }
                .onChange(of: acceptedTermsVersion) { _, version in
                    model.setRealtimeForeground(
                        version == Terms.currentVersion && scenePhase == .active
                    )
                }
                .environmentObject(model.ble)   // #334: Today pull-to-sync reads BLEManager (no HR churn)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                // v5 L3: the shared stress check-in nudge surface, so the Breathe screen's passive
                // card observes the SAME instance the central detector (AppModel.evaluateStress) posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .noopAppearance(appearanceRaw)
                .onChange(of: appearanceRaw, initial: true) { _, rawValue in
                    // The widget extension is a separate process, so mirror the complete preference to
                    // the App Group and reload immediately. This preserves Graphite vs OLED Black rather
                    // than making widgets merely follow the system scheme until the next data publish.
                    WidgetAppearancePreference.save(AppearanceMode.resolve(rawValue).rawValue)
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .chartStyle(chartStyleRaw)
                // Dynamic Type now scales the prose/label roles (StrandFont). Cap the upper end so the
                // fixed-geometry tiles/gauges stay legible at the largest accessibility sizes rather than
                // clipping; the common Larger-Text range still scales fully.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onReceive(model.live.heartRateSamplePublisher) { sample in
                    // #911: anchor the Live Activity on the SAME shared `Repository.widgetAnchor` the
                    // Home/Lock widget and the watch snapshot use, so this fourth surface can't drift to a
                    // different day at the rollover (it previously read `days.last(where: recovery != nil)`,
                    // which kept pointing at yesterday's scored row after Today had moved on).
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: model.live.connected ? sample.bpm : nil,
                        recovery: liveActivityShowsCharge
                            ? day?.recovery.map { Int($0.rounded()) } : nil,
                        connected: model.live.connected,
                        effort: liveActivityShowsEffort
                            ? day?.strain.map { Int($0.rounded()) } : nil,
                        observedAt: sample.receivedAt
                    )
                }
                // End the Live Activity the moment the link drops, even if no further HR tick arrives.
                .onReceive(model.live.$connected) { isConnected in
                    // #911: same shared anchor as the heartRate site above, so the Live Activity, the
                    // widget, the watch and Today never disagree about which day they describe.
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: liveActivityShowsCharge
                            ? day?.recovery.map { Int($0.rounded()) } : nil,
                        connected: isConnected,
                        effort: liveActivityShowsEffort
                            ? day?.strain.map { Int($0.rounded()) } : nil,
                        observedAt: model.live.heartRateSample?.receivedAt
                    )
                }
                .onChange(of: liveActivityEnabled, initial: true) { _, _ in
                    // Reconcile both edges: disabling removes every persisted surface immediately;
                    // enabling may adopt/start from the still-fresh cached packet without waiting for
                    // another BLE tick.
                    reconcileLiveActivity()
                }
                .onChange(of: liveActivityShowsCharge) { _, _ in
                    reconcileLiveActivity()
                }
                .onChange(of: liveActivityShowsEffort) { _, _ in
                    reconcileLiveActivity()
                }
                // #911/#759: republish the Home/Lock-Screen widget whenever the dashboard caches actually
                // change mid-session. The only other publish site is the scenePhase .active handler, so
                // during a long foreground session the widget froze at the last-foreground snapshot while
                // Today and the Live Activity kept updating. `refreshSeq` is diff-guarded (Repository.refresh
                // skips the bump when the merged caches are byte-identical) and refresh() assigns every cache
                // BEFORE bumping the seq, so this publish always reads fresh data. `dropFirst()` skips the
                // publisher's attach-time replay of the current value; the .active publish already covers
                // launch. BUDGET: this app runs with bluetooth-central, so the process is NOT suspended in
                // the background, and the 15-minute analyze tick + backfill-completion refreshes bump the
                // seq back there too, where WidgetKit reloads DO count against the daily budget. Hence the
                // foreground gate: publish only while .active (foreground-initiated reloads are budget
                // exempt); a background bump is covered by the widget's own 15-minute timeline policy and
                // by the .active republish on return.
                .onReceive(model.repo.$refreshSeq.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                    // The watch rides the same active-only hook because the bridge now SELF-THROTTLES
                    // (30-minute spacing + headline-change dedup, both must pass, see WatchSessionBridge),
                    // so a refresh storm can't burn the ~50/day complication transfer budget.
                    Task { await watch.pushLatest(from: model) }
                }
                // #114: strap battery % and connection are LIVE (model.live), not repo-cache, so they never
                // bump refreshSeq — the widget's battery would otherwise never move while the app is open
                // (the "battery not updating" report). Republish on those too, foreground-gated. Both are
                // low-frequency (battery ~every 8 min; connection flips are rare), so no throttle is needed
                // and foreground-initiated reloads are budget-exempt. dropFirst() skips the attach replay.
                .onReceive(model.live.$batteryPct.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(model.live.$connected.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                // #114 (follow-up): `WidgetSnapshot.bpm` reads `model.bpm` (WidgetPublish.swift), the
                // smoothed live HR — same LIVE-not-repo-cache category as battery/connected above, so it
                // has the same gap: nothing bumped `refreshSeq` while a heart-rate stream was live, so the
                // widget's HR froze at the last foreground snapshot for the rest of the session. UNLIKE
                // battery/connection, HR is HIGH-frequency (the smoothed median moves every few seconds
                // under activity), so — unlike the ungated hooks above — this one is throttled through
                // `HRPublishThrottle` (60 s, mirroring Android's PushGate HR cadence) so it can't re-run
                // publish's `exploreSeries` read + `reloadAllTimelines()` on every tick.
                .onReceive(model.$bpm.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    guard WidgetSnapshot.HRPublishThrottle.admit() else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                // #581: the `noop://import-health` deep link the iOS Shortcut opens after building the
                // HealthKit-free payload. Filter on the host so other future schemes don't trip the
                // importer; macOS never registers the scheme so this stays iOS-only.
                .onOpenURL { url in
                    if let destination = NOOPWidgetDestination(url: url) {
                        switch destination {
                        case .today: router.openToday()
                        case .trends: router.openTrends()
                        case .sleep: router.openSleep()
                        case .live: router.openLive()
                        }
                    } else if url.host == "import-health" {
                        model.handleHealthImportURL(url)
                    }
                }
                .alert("Import Apple Health data?", isPresented: Binding(
                    get: { model.pendingShortcutHealthImport != nil },
                    set: { showing in
                        if !showing { model.cancelPendingHealthImport() }
                    }
                )) {
                    Button("Import") { model.confirmPendingHealthImport() }
                    Button("Cancel", role: .cancel) { model.cancelPendingHealthImport() }
                } message: {
                    if let pending = model.pendingShortcutHealthImport {
                        Text("A Shortcut wants to add \(pending.daysCount) days and \(pending.workoutsCount) workouts to the Apple Health import source.")
                    } else {
                        Text("A Shortcut wants to add data to the Apple Health import source.")
                    }
                }
                // Bring the watch link up once at launch (WCSession ignores a redundant activate), then
                // push the first snapshot so a watch that's already on-wrist gets current scores without
                // waiting for the next foreground. activate() is idempotent + a no-op where WC isn't
                // supported, so this is safe on every device/simulator combination.
                .task {
                    // Cold-launch adoption/cleanup: packet publishers may stay quiet while an activity
                    // from the prior process is still visible, so reconcile the cached sensor state too.
                    watch.startStrengthRoutineHandler = {
                        [weak model, weak router, weak watch] routineID in
                        guard let model, let router, let watch else { return }
                        Task { @MainActor in
                            _ = try? await model.repo.startStrengthSession(routineID: routineID)
                            router.openStrength()
                            await watch.pushStrengthLatest(from: model)
                        }
                    }
                    watch.activate()
                    reconcileLiveActivity(repairHydration: true)
                    await model.reconcileAutomaticWorkoutSurfaces()
                    await watch.pushLatest(from: model)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .strengthTrainingChanged)
                ) { _ in
                    Task { await watch.pushStrengthLatest(from: model) }
                }
        }
        // HealthKit authorization is intentionally NOT requested on launch. The system permission
        // dialog without prior in-app rationale violates Apple HIG / App Review guidance — the user
        // sees the prompt before any context. It is requested from an explicit user action instead:
        // the "Enable Apple Health" affordance in AppleHealthView (More → Data → Apple Health).
        // The app initializer re-arms observer delivery at the process-launch boundary for users with
        // NOOP's prior explicit-request marker. Below, `refreshAuthIfPreviouslyGranted` also re-primes
        // legacy returning users once the scene is active (status-only, never prompts); and
        // HealthKitBridge.sync guards on `auth == .authorized`, so the scenePhase trigger stays a
        // safe no-op until the user opts in.
        .onChange(of: scenePhase) { _, phase in
            // Dense Live/workout/session streaming is foreground-only. Logical leases survive so the
            // same visible opted-in session resumes on return; connection/history sync and the separate
            // Continuous HRV background preference are intentionally unaffected.
            guard acceptedTermsVersion == Terms.currentVersion else {
                model.setRealtimeForeground(false)
                return
            }
            model.setRealtimeForeground(phase == .active)
            if phase == .active {
                // Re-check packet age and ActivityKit's persisted list whenever NOOP returns. This ends a
                // stale activity even when iOS suspended the in-process expiry task while in background.
                reconcileLiveActivity(repairHydration: true)
                model.drainPendingIntents()
                // Re-arm the strap's smart alarm on foreground: the firmware alarm is a single instant
                // and iOS can't re-arm it while suspended, so it would otherwise fire once and stop.
                model.applySmartAlarm()
                // #267: pull a reasonably fresh sync on open rather than waiting for the 900s periodic
                // timer or an incidental reconnect. Floored at 90s and never clock/empty-streak-suppressed
                // (BackfillPolicy.shouldRun's .foreground case), so this is a safe no-op on rapid re-opens.
                model.ble.requestSync(.foreground)
                Task {
                    await model.reconcileAutomaticWorkoutSurfaces()
                    health.refreshAuthIfPreviouslyGranted()
                    await health.foregroundCatchUp()
                    await WidgetSnapshot.publish(from: model)
                    // Push the wrist on the SAME refresh as the Home-screen widget so the watch, the
                    // widget and Today never disagree about which day they describe. Without this the
                    // watch only ever holds placeholder data on a real device.
                    await watch.pushLatest(from: model)
                }
                Task { await FriendsService.catchUpIfDue(repo: model.repo) }
            } else if phase == .background {
                // Single-shot and best-effort: iOS chooses whether/when this runs. The handler re-arms
                // itself after delivery; every later background transition also repairs the schedule.
                BackgroundSyncScheduler.scheduleNext()
                // #114: capture the LAST in-app live state on the way out so the Home widget matches what
                // the user just saw — its battery/HR/score otherwise lag to the last FOREGROUND refreshSeq
                // bump. One reload per app-exit is low-frequency and well within WidgetKit's daily budget.
                Task { await WidgetSnapshot.publish(from: model) }
                // #155: refresh the Documents/noop_sync.txt drop file the user's Siri Shortcut logs
                // into Apple Health. Gated inside writeIfEnabled on the opt-in default (OFF) — a
                // no-op until the user turns on Shortcuts Export.
                Task { await ShortcutHealthExport.writeIfEnabled(repo: model.repo) }
            }
        }
    }

    private func reconcileLiveActivity(repairHydration: Bool = false) {
        let day = Repository.widgetAnchor(days: model.repo.days)
        let bpm = model.live.connected ? (model.bpm ?? model.live.heartRate) : nil
        let recovery = liveActivityShowsCharge
            ? day?.recovery.map { Int($0.rounded()) } : nil
        let effort = liveActivityShowsEffort
            ? day?.strain.map { Int($0.rounded()) } : nil
        let observedAt = model.live.heartRateSample?.receivedAt
        if repairHydration {
            liveActivity.reconcile(
                bpm: bpm, recovery: recovery, connected: model.live.connected,
                effort: effort, observedAt: observedAt
            )
        } else {
            liveActivity.update(
                bpm: bpm, recovery: recovery, connected: model.live.connected,
                effort: effort, observedAt: observedAt
            )
        }
    }
}

/// iOS root — the `RootTabView` shell with the first-run onboarding/pairing wizard overlaid until
/// complete, the Terms acknowledgment gate over everything until the current version is accepted, and
/// a "What's New" changelog sheet shown automatically after an update.
///
/// This mirrors the macOS `ContentView` (same `@AppStorage` keys, same gate ordering) but swaps the
/// excluded `RootView()` sidebar for `RootTabView()`. The shared `OnboardingWizard`, `TermsGateView`,
/// `WhatsNewView`, `AppChangelog`, and `Terms` symbols all compile into the iOS target unchanged.
private struct iOSRootView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    @AppStorage("noop.acceptedTermsAt") private var acceptedTermsAt = ""
    /// Local-only build marker. It contains no account or health data and makes the preview disclosure
    /// appear once per genuinely newer app build instead of once per cold process launch.
    @AppStorage(TrialNoticePolicy.acknowledgedBuildStorageKey)
    private var acknowledgedTrialBuild = ""
    @State private var showWhatsNew = false

    var body: some View {
        #if DEBUG
        // DEBUG-only: `--demo-screen <name>` renders one screen full-bleed (gates bypassed) so a
        // seeded simulator build can be screenshotted deterministically for verification + marketing.
        // No-op in Release (whole branch is #if DEBUG) and when the arg is absent.
        if let demo = DemoScreens.requested {
            // Inherit the app appearance (set via the Theme picker, or `-theme.appearance light|dark`
            // in the launch arguments) so demo/marketing shots can be taken in either scheme.
            return AnyView(
                NavigationStack {
                    demo
                        .background(StrandPalette.surfaceBase.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                }
            )
        }
        #endif
        return AnyView(shell)
    }

    private var shell: some View {
        ZStack {
            // Do not mount the operational shell before clickwrap acceptance. RootTabView starts repository
            // refresh, backup catch-up and optional remote sync from its task modifier.
            if acceptedTerms == Terms.currentVersion || demoBypass {
                RootTabView()
            } else {
                StrandPalette.surfaceBase.ignoresSafeArea()
            }
            if acceptedTerms == Terms.currentVersion && !onboarded && !demoBypass {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    // A brand-new user just saw the expectations in onboarding — don't also pop the
                    // changelog at them; mark them current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — before onboarding or the operational shell until
            // the current terms version is accepted; re-appears if the terms materially change.
            if acceptedTerms != Terms.currentVersion && !demoBypass {
                TermsGateView(onAccept: {
                    acceptedTermsAt = ISO8601DateFormatter().string(from: Date())
                    acceptedTerms = Terms.currentVersion
                })
                    .transition(.opacity)
                    .zIndex(2)
            }
            // Trial disclosure sits above Terms/onboarding so it is the first thing a tester sees on a
            // fresh install or newer build. The DEBUG demo harness bypasses it for deterministic captures.
            if TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: acknowledgedTrialBuild,
                currentBuildIdentifier: TrialNoticePolicy.currentBuildIdentifier(),
                demoBypass: demoBypass
            ) {
                TrialNoticeView(onContinue: {
                    acknowledgedTrialBuild = TrialNoticePolicy.currentBuildIdentifier()
                })
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
        .animation(.easeInOut(duration: 0.35), value: acceptedTerms)
        .animation(.easeInOut(duration: 0.35), value: acknowledgedTrialBuild)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        // The Terms gate must stay "over everything" - don't pop What's New on top of it after a
        // combined terms+version update. Gate on terms being current, and re-check when they're
        // accepted (onAppear already fired before acceptance), so What's New shows right after.
        .onAppear {
            showWhatsNewIfDue()
            // Seed the current What's New into the Updates inbox (idempotent per version) so the bell
            // collects it even if the user dismisses the auto sheet.
            UpdateStore.shared.seedWhatsNewIfNeeded()
        }
        .onChange(of: acceptedTerms) { _, _ in showWhatsNewIfDue() }
        .onChange(of: acknowledgedTrialBuild) { _, _ in showWhatsNewIfDue() }
    }

    /// DEBUG: launched with --demo-seed, skip the first-run gates (onboarding / terms / What's New) so the
    /// FULL shell with the tab bar renders populated for verification + screenshots. No-op in Release.
    private var demoBypass: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-seed")
        #else
        return false
        #endif
    }

    private func showWhatsNewIfDue() {
        if demoBypass { return }
        // Existing users who updated: their last-seen release is genuinely behind the current one.
        // Persist before presentation so an interactive swipe-dismiss or process termination cannot make
        // the same release notes replay on the next launch. They remain manually available in Settings.
        guard !TrialNoticePolicy.shouldPresent(
            acknowledgedBuildIdentifier: acknowledgedTrialBuild,
            currentBuildIdentifier: TrialNoticePolicy.currentBuildIdentifier(),
            demoBypass: demoBypass
        ), onboarded,
           acceptedTerms == Terms.currentVersion,
           TrialNoticePolicy.isNewerMarketingVersion(
               AppChangelog.currentVersion,
               than: lastSeenChangelog
           ) else { return }
        lastSeenChangelog = AppChangelog.currentVersion
        showWhatsNew = true
    }
}

#if DEBUG
/// DEBUG-only screenshot harness. Maps `--demo-screen <name>` to a single screen so a seeded
/// simulator build can be captured deterministically (verification + marketing). Stripped from Release.
enum DemoScreens {
    /// The screen named by `--demo-screen <name>`, or nil if the arg is absent/unknown.
    static var requested: AnyView? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-screen"), i + 1 < args.count else { return nil }
        switch args[i + 1].lowercased() {
        case "today":    return AnyView(TodayView())
        // The DEFAULT iOS Today (`noop.liquidTodayEnabled` ships true), so it needs its own entry — plain
        // "today" renders the CLASSIC screen, which is exactly the screen whose behaviour Liquid was found
        // to have diverged from. Without this, the default Today was the one screen the harness could not
        // capture.
        case "liquidtoday": return AnyView(LiquidTodayView())
        // UI v2 ("Aurora") - the redesigned Today. Renders from TodayV2Model.demo so the harness can
        // capture it deterministically; the live wiring reads the same model shape.
        case "todayv2":  return AnyView(TodayV2View(model: .demo))
        case "v2calendar": return AnyView(V2MonthCalendarDemo())
        case "calendar": return AnyView(CalendarMonthView())
        // UI v3 "Instrument" - dense, flat-field, status-word instrument language.
        case "todayv3":  return AnyView(TodayV3View(model: .demo))
        // UI v4 "Useful" - NOOP 3D glyphs + BevelGauge, every block answers one real question.
        case "todayv4":  return AnyView(TodayV4View(model: .demo))
        case "trends":   return AnyView(TrendsView())
        case "sleep":    return AnyView(SleepView())
        case "live":     return AnyView(LiveView())
        case "stress":   return AnyView(StressView())
        case "workouts": return AnyView(WorkoutsView())
        case "startworkout": return AnyView(StartWorkoutSheet { _ in })
        case "health":   return AnyView(HealthView())
        case "cycletracker": return AnyView(CycleTrackerDemoHost())
        case "insights": return AnyView(InsightsView())
        case "explore":  return AnyView(MetricExplorerView())
        case "metricdetail":
            // Direct, deterministic metric-dossier render target. Example:
            // `--demo-screen metricdetail --demo-metric fitness_age`.
            let metricKey: String = {
                guard let j = args.firstIndex(of: "--demo-metric"), j + 1 < args.count else {
                    return "fitness_age"
                }
                return args[j + 1]
            }()
            let metricSource: String? = {
                guard let j = args.firstIndex(of: "--demo-source"), j + 1 < args.count else {
                    return nil
                }
                return args[j + 1]
            }()
            let metric = MetricCatalog.all.first {
                $0.key == metricKey && (metricSource == nil || $0.source == metricSource)
            } ?? MetricCatalog.all.first { $0.key == "fitness_age" }!
            return AnyView(MetricDetailView(metric: metric))
        case "compare":  return AnyView(CompareView())
        case "settings": return AnyView(SettingsView())
        case "automations": return AnyView(AutomationsView())
        case "terms": return AnyView(TermsGateView(onAccept: {}))
        case "hydration": return AnyView(HydrationView())
        case "smartalarm", "sleepplanner": return AnyView(SmartAlarmView())
        case "widgets": return AnyView(WidgetSettingsView())
        case "onboarding": return AnyView(OnboardingWizard(onFinished: {}))
        case "chargebreakdown": return AnyView(ChargeBreakdownDemoHost())
        case "devices":  return AnyView(DevicesView())
        case "friends":  return AnyView(FriendsView())
        case "devicescatalog": return AnyView(DeviceCardCatalog())
        case "fitnessage": return AnyView(FitnessAgeDemoScreen())
        case "vitality": return AnyView(VitalityDemoScreen())
        case "addwizard": return AnyView(AddWizardDemoHost())
        // Oura onboarding: the Add-device wizard deep-linked straight to the Oura factory-reset-and-adopt
        // prep step (the Beta banner + get/lose card + the red irreversible-consent gate), screenshot-able
        // WITHOUT a ring.
        case "ouraonboarding": return AnyView(OuraOnboardingDemoHost())
        // Oura device card: the locally-adopted Oura ring card (Beta chip + per-gen honest capability copy
        // + battery + local-state note), rendered with mock data, no ring required.
        case "ouradevice": return AnyView(OuraDeviceDemoScreen())
        // #221: a WHOOP 5/MG whose encrypted bond was refused (#78) - the "Connected · not paired" pill
        // + self-service pairing guidance, screenshot-able WITHOUT reproducing the bond refusal on real
        // hardware.
        case "bondrefused": return AnyView(BondRefusedDemoScreen())
        default:         return nil
        }
    }
}
#endif
#endif

#if DEBUG
/// DEBUG-only host so `--demo-screen addwizard` can render the multi-step Add-a-device wizard.
/// A SwiftUI View body is main-actor, so it can pull the injected LiveState and hand it to the
/// wizard's `init(live:)` (the nonisolated DemoScreens switch can't construct a LiveState itself).
private struct AddWizardDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View { AddDeviceWizard(live: live, onClose: {}) }
}

private struct CycleTrackerDemoHost: View {
    @EnvironmentObject private var repo: Repository

    private let result = CyclePhaseEngine.Result(
        phase: .luteal,
        confidence: .building,
        cycleDayLow: 20,
        cycleDayHigh: 24,
        cycleLengthDays: 29,
        nextPeriodWindow: .init(
            earliestDay: "2026-08-27",
            latestDay: "2026-08-31"
        ),
        shiftMarkers: [],
        note: "Your logged dates and nightly temperature suggest a luteal-range pattern."
    )

    var body: some View {
        CycleTrackerView(
            result: result,
            curve: [-0.2, -0.1, 0.0, 0.1, 0.3, 0.5, 0.6]
        )
        .task {
            let today = Repository.localDayKey(Date())
            _ = await repo.logPeriodStart(day: today)
            _ = await repo.saveCycleDailyLog(
                day: today,
                flow: .medium,
                symptoms: [.cramps, .fatigue, .bloating]
            )
            if let prior = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                _ = await repo.saveCycleDailyLog(
                    day: Repository.localDayKey(prior),
                    flow: .light,
                    symptoms: [.headache]
                )
            }
        }
    }
}

/// DEBUG-only host so `--demo-screen ouraonboarding` renders the Add-device wizard deep-linked to the
/// Oura factory-reset-and-adopt prep step (the Beta banner + what-you-get/what-you-lose card + the red
/// irreversible-consent gate). A SwiftUI View body is main-actor, so it can pull the injected LiveState
/// and seed the wizard's `startAt` into the Oura prep step without a ring present.
private struct OuraOnboardingDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        AddDeviceWizard(live: live, onClose: {}, startAt: (.oura, .prep))
    }
}
#endif
