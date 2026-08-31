#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private typealias NOOPActivity = Activity<NOOPActivityAttributes>

    private var activity: NOOPActivity?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// The newest requested presentation. Updates can arrive while ActivityKit is suspending in an
    /// `await`; keeping only the latest state and draining it serially prevents an older START from
    /// racing a newer END after a disconnect or preference change.
    private var pendingState: DesiredState?
    /// Last requested state survives the serialized drain. The delayed ActivityKit hydration repair must
    /// re-read this value instead of replaying the launch snapshot, otherwise a packet/disconnect received
    /// during that 500 ms window could be overwritten by stale captured inputs.
    private var latestState: DesiredState?
    /// Every requested presentation/end advances this fence. ActivityKit calls suspend, so an older
    /// apply must re-check the fence after each await before it can publish or schedule follow-up work.
    private var stateGeneration: UInt64 = 0
    private var isReconciling = false
    /// Public `end()` is allowed to interleave while ActivityKit is suspended. While it owns the bridge,
    /// new updates remain queued and the normal drain pauses; concurrent end callers join the same pass.
    private var isEnding = false
    private var endWaiters: [CheckedContinuation<Void, Never>] = []
    private var expiryTask: Task<Void, Never>?
    private var hydrationTask: Task<Void, Never>?

    private struct DesiredState {
        let generation: UInt64
        let bpm: Int?
        let recovery: Int?
        let effort: Int?
        let batteryPct: Int?
        let connected: Bool
        let observedAt: Date?
        let now: Date

        var hasFreshHeartRate: Bool {
            LiveHeartRateSurfacePolicy.isLive(
                connected: connected, bpm: bpm, observedAt: observedAt, now: now
            )
        }
    }

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Throttled to ~once every 2 s so we stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil,
                batteryPct: Int? = nil, observedAt: Date?, now: Date = Date()) {
        stateGeneration &+= 1
        let desired = DesiredState(generation: stateGeneration,
                                   bpm: bpm, recovery: recovery, effort: effort,
                                   batteryPct: batteryPct,
                                   connected: connected, observedAt: observedAt, now: now)
        latestState = desired
        pendingState = desired
        // A fresh observation supersedes an older sample's timer immediately, before a queued
        // ActivityKit apply gets the main actor again.
        cancelExpiry()
        startDrainIfNeeded()
    }

    /// Adopt and repair activities that survived a previous process before the first HR publisher
    /// emits. A disconnected, disabled, or freshly reinstalled app must not leave an orphaned heart
    /// pill that launches a surface iOS can no longer resolve.
    func reconcile(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil,
                   batteryPct: Int? = nil, observedAt: Date?) {
        update(bpm: bpm, recovery: recovery, connected: connected, effort: effort,
               batteryPct: batteryPct, observedAt: observedAt)
        // ActivityKit can hydrate surviving activities shortly after the app scene mounts. A second
        // reconciliation reaches those handles and either adopts or ends them; it cannot start from a
        // stale packet because the original observation timestamp is carried through unchanged.
        scheduleHydrationRepair()
    }

    private func startDrainIfNeeded() {
        guard !isReconciling, !isEnding, pendingState != nil else { return }
        isReconciling = true
        Task { await drainPendingStates() }
    }

    private func drainPendingStates() async {
        while !isEnding, let desired = pendingState {
            pendingState = nil
            await apply(desired)
        }
        isReconciling = false
        // An update cannot interleave between the two synchronous lines above on the main actor. The
        // explicit helper also covers a direct end that released its serialization gate while this
        // older drain was unwinding.
        startDrainIfNeeded()
    }

    private func apply(_ desired: DesiredState) async {
        guard isCurrent(desired) else { return }

        guard authInfo.areActivitiesEnabled,
              UnitPrefs.liveActivityEnabled(),
              desired.hasFreshHeartRate else {
            // Preserve the delayed hydration repair. Its whole purpose is to repeat this terminal
            // cleanup after ActivityKit has exposed activities that were absent from the launch list.
            cancelExpiry()
            await endActivities()
            return
        }

        if !hasUsableCachedActivity {
            let usable = allKnownActivities().filter { candidate in
                switch candidate.activityState {
                case .ended, .dismissed: false
                default: true
                }
            }
            // ActivityKit does not promise an ordering for `activities`. Pick the newest stale-date and
            // use a stable ID tie-break so cold-launch adoption cannot oscillate between survivors.
            let selection = LiveActivitySelection.select(usable.map {
                .init(id: $0.id, freshnessDate: $0.content.staleDate)
            })
            let canonical = selection.canonicalID.flatMap { id in
                usable.first { $0.id == id }
            }
            adopt(canonical)

            // A previous race/build may have left duplicates. Reconcile them when adopting; once a valid
            // handle is cached, normal HR pushes no longer enumerate the process-wide activity list.
            let duplicateIDs = Set(selection.duplicateIDs)
            for duplicate in usable where duplicateIDs.contains(duplicate.id) {
                await duplicate.end(nil, dismissalPolicy: .immediate)
                guard isCurrent(desired) else { return }
            }
        }

        guard isCurrent(desired) else { return }
        guard let bpm = desired.bpm, let observedAt = desired.observedAt else { return }
        let state = NOOPActivityAttributes.ContentState(
            bpm: bpm,
            recovery: desired.recovery,
            bonded: desired.connected,
            effort: desired.effort,
            batteryPct: desired.batteryPct
        )
        let staleDate = observedAt.addingTimeInterval(
            LiveHeartRateSurfacePolicy.maximumSampleAge
        )

        if let activity {
            guard desired.now.timeIntervalSince(lastPush) > 2 else {
                scheduleExpiry(observedAt: observedAt)
                return
            }
            lastPush = desired.now
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
            guard isCurrent(desired) else { return }
        } else {
            guard !isStarting else { return }
            isStarting = true
            defer { isStarting = false }
            do {
                let started = try NOOPActivity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                adopt(started)
                lastPush = desired.now
            } catch {
                activity = nil
            }
        }
        scheduleExpiry(observedAt: observedAt)
    }

    private func isCurrent(_ desired: DesiredState) -> Bool {
        desired.generation == stateGeneration && !isEnding
    }

    private func adopt(_ canonical: NOOPActivity?) {
        if activity?.id != canonical?.id { lastPush = .distantPast }
        activity = canonical
    }

    private var hasUsableCachedActivity: Bool {
        guard let activity else { return false }
        switch activity.activityState {
        case .ended, .dismissed: return false
        default: return true
        }
    }

    private func allKnownActivities() -> [NOOPActivity] {
        var activities = NOOPActivity.activities
        if let activity, !activities.contains(where: { $0.id == activity.id }) {
            activities.append(activity)
        }
        return activities
    }

    private func scheduleExpiry(observedAt: Date) {
        cancelExpiry()
        let delay = LiveHeartRateSurfacePolicy.expiryDelay(observedAt: observedAt, now: Date())
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.end()
        }
    }

    private func cancelExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    /// ActivityKit may populate `Activity.activities` shortly after scene mount. The repair always
    /// resolves from actor-owned current state at fire time: a newer packet is replayed with its original
    /// observation timestamp, while a still-terminal controller performs a second orphan cleanup.
    private func scheduleHydrationRepair() {
        hydrationTask?.cancel()
        hydrationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            if let latest = self.latestState {
                self.update(bpm: latest.bpm, recovery: latest.recovery,
                            connected: latest.connected, effort: latest.effort,
                            batteryPct: latest.batteryPct,
                            observedAt: latest.observedAt, now: Date())
            } else {
                await self.end(scheduleHydrationRepair: false)
            }
        }
    }

    func end() async {
        await end(scheduleHydrationRepair: true)
    }

    /// Serialization boundary for an explicit opt-out, disconnect expiry, or hydration cleanup.
    /// New presentations may queue while ActivityKit suspends, but cannot drain until the terminal pass
    /// has finished. Multiple end callers join the active pass instead of racing separate snapshots.
    private func end(scheduleHydrationRepair shouldRepairHydration: Bool) async {
        stateGeneration &+= 1
        latestState = nil
        pendingState = nil
        cancelExpiry()
        if shouldRepairHydration { scheduleHydrationRepair() }

        if isEnding {
            await withCheckedContinuation { endWaiters.append($0) }
            // A delayed hydration repair must take a NEW Activity.activities snapshot after the
            // in-flight terminal pass. If it merely joins that pass, an orphan that became visible
            // after the first snapshot can survive indefinitely. Do not repeat a user-facing end:
            // only the no-repair hydration path needs this second, still-terminal pass, and abandon
            // it if a newer live state arrived while we were waiting.
            if !shouldRepairHydration, latestState == nil {
                await end(scheduleHydrationRepair: false)
            }
            return
        }

        isEnding = true
        await endActivities()
        isEnding = false

        let waiters = endWaiters
        endWaiters.removeAll()
        waiters.forEach { $0.resume() }
        startDrainIfNeeded()
    }

    private func endActivities() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted and any rare duplicate. Include the cached handle because a newly
        // requested activity can exist briefly before the process-wide list reflects it.
        var ended = Set<String>()
        for candidate in allKnownActivities() where ended.insert(candidate.id).inserted {
            await candidate.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastPush = .distantPast
    }
}
#endif
