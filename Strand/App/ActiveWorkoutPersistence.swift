import Foundation
import WhoopProtocol

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// A manual workout used to live ONLY in `AppModel.activeWorkout` (in memory), so if iOS killed the app
/// mid-session — a backgrounded phone under memory pressure — the whole session was lost and could never
/// be ended + saved. This is the Apple analogue of Android's `ActiveWorkoutStore`/
/// `ActiveWorkoutPersistence`: a compact `Codable` snapshot (bounds, sport, GPS
/// intent/checkpoint, accumulated HR samples + running stats) is written to `UserDefaults` on start and
/// at bounded sensor checkpoints, then read on launch so an interrupted session can continue or save.
///
/// On-device only; mirrors the existing `moments` / `sleepMarks` `UserDefaults` persistence in `AppModel`.
/// The encode/decode is pure (no `UserDefaults` dependency on the codec itself) so the persist/rehydrate
/// round-trip is unit-testable — `store(into:)` / `load(from:)` just thread a `UserDefaults` through it.
enum ActiveWorkoutPersistence {

    /// The durable shape of an in-flight manual workout. A small, self-contained `Codable` value — the
    /// minimum needed to rebuild `AppModel.ActiveWorkout` on relaunch and still End + save it.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds (stable across encodings; `AppModel` maps to/from `Date`).
        var startSec: Int
        /// The moment the user tapped End, retained while the finished row is waiting for a durable DB
        /// commit. nil means the session is still recording. Keeping this in the recovery snapshot makes
        /// a failed save retry the same bounded workout instead of silently extending it after relaunch.
        var endSec: Int? = nil
        /// Distance-sport intent survives process death even when permission yielded no route points.
        var gpsEnabled: Bool = false
        /// Latest validated, compact accepted-route checkpoint. nil is honest "no accepted GPS fix yet."
        var routeCheckpoint: WorkoutRouteCheckpoint? = nil
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrain: Double

        init(startSec: Int, endSec: Int? = nil, gpsEnabled: Bool = false,
             routeCheckpoint: WorkoutRouteCheckpoint? = nil, sport: String,
             samples: [HRSample], avgHr: Int, peakHr: Int, liveStrain: Double) {
            self.startSec = startSec
            self.endSec = endSec
            self.gpsEnabled = gpsEnabled
            self.routeCheckpoint = routeCheckpoint
            self.sport = sport
            self.samples = samples
            self.avgHr = avgHr
            self.peakHr = peakHr
            self.liveStrain = liveStrain
        }

        private enum CodingKeys: String, CodingKey {
            case startSec, endSec, gpsEnabled, routeCheckpoint, sport, samples, avgHr, peakHr, liveStrain
        }

        /// Explicit decode keeps pre-GPS snapshots compatible: synthesized Codable would require the new
        /// nonoptional Bool key and discard a perfectly valid workout written by an older build.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startSec = try c.decode(Int.self, forKey: .startSec)
            endSec = try c.decodeIfPresent(Int.self, forKey: .endSec)
            gpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .gpsEnabled) ?? false
            routeCheckpoint = try c.decodeIfPresent(WorkoutRouteCheckpoint.self, forKey: .routeCheckpoint)
            sport = try c.decode(String.self, forKey: .sport)
            samples = try c.decode([HRSample].self, forKey: .samples)
            avgHr = try c.decode(Int.self, forKey: .avgHr)
            peakHr = try c.decode(Int.self, forKey: .peakHr)
            liveStrain = try c.decode(Double.self, forKey: .liveStrain)
        }

        /// Resume location only for a GPS-enabled session the user has not already ended. A retained
        /// failed-save snapshot may contain a route, but must stay frozen and never restart GPS.
        var shouldResumeGps: Bool { gpsEnabled && endSec == nil }
    }

    /// The single `UserDefaults` key (JSON-encoded `Snapshot`). Namespaced like `moments`/`sleepMarks`.
    static let defaultsKey = "noop.activeWorkout"

    /// Encode a snapshot to JSON `Data`. Returns nil only if encoding somehow fails (never expected for
    /// this all-value shape) so the caller can no-op rather than write garbage.
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot from JSON `Data`, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no
    /// in-flight session" rather than reviving a broken card.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop any out-of-range persisted HR samples (a real bpm + a positive ts only) — never trust the
        // blob to be clean. Parity with the Android decoder's 1...300 bpm / ts > 0 gate.
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        // A persisted "finished before it started" bound is corrupt. Failing the entire value closed is
        // safer than turning it back into an unfinished workout and silently restarting HR/GPS capture.
        if let endSec = raw.endSec, endSec < raw.startSec { return nil }
        let endSec = raw.endSec
        let routeCheckpoint = raw.routeCheckpoint?.validated()
        return Snapshot(
            startSec: raw.startSec,
            endSec: endSec,
            gpsEnabled: raw.gpsEnabled,
            routeCheckpoint: routeCheckpoint,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrain: raw.liveStrain.isFinite ? max(0, raw.liveStrain) : 0,
        )
    }

    /// Persist (overwrite) the snapshot. Called on start, bounded HR/GPS checkpoints, and forced at End.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Read back the persisted snapshot, or nil if none is stored (or it was corrupt).
    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Clear the snapshot only after its finished row commits, or after an explicit discard.
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Commit a finished workout before deleting its recovery snapshot. A failed/unavailable database
    /// leaves the snapshot byte-for-byte intact so the UI (or the next launch) can retry. This ordering is
    /// centralized here rather than being left to an unstructured Task in AppModel, and is directly
    /// regression-tested with a throwing save closure.
    enum SaveResult: Equatable {
        case saved
        case failed(String)
    }

    @MainActor
    static func saveThenClear(
        from defaults: UserDefaults = .standard,
        save: () async throws -> Void
    ) async -> SaveResult {
        do {
            try await save()
            clear(from: defaults)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Pure checkpoint gate for the growing manual-workout HR window. Serializing the complete recovery
/// snapshot for every ~1 Hz packet repeatedly rewrites the same prefix; instead we write at most once per
/// 30 new accepted samples or 30 seconds, plus explicit lifecycle/GPS checkpoints. An abrupt process kill
/// can therefore lose at most the uncheckpointed tail: 29 accepted samples or just under 30 seconds under
/// normal monotonic sensor time. End always forces a final snapshot before any database attempt.
struct WorkoutRecoveryCadence: Equatable {
    static let sampleStride = 30
    static let intervalSec = 30

    private(set) var persistedSampleCount: Int
    private(set) var persistedAtSec: Int

    init(persistedSampleCount: Int = 0, persistedAtSec: Int = 0) {
        self.persistedSampleCount = max(0, persistedSampleCount)
        self.persistedAtSec = max(0, persistedAtSec)
    }

    func isDue(sampleCount: Int, nowSec: Int) -> Bool {
        guard sampleCount > persistedSampleCount else { return false }
        return sampleCount - persistedSampleCount >= Self.sampleStride
            || (nowSec >= persistedAtSec && nowSec - persistedAtSec >= Self.intervalSec)
    }

    mutating func didPersist(sampleCount: Int, atSec: Int) {
        persistedSampleCount = max(0, sampleCount)
        persistedAtSec = max(0, atSec)
    }
}

/// Bounds full-window live Effort recomputation while a workout grows. The scorer remains authoritative:
/// this gate changes only presentation cadence, and `endWorkout()` always scores the complete final array.
struct WorkoutLiveStrainCadence: Equatable {
    static let sampleStride = 5
    static let intervalSec = 5

    private(set) var computedSampleCount: Int
    private(set) var computedAtSec: Int

    init(computedSampleCount: Int = 0, computedAtSec: Int = 0) {
        self.computedSampleCount = max(0, computedSampleCount)
        self.computedAtSec = max(0, computedAtSec)
    }

    func isDue(
        sampleCount: Int,
        firstSampleSec: Int?,
        nowSec: Int,
        minimumSampleCount: Int,
        minimumSpanSec: Int
    ) -> Bool {
        guard sampleCount >= minimumSampleCount,
              let firstSampleSec,
              nowSec >= firstSampleSec,
              nowSec - firstSampleSec >= minimumSpanSec else { return false }
        return sampleCount - computedSampleCount >= Self.sampleStride
            || (nowSec >= computedAtSec && nowSec - computedAtSec >= Self.intervalSec)
    }

    mutating func didCompute(sampleCount: Int, atSec: Int) {
        computedSampleCount = max(0, sampleCount)
        computedAtSec = max(0, atSec)
    }
}

/// Event cursor for manual-workout HR capture. `LiveState.heartRate` is display state and may be read or
/// republished repeatedly after transport stalls; a workout sample is admitted only when the sensor-event
/// sequence advances. The event's receipt time becomes the stored timestamp, and the one-second storage
/// resolution is deduplicated rather than fabricating extra time for multiple callbacks in one second.
struct WorkoutHeartRateCursor: Equatable {
    private(set) var consumedSequence: UInt64
    private(set) var lastTimestamp: Int?

    init(consumedSequence: UInt64, lastTimestamp: Int? = nil) {
        self.consumedSequence = consumedSequence
        self.lastTimestamp = lastTimestamp
    }

    mutating func consume(sequence: UInt64, bpm: Int?, receivedAt: Date) -> HRSample? {
        guard sequence != consumedSequence else { return nil }
        consumedSequence = sequence
        guard let bpm, (30...220).contains(bpm) else { return nil }
        let ts = Int(receivedAt.timeIntervalSince1970)
        guard ts > (lastTimestamp ?? 0) else { return nil }
        lastTimestamp = ts
        return HRSample(ts: ts, bpm: bpm)
    }
}
