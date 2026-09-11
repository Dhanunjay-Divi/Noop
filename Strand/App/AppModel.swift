import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport
#if os(iOS)
import UserNotifications
#endif

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
    case xiaomi
}

private enum ManualWorkoutSaveError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "The local health database is unavailable."
        }
    }
}

/// Upgrade boundary for formula changes that do not alter raw-input fingerprints.
///
/// A revision string, rather than a one-shot boolean, makes every future Charge revision fail open into
/// a full-history rescore. Completion is persisted only after `analyzeRecent` returns a receipt.
enum ChargeFormulaUpgradeGate {
    static let completedRevisionKey = "noop.analysis.completedChargeFormulaRevision"
    static let historyDays = 4_000
    static var currentRevision: String { NoopScoreAlgorithmRevision.charge }

    static func needsRescore(completedRevision: String?) -> Bool {
        completedRevision != currentRevision
    }

    static func revisionToPersist(passCompleted: Bool, wasRequired: Bool) -> String? {
        passCompleted && wasRequired ? currentRevision : nil
    }
}

/// Upgrade boundary for the persisted Active Minutes series.
///
/// Existing installs may already have an unchanged raw-input watermark from a build that did not write
/// these rows. One bounded 21-day pass is enough to populate the seven-day card without reprocessing the
/// user's full history.
enum ActiveZoneUpgradeGate {
    static let completedRevisionKey = "noop.analysis.completedActiveZoneRevision"
    static let historyDays = 21
    static let currentRevision = "noop-active-zone-v1"

    static func needsRescore(completedRevision: String?) -> Bool {
        completedRevision != currentRevision
    }

    static func revisionToPersist(passCompleted: Bool, wasRequired: Bool) -> String? {
        passCompleted && wasRequired ? currentRevision : nil
    }
}

struct AdaptiveDayEvaluationGenerationGate {
    private(set) var generation: UInt64 = 0

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func begin() -> UInt64 {
        invalidate()
        return generation
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }
}

/// Root app state: owns the live BLE connection state and the CoreBluetooth engine.
/// More subsystems (Repository, AnalyticsEngine, ImportCoordinator) get wired in here
/// in later milestones.
@MainActor
final class AppModel: ObservableObject {
    /// The live instance, so an AppIntent (Shortcuts) can reach the bonded strap rather than spinning
    /// up a dead second AppModel (which would start a duplicate BLE engine and never buzz). Published only
    /// after launch access; `weak` so a closed or still-locked app asks the user to open it. (#42)
    static weak var shared: AppModel?

    /// Idle scoring is only a safety-net. Imports, completed syncs, edits, recalibration and foreground
    /// refreshes each force their own pass, so a 30-minute cadence avoids repeatedly rescoring the full
    /// lookback while live HR advances the fingerprint every second.
    nonisolated static let analysisBackstopNanoseconds: UInt64 = 1_800_000_000_000
    private static let ageMetricReconciledProfileStateKey =
        "noop.ageMetrics.reconciledProfileState.v2"

    /// Timestamp formatter for the generic-HR strap-log lines routed through `straplog` into the shared
    /// log (issue #421). Mirrors `BLEManager.logTimeFormatter`'s `HH:mm:ss` so WHOOP and HR-strap lines
    /// read identically in the exported strap log.
    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// The CANONICAL imported/computed id ("my-whoop"). The WHOOP-IMPORT target (`WhoopImporter`), the
    /// FusionSource `.whoopImport` mapping, and a manually-saved workout all land under THIS stable id, and
    /// the engine writes its computed scores under the matching `-noop` sibling. It must NOT follow the
    /// active strap (#814 union-model follow-up): a remove+re-add gives the strap a fresh "whoop-<uuid>" id,
    /// but if the import/computed target drifted to it, history banked earlier under "my-whoop" would be
    /// orphaned. The Repository's ACTIVE-strap read id follows the registry instead (`adoptActiveDevice`),
    /// and the dashboard reads the UNION of the two, so the re-added strap's live data AND the canonical
    /// history both surface. `let` because nothing moves it.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine , scans, connects, bonds, streams.
    let ble: BLEManager
    /// Independent Bluetooth SIG Weight Scale collector (0x181D/0x2A9D). It never participates in
    /// the active HR-source coordinator and therefore cannot interrupt the WHOOP connection.
    let weightScaleSource: WeightScaleSource
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile: ProfileStore
    /// Behaviour settings: double-tap action, wear automation, zone coaching, smart alarm, illness watch.
    let behavior: BehaviorStore
    /// Current delivery state for the unified fixed-time / detected-duration alarm surface.
    @Published private(set) var smartAlarmRuntimeState: SmartAlarmRuntimeState = .off
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine

    /// Opt-in AI coach (bring-your-own-key), off until the user enables it.
    let coach: AICoachEngine

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator.
    /// Built lazily once the store opens (see `wireSourceCoordinator`). nil until then , with no generic
    /// strap paired the active id stays "my-whoop", so this never affects the WHOOP startup path.
    /// `@Published` so the Devices screen re-renders the moment the registry is wired in (it observes
    /// `model.deviceRegistry`); nested `registry.$devices` changes are observed by the screen directly.
    @Published private(set) var deviceRegistry: DeviceRegistry?
    /// Runs exactly one device's live BLE at a time. DORMANT whenever WHOOP is active (the default and
    /// every no-strap case): it only acts when a non-WHOOP generic strap becomes the active device,
    /// pausing WHOOP and running the isolated `StandardHRSource`. nil until wired (post store-open).
    private(set) var sourceCoordinator: SourceCoordinator?

    /// Timestamps of moments marked via a double-tap (persisted).
    @Published var moments: [Date] = []

    /// Timestamps of "sleep marks" tapped on the strap (#461) , bedtime / wake / mid-night marks the
    /// user double-taps without screenshots or remembering the time. Persisted; each also writes a
    /// greppable "Sleep mark @ HH:mm" line into the strap log. Phase-1 foundation for tap-driven sleep
    /// bounds + personal sleep-stage calibration.
    @Published var sleepMarks: [Date] = []

    /// An in-progress manually-tracked workout (requested by users who want to start a session
    /// themselves rather than rely on auto-detection). Holds the start time + the live HR collected
    /// since; on End the window is scored via `StrainScorer` and saved as a `WorkoutRow` (source
    /// "manual"), which then shows in the Workouts view. The day's strain already counts this HR (it's
    /// the same live stream the store persists), so this is a per-session annotation, not a double-count.
    @Published var activeWorkout: ActiveWorkout?
    /// The just-ended workout, for a brief inline confirmation on Live (cleared on the next start).
    @Published var lastWorkout: WorkoutRow?
    /// Finishing is a small durable transaction: the recovery snapshot stays present until the workout
    /// row commits. These states keep Retry/Discard explicit instead of silently losing a failed save.
    @Published private(set) var workoutSaveInProgress = false
    @Published private(set) var workoutSaveError: String?

    /// Records the GPS route of an in-flight distance-type workout (run / ride / walk / hike) from
    /// CoreLocation (#524) , the Apple analogue of Android's `GpsSession` + foreground `LocationManager`.
    /// Fails safe: on a Mac with no GPS, or when location permission is denied, it records nothing and
    /// the session still banks HR + Effort without a route. Observed by the live workout card for live
    /// distance/pace; its final route is persisted on End via `RouteStore`, keyed by the saved row's
    /// natural key (the shared `WorkoutRow` has no route column on Apple). Default behaviour is opt-in by
    /// sport: it only arms for a `WorkoutCatalog.Sport.isDistanceSport`, and only actually captures once
    /// the user grants When-In-Use location.
    let gpsRecorder = GpsWorkoutRecorder()
    /// Whether the manual workout is a GPS distance sport. This intent survives a stopped/failed-save
    /// phase and process death; `gpsRecorder.isRecording` separately describes the live hardware stream.
    private var activeWorkoutGpsEnabled = false
    /// Latest compact, validated accepted-route checkpoint, persisted in the SAME recovery snapshot as
    /// the workout. nil means no accepted location fix—not zero distance and never a fabricated route.
    private var activeWorkoutRouteCheckpoint: WorkoutRouteCheckpoint?
    /// Bounds full recovery-snapshot rewrites for the growing ~1 Hz HR array. Lifecycle/GPS checkpoints
    /// also reset this cursor; End always forces one final snapshot before save.
    private var workoutRecoveryCadence = WorkoutRecoveryCadence()
    /// The sensor window is capture state, not presentation state. Keeping it outside the published
    /// `ActiveWorkout` avoids copy-on-write cloning a growing array on every accepted packet.
    private var activeWorkoutSamples: [HRSample] = []
    /// Exact running sum for O(1) live average updates.
    private var activeWorkoutHeartRateTotal = 0
    /// Live Effort is presentation data and does not need a full-window score on every ~1 Hz packet.
    /// The final saved workout is still rescored from the complete window.
    private var workoutLiveStrainCadence = WorkoutLiveStrainCadence()
    /// A manual workout owns one logical realtime lease from explicit Start through End. The central
    /// foreground policy temporarily disarms its physical stream when the app is inactive without
    /// ending or corrupting the durable workout.
    private var activeWorkoutOwnsRealtimeLease = false

    /// A manual workout's lightweight presentation state. The growing sensor window stays private so
    /// publishing a live-stat change never copies thousands of samples through SwiftUI.
    struct ActiveWorkout: Equatable {
        let start: Date
        /// The named sport chosen at start (e.g. "Tennis", "Padel") , persisted as the saved row's
        /// `sport` so a live-tracked session keeps its label instead of the old generic "Workout".
        /// Defaults to the catalogue default ("Other") when started without a pick. (#519)
        var sport: String = WorkoutCatalog.defaultSportName
        var liveStrain: Double = 0
        var avgHr: Int = 0
        var peakHr: Int = 0
        /// Frozen when the user taps End. A non-nil value means capture has stopped and this exact bounded
        /// session is waiting for (or retrying) its durable database save.
        var endedAt: Date? = nil
    }
    /// Illness/strain early-warning (recent RHR up + HRV down + skin-temp up vs baseline). nil = clear.
    @Published var healthAlert: String?

    // MARK: - v5 pillar snapshot (engines run in the analytics pass; the views read these)
    //
    // The Insights / skin-temp Health-hub cards take pure engine RESULTS by value. The analytics pass
    // (IntelligenceEngine.analyzeRecent → refreshV5Signals) computes them once from the stores and
    // publishes them here; AppModel exposes them so HealthView / InsightsHubView read a snapshot rather
    // than re-deriving. All opt-in / honest-nil , a nil result means "not enough data / not enabled".
    @Published var illnessSignal: IllnessSignalEngine.Result?
    /// Parallel Mahalanobis illness-distance read (IllnessDistance), computed on the SAME illness-ward
    /// z-vector as illnessSignal but NEVER gating the alert. The shipped IllnessSignalEngine stays the
    /// sole fire gate; this only surfaces a "how strong" confidence readout in the Heads-Up card when
    /// the engine has already raised. nil = not computed this pass. (Augment-only, Option A.)
    @Published var illnessDistance: IllnessDistance.Result?
    /// Cycle-phase awareness (only computed when the user has opted in; else nil). Awareness only.
    @Published var cyclePhase: CyclePhaseEngine.Result?
    /// The nightly fused-index curve (oldest→newest) feeding the cycle card's sparkline.
    @Published var cycleCurve: [Double] = []
    /// Body-clock phase estimate (circadian). nil until a usable activity profile exists.
    @Published var circadianPhase: CircadianEngine.PhaseEstimate?

    /// The L3 passive-nudge surface (haptic biofeedback "stress check-in"). The detector fires onto this
    /// from `evaluateStress`; both app roots inject it into the environment so the Breathe screen's card
    /// (and any host) surfaces the pending nudge. Owned here so the central hook can reach it. (v5 L3)
    let stressNudgeCenter = StressNudgeCenter()

    private var lastDoubleTapAt: Date = .distantPast
    private var safetySOSGestureAccumulator = SafetySOSGestureAccumulator()
    // L3 stress-onset detector state: a rolling R-R buffer + the replay-safe detector state (persisted
    // via BiofeedbackPrefs so a relaunch can't re-fire), carried verbatim between evaluations.
    private var rrBuf: [Int] = []
    private var stressState = BiofeedbackPrefs.loadStressState()
    /// Cross-surface truth gate for automatic stress nudges. View-owned workout/session/breathe flows
    /// increment/decrement this around their real running lifetime; a pending card remains a separate gate.
    /// Ref-counting is intentional because multiple explicit sessions must not clear each other's block.
    private var stressNudgeSessionCount = 0

    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Last Xiaomi / Mi Band import result surfaced in the Mi Band card.
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source , the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false
    /// A decoded Health Shortcut import waiting for explicit user confirmation before it writes rows.
    @Published var pendingShortcutHealthImport: ShortcutHealthImport.PendingImport?

    /// True while any data-source import is writing to the local store.
    var hasActiveImport: Bool { activeImportSource != nil }

    /// Returns true only for the source currently importing.
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    /// Whether the last import for a source ended in failure (for warning styling).
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }

    /// Smoothed, display-ready live heart rate , median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var stressRRBufferReceivedAt: Date?
    private var hrCancellables = Set<AnyCancellable>()
    /// Serialized, starvation-proof owner for dashboard refreshes caused by durable history commits.
    private var persistedHistoryRefreshWorker: PersistedHistoryRefreshWorker?
    /// Coalesces a burst of repository publications into one contextual-vitals read. A newer refresh
    /// cancels the pending pass; delivery itself remains deduplicated by ContextualInterventionPolicy.
    private var contextualEvaluationTask: Task<Void, Never>?
    /// Invalidates scheduler callbacks and queued evaluations before their replacement reaches EventKit.
    /// An older superseded query therefore cannot reconcile a newer workout as if the calendar were empty.
    private var adaptiveDayEvaluationGate = AdaptiveDayEvaluationGenerationGate()
    /// Debounced profile reconciliation. A DOB/sex/waist edit invalidates stored provenance immediately;
    /// this task writes the matching replacement values and then wakes metric-series-only views.
    private var ageMetricRecomputeTask: Task<Void, Never>?
    /// Resolves the workout frontier before an explicit enable. A later toggle cancels this lookup so
    /// an in-flight read can never turn the preference back on after the user switched it off.
    private var postWorkoutPreferenceTask: Task<Void, Never>?
    /// Last profile token handed to the focused age-metric reconciler. Unlike the profile publishers,
    /// this also detects age changing naturally across a birthday when the app returns to foreground.
    private var lastAgeMetricProfileState: String?
    /// Manual workouts consume the live sensor EVENT stream, never repeated reads of cached display HR.
    private var workoutHeartRateCursor = WorkoutHeartRateCursor(consumedSequence: 0)
    /// Sustained, artifact-gated exertion policy for the current manual workout. It is recreated from
    /// the durable session start after a relaunch; warm-up and dwell then rebuild from fresh samples.
    private var workoutCautionPolicy: WorkoutCautionPolicy?
    /// Drives the READ spine off the registry's active device (#814 HIGH-1). A Devices-screen
    /// switch/remove/re-add calls `registry.setActive` DIRECTLY (not through `registerDevice`), so without
    /// this subscription the reads stayed pinned to whatever id was active at wiring time for the whole
    /// session. Mirrors how `SourceCoordinator` drives the WRITE side off the same publisher. Retained for
    /// the app's lifetime (the registry outlives the session); `removeDuplicates` collapses redundant emits.
    private var readSpineCancellable: AnyCancellable?
    /// Daily re-arm timer for the single-instant firmware smart alarm (see scheduleDailySmartAlarmRearm).
    private var smartAlarmRearmTimer: Timer?
    /// The temporary launch gate may construct the observable graph while deliberately leaving every
    /// hardware/background subsystem inert. This latch makes the later unlock edge idempotent.
    private var operationalWorkStarted = false

    #if DEBUG
    nonisolated static func shouldStartDemoFixtureWork(
        startOperationalWork: Bool,
        arguments: [String]
    ) -> Bool {
        !startOperationalWork && arguments.contains("--demo-seed")
    }
    #endif

    private static func applyPendingRestoreAtColdLaunch() {
        do {
            let path = try StorePaths.defaultDatabasePath()
            switch try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: path) {
            case .none:
                break
            case .applied:
                AppDiagnosticsRecorder.shared.record(
                    "database_restore.cold_launch",
                    fields: ["outcome": "applied"]
                )
            case .discarded:
                AppDiagnosticsRecorder.shared.record(
                    "database_restore.cold_launch",
                    fields: ["outcome": "discarded"]
                )
            }
        } catch {
            // The per-process claim prevents StoreOpenGate from retrying after ProfileStore/BLE/Repository
            // have been constructed; it repeats the recorded failure instead of opening an uncertain
            // store. The untouched pending manifest is retried from this same cold boundary next launch.
            AppDiagnosticsRecorder.shared.record(
                "database_restore.cold_launch",
                fields: [
                    "outcome": "deferred",
                    "failure_kind": AppDiagnosticsRecorder.failureKind(error),
                ]
            )
        }
    }

    init(startOperationalWork: Bool = true) {
        // A restore is validated/staged by the running app and consumed only on a cold launch. Apply it
        // synchronously before ProfileStore reads the restored settings and before BLE/Repository can
        // create either of the two live WhoopStore pools. PendingDatabaseRestore's per-process claim also
        // prevents any store opened later in THIS session from consuming a restore the user just staged.
        if startOperationalWork {
            Self.applyPendingRestoreAtColdLaunch()
        }
        let profile = ProfileStore()
        self.profile = profile
        self.lastAgeMetricProfileState = UserDefaults.standard.string(
            forKey: Self.ageMetricReconciledProfileStateKey)
        self.behavior = BehaviorStore()
        let live = LiveState()
        self.live = live
        self.weightScaleSource = WeightScaleSource(
            resumeRememberedRuntimeAtLaunch: startOperationalWork
        )
        // SEED every subsystem with the same id (`deviceId`, "my-whoop" at launch). The store/registry
        // aren't open yet here, so the registry's active id can't be read synchronously; `bootstrapStore`
        // (write side) and `wireSourceCoordinator → adoptActiveDevice` (read spine, #814) re-point them to
        // the registry active id once the store opens. Single-device install keeps "my-whoop" throughout.
        self.ble = BLEManager(
            state: live,
            deviceId: deviceId,
            resumeRememberedRuntimeAtLaunch: startOperationalWork
        )
        self.repo = Repository(deviceId: deviceId)
        self.coach = AICoachEngine(repo: repo)
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: deviceId)
        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log every other
        // subsystem writes to (PII-scrubbed by `live.append(log:)`), so a bug report ships proof of what
        // was computed per day. `live` is captured strongly (created just above) , the engine outlives the
        // app session, so there's no retain-cycle risk worth a weak dance here. (Sleep overhaul §2.5.)
        self.intelligence.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }
        // Workouts & GPS test mode (Test Centre): wire the Repository (auto-detect inputs/why + cross-source
        // dedup decisions) and the GPS recorder (fix-progress) tagged sinks to the SAME shareable strap log.
        // Each emitter re-checks `TestCentre.active(.workouts)` before building a line, so these wirings are
        // inert (one UserDefaults bool read) when the mode is off. `live` is captured strongly, as above.
        self.repo.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        self.gpsRecorder.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        // Each bounded recorder checkpoint is folded into the same atomic recovery snapshot as HR. A
        // late callback after End is ignored; End forces and snapshots its own final checkpoint once.
        self.gpsRecorder.checkpointSink = { [weak self] checkpoint in
            guard let self, self.activeWorkoutGpsEnabled,
                  self.activeWorkout?.endedAt == nil else { return }
            self.activeWorkoutRouteCheckpoint = checkpoint
            self.persistActiveWorkout()
        }
        // #961: give the read model the user's HRmax + sex so it can backfill a strap-native workout's
        // Effort on display when the stored value is nil (a live/manual session that ended with sparse HR).
        // Seed it now and keep it in step with any profile edit (objectWillChange fires just before a
        // @Published setter lands, so read the CURRENT values , they're already committed by the time the
        // next reconcile reads `strainProfile`). Display-only; the score itself is unchanged.
        self.repo.strainProfile = Repository.StrainProfile(hrMax: Double(profile.hrMax), sex: profile.sex)
        profile.objectWillChange.sink { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.repo.strainProfile = Repository.StrainProfile(
                    hrMax: Double(self.profile.hrMax), sex: self.profile.sex)
            }
        }.store(in: &hrCancellables)
        Publishers.CombineLatest3(profile.$dateOfBirth, profile.$sex, profile.$waistCm)
            .map { dateOfBirth, sex, waist in
                "\(dateOfBirth.timeIntervalSinceReferenceDate)|\(sex)|\(waist)"
            }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleAgeMetricRecompute()
            }
            .store(in: &hrCancellables)
        // Every valid standards-level scale indication is first persisted with its source + precise
        // timestamp. Only the explicitly selected scale user (or a single-user packet with no user id)
        // may then project into ProfileStore; the shared freshness API prevents a stored backlog from
        // rolling the profile backwards.
        weightScaleSource.$latestCapture
            .compactMap { $0 }
            .sink { [weak self] capture in
                Task { [weak self] in await self?.ingestWeightScaleCapture(capture) }
            }
            .store(in: &hrCancellables)
        // Smooth HR centrally so it's solid everywhere it's shown. Only an R-R publication may advance
        // the stress detector: an HR-only callback can otherwise append the same cached R-R packet again
        // and counterfeit the detector's distinct-window warm-up.
        live.$heartRate.sink { [weak self] _ in
            self?.ingestHR(shouldEvaluateStress: false)
        }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] intervals in
            self?.ingestHR(shouldEvaluateStress: true, rrPacket: intervals)
        }.store(in: &hrCancellables)
        // Mirror only the history-write edge onto Repository. Today/Sleep already observe Repository for
        // data revisions, so this gives their first render a synchronous gate without making the heavy
        // screen roots observe LiveState's sensor-rate publications.
        live.$backfilling.removeDuplicates().sink { [weak self] active in
            self?.repo.setHistoryWritesActive(active)
        }.store(in: &hrCancellables)
        // A natural history sync can publish the missing half of the stress evidence after the latest
        // R-R packet. Re-evaluate the already-buffered R-R window without appending that packet again.
        live.$recentWristMotionEvidence.dropFirst().sink { [weak self] _ in
            // @Published emits before its backing value is committed. Defer one main-queue turn so the
            // evaluator reads the newly-published evidence rather than the previous window.
            DispatchQueue.main.async {
                self?.evaluateStress()
            }
        }.store(in: &hrCancellables)
        // Capture a workout point only for a genuine accepted HR packet. The LiveState event carries a
        // monotonic identity + receipt timestamp, unlike @Published display state, so an R-R republish,
        // timer tick, or cached BPM after disconnect cannot add duplicate/synthetic strain samples.
        live.heartRateSamplePublisher.sink { [weak self] sample in
            self?.captureWorkoutSample(sample)
        }.store(in: &hrCancellables)
        behavior.$zoneCoaching.dropFirst().sink { [weak self] enabled in
            if !enabled {
                self?.workoutCautionPolicy = nil
            }
        }.store(in: &hrCancellables)
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                WindDownNudge.restoreScheduleIfAuthorized()
                self.scheduleContextualInterventionEvaluation()
            }
            .store(in: &hrCancellables)
        NotificationCenter.default.publisher(for: PlannedWorkoutCalendarStore.providerDidChange)
            .sink { [weak self] _ in
                self?.scheduleContextualInterventionEvaluation()
            }
            .store(in: &hrCancellables)
        NotificationCenter.default.publisher(for: ContextualInterventionInputs.didChange)
            .sink { [weak self] _ in
                self?.scheduleContextualInterventionEvaluation()
            }
            .store(in: &hrCancellables)

        // Physical-input + wear hooks (fired live by FrameRouter).
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        // Re-arm the next day's firmware alarm the moment the strap reports it fired (if/when the
        // firmware pushes STRAP_DRIVEN_ALARM_EXECUTED). Gated on enabled inside applySmartAlarm.
        live.onSmartAlarmFired = { [weak self] in
            guard let self, self.behavior.smartAlarmEnabled else { return }
            TapAutomationPreferences.armAlarmDismiss()
            // PR #577 (iOS): mirror the strap's wake buzz to a local notification so a phone-in-pocket
            // user still gets woken; no-op on macOS / when wrist alerts are off.
            AppModel.postSmartAlarm()
            if self.behavior.smartAlarmMode.usesDetectedSleep {
                let target = Self.smartAlarmTargetMinutes(
                    mode: self.behavior.smartAlarmMode,
                    fixedMinutes: self.behavior.smartAlarmDurationMinutes,
                    adaptiveMinutes: WindDownNudge.targetSleepMinutes
                )
                if self.behavior.smartAlarmArmedSessionStart > 0 {
                    self.behavior.smartAlarmLastFiredSessionStart =
                        self.behavior.smartAlarmArmedSessionStart
                }
                self.behavior.smartAlarmArmedSessionStart = 0
                Self.cancelSmartAlarmBackupNotification()
                self.smartAlarmRuntimeState = .durationReached(
                    asleepMinutes: target,
                    targetMinutes: target
                )
            } else {
                self.applySmartAlarm()
            }
        }
        // Strap battery alerts (#368): low-battery warning + full-charge note. The notifier self-gates
        // on the user's setting and the OS authorization, and carries its own persisted once-per-
        // crossing state, so feeding it every battery reading is safe.
        live.onBatteryUpdate = { [weak self] pct in
            guard let self else { return }
            BatteryNotifier.onBatteryUpdate(pct: Int(pct.rounded()),
                                            charging: self.live.charging,
                                            enabled: self.behavior.batteryAlerts)
            // Predictive runtime alert: the same reading just banked into the SoC buffer, so
            // batteryEstimate is fresh here. Nil estimate (no readings yet) is a no-op — the 15%
            // alert above remains the safety net.
            BatteryNotifier.onRuntimeEstimate(remainingHours: self.live.batteryEstimate?.remainingHours,
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts
                                                    && self.behavior.batteryPredictiveAlerts)
        }
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in
            guard let self, self.operationalWorkStarted else { return }
            self.evaluateIllness(days)
            self.evaluateStrainTarget()
            ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()
            self.scheduleContextualInterventionEvaluation()
        }.store(in: &hrCancellables)
        repo.$refreshSeq.dropFirst().sink { [weak self] _ in
            guard let self, self.operationalWorkStarted else { return }
            ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()
            self.scheduleContextualInterventionEvaluation()
        }.store(in: &hrCancellables)
        // A newly-published detected session is the authoritative duration-alarm input. Reconcile after
        // every real sleep-cache change; repeated analysis of the same session is deduplicated by onset.
        repo.$sleeps.dropFirst().sink { [weak self] sessions in
            guard let self,
                  self.behavior.smartAlarmEnabled,
                  self.behavior.smartAlarmMode == .sleepDuration else { return }
            self.reconcileSleepDurationAlarm(sessions: sessions)
        }.store(in: &hrCancellables)
        // Re-arm the strap's firmware alarm once the connection has SETTLED — not the instant it (re)bonds.
        // A smart-alarm time changed while the strap was away never reached it , the send is gated on bond
        // , so the strap kept the OLD time and fired at it (#59).
        //
        // #34: keyed off `connectSettled` (a monotonic counter BLEManager bumps once the connect handshake
        // has both run AND the cmd-notify characteristic has confirmed subscribed — see LiveState.swift /
        // BLEManager.maybeSignalConnectSettled), NOT off raw `bonded`. `state.bonded` publishes from
        // INSIDE BLEManager's connect-handshake continuation (the bonding-confirm write's
        // didWriteValueFor), and Combine delivered to a `$bonded` sink SYNCHRONOUSLY on that same call
        // stack — arming there nested the alarm's SET_CLOCK/SET_ALARM_TIME/GET_ALARM_TIME burst in the
        // MIDDLE of the handshake, ahead of its own clock-set and before the cmd-notify channel was
        // confirmed subscribed. A strap log (#34 v8.6.2) confirmed the result: the alarm's GET_ALARM_TIME
        // readback got no reply at all — the strap's answer had nowhere confirmed-subscribed to land.
        // `connectSettled` only bumps once that channel is confirmed live, so the readback (and the arm
        // itself) always goes out on a link that's actually ready. `dropFirst()` skips the initial
        // published value (0) at subscribe time, so this doesn't fire on app launch before any connection.
        live.$connectSettled.dropFirst().sink { [weak self] _ in
            guard let self, self.operationalWorkStarted,
                  self.behavior.smartAlarmEnabled else { return }
            self.applySmartAlarm()
        }.store(in: &hrCancellables)
        // The firmware alarm is a single absolute instant with no recurrence, and was re-armed ONLY on
        // a (re)bond or a settings change. A strap that stays continuously bonded (a Mac in range) would
        // fire once and never re-arm , silent from day two. Re-arm daily so an always-on session keeps
        // waking the user.
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap should hold the dense
        // realtime stream armed even with no Live screen open, so it banks beat-to-beat R-R 24/7 for
        // better overnight HRV/recovery/sleep. The BLE reconciler arms it on the off→on edge; pushing it
        // here (and at the init tail) covers a fresh launch and every reconnect. (See PuffinExperiment.)
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            guard let self, self.operationalWorkStarted else { return }
            self.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
            self.applyPowerSaving()
        }.store(in: &hrCancellables)
        // Newly inserted history has reached durable storage. This receipt is intentionally separate from
        // `lastSyncedAt`: a session can save valid overnight chunks and then end on the idle watchdog or a
        // disconnect before HISTORY_COMPLETE. Those rows still need scoring now, not at the next backstop.
        //
        // A resettable debounce starved this path when a deep offload committed about every 1.4 seconds:
        // the two-second quiet edge never arrived, so rows accumulated for an hour while dashboard
        // calibration appeared frozen. The revision worker gives the first commit a quick pass, coalesces
        // continuous commits to a bounded cadence, serializes expensive reads/scoring, and still performs
        // the final quiet-edge pass after the transfer stops.
        persistedHistoryRefreshWorker = PersistedHistoryRefreshWorker { [weak self] in
            await self?.refreshAfterPersistedHistory()
        }
        live.historyDataPublisher
            .removeDuplicates()
            .sink { [weak self] revision in
                self?.persistedHistoryRefreshWorker?.noteCommit(revision: revision)
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        #if DEBUG
        // Publish screenshot-only live state before SwiftUI mounts. Repository/registry startup can
        // subsequently reconcile transport identity, so each demo startup path reasserts this fixture
        // once its own wiring is complete.
        AppleDemoSeeder.applyLiveFixtureIfRequested(to: live)
        #endif
        if startOperationalWork {
            startOperationalWorkAfterLaunchAccess()
        }
        #if DEBUG
        if Self.shouldStartDemoFixtureWork(
            startOperationalWork: startOperationalWork,
            arguments: CommandLine.arguments
        ) {
            startDemoFixtureWork()
        }
        #endif
    }

    #if DEBUG
    /// Prepare deterministic screenshot/UI-test data without crossing the protected hardware boundary.
    /// `--demo-seed` deliberately bypasses first-run presentation gates, but a clean simulator can still
    /// have no launch-access receipt. In that state the full operational runtime must remain off while the
    /// synthetic store and registry still need to materialize for production-screen layout tests.
    private func startDemoFixtureWork() {
        Task(priority: .utility) { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            await AppleDemoSeeder.seedIfRequested(
                into: store,
                profileAge: self.profile.age,
                profileSex: self.profile.sex
            )
            await self.repo.refresh()
            _ = await self.wireDeviceRegistry()
            AppleDemoSeeder.applyLiveFixtureIfRequested(to: self.live)
        }
    }
    #endif

    /// Cross the hardware/background boundary after the launch-access receipt is valid. The locked app
    /// still owns a lightweight observable graph for SwiftUI injection, but does not restore Bluetooth,
    /// resume a scale, publish App Intents, restore SOS sharing, purge files, or open the analysis loop.
    /// A pending database restore deliberately waits for the next cold launch because applying it after
    /// ProfileStore/Repository construction would violate the restore transaction's cold-start contract.
    func startOperationalWorkAfterLaunchAccess() {
        guard !operationalWorkStarted else { return }
        let trace = AppDiagnosticsRecorder.shared.beginOperation("runtime.start_operational_work")
        defer {
            AppDiagnosticsRecorder.shared.endOperation(
                trace,
                includeResourceSnapshot: true
            )
        }
        let now = Date()
        let resumedAfterBlock = AdaptiveDayTimeZoneStore.resumeAfterOperationalAccess(
            offsetSec: TimeZone.autoupdatingCurrent.secondsFromGMT(for: now)
        )
        if resumedAfterBlock {
            AppDiagnosticsRecorder.shared.record(
                "adaptive_day.time_zone_baseline",
                fields: ["outcome": "rebased_after_operational_block"]
            )
        }
        operationalWorkStarted = true

        AppModel.shared = self   // publish for App Intents only after the launch gate is open
        // An unfinished GPS workout resumes location + realtime hardware, so restoration belongs on the
        // same authorized side of the boundary as Bluetooth rather than in the lightweight initializer.
        rehydrateActiveWorkout()
        Task { @MainActor in
            await SafetySOSRuntime.shared.restoreLocationSharingIfNeeded()
        }
        scheduleDailySmartAlarmRearm()

        // Seed preferences before restoring the central so its first powered-on callback sees the final
        // realtime/power-saving intent. Both calls and both resume paths are idempotent.
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        applyPowerSaving()
        ble.resumeRememberedRuntimeAfterLaunchAccess()
        weightScaleSource.resumePairedScale()

        Task.detached { AppModel.purgeImportInbox(); AppModel.purgeImportTemp() }

        startAnalysisLoop()
        ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()
        scheduleContextualInterventionEvaluation()
    }

    /// Turn the strap's offloaded raw data into dashboard scores on launch and every 30 minutes. Kept in
    /// a separate helper so a locked process can start the exact same loop once, on the unlock edge.
    private func startAnalysisLoop() {

        // FIX 2(b): the launch sequence runs at `.utility` so its heavy one-shot 4000-day heal/rescore
        // yields to UI rendering instead of contending at the inherited user-initiated QoS. The reads are
        // already off the main actor (analyzeRecent , FIX 1), and at `.utility` the scheduler keeps the
        // main thread free for SwiftUI during the deep-history pass right after an import / first launch.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            #if DEBUG
            // DEBUG-only: when launched with `--demo-seed`, populate a deterministic synthetic
            // dataset so an empty simulator/dev build can walk every screen (verification + marketing
            // screenshots). No-op in Release (whole seeder is #if DEBUG) and once data already exists.
            if AppleDemoSeeder.requested, let store = await self.repo.storeHandle() {
                await AppleDemoSeeder.seedIfRequested(
                    into: store,
                    profileAge: self.profile.age,
                    profileSex: self.profile.sex
                )
            }
            #endif
            await self.repo.refresh()                          // surface any imported data at once
            // Vitality v2 is a provenance/model boundary, so reconcile it once per launch even when the
            // raw scoring-input fingerprint is unchanged and the normal analysis backstop will short-circuit. This
            // removes only legacy computed vitality/body-age rows; imported/vendor metrics are untouched.
            #if DEBUG
            // The screenshot fixture has no confirmed onboarding profile; its synthetic scores carry an
            // explicit v2 marker from the seeder and must not be mistaken for released v1 user data.
            if !AppleDemoSeeder.requested {
                let trace = AppDiagnosticsRecorder.shared.beginOperation(
                    "analysis.vitality_reconcile"
                )
                _ = await self.intelligence.recomputeVitalityOnly()
                AppDiagnosticsRecorder.shared.endOperation(trace)
            }
            #else
            let trace = AppDiagnosticsRecorder.shared.beginOperation(
                "analysis.vitality_reconcile"
            )
            _ = await self.intelligence.recomputeVitalityOnly()
            AppDiagnosticsRecorder.shared.endOperation(trace)
            #endif
            await self.wireSourceCoordinator()                 // dormant unless a generic strap is active
            #if DEBUG
            AppleDemoSeeder.applyLiveFixtureIfRequested(to: self.live)
            #endif
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            // FIX 2(a): DEFER the heavy one-shot 4000-day heal/rescore while an import is in flight. A
            // large Apple Health import is the worst-case launch overlap , running a 4000-iteration heal
            // + rescore concurrently with the import's parse+writes is what produced the ~1-minute app-wide
            // lag. The import refreshes the dashboard itself on completion, and the steady-state cadence
            // loop below still runs, so deferring the ONE-SHOT passes until the import finishes costs
            // nothing but removes the contention. Bounded poll (respects cancellation); typical imports
            // clear in seconds, so this almost always passes through immediately.
            // CAP the wait (#review): `hasActiveImport` is cleared only by finishImport(), which a true
            // non-throwing import HANG would never reach, permanently starving the one-shot passes AND the
            // cadence loop below for the whole session. Bound it so a wedged import can't disable analysis;
            // the merge reads are off-actor now, so proceeding under a still-flagged import is safe.
            var importWaited = 0
            while self.hasActiveImport && !Task.isCancelled && importWaited < 180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s, re-check; ~3 min cap then proceed
                importWaited += 1
            }
            // One-shot on-upgrade heal (#547): purge rows a bad-clock strap dated to scattered garbage
            // (far-past / bogus-2027 / FUTURE) from an older build, then rescore the real days. Runs
            // BEFORE the Effort rescore + analyzeRecent loop so both operate on a cleaned DB. Persisted
            // flag → no-op on every subsequent launch; idempotent on a clean DB.
            var operation = AppDiagnosticsRecorder.shared.beginOperation(
                "analysis.timestamp_heal"
            )
            await self.intelligence.runTimestampHealIfNeeded()
            AppDiagnosticsRecorder.shared.endOperation(operation)
            // One-shot on-upgrade Effort rescore (#313): recompute strain from source across the FULL
            // history once, so any deep-history rows an older build left on the 0–21 axis regenerate on
            // the 0–100 axis. Guarded by a persisted flag, so this is a no-op on every subsequent launch.
            operation = AppDiagnosticsRecorder.shared.beginOperation(
                "analysis.effort_rescore"
            )
            await self.intelligence.runEffortRescoreIfNeeded()
            AppDiagnosticsRecorder.shared.endOperation(operation)
            while !Task.isCancelled {
                // #547 RE-POLLUTION: a sync since the last tick may have armed a re-heal (its ingest gate
                // dropped bad-clock records). `runTimestampHealIfNeeded` honours the pending flag even after
                // the one-shot done flag is set, purges any pollution, and rescores the affected days , so a
                // wandering-clock strap can't keep re-polluting. A no-op when nothing's pending.
                operation = AppDiagnosticsRecorder.shared.beginOperation(
                    "analysis.timestamp_heal_backstop"
                )
                await self.intelligence.runTimestampHealIfNeeded()
                AppDiagnosticsRecorder.shared.endOperation(operation)
                // #836: the steady-state tick is a BACKSTOP, not a data-driven refresh. A formula-only app
                // upgrade does not move the raw-input fingerprint, though, so its explicit revision marker
                // overrides that skip exactly once. Use the full history before labeling any local/remote row
                // Charge v2; a failed or overlapping pass returns nil and leaves the marker stale for retry.
                let completedChargeRevision = UserDefaults.standard.string(
                    forKey: ChargeFormulaUpgradeGate.completedRevisionKey)
                let chargeUpgradePending = ChargeFormulaUpgradeGate.needsRescore(
                    completedRevision: completedChargeRevision)
                let completedActiveZoneRevision = UserDefaults.standard.string(
                    forKey: ActiveZoneUpgradeGate.completedRevisionKey)
                let activeZoneUpgradePending = ActiveZoneUpgradeGate.needsRescore(
                    completedRevision: completedActiveZoneRevision)
                operation = AppDiagnosticsRecorder.shared.beginOperation(
                    "analysis.recent",
                    fields: [
                        "charge_upgrade": chargeUpgradePending ? "true" : "false",
                        "active_zone_upgrade": activeZoneUpgradePending ? "true" : "false",
                    ]
                )
                let receipt = await self.intelligence.analyzeRecent(
                    maxDays: chargeUpgradePending
                        ? ChargeFormulaUpgradeGate.historyDays
                        : ActiveZoneUpgradeGate.historyDays,
                    force: chargeUpgradePending || activeZoneUpgradePending)
                AppDiagnosticsRecorder.shared.endOperation(
                    operation,
                    outcome: receipt == nil ? "skipped_or_busy" : "completed",
                    includeResourceSnapshot: true
                )
                if let revision = ChargeFormulaUpgradeGate.revisionToPersist(
                    passCompleted: receipt != nil,
                    wasRequired: chargeUpgradePending) {
                    UserDefaults.standard.set(
                        revision,
                        forKey: ChargeFormulaUpgradeGate.completedRevisionKey)
                }
                if let revision = ActiveZoneUpgradeGate.revisionToPersist(
                    passCompleted: receipt != nil,
                    wasRequired: activeZoneUpgradePending) {
                    UserDefaults.standard.set(
                        revision,
                        forKey: ActiveZoneUpgradeGate.completedRevisionKey)
                }
                // v5: recompute the skin-temp suite snapshots (cycle phase + body clock) from the
                // freshly-scored history so the Health hub cards read a ready result.
                operation = AppDiagnosticsRecorder.shared.beginOperation(
                    "analysis.v5_signals"
                )
                await self.refreshV5Signals()
                AppDiagnosticsRecorder.shared.endOperation(operation)
                try? await Task.sleep(nanoseconds: Self.analysisBackstopNanoseconds)
            }
        }
    }

    private func scheduleAgeMetricRecompute() {
        ageMetricRecomputeTask?.cancel()
        let requestedProfileState = profile.ageMetricStateToken
        ageMetricRecomputeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            async let fitnessAge = intelligence.recomputeFitnessAgeOutcome()
            async let vitality = intelligence.recomputeVitalityOutcome()
            let outcomes = await (fitnessAge, vitality)
            guard !Task.isCancelled,
                  requestedProfileState == profile.ageMetricStateToken else { return }
            // Publish successful writes or cleanups immediately, but retain the old watermark unless both
            // passes reached storage. A failed half then retries on the next foreground/unlock boundary.
            if outcomes.0.completed || outcomes.1.completed {
                repo.noteAgeMetricsChanged()
            }
            if outcomes.0.completed && outcomes.1.completed {
                lastAgeMetricProfileState = requestedProfileState
                UserDefaults.standard.set(
                    requestedProfileState,
                    forKey: Self.ageMetricReconciledProfileStateKey
                )
            }
        }
    }

    /// Reconcile profile-dependent metrics only when the derived profile token actually changed. Called
    /// after onboarding confirmation and whenever the app becomes active, which catches a birthday without
    /// polling or requiring the user to edit their date of birth.
    func refreshAgeMetricsIfProfileChanged() {
        guard profile.ageMetricStateToken != lastAgeMetricProfileState else { return }
        scheduleAgeMetricRecompute()
    }

    /// Build the device registry + source coordinator once the store is open, then start observing.
    /// #477: push the persisted Power-saving prefs to the BLE manager (parity with Android
    /// `AppViewModel.applyPowerSaving`). Offload-cadence stretch uses the battery-% threshold (0 = off
    /// when the master is off); the HRV pause is a sub-option, only effective while the master is on.
    /// The riskier connection-priority idle throttle is intentionally not wired (Android-only, and dormant).
    func applyPowerSaving() {
        let on = PuffinExperiment.powerSavingEnabled
        ble.setLowBatteryOffloadThrottle(on ? PuffinExperiment.powerSavingBatteryPct : 0)
        // HRV pause is battery-%-aware like the offload lever — pass the same threshold.
        ble.setPauseCaptureOnPowerSave(on && PuffinExperiment.pauseHrvOnPowerSaveEnabled,
                                       thresholdPct: PuffinExperiment.powerSavingBatteryPct)
    }

    /// Tiny and guarded: with no generic strap paired the active id is "my-whoop", so the coordinator
    /// observes WHOOP-active and stays a NO-OP , the existing `scan()`/`disconnect()` WHOOP flow is
    /// untouched. The coordinator only acts if/when a non-WHOOP strap becomes the active device.
    /// `startWhoop`/`stopWhoop` are thin closures over BLEManager's EXISTING public methods (via the
    /// model's `scan()` / `disconnect()`), so the coordinator never references BLEManager directly.
    private func wireDeviceRegistry() async -> DeviceRegistry? {
        if let deviceRegistry { return deviceRegistry }
        guard let store = await repo.storeHandle() else { return nil }
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        self.deviceRegistry = registry
        return registry
    }

    private func wireSourceCoordinator() async {
        guard sourceCoordinator == nil,
              let registry = await wireDeviceRegistry() else { return }
        // BLE writes connected GATT/DIS identity directly to the durable registry. Refresh this observable
        // cache on each actual identity change so Devices immediately shows WHOOP MG vs WHOOP 5.0 rather
        // than waiting for a disconnect or relaunch.
        ble.onRegistryIdentityChanged = { [weak registry] in registry?.reload() }
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            startWhoop: { [weak self] in self?.scan() },
            stopWhoop: { [weak self] in self?.disconnect() },
            // WHOOP targeting hooks , thin wrappers over BLEManager's existing additive setters, so the
            // coordinator never references BLEManager directly (mirrors the start/stop injection). On the
            // single-WHOOP path these are setPreferredPeripheral(nil) and (no setActiveDeviceId call),
            // i.e. the BLE engine's defaults , no behaviour change.
            setWhoopPreferredPeripheral: { [weak self] uuid in self?.ble.setPreferredPeripheral(uuid) },
            setWhoopActiveDeviceId: { [weak self] id in self?.ble.setActiveDeviceId(id) },
            // The engine's last-connected WHOOP uuid drives first-connect identity adoption.
            connectedPeripheralUUID: ble.$connectedPeripheralUUID.eraseToAnyPublisher(),
            // Generic-HR connect lifecycle → the SAME strap log BLEManager writes to (`live.append(log:)`),
            // so a "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc
            // path. Timestamp matches BLEManager.log()'s "HH:mm:ss" so the lines read consistently.
            straplog: { [weak self] line in
                self?.live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            })
        coordinator.start()
        self.sourceCoordinator = coordinator
        // #814 READ SPINE (HIGH-1): drive the read side off the registry's `activeDeviceId` for the WHOLE
        // session, exactly as SourceCoordinator drives the WRITE side off the SAME publisher. A Devices-
        // screen switch/remove/re-add calls `registry.setActive` DIRECTLY (NOT through `registerDevice`), so
        // a one-shot adopt at wiring time would leave the reads pinned to the launch-time active id all
        // session, a re-add's fresh "whoop-<uuid>" raw never surfaced until the next relaunch. The
        // subscription re-points the Repository's active-strap READ id on every change; `adoptActiveDevice`
        // is idempotent, so the initial emission (the current active id) does the first adopt and any later
        // explicit `adoptActiveDevice` call (e.g. from `registerDevice`) is safely redundant. The import +
        // computed WRITE targets stay STABLE on the canonical id (see `adoptActiveDevice`'s union-model note).
        readSpineCancellable = registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in
                Task { await self?.adoptActiveDevice(id) }
            }
    }

    /// Re-point the Repository's ACTIVE-strap READ id at `activeId` and, if it moved, refresh + re-score so a
    /// re-added strap's LIVE raw (written under its fresh "whoop-<uuid>" id) surfaces on the dashboard (#814).
    /// Centralised so the registry-active subscription and a device add/activate share one path. A no-op (no
    /// refresh) when the id is unchanged (the common single-device case).
    ///
    /// UNION MODEL (#814 follow-up): this moves ONLY the read-side active-strap id. The WHOOP-IMPORT + the
    /// engine's COMPUTED write target, and the FusionSource `.whoopImport` mapping, stay STABLE on the
    /// canonical `deviceId` ("my-whoop"), they must NOT follow the active strap, or history imported/scored
    /// earlier under the canonical id would be orphaned. The Repository reads the UNION of the active strap +
    /// the canonical id, so both the re-added strap's live data AND the canonical history surface. The engine
    /// already resolves the active strap per day via the registry's own active id (`resolveDayOwner`), so it
    /// reads + scores the re-added strap's raw and writes the computed result to the STABLE canonical
    /// `-noop` sibling, no engine re-point needed.
    private func adoptActiveDevice(_ activeId: String) async {
        let trimmed = activeId.trimmingCharacters(in: .whitespaces)
        let repoMoved = repo.adoptActiveDeviceId(trimmed)
        guard repoMoved else { return }
        live.append(log: "Read spine re-pointed to active device after registry change (#814).")
        await repo.refresh()
        await intelligence.analyzeRecent()
    }

    #if os(iOS)
    /// Injected by the iOS scene so freshly completed offloads write through to Apple Health instead
    /// of waiting for a later foreground launch. Nil on macOS and in headless tests.
    var healthWriteBack: (() async -> Void)?
    #endif

    private func refreshAfterPersistedHistory() async {
        guard operationalWorkStarted else { return }
        live.append(log: "Backfill: scoring newly persisted history")
        await repo.refresh(days: 120)
        // Score the freshly-offloaded raw data RIGHT NOW rather than waiting for the next 15-minute
        // analyzeRecent tick , otherwise a just-synced night's Charge / Effort / Rest can take up to
        // 15 minutes to appear on a strap-only (no-import) dashboard. analyzeRecent no-ops if a tick is
        // already running and refreshes the dashboard itself once the new scores persist. (PR #218)
        await intelligence.analyzeRecent(force: true)
        await refreshV5Signals()
        await reconcileMorningRecapNotifications()
        // A completed sync is the earliest reliable moment to inspect an offloaded session. Existing
        // users keep their chosen mode; fresh installs default to Ask until the classifier has real-world
        // validation. A legacy Auto-save preference resolves to approval-first Ask until confidence is calibrated.
        await processAutomaticWorkoutAfterSync()
        await reconcilePostWorkoutSummaryNotifications()
        #if os(iOS)
        // #980: a strap backfill routinely completes while the app is BACKGROUNDED (it runs as a
        // bluetooth-central, so it stays alive to receive the offload). The only other widget-publish
        // sites are gated on scenePhase == .active, so a background sync would rescore today's data but
        // never rewrite the shared App-Group snapshot or call WidgetCenter.reloadAllTimelines — the
        // widget kept showing yesterday's numbers. Publishing here, on the real "new data landed"
        // signal, pushes the fresh snapshot to the home-screen widget without needing a foreground.
        await WidgetSnapshot.publish(from: self)
        await healthWriteBack?()
        #endif
    }

    private func processAutomaticWorkoutAfterSync() async {
        let mode = PuffinExperiment.autoWorkoutMode
        guard mode != .off else {
            AutoWorkoutNotifications.clear()
            return
        }
        guard let candidate = await repo.autoDetectCandidate(forceRefresh: true) else {
            AutoWorkoutNotifications.clear()
            return
        }
        guard AutoWorkoutBackgroundPolicy.shouldProcess(
            candidate,
            nowSec: Int(Date().timeIntervalSince1970)
        ) else {
            // Borderline and older candidates remain visible on Today without interrupting the user.
            AutoWorkoutNotifications.clear()
            return
        }
        if mode == .autoSave, AutoWorkoutAutomationPolicy.shouldAutoSave(candidate) {
            if await repo.saveDetectedWorkout(candidate, markForReview: true) {
                await repo.refresh()
                await AutoWorkoutNotifications.postAutoSavedIfAuthorized(
                    startSec: candidate.startSec, endSec: candidate.endSec)
                return
            }
            // A failed unattended write is never reported as saved. Fall through to the review prompt so
            // the user can retry explicitly when notifications are already available.
        }
        await AutoWorkoutNotifications.postIfAuthorized(
            startSec: candidate.startSec, endSec: candidate.endSec)
    }

    /// Repairs notification state at launch/foreground as well as after a backfill. Detection remains
    /// quiet inside Today when alerts are off; an older build's delivered suggestion is removed rather
    /// than lingering after its candidate, mode, or explicit notification opt-in is no longer current.
    func reconcileAutomaticWorkoutSurfaces() async {
        await processAutomaticWorkoutAfterSync()
    }

    /// Toggle the optional post-workout phone summary. Enabling snapshots the current newest workout
    /// before requesting notification access, so existing history is the frontier rather than a reason
    /// to interrupt the user immediately.
    func setPostWorkoutSummaryNotificationsEnabled(
        _ enabled: Bool,
        completion: (@MainActor @Sendable (PostWorkoutSummaryNotifications.EnableOutcome) -> Void)? = nil
    ) {
        postWorkoutPreferenceTask?.cancel()
        postWorkoutPreferenceTask = nil
        guard enabled else {
            PostWorkoutSummaryNotifications.setEnabled(
                false,
                currentNewestWorkoutStart: nil,
                completion: completion
            )
            return
        }
        postWorkoutPreferenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let newest = await self.repo.workoutRows().map(\.startTs).max()
            guard !Task.isCancelled else { return }
            PostWorkoutSummaryNotifications.setEnabled(
                true,
                currentNewestWorkoutStart: newest,
                completion: completion
            )
        }
    }

    /// Called only after persisted wearable history has refreshed and scored. This timing is honest:
    /// a workout summary can arrive after the session, whenever the next sync completes.
    private func reconcilePostWorkoutSummaryNotifications() async {
        let newest = await repo.workoutRows().map(\.startTs).max()
        await PostWorkoutSummaryNotifications.postIfAuthorized(newestWorkoutStart: newest)
    }

    /// Data-triggered twin of Android's morning recap. It runs only from a completed persisted-history
    /// refresh, so opening the app on an old row cannot manufacture a fresh-notification event.
    private func reconcileMorningRecapNotifications() async {
        guard let row = repo.today, row.totalSleepMin != nil else { return }
        let sleepScore = Repository.dailyColumn(key: "sleep_performance", day: row)
        await MorningRecapNotifications.postIfAuthorized(
            reportDay: row.day,
            chargeOrRestPresent: row.recovery != nil || sleepScore != nil
        )
    }

    /// Canonical ingest for one Bluetooth SIG Weight Measurement. This is deliberately separate from
    /// ProfileStore: all valid user slots remain in timestamped SQLite history, while only a safe/current
    /// slot is allowed to update the single-person profile projection.
    private func ingestWeightScaleCapture(_ capture: WeightScaleSource.Capture) async {
        let measurement = capture.measurement
        let measuredAt = measurement.timestamp ?? capture.receivedAt
        guard ExternalWeightUpdatePolicy.accepts(weightKg: measurement.weightKg,
                                                 measuredAt: measuredAt,
                                                 receivedAt: capture.receivedAt,
                                                 previousExternalAt: nil,
                                                 manualOverrideAt: nil),
              let store = await repo.storeHandle() else { return }

        let sourceDeviceID = "weight-scale-" + capture.peripheralID.uuidString.lowercased()
        let row = BodyMeasurementRow(
            measuredAt: Int(measuredAt.timeIntervalSince1970.rounded(.down)),
            receivedAt: Int(capture.receivedAt.timeIntervalSince1970.rounded(.down)),
            weightKg: measurement.weightKg,
            bmi: measurement.bmi,
            heightCm: measurement.heightCm,
            userID: measurement.userID.map(Int.init),
            unit: measurement.unit.rawValue,
            source: "bluetooth-sig-wss"
        )
        do {
            try await store.upsertBodyMeasurements([row], deviceId: sourceDeviceID)
        } catch {
            // Never advance profile provenance if the canonical history write failed: a future replay
            // must still be eligible to store + apply this reading atomically from the user's perspective.
            return
        }

        guard weightScaleSource.mayUpdateProfile(for: measurement),
              profile.acceptExternalWeight(weightKg: measurement.weightKg,
                                           measuredAt: measuredAt,
                                           source: "bluetooth-sig-wss:\(capture.peripheralID.uuidString)",
                                           receivedAt: capture.receivedAt) else { return }

        // Daily projection is only for the profile-selected person. Unknown/other scale users stay in
        // bodyMeasurement history and can never leak into this user's dashboard metric series.
        let day = Repository.localDayKey(measuredAt)
        var points = [MetricPoint(day: day, key: "weightKg", value: measurement.weightKg)]
        if let bmi = measurement.bmi, bmi.isFinite, bmi > 0 {
            points.append(MetricPoint(day: day, key: "bmi", value: bmi))
        }
        if let heightCm = measurement.heightCm, heightCm.isFinite, heightCm > 0 {
            points.append(MetricPoint(day: day, key: "heightCm", value: heightCm))
        }
        _ = try? await store.upsertMetricSeries(points, deviceId: sourceDeviceID)
        await repo.refresh()
    }

    /// Fold a fresh reading into the smoothing window and republish a stable bpm.
    /// Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to a plausible
    /// 30–220 range (rejects 0 / garbage spikes) and publishes the window MEDIAN.
    private func ingestHR(shouldEvaluateStress: Bool, rrPacket: [Int]? = nil) {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // #39: when the live source is gone (disconnect blanks heartRate AND rr), drop the stale
            // median so screens that now prefer `bpm` fall through to "," instead of freezing on the
            // last value. Mirrors Android (_bpm = null on disconnect). A transient out-of-range sample
            // with the link still up (heartRate or rr still present) keeps the last median.
            if live.heartRate == nil && live.rr.isEmpty { resetSmoothing() }
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        // live perf: only republish when the SMOOTHED value actually changes. ingestHR fires on every
        // heartRate AND rr update (~1–3 Hz), but the median is stable across most of them , an
        // unconditional assign re-renders every bpm observer (Live, menu bar, widgets) for nothing.
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        if shouldEvaluateStress { evaluateStress(rrPacket: rrPacket) }
        // Hydration's durable lane is the scheduled OS notification. The optional strap lane is
        // deliberately evaluated only while fresh HR packets are flowing, then additionally gated by
        // connected + worn + bonded + encrypted state. This makes the one-buzz behavior useful without
        // pretending iOS can guarantee a background BLE command after NOOP is suspended.
        if live.connected, live.worn, canBuzz,
           let slot = HydrationReminders.claimDueStrapBuzz(now: now) {
            buzz(loops: 1)
            HydrationReminders.armDoubleTapConfirmation(for: slot, now: now)
            live.append(log: "Water reminder · band cue issued")
        }
    }

    // MARK: - Manual workout tracking

    /// Begin a manually-tracked workout for the named `sport` (the picker passes the chosen catalogue
    /// name; callers that don't pick a sport get the catalogue default "Other", parity with Android's
    /// `startWorkout(sport:)`). The active card on Live then shows elapsed time, live HR and strain
    /// building; End scores + saves it under this sport. Confirms with a single buzz. (#519)
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        activeWorkoutSamples.removeAll(keepingCapacity: false)
        activeWorkoutHeartRateTotal = 0
        workoutLiveStrainCadence = WorkoutLiveStrainCadence(
            computedSampleCount: 0,
            computedAtSec: Int(started.timeIntervalSince1970)
        )
        workoutCautionPolicy = behavior.zoneCoaching
            && live.bonded
            && live.encryptedBond
            && live.worn
            ? WorkoutCautionPolicy(
                config: .init(hrMax: Double(profile.hrMax)),
                startTs: Int(started.timeIntervalSince1970)
            )
            : nil
        activeWorkout = ActiveWorkout(start: started, sport: resolved)
        workoutSaveError = nil
        workoutSaveInProgress = false
        // A pre-Start cached HR is display context, not part of the new workout. Seed the event cursor at
        // the current identity so capture begins with the first packet that arrives after Start.
        workoutHeartRateCursor = WorkoutHeartRateCursor(
            consumedSequence: live.heartRateSampleSequence
        )
        holdActiveWorkoutRealtimeLease()
        // #524: arm GPS route recording for a distance-type sport (run / ride / walk / hike), mirroring
        // Android, which defaults GPS on for `isDistanceSport`. Manual-first / opt-in: only these sports
        // record a route, and the recorder still captures nothing unless the user grants When-In-Use
        // location (and on a Mac with no GPS it stays empty) , the session always banks HR + Effort
        // regardless. A non-distance sport (yoga, strength) never touches location at all.
        activeWorkoutGpsEnabled = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        activeWorkoutRouteCheckpoint = nil
        workoutRecoveryCadence = WorkoutRecoveryCadence(
            persistedSampleCount: 0,
            persistedAtSec: Int(started.timeIntervalSince1970)
        )
        if activeWorkoutGpsEnabled {
            gpsRecorder.start(startMs: Int64(started.timeIntervalSince1970 * 1000))
        }
        // Make the session durable from the first instant (#529): persist it now so an OS kill right
        // after Start , before any HR sample lands , can still be rehydrated + ended on relaunch.
        persistActiveWorkout()
        // Workouts & GPS test mode (Test Centre): one session-start line tagged `.workouts`. Zero-cost when
        // off (the gate is one UserDefaults bool read), so the lifecycle of a missing workout is visible.
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "start", sportKey: WorkoutSource.traceSportKey(resolved), hrSamples: 0))
        buzz(loops: 1)
    }

    /// Emit one Workouts & GPS test-mode line tagged `.workouts` iff the mode is on. The cheap
    /// `TestCentre.active(.workouts)` gate is checked BEFORE the @autoclosure builds the line, so nothing is
    /// constructed when the mode is off. Diagnostic only - the session lifecycle is unchanged.
    private func emitWorkoutsTrace(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts) else { return }
        live.append(log: build(), domain: .workouts)
    }

    /// The gated sink the import handlers pass to the importers for the Import & Data Ingest test mode.
    /// Returns nil when the mode is off, so the importer takes its byte-identical untraced path (it builds
    /// no trace line and captures nothing extra); returns a `@Sendable` closure that hops the batch of
    /// already-redacted lines to the main actor (LiveState is @MainActor) and appends them, tagged
    /// `.dataImport`, in order, when the mode is on. The importer runs nonisolated, so the main-actor hop
    /// keeps the append race-free. One UserDefaults bool read decides whether any of this runs.
    private func importTraceSink() -> (@Sendable ([String]) -> Void)? {
        guard TestCentre.active(.dataImport) else { return nil }
        return { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines { self.live.append(log: line, domain: .dataImport) }
            }
        }
    }

    /// Emit the file-meta line for an import run (detected kind + extension + size BUCKET, never the path or
    /// name), tagged `.dataImport`, iff the mode is on. Called by the handlers that have the materialized
    /// URL. The size is bucketed inside `ImportTrace`, so no byte-exact size or filename leaves the device.
    private func emitImportFileMeta(kind: DataSourceKind, url: URL) {
        guard TestCentre.active(.dataImport) else { return }
        let ext = url.pathExtension
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        live.append(log: ImportTrace.fileMetaLine(sourceKind: kind, ext: ext, sizeBytes: size),
                    domain: .dataImport)
    }

    /// Persist the in-flight manual workout to `UserDefaults` so it survives the app being killed mid-
    /// session (#529). Called on start, bounded HR/GPS checkpoints, and End. A
    /// no-op when nothing is running; GPS intent and accepted route live in this same snapshot.
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                endSec: w.endedAt.map { Int($0.timeIntervalSince1970) },
                gpsEnabled: activeWorkoutGpsEnabled,
                routeCheckpoint: activeWorkoutRouteCheckpoint,
                sport: w.sport,
                samples: activeWorkoutSamples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrain: w.liveStrain))
        workoutRecoveryCadence.didPersist(
            sampleCount: activeWorkoutSamples.count,
            atSec: Int(Date().timeIntervalSince1970)
        )
    }

    /// If a manual workout was in flight when iOS killed the app, rebuild `activeWorkout` from the durable
    /// snapshot so reopening doesn't lose it: unfinished GPS sessions restore their exact accepted route
    /// and resume, while ended failed-save sessions stay frozen. No-op when a workout is already live (a
    /// live session wins over a stale snapshot) or nothing is stored. Called once from `init`.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport)
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        w.endedAt = snap.endSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        activeWorkoutSamples = snap.samples
        activeWorkoutHeartRateTotal = snap.samples.reduce(0) { $0 + $1.bpm }
        workoutLiveStrainCadence = WorkoutLiveStrainCadence(
            computedSampleCount: snap.samples.count,
            computedAtSec: snap.samples.last?.ts ?? snap.startSec
        )
        activeWorkout = w
        activeWorkoutGpsEnabled = snap.gpsEnabled
        activeWorkoutRouteCheckpoint = snap.routeCheckpoint
        workoutRecoveryCadence = WorkoutRecoveryCadence(
            persistedSampleCount: snap.samples.count,
            persistedAtSec: Int(Date().timeIntervalSince1970)
        )
        workoutHeartRateCursor = WorkoutHeartRateCursor(
            consumedSequence: live.heartRateSampleSequence,
            lastTimestamp: snap.samples.map(\.ts).max()
        )
        workoutCautionPolicy = w.endedAt == nil
            && behavior.zoneCoaching
            && live.bonded
            && live.encryptedBond
            && live.worn
            ? WorkoutCautionPolicy(
                config: .init(hrMax: Double(profile.hrMax)),
                startTs: snap.startSec
            )
            : nil
        if w.endedAt == nil {
            if snap.shouldResumeGps {
                gpsRecorder.resume(
                    startMs: Int64(snap.startSec) * 1_000,
                    checkpoint: snap.routeCheckpoint
                )
            }
            holdActiveWorkoutRealtimeLease()
        } else {
            // A prior DB commit failed (or the process was killed during it). Keep the bounded snapshot
            // stopped and invite an explicit retry; never resume sampling into a workout the user ended.
            workoutSaveError = String(localized: "This finished workout still needs to be saved.")
        }
    }

    private func holdActiveWorkoutRealtimeLease() {
        guard !activeWorkoutOwnsRealtimeLease else { return }
        activeWorkoutOwnsRealtimeLease = true
        startRealtimeHR()
    }

    private func releaseActiveWorkoutRealtimeLease() {
        guard activeWorkoutOwnsRealtimeLease else { return }
        activeWorkoutOwnsRealtimeLease = false
        stopRealtimeHR()
    }

    /// Finish the active workout: finalize the GPS route (#524), score the captured HR window, and save it
    /// as a `WorkoutRow`. A session with no HR window AND no real GPS route is discarded quietly (parity
    /// with Android) , but a GPS-only walk with HR not streaming still saves. Double-buzz confirms.
    func endWorkout() {
        guard var w = activeWorkout, !workoutSaveInProgress else { return }
        let startTs = Int(w.start.timeIntervalSince1970)

        // Freeze exactly once. A failed commit leaves `endedAt` + the same samples in the durable recovery
        // snapshot; Retry therefore cannot extend the duration or collect new HR behind the user's back.
        var route = activeWorkoutRouteCheckpoint?.workoutRoute()
        var gpsPointCount = activeWorkoutRouteCheckpoint?.pointCount
        if w.endedAt == nil {
            w.endedAt = Date()
            activeWorkout = w
            workoutCautionPolicy = nil
            if activeWorkoutGpsEnabled {
                // Force the exact final accepted track into the recovery snapshot before stopping GPS.
                // If no fix ever landed this remains nil—honest no route/no distance.
                if let checkpoint = gpsRecorder.checkpoint(force: true, notify: false) {
                    activeWorkoutRouteCheckpoint = checkpoint
                }
                gpsPointCount = activeWorkoutRouteCheckpoint?.pointCount
                route = activeWorkoutRouteCheckpoint?.workoutRoute()
                if gpsRecorder.isRecording { gpsRecorder.stop() }
            }
            releaseActiveWorkoutRealtimeLease()
            persistActiveWorkout()
        } else if route == nil {
            // Compatibility only: the immediately previous build stored a final route beside an ended
            // snapshot before route checkpoints existed. It was produced from accepted recorder points.
            route = RouteStore.load(startTs: startTs, sport: w.sport)
        }
        let samples = activeWorkoutSamples
        // Save when there's an HR window OR a real GPS route , a GPS-only walk (HR not streaming) is
        // still a workout (parity with Android's `samples.size < 2 && track.size < 2` discard gate).
        guard samples.count >= 2 || route != nil else {
            // Workouts & GPS test mode: record WHY a session vanished (too short / no route), tagged `.workouts`.
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "discarded", sportKey: WorkoutSource.traceSportKey(w.sport),
                hrSamples: samples.count, gpsPoints: route == nil ? 0 : nil))
            discardActiveWorkout()
            return
        }
        guard let end = w.endedAt else { return }
        if let route, !RouteStore.store(route, startTs: startTs, sport: w.sport) {
            // Do not commit a DB distance whose drawable route failed to become durable. The same ended
            // recovery snapshot remains intact for Retry; no partial success is presented to the user.
            workoutSaveError = String(localized:
                "Couldn't preserve this workout's GPS route. It is still kept on this device. Retry when ready.")
            return
        }
        let avg = samples.isEmpty ? nil
            : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max()
        let strain = samples.count >= 2
            ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax), sex: profile.sex) : nil
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax), restingHR: nil).0
            : 0
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            // GPS distance rides the shared row so the Workouts list / detail show it like any other
            // distance workout; the polyline itself is persisted alongside in RouteStore (the shared
            // WorkoutRow has no route column on Apple). Only a real route sets distance , honest ",".
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil)
        workoutSaveInProgress = true
        workoutSaveError = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await ActiveWorkoutPersistence.saveThenClear {
                guard let store = await self.repo.storeHandle() else {
                    throw ManualWorkoutSaveError.storeUnavailable
                }
                _ = try await store.upsertWorkouts([row], deviceId: self.deviceId)
            }
            self.workoutSaveInProgress = false
            switch result {
            case .saved:
                self.activeWorkout = nil
                self.activeWorkoutSamples.removeAll(keepingCapacity: false)
                self.activeWorkoutHeartRateTotal = 0
                self.workoutLiveStrainCadence = WorkoutLiveStrainCadence()
                self.workoutCautionPolicy = nil
                self.activeWorkoutGpsEnabled = false
                self.activeWorkoutRouteCheckpoint = nil
                self.workoutSaveError = nil
                self.lastWorkout = row
                self.emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                    event: "end", sportKey: WorkoutSource.traceSportKey(w.sport),
                    hrSamples: samples.count, durationSec: Int(end.timeIntervalSince(w.start)),
                    gpsPoints: gpsPointCount))
                self.buzz(loops: 2)
                self.repo.noteWorkoutsChanged()
                await self.repo.refresh()
            case .failed(let detail):
                self.workoutSaveError = String(localized:
                    "Couldn't save this workout. It is still kept on this device. Retry when ready. (\(detail))")
            }
        }
    }

    /// Explicitly abandon the retained in-flight/failed-save workout. This is the only non-save path that
    /// removes its recovery snapshot; the UI labels it destructively and never calls it implicitly.
    func discardActiveWorkout() {
        guard let w = activeWorkout, !workoutSaveInProgress else { return }
        if gpsRecorder.isRecording { gpsRecorder.stop() }
        activeWorkoutGpsEnabled = false
        activeWorkoutRouteCheckpoint = nil
        releaseActiveWorkoutRealtimeLease()
        RouteStore.remove(startTs: Int(w.start.timeIntervalSince1970), sport: w.sport)
        ActiveWorkoutPersistence.clear()
        activeWorkout = nil
        workoutCautionPolicy = nil
        activeWorkoutSamples.removeAll(keepingCapacity: false)
        activeWorkoutHeartRateTotal = 0
        workoutLiveStrainCadence = WorkoutLiveStrainCadence()
        lastWorkout = nil
        workoutSaveError = nil
    }

    /// Append one timestamped, sequence-identified sensor event and update lightweight live stats. The
    /// full-window Effort pass is cadence-limited; End always performs an exact final score.
    private func captureWorkoutSample(_ packet: LiveState.HeartRateSample) {
        guard var w = activeWorkout, w.endedAt == nil else { return }
        guard (30...220).contains(packet.bpm) else { return }
        guard let sample = workoutHeartRateCursor.consume(
            sequence: packet.sequence,
            bpm: packet.bpm,
            receivedAt: packet.receivedAt
        ) else { return }
        let hr = sample.bpm
        activeWorkoutSamples.append(sample)
        activeWorkoutHeartRateTotal += hr
        let sampleCount = activeWorkoutSamples.count
        w.peakHr = max(w.peakHr, hr)
        w.avgHr = Int((Double(activeWorkoutHeartRateTotal) / Double(sampleCount)).rounded())
        let nowSec = sample.ts
        evaluateWorkoutCaution(nowSec: nowSec, bpm: hr)
        if workoutLiveStrainCadence.isDue(
            sampleCount: sampleCount,
            firstSampleSec: activeWorkoutSamples.first?.ts,
            nowSec: nowSec,
            minimumSampleCount: StrainScorer.minSparseReadings,
            minimumSpanSec: StrainScorer.minSpanSeconds - 1
        ) {
            w.liveStrain = StrainScorer.strain(
                activeWorkoutSamples,
                maxHR: Double(profile.hrMax),
                sex: profile.sex
            ) ?? 0
            workoutLiveStrainCadence.didCompute(sampleCount: sampleCount, atSec: nowSec)
        }
        activeWorkout = w
        // Avoid JSON-encoding the entire growing sample prefix at ~1 Hz. The pure cadence gate caps full
        // recovery writes at 30 accepted samples / 30 seconds; End and GPS lifecycle checkpoints force.
        if workoutRecoveryCadence.isDue(sampleCount: sampleCount, nowSec: nowSec) {
            persistActiveWorkout()
        }
    }

    /// Apply the pure sustained-exertion policy only to a real accepted workout packet. The strongest
    /// cue gets a distinct wrist pattern plus a phone prompt when permission exists. It never claims a
    /// medical event; the notification asks the user to pause and assess symptoms.
    private func evaluateWorkoutCaution(nowSec: Int, bpm: Int) {
        guard behavior.zoneCoaching,
              live.bonded,
              live.encryptedBond,
              live.worn else {
            workoutCautionPolicy = nil
            return
        }
        var policy = workoutCautionPolicy ?? WorkoutCautionPolicy(
            config: .init(hrMax: Double(profile.hrMax)),
            startTs: nowSec
        )
        let output = policy.update(now: nowSec, bpm: bpm)
        workoutCautionPolicy = policy
        guard let cue = output.cue else { return }
        let wristHapticsEnabled = UserDefaults.standard.bool(
            forKey: Self.wristAlertsMasterKey
        )
        switch cue {
        case .easeOff:
            if wristHapticsEnabled, canBuzz, live.worn { buzz(loops: 3) }
        case .pauseAndAssess:
            if wristHapticsEnabled, canBuzz, live.worn { buzz(loops: 5) }
            WorkoutCautionNotifier.post()
        case .recovered:
            if wristHapticsEnabled, canBuzz, live.worn { buzz(loops: 1) }
        }
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows ","
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on an explicit foreground Live/workout/reading/session arm (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm , so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// The unit-tested `StressOnsetDetector` decides whether to offer a 60-s guided breath. On a fresh,
    /// short-window HRV dip below a warmed personal baseline, with observed low motion, it fires a single
    /// confirming buzz and posts a
    /// passive nudge to `stressNudgeCenter`. The detector carries replay-safe state (de-dup + slow
    /// baseline + rate limit), persisted via `BiofeedbackPrefs` so a relaunch can't re-fire. Honest /
    /// non-clinical: "stress" is an autonomic proxy vs the user's own baseline, never a diagnosis.
    private func evaluateStress(rrPacket: [Int]? = nil) {
        let now = Date()
        if let rrPacket {
            let fresh = rrPacket.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
            guard !fresh.isEmpty, let receivedAt = live.rrReceivedAt else {
                rrBuf.removeAll()
                stressRRBufferReceivedAt = nil
                return
            }
            if StressEvidencePolicy.shouldResetRRBuffer(
                previousReceivedAt: stressRRBufferReceivedAt,
                currentReceivedAt: receivedAt
            ) {
                rrBuf.removeAll()
            }
            rrBuf.append(contentsOf: fresh)
            if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }
            stressRRBufferReceivedAt = receivedAt
        }
        guard !rrBuf.isEmpty,
              let rrAt = live.rrReceivedAt,
              let recentMotionG = StressEvidencePolicy.qualifiedMotion(
                now: now,
                rrReceivedAt: rrAt,
                heartRateReceivedAt: live.heartRateSample?.receivedAt,
                motion: live.recentWristMotionEvidence,
                connected: live.connected,
                bonded: live.bonded,
                encryptedBond: live.encryptedBond,
                worn: live.worn
              ) else { return }

        // Inert unless the master toggle is on; the engine owns every gate (auto-nudge, exercise gate,
        // motion evidence, baseline warm-up, quiet hours, rate limit, edge).
        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled else { return }
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: bpm.map(Double.init),
            recentMotionG: recentMotionG,
            sessionActive: activeWorkout != nil || stressNudgeSessionCount > 0
                || stressNudgeCenter.pending != nil,
            state: stressState,
            config: cfg,
            nowSec: Int(now.timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        guard decision.shouldNudge else { return }
        if canBuzz, UserDefaults.standard.bool(forKey: Self.wristAlertsMasterKey) {
            buzz(loops: UInt8(clamping: decision.buzzLoops))
        }
        stressNudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        ContextualActionCenter.shared.presentStress(
            fastRMSSD: decision.fastRMSSD,
            baselineRMSSD: decision.baselineRMSSD,
            fingerprint: String(decision.nextState.lastFireAt),
            now: now
        )
        if BiofeedbackPrefs.phoneNudge {
            ContextualInterventionCenter.post(
                ContextualInterventionCandidate(
                    kind: .stressBreathing,
                    observedAt: rrAt,
                    maximumAge: 5 * 60,
                    fingerprint: String(decision.nextState.lastFireAt),
                    title: String(localized: "appwide.stress_checkin.notification_title"),
                    body: String(localized: "appwide.stress_checkin.notification_body"),
                    route: .breathe
                )
            )
        }
        live.append(log: "Stress check-in · short-window HRV moved below recent baseline")
    }

    /// Register/unregister a user-started coaching or breathing session as an automatic stress-nudge
    /// suppressor. Calls are balanced by each session owner; clamping makes a duplicate teardown harmless.
    func setStressNudgeSessionActive(_ active: Bool) {
        if active {
            stressNudgeSessionCount += 1
        } else {
            stressNudgeSessionCount = max(0, stressNudgeSessionCount - 1)
        }
    }

    /// Whether the encrypted channel is up so a confirming buzz can actually fire (the command
    /// characteristic is gated on bond; an un-encrypted live-HR-only link can't buzz).
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point ,
    /// Live, onboarding, the menu bar, Settings , honours the same choice.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }
    /// Restart the connected strap (user-initiated, confirmation-gated in DevicesView). Non-destructive —
    /// the strap keeps its data and re-advertises after boot; NOOP auto-reconnects. See BLEManager.rebootStrap().
    func rebootStrap() { ble.rebootStrap() }
    /// Send one WHOOP 4.0 reboot-probe candidate (Test Centre → Connection, 4.0 only). Confirmation-gated
    /// in DevicesView; finds the real 4.0 reboot frame when the production one is ignored (#235).
    func rebootProbe(_ variant: RebootProbeVariant) { ble.rebootProbe(variant) }

    /// #592 read-only extended-battery opcode probe (Devices → strap menu, Test Centre → Connection gated).
    func probeExtendedBatteryInfo() { ble.probeExtendedBatteryInfo() }
    func clearExtendedBatteryProbe() { ble.clearExtendedBatteryProbe() }

    // #690: read-only body-location/status probe (0x54). User-initiated, Test-Centre-gated in DevicesView.
    func probeBodyLocationAndStatus() { ble.probeBodyLocationAndStatus() }
    func clearBodyLocationProbe() { ble.clearBodyLocationProbe() }

    // WHOOP MG ECG ("Labrador") research probe. BLEManager owns the safety gates: explicit opt-in,
    // positively identified MG hardware, a live connection, and a user-initiated action.
    var isWhoop5MG: Bool { ble.isWhoop5MG }
    func ecgSelectWrist(_ wrist: Whoop5Ecg.WristSelection) { ble.ecgSelectWrist(wrist) }
    func ecgStartCapture() { ble.ecgStartCapture() }
    func ecgStopCapture(reportsResult: Bool = true) {
        ble.ecgStopCapture(reportsResult: reportsResult)
    }
    func clearEcgProbe() { ble.clearEcgProbe() }
    var ecgMayBeRunning: Bool { ble.ecgMayBeRunning }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    //
    // Thin pass-throughs over BLEManager's EXISTING public present-scan surface so the wizard never
    // references BLEManager directly (mirrors `scan()` / `disconnect()`). The wizard observes
    // `ble.discoveredWhoops` for the WHOOP families and runs its own `StandardHRSource` for generic
    // straps , see AddDeviceWizard.

    /// The straps surfaced by the WHOOP present-scan (`scanForWhoops`), for the wizard's live list.
    /// Empty until a present-scan has discovered something; refreshed in place as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int, model: WhoopModel)] {
        ble.discoveredWhoops
    }

    /// True when the selected/connected strap is a WHOOP 5/MG. A thin window onto `BLEManager.isWhoop5`
    /// (its `selectedModel` is private) so a view can branch on the strap generation without reaching into
    /// the BLE layer. #864: the Smart-alarm card uses this to give a 5/MG owner the honest "saved but NOT
    /// armed until Experimental is on" copy, instead of hardcoding WHOOP 4.0. Mirrors the Android
    /// `LiveState.whoop5Detected` field the equivalent screen reads.
    var whoop5Detected: Bool { ble.isWhoop5 }

    /// Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting.
    /// `prepareForModelSwitch()` first clears any sticky bond/connection so the engine is idle, then
    /// `connect(model:)` selects the family + installs its framing (it sets the engine's private
    /// `selectedModel`, which `scanForWhoops()` scans for), and the immediate `scanForWhoops()` takes
    /// over the central in present-mode (it `stopScan()`s the connect's scan and re-arms a duplicate-
    /// allowing present scan). The persisted `selectedWhoopModel` is updated too, so a later real
    /// connect to the chosen strap targets the right family. All via existing public methods.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.prepareForPresentScan(model: model) // idle for a family switch, but KEEP a live same-family bond (#74)
        ble.connect(model: model)             // select the family (sets engine selectedModel + framing)
        ble.scanForWhoops()                   // take over the central, present nearby straps only
    }

    /// End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss.
    func stopWhoopScan() { ble.stopWhoopScan() }

    /// Source-aware pre-archive teardown for Devices. The registry row still carries brand, source kind,
    /// and active status here; after reducing it to `peripheralId` a nil Apple Watch/import/legacy id is
    /// ambiguous and must never be allowed to mean "release the active WHOOP." Historical data is not
    /// touched — this only stops the live owner for the row the user explicitly removed.
    func prepareForDeviceRemoval(_ device: PairedDevice) {
        switch SourceCoordinator.removalAction(for: device) {
        case .archiveOnly:
            break
        case .releaseActiveWhoop:
            ble.forgetActiveWhoop()
        case .stopActiveNonWhoop:
            sourceCoordinator?.prepareForRemoval(deviceId: device.id)
        }
    }

    /// Register a paired device and (optionally) make it the active one. The Add-a-device wizard's
    /// single write path: `add` upserts the row, and when `makeActive` is true `setActive` promotes it
    /// (the SourceCoordinator reacts to the active-device change and connects). No-op if the registry
    /// hasn't been wired yet (pre store-open) , the wizard is only reachable once it has.
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard let registry = deviceRegistry else { return }
        registry.add(device)
        if makeActive {
            // `setActive` republishes `registry.$activeDeviceId`, which the read-spine subscription
            // (`readSpineCancellable`, wired in `wireSourceCoordinator`) observes and re-points the reads
            // off, so the dashboard follows a re-add without a one-shot call here. The explicit adopt below
            // is kept as a belt-and-braces immediate re-point (idempotent, so it's a safe no-op once the
            // subscription has also fired). The just-activated id IS `device.id` (`setActive` made it active).
            registry.setActive(device.id)
            Task { [weak self] in await self?.adoptActiveDevice(device.id) }
        }
    }

    #if os(iOS)
    /// Refresh the active read spine after Apple Health commits a projection. Apple Health is registered
    /// with only capabilities actually present in recent samples, and it replaces the seeded WHOOP row
    /// only when that row is still an unused placeholder. A real or user-selected source is never displaced.
    func refreshAfterAppleHealthSync(authorized: Bool, now: Date = Date()) async {
        await wireSourceCoordinator()
        guard let registry = deviceRegistry, let store = await repo.storeHandle() else {
            await repo.refresh()
            return
        }

        let current = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        var currentHasRecentData = false
        if let current {
            let range = AppleWatchDevice.recentDayRange(now: now)
            let cutoff = Int(now.timeIntervalSince1970)
                - AppleWatchDevice.recentWindowDays * 86_400
            let latestHR = (try? await store.latestHRSampleTs(deviceId: current.id)) ?? nil
            let recentDaily = (try? await store.dailyMetrics(
                deviceId: current.id, from: range.from, to: range.to)) ?? []
            currentHasRecentData = (latestHR ?? 0) >= cutoff || !recentDaily.isEmpty
        }

        await AppleWatchDevice.registerIfAuthorized(
            registry: registry, store: store, authorized: authorized, now: now)
        guard registry.devices.contains(where: { $0.id == AppleWatchDevice.deviceId }) else {
            await repo.refresh()
            return
        }

        if AppleWatchDevice.shouldAutoActivate(
            current: current, currentHasRecentData: currentHasRecentData) {
            registry.setActive(AppleWatchDevice.deviceId)
            await adoptActiveDevice(AppleWatchDevice.deviceId)
        } else if registry.activeDeviceId == AppleWatchDevice.deviceId {
            // On relaunch the registry may already be active while the Repository is still initializing.
            await adoptActiveDevice(AppleWatchDevice.deviceId)
            await repo.refresh()
        } else {
            await repo.refresh()
        }
    }
    #endif

    // MARK: - Oura adopt (factory-reset-and-adopt)

    /// The live adopt outcome of the active Oura ring, mirrored off the coordinator's live `OuraLiveSource`
    /// so the Add-device wizard can drive its "Taking over your ring" step to success or an honest Failed
    /// WITHOUT reaching into the BLE layer. nil when no Oura source is live or no adopt is in flight. PARITY:
    /// the Android wizard observes the same coarse outcome to leave its Adopting step.
    @Published private(set) var ouraAdoptPhase: OuraLiveSource.AdoptPhase = .idle
    /// The active Oura ring's honest needs-pairing message (mirrored off the live source), surfaced verbatim
    /// on the wizard's Failed step. nil when the ring is fine or no Oura source is live.
    @Published private(set) var ouraNeedsPairing: String?
    /// Combine subscriptions mirroring the live Oura source's `adoptPhase` / `needsPairing` into the two
    /// published properties above. Re-bound whenever the active Oura source changes.
    private var ouraAdoptCancellables = Set<AnyCancellable>()

    /// Take over a factory-reset Oura ring: grant the coordinator explicit adopt consent for THIS ring (so
    /// its live session may run the one-time key install, s3.2), register it active (which starts that live
    /// session), then begin mirroring its adopt outcome for the wizard. The irreversible-consent gate has
    /// ALREADY been passed in the wizard (the consent tick + the "Take over this ring?" confirm); this is the
    /// commit. Never prompts to make-active (the takeover IS the user's new active source).
    func adoptOuraRing(_ device: PairedDevice) {
        sourceCoordinator?.requestOuraAdopt(deviceId: device.id)
        // Reset the mirror so a previous attempt's outcome never leaks into this one.
        ouraAdoptPhase = .idle
        ouraNeedsPairing = nil
        registerDevice(device, makeActive: true)
        bindOuraAdoptMirror()
    }

    /// (Re)bind the adopt-outcome mirror to whichever `OuraLiveSource` the coordinator has live now and on
    /// every later swap. `flatMap` switches to the current source's `adoptPhase` (defaulting to `.idle` when
    /// there is no source), so the published value always tracks the live source without leaking subscriptions.
    private func bindOuraAdoptMirror() {
        ouraAdoptCancellables.removeAll()
        guard let coordinator = sourceCoordinator else { return }
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<OuraLiveSource.AdoptPhase, Never> in
                source?.$adoptPhase.eraseToAnyPublisher()
                    ?? Just(.idle).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraAdoptPhase = $0 }
            .store(in: &ouraAdoptCancellables)
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<String?, Never> in
                source?.$needsPairing.eraseToAnyPublisher()
                    ?? Just(nil).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraNeedsPairing = $0 }
            .store(in: &ouraAdoptCancellables)
    }

    /// Ref-count + app-lifecycle gate for battery-intensive realtime requests. Logical leases survive a
    /// background transition, but the physical screen stream does not: it is disarmed while inactive and
    /// re-armed exactly once if the same explicit Live/workout/session lease still exists on foreground.
    /// BLEManager composes this screen intent with the separate Continuous HRV setting, so backgrounding
    /// a foreground lease never disables that independently opted-in capture or lightweight history sync.
    private var realtimeLeasePolicy = ForegroundRealtimeLeasePolicy()

    /// A surface that shows live HR appeared. Arms the realtime stream on the 0→1 edge , and ONLY on
    /// that edge blanks the stale smoothing window (#46) so a resume shows "," until a fresh sample
    /// lands, never re-clearing an already-live window when a second concurrent HR surface opens. The
    /// keep-alive re-arm goes through `ble.startRealtime()` directly, NOT here, so steady-state is
    /// untouched. Each surface must balance this with exactly one `stopRealtimeHR()` on disappear.
    func startRealtimeHR() {
        if realtimeLeasePolicy.requestLease() == .arm {
            resetSmoothing()
            ble.startRealtime()
        }
    }
    /// A live-HR surface went away. Stops the realtime stream only when the last one leaves (1→0 edge);
    /// the lightweight 0x2A37 HR keeps recording regardless. Clamped at 0 so an unbalanced extra stop
    /// can't drive the count negative and wedge the stream off.
    func stopRealtimeHR() {
        if realtimeLeasePolicy.releaseLease() == .disarm { ble.stopRealtime() }
    }

    /// App/scene lifecycle gate for high-rate foreground leases. This deliberately does not disconnect
    /// BLE, stop historical sync, or change Continuous HRV capture; it only applies/removes the screen
    /// side of BLEManager's combined realtime want. Re-entering foreground blanks stale smoothing before
    /// re-arming so a paused session never flashes its pre-background BPM as current.
    func setRealtimeForeground(_ foreground: Bool) {
        switch realtimeLeasePolicy.setForeground(foreground) {
        case .arm:
            resetSmoothing()
            ble.startRealtime()
        case .disarm:
            ble.stopRealtime()
        case .none:
            break
        }
    }

    /// Re-issue the BLE realtime arm WITHOUT touching the ref-count , used when a fresh
    /// connection/bond lands while a surface is already showing live HR (Apple's `ble.startRealtime()`
    /// must be re-sent on a new connection). A no-op when nothing wants the stream, so a stray
    /// connection event can't arm it behind a closed Live tab. Mirrors that Android re-arms via its
    /// own keep-alive rather than re-calling `requestRealtimeHr` on reconnect.
    func rearmRealtimeIfWanted() {
        guard realtimeLeasePolicy.shouldArm else { return }
        ble.startRealtime()
    }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Used by scheduled cues (coach zones, moment marks, biofeedback).
    /// Requires a bonded connection , no-op otherwise (the command characteristic is gated on bond).
    /// For a user-facing "buzz the strap now" action use `buzzStrapOnce()` instead (#921).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// One-shot user buzz (#921): the on-device-confirmed pattern (patternId=2, 3 loops) followed by
    /// RUN_ALARM, both written acknowledged. A bare RUN_HAPTICS_PATTERN write can be silently ignored
    /// (WHOOP 4.0 via the Siri shortcut) or dropped unacked on a busy link, so the Live "Buzz strap"
    /// button and the Buzz Strap App Intent both route through this single sequence.
    func buzzStrapOnce() {
        ble.buzzStrapOnce()
    }

    /// Best-effort receiver-side handoff for an explicitly enabled managed Friends poke. The caller
    /// acknowledges only that an eligible command was requested; BLE acceptance still requires
    /// physical-device evidence and is never inferred from this return value.
    func requestManagedSocialPokeHaptic() -> Bool {
        guard live.connected,
              live.bonded,
              live.encryptedBond,
              live.worn else {
            return false
        }
        buzz(loops: 1)
        return true
    }

    /// Fire a specific preset haptic pattern (patternId 0–6 on Harvard; loops sets length).
    /// Used by the notification-pattern picker and coaching features.
    func buzz(pattern: UInt8, loops: UInt8 = 1) {
        ble.send(.runHapticsPattern, payload: [pattern, loops, 0, 0, 0])
    }

    /// Tell the strap to STOP an in-progress haptic pattern (#769). The biofeedback layers (Breathe /
    /// "Calm me" / resonance) schedule a stream of buzzes; cancelling the app-side DispatchWorkItems stops
    /// scheduling NEW pulses but cannot recall a pattern the strap is already mid-way through. If the link
    /// then drops mid-pattern, the strap's UI/haptic manager can be left wedged on that pattern with no app
    /// able to clear it. STOP_HAPTICS (cmd 122, payload [0x00]) is the documented, reversible clear for
    /// WHOOP 4.0.
    ///
    /// WHOOP 5/MG CAVEAT: the 5/MG buzz rides the maverick 0x13 path (a one-shot, not a sustained pattern),
    /// and we have NOT confirmed the 5/MG honours cmd 122 on that path. `send` does not allow-list 122 for
    /// the 5/MG family, so on a 5/MG this is a no-op (logged "skipped"), not a guessed write. So this is
    /// BEST-EFFORT: it reliably clears a wedged WHOOP 4.0; on a 5/MG the one-shot nature already limits the
    /// wedge, and we deliberately do not invent an unverified stop opcode. Safe to call always (no-op when
    /// unbonded or when the family doesn't accept it).
    func stopHaptics() {
        ble.send(.stopHaptics, payload: [0x00])
    }

    // MARK: - Wrist-buzz mirror notifications (PR #577 , iOS only)
    //
    // iOS can't keep the strap buzz silent in a pocket the way macOS surfaces it on screen, so a wrist
    // buzz the user might miss (a long sedentary stretch, the smart-alarm wake) is ALSO posted as a
    // local notification. macOS keeps routing to its dedicated Notifications screen and never calls
    // these , `#if os(iOS)` makes them no-ops there so that path is untouched. Both are gated on the
    // same `notif.masterEnabled` master switch the iOS Automations "Wrist alerts" toggle (PR #572) and
    // the SedentaryDetector read, so turning wrist alerts off silences these too.

    /// The master wrist-alerts gate (PR #572). One key, shared with the iOS Automations toggle and the
    /// SedentaryDetector, so all three honour the same switch.
    static let wristAlertsMasterKey = "notif.masterEnabled"

    /// Post the local notification mirroring the inactivity (sedentary) wrist nudge. Called right after
    /// `BLEManager.maybeBuzzInactivity` fires its buzz (see crossLaneNotes). `minutes` = the seated bout
    /// length the detector reported. No-op on macOS and when wrist alerts are off.
    static func postInactivity(minutes: Int) {
        #if os(iOS)
        let body = minutes > 0
            ? String(localized: "You've been seated for about \(minutes) min. Time to move.")
            : String(localized: "Time to move. You've been seated a while.")
        postWristAlert(identifier: "inactivity-nudge", title: String(localized: "Move reminder"), body: body)
        #endif
    }

    /// Post the local notification mirroring the smart-alarm wake buzz. Called from the
    /// `onSmartAlarmFired` hook. No-op on macOS and when wrist alerts are off.
    static func postSmartAlarm() {
        #if os(iOS)
        postWristAlert(identifier: "smart-alarm-wake", title: String(localized: "Smart alarm"),
                       body: String(localized: "Good morning. Your smart alarm just woke you."))
        #endif
    }

    #if os(iOS)
    /// Shared post path: gate on the wrist-alerts master, then deliver only if the OS already authorized
    /// notifications (no second system prompt , BatteryNotifier-style status-only check). A fresh
    /// identifier per category means a new alert replaces the old one rather than stacking.
    private static func postWristAlert(identifier: String, title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: wristAlertsMasterKey) else {
            LocalNotificationLifecycle.suppressed(identifier: identifier)
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                LocalNotificationLifecycle.suppressed(identifier: identifier)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await LocalNotificationLifecycle.schedule(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
                on: center
            )
        }
    }
    #endif

    /// Stable identifier base for the smart-alarm BACKUP wake notification(s). The every-day case uses
    /// this id directly; the per-weekday case fans out to "<base>-d<weekday>" so a re-arm replaces by id
    /// and never stacks. Kept separate from "smart-alarm-wake" (the strap-confirmed mirror) so the two
    /// never collide.
    private static let smartAlarmBackupId = "smart-alarm-wake-backup"
    private static let smartAlarmDurationBackupId = "smart-alarm-duration-backup"
    private static var smartAlarmBackupIds: [String] {
        [smartAlarmBackupId, smartAlarmDurationBackupId]
            + (1...7).map { "\(smartAlarmBackupId)-d\($0)" }
    }

    /// Schedule a BEST-EFFORT repeating daily backup wake notification for the smart alarm (#4 + #6).
    ///
    /// The strap firmware alarm is one absolute instant and the mirror in `postSmartAlarm` only posts
    /// AFTER the strap reports it fired, so if the buzz fails or the phone is suspended past day one there
    /// was previously no OS-level wake at all. This adds a repeating `UNCalendarNotificationTrigger` that
    /// "lives in the notification center, not our process" (the WindDownNudge idiom), so it survives
    /// relaunch and keeps firing each chosen morning even with the app killed.
    ///
    /// HONEST: this is NOT a guaranteed loud alarm. A sideloaded build has no critical-alert entitlement,
    /// so iOS Focus / silent mode can still suppress the sound. The UI copy says to keep a real backup.
    ///
    /// Gated on the ALARM being enabled (its sole caller `applySmartAlarm()` already enforces that) plus
    /// notification permission — NOT the wrist-alerts master (#34): a wake backup must not depend on the
    /// unrelated HR/strain-alerts switch. When permission is undetermined the user is prompted here (they
    /// just enabled the alarm) and scheduled on grant, so the FIRST night is covered. Always removes the
    /// prior set first, so a re-arm replaces rather than stacks. `weekdays` empty = every day (single daily
    /// trigger); a non-empty set fans out to one weekday-pinned trigger per selected day. No-op on macOS.
    /// `log` (optional): strap-log sink for the not-authorized bail (#401 close-out) — a silent no-op left a
    /// user whose backup never fired with nothing in the log. The caller wraps the sink in a main-actor hop
    /// (the auth check completes off-main). Diagnostic only.
    static func scheduleSmartAlarmBackupNotification(minutes: Int, weekdays: Set<Int>,
                                                     log: (@MainActor @Sendable (String) -> Void)? = nil) {
        #if os(iOS)
        // Always clear BOTH the single and the per-day ids so switching modes (or editing the weekday set)
        // never leaves an orphaned trigger or double-fires.
        LocalNotificationLifecycle.cancel(identifiers: smartAlarmBackupIds)
        // #34: the backup follows THE ALARM, not the wrist-alerts master. This is only reached from
        // applySmartAlarm() with the alarm enabled, so the alarm being on IS the correct gate — a user who
        // sets a smart alarm but never turned on the separate wrist HR/strain alerts must still get a backup
        // wake. The old `notif.masterEnabled` guard suppressed it for exactly those users, so a strap that
        // couldn't arm left them with nothing.
        let valid = weekdays.filter { (1...7).contains($0) }
        // A non-empty selection that filters to nothing (only out-of-range numbers) has no day to fire on.
        if !weekdays.isEmpty && valid.isEmpty {
            LocalNotificationLifecycle.suppressed(
                identifier: smartAlarmBackupId
            )
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let initialStatus = await center.notificationSettings().authorizationStatus
            switch initialStatus {
            case .authorized:
                addSmartAlarmBackupRequests(center: center, minutes: minutes, weekdays: valid)
            case .notDetermined:
                // The user just enabled the alarm but was never asked for notification permission (nothing
                // else prompted — wrist alerts, which used to, may be off). Ask now, then schedule on grant
                // so the FIRST night is covered rather than only after some later re-arm.
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    // Re-read status rather than treating the request return as authorization truth.
                    let finalStatus = await center.notificationSettings().authorizationStatus
                    if finalStatus == .authorized {
                        addSmartAlarmBackupRequests(center: center, minutes: minutes, weekdays: valid)
                    } else {
                        LocalNotificationLifecycle.suppressed(
                            identifier: smartAlarmBackupId
                        )
                        log?("Smart alarm: backup notification NOT scheduled (notifications not authorized)")
                    }
                } else {
                    LocalNotificationLifecycle.suppressed(
                        identifier: smartAlarmBackupId
                    )
                    log?("Smart alarm: backup notification NOT scheduled (notification permission denied)")
                }
            default:
                LocalNotificationLifecycle.suppressed(
                    identifier: smartAlarmBackupId
                )
                log?("Smart alarm: backup notification NOT scheduled (notifications not authorized)")
            }
        }
        #endif
    }

    #if os(iOS)
    /// Build the repeating request set after authorization has been confirmed. Main-actor isolated with
    /// the enclosing AppModel, so mutable UserNotifications objects never cross an executor boundary.
    private static func addSmartAlarmBackupRequests(
        center: UNUserNotificationCenter,
        minutes: Int,
        weekdays: Set<Int>
    ) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Smart alarm")
        content.body = String(localized: "Backup wake: your smart alarm time is here.")
        content.sound = .default
        let hour = minutes / 60
        let minute = minutes % 60
        if weekdays.isEmpty {
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: smartAlarmBackupId,
                    content: content,
                    trigger: trigger
                ),
                on: center
            )
        } else {
            for weekday in weekdays {
                var comps = DateComponents()
                comps.weekday = weekday   // Calendar weekday 1=Sun…7=Sat , fires weekly on that day
                comps.hour = hour
                comps.minute = minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                LocalNotificationLifecycle.schedule(
                    UNNotificationRequest(
                        identifier: "\(smartAlarmBackupId)-d\(weekday)",
                        content: content,
                        trigger: trigger
                    ),
                    on: center
                )
            }
        }
    }
    #endif

    /// Schedule one best-effort OS fallback at the currently projected detected-sleep target. Every
    /// fresh sync replaces this request, so accumulated awake time can move the wake later without
    /// leaving an older notification behind.
    static func scheduleSmartAlarmDurationBackupNotification(
        at fireDate: Date,
        log: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        LocalNotificationLifecycle.cancel(
            identifiers: smartAlarmBackupIds,
            on: center
        )
        guard fireDate.timeIntervalSinceNow > 1 else {
            LocalNotificationLifecycle.suppressed(
                identifier: smartAlarmDurationBackupId
            )
            return
        }

        Task { @MainActor in
            let initialStatus = await center.notificationSettings().authorizationStatus
            switch initialStatus {
            case .authorized:
                addSmartAlarmDurationBackupRequest(center: center, fireDate: fireDate)
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                let finalStatus = await center.notificationSettings().authorizationStatus
                if granted, finalStatus == .authorized {
                    addSmartAlarmDurationBackupRequest(center: center, fireDate: fireDate)
                } else {
                    LocalNotificationLifecycle.suppressed(
                        identifier: smartAlarmDurationBackupId
                    )
                    log?("Sleep-duration alarm: backup notification NOT scheduled (notifications not authorized)")
                }
            default:
                LocalNotificationLifecycle.suppressed(
                    identifier: smartAlarmDurationBackupId
                )
                log?("Sleep-duration alarm: backup notification NOT scheduled (notifications not authorized)")
            }
        }
        #endif
    }

    #if os(iOS)
    private static func addSmartAlarmDurationBackupRequest(
        center: UNUserNotificationCenter,
        fireDate: Date
    ) {
        let delay = max(fireDate.timeIntervalSinceNow, 1)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sleep goal")
        content.body = String(localized: "Your detected-sleep target is due. This is a best-effort backup for the Noop Band vibration.")
        content.sound = .default
        LocalNotificationLifecycle.schedule(
            UNNotificationRequest(
                identifier: smartAlarmDurationBackupId,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            ),
            on: center
        )
    }
    #endif

    /// Cancel the smart-alarm backup wake notification(s). Called on disarm. No-op on macOS.
    static func cancelSmartAlarmBackupNotification() {
        #if os(iOS)
        LocalNotificationLifecycle.cancel(identifiers: smartAlarmBackupIds)
        #endif
    }

    /// Arm (or clear) the strap's firmware alarm from the smart-alarm settings. The firmware alarm
    /// fires even if the Mac is asleep / NOOP is closed. No-op until bonded (send is gated on bond).
    ///
    /// On iOS this ALSO (dis)arms the best-effort backup wake notification (#4 + #6): a repeating daily
    /// `UNCalendarNotificationTrigger` that survives suspend/relaunch, so a missed strap buzz still gets
    /// an OS-level wake. macOS keeps just the firmware alarm (the static helpers are no-ops there).
    func applySmartAlarm() {
        guard behavior.smartAlarmEnabled else {
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            behavior.smartAlarmArmedSessionStart = 0
            smartAlarmRuntimeState = .off
            return
        }
        if behavior.smartAlarmMode.usesDetectedSleep {
            reconcileSleepDurationAlarm(sessions: repo.sleeps)
            return
        }
        behavior.smartAlarmArmedSessionStart = 0
        guard let next = Self.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                                 weekdays: behavior.smartAlarmWeekdays) else {
            // No enabled weekday in the next week (only possible from a corrupted set) , disarm rather
            // than arm a misleading time the user never asked for.
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            smartAlarmRuntimeState = .off
            return
        }
        ble.armStrapAlarm(at: next)
        smartAlarmRuntimeState = .fixed(next)
        // Replace (remove + re-add by stable identifier) on every re-arm so the backup never stacks.
        // The log sink hops to the main actor because the auth check completes off-main and LiveState is
        // @MainActor - the same Task hop the importTraceSink uses.
        Self.scheduleSmartAlarmBackupNotification(minutes: behavior.smartAlarmMinutes,
                                                  weekdays: behavior.smartAlarmWeekdays,
                                                  log: { [weak self] line in
                                                      self?.live.append(log: line)
                                                  })
    }

    private func reconcileSleepDurationAlarm(sessions: [CachedSleepSession]) {
        let activeTarget = Self.smartAlarmTargetMinutes(
            mode: behavior.smartAlarmMode,
            fixedMinutes: behavior.smartAlarmDurationMinutes,
            adaptiveMinutes: WindDownNudge.targetSleepMinutes
        )
        let decision = SleepDurationAlarmPolicy.decision(
            sessions: sessions,
            targetMinutes: activeTarget,
            weekdays: behavior.smartAlarmWeekdays,
            lastFiredSessionStart: behavior.smartAlarmLastFiredSessionStart
        )
        switch decision {
        case .waiting:
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            behavior.smartAlarmArmedSessionStart = 0
            smartAlarmRuntimeState = .waitingForSleep

        case .schedule(let fireDate, let observation, let targetMinutes):
            ble.armStrapAlarm(at: fireDate)
            behavior.smartAlarmArmedSessionStart = observation.sessionStart
            smartAlarmRuntimeState = .durationScheduled(
                fireDate: fireDate,
                asleepMinutes: observation.asleepMinutes,
                targetMinutes: targetMinutes
            )
            Self.scheduleSmartAlarmDurationBackupNotification(
                at: fireDate,
                log: { [weak self] line in self?.live.append(log: line) }
            )

        case .fire(let observation, let targetMinutes):
            // Persist the guard before sending either wake path. A reconnect, refresh, or app crash after
            // the command cannot make this same detected session buzz twice.
            behavior.smartAlarmLastFiredSessionStart = observation.sessionStart
            behavior.smartAlarmArmedSessionStart = 0
            Self.cancelSmartAlarmBackupNotification()
            TapAutomationPreferences.armAlarmDismiss()
            ble.buzzStrapOnce()
            AppModel.postSmartAlarm()
            smartAlarmRuntimeState = .durationReached(
                asleepMinutes: observation.asleepMinutes,
                targetMinutes: targetMinutes
            )

        case .alreadyFired(let observation, let targetMinutes):
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            behavior.smartAlarmArmedSessionStart = 0
            smartAlarmRuntimeState = .durationReached(
                asleepMinutes: observation.asleepMinutes,
                targetMinutes: targetMinutes
            )
        }
    }

    nonisolated static func smartAlarmTargetMinutes(
        mode: SmartAlarmMode,
        fixedMinutes: Int,
        adaptiveMinutes: Int
    ) -> Int {
        SleepDurationAlarmPolicy.normalizedTargetMinutes(
            mode == .adaptiveSleep ? adaptiveMinutes : fixedMinutes
        )
    }

    /// Compute the next fire date for the smart alarm, honouring the weekday selection.
    /// - `minutes`: target wake time, minutes since local midnight.
    /// - `weekdays`: Calendar weekday numbers (1 = Sun … 7 = Sat) the alarm may fire on. Empty = every
    ///   day. Days outside 1…7 are ignored.
    /// Returns the next strictly-future date matching the time on an enabled weekday, scanning today
    /// plus the next 7 days, or nil if no enabled weekday falls in that range. Pure + side-effect-free
    /// so it can be unit-tested against a fixed clock.
    nonisolated static func nextSmartAlarmDate(minutes: Int,
                                               weekdays: Set<Int>,
                                               from now: Date = Date(),
                                               calendar cal: Calendar = .current) -> Date? {
        let valid = weekdays.filter { (1...7).contains($0) }
        // An empty input means "every day" (backward compatible). A non-empty selection that filters to
        // nothing (only out-of-range numbers) has no valid day to fire on, so it's nil, not a daily alarm.
        if !weekdays.isEmpty && valid.isEmpty { return nil }
        let hour = minutes / 60
        let minute = minutes % 60
        // Scan today (offset 0) through +7 days so a once-a-week alarm picked for "today, already
        // passed" still resolves to the same weekday next week.
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if fire <= now { continue }
            if weekdays.isEmpty { return fire }
            if valid.contains(cal.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }

    /// Re-arms the single-instant firmware alarm once per day (just after local midnight) so a
    /// continuously-bonded strap keeps waking the user past the first fire. macOS stays running so this
    /// fires reliably; iOS additionally re-arms on foreground (it can't run timers while suspended).
    /// `applySmartAlarm` self-gates on `smartAlarmEnabled`, so this is a no-op when the alarm is off.
    private func scheduleDailySmartAlarmRearm() {
        smartAlarmRearmTimer?.invalidate()
        let cal = Calendar.current
        guard let firstFire = cal.nextDate(after: Date(),
                                           matching: DateComponents(hour: 0, minute: 1, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: firstFire, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor for the @MainActor model.
            // applySmartAlarm self-gates on smartAlarmEnabled (and re-asserts the disarmed state if off).
            Task { @MainActor in self?.applySmartAlarm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        smartAlarmRearmTimer = timer
    }

    // MARK: - Physical inputs / wear automation

    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }   // debounce repeats
        lastDoubleTapAt = now

        if let pending = TapAutomationStore.consume(now: now) {
            switch pending.kind {
            case .alarmDismiss:
                stopHaptics()
                live.append(log: "Double-tap → stopped active band alarm haptics")
            case .hydrationConfirm:
                let amountML = min(max(pending.value, 50), 1_000)
                live.append(log: "Double-tap → confirmed \(amountML) ml water")
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.repo.logHydration(amountMl: amountML)
                    HydrationReminders.markDoubleTapConfirmed(contextKey: pending.contextKey)
                    self.buzz(loops: 1)
                }
            case .reminderAcknowledge:
                live.append(log: "Double-tap → acknowledged reminder")
            }
            return
        }

        if SafetySOSGesturePreferences.isEnabled {
            let required = SafetySOSGesturePreferences.requiredEvents
            switch safetySOSGestureAccumulator.record(
                eventUptime: ProcessInfo.processInfo.systemUptime,
                requiredEvents: required
            ) {
            case .progress(let count):
                live.append(
                    log: "SOS gesture: repeated double-tap \(count)/\(required)"
                )
            case .triggered:
                live.append(log: "SOS gesture complete; opening a manual contact page")
                buzz(loops: 3)
                SafetySOSRuntime.shared.trigger { [weak self] outcome in
                    self?.live.append(log: outcome.logLine)
                }
            }
            return
        }

        safetySOSGestureAccumulator.reset()
        live.append(log: "Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock + shortcuts
    /// go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen:
            if !MacActions.lockScreen() {
                #if os(macOS)
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable , fall back to a Shortcut
                #endif
                // iOS can't lock the device and .lockScreen isn't selectable there, so no stray Shortcut launch.
            }
        case .buzzBack: buzz(loops: 1)
        case .markMoment: markMoment()
        case .sleepMark: markSleep()
        case .hapticClock: ble.buzzTimeNow(is24h: Self.localeUses24HourClock)
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// Whether the user's locale formats time on a 24-hour clock , drives the Haptic Clock's hour
    /// encoding (#460) so a double-tap buzzes the time the way the user reads it. Derived from the
    /// locale's "j" (hour) template: a 12-hour locale includes the AM/PM ("a") symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        return !fmt.contains("a")
    }

    /// Record a "moment" (double-tap marker) with a confirming buzz.
    func markMoment() { markMoment(at: Date()) }

    /// Record a "moment" at a specific time (used by the Siri/Shortcuts path, which captures the
    /// invocation time even though the app only drains the queue later when it becomes active).
    func markMoment(at date: Date) {
        moments.append(date)
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(loops: 1)
        live.append(log: "Moment marked")
    }

    /// #461: record a "sleep mark" , a bedtime / wake / mid-night tap. Stored like moments (survives
    /// relaunch) and written as a distinct, greppable "Sleep mark @ HH:mm" line into the strap log so it
    /// rides along in the shared log / raw export. A single buzz confirms it registered. No start/end
    /// smarts yet (Phase 1): marks are logged in sequence; pairing into sleep bounds comes later.
    func markSleep() { markSleep(at: Date()) }
    func markSleep(at date: Date) {
        sleepMarks.append(date)
        if sleepMarks.count > 500 { sleepMarks.removeFirst(sleepMarks.count - 500) }
        UserDefaults.standard.set(sleepMarks.map(\.timeIntervalSince1970), forKey: "sleepMarks")
        buzz(loops: 1)
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        live.append(log: "Sleep mark @ \(hhmm.string(from: date))")
        // Persistence parity with Android's `AppViewModel.markSleep` (#461): also upsert the TYPED
        // `sleep_mark` metric-series row that the Sleep screen reads back (SleepView.logMark writes the
        // same row when the user taps a button). A physical double-tap can't choose bedtime vs wake, so
        // it defaults to `.bedtime` , the boundary the gesture most naturally marks. Idempotent by
        // (deviceId, day, key) through the repo's live store handle: no new Repository API, no schema
        // change. The UserDefaults list + buzz + freetext log line above are unchanged.
        let mark = SleepMark(type: .bedtime, at: date)
        Task { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            _ = try? await store.upsertMetricSeries([mark.metricPoint], deviceId: self.repo.deviceId)
        }
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            #if os(macOS)
            // Auto-lock on wrist-off is a macOS-only affordance (the toggle is hidden on iOS, where a
            // third-party app can't lock the device). Guarding it here also stops a stray "Lock Screen"
            // Shortcut launch for any iOS user who toggled this on before it was gated off iPhone.
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            #endif
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }

    /// Illness/strain early-warning (v5). Each signal gets its own calendar freshness and trusted
    /// personal baseline through `IllnessSignalPipeline`; nearby journal context is explanatory and can
    /// never hide a corroborated shift. An explicit feeling-unwell entry remains visible even when the
    /// wearable is absent because missing sensor data cannot assess symptom severity.
    private func evaluateIllness(_ days: [DailyMetric]) {
        let ordered = days.sorted { $0.day < $1.day }
        let currentKey = max(Repository.logicalDayKey(Date()), Repository.localDayKey(Date()))
        guard behavior.illnessWatch else {
            healthAlert = nil; illnessSignal = nil; illnessDistance = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            // Journal context uses exact civil days rather than whichever wearable rows happen to be
            // last. This keeps symptom-first behavior available through data gaps and sparse histories.
            let recentDays = Self.illnessJournalDayKeys()
            let journal = await self.repo.journalEntries(days: 7)
            guard self.behavior.illnessWatch else { return }
            var ctxAlcohol = false, ctxHardWorkout = false, ctxAlreadyUnwell = false
            for e in journal where e.answeredYes && recentDays.contains(e.day) {
                let q = e.question.lowercased()
                if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
                if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
                if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
            }
            self.applyIllnessSignal(ordered, alcohol: ctxAlcohol, hardOrLateWorkout: ctxHardWorkout,
                                    alreadyUnwell: ctxAlreadyUnwell, todayKey: currentKey)
        }
    }

    /// Current civil day plus the prior two, matching the engine's maximum per-signal age without
    /// borrowing dates from available sensor rows.
    nonisolated static func illnessJournalDayKeys(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Set<String> {
        Set((0...IllnessSignalPipeline.maximumSignalAgeDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return String(
                format: "%04d-%02d-%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                year,
                month,
                day
            )
        })
    }

    /// Pure freshness seam for the illness adapter. A historical import must never be presented as a
    /// current multi-vital shift; allow today plus the prior two wake days, reject future-dated rows.
    nonisolated static func illnessHistoryIsFresh(dayKeys: [String], todayKey: String,
                                                  maxAgeDays: Int = 2) -> Bool {
        guard let latestKey = dayKeys.max() else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let latest = formatter.date(from: latestKey),
              let today = formatter.date(from: todayKey) else { return false }
        let age = formatter.calendar.dateComponents([.day], from: latest, to: today).day ?? Int.max
        return age >= 0 && age <= maxAgeDays
    }

    /// Run the `IllnessSignalEngine` from the day history + the journal-derived confounder context, then
    /// publish the result + the legacy `healthAlert` banner string (kept for the existing banner surface).
    private func applyIllnessSignal(_ days: [DailyMetric], alcohol: Bool,
                                    hardOrLateWorkout: Bool, alreadyUnwell: Bool,
                                    todayKey: String) {
        let previous = healthAlert
        let prepared = IllnessSignalPipeline.prepare(days: days, todayKey: todayKey)
        let result = IllnessSignalEngine.evaluate(
            prepared.inputs,
            context: .init(
                alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout,
                alreadyUnwell: alreadyUnwell,
                recentMedicationChange: MedicationStore.hasRecentChange,
                baselineTrusted: prepared.baselineTrusted
            ),
            firedLabels: prepared.firedLabels
        )
        illnessDistance = IllnessDistance.evaluate(
            features: prepared.distanceFeatures,
            correlation: nil
        )
        illnessSignal = result
        // The amber banner string reflects the raised / already-unwell levels only (the calmer levels
        // surface in the Health hub's Heads-Up card, never as a scary banner).
        healthAlert = (result.level == .raised || result.level == .alreadyUnwell) ? result.copy : nil
        if healthAlert != nil, previous == nil {
            IllnessNotifier.post()
        }
    }

    /// #593: once-a-day Effort-marker nudge. The old three-bucket recovery mapping is intentionally
    /// gone: this uses DailyActionPlanner's personal-history range, which requires a current solid
    /// multi-signal readiness read plus today's explicit "as usual" self-check. Missing/thin/shifted
    /// evidence yields no target and therefore no notification. The gate stays on canonical 0–100
    /// Effort so storage, planner, and notifier cannot disagree about conversion.
    func evaluateStrainTarget() {
        guard let row = repo.today else { return }
        let plan = DailyActionPlanner.plan(
            today: row.day,
            readiness: ReadinessEngine.evaluate(days: repo.days, today: row.day),
            checkIn: behavior.dailyActionCheckIn(for: row.day),
            recentEffort: repo.days.map {
                DailyActionPlanner.EffortDay(day: $0.day, effort: $0.strain)
            }
        )
        StrainTargetNotifier.onDayUpdate(
            day: row.day,
            dayEffort: row.strain,
            targetRange: plan.target,
            enabled: behavior.strainTargetNudge)
    }

    /// Re-run the illness watch over the cached history. Called when the Automations toggle
    /// flips , the repo.$days sink only fires on data changes, so a flip would otherwise wait
    /// for the next refresh.
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    /// Re-run opt-in contextual checks after a settings change. Repository refreshes call the same
    /// coalesced path automatically when new wearable or HealthKit data lands.
    func reevaluateContextualInterventions() {
        scheduleContextualInterventionEvaluation()
    }

    /// Background refreshes await this boundary so iOS cannot complete the BG task between enqueueing
    /// and evaluating newly imported sleep/vital evidence.
    func reevaluateContextualInterventionsNow() async {
        guard operationalWorkStarted else { return }
        adaptiveDayEvaluationGate.invalidate()
        contextualEvaluationTask?.cancel()
        contextualEvaluationTask = nil
        await evaluateContextualInterventions()
    }

    private func scheduleContextualInterventionEvaluation() {
        guard operationalWorkStarted else { return }
        adaptiveDayEvaluationGate.invalidate()
        contextualEvaluationTask?.cancel()
        contextualEvaluationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.evaluateContextualInterventions()
        }
    }

    /// Event-driven wellness delivery over data that has already been validated and stored. Oxygen needs
    /// two fresh low days; explicit body temperature gets a recheck-only review; VO2 needs two persistent
    /// recent points against an older reference. Skin temperature stays in the corroborated multi-vital
    /// rule and is never treated as body temperature.
    private func evaluateContextualInterventions() async {
        guard operationalWorkStarted else { return }
        await evaluateAdaptiveDayGuidance()

        if ContextualInterventionSettings.vitalReviewEnabled {
            if let oxygen = ContextualVitalPolicy.oxygenCandidate(sourceRows: repo.vitalRows) {
                ContextualInterventionCenter.post(oxygen)
            }

            async let appleBodyRows = repo.exploreSeries(
                key: "body_temp", source: Repository.appleHealthSource, days: 7
            )
            async let healthConnectBodyRows = repo.exploreSeries(
                key: "body_temp", source: Repository.healthConnectSource, days: 7
            )
            async let wearableBodyRows = repo.exploreSeries(
                key: "body_temp", source: repo.deviceId, days: 7
            )
            let (appleBody, healthConnectBody, wearableBody) = await (
                appleBodyRows, healthConnectBodyRows, wearableBodyRows
            )
            guard !Task.isCancelled else { return }
            let bodyPoints =
                appleBody.map {
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        day: $0.day, valueC: $0.value,
                        source: Repository.appleHealthSource, sourcePriority: 0
                    )
                } +
                healthConnectBody.map {
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        day: $0.day, valueC: $0.value,
                        source: Repository.healthConnectSource, sourcePriority: 1
                    )
                } +
                wearableBody.map {
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        day: $0.day, valueC: $0.value,
                        source: repo.deviceId, sourcePriority: 2
                    )
                }
            if let bodyTemperature = ContextualVitalPolicy.bodyTemperatureCandidate(
                points: bodyPoints
            ) {
                ContextualInterventionCenter.post(bodyTemperature)
            }
        }

        guard ContextualInterventionSettings.vo2ReviewEnabled,
              !Task.isCancelled else { return }
        async let appleMeasuredRows = repo.exploreSeries(
            key: "vo2max",
            source: Repository.appleHealthSource,
            days: 400
        )
        async let wearableMeasuredRows = repo.exploreSeries(
            key: "vo2max",
            source: "my-whoop",
            days: 400
        )
        async let estimatedRows = repo.exploreSeries(
            key: "vo2max_est",
            source: "my-whoop",
            days: 400
        )
        let (appleMeasured, wearableMeasured, estimated) = await (
            appleMeasuredRows,
            wearableMeasuredRows,
            estimatedRows
        )
        guard !Task.isCancelled else { return }

        // Apple Health wins a same-day collision because it carries an explicit measured VO2 type;
        // wearable imports fill days Apple does not have. Estimated model points remain a separate lane.
        var measuredByDay: [String: Double] = [:]
        for row in wearableMeasured { measuredByDay[row.day] = row.value }
        for row in appleMeasured { measuredByDay[row.day] = row.value }
        let measured = measuredByDay
            .map { ContextualVitalPolicy.VO2Point(day: $0.key, value: $0.value) }
            .sorted { $0.day < $1.day }
        let modelled = estimated.map {
            ContextualVitalPolicy.VO2Point(day: $0.day, value: $0.value)
        }
        if let candidate = ContextualVitalPolicy.vo2Candidate(
            measured: measured,
            estimated: modelled
        ) {
            ContextualInterventionCenter.post(candidate)
        }
    }

    /// Evaluate fresh sleep, personal sleep timing, and a persisted timezone transition through one
    /// ranked policy. The offset baseline is maintained even while the feature is off so enabling it
    /// later cannot resurrect an old trip as a new observation.
    private func evaluateAdaptiveDayGuidance(now: Date = Date()) async {
        guard operationalWorkStarted else { return }
        let evaluationGeneration = adaptiveDayEvaluationGate.begin()
        let nowSec = Int(now.timeIntervalSince1970)
        let offset = TimeZone.autoupdatingCurrent.secondsFromGMT(for: now)
        let change = AdaptiveDayTimeZoneStore.observe(
            offsetSec: offset,
            nowSec: nowSec
        )
        guard ContextualInterventionSettings.adaptiveDayGuidanceEnabled else {
            AdaptiveDayTimeZoneStore.discardPending()
            AdaptivePlannedWorkoutScheduler.cancelPending()
            ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                keepingFingerprint: nil
            )
            return
        }
        let today = max(Repository.logicalDayKey(now), Repository.localDayKey(now))
        let recommendation = AdaptiveDayGuidance.recommendation(.init(
            today: today,
            nowSec: nowSec,
            currentTimeZoneOffsetSec: offset,
            sleepTargetMinutes: WindDownNudge.sleepNeedMinutes,
            sleepDays: repo.days.map {
                .init(day: $0.day, totalSleepMinutes: $0.totalSleepMin)
            },
            sleepWindows: repo.sleeps.map {
                .init(startSec: $0.effectiveStartTs, endSec: $0.endTs)
            },
            timeZoneChange: change
        ))
        if let recommendation, recommendation.kind == .travelAdjustment {
            guard !Task.isCancelled else { return }
            AdaptivePlannedWorkoutScheduler.cancelPending()
            ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                keepingFingerprint: nil
            )
            ContextualInterventionCenter.post(
                AdaptiveDayInterventionFactory.candidate(from: recommendation)
            )
            return
        }

        let calendarRefresh = await PlannedWorkoutCalendarStore.shared.refreshOutcome(now: now)
        guard !Task.isCancelled else { return }
        guard adaptiveDayEvaluationGate.isCurrent(evaluationGeneration) else { return }
        guard case .completed(let plannedWorkout) = calendarRefresh else { return }
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: ReadinessEngine.evaluate(days: repo.days, today: today),
            checkIn: behavior.dailyActionCheckIn(for: today),
            recentEffort: repo.days.map {
                DailyActionPlanner.EffortDay(day: $0.day, effort: $0.strain)
            },
            recentSleep: repo.days.map {
                DailyActionPlanner.SleepDay(day: $0.day, minutes: $0.totalSleepMin)
            },
            sleepTargetMinutes: WindDownNudge.sleepNeedMinutes,
            sleepTargetIsExplicit: WindDownNudge.hasExplicitSleepNeed,
            plannedWorkout: plannedWorkout?.plannedWorkout(forPlanningDay: today),
            nowSec: nowSec
        )
        if let adjustment = plan.workoutAdjustment {
            let candidate = AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
                from: adjustment,
                day: today,
                observedAt: now
            )
            let leadSeconds = adjustment.startSec - nowSec
            if leadSeconds <= 0 {
                AdaptivePlannedWorkoutScheduler.cancelPending()
                ContextualInterventionCenter.expirePlannedWorkoutArtifacts(
                    fingerprint: candidate.fingerprint
                )
            } else {
                ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                    keepingFingerprint: candidate.fingerprint
                )
                if leadSeconds > Int(AdaptivePlannedWorkoutScheduler.leadTime) {
                    let scheduled = await AdaptivePlannedWorkoutScheduler.schedule(
                        adjustment: adjustment,
                        day: today,
                        now: now
                    ) { [weak self] in
                        await self?.evaluateAdaptiveDayGuidance(now: Date())
                    }
                    guard !Task.isCancelled else { return }
                    guard adaptiveDayEvaluationGate.isCurrent(evaluationGeneration) else {
                        return
                    }
                    if scheduled { return }
                } else {
                    AdaptivePlannedWorkoutScheduler.cancelPending()
                }
                if leadSeconds <= Int(AdaptivePlannedWorkoutScheduler.leadTime) {
                    ContextualInterventionCenter.post(
                        candidate
                    ) { [weak self] retryAt in
                        _ = AdaptivePlannedWorkoutScheduler.scheduleRetry(
                            start: Date(
                                timeIntervalSince1970: TimeInterval(adjustment.startSec)
                            ),
                            fingerprint: candidate.fingerprint,
                            retryAt: retryAt
                        ) { [weak self] in
                            await self?.evaluateAdaptiveDayGuidance(now: Date())
                        }
                    }
                    return
                }
            }
        } else {
            AdaptivePlannedWorkoutScheduler.cancelPending()
            ContextualInterventionCenter.reconcileMissingPlannedWorkoutArtifacts(
                now: now
            )
        }

        if let recommendation {
            ContextualInterventionCenter.post(
                AdaptiveDayInterventionFactory.candidate(from: recommendation)
            )
        }
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    //
    // Run in the analytics pass (IntelligenceEngine calls this after it persists the night's scores) so
    // the Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines fed
    // from the merged daily history; cycle awareness is gated behind the opt-in flag (default OFF) and
    // never computes , let alone surfaces , until the user turns it on.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF , the most sensitive health category,
    /// manual-first). The Settings toggle + the card's opt-in CTA both write this single key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    /// Recompute the v5 skin-temp suite snapshots (cycle phase + body clock) from the current history.
    /// Called from the analytics pass and when the cycle opt-in flips. Honest-nil throughout: cycle is
    /// nil unless opted in; circadian is nil unless a usable activity profile exists.
    func refreshV5Signals() async {
        await computeCyclePhase()
        await computeCircadianPhase()
    }

    /// Cycle-phase awareness from the nightly skin-temperature shift (+ luteal RHR rise / HRV drop). Each
    /// night is z-scored against the personal baseline, then `CyclePhaseEngine.classify` reads the run.
    /// Gated behind the opt-in flag; clears the published result the moment it's turned off.
    private func computeCyclePhase() async {
        guard cycleAwarenessEnabled else { cyclePhase = nil; cycleCurve = []; return }
        let days = repo.days
        guard let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return }

        // The daily skin-temp column is mixed: imported WHOOP rows are absolute °C and local rows are
        // signed deviations. Each night is therefore evaluated only against PRIOR rows of its own kind;
        // RHR + HRV continue to z-score their raw columns. Oldest→newest.
        let sorted = days.sorted { $0.day < $1.day }
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)

        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        var latestSkinAssessment: VitalBands.SkinTempIllnessAssessment?
        for (index, d) in sorted.enumerated() {
            let priorSkin = sorted[..<index].map(\.skinTempDevC)
            let skinAssessment = VitalBands.skinTempIllnessAssessment(
                recent: [d.skinTempDevC],
                baseline: Array(priorSkin)
            )
            latestSkinAssessment = skinAssessment ?? latestSkinAssessment
            let tempZ = skinAssessment?.reading.present == true
                ? skinAssessment?.reading.zIllnessward
                : nil
            let rhrZ = (rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil)
            let hrvZ = (hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil)
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        // User-entered cycle-day-1 anchors live in the isolated local `noop-cycle` series. The pure
        // engine cross-validates them against the temperature shift; a mistimed log is flagged rather
        // than silently overriding the sensor evidence.
        let loggedPeriodStarts = await repo.periodStarts()
        cyclePhase = CyclePhaseEngine.classify(nights,
                                               baselineUsable: latestSkinAssessment?.baselineTrusted == true,
                                               loggedPeriodStarts: loggedPeriodStarts,
                                               asOfDay: Repository.localDayKey(Date()))
        cycleCurve = curve
    }

    /// Body-clock phase estimate. Builds a coarse per-hour activity profile from the last ~14 days of
    /// downsampled HR buckets (HR amplitude is a usable rest/activity rhythm proxy when raw motion isn't
    /// to hand), then fits the cosinor. nil when there isn't enough to read.
    private func computeCircadianPhase() async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 14 * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now, bucketSeconds: 3_600)
        guard buckets.count >= 24 else { circadianPhase = nil; return }
        let tz = TimeZone.current.secondsFromGMT()
        // Pool HR by LOCAL hour-of-day → mean bpm per hour as the activity proxy (higher HR ≈ more active).
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { circadianPhase = nil; return }
        // Habitual wake from the most recent night's banked wake, falling back to a 07:00 default.
        let wakeHour = habitualWakeHour() ?? 7.0
        circadianPhase = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: daySet.count, habitualWakeHour: wakeHour)
    }

    /// A coarse habitual wake hour (local) from the most recent banked sleep session's end time, for the
    /// circadian schedule-offset comparison. nil when no sleep is banked.
    private func habitualWakeHour() -> Double? {
        guard let last = repo.sleeps.last else { return nil }
        let tz = TimeZone.current.secondsFromGMT()
        let local = (last.endTs + tz) % 86_400
        return Double((local + 86_400) % 86_400) / 3_600.0
    }

    // MARK: - v5 local multi-device fusion adapter
    //
    // Assemble today's per-source values per metric and run `FusionResolver` so the "Your Data, Fused"
    // screen (FusedRecordView) can show the best-sourced number + provenance + agreement. This does NOT
    // touch the core resolvedSeries waterfall , it's an additive read that reuses the rows the store
    // already holds, exactly the seam the view's header documents.

    /// Build today's fused record (best signal per metric across every source, with agreement). Reads each
    /// declared-fusable metric's latest per-source daily value, runs the pure `FusionResolver`, and maps
    /// the result into the view's `FusedRecord`. Honest single-source degradation falls out of the engine
    /// (a one-WHOOP user gets `.single` agreement and `contributingSourceCount == 1`).
    func buildTodayFusedRecord() async -> FusedRecord {
        guard let store = await repo.storeHandle() else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }
        // The metrics surfaced, in importance-first display order, with a label + accent.
        let specs: [(key: String, label: String, accent: String?)] = [
            ("rhr", "Resting HR", nil),
            ("hrv", "HRV", nil),
            ("sleep_total_min", "Sleep", nil),
            ("steps", "Steps", nil),
            ("skin_temp", "Skin temp", nil),
            ("spo2", "Blood oxygen", nil),
        ]
        // Every source that could carry a value, mapped to its stored device id. (FusionSource.rawValue
        // IS the canonical source id, but the strap's real id is `deviceId`/`computed` , map explicitly.)
        let sources: [(FusionSource, String)] = [
            (.whoopImport, deviceId),
            (.noopComputed, deviceId + "-noop"),
            (.appleHealth, appleDeviceId),
            (.xiaomiBand, FusionSource.xiaomiBand.rawValue),
        ]

        let now = Date()
        let fromDay = Repository.dayString(now.addingTimeInterval(-3 * 86_400))
        let toDay = Repository.dayString(now.addingTimeInterval(86_400))

        // Read each source's daily rows once, then pick the freshest per metric for the latest day.
        var rowsBySource: [FusionSource: DailyMetric] = [:]
        for (src, id) in sources {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)) ?? []
            if let latest = rows.sorted(by: { $0.day < $1.day }).last { rowsBySource[src] = latest }
        }
        guard !rowsBySource.isEmpty else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }

        var fusedRows: [FusedRow] = []
        var contributingSources = Set<FusionSource>()
        for spec in specs {
            var inputs: [FusionInput] = []
            for (src, daily) in rowsBySource {
                if let v = Self.fusionColumn(key: spec.key, day: daily) {
                    inputs.append(FusionInput(source: src, value: v))
                    contributingSources.insert(src)
                }
            }
            guard let point = FusionResolver.resolve(metricKey: spec.key, inputs: inputs) else { continue }
            fusedRows.append(FusedRow(point: point, label: spec.label, accentHex: spec.accent))
        }

        // The day-owner = the highest-priority source that actually contributed (the scores' single owner).
        let owner = contributingSources.min(by: {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        })
        return FusedRecord(rows: fusedRows, dayOwner: owner,
                           contributingSourceCount: contributingSources.count)
    }

    /// The DailyMetric column a fusion metric key maps to (mirrors Repository.dailyColumn for the keys
    /// the fused record surfaces). nil when the source row doesn't carry that metric.
    private static func fusionColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "rhr":             return d.restingHr.map(Double.init)
        case "hrv":             return d.avgHrv
        case "sleep_total_min": return d.totalSleepMin
        case "steps":           return d.steps.map(Double.init)
        case "skin_temp":       return d.skinTempDevC
        case "spo2":            return d.spo2Pct
        default:                return nil
        }
    }

    /// Import a Whoop CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    /// A picked import file made safe to read. On iOS the security-scoped , and possibly
    /// iCloud-placeholder , URL is coordinated and COPIED into the app's temp directory, so the
    /// importer reads a stable LOCAL file. That's what makes import work for iCloud Drive files (they
    /// arrive as un-downloaded placeholders that ZIPFoundation can't open in place) and removes the
    /// scoped-access timing fragility that blocked iPhone imports (#179). On macOS the picked URL is
    /// read in place. `cleanup()` removes the temp copy AND the original `Documents/Inbox/` copy that
    /// `UIDocumentPickerViewController(asCopy: true)` leaves behind , a multi-GB Apple Health
    /// `export.zip` parked there was the runaway "Documents & Data" growth in #590 (one import → the
    /// store rows AND a permanent ~19 GB Inbox duplicate the OS never reclaims). Sendable so it can
    /// cross the actor boundary.
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        /// The picker's `asCopy:true` drop in `Documents/Inbox/`, deleted on cleanup so it can't
        /// accumulate. nil on macOS (the URL is read in place, nothing to reclaim).
        private let inboxOriginal: URL?
        init(url: URL, temp: URL?, inboxOriginal: URL? = nil) {
            self.url = url; self.temp = temp; self.inboxOriginal = inboxOriginal
        }
        func cleanup() {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let inboxOriginal, Self.isInImportInbox(inboxOriginal) {
                try? FileManager.default.removeItem(at: inboxOriginal)
            }
        }

        /// Only ever delete files the picker placed in OUR app's `Documents/Inbox/` , never a
        /// user-chosen in-place file on macOS or an iCloud URL outside the sandbox. The guard keeps
        /// `cleanup()` from removing anything the user still owns.
        static func isInImportInbox(_ url: URL) -> Bool {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let inbox = docs.appendingPathComponent("Inbox").standardizedFileURL.path
            let candidate = url.standardizedFileURL.path
            return candidate.hasPrefix(inbox + "/")
        }
    }

    /// Runs off the main actor (nonisolated) so copying a large export never blocks the UI; the
    /// caller holds the security scope (process-wide) for the duration.
    nonisolated static func materializeForImport(_ picked: URL) async throws -> ImportFile {
        #if os(iOS)
        let ext = picked.pathExtension.isEmpty ? "dat" : picked.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        var coordError: NSError?
        var ioError: Error?
        // .forUploading materialises an iCloud placeholder and gives a stable snapshot to copy from.
        NSFileCoordinator().coordinate(readingItemAt: picked, options: [.forUploading], error: &coordError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
            } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        // The picked URL is the picker's own `asCopy:true` duplicate in Documents/Inbox; pass it
        // through so cleanup() can reclaim it (it's the original of `dst`, not a user file).
        return ImportFile(url: dst, temp: dst, inboxOriginal: picked)
        #else
        return ImportFile(url: picked, temp: nil)
        #endif
    }

    /// One-shot launch sweep of `Documents/Inbox/`: deletes any stale `asCopy:true` picker drops a
    /// previous build left behind before `cleanup()` reclaimed them (#590). Best-effort, off-main, and
    /// safe , `Inbox` only ever holds picker hand-offs, never user data. Skips files newer than 60 s so
    /// it can't race an import that's mid-flight at launch.
    nonisolated static func purgeImportInbox() {
        #if os(iOS)
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = docs.appendingPathComponent("Inbox")
        guard let items = try? fm.contentsOfDirectory(at: inbox,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }   // leave an in-flight hand-off alone
            try? fm.removeItem(at: item)
        }
        #endif
    }

    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .whoopExport, url: local.url)
                let summary = try await WhoopImporter.importExport(url: local.url, into: store,
                                                                   deviceId: deviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                repo.noteWorkoutsChanged()
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Import an Apple Health export (export.zip) , streams + aggregates per-day into the store
    /// under the `apple-health` source, then refreshes. Large exports take ~1–2 minutes.
    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.xiaomi, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .xiaomiBand, url: local.url)
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store,
                                                                    trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                finishImport(.xiaomi, summary: "Imported \(days) days · \(sleeps) sleeps\(span)")
            } catch {
                finishImport(.xiaomi, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        // FIX 2(c): run the parse+writes at `.utility` so a large Apple Health import yields to UI
        // rendering instead of inheriting the user-initiated QoS of the calling tap , the import's bulk
        // work was contending with the main actor and contributing to the transient post-import lag.
        Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .appleHealth, url: local.url)
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store,
                                                                       deviceId: appleDeviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                repo.noteWorkoutsChanged()
                await repo.refresh()
                repo.noteAgeMetricsChanged()
                // #833/v7.7.2: an Apple Health import may write ONLY body-composition series (weight/body_fat/
                // lean_mass/bmi/vo2max), which live in metricSeries OUTSIDE refresh()'s diff over daily/sleep/
                // vitals, so refresh() may not bump `refreshSeq`. AppleHealthView's re-mount cache keys on
                // `refreshSeq`, so it would keep serving the pre-import snapshot. Explicitly drop the cache so
                // the next visit re-reads the freshly imported data. (refresh() alone is insufficient here.)
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    // MARK: - Storage diagnostics (#590 , StorageView)

    /// A point-in-time snapshot of where the app's on-disk footprint is going, for the Storage screen.
    /// All sizes in bytes; `db` is nil only for an unopened/in-memory store.
    struct StorageCategory: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let bytes: Int64
    }

    struct StorageReport: Equatable, Sendable {
        var db: Int64?
        var inbox: Int64
        var importTemp: Int64
        var databaseCategories: [StorageCategory]
    }

    /// Gather the storage report off the main actor: the GRDB file (+ WAL/SHM) from the store, plus the
    /// `Documents/Inbox/` picker-drop directory and the import temp files this app writes.
    func storageReport() async -> StorageReport {
        let store = await repo.storeHandle()
        let db = await store?.databaseFileSizeBytes()
        let detail = await store?.databaseStorageBreakdown()
        let inbox = Self.inboxSizeBytes()
        let temp = Self.importTempSizeBytes()
        return StorageReport(
            db: db,
            inbox: inbox,
            importTemp: temp,
            databaseCategories: Self.storageCategories(from: detail)
        )
    }

    /// Convert physical SQLite objects into user-meaningful sensor groups. Unknown/future tables stay
    /// visible under scores and records, so adding a migration can never make bytes disappear from the
    /// explanation merely because this mapper has not learned the new table name yet.
    nonisolated static func storageCategories(
        from detail: DatabaseStorageBreakdown?
    ) -> [StorageCategory] {
        guard let detail else { return [] }
        let heart: Set<String> = ["hrSample", "rrInterval", "ppgHrSample"]
        let optical: Set<String> = ["ppgWaveformSample"]
        let movement: Set<String> = ["gravitySample", "stepSample", "sleepStateSample"]
        let sensors: Set<String> = [
            "spo2Sample", "skinTempSample", "respSample", "battery", "event",
        ]
        let diagnostic: Set<String> = ["rawBatch", "rawImuSample"]

        var totals: [String: Int64] = [:]
        for object in detail.objects {
            let key: String
            if heart.contains(object.tableName) {
                key = "heart"
            } else if optical.contains(object.tableName) {
                key = "optical"
            } else if movement.contains(object.tableName) {
                key = "movement"
            } else if sensors.contains(object.tableName) {
                key = "sensors"
            } else if diagnostic.contains(object.tableName) {
                key = "diagnostic"
            } else {
                key = "records"
            }
            totals[key, default: 0] += object.bytes
        }
        totals["working", default: 0] += detail.otherMainBytes + detail.sidecarBytes

        let labels = [
            "heart": "Heart & rhythm history",
            "optical": "Optical waveform history",
            "movement": "Movement history",
            "sensors": "Other sensor history",
            "records": "Scores, workouts & records",
            "diagnostic": "Diagnostic captures",
            "working": "Database working space",
        ]
        return totals.compactMap { key, bytes in
            guard bytes > 0, let label = labels[key] else { return nil }
            return StorageCategory(id: key, label: label, bytes: bytes)
        }
        .sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.label < rhs.label
        }
    }

    /// Total bytes in `Documents/Inbox/` (the picker's `asCopy:true` drops). 0 on macOS / when absent.
    nonisolated static func inboxSizeBytes() -> Int64 {
        #if os(iOS)
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        return directorySizeBytes(docs.appendingPathComponent("Inbox"))
        #else
        return 0
        #endif
    }

    /// True for any scratch file/dir NOOP itself writes into the temp directory , import copies, the
    /// decompressed export.xml, exports, backups, raw captures: every one is prefixed `noop-`. #590: the
    /// import decompresses `export.xml` to a `noop-health-*` temp file (up to 8 GB), but a previous build
    /// only matched `noop-import-*`, so an interrupted import stranded multi-GB extractions the Storage
    /// screen never saw OR reclaimed. Matching the shared `noop-` prefix counts + sweeps them all and is
    /// future-proof. Safe: the temp dir is NOOP's private sandbox and the 60 s in-flight guard in
    /// `purgeImportTemp` protects a live import.
    nonisolated static func isNoopTempScratch(_ name: String) -> Bool { name.hasPrefix("noop-") }

    /// Total bytes of NOOP's own `noop-*` temp scratch (a crash mid-import can strand a multi-GB one).
    /// Recurses into directories (the Xiaomi importer stages a `noop-xiaomi-*` folder).
    nonisolated static func importTempSizeBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// Sum every regular file under `dir` (one level , Inbox is flat). Best-effort; missing dir → 0.
    nonisolated private static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// The Storage screen's "Clean up" action: purge the Inbox + stranded import temps, then truncate
    /// the WAL so the freed pages return to the OS. Returns a fresh report so the screen updates. Safe ,
    /// Inbox/temp hold only picker hand-offs + this app's own temp copies, never user data or live rows.
    @discardableResult
    func cleanUpStorage() async -> StorageReport {
        Self.purgeImportInbox()
        Self.purgeImportTemp()
        _ = await ble.performStorageMaintenance(force: true)
        if let store = await repo.storeHandle() {
            if RemoteSyncPreferences.endpoint.isEmpty {
                try? await store.configureRemoteSyncPendingIndexes(enabled: false)
            }
            try? await store.checkpointWAL()
            try? await store.compactDatabase()
        }
        return await storageReport()
    }

    /// Remove NOOP's stranded `noop-*` temp scratch (import copies, the multi-GB `noop-health-*`
    /// export.xml an interrupted import leaves behind , #590, exports, backups, raw captures). Mirrors
    /// `purgeImportInbox`'s 60 s in-flight guard so a concurrent import/export isn't disturbed.
    nonisolated static func purgeImportTemp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: item)
        }
    }

    /// Handle a `noop://import-health` deep link (PR #581), the HealthKit-free Shortcuts import for
    /// sideloaded installs. Custom URL schemes are forgeable by other apps/sites, so this only decodes
    /// and stages the payload. The iOS shell shows a confirmation alert before `confirmHealthImport()`
    /// writes anything into the `apple-health` source.
    func handleHealthImportURL(_ url: URL) {
        switch ShortcutHealthImport.prepare(url: url) {
        case .success(let pending):
            pendingShortcutHealthImport = pending
        case .failure(let outcome):
            beginImport(.appleHealth)
            Task { await finishShortcutHealthImport(outcome) }
        }
    }

    func cancelPendingHealthImport() {
        pendingShortcutHealthImport = nil
    }

    func confirmPendingHealthImport() {
        guard let pending = pendingShortcutHealthImport else { return }
        pendingShortcutHealthImport = nil
        beginImport(.appleHealth)
        Task {
            guard let store = await repo.storeHandle() else {
                finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                return
            }
            let outcome = await ShortcutHealthImport.ingest(prepared: pending, into: store)
            await finishShortcutHealthImport(outcome)
        }
    }

    private func finishShortcutHealthImport(_ outcome: ShortcutHealthImport.Outcome) async {
        switch outcome {
        case .imported(let days, let workouts):
            if workouts > 0 { repo.noteWorkoutsChanged() }
            await repo.refresh()
            repo.noteAgeMetricsChanged()
            // #833/v7.7.2: the Shortcuts import writes body-composition series (e.g. weight) into
            // metricSeries, which sits OUTSIDE refresh()'s diff, so refresh() may leave `refreshSeq`
            // unchanged and AppleHealthView's re-mount cache would serve stale data. Drop the cache so the
            // next visit re-reads. (Same reasoning as the file-import path above.)
            repo.appleHealthCache = nil
            repo.appleHealthLoadedSeq = -1
            let w = workouts > 0 ? " · \(workouts) workouts" : ""
            finishImport(.appleHealth, summary: "Imported \(days) days\(w)")
        case .nothingToImport:
            finishImport(.appleHealth, summary: "Nothing new to import.")
        case .rejected(let reason):
            finishImport(.appleHealth, summary: reason, failed: true)
        }
    }

    /// Marks a source as importing and clears only that source's old status text + failure flag.
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        case .xiaomi:
            xiaomiImportSummary = nil
            xiaomiImportFailed = false
        }
    }

    /// Stores the completed import summary (and typed failure flag) on the matching source card.
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = CustomerFacingBrand.text(summary)
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        activeImportSource = nil
    }
}
