#if os(iOS)
import Foundation
import HealthKit
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. NOOP does not upload this data to a NOOP-operated cloud and every access is
/// strictly opt-in; samples written to Apple Health follow the user's Apple Health/iCloud settings.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// Sideloadly) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework is
        /// present but the app can never read/write Health and can never appear under
        /// Settings › Health › Data Access & Devices. Distinct from `.denied` (entitled build, user
        /// said no) and `.unavailable` (no HealthKit hardware) so the UI can route to the honest
        /// file/Shortcuts import path instead of giving impossible Settings instructions (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// These optional scopes are deliberately separate from the first Apple Health connection.
    /// HealthKit does not reveal read authorization, so these flags mean only that the user tapped
    /// NOOP's dedicated rationale/action and the staged system request completed.
    @Published private(set) var bodyCompositionAccessRequested = false
    @Published private(set) var highResolutionWritebackRequested = false
    /// The most recent failure surfaced by `sync` / `writeBack`. Cleared on a successful run. UI binds
    /// here so an Apple Health auth revoke, quota hit, or invalid sample is visible instead of silent.
    @Published private(set) var lastError: String?

    /// Whether this signed build carries Apple's separate observer background-delivery entitlement.
    /// Observer queries still run while NOOP is active when false; only system-scheduled background
    /// wakes are unavailable. App Store builds have no embedded profile and are assumed entitled.
    var backgroundDeliveryAvailable: Bool {
        HealthKitBridge.hasHealthKitBackgroundDeliveryEntitlement
    }

    private let store = HKHealthStore()
    private let repo: Repository
    /// Profile projection for the newest valid HealthKit body-mass sample. The canonical measurement
    /// remains in the apple-health store; ProfileStore owns freshness/manual-precedence decisions.
    private let profile: ProfileStore
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String
    /// Injected by the iOS app so a newly imported/deleted period-start anchor can refresh the pure
    /// on-device cycle estimate immediately. Nil in previews/tests; no data leaves the process.
    var cycleAnchorsChanged: (() async -> Void)?
    /// Called only after an Apple Health read projection has committed. The app injects a refresh of
    /// the active Repository/device spine so Today, widgets, and watch snapshots cannot remain stale.
    /// Keeping this at the commit boundary covers foreground, manual, and observer-triggered syncs.
    var dataProjectionChanged: (() async -> Void)?
    /// NOOP's on-device COMPUTED daily scores (recovery/HRV/RHR/SpO₂/resp) live under the sibling
    /// `deviceId + "-noop"` id — mirrors `Repository.computedDeviceId` / `IntelligenceEngine.computedId`.
    /// `writeBack` must read this, not the raw import id: a Bluetooth-only WHOOP user has no imported
    /// `noopDeviceId` daily row, so those metrics exist ONLY here.
    private var computedDeviceId: String { noopDeviceId + "-noop" }

    init(repo: Repository, profile: ProfileStore, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.profile = profile
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        bodyCompositionAccessRequested = UserDefaults.standard.bool(
            forKey: HealthKitBridge.bodyCompositionAuthorizationRequestedKey)
        highResolutionWritebackRequested = UserDefaults.standard.bool(
            forKey: HealthKitBridge.highResolutionWritebackAuthorizationRequestedKey)
        // Order matters: a free-signed build with no HealthKit entitlement is dead in the water even
        // where the hardware supports Health, so surface that first. `.unavailable` (no HealthKit at
        // all, e.g. iPad without the framework) still wins where it applies because we only reach the
        // entitlement check when `isHealthDataAvailable()` is true.
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthKitBridge.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for id in HealthKitBridge.quantityReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        // Menstrual flow is intentionally NOT part of this general Apple Health request. It is a
        // separate, sensitive read scope requested only from the explicit Cycle awareness opt-in.
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    /// Slow-changing body measurements are useful but not necessary to compute the first dashboard.
    /// Keep them behind their own in-app explanation and explicit action instead of bundling them into
    /// the initial watch/recovery request.
    private var bodyCompositionReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for id in HealthKitBridge.bodyCompositionReadIds {
            if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        return types
    }

    /// Continuous HR and workout energy/distance are materially higher-volume writes than the small
    /// nightly/sleep/workout core. They are requested only from the dedicated write-back action.
    private var highResolutionWriteTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for id in HealthKitBridge.highResQuantityWriteIds {
            if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        return types
    }

    /// The write set requested by older releases. It includes HRV solely so a returning user's prior
    /// explicit Health connection can be recognized. It is never used for a new request or write:
    /// the legacy `avgHrv` column mixes WHOOP RMSSD with Apple SDNN and therefore cannot safely be
    /// emitted as `heartRateVariabilitySDNN`.
    private var legacyCoreWriteTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.legacyQuantityWriteIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // Every id here ends up in the HealthKit permission dialog. Only request what `sync` actually
    // aggregates into `DayAgg`; adding read scopes the app never consumes makes the consent prompt
    // noisier and surfaces a privacy ask we don't honour.
    private static let quantityReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .appleSleepingWristTemperature,
        .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max
    ]
    private static let bodyCompositionReadIds: [HKQuantityTypeIdentifier] = [
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex
    ]
    // `heartRateVariabilitySDNN` is intentionally absent. Strap/WHOOP `avgHrv` is RMSSD, and the
    // current mixed schema cannot prove a row is SDNN. Reading Apple SDNN remains supported; writing
    // any ambiguous HRV value under Apple's SDNN identifier would silently corrupt Health data.
    private static let quantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .oxygenSaturation, .respiratoryRate
    ]
    private static let legacyQuantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]
    // High-res write-back shares: the continuous 1-minute HR stream, and the energy/distance samples
    // attached to written workouts. Kept out of `quantityWriteIds` so `legacyCoreWriteTypes` (the
    // auth-resume set) stays exactly what pre-update users granted.
    private static let highResQuantityWriteIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling
    ]

    // MARK: - Authorization

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build (no `com.apple.developer.healthkit` entitlement) can NEVER reach Health:
        // `requestAuthorization` either throws "Missing application-identifier"/"missing entitlement"
        // or returns without ever presenting the sheet and leaves every type `.notDetermined`. Either
        // way the honest answer is "this build can't use Apple Health directly", NOT "you denied it" —
        // so never fall through to `.denied` (which tells the user to fix it in Settings, where the app
        // can never appear). Detect via the embedded provisioning profile up front (#348).
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            // The entitlement is present (the guard above proved it via the embedded profile, or there's
            // no profile = App Store build), so a successful request means the bridge is usable. We do
            // NOT reclassify to `.entitlementMissing` off the post-request `.notDetermined` heuristic
            // here: on a genuinely-entitled build the user could grant only reads (writes stay
            // `.notDetermined`) or dismiss the share sheet, and that must stay `.authorized` with the
            // normal Settings guidance — never the file-import reroute. The provisioning-profile check is
            // the authoritative signal; the `.notDetermined` fallback only matters when that check can't
            // run, which on iOS means an App Store build that by definition has the entitlement.
            auth = .authorized
            UserDefaults.standard.set(true, forKey: HealthKitBridge.authorizationRequestedKey)
        } catch {
            // A thrown error here is on a build that carries the entitlement (guarded above), so it's a
            // genuine denial / request failure — keep the normal `.denied` "enable in Settings" path,
            // never the entitlement-missing reroute.
            auth = .denied
        }
        // First successful grant in this process: arm the live HealthKit stream so a watch-only user
        // gets continuous ingestion (new SDNN/RHR/sleep/etc. land within the hour) instead of only on
        // app foreground. Guarded inside enableLiveDelivery on auth == .authorized, so the .denied path
        // above is a no-op.
        enableLiveDelivery()
    }

    /// Stage 2 read consent: body mass, body-fat percentage, lean mass and BMI only. The calling UI
    /// presents a plain-language rationale before invoking this method. A completed HealthKit request
    /// does not prove which read boxes were granted, so the published flag is named `...Requested`.
    func requestBodyCompositionAccess() async {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(
                toShare: Set<HKSampleType>(), read: bodyCompositionReadTypes)
            bodyCompositionAccessRequested = true
            UserDefaults.standard.set(
                true, forKey: HealthKitBridge.bodyCompositionAuthorizationRequestedKey)
            lastError = nil
            enableLiveDelivery()
        } catch {
            lastError = String(localized: "Apple Health body-composition access failed: \(error.localizedDescription)")
        }
    }

    /// Stage 2 write consent: continuous minute HR and workout energy/distance only. Core connection
    /// never asks for these high-volume share types. The write path additionally checks this local
    /// explicit-action marker, so an old broad grant cannot silently turn the feature back on.
    func requestHighResolutionWritebackAccess() async {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(
                toShare: highResolutionWriteTypes, read: Set<HKObjectType>())
            highResolutionWritebackRequested = true
            UserDefaults.standard.set(
                true, forKey: HealthKitBridge.highResolutionWritebackAuthorizationRequestedKey)
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health detailed write-back access failed: \(error.localizedDescription)")
        }
    }

    /// Re-establish observer queries during process launch for a user who previously completed NOOP's
    /// explicit Apple Health action. HealthKit can relaunch a terminated app directly into the
    /// background for observer delivery, before SwiftUI ever reports an `.active` scene. Registering
    /// only from the scene-phase foreground path therefore misses the very wake that should be handled.
    ///
    /// This launch hook is deliberately stricter than `refreshAuthIfPreviouslyGranted`: it accepts only
    /// NOOP's persisted explicit-action marker, never the legacy share-status heuristic, and it never
    /// calls `requestAuthorization`. A fresh install consequently cannot produce a Health permission
    /// sheet (or register sensitive observers) before the in-app rationale.
    func registerObserversAtLaunchIfPreviouslyRequested(defaults: UserDefaults = .standard) {
        guard auth == .unknown,
              defaults.bool(forKey: HealthKitBridge.authorizationRequestedKey),
              HKHealthStore.isHealthDataAvailable(),
              HealthKitBridge.hasHealthKitEntitlement else { return }
        auth = .authorized
        enableLiveDelivery()
    }

    /// Resume a prior grant on launch without re-prompting. `auth` is a fresh `.unknown` every
    /// process (the bridge isn't persisted), so a user who already enabled Apple Health would
    /// otherwise have to re-tap "Enable" each session before the scenePhase sync runs. HealthKit
    /// never reveals *read* status, but *write*/share status is observable — if the user already
    /// authorized all of our write types, treat the bridge as `.authorized`. This only reads
    /// status, so no system permission sheet is shown.
    func refreshAuthIfPreviouslyGranted() {
        // This is status-only and never opens a permission sheet. The cycle observer resumes only if
        // this user previously made the dedicated cycle-health request AND cycle awareness remains on.
        resumeCycleDeliveryIfOptedIn()
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        // A read-only grant is valid, but HealthKit intentionally never reveals read status. Resume
        // once a prior explicit request is known: new installs stamp the local flag; legacy installs
        // are detected when every original share type has reached a decided (allowed OR denied) state.
        let explicitlyRequested = UserDefaults.standard.bool(forKey: HealthKitBridge.authorizationRequestedKey)
        let legacyRequestResolved = legacyCoreWriteTypes.allSatisfy {
            store.authorizationStatus(for: $0) != .notDetermined
        }
        if explicitlyRequested || legacyRequestResolved {
            auth = .authorized
            // A returning user who already granted access should get the live stream re-armed for this
            // process. enableLiveDelivery is idempotent (HealthKit dedups observers + background
            // delivery per type), so calling it here as well as after a fresh requestAuthorization is safe.
            enableLiveDelivery()
            // Never open a Health authorization sheet from launch/resume. New read/share scopes are
            // requested only from the page's explicit Enable / Review access buttons; this method is
            // deliberately status-only even when a newly-added type remains `.notDetermined`.
        }
    }

    // MARK: - Live delivery (continuous ingestion)

    /// Read types with observer + background delivery. Keep this aligned with what `sync(days:)`
    /// actually consumes: a connected watch, scale, or health app should not require the user to open
    /// NOOP before its SpO₂, temperature, steps or workout appears. Optional body-composition types
    /// are appended only after their dedicated consent action. HealthKit still owns scheduling and may
    /// coalesce wakes; the foreground catch-up remains the final safety net.
    private static let liveQuantityIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .appleSleepingWristTemperature,
        .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max
    ]

    /// Long-lived observer queries, retained so HealthKit doesn't tear them down. Keyed by the sample
    /// type's identifier so a second `enableLiveDelivery()` call replaces rather than duplicates.
    private var observerQueries: [String: HKObserverQuery] = [:]

    /// Observer wakes can arrive together for several types. If one aggregate sync is already running,
    /// retain the widest requested window and perform one coalesced follow-up instead of advancing the
    /// other types' anchors and silently dropping their refresh request.
    private var pendingSyncDays: Int?

    /// HealthKit can wake several per-type observers while another read/write pass is suspended. Keep
    /// one durable-delta job per type and drain them through the same serialization gate as foreground
    /// sync. Dropping one here would leave its SQLite anchor unchanged (safe but wasteful) and could
    /// postpone a deletion reconciliation until the next HealthKit wake.
    private var pendingObserverTypes: [String: HKSampleType] = [:]

    /// A strap offload can finish while a HealthKit import owns the gate. Preserve that write-back
    /// request instead of silently dropping it; it is drained after higher-priority HealthKit deltas.
    private var pendingWriteBack = false

    /// Per-sync query health. HealthKit read authorization is intentionally opaque, but an actual query
    /// error is not an empty dataset and must prevent persistence/anchor advancement.
    private var currentReadQueryFailed = false

    /// Local proof that the user explicitly requested the sensitive menstrual-flow read. HealthKit
    /// deliberately does not expose read-authorization status, so this marker is the only honest way
    /// to distinguish an opted-in returning user from a general Apple Health connection.
    private var cycleImportExplicitlyRequested: Bool {
        UserDefaults.standard.bool(forKey: HealthKitBridge.cycleAuthorizationRequestedKey)
    }

    private var cycleImportEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppModel.cycleAwarenessKey)
            && cycleImportExplicitlyRequested
    }

    /// Register one `HKObserverQuery` per scored read type and turn on hourly background delivery, so
    /// new Apple Watch data is ingested continuously. Each observer's update handler runs an anchored
    /// delta sync of just the affected window and then calls HealthKit's completion handler (required —
    /// HealthKit stops delivering to an observer that never acknowledges). Idempotent and guarded behind
    /// `auth == .authorized`; safe to call from several entry points.
    func enableLiveDelivery() {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }

        var types: [HKSampleType] = []
        let liveIds = HealthKitBridge.liveQuantityIds
            + (bodyCompositionAccessRequested ? HealthKitBridge.bodyCompositionReadIds : [])
        for id in liveIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
        types.append(HKObjectType.workoutType())

        for type in types {
            let key = type.identifier
            // Tear down a prior observer for this type before re-registering, so a re-arm (e.g. a
            // returning user hitting both requestAuthorization and refreshAuthIfPreviouslyGranted) can
            // never leave two live observers fighting over the same completion handler.
            if let existing = observerQueries[key] {
                store.stop(existing)
                observerQueries[key] = nil
            }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // HealthKit invokes this on a background queue. Hop to the main actor (the bridge is
                // @MainActor and `sync` mutates published state), run the incremental catch-up, then
                // ALWAYS call completion so HealthKit keeps delivering. We don't tie completion to sync
                // success: a transient store error shouldn't make HealthKit think we never handled the
                // update and back off — the next foreground catch-up will reconcile.
                guard let self else { completion(); return }
                Task { @MainActor in
                    await self.syncFromObserver(type: type)
                    completion()
                }
            }
            store.execute(observer)
            observerQueries[key] = observer

            // Hourly is the finest cadence HealthKit honours for most types and is plenty for daily
            // aggregate scores. Failure here is non-fatal: the foreground catch-up still backfills.
            if HealthKitBridge.hasHealthKitBackgroundDeliveryEntitlement {
                store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
            }
        }
        enableCycleDeliveryIfOptedIn()
    }

    // MARK: - Explicit cycle-health import

    /// Request the single sensitive Apple Health read used by cycle awareness. This method is called
    /// only by the user's Cycle-awareness toggle; it is never part of launch, general Health connect,
    /// or a background task. Declining still leaves manual + temperature-only awareness available.
    func requestCycleDataAccessAndImport() async {
        guard UserDefaults.standard.bool(forKey: AppModel.cycleAwarenessKey),
              HKHealthStore.isHealthDataAvailable() else { return }
        guard HealthKitBridge.hasHealthKitEntitlement else {
            lastError = String(localized: "This build cannot read Apple Health directly. Cycle awareness still works with manual period starts and available temperature data.")
            return
        }
        guard let type = HKObjectType.categoryType(forIdentifier: .menstrualFlow) else { return }
        do {
            try await store.requestAuthorization(toShare: Set<HKSampleType>(),
                                                 read: Set<HKObjectType>([type]))
            UserDefaults.standard.set(true, forKey: HealthKitBridge.cycleAuthorizationRequestedKey)
            enableCycleDeliveryIfOptedIn()
            await syncAppleHealthCycleAnchors()
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health cycle-history access failed: \(error.localizedDescription)")
        }
    }

    /// Stop reading reproductive-health samples and physically purge only the imported anchors when
    /// cycle awareness is turned off. Manual NOOP entries are preserved and HealthKit itself is never
    /// modified; the user can delete or edit the source record in Apple Health.
    func disableCycleDataImport() async {
        UserDefaults.standard.set(false, forKey: HealthKitBridge.cycleAuthorizationRequestedKey)
        if let type = HKObjectType.categoryType(forIdentifier: .menstrualFlow) {
            let key = type.identifier
            if let existing = observerQueries.removeValue(forKey: key) { store.stop(existing) }
            if HealthKitBridge.hasHealthKitBackgroundDeliveryEntitlement {
                try? await store.disableBackgroundDelivery(for: type)
            }
        }
        if await repo.deleteAllAppleHealthPeriodStarts() {
            await cycleAnchorsChanged?()
        } else {
            lastError = String(localized: "Cycle import is off, but NOOP could not finish removing its local Apple Health cycle anchors. It will retry next time the app opens.")
        }
    }

    /// Re-arm without prompting. The dual local gates are essential: general Health permission alone
    /// must never start a menstrual-flow observer, and a prior grant must stop being consumed when the
    /// cycle feature is off.
    private func resumeCycleDeliveryIfOptedIn() {
        guard cycleImportEnabled else { return }
        enableCycleDeliveryIfOptedIn()
    }

    private func enableCycleDeliveryIfOptedIn() {
        guard cycleImportEnabled,
              HKHealthStore.isHealthDataAvailable(),
              HealthKitBridge.hasHealthKitEntitlement,
              let type = HKObjectType.categoryType(forIdentifier: .menstrualFlow) else { return }
        let key = type.identifier
        if let existing = observerQueries.removeValue(forKey: key) { store.stop(existing) }
        let observer = HKObserverQuery(sampleType: type, predicate: Self.notNoopAuthored) {
            [weak self] _, completion, _ in
            guard let self else { completion(); return }
            Task { @MainActor in
                // The reproductive-health record is small. Reconcile the complete set so a HealthKit
                // deletion (whose HKDeletedObject has no timestamp) physically removes the right local
                // imported anchor without ever touching a manual one.
                await self.syncAppleHealthCycleAnchors()
                completion()
            }
        }
        store.execute(observer)
        observerQueries[key] = observer
        if HealthKitBridge.hasHealthKitBackgroundDeliveryEntitlement {
            store.enableBackgroundDelivery(for: type, frequency: .daily) { _, _ in }
        }
    }

    /// Foreground catch-up. Call on app-active so anything background delivery missed (the system can
    /// throttle or skip wakes) is backfilled. A short window is enough because live delivery keeps the
    /// recent days current; 7 covers a weekend of missed wakes. Exposed for the existing scenePhase
    /// hook in `StrandiOSApp` to call — no other file is edited.
    func foregroundCatchUp() async {
        if cycleImportEnabled {
            await syncAppleHealthCycleAnchors()
        } else if await repo.deleteAllAppleHealthPeriodStarts() {
            // Privacy cleanup retry: an explicit turn-off may race data protection / database open.
            // This also clears any stale imported rows for an older cycle preference that has never
            // made the new dedicated Health request. Never touch manual entries.
            await cycleAnchorsChanged?()
        }
        await sync(days: 7)
    }

    /// Drive an incremental sync off an observer wake. The per-type anchor lives in SQLite, beside the
    /// projection it guards. Additions rebuild the exact touched day span. A deletion has only a UUID —
    /// no timestamp — so it triggers a complete re-read of that one type, never a guessed recent window.
    /// Projection replacement and anchor advancement then commit in one store transaction.
    private func syncFromObserver(type: HKSampleType) async {
        guard auth == .authorized else { return }
        if syncing {
            pendingObserverTypes[type.identifier] = type
            return
        }
        syncing = true
        currentReadQueryFailed = false
        defer { finishSerializedSync() }

        guard let whoopStore = await repo.storeHandle(),
              let delta = await fetchTouchedDayWindow(type: type, whoopStore: whoopStore),
              let anchorData = delta.anchorData else { return }

        // A successful empty delta has no projection dependency; advancing only the cursor avoids
        // walking the same empty result again. Changed deltas are committed by the atomic reconcile.
        guard delta.oldestTouched != nil || delta.hasDeletions else {
            do {
                try await whoopStore.commitHealthKitAnchor(
                    sampleType: type.identifier,
                    anchor: anchorData
                )
                UserDefaults.standard.removeObject(forKey: delta.legacyDefaultsKey)
            } catch {
                lastError = String(localized: "Apple Health could not save its sync cursor: \(error.localizedDescription)")
            }
            return
        }

        if await reconcileHealthKitProjection(
            type: type,
            delta: delta,
            anchorData: anchorData,
            whoopStore: whoopStore
        ) {
            // One-time migration from the old UserDefaults cursor. SQLite is now authoritative.
            UserDefaults.standard.removeObject(forKey: delta.legacyDefaultsKey)
            await dataProjectionChanged?()
        }
    }

    private struct ObserverDelta {
        let oldestTouched: Date?
        let newestTouched: Date?
        let hasDeletions: Bool
        let anchorData: Data?
        let legacyDefaultsKey: String
    }

    private struct ObserverPage: Sendable {
        let oldestTouched: Date?
        let newestTouched: Date?
        let deletedCount: Int
        let returnedCount: Int
        let anchorData: Data?
    }

    /// Read this type's delta and stage (but do not persist) its next anchor. A changed delta's anchor is
    /// committed by `syncFromObserver` only after the database/write-back round trip succeeds, so a
    /// disk or HealthKit failure cannot consume unseen work. A query failure returns nil and preserves
    /// the prior cursor.
    private func fetchTouchedDayWindow(type: HKSampleType,
                                       whoopStore: WhoopStore) async -> ObserverDelta? {
        let key = HealthKitBridge.anchorDefaultsKey(for: type)
        let databaseAnchor: Data?
        do {
            databaseAnchor = try await whoopStore.healthKitAnchor(sampleType: type.identifier)
        } catch {
            lastError = String(localized: "Apple Health could not read its sync cursor: \(error.localizedDescription)")
            return nil
        }
        // Migrate an existing installation once. A database cursor always wins because it may have
        // advanced atomically with a full deletion reconciliation after the legacy value was written.
        let priorAnchorData = databaseAnchor ?? UserDefaults.standard.data(forKey: key)
        let priorAnchor: HKQueryAnchor? = {
            guard let data = priorAnchorData else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }()

        let pageSize = 10_000
        let maxPages = 10_000 // 100M changes: corruption guard, not a historical look-back limit.
        var cursor = priorAnchor
        var cursorData = priorAnchorData
        var oldest: Date?
        var newest: Date?
        var hasDeletions = false
        var finalAnchorData: Data?

        for _ in 0..<maxPages {
            guard let page = await fetchObserverPage(
                type: type,
                anchor: cursor,
                limit: pageSize
            ) else { return nil }
            if let candidate = page.oldestTouched {
                oldest = oldest.map { min($0, candidate) } ?? candidate
            }
            if let candidate = page.newestTouched {
                newest = newest.map { max($0, candidate) } ?? candidate
            }
            hasDeletions = hasDeletions || page.deletedCount > 0
            finalAnchorData = page.anchorData ?? finalAnchorData

            guard page.returnedCount >= pageSize, let nextData = page.anchorData else {
                return ObserverDelta(
                    oldestTouched: oldest,
                    newestTouched: newest,
                    hasDeletions: hasDeletions,
                    anchorData: finalAnchorData,
                    legacyDefaultsKey: key
                )
            }
            guard nextData != cursorData else {
                lastError = String(localized: "Apple Health returned a non-advancing sync cursor.")
                return nil
            }
            guard let next = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: nextData
            ) else {
                lastError = String(localized: "Apple Health returned an unreadable sync cursor.")
                return nil
            }
            cursor = next
            cursorData = nextData
        }

        lastError = String(localized: "Apple Health returned too many changes in one update; no cursor was advanced.")
        return nil
    }

    /// Fetch one bounded anchored page and immediately reduce HealthKit objects to Sendable dates/counts.
    /// A multi-year continuous-HR store can contain millions of samples; `HKObjectQueryNoLimit` would
    /// materialize all of them in one callback and invite jetsam during first connection.
    private func fetchObserverPage(type: HKSampleType,
                                   anchor: HKQueryAnchor?,
                                   limit: Int) async -> ObserverPage? {
        await withCheckedContinuation { (cont: CheckedContinuation<ObserverPage?, Never>) in
            let q = HKAnchoredObjectQuery(
                type: type, predicate: Self.notNoopAuthored,
                anchor: anchor, limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                guard error == nil else { cont.resume(returning: nil); return }
                let changed = samples ?? []
                let oldest = changed.map(\.startDate).min()
                let newest = changed.map(\.endDate).max()
                let anchorData = newAnchor.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                let deletedCount = deletedObjects?.count ?? 0
                cont.resume(returning: ObserverPage(
                    oldestTouched: oldest,
                    newestTouched: newest,
                    deletedCount: deletedCount,
                    returnedCount: changed.count + deletedCount,
                    anchorData: anchorData
                ))
            }
            store.execute(q)
        }
    }

    /// UserDefaults key for a type's persisted HealthKit anchor. Namespaced so it can't collide with
    /// other app defaults, and keyed by the stable HK identifier so it survives across launches.
    private static func anchorDefaultsKey(for type: HKSampleType) -> String {
        "hkAnchor.v1.\(type.identifier)"
    }

    /// Release the single HealthKit read/write gate and schedule exactly one queued operation. Each
    /// operation calls this again on completion, so a burst drains without recursion or concurrent
    /// mutation of `currentReadQueryFailed` / published status. Per-type observer deltas come first,
    /// then an explicit foreground catch-up, then a strap-data write-back.
    private func finishSerializedSync() {
        syncing = false
        if let entry = pendingObserverTypes.first {
            pendingObserverTypes[entry.key] = nil
            Task { @MainActor [weak self] in
                await self?.syncFromObserver(type: entry.value)
            }
            return
        }
        if let days = pendingSyncDays {
            pendingSyncDays = nil
            Task { @MainActor [weak self] in
                await self?.sync(days: days)
            }
            return
        }
        if pendingWriteBack {
            pendingWriteBack = false
            Task { @MainActor [weak self] in
                await self?.writeBackAfterNewData()
            }
        }
    }

    /// Stable mapping between a HealthKit observer type and the columns/metric keys NOOP owns for it.
    /// Unknown future types are ignored rather than accidentally clearing a shared projection.
    private static func projectionKind(for type: HKSampleType) -> HealthKitProjectionKind? {
        switch type.identifier {
        case HKQuantityTypeIdentifier.restingHeartRate.rawValue: return .restingHeartRate
        case HKQuantityTypeIdentifier.heartRate.rawValue: return .heartRate
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: return .hrv
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue: return .oxygenSaturation
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue: return .respiratoryRate
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue: return .bodyTemperature
        case HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue: return .wristTemperature
        case HKQuantityTypeIdentifier.stepCount.rawValue: return .steps
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: return .activeEnergy
        case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue: return .basalEnergy
        case HKQuantityTypeIdentifier.vo2Max.rawValue: return .vo2Max
        case HKQuantityTypeIdentifier.bodyMass.rawValue: return .bodyMass
        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: return .bodyFat
        case HKQuantityTypeIdentifier.leanBodyMass.rawValue: return .leanBodyMass
        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue: return .bodyMassIndex
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue: return .sleep
        case HKObjectType.workoutType().identifier: return .workout
        default: return nil
        }
    }

    /// Rebuild one type's exact local projection. For ordinary additions this touches only the days
    /// present in the anchored delta. For any deletion it walks that type's complete HealthKit history,
    /// because `HKDeletedObject` deliberately exposes no date. The store clears/rebuilds only the
    /// columns and metric keys owned by this type and commits the new cursor in the same transaction.
    private func reconcileHealthKitProjection(type: HKSampleType,
                                              delta: ObserverDelta,
                                              anchorData: Data,
                                              whoopStore: WhoopStore) async -> Bool {
        guard let kind = Self.projectionKind(for: type) else { return false }
        let calendar = Calendar.current
        let todayEnd = calendar.date(byAdding: .day, value: 1,
                                     to: calendar.startOfDay(for: Date())) ?? Date()
        let projectionStart: Date
        let projectionEnd: Date
        if delta.hasDeletions {
            // HealthKit did not exist in 1970, so this safely covers every possible sample while
            // retaining a stable, platform-independent lower bound for the SQLite replacement.
            projectionStart = Date(timeIntervalSince1970: 0)
            projectionEnd = todayEnd
        } else if let oldest = delta.oldestTouched {
            projectionStart = calendar.startOfDay(for: oldest)
            let newest = delta.newestTouched ?? oldest
            projectionEnd = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: newest)) ?? todayEnd
        } else {
            return false
        }

        // A sleep record is keyed to its wake day but can start the prior evening. Include one leading
        // day in the query while retaining the exact projection replacement range below.
        let queryStart = kind == .sleep
            ? (calendar.date(byAdding: .day, value: -1, to: projectionStart) ?? projectionStart)
            : projectionStart
        let queryEnd = projectionEnd
        let fromDay = Self.dayString(projectionStart)
        let inclusiveEnd = queryEnd.addingTimeInterval(-1)
        let toDay = Self.dayString(inclusiveEnd)

        var byDay: [String: DayAgg] = [:]
        func agg(_ day: String) -> DayAgg { byDay[day] ?? DayAgg() }

        switch kind {
        case .restingHeartRate:
            await collect(.restingHeartRate,
                          unit: HKUnit.count().unitDivided(by: .minute()),
                          start: queryStart, end: queryEnd, op: .discreteAverage) { day, value in
                var row = agg(day); row.restingHr = value; byDay[day] = row
            }
        case .heartRate:
            let unit = HKUnit.count().unitDivided(by: .minute())
            await collect(.heartRate, unit: unit, start: queryStart, end: queryEnd,
                          op: .discreteAverage) { day, value in
                var row = agg(day); row.avgHr = value; byDay[day] = row
            }
            await collect(.heartRate, unit: unit, start: queryStart, end: queryEnd,
                          op: .discreteMax) { day, value in
                var row = agg(day); row.maxHr = value; byDay[day] = row
            }
        case .hrv:
            await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
                          start: queryStart, end: queryEnd, op: .discreteAverage) { day, value in
                var row = agg(day); row.hrv = value; byDay[day] = row
            }
        case .oxygenSaturation:
            await collect(.oxygenSaturation, unit: .percent(), start: queryStart, end: queryEnd,
                          op: .discreteAverage) { day, value in
                var row = agg(day); row.spo2 = value * 100; byDay[day] = row
            }
        case .respiratoryRate:
            await collect(.respiratoryRate,
                          unit: HKUnit.count().unitDivided(by: .minute()),
                          start: queryStart, end: queryEnd, op: .discreteAverage) { day, value in
                var row = agg(day); row.respRate = value; byDay[day] = row
            }
        case .bodyTemperature:
            await collect(.bodyTemperature, unit: .degreeCelsius(), start: queryStart,
                          end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.bodyTemperatureC = value; byDay[day] = row
            }
        case .wristTemperature:
            await collect(.appleSleepingWristTemperature, unit: .degreeCelsius(),
                          start: queryStart, end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.wristTemperatureC = value; byDay[day] = row
            }
        case .steps:
            await collect(.stepCount, unit: .count(), start: queryStart, end: queryEnd,
                          op: .cumulativeSum) { day, value in
                var row = agg(day); row.steps = value; byDay[day] = row
            }
        case .activeEnergy:
            await collect(.activeEnergyBurned, unit: .kilocalorie(), start: queryStart,
                          end: queryEnd, op: .cumulativeSum) { day, value in
                var row = agg(day); row.activeKcal = value; byDay[day] = row
            }
        case .basalEnergy:
            await collect(.basalEnergyBurned, unit: .kilocalorie(), start: queryStart,
                          end: queryEnd, op: .cumulativeSum) { day, value in
                var row = agg(day); row.basalKcal = value; byDay[day] = row
            }
        case .vo2Max:
            await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: queryStart,
                          end: queryEnd, op: .discreteAverage) { day, value in
                var row = agg(day); row.vo2max = value; byDay[day] = row
            }
        case .bodyMass:
            await collect(.bodyMass, unit: .gramUnit(with: .kilo), start: queryStart,
                          end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.weightKg = value; byDay[day] = row
            }
        case .bodyFat:
            await collect(.bodyFatPercentage, unit: .percent(), start: queryStart,
                          end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.bodyFatPct = value * 100; byDay[day] = row
            }
        case .leanBodyMass:
            await collect(.leanBodyMass, unit: .gramUnit(with: .kilo), start: queryStart,
                          end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.leanMassKg = value; byDay[day] = row
            }
        case .bodyMassIndex:
            await collect(.bodyMassIndex, unit: .count(), start: queryStart,
                          end: queryEnd, op: .mostRecent) { day, value in
                var row = agg(day); row.bmi = value; byDay[day] = row
            }
        case .sleep:
            await collectSleep(start: queryStart, end: queryEnd) {
                day, asleep, deep, rem, core, awake, inBed in
                var row = agg(day)
                row.asleepMin = asleep; row.deepMin = deep; row.remMin = rem; row.coreMin = core
                row.awakeMin = awake; row.inBedMin = inBed
                byDay[day] = row
            }
        case .workout:
            break
        }
        guard !currentReadQueryFailed else {
            lastError = String(localized: "Apple Health reconciliation failed while reading \(type.identifier). Nothing was updated.")
            return false
        }

        let appleRows = byDay.map { day, row in
            AppleDaily(
                day: day,
                steps: row.steps.map { Int($0.rounded()) },
                activeKcal: row.activeKcal,
                basalKcal: row.basalKcal,
                vo2max: row.vo2max,
                avgHr: row.avgHr.map { Int($0.rounded()) },
                maxHr: row.maxHr.map { Int($0.rounded()) },
                walkingHr: nil,
                weightKg: row.weightKg
            )
        }
        let dailyRows = byDay.map { day, row in
            DailyMetric(
                day: day,
                totalSleepMin: row.asleepMin,
                efficiency: nil,
                deepMin: row.deepMin,
                remMin: row.remMin,
                lightMin: row.coreMin,
                disturbances: nil,
                restingHr: row.restingHr.map { Int($0.rounded()) },
                avgHrv: row.hrv,
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                spo2Pct: row.spo2,
                skinTempDevC: nil,
                respRateBpm: row.respRate,
                steps: row.steps.map { Int($0.rounded()) }
            )
        }
        let aggregates = byDay.map { day, row in
            AppleDailyAggregate(
                day: day,
                restingHr: row.restingHr,
                hrvSDNN: row.hrv,
                spo2Pct: row.spo2,
                respRate: row.respRate,
                avgHr: row.avgHr,
                maxHr: row.maxHr,
                steps: row.steps,
                activeKcal: row.activeKcal,
                basalKcal: row.basalKcal,
                vo2max: row.vo2max,
                weightKg: row.weightKg,
                bodyFatPct: row.bodyFatPct,
                leanMassKg: row.leanMassKg,
                bmi: row.bmi,
                bodyTemperatureC: row.bodyTemperatureC,
                wristTemperatureC: row.wristTemperatureC,
                asleepMin: row.asleepMin,
                deepMin: row.deepMin,
                remMin: row.remMin,
                coreMin: row.coreMin,
                awakeMin: row.awakeMin,
                inBedMin: row.inBedMin
            )
        }
        let points = AppleHealthAggregator.metricPoints(aggregates).map {
            MetricPoint(day: $0.day, key: $0.key, value: $0.value)
        }

        var workoutRows: [WorkoutRow] = []
        if kind == .workout {
            do {
                let existing = try await whoopStore.workouts(
                    deviceId: appleDeviceId,
                    from: Int(projectionStart.timeIntervalSince1970),
                    to: Int(queryEnd.timeIntervalSince1970),
                    limit: 100_000
                )
                let daily = try await whoopStore.dailyMetrics(
                    deviceId: appleDeviceId,
                    from: fromDay,
                    to: toDay
                )
                let resting = Dictionary(
                    daily.compactMap { row in row.restingHr.map { (row.day, Double($0)) } },
                    uniquingKeysWith: { _, newer in newer }
                )
                let fresh = try await collectWorkouts(
                    start: projectionStart,
                    end: queryEnd,
                    restingHRByDay: resting
                )
                workoutRows = Self.mergeAppleWorkoutRows(fresh: fresh, existing: existing)
            } catch {
                lastError = String(localized: "Apple Health workout reconciliation failed: \(error.localizedDescription)")
                return false
            }
        }

        let reconciledWeight: BodyMassReading?
        if kind == .bodyMass {
            reconciledWeight = await newestBodyMassReading()
            guard !currentReadQueryFailed else {
                lastError = String(localized: "Apple Health body-mass reconciliation failed while finding the newest remaining measurement.")
                return false
            }
        } else {
            reconciledWeight = nil
        }

        do {
            try await whoopStore.reconcileHealthKitProjection(
                kind: kind,
                sampleType: type.identifier,
                anchor: anchorData,
                deviceId: appleDeviceId,
                fromDay: fromDay,
                toDay: toDay,
                fromTs: Int(projectionStart.timeIntervalSince1970),
                toTs: Int(queryEnd.timeIntervalSince1970),
                appleRows: appleRows,
                dailyRows: dailyRows,
                metricPoints: points,
                workouts: workoutRows
            )
            if kind == .bodyMass, let newestWeight = reconciledWeight {
                profile.reconcileExternalWeight(
                    weightKg: newestWeight.kg,
                    measuredAt: newestWeight.measuredAt,
                    source: newestWeight.source
                )
            } else if kind == .bodyMass {
                profile.reconcileExternalWeight(weightKg: nil, measuredAt: nil, source: "apple-health")
            }
            lastSync = Date()
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "Apple Health could not save its reconciled data: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Read → store

    /// Pull the last `days` of Apple Health into the on-device store under the `apple-health` source,
    /// then write NOOP's own computed metrics back into Health. Safe to call repeatedly (idempotent
    /// upserts keyed by day).
    @discardableResult
    func sync(days: Int = 30) async -> Bool {
        guard auth == .authorized else { return false }
        let requestedDays = max(1, days)
        if syncing {
            pendingSyncDays = max(pendingSyncDays ?? 0, requestedDays)
            return false
        }
        syncing = true
        currentReadQueryFailed = false
        defer { finishSerializedSync() }
        guard let store = await repo.storeHandle() else { return false }

        let cal = Calendar.current
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -requestedDays,
                                   to: cal.startOfDay(for: end)) else { return false }

        var byDay: [String: DayAgg] = [:]
        func agg(_ day: String) -> DayAgg { byDay[day] ?? DayAgg() }

        // Quantity aggregates per day.
        await collect(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.restingHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.avgHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteMax) { day, v in
            var a = agg(day); a.maxHr = v; byDay[day] = a
        }
        await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.hrv = v; byDay[day] = a
        }
        await collect(.oxygenSaturation, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.spo2 = v * 100; byDay[day] = a   // 0…1 → percent
        }
        await collect(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.respRate = v; byDay[day] = a
        }
        await collect(.bodyTemperature, unit: .degreeCelsius(), start: start, end: end, op: .mostRecent) { day, v in
            var a = agg(day); a.bodyTemperatureC = v; byDay[day] = a
        }
        await collect(.appleSleepingWristTemperature, unit: .degreeCelsius(), start: start, end: end, op: .mostRecent) { day, v in
            var a = agg(day); a.wristTemperatureC = v; byDay[day] = a
        }
        await collect(.stepCount, unit: .count(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.steps = v; byDay[day] = a
        }
        await collect(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.activeKcal = v; byDay[day] = a
        }
        await collect(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.basalKcal = v; byDay[day] = a
        }
        await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.vo2max = v; byDay[day] = a
        }

        // Body composition is a separate, optional consent stage. Do not even query these types until
        // the user taps the dedicated action; permission denial is intentionally indistinguishable
        // from no samples, but the local action marker makes NOOP's own access boundary unambiguous.
        if bodyCompositionAccessRequested {
            await collect(.bodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .mostRecent) { day, v in
                var a = agg(day); a.weightKg = v; byDay[day] = a
            }
            await collect(.bodyFatPercentage, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
                var a = agg(day); a.bodyFatPct = v * 100; byDay[day] = a   // 0…1 → percent
            }
            await collect(.leanBodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .mostRecent) { day, v in
                var a = agg(day); a.leanMassKg = v; byDay[day] = a
            }
            await collect(.bodyMassIndex, unit: .count(), start: start, end: end, op: .mostRecent) { day, v in
                var a = agg(day); a.bmi = v; byDay[day] = a
            }
        }

        // Sleep minutes per day (asleep stages summed; attributed to wake day).
        await collectSleep(start: start, end: end) {
            day, asleepMin, deepMin, remMin, coreMin, awakeMin, inBedMin in
            var a = agg(day)
            a.asleepMin = asleepMin; a.deepMin = deepMin; a.remMin = remMin; a.coreMin = coreMin
            a.awakeMin = awakeMin; a.inBedMin = inBedMin
            byDay[day] = a
        }
        guard !currentReadQueryFailed else {
            lastError = String(localized: "Apple Health sync failed while reading authorized data. Nothing was updated; try again.")
            return false
        }

        // Build + upsert the store rows under the apple-health source.
        var appleRows = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.map { Int($0) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.map { Int($0.rounded()) }, maxHr: a.maxHr.map { Int($0.rounded()) },
                       walkingHr: nil, weightKg: a.weightKg)
        }
        // `upsertAppleDaily` replaces nullable columns. Preserve a previously imported weight when
        // this staged sync did not request body composition (or HealthKit returned no visible sample),
        // otherwise connecting only the core scopes would silently erase historical scale data.
        do {
            let existingAppleRows = try await store.appleDaily(
                deviceId: appleDeviceId,
                from: HealthKitBridge.dayString(start),
                to: HealthKitBridge.dayString(end)
            )
            let existingWeightByDay = Dictionary(
                existingAppleRows.compactMap { row in row.weightKg.map { (row.day, $0) } },
                uniquingKeysWith: { _, newer in newer }
            )
            appleRows = appleRows.map { row in
                guard row.weightKg == nil, let existing = existingWeightByDay[row.day] else {
                    return row
                }
                return AppleDaily(
                    day: row.day, steps: row.steps, activeKcal: row.activeKcal,
                    basalKcal: row.basalKcal, vo2max: row.vo2max, avgHr: row.avgHr,
                    maxHr: row.maxHr, walkingHr: row.walkingHr, weightKg: existing
                )
            }
        } catch {
            lastError = String(localized: "Apple Health sync failed while preserving existing body measurements: \(error.localizedDescription)")
            return false
        }
        let dmRows = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.map { Int($0.rounded()) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate,
                        steps: a.steps.map { Int($0.rounded()) })
        }
        // Flatten to the generic metricSeries the shared Apple Health screen, the Today apple-health
        // sparklines, and the Metric Explorer read from — repo.series(key:source:"apple-health")
        // queries ONLY metricSeries, so without this every tile/chart renders "—" after a successful
        // sync. Reuse the importer's canonical key mapping so the keys match the macOS path exactly.
        // Once its separate consent stage has been requested, body composition
        // (weight/body_fat/lean_mass/bmi) flows through the same metricPoints keys as the file
        // importer. iOS still doesn't collect awake/in-bed minutes, so those stay nil and emit no
        // points — correct.
        let aggregates = byDay.map { (day, a) in
            AppleDailyAggregate(
                day: day,
                restingHr: a.restingHr,
                hrvSDNN: a.hrv,
                spo2Pct: a.spo2,
                respRate: a.respRate,
                avgHr: a.avgHr,
                maxHr: a.maxHr,
                steps: a.steps,
                activeKcal: a.activeKcal,
                basalKcal: a.basalKcal,
                vo2max: a.vo2max,
                weightKg: a.weightKg,
                bodyFatPct: a.bodyFatPct,
                leanMassKg: a.leanMassKg,
                bmi: a.bmi,
                bodyTemperatureC: a.bodyTemperatureC,
                wristTemperatureC: a.wristTemperatureC,
                asleepMin: a.asleepMin,
                deepMin: a.deepMin,
                remMin: a.remMin,
                coreMin: a.coreMin,
                awakeMin: a.awakeMin,
                inBedMin: a.inBedMin
            )
        }
        let points = AppleHealthAggregator.metricPoints(aggregates)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }

        // Workouts the user logged in Apple Health (Apple Watch rings, gym apps, etc.). macOS already
        // imports these from a static Health export and Android reads them from Health Connect; iOS now
        // reads them live on-device too, so the platforms reach parity. ON-DEVICE ONLY: this is a plain
        // HealthKit read of workouts NOOP did NOT author, never any cloud/3rd-party API. (#835)
        // HealthKit does not reveal whether a read returned no samples because none exist or because
        // the user later withheld that particular read scope. Keep the prior nullable enrichment in
        // the latter case instead of turning an already-imported workout back into a row of dashes.
        // A store read failure aborts the sync before any write, preserving the same all-or-nothing
        // advancement rule used below.
        let existingWorkoutRows: [WorkoutRow]
        do {
            existingWorkoutRows = try await store.workouts(
                deviceId: appleDeviceId,
                from: Int(start.timeIntervalSince1970),
                to: Int(end.timeIntervalSince1970),
                limit: 50_000
            )
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
            return false
        }
        let restingHRByDay = byDay.compactMapValues(\.restingHr)
        let freshWorkoutRows: [WorkoutRow]
        do {
            freshWorkoutRows = try await collectWorkouts(
                start: start,
                end: end,
                restingHRByDay: restingHRByDay
            )
        } catch {
            // A partial workout/HR query is not a successful sync. In particular, do not advance
            // lastSync or an observer anchor after HealthKit reports an error.
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
            return false
        }
        let workoutRows = Self.mergeAppleWorkoutRows(
            fresh: freshWorkoutRows,
            existing: existingWorkoutRows
        )
        // Query an exact weight sample only after the separate body-composition action. The profile API
        // independently rejects invalid, stale, future, or manual-overridden values.
        var newestWeight: BodyMassReading?
        if bodyCompositionAccessRequested {
            newestWeight = await newestBodyMassReading()
            guard !currentReadQueryFailed else {
                lastError = String(localized: "Apple Health sync failed while reading body mass. Nothing was updated; try again.")
                return false
            }
        }

        // Persist all the apple-health rows AND write back, advancing lastSync only when the WHOLE
        // round-trip succeeds. The three read-side upserts used to be swallowed by `try?`, so a failed
        // import (e.g. a disk-full GRDB write) dropped rows yet still cleared lastError and advanced
        // lastSync — a false "success", and the next delta sync skipped the window. (Reimplemented
        // from @vulnix0x4's PR #375.)
        do {
            try await store.upsertAppleDaily(appleRows, deviceId: appleDeviceId)
            try await store.upsertDailyMetrics(dmRows, deviceId: appleDeviceId)
            try await store.upsertMetricSeries(points, deviceId: appleDeviceId)
            if !workoutRows.isEmpty { try await store.upsertWorkouts(workoutRows, deviceId: appleDeviceId) }
            if let newestWeight {
                profile.acceptExternalWeight(weightKg: newestWeight.kg,
                                             measuredAt: newestWeight.measuredAt,
                                             source: newestWeight.source)
            }
            // The read-side transaction is durable now. Refresh immediately even when the optional
            // NOOP-to-Health write-back later fails; a write permission or quota error must not hide
            // health data that was already imported successfully.
            await dataProjectionChanged?()
            try await writeBack(whoopStore: store)
            lastSync = Date()
            lastError = nil
            return true
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Write newly landed strap data without re-reading HealthKit. This is called after a completed
    /// background offload, uses the same serialization guard as a full sync, never prompts in the
    /// background, and deliberately leaves `lastSync` (the last two-way read) unchanged.
    func writeBackAfterNewData() async {
        refreshAuthIfPreviouslyGranted()
        guard auth == .authorized else { return }
        if syncing {
            pendingWriteBack = true
            return
        }
        syncing = true
        defer { finishSerializedSync() }
        guard let whoopStore = await repo.storeHandle() else { return }
        do {
            try await writeBack(whoopStore: whoopStore)
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived data into Apple Health: sleep sessions with full stage segments,
    /// strap/manual workouts, and compatible nightly vitals (resting HR, SpO₂, respiratory rate)
    /// stamped at that day's wake time. Continuous 1-minute HR and workout energy/distance require
    /// the separate detailed-write action. HRV is read-only until the store distinguishes RMSSD from
    /// SDNN; writing an ambiguous `avgHrv` as Apple's SDNN would be semantic corruption.
    ///
    /// Each feature saves independently and guards on ITS OWN type's share status, so one declined
    /// Health checkbox (or a save error) skips that feature without sinking the rest; the first error
    /// is rethrown at the end so `sync` still surfaces it in `lastError` without advancing `lastSync`.
    ///
    /// Dedup model (vitals): each emitted sample carries a deterministic `HKMetadataKeyExternalUUID`
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`.
    ///
    /// Throws on save failure so the caller can decide whether to advance `lastSync`.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard auth == .authorized else { return }
        let now = Date()
        guard let fromDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let fromTs = Int(fromDate.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        // Sleep sessions drive both the sleep write and the vitals' wake-time stamps: computed
        // sessions (deviceId + "-noop") first, imported rows override on startTs collision — the
        // same source precedence as the dailies union below and IntelligenceEngine's sleep reads.
        let computedSleeps = try await whoopStore.sleepSessions(
            deviceId: computedDeviceId, from: fromTs, to: nowTs, limit: 200)
        let importedSleeps = try await whoopStore.sleepSessions(
            deviceId: noopDeviceId, from: fromTs, to: nowTs, limit: 200)
        var sleepsByStart: [Int: CachedSleepSession] = [:]
        for s in computedSleeps { sleepsByStart[s.startTs] = s }
        for s in importedSleeps { sleepsByStart[s.startTs] = s }
        let sessions = sleepsByStart.keys.sorted().map { sleepsByStart[$0]! }

        var firstError: Error?
        func attempt(_ op: () async throws -> Void) async {
            do { try await op() } catch { if firstError == nil { firstError = error } }
        }
        await attempt { try await writeVitals(whoopStore: whoopStore, days: days, sessions: sessions) }
        await attempt { try await writeSleep(sessions: sessions) }
        if highResolutionWritebackRequested {
            await attempt { try await writeHeartRate(whoopStore: whoopStore, fromTs: fromTs, nowTs: nowTs) }
        }
        await attempt { try await writeWorkouts(whoopStore: whoopStore, fromTs: fromTs, toTs: nowTs) }
        if let firstError { throw firstError }
    }

    /// The nightly vitals write (the original write-back), now stamped at the day's wake time when
    /// that day has a sleep session — a real timestamp inside the night the value describes, instead
    /// of a fabricated noon. Keys are unchanged, so re-stamped samples replace their noon ancestors.
    private func writeVitals(whoopStore: WhoopStore, days: Int, sessions: [CachedSleepSession]) async throws {
        // Releases before the RMSSD/SDNN safety fix could write strap RMSSD under HealthKit's SDNN
        // identifier. Remove every sample authored by this app for that type once; `HKSource.default()`
        // scopes deletion to NOOP, never Apple Watch or another app. If Health access is unavailable,
        // leave the marker unset and retry after the user restores permission.
        try await removeLegacyMislabelledHrvIfPossible()

        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
        let from = HealthKitBridge.dayString(fromDate)

        // day (of wake) → wake instant. Ascending session order means the latest wake of a day wins,
        // matching collectSleep's end-date day attribution.
        var wakeByDay: [String: Date] = [:]
        for s in sessions where s.endTs > s.effectiveStartTs {
            let wake = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            wakeByDay[HealthKitBridge.dayString(wake)] = wake
        }
        // Read NOOP's COMPUTED dailies (deviceId + "-noop"), which is the only place a strap-only
        // user's recovery/HRV/RHR/SpO₂/resp lives, then union with any imported `noopDeviceId` rows so
        // a user who ALSO imported a WHOOP export still gets the imported values. Imported overrides
        // computed per day, matching the dashboard's source precedence.
        let computed = try await whoopStore.dailyMetrics(
            deviceId: computedDeviceId, from: from, to: to)
        let imported = try await whoopStore.dailyMetrics(
            deviceId: noopDeviceId, from: from, to: to)
        var byDay: [String: DailyMetric] = [:]
        for r in computed { byDay[r.day] = r }   // computed first
        for r in imported { byDay[r.day] = r }   // imported overrides
        let rows = byDay.keys.sorted().map { byDay[$0]! }

        struct Candidate { let type: HKQuantityType; let key: String; let sample: HKQuantitySample }
        var candidates: [Candidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String, _ at: Date) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { return }
            let key = "noop:\(noopDeviceId):\(id.rawValue):\(day)"
            let sample = HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: value),
                start: at, end: at,
                metadata: [HKMetadataKeyExternalUUID: key]
            )
            candidates.append(Candidate(type: type, key: key, sample: sample))
        }

        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let at = wakeByDay[row.day] ?? noon
            if let rhr = row.restingHr {
                add(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), Double(rhr), row.day, at)
            }
            if let spo2 = row.spo2Pct {
                add(.oxygenSaturation, .percent(), spo2 / 100, row.day, at)
            }
            if let rr = row.respRateBpm {
                add(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), rr, row.day, at)
            }
        }
        guard !candidates.isEmpty else { return }

        // Delete any of OUR prior samples that carry the same metadata keys, then write the fresh
        // batch. Scoped to HKSource.default() so we never touch a sample written by another app
        // that happens to use the same external UUID. Delete failures are non-fatal (e.g., nothing
        // to delete on first run) — only the save throws.
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let grouped = Dictionary(grouping: candidates, by: { $0.type })
        for (type, items) in grouped {
            let keys = Array(Set(items.map { $0.key }))
            let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                    allowedValues: keys)
            let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            _ = try? await self.store.deleteObjects(of: type, predicate: pred)
        }
        try await self.store.save(candidates.map { $0.sample })
    }

    /// One-time cleanup for the old mixed-unit HRV write. There is deliberately no replacement write:
    /// `DailyMetric.avgHrv` can be WHOOP RMSSD or imported Apple SDNN, and provenance alone does not
    /// establish the mathematical statistic. A future typed schema can re-enable only proven SDNN.
    private func removeLegacyMislabelledHrvIfPossible() async throws {
        guard !UserDefaults.standard.bool(
            forKey: HealthKitBridge.mislabelledHrvCleanupCompletedKey),
              let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let authoredByNoop = HKQuery.predicateForObjects(from: HKSource.default())
        _ = try await store.deleteObjects(of: type, predicate: authoredByNoop)
        UserDefaults.standard.set(
            true, forKey: HealthKitBridge.mislabelledHrvCleanupCompletedKey)
    }

    /// Write each BRIDGED NIGHT (#364) as one `.inBed` sample plus one category sample per stage
    /// segment (`deep → .asleepDeep`, `rem → .asleepREM`, `light → .asleepCore`, `wake → .awake`) —
    /// the same shape Oura and Apple Watch write, so Health renders the full hypnogram. A night the
    /// detector split on a brief mid-night wake exports as ONE entry whose gap is an explicit
    /// `.awake` segment (grouped by `SleepStageTotals.bridgedNightGroups`, the SAME bridge the daily
    /// totals score with, #561); naps never bridge and stay their own entries. Fragments whose
    /// `stagesJSON` carries no timing (the legacy aggregate-minutes shapes) get one honest
    /// `.asleepUnspecified` block instead of fabricated stage placement.
    ///
    /// Dedup: every sample of a night carries `HKMetadataKeyExternalUUID =
    /// noop:<deviceId>:sleep:<startTs>` keyed by the group's EARLIEST fragment's immutable detected
    /// onset (a user edit moves the span, never the key). The delete predicate carries EVERY
    /// fragment's key, so a night previously written as two entries fully clears when it becomes
    /// one; delete-then-write scoped to our own `HKSource`, like the vitals.
    private func writeSleep(sessions: [CachedSleepSession]) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: TimeZone.current.secondsFromGMT())
            .map { g in
                g.indices.map { i -> HealthWriteback.SleepFragment in
                    let s = sessions[i]
                    return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                                 endTs: s.endTs, stagesJSON: s.stagesJSON)
                }
            }
        var samples: [HKCategorySample] = []
        var keys: [String] = []
        for entry in HealthWriteback.mergedSleepPlan(groups: groups) {
            let key = "noop:\(noopDeviceId):sleep:\(entry.keyStartTs)"
            let meta = [HKMetadataKeyExternalUUID: key]
            keys.append(contentsOf: entry.allKeyStartTs.map { "noop:\(noopDeviceId):sleep:\($0)" })
            samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                                            end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                                            metadata: meta))
            for seg in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch seg.kind {
                case .awake:       value = .awake
                case .light:       value = .asleepCore
                case .deep:        value = .asleepDeep
                case .rem:         value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type, value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(seg.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(seg.end)),
                    metadata: meta))
            }
        }
        guard !samples.isEmpty else { return }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
    }

    /// UserDefaults key for the HR write cursor (the newest bucket ts we've written). Per-strap so a
    /// device switch restarts the backfill for the new strap instead of resuming mid-stream.
    private var hrWriteCursorKey: String { "hkHRWriteCursor.v1.\(noopDeviceId)" }

    /// Write the strap's continuous heart rate as 1-minute mean samples — the same `hrBuckets` SQL
    /// the charts read (measured-first, PPG fallback), so Health sees exactly what NOOP plots. Raw
    /// ~1 Hz is deliberately downsampled: a fully-worn day is ~86k samples, which bloats the Health
    /// store; 1/min matches Apple Watch's background cadence.
    ///
    /// Dedup: forward-only cursor plus a 48 h rewrite window. Each run deletes OUR OWN prior HR
    /// samples in `[windowStart, now]` (source-scoped, date-range predicate — far cheaper than per-
    /// sample external-UUID keys at this volume) and rewrites the window, so a strap offload that
    /// backfills a recent night reconciles. Offloads older than 48 h behind the cursor are missed
    /// until the cursor is cleared — accepted trade-off for not re-walking 14 days every sync.
    private func writeHeartRate(whoopStore: WhoopStore, fromTs: Int, nowTs: Int) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let cursor = UserDefaults.standard.integer(forKey: hrWriteCursorKey)
        let windowStart = cursor > 0 ? max(fromTs, cursor - 48 * 3600) : fromTs
        let buckets = try await whoopStore.hrBuckets(deviceId: noopDeviceId, from: windowStart,
                                                     to: nowTs, bucketSeconds: 60)
        guard !buckets.isEmpty else { return }

        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
                                        end: Date(timeIntervalSince1970: TimeInterval(nowTs) + 60),
                                        options: []),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)

        let unit = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKQuantitySample] = []
        samples.reserveCapacity(buckets.count)
        for b in buckets {
            let start = Date(timeIntervalSince1970: TimeInterval(b.ts))
            // Span the bucket, clamped so a bucket at the window edge can't end in the future
            // (HealthKit rejects future-dated samples).
            let end = Date(timeIntervalSince1970: TimeInterval(min(b.ts + 60, nowTs)))
            samples.append(HKQuantitySample(type: type,
                                            quantity: .init(unit: unit, doubleValue: b.bpm),
                                            start: start, end: max(start, end)))
        }
        // First run backfills ~20k samples (14 d × 1440/day); chunk the saves so no single HealthKit
        // transaction is oversized. Cursor only advances past what actually saved.
        var lastSaved = cursor
        var pending = samples[...]
        var pendingTs = buckets.map(\.ts)[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(5000))
            let chunkTs = Array(pendingTs.prefix(5000))
            pending = pending.dropFirst(chunk.count)
            pendingTs = pendingTs.dropFirst(chunk.count)
            try await store.save(chunk)
            lastSaved = max(lastSaved, chunkTs.last ?? lastSaved)
            UserDefaults.standard.set(lastSaved, forKey: hrWriteCursorKey)
        }
    }

    /// Write strap-detected and manual workouts into Health via `HKWorkoutBuilder`, with an
    /// `activeEnergyBurned` sample when the row has energy and a distance sample for distance
    /// sports. Workouts whose source is `apple-health` are EXCLUDED — those were imported FROM
    /// Health, and writing them back would duplicate the user's own Apple Watch/gym-app workouts.
    ///
    /// Dedup: `HKMetadataKeyExternalUUID = noop:<deviceId>:workout:<startTs>` in the workout
    /// metadata; delete-then-write scoped to our own source, like sleep and the vitals.
    private func writeWorkouts(whoopStore: WhoopStore, fromTs: Int, toTs: Int) async throws {
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let mine = try await whoopStore.workouts(
            deviceId: noopDeviceId, from: fromTs, to: toTs, limit: 500)
        let computed = try await whoopStore.workouts(
            deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 500)
        var byKey: [String: WorkoutRow] = [:]
        for w in computed + mine where w.source != HealthKitBridge.appleWorkoutSource {
            byKey["\(w.startTs):\(w.sport)"] = w
        }
        let rows = byKey.values.sorted { $0.startTs < $1.startTs }
        guard !rows.isEmpty else { return }

        func key(_ row: WorkoutRow) -> String { "noop:\(noopDeviceId):workout:\(row.startTs)" }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                        allowedValues: rows.map(key)),
        ])
        _ = try? await store.deleteObjects(of: .workoutType(), predicate: pred)

        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
            guard end > start else { continue }
            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(forSport: row.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.addMetadata([HKMetadataKeyExternalUUID: key(row)])
                var extras: [HKSample] = []
                if highResolutionWritebackRequested,
                   let kcal = row.energyKcal, kcal > 0,
                   let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end))
                }
                if highResolutionWritebackRequested,
                   let meters = row.distanceM, meters > 0,
                   let id = Self.distanceTypeId(forSport: row.sport),
                   let t = HKQuantityType.quantityType(forIdentifier: id),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end))
                }
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
    }

    /// Reverse of `sportName`: NOOP's sport label → the `HKWorkoutActivityType` written to Health.
    /// Labels the forward map collapses (e.g. boxing/kickboxing → "Boxing") reverse to the first
    /// member; unknown labels fall back to `.other`, never dropped.
    private static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        if sport == LiftingImporter.sport { return .traditionalStrengthTraining }
        switch sport.lowercased() {
        case "running":       return .running
        case "walking":       return .walking
        case "hiking":        return .hiking
        case "cycling":       return .cycling
        case "hiit":          return .highIntensityIntervalTraining
        case "core training": return .coreTraining
        case "yoga":          return .yoga
        case "pilates":       return .pilates
        case "rowing":        return .rowing
        case "elliptical":    return .elliptical
        case "stairs":        return .stairClimbing
        case "jump rope":     return .jumpRope
        case "boxing":        return .boxing
        case "basketball":    return .basketball
        case "soccer":        return .soccer
        case "football":      return .americanFootball
        case "baseball":      return .baseball
        case "badminton":     return .badminton
        case "tennis":        return .tennis
        case "table tennis":  return .tableTennis
        case "volleyball":    return .volleyball
        case "squash":        return .squash
        case "martial arts":  return .martialArts
        case "dancing":       return .socialDance
        case "golf":          return .golf
        case "climbing":      return .climbing
        case "skiing":        return .downhillSkiing
        case "snowboarding":  return .snowboarding
        case "swimming":      return .swimming
        case "surfing":       return .surfingSports
        case "paddling":      return .paddleSports
        default:              return .other
        }
    }

    /// Which distance quantity a sport's `distanceM` maps to; nil for sports whose Health distance
    /// type NOOP doesn't request share access for (e.g. swimming).
    private static func distanceTypeId(forSport sport: String) -> HKQuantityTypeIdentifier? {
        switch sport.lowercased() {
        case "running", "walking", "hiking": return .distanceWalkingRunning
        case "cycling":                      return .distanceCycling
        default:                             return nil
        }
    }

    private struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var weightKg: Double?; var bodyFatPct: Double?; var leanMassKg: Double?; var bmi: Double?
        var bodyTemperatureC: Double?; var wristTemperatureC: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
        var awakeMin: Double?; var inBedMin: Double?
    }

    private struct BodyMassReading {
        let kg: Double
        let measuredAt: Date
        let source: String
    }

    /// Newest point-in-time body-mass reading across Apple Health history. Unlike the daily statistic
    /// used for charts, this preserves the sample's exact timestamp and source bundle for ProfileStore's
    /// provenance/freshness policy. NOOP-authored samples are excluded by the common predicate.
    private func newestBodyMassReading() async -> BodyMassReading? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<BodyMassReading?, Error>, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: Self.notNoopAuthored,
                                      limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(returning: .failure(error)); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    cont.resume(returning: .success(nil))
                    return
                }
                let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                guard kg.isFinite else {
                    cont.resume(returning: .success(nil))
                    return
                }
                let source = sample.sourceRevision.source
                let origin = source.bundleIdentifier.isEmpty ? source.name : source.bundleIdentifier
                cont.resume(returning: .success(BodyMassReading(
                    kg: kg,
                    measuredAt: sample.endDate,
                    source: "apple-health:\(origin)"
                )))
            }
            store.execute(query)
        }
        switch result {
        case let .success(reading): return reading
        case .failure:
            currentReadQueryFailed = true
            return nil
        }
    }

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own
    /// output back in as "apple-health" data — which would make the strap and "Apple Health" plot the
    /// same line for a strap-only user, and bias the apple-health average for someone who also has a
    /// watch. `HKSource.default()` is this app's own source. (Reimplemented from @vulnix0x4's PR #375.)
    private static var notNoopAuthored: NSPredicate {
        NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
    }

    private func collect(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                         op: HKStatisticsOptions, sink: @escaping (String, Double) -> Void) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: op, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                guard error == nil else { cont.resume(returning: false); return }
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q: HKQuantity?
                    switch op {
                    case .cumulativeSum:     q = stats.sumQuantity()
                    case .discreteAverage:   q = stats.averageQuantity()
                    case .discreteMax:       q = stats.maximumQuantity()
                    case .mostRecent: q = stats.mostRecentQuantity()
                    default:                 q = stats.averageQuantity()
                    }
                    if let q { sink(HealthKitBridge.dayString(stats.startDate), q.doubleValue(for: unit)) }
                }
                cont.resume(returning: true)
            }
            store.execute(q)
        }
        if !succeeded { currentReadQueryFailed = true }
    }

    private func collectSleep(
        start: Date,
        end: Date,
        sink: @escaping (String, Double?, Double?, Double?, Double?, Double?, Double?) -> Void
    ) async {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            Self.notNoopAuthored,
        ])
        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                guard error == nil else { cont.resume(returning: false); return }
                var asleep: [String: Double] = [:], deep: [String: Double] = [:]
                var rem: [String: Double] = [:], core: [String: Double] = [:]
                var awake: [String: Double] = [:], inBed: [String: Double] = [:]
                for case let s as HKCategorySample in samples ?? [] {
                    let mins = s.endDate.timeIntervalSince(s.startDate) / 60
                    let day = HealthKitBridge.dayString(s.endDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        core[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.awake.rawValue:
                        awake[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.inBed.rawValue:
                        inBed[day, default: 0] += mins
                    default:
                        break
                    }
                }
                let days = Set(asleep.keys)
                    .union(awake.keys)
                    .union(inBed.keys)
                for day in days {
                    sink(day, asleep[day], deep[day], rem[day], core[day], awake[day], inBed[day])
                }
                cont.resume(returning: true)
            }
            store.execute(q)
        }
        if !succeeded { currentReadQueryFailed = true }
    }

    /// Read only cycle-day-one anchors from Apple Health. Apple's contract requires every menstrual-
    /// flow sample to carry `HKMetadataKeyMenstrualCycleStart`; only a true flag and a non-`.none`
    /// flow value becomes an anchor. We intentionally do not retain flow intensity, symptoms,
    /// fertility data, contraception, or diagnoses.
    private func collectAppleHealthCycleStartDays() async -> Set<String>? {
        guard cycleImportEnabled,
              let type = HKObjectType.categoryType(forIdentifier: .menstrualFlow) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Set<String>?, Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: Self.notNoopAuthored,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) {
                _, samples, error in
                guard error == nil else { cont.resume(returning: nil); return }
                var days = Set<String>()
                for case let sample as HKCategorySample in samples ?? [] {
                    let startsCycle = (sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool)
                        ?? (sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? NSNumber)?.boolValue
                        ?? false
                    guard startsCycle,
                          sample.value != HKCategoryValueMenstrualFlow.none.rawValue else { continue }
                    days.insert(HealthKitBridge.dayString(sample.startDate))
                }
                cont.resume(returning: days)
            }
            store.execute(query)
        }
    }

    /// Full-set reconciliation is deliberate: HealthKit deletion callbacks contain UUIDs but no sample
    /// dates. The cycle record is tiny, so re-reading it is both cheaper and more correct than guessing a
    /// deletion window. The repository replaces only `apple-health-cycle`; manual anchors are isolated.
    private func syncAppleHealthCycleAnchors() async {
        guard cycleImportEnabled,
              let days = await collectAppleHealthCycleStartDays() else { return }
        if await repo.reconcileAppleHealthPeriodStarts(days: days) {
            await cycleAnchorsChanged?()
        }
    }

    // MARK: - Workouts (#835)

    private struct WorkoutHRStatistics: Sendable {
        let average: Double?
        let maximum: Double?
    }

    /// Read the workouts the user logged in Apple Health over `[start, end)` and enrich each with only
    /// data explicitly associated with that `HKWorkout`: source-native Avg/Max HR statistics and the
    /// scoped HR series for NOOP's shared zones/Effort engines. NOOP does not request workout-route
    /// access as part of general Health authorization; precise location needs its own future opt-in and
    /// protected storage design. NOOP-authored workouts are excluded so write-back never re-imports.
    /// Any HealthKit query error throws and aborts the sync instead of masquerading as successful emptiness.
    private func collectWorkouts(start: Date, end: Date,
                                 restingHRByDay: [String: Double]) async throws -> [WorkoutRow] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        let workoutResult = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<[HKWorkout], Error>, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(returning: .failure(error)); return }
                cont.resume(returning: .success((samples ?? []).compactMap { $0 as? HKWorkout }))
            }
            store.execute(q)
        }
        let workouts = try workoutResult.get()

        var rows: [WorkoutRow] = []
        rows.reserveCapacity(workouts.count)
        for workout in workouts {
            // These independent reads start together, avoiding two serial round trips per workout while
            // retaining the bridge's MainActor
            // ownership for all published state and persistence.
            async let statistics = collectWorkoutHeartRateStatistics(workout)
            async let samples = collectWorkoutHeartRateSamples(workout)
            let (scopedStatistics, scopedSamples) = try await (statistics, samples)

            let startTs = Int(workout.startDate.timeIntervalSince1970)
            let endTs = max(Int(workout.endDate.timeIntervalSince1970), startTs)
            let duration = workout.duration > 0 ? workout.duration : Double(endTs - startTs)
            let day = Self.dayString(workout.startDate)
            let hr = WorkoutHeartRateEnrichment.summarize(
                samples: scopedSamples,
                workoutStart: startTs,
                workoutEnd: endTs,
                maxHR: Double(profile.hrMax),
                restingHR: restingHRByDay[day],
                sex: profile.sex,
                statisticsAverage: scopedStatistics?.average,
                statisticsMaximum: scopedStatistics?.maximum
            )
            rows.append(WorkoutRow(
                startTs: startTs,
                endTs: endTs,
                sport: Self.sportName(workout.workoutActivityType),
                source: HealthKitBridge.appleWorkoutSource,
                durationS: duration,
                energyKcal: Self.finitePositive(
                    workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())),
                avgHr: hr.avgHR,
                maxHr: hr.maxHR,
                strain: hr.strain,
                distanceM: Self.finitePositive(
                    workout.totalDistance?.doubleValue(for: .meter())),
                zonesJSON: hr.zonesJSON,
                notes: Self.workoutNotes(from: workout.metadata)
            ))
        }
        return rows
    }

    /// Source-native Avg/Max over HR samples linked to this workout. The association predicate matters:
    /// a plain date predicate can mix a phone app's background HR or an overlapping workout into the row.
    private func collectWorkoutHeartRateStatistics(_ workout: HKWorkout) async throws -> WorkoutHRStatistics? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            Self.notNoopAuthored,
        ])
        let unit = HKUnit.count().unitDivided(by: .minute())
        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<WorkoutHRStatistics?, Error>, Never>) in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: [.discreteAverage, .discreteMax]) { _, stats, error in
                if let error { cont.resume(returning: .failure(error)); return }
                guard let stats else { cont.resume(returning: .success(nil)); return }
                cont.resume(returning: .success(WorkoutHRStatistics(
                    average: stats.averageQuantity()?.doubleValue(for: unit),
                    maximum: stats.maximumQuantity()?.doubleValue(for: unit)
                )))
            }
            store.execute(query)
        }
        return try result.get()
    }

    /// Exact workout-associated samples for zones and Effort. We retain only Unix second + rounded bpm;
    /// source metadata and UUIDs are neither persisted nor exposed to any sync/export path.
    private func collectWorkoutHeartRateSamples(_ workout: HKWorkout) async throws -> [HRSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            Self.notNoopAuthored,
        ])
        let unit = HKUnit.count().unitDivided(by: .minute())
        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<[HRSample], Error>, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      // >55 hours at 1 Hz; bounds memory against a corrupt provider.
                                      limit: 200_000, sortDescriptors: [sort]) {
                _, samples, error in
                if let error { cont.resume(returning: .failure(error)); return }
                let mapped = (samples ?? []).compactMap { object -> HRSample? in
                    guard let sample = object as? HKQuantitySample else { return nil }
                    let value = sample.quantity.doubleValue(for: unit)
                    guard value.isFinite,
                          value >= Double(WorkoutHeartRateEnrichment.plausibleBPMRange.lowerBound),
                          value <= Double(WorkoutHeartRateEnrichment.plausibleBPMRange.upperBound) else {
                        return nil
                    }
                    return HRSample(ts: Int(sample.startDate.timeIntervalSince1970),
                                    bpm: Int(value.rounded()))
                }
                cont.resume(returning: .success(mapped))
            }
            store.execute(query)
        }
        return try result.get()
    }

    /// Preserve only a small allow-list of explicitly user-visible workout metadata. Never serialize the
    /// metadata dictionary wholesale: it can contain private custom keys, UUIDs, device data, or tokens.
    private static func workoutNotes(from metadata: [String: Any]?) -> String? {
        guard let metadata else { return nil }
        func bool(_ key: String) -> Bool {
            (metadata[key] as? Bool) ?? (metadata[key] as? NSNumber)?.boolValue ?? false
        }
        var parts: [String] = []
        if bool(HKMetadataKeyIndoorWorkout) { parts.append("Indoor") }
        if bool(HKMetadataKeyCoachedWorkout) { parts.append("Coached") }
        if bool(HKMetadataKeyGroupFitness) { parts.append("Group workout") }
        if let rawBrand = metadata[HKMetadataKeyWorkoutBrandName] as? String {
            // Custom providers can put arbitrary text here. Remove control characters before applying
            // the small display cap so metadata can never smuggle terminal/log formatting into notes.
            let visibleBrand = rawBrand.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : String($0)
            }.joined()
            let brand = visibleBrand.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !brand.isEmpty { parts.append("Brand: \(String(brand.prefix(80)))") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func workoutNaturalKey(_ row: WorkoutRow) -> String {
        "\(row.startTs)|\(row.sport)"
    }

    /// HealthKit can withhold individual optional workout fields even when the workout itself remains
    /// readable. Preserve prior enrichment for the same natural key, while deletion reconciliation
    /// still removes rows absent from `fresh` entirely.
    private static func mergeAppleWorkoutRows(fresh: [WorkoutRow],
                                              existing: [WorkoutRow]) -> [WorkoutRow] {
        let existingByKey = Dictionary(
            existing.map { (workoutNaturalKey($0), $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        return fresh.map { row in
            guard let old = existingByKey[workoutNaturalKey(row)] else { return row }
            return WorkoutRow(
                startTs: row.startTs,
                endTs: row.endTs,
                sport: row.sport,
                source: row.source,
                durationS: row.durationS ?? old.durationS,
                energyKcal: row.energyKcal ?? old.energyKcal,
                avgHr: row.avgHr ?? old.avgHr,
                maxHr: row.maxHr ?? old.maxHr,
                strain: row.strain ?? old.strain,
                distanceM: row.distanceM ?? old.distanceM,
                zonesJSON: row.zonesJSON ?? old.zonesJSON,
                notes: row.notes ?? old.notes,
                // HKWorkout has no universal step field. A prior Apple export may have supplied one.
                steps: row.steps ?? old.steps
            )
        }
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Source tag stamped on workouts imported from Apple Health. Matches the macOS importer's
    /// `WorkoutSource.appleHealthSource` ("apple-health") and `appleDeviceId`, so the workout list and
    /// source filters treat an iOS-read workout exactly like a macOS-imported one.
    nonisolated static let appleWorkoutSource = "apple-health"

    /// Map an `HKWorkoutActivityType` to NOOP's human sport label. Strength training routes to the
    /// shared lifting sport so a gym session lands in the Lifting lane; anything we don't name explicitly
    /// falls back to a generic "Workout" rather than an opaque numeric type.
    nonisolated private static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                    return "Running"
        case .walking:                    return "Walking"
        case .hiking:                     return "Hiking"
        case .cycling:                    return "Cycling"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return LiftingImporter.sport
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:               return "Core training"
        case .yoga:                       return "Yoga"
        case .pilates:                    return "Pilates"
        case .rowing:                     return "Rowing"
        case .elliptical:                 return "Elliptical"
        case .stairClimbing, .stairs:     return "Stairs"
        case .jumpRope:                   return "Jump rope"
        case .boxing, .kickboxing:        return "Boxing"
        case .basketball:                 return "Basketball"
        case .soccer:                     return "Soccer"
        case .americanFootball:           return "Football"
        case .baseball:                   return "Baseball"
        case .badminton:                  return "Badminton"
        case .tennis:                     return "Tennis"
        case .tableTennis:                return "Table tennis"
        case .volleyball:                 return "Volleyball"
        case .squash, .racquetball:       return "Squash"
        case .martialArts, .taiChi:       return "Martial arts"
        case .dance, .cardioDance, .socialDance: return "Dancing"
        case .golf:                       return "Golf"
        case .climbing:                   return "Climbing"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .snowboarding:               return "Snowboarding"
        case .swimming:                   return "Swimming"
        case .surfingSports:              return "Surfing"
        case .paddleSports:               return "Paddling"
        default:                          return "Workout"
        }
    }

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / Sideloadly
    /// re-sign, which strips the HealthKit capability: the framework links and `isHealthDataAvailable()`
    /// is still true, but `requestAuthorization` is a dead-end and the app can never appear under
    /// Settings › Health › Data Access & Devices.
    ///
    /// Resolution order (most authoritative first), mirroring `IOSDiagnostics`'s profile parse:
    ///  1. If an `embedded.mobileprovision` is present (every dev / sideloaded / TestFlight build ships
    ///     one), slice the wrapped XML plist and look for `com.apple.developer.healthkit` in its
    ///     `Entitlements` dict. A free re-sign re-writes this profile WITHOUT that key. This is the
    ///     definitive signal and is unaffected by whether the user later granted/denied permission.
    ///  2. No embedded profile → an App Store install (App Store strips it). Those are properly signed
    ///     with whatever capabilities the app declares, so treat the entitlement as PRESENT. This is the
    ///     conservative default: it never down-routes a legitimately-signed build, so a user who simply
    ///     denied permission keeps the normal Settings guidance rather than the file-import reroute.
    ///
    /// Computed once and cached: the bundle's profile can't change within a process lifetime.
    nonisolated static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    /// HealthKit observer background wakes require a second entitlement on iOS 15+. Keep this
    /// separate from the base HealthKit capability so a development/re-signed profile can still use
    /// foreground Health reads without NOOP claiming it will be woken in the background.
    nonisolated static let hasHealthKitBackgroundDeliveryEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return true // App Store strips the embedded profile.
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else { return false }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        return (entitlements["com.apple.developer.healthkit.background-delivery"] as? Bool) == true
    }()

    private static let authorizationRequestedKey = "healthkit.authorizationRequested.v1"
    private static let bodyCompositionAuthorizationRequestedKey =
        "healthkit.bodyCompositionAuthorizationRequested.v1"
    private static let highResolutionWritebackAuthorizationRequestedKey =
        "healthkit.highResolutionWritebackAuthorizationRequested.v1"
    private static let mislabelledHrvCleanupCompletedKey =
        "healthkit.mislabelledHrvCleanupCompleted.v1"
    private static let cycleAuthorizationRequestedKey = "healthkit.cycleAuthorizationRequested.v1"

    // MARK: - Date helpers

    // LOCAL civil day: the rest of the store keys days by the device-local civil day —
    // AppleHealthAggregator.localDay shifts each sample into its own offset, and
    // Repository.dayFormatter leaves timeZone at the default (local) zone. The
    // HKStatisticsCollectionQuery here already buckets in Calendar.current (anchor =
    // startOfDay, interval = 1 day), so labelling those local-midnight bucket starts with a
    // matching local formatter is strictly 1:1; using UTC instead mislabelled a full local day
    // under the previous UTC date for users east of UTC, so apple-health rows never merged with
    // the strap-computed/imported rows for the same civil day.
    // `nonisolated` so the HealthKit query completion handlers — which HealthKit invokes on a private
    // background queue (a nonisolated context) — can label day buckets without a main-actor-isolation
    // warning. They only read a thread-safe DateFormatter, so this is safe off the main actor.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
