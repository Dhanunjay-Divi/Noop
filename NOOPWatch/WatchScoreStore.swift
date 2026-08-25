import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import StrandDesign

// MARK: - WatchScoreStore — the watch side of the phone->watch bridge
//
// Activates WCSession on the watch, receives the latest score snapshot the phone pushed via
// `updateApplicationContext` (latest-state semantics, no queue buildup), persists it into the shared
// App Group so the complication can read the same bytes, and reloads the complication timelines so the
// watch face matches the glance. The phone is the brain; this object never computes a score, it only
// carries the one the phone already earned.
//
// The published `snapshot` is what the glance binds to. It starts from whatever was last persisted to the
// App Group (so a relaunch shows the last-known scores immediately, with an honest "as of" age) and is
// nil only on a truly fresh install, which the glance renders as the "open NOOP on your iPhone" state.
@MainActor
final class WatchScoreStore: NSObject, ObservableObject, WCSessionDelegate {

    /// The latest snapshot the watch knows about. nil = nothing has ever synced (fresh install).
    @Published private(set) var snapshot: WatchScoreSnapshot?
    @Published private(set) var strengthPlan: WatchStrengthPlan?
    @Published private(set) var strengthHandoffMessage: String?

    /// The shared App Group suite the watch app + its complication both read/write. `Bundle.main` is
    /// process-global, so this is exactly the lookup `WatchScoreSnapshot.appGroupId` itself performs —
    /// deferring to it directly (rather than repeating the lookup here) keeps the resolution in ONE
    /// place so the writer and readers can't desync on it.
    static let suiteName: String = WatchScoreSnapshot.appGroupId

    /// The key the complication also reads. The single source of truth lives in the shared contract.
    static let storageKey = WatchScoreSnapshot.storageKey

    override init() {
        #if DEBUG
        Self.seedDemoStrengthPlanIfNeeded()
        #endif
        super.init()
        // Show the last-known snapshot straight away (honest about its age via the glance's "as of").
        snapshot = Self.loadPersisted()
        strengthPlan = WatchStrengthPlan.load()
        activate()
    }

    #if DEBUG
    /// Screenshot-only routine data, activated solely by the existing explicit demo route.
    private static func seedDemoStrengthPlanIfNeeded() {
        guard ProcessInfo.processInfo.environment["NOOP_DEMO_SCREEN"] == "strength",
              WatchStrengthPlan.load() == nil else { return }
        WatchStrengthPlan(
            routines: [
                WatchStrengthRoutine(
                    id: "demo-upper",
                    name: "Upper strength",
                    exerciseNames: ["Bench press", "Row", "Shoulder press"],
                    targetSetCount: 12
                ),
                WatchStrengthRoutine(
                    id: "demo-lower",
                    name: "Lower strength",
                    exerciseNames: ["Squat", "Romanian deadlift", "Calf raise"],
                    targetSetCount: 11
                ),
            ],
            activeSessionName: nil,
            activeCompletedSets: 0,
            activeTargetSets: 0,
            updatedAt: Date()
        ).save()
    }
    #endif

    /// Bring up the WCSession so the phone can reach us. Guarded because the simulator / an unpaired
    /// state can report the session unsupported, in which case we simply run on the last persisted snapshot.
    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Persistence (shared with the complication)

    /// Read the last snapshot the phone delivered, if any. The complication uses the same key.
    static func loadPersisted() -> WatchScoreSnapshot? {
        WatchScoreSnapshot.load()
    }

    /// Persist a snapshot into the shared group so the complication reads the SAME bytes the glance shows.
    /// They can never disagree because there is one source of truth.
    private func persist(_ snap: WatchScoreSnapshot) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Apply a freshly received snapshot: store it, publish to the glance, refresh the complication.
    /// Hops to the main actor because it touches @Published state and WidgetCenter.
    private func apply(_ snap: WatchScoreSnapshot) {
        guard snap.isLaunchSurfaceAuthorized() else {
            UserDefaults(suiteName: Self.suiteName)?.removeObject(forKey: Self.storageKey)
            snapshot = nil
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        persist(snap)
        snapshot = snap
        // The phone just pushed new scores, so pull the complication timelines forward now rather
        // than waiting for WidgetKit's own cadence.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func apply(_ plan: WatchStrengthPlan) {
        plan.save()
        strengthPlan = plan
    }

    /// Decode a WatchScoreSnapshot out of a WatchConnectivity payload. The phone encodes the Codable
    /// snapshot to Data under "snapshot"; we tolerate a missing/garbled payload by simply ignoring it.
    nonisolated private static func decode(from payload: [String: Any]) -> WatchScoreSnapshot? {
        guard let data = payload["snapshot"] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
    }

    nonisolated private static func decodeStrength(
        from payload: [String: Any]
    ) -> WatchStrengthPlan? {
        guard let data = payload[WatchStrengthPlan.contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchStrengthPlan.self, from: data)
    }

    /// Ask the paired phone to create or resume one routine-backed session. The phone is the source
    /// of truth; an unreachable phone never produces a local phantom workout.
    func startStrengthRoutine(id: String) {
        guard WCSession.isSupported() else {
            strengthHandoffMessage = "Open NOOP on your iPhone to start this routine."
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            strengthHandoffMessage = "Open NOOP on your iPhone, then try again."
            return
        }
        strengthHandoffMessage = "Starting on iPhone…"
        session.sendMessage(
            [WatchStrengthPlan.startRoutineMessageKey: id],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.strengthHandoffMessage = (reply["accepted"] as? Bool) == true
                        ? "Started on iPhone"
                        : "The iPhone did not confirm the start."
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.strengthHandoffMessage = "Open NOOP on your iPhone, then try again."
                }
            }
        )
    }

    func clearStrengthHandoffMessage() {
        strengthHandoffMessage = nil
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // On activation the system hands us the most recent application context the phone set, even if it
        // was set while we were not running. Pick it up so a relaunch immediately reflects the latest scores.
        if let snap = Self.decode(from: session.receivedApplicationContext) {
            Task { @MainActor [weak self] in self?.apply(snap) }
        }
        if let plan = Self.decodeStrength(from: session.receivedApplicationContext) {
            Task { @MainActor [weak self] in self?.apply(plan) }
        }
    }

    /// The phone calls `updateApplicationContext` whenever its dashboard refreshes. Latest-state only, so
    /// we always have the freshest scores without a backlog of stale messages.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        if let snap = Self.decode(from: applicationContext) {
            Task { @MainActor [weak self] in self?.apply(snap) }
        }
        if let plan = Self.decodeStrength(from: applicationContext) {
            Task { @MainActor [weak self] in self?.apply(plan) }
        }
    }

    // Required by the protocol on watchOS even though they are phone-side concerns. No-ops here.
    #if os(watchOS)
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {}
    #endif
}
