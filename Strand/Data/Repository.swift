import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign   // TrendPoint , the shared chart point type the Deep Timeline series uses

enum RepositoryReadError: Error {
    case storeUnavailable
    case incompleteSleepSnapshot
}

/// Stable identity for one suggestion. The endpoint is deliberately excluded: a later sync can extend
/// the same bout or merge a nearby finalized span, but it must not create a second prompt/notification.
/// Legacy `start:end` values remain readable so existing dismissals survive the migration.
enum AutoWorkoutSuggestionIdentity {
    private static let prefix = "start:"

    static func token(startSec: Int, endSec: Int) -> String {
        _ = endSec
        return prefix + String(startSec)
    }

    static func startSec(from token: String) -> Int? {
        if token.hasPrefix(prefix) { return Int(token.dropFirst(prefix.count)) }
        let parts = token.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[0])
    }

    static func referenceSec(from token: String) -> Int? {
        if token.hasPrefix(prefix) { return startSec(from: token) }
        guard let colon = token.lastIndex(of: ":") else { return nil }
        return Int(token[token.index(after: colon)...])
    }

    static func matches(_ token: String, startSec: Int) -> Bool {
        self.startSec(from: token) == startSec
    }
}

/// A deliberately stricter gate for unattended saves than for a visible suggestion. The detector has
/// already required a finalized elevated-HR window, dense HR coverage, no saved overlap, and motion
/// confirmation whenever enough motion exists. Uncalibrated rules can only surface a visible suggestion;
/// even a longer candidate cannot be written unattended until event confidence is genuinely calibrated.
enum AutoWorkoutAutomationPolicy {
    static let minimumAutoSaveMinutes = 15

    static func shouldAutoSave(_ candidate: DetectedWorkout) -> Bool {
        guard candidate.confidenceStatus.permitsUnattendedSave,
              let eventConfidence = candidate.eventConfidence,
              eventConfidence.isFinite,
              (0...1).contains(eventConfidence),
              candidate.startSec > 0,
              candidate.endSec > candidate.startSec,
              candidate.durationMin >= minimumAutoSaveMinutes,
              (30...220).contains(candidate.avgBpm),
              (candidate.avgBpm...250).contains(candidate.peakBpm) else { return false }
        if candidate.suggestedClass != nil {
            guard let confidence = candidate.suggestionConfidence,
                  confidence.isFinite,
                  confidence >= WorkoutTypeClassifier.minAdvisoryConfidence else { return false }
        }
        return true
    }
}

/// A background BLE offload can finish while the phone is locked and may contain two days of history.
/// The in-app card may safely offer any detector-qualified candidate for review, but a lock-screen alert
/// must not make an old or borderline HR-only window feel like a confident real-time claim. Background
/// processing therefore requires recency plus motion/activity corroboration. HR-only candidates remain
/// available for quiet in-app review but can never create a lock-screen claim by themselves.
enum AutoWorkoutBackgroundPolicy {
    static let maximumCandidateAgeSeconds = 2 * 60 * 60
    static let futureToleranceSeconds = 5 * 60
    /// Match the detector's ten-minute candidate floor once independent wrist motion corroborates it.
    /// A second, longer notification floor made valid 10-14 minute sessions visible only in-app.
    static let minimumCorroboratedMinutes = 10

    static func shouldProcess(_ candidate: DetectedWorkout, nowSec: Int) -> Bool {
        guard candidate.startSec > 0,
              candidate.endSec > candidate.startSec,
              candidate.endSec <= nowSec + futureToleranceSeconds,
              nowSec - candidate.endSec <= maximumCandidateAgeSeconds,
              (30...220).contains(candidate.avgBpm),
              (candidate.avgBpm...250).contains(candidate.peakBpm) else { return false }

        // HR-only detection remains useful as a quiet Today suggestion, but it is not enough evidence
        // for a lock-screen interruption: stress, illness, poor optical contact, and an old backfill can
        // all produce a sustained rise. A broad type hint is not independent proof: the classifier can
        // infer a type from a smooth HR trace plus non-locomotion ("still") ticks. Require the detector's
        // separately confirmed motion stream before claiming a possible workout outside the app.
        return candidate.durationMin >= minimumCorroboratedMinutes
            && candidate.evidenceProvenance == .heartRateAndMotion
    }
}

/// The latest unattended save waiting for a quick Keep / Not a workout review on Today. This contains
/// only local workout metadata and lives in UserDefaults beside the mode preference; it never leaves the
/// device. A newer auto-save replaces the review card, while all older rows remain editable in Workouts.
struct AutoWorkoutReview: Codable, Equatable {
    let startSec: Int
    let endSec: Int
    let sport: String
    let source: String
    let avgBpm: Int
    let peakBpm: Int

    var row: WorkoutRow {
        WorkoutRow(startTs: startSec, endTs: endSec, sport: sport, source: source,
                   durationS: Double(endSec - startSec), energyKcal: nil,
                   avgHr: avgBpm, maxHr: peakBpm, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil)
    }

    var candidate: DetectedWorkout {
        DetectedWorkout(startSec: startSec, endSec: endSec, avgBpm: avgBpm,
                        peakBpm: peakBpm, durationMin: max(1, (endSec - startSec) / 60))
    }
}

enum AutoWorkoutReviewStore {
    static let key = "autoWorkout.pendingReview"

    static var current: AutoWorkoutReview? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AutoWorkoutReview.self, from: data)
    }

    static func record(_ review: AutoWorkoutReview) {
        guard let data = try? JSONEncoder().encode(review) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear(startSec: Int? = nil) {
        if let startSec, current?.startSec != startSec { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum AutoWorkoutDecisionAction: String, Codable, Sendable {
    case accepted
    case dismissed
    case autoSaved = "auto_saved_pending_review"
    case keptAutoSave = "kept_auto_save"
    case rejectedAutoSave = "rejected_auto_save"
    case removedDetectedWorkout = "removed_detected_workout"
}

enum AutoWorkoutDecisionActor: String, Codable, Sendable {
    case user
    case automation
}

/// One durable detector outcome for parallel-wear validation. Rows created from a live suggestion
/// retain the evidence that was actually present at that decision. Review/delete events intentionally
/// leave unavailable detector fields nil instead of reconstructing them from a saved workout.
struct AutoWorkoutDecisionRecord: Codable, Equatable, Sendable {
    let candidateStartSec: Int
    let candidateEndSec: Int?
    let recordedAtSec: Int?
    let action: AutoWorkoutDecisionAction
    let actor: AutoWorkoutDecisionActor
    let activityName: String?
    let detectorVersion: String?
    let averageBpm: Int?
    let peakBpm: Int?
    let eventConfidence: Double?
    let confidenceStatus: String?
    let evidenceProvenance: String?
    let suggestedClass: String?
    let suggestionConfidence: Double?
    let origin: String
}

enum AutoWorkoutDecisionHistory {
    static let key = "workouts.autoDetectDecisionHistory.v1"
    static let maxRecords = 1_000
    static let recordedOrigin = "recorded_event"
    static let legacyOrigin = "legacy_dismissal_tombstone"

    static func records(defaults: UserDefaults = .standard) -> [AutoWorkoutDecisionRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AutoWorkoutDecisionRecord].self, from: data)
        else { return [] }
        return Array(decoded.suffix(maxRecords))
    }

    static func record(
        candidate: DetectedWorkout,
        action: AutoWorkoutDecisionAction,
        actor: AutoWorkoutDecisionActor,
        activityName: String?,
        nowSec: Int = Int(Date().timeIntervalSince1970),
        defaults: UserDefaults = .standard
    ) {
        record(
            AutoWorkoutDecisionRecord(
                candidateStartSec: candidate.startSec,
                candidateEndSec: candidate.endSec,
                recordedAtSec: nowSec,
                action: action,
                actor: actor,
                activityName: activityName,
                detectorVersion: candidate.detectorVersion,
                averageBpm: candidate.avgBpm,
                peakBpm: candidate.peakBpm,
                eventConfidence: candidate.eventConfidence,
                confidenceStatus: candidate.confidenceStatus.rawValue,
                evidenceProvenance: candidate.evidenceProvenance.rawValue,
                suggestedClass: candidate.suggestedClass?.rawValue,
                suggestionConfidence: candidate.suggestionConfidence,
                origin: recordedOrigin
            ),
            defaults: defaults
        )
    }

    static func recordSpan(
        startSec: Int,
        endSec: Int?,
        action: AutoWorkoutDecisionAction,
        actor: AutoWorkoutDecisionActor = .user,
        activityName: String?,
        nowSec: Int = Int(Date().timeIntervalSince1970),
        defaults: UserDefaults = .standard
    ) {
        record(
            AutoWorkoutDecisionRecord(
                candidateStartSec: startSec,
                candidateEndSec: endSec,
                recordedAtSec: nowSec,
                action: action,
                actor: actor,
                activityName: activityName,
                detectorVersion: nil,
                averageBpm: nil,
                peakBpm: nil,
                eventConfidence: nil,
                confidenceStatus: nil,
                evidenceProvenance: nil,
                suggestedClass: nil,
                suggestionConfidence: nil,
                origin: recordedOrigin
            ),
            defaults: defaults
        )
    }

    /// Add or replace one `(candidate, action)` event, then retain only the newest bounded tail.
    /// Replacing makes duplicate background/foreground handling idempotent while preserving separate
    /// events such as auto-save followed by Keep or Reject.
    private static func record(
        _ newRecord: AutoWorkoutDecisionRecord,
        defaults: UserDefaults
    ) {
        var history = records(defaults: defaults)
        if let index = history.firstIndex(where: {
            $0.candidateStartSec == newRecord.candidateStartSec
                && $0.action == newRecord.action
        }) {
            history[index] = newRecord
        } else {
            history.append(newRecord)
        }
        history = Array(history.suffix(maxRecords))
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: key)
    }

    /// Merge old dismissal tokens into export only. Modern `start:<ts>` tombstones know no endpoint
    /// or decision time; legacy `start:end` tokens know the endpoint. Unknown fields stay nil.
    static func exportRecords(
        legacyDismissedTokens: [String],
        defaults: UserDefaults = .standard
    ) -> [AutoWorkoutDecisionRecord] {
        var result = records(defaults: defaults)
        let alreadyRejected = Set(result.compactMap { record -> Int? in
            switch record.action {
            case .dismissed, .rejectedAutoSave, .removedDetectedWorkout:
                return record.candidateStartSec
            case .accepted, .autoSaved, .keptAutoSave:
                return nil
            }
        })
        var seenLegacy = alreadyRejected
        for token in legacyDismissedTokens {
            guard let start = AutoWorkoutSuggestionIdentity.startSec(from: token),
                  seenLegacy.insert(start).inserted else { continue }
            let end: Int?
            if token.hasPrefix("start:") {
                end = nil
            } else {
                let parts = token.split(separator: ":")
                end = parts.count == 2 ? Int(parts[1]) : nil
            }
            result.append(
                AutoWorkoutDecisionRecord(
                    candidateStartSec: start,
                    candidateEndSec: end,
                    recordedAtSec: nil,
                    action: .dismissed,
                    actor: .user,
                    activityName: nil,
                    detectorVersion: nil,
                    averageBpm: nil,
                    peakBpm: nil,
                    eventConfidence: nil,
                    confidenceStatus: nil,
                    evidenceProvenance: nil,
                    suggestedClass: nil,
                    suggestionConfidence: nil,
                    origin: legacyOrigin
                )
            )
        }
        return result.sorted {
            ($0.candidateStartSec, $0.recordedAtSec ?? .min, $0.action.rawValue)
                < ($1.candidateStartSec, $1.recordedAtSec ?? .min, $1.action.rawValue)
        }
    }
}

/// Per-day sleep figures the WHOOP export carried verbatim (metricSeries rows written by
/// WhoopImporter under the imported deviceId). SleepView prefers these over its on-device
/// APPROXIMATE recomputations.
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?   // "sleep_performance", 0–100
    var consistencyPct: Double?   // "sleep_consistency", 0–100
    var needMin: Double?          // "sleep_need_min", minutes
    var debtMin: Double?          // "sleep_debt_min", minutes
}

// MARK: - Cross-source resolver model (PR#196 , fresher live charts/metrics)
//
// Product surfaces (Compare, Insights, Stress, Explore, Today) historically read rows under the EXACT
// requested source. That hid freshly-computed and Apple-compatible data that sat under a different
// device id. `Repository.resolvedSeries` resolves a metric over an explicit source PRECEDENCE , imported
// WHOOP wins, NOOP-computed fills the days it doesn't cover, and Apple Health only fills declared-
// compatible vitals on days neither strap source has. These types model that resolution; the exact-source
// reads (`series(key:source:)`) stay available for surfaces that must not mix sources.

/// One day's resolved value plus the source that actually supplied it (so a caption can name it).
struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let source: String
    let sourceKey: String
}

/// A candidate (source, key) pair the resolver will try, in precedence order.
struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String
    let key: String
}

/// The full result of resolving one metric: which sources were tried, and the merged per-day points.
struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]

    /// Plain `(day, value)` rows , the shape the chart/correlation code already consumes.
    var values: [(day: String, value: Double)] { points.map { ($0.day, $0.value) } }

    /// Distinct sources that actually contributed a point, in first-seen order (for a caption).
    var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }
}

/// Source provenance for daily rows before product surfaces merge them. The UI uses this to say
/// where a vital came from without changing the stored data.
enum DailyMetricSource: Equatable {
    case whoopImport
    case noopComputed
    case appleHealth
    case localCache

    var vitalPriority: Int {
        switch self {
        case .whoopImport:  return 0
        case .noopComputed: return 1
        case .appleHealth:  return 2
        case .localCache:   return 3
        }
    }
}

struct SourcedDailyMetric: Equatable {
    let metric: DailyMetric
    let source: DailyMetricSource
}

/// Timing identity used only while attributing the exact rows in one in-memory collection to their
/// bridged wake day. It deliberately remains compact; stage publication uses the stronger fingerprint below.
struct SleepSessionIdentity: Hashable, Sendable {
    let startTs: Int
    let endTs: Int

    init(_ session: CachedSleepSession) {
        startTs = session.startTs
        endTs = session.endTs
    }
}

/// Content-complete identity for a stage-publication verdict. Timestamps alone are insufficient: imported
/// and locally computed source twins can share detected bounds while carrying different edits, stage payloads,
/// or R-R evidence. Including every publication-relevant field makes a later edit/rescore a different row and
/// prevents one source twin's permission from following another row after the source-aware merge.
struct SleepStageEvidenceFingerprint: Hashable, Sendable {
    let startTs: Int
    let effectiveStartTs: Int
    let endTs: Int
    let stagesJSON: String?
    let rrEligibleWindowCount: Int?
    let rrValidWindowCount: Int?

    init(_ session: CachedSleepSession) {
        startTs = session.startTs
        effectiveStartTs = session.effectiveStartTs
        endTs = session.endTs
        stagesJSON = session.stagesJSON
        rrEligibleWindowCount = session.rrEligibleWindowCount
        rrValidWindowCount = session.rrValidWindowCount
    }
}

/// Publication evidence for the sleep sessions returned by the merged read spine. Imported stages are
/// independently classified; locally computed stages are keyed to the evidence row from the same device.
struct DetailedSleepStageEvidenceSnapshot: Equatable, Sendable {
    let independentlyStagedImports: Set<SleepStageEvidenceFingerprint>
    let localPermissionBySession: [SleepStageEvidenceFingerprint: Bool]

    static let empty = DetailedSleepStageEvidenceSnapshot(
        independentlyStagedImports: [],
        localPermissionBySession: [:])

    func canPublish(_ session: CachedSleepSession) -> Bool {
        let fingerprint = SleepStageEvidenceFingerprint(session)
        let imported = independentlyStagedImports.contains(fingerprint)
        let local = localPermissionBySession[fingerprint]
        // Cached rows do not carry their source id. If byte-identical imported and local rows
        // collide, source attribution is ambiguous and detail must be withheld rather than allowing
        // an imported verdict to authorize an unsupported local classifier (or vice versa).
        guard !(imported && local != nil) else { return false }
        return imported || local == true
    }

    func isIndependentlyStagedImport(_ session: CachedSleepSession) -> Bool {
        let fingerprint = SleepStageEvidenceFingerprint(session)
        return independentlyStagedImports.contains(fingerprint)
            && localPermissionBySession[fingerprint] == nil
    }
}

/// Complete, source-resolved input for a HealthKit sleep replacement. This snapshot is produced only
/// after every participating source read succeeds, so a destructive publication migration can never
/// interpret a database failure as an empty sleep history.
struct SleepWritebackRepositorySnapshot: Equatable, Sendable {
    let sessions: [CachedSleepSession]
    let detailedStageEvidence: DetailedSleepStageEvidenceSnapshot
}

/// A compact snapshot of how much history each source holds, fed to the Data Sources "Freshness
/// Pipeline" card and the Android equivalent. Counts only , no per-day rows leave the refresh.
struct RepositoryFreshness: Equatable, Sendable {
    var importedDays: Int = 0
    var computedDays: Int = 0
    var appleDays: Int = 0
    var importedSleeps: Int = 0
    var computedSleeps: Int = 0
    var earliestDay: String?
    var latestDay: String?

    static let empty = RepositoryFreshness()

    var hasAnyHistory: Bool { importedDays > 0 || computedDays > 0 || appleDays > 0 }
}

/// What `deleteSleepSession` hands back so a transient UNDO can restore the night (#65). Carries the
/// deleted row VERBATIM (stagesJSON, motion via the row's own fields, `userEdited`, the effective onset)
/// plus the deviceId of the namespace that OWNED it (computed vs imported), so undo re-inserts it exactly
/// where it came from. A `userEdited` night restored into computed keeps its flag and is not re-scored
/// as a detected twin.
struct SleepDeletionSnapshot: Equatable {
    let session: CachedSleepSession
    let ownerDeviceId: String
    /// The night's wake span used in the tombstone token (== `session.endTs`).
    let endTs: Int
    /// The per-epoch Deep Timeline motion series (`motionJSON`), captured at delete time. Not carried on
    /// `CachedSleepSession`, so undo must re-persist it after the upsert or a `userEdited` night's motion
    /// track vanishes (a detected night self-heals via `analyzeRecent`; a hand-edited one is never
    /// re-detected). nil when the column was NULL. (#65 Android parity.)
    var motion: [Double]?
    /// The per-epoch banked band sleep-state series (`sleepStateJSON`), captured at delete time. Same
    /// reason as `motion`: undo re-persists it so a `userEdited` night keeps its Band Sleep State track.
    var sleepState: [Int]?
}

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
final class Repository: ObservableObject {
    /// The id of the strap whose recordings this read model surfaces. SEEDED at construction with the
    /// legacy "my-whoop", then RE-POINTED to the device registry's `activeDeviceId` once the store opens
    /// (see `adoptActiveDeviceId`), exactly as `BLEManager.bootstrapStore` re-points the WRITE side.
    /// #814: a remove+re-add gives the strap a fresh id ("whoop-<uuid>"), so the Collector writes today's
    /// raw under THAT id while the dashboard kept reading "my-whoop" and snapped to a stale day. Now the
    /// read side follows the same active id the write side does. NOT a `let` for that reason; `private(set)`
    /// so only `adoptActiveDeviceId` can move it.
    private(set) var deviceId: String
    /// Source id for on-device computed scores (recovery/strain/sleep derived from the raw strap
    /// streams by IntelligenceEngine). Merged UNDER the imported `deviceId` rows at read time, so a
    /// real WHOOP import always wins and the strap-only user still gets a populated dashboard.
    private var computedDeviceId: String { deviceId + "-noop" }

    /// The CANONICAL imported/computed id ("my-whoop" + its "-noop" sibling). The WHOOP-IMPORT and the
    /// engine's computed write target stay STABLE here forever (they never follow the active strap), so a
    /// remove+re-add never orphans the history a prior import/score banked. `deviceId` follows the active
    /// strap so today's LIVE raw under a re-added strap's "whoop-<uuid>" id still surfaces (#814); reads
    /// take the UNION of the two so BOTH the live strap AND the canonical history reach the dashboard.
    /// When the active strap IS the canonical id (single-device install) the union collapses to one id and
    /// is byte-identical to the pre-union behaviour.
    private var canonicalDeviceId: String { Self.whoopSource }
    private var canonicalComputedId: String { Self.whoopSource + "-noop" }

    /// The distinct IMPORTED/MEASURED source ids to union for a dashboard read: the active strap (live raw,
    /// #814) and the canonical imported id. Active strap FIRST so per-day dedup lets the measured/live row
    /// win over the imported one. Deduped, so a single-device install (active id == canonical) reads one id.
    var importedReadIds: [String] {
        deviceId == canonicalDeviceId ? [deviceId] : [deviceId, canonicalDeviceId]
    }
    /// The distinct COMPUTED ("-noop") source ids to union: the active strap's computed sibling and the
    /// canonical computed sibling. Same dedup rule as `importedReadIds`.
    var computedReadIds: [String] {
        computedDeviceId == canonicalComputedId ? [computedDeviceId] : [computedDeviceId, canonicalComputedId]
    }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    /// Local wake-days carrying a user edit in the computed namespace. Kept separately because the
    /// presentation merge can legitimately select an imported session and drop the edited row itself.
    @Published private(set) var editedSleepDays: Set<String> = []
    /// Imported (export-verbatim) sleep figures by day. Empty until a WHOOP import lands.
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    /// How much history each source currently holds, recomputed on every `refresh()`. Powers the
    /// Data Sources "Freshness Pipeline" card so the user can see imported vs computed vs Apple coverage.
    @Published private(set) var freshness: RepositoryFreshness = .empty
    /// Daily metric rows with source provenance, used by vital-sign surfaces that need honest
    /// "WHOOP import / NOOP computed / Apple Health" captions instead of a silent merged row.
    @Published private(set) var vitalRows: [SourcedDailyMetric] = []
    /// Monotonic counter bumped on every successful `refresh()`. Intraday-updating views key their
    /// data load on this so they reload when fresh strap data lands , `today?.day` alone is a stable
    /// date string within a day and would freeze e.g. the Today HR trend until the date rolls over.
    @Published private(set) var refreshSeq = 0

    /// #989: bumped by every hydration mutation (log / edit / delete). Today's hydration card re-reads on
    /// this instead of waiting for a full `refreshSeq` data refresh, which a hydration write never causes,
    /// so the card sat stale until an unrelated sync landed. Race-free: Repository is @MainActor.
    @Published private(set) var hydrationSeq = 0
    func noteHydrationChanged() { hydrationSeq += 1 }

    /// Bumped whenever a period-start row is logged or removed. Cycle surfaces can refresh the
    /// sensitive local series without forcing an unrelated full strap-data reload.
    @Published private(set) var cycleTrackingSeq = 0
    func noteCycleTrackingChanged() { cycleTrackingSeq += 1 }

    /// Bumped after a profile-triggered Fitness Age/Vitality reconciliation finishes. Metric-series
    /// writes do not change `days` or `refreshSeq`, so age-shaped surfaces need this focused invalidation.
    @Published private(set) var ageMetricsSeq = 0
    func noteAgeMetricsChanged() {
        ageMetricsSeq += 1
        todayHistoryWideLoadedSeq = -1
        todayHistoryWideCache = nil
    }

    /// Bumped whenever workout persistence changes independently of the daily-metric cache. Activity
    /// calendars and Today workout summaries key their targeted reloads to this revision.
    @Published private(set) var workoutsSeq = 0
    func noteWorkoutsChanged() {
        workoutsSeq += 1
        todayHistoryWideLoadedSeq = -1
        todayHistoryWideCache = nil
    }

    /// Workouts & GPS test mode (Test Centre): the tagged sink for the `.workouts` diagnostic lines
    /// (auto-detect inputs/thresholds/why, cross-source dedup decisions). Default nil (inert) so tests +
    /// non-prod inits get the byte-identical untraced path; AppModel wires it to `live.append(log:domain:)`.
    /// We ALWAYS check `TestCentre.active(.workouts)` BEFORE building any line (the gate is one UserDefaults
    /// bool read), so the read facades pay nothing when the mode is off. Diagnostic only - it never changes
    /// the workout list the query returns.
    var workoutsLog: ((String) -> Void)?

    /// The user's HRmax + sex, injected once by AppModel so the read path can BACKFILL a strap-native
    /// workout's Effort (strain) on display when its stored value is nil (#961). Default nil (inert): tests
    /// and non-prod inits skip the fill and take the byte-identical untraced path. A live/manual session can
    /// end with strain nil (sparse live HR at save time on a 5/MG) while the DAY total already counted the
    /// bout from the raw stream; the backend rescore (IntelligenceEngine.rescoreManualWorkouts) fills it on
    /// the next analyze tick, but that can be up to a tick away. This lets the row show a real Effort the
    /// instant the strap trace covers the window, recomputed from the SAME samples the graph/zones use, so
    /// per-workout Effort can never read blank while the day total counted it. Honest: only filled when the
    /// window is genuinely dense (the same minSamples gate the HR reconcile uses); never fabricated.
    struct StrainProfile: Sendable { let hrMax: Double; let sex: String }
    var strainProfile: StrainProfile?

    /// Emit one Workouts & GPS test-mode line iff the mode is on and a sink is wired. The cheap
    /// `TestCentre.active(.workouts)` gate is checked BEFORE `build()` runs, so the string is never
    /// constructed when the mode is off (the @autoclosure defers it).
    private func emitWorkouts(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts), let workoutsLog else { return }
        workoutsLog(build())
    }

    init(deviceId: String) { self.deviceId = deviceId }

    /// Re-point the read model's ACTIVE-strap id at the device registry's active device, so a re-added
    /// strap's LIVE raw (written under its fresh "whoop-<uuid>" id) surfaces on the dashboard (#814).
    /// Called by AppModel on every registry active-id change. Idempotent + best-effort: an empty/unchanged
    /// id is a no-op, so a single-device install (active id still "my-whoop") never moves and is byte-
    /// identical to the pre-#814 behaviour. This moves only the ACTIVE-strap read id; the dashboard reads
    /// the UNION of it and the canonical "my-whoop" (see `importedReadIds`), so the canonical imported/
    /// computed history a prior import banked still surfaces too (it is NOT orphaned by the move). The
    /// import + computed WRITE targets stay STABLE on the canonical id elsewhere, this is read-side only.
    /// Returns true when the id actually changed (so the caller can `refresh()` the now-restapped caches).
    @discardableResult
    func adoptActiveDeviceId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != deviceId else { return false }
        deviceId = trimmed
        return true
    }

    #if DEBUG
    /// Inject a pre-opened store so unit tests can exercise the read facades (e.g. `timelineSeries`)
    /// against an in-memory `WhoopStore` without touching the on-disk path. DEBUG-only test seam.
    func setStoreForTesting(_ s: WhoopStore) { self.store = s }
    /// Inject a deterministic success/failure into the strict age-metric history read. The production
    /// path remains the real active/canonical store union.
    var reconciliationDailyMetricsReaderForTesting:
        ((String, String) async throws -> [DailyMetric])?
    /// Inject a deterministic source-read failure into the destructive-writeback preflight.
    var strictSleepSessionReaderForTesting:
        ((String, Int, Int, Int) async throws -> [CachedSleepSession])?
    #endif

    // MARK: - Union reads (active strap + canonical)
    //
    // Each helper reads the SAME store query across `importedReadIds` (active strap + canonical "my-whoop")
    // and concatenates the rows, ACTIVE STRAP FIRST. The callers feed the concatenated rows into the SAME
    // per-day dedup they already used (mergeDaily/mergeSleep key by day; the daily/series facades dedup
    // explicitly below), so per local-day the active-strap (live/measured) row wins over the canonical
    // (imported) one and nothing double-counts. A single-device install reads one id (the union collapses).

    /// Daily-metric rows across the imported union for a day range, DEDUPED per day with the ACTIVE STRAP
    /// winning over the canonical import (a live/measured row beats an imported one for the same day). The
    /// single returned row per day feeds the existing imported-vs-computed `mergeDaily` unchanged.
    private func unionDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in importedReadIds {   // active strap FIRST → it claims each column, canonical fills its gaps
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Strict union read for durable reconciliation jobs. Dashboard reads remain best-effort, but a
    /// watermark must never interpret a failed source query as valid missing history.
    private func unionDailyMetricsStrict(
        store: WhoopStore, from: String, to: String
    ) async throws -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in importedReadIds {
            for metric in try await store.dailyMetrics(deviceId: id, from: from, to: to) {
                byDay[metric.day] = byDay[metric.day].map {
                    Self.coalesceDay($0, metric)
                } ?? metric
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Fold two rows for the same day inside one source bucket without discarding useful columns.
    /// The earlier/high-precedence row keeps every value it actually carries (including a measured
    /// zero); the later row only fills nils. Sleep and raw SpO2 channels move as atomic groups so a
    /// total from one device can never be paired with stage/optical components from another device.
    nonisolated static func coalesceDay(_ winner: DailyMetric, _ filler: DailyMetric) -> DailyMetric {
        let sleepFromFiller = winner.totalSleepMin == nil && winner.efficiency == nil &&
            winner.deepMin == nil && winner.remMin == nil && winner.lightMin == nil &&
            winner.disturbances == nil
        let rawSpo2FromFiller = winner.spo2Red == nil && winner.spo2Ir == nil
        return DailyMetric(
            day: winner.day,
            totalSleepMin: sleepFromFiller ? filler.totalSleepMin : winner.totalSleepMin,
            efficiency: sleepFromFiller ? filler.efficiency : winner.efficiency,
            deepMin: sleepFromFiller ? filler.deepMin : winner.deepMin,
            remMin: sleepFromFiller ? filler.remMin : winner.remMin,
            lightMin: sleepFromFiller ? filler.lightMin : winner.lightMin,
            disturbances: sleepFromFiller ? filler.disturbances : winner.disturbances,
            restingHr: winner.restingHr ?? filler.restingHr,
            avgHrv: winner.avgHrv ?? filler.avgHrv,
            recovery: winner.recovery ?? filler.recovery,
            strain: winner.strain ?? filler.strain,
            exerciseCount: winner.exerciseCount ?? filler.exerciseCount,
            spo2Pct: winner.spo2Pct ?? filler.spo2Pct,
            skinTempDevC: winner.skinTempDevC ?? filler.skinTempDevC,
            respRateBpm: winner.respRateBpm ?? filler.respRateBpm,
            steps: winner.steps ?? filler.steps,
            activeKcalEst: winner.activeKcalEst ?? filler.activeKcalEst,
            spo2Red: rawSpo2FromFiller ? filler.spo2Red : winner.spo2Red,
            spo2Ir: rawSpo2FromFiller ? filler.spo2Ir : winner.spo2Ir,
            hrvMethod: winner.avgHrv == nil ? filler.hrvMethod : winner.hrvMethod
        )
    }

    /// metricSeries points across the imported union for a key + day range, DEDUPED per day with the active
    /// strap winning (same precedence as `unionDailyMetrics`).
    private func unionMetricSeries(store: WhoopStore, key: String, from: String, to: String) async -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for id in importedReadIds {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] where byDay[p.day] == nil {
                byDay[p.day] = p
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Sleep sessions across the imported union for a ts range, keeping ALL sessions per day (a nap + a main
    /// night both survive) and dropping only EXACT-duplicate blocks (same start+end) recorded under both
    /// union ids. The downstream `mergeSleep`/`userEditedDays` do the per-day collapse, exactly as before.
    private func unionSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: importedReadIds, from: from, to: to, limit: limit))
    }

    /// Computed ("-noop") daily-metric rows across the computed union, DEDUPED per day (active strap's
    /// computed sibling wins over the canonical computed sibling).
    private func unionComputedDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in computedReadIds {
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Computed ("-noop") sleep sessions across the computed union, keeping ALL sessions per day and dropping
    /// only EXACT-duplicate blocks recorded under both computed siblings.
    private func unionComputedSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: computedReadIds, from: from, to: to, limit: limit))
    }

    /// ALL sleep blocks across `ids` for a ts range, concatenated (NOT collapsed to one per day, used by
    /// `allSleepSessions`, which expands split sleeps). Active strap first.
    private func unionRawSleepBlocks(store: WhoopStore, ids: [String], from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        var blocks: [CachedSleepSession] = []
        for id in ids {
            blocks += (try? await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        return blocks
    }

    /// Best-effort source-preserving sleep read for presentation refreshes. Keeping the source partition
    /// until detailed-stage derivation prevents one band's evidence from authorizing another band's row.
    private func sleepSessionsBySource(
        store: WhoopStore,
        ids: [String],
        from: Int,
        to: Int,
        limit: Int = 4000
    ) async -> [String: [CachedSleepSession]] {
        var rows: [String: [CachedSleepSession]] = [:]
        for id in ids {
            rows[id] = (try? await store.sleepSessions(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        return rows
    }

    /// Best-effort source-preserving daily read. Local detailed-stage columns are replaced from the
    /// matching session payload before active/canonical coalescing.
    private func dailyMetricsBySource(
        store: WhoopStore,
        ids: [String],
        from: String,
        to: String
    ) async -> [String: [DailyMetric]] {
        var rows: [String: [DailyMetric]] = [:]
        for id in ids {
            rows[id] = (try? await store.dailyMetrics(
                deviceId: id, from: from, to: to)) ?? []
        }
        return rows
    }

    /// Throwing twin used before a destructive external-store migration. Reaching the query limit is
    /// treated as incomplete rather than silently truncating the replacement snapshot.
    private func strictSleepSessions(
        store: WhoopStore,
        ids: [String],
        from: Int,
        to: Int,
        limit: Int
    ) async throws -> [String: [CachedSleepSession]] {
        var bySource: [String: [CachedSleepSession]] = [:]
        for id in ids {
            let rows: [CachedSleepSession]
            #if DEBUG
            if let reader = strictSleepSessionReaderForTesting {
                rows = try await reader(id, from, to, limit)
            } else {
                rows = try await store.sleepSessions(
                    deviceId: id, from: from, to: to, limit: limit)
            }
            #else
            rows = try await store.sleepSessions(
                deviceId: id, from: from, to: to, limit: limit)
            #endif
            guard rows.count < limit else {
                throw RepositoryReadError.incompleteSleepSnapshot
            }
            bySource[id] = rows
        }
        return bySource
    }

    /// Strict learned-timing read for publication boundaries. `nil` is a valid cold-start result; a
    /// failed or truncated source read throws so callers can distinguish it from insufficient history.
    private func strictHabitualMidsleepSec(store: WhoopStore, days: Int = 4000) async throws -> Int? {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - days * 86_400
        let to = now + 86_400
        let limit = 100_000
        let imported = try await strictSleepSessions(
            store: store, ids: importedReadIds, from: from, to: to, limit: limit)
        let computed = try await strictSleepSessions(
            store: store, ids: computedReadIds, from: from, to: to, limit: limit)
        let sessions = Self.dedupBlocks(
            importedReadIds.flatMap { imported[$0] ?? [] }
                + computedReadIds.flatMap { computed[$0] ?? [] })
        return Self.historicalHabitualMidsleepSec(sessions)
    }

    /// Drop blocks that share a (startTs, endTs) key, the same physical session recorded under both union
    /// ids, keeping the first (active strap). Preserves genuinely distinct blocks (naps + main night).
    nonisolated private static func dedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<String>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = "\(b.startTs)-\(b.endTs)"
            if seen.insert(key).inserted { out.append(b) }
        }
        return out
    }

    /// Learn habitual midsleep with the UTC offset that applied to each historical session. Shifting each
    /// block into its historical local clock lets the shared circular learner run with offset zero while
    /// preserving durations. This fixes DST-boundary bucketing without changing its selection formula.
    nonisolated static func historicalHabitualMidsleepSec(
        _ sessions: [CachedSleepSession],
        timeZone: TimeZone = .current
    ) -> Int? {
        let blocks = sessions.compactMap { session -> SleepStageTotals.HistoryBlock? in
            let start = session.effectiveStartTs
            let end = session.endTs
            guard end > start else { return nil }
            let midpoint = start + (end - start) / 2
            let offset = timeZone.secondsFromGMT(
                for: Date(timeIntervalSince1970: TimeInterval(midpoint)))
            return SleepStageTotals.HistoryBlock(
                start: start + offset,
                end: end + offset,
                dayKey: AnalyticsEngine.dayString(midpoint, offsetSec: offset))
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: 0)
    }

    /// Imported/computed merge shared by tolerant screen reads and strict HealthKit snapshots. Reuse the
    /// canonical richness-aware policy so a sparse import cannot suppress a valid computed main night.
    nonisolated private static func mergeAllSleepSessions(
        imported: [CachedSleepSession],
        computed: [CachedSleepSession]
    ) -> [CachedSleepSession] {
        mergeSleep(imported: imported, computed: computed)
    }

    /// Drop workout rows that share a (startTs, endTs, sport, source) key, the same session recorded under
    /// both union device ids, keeping the first (active strap). Distinct sessions are preserved; the
    /// downstream `dedupCrossSource` still collapses strap-vs-Apple twins by time.
    nonisolated private static func dedupWorkoutsByNaturalKey(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        var out: [WorkoutRow] = []
        for r in rows {
            let key = "\(r.startTs)-\(r.endTs)-\(r.sport)-\(r.source)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    /// Latest HR-sample ts across the imported union, or nil. The auto-land Today anchor (#597) uses this,
    /// so a re-added strap's live raw AND the canonical history both count toward "the most recent data day".
    private func unionLatestHRSampleTs(store: WhoopStore) async -> Int? {
        var latest: Int?
        for id in importedReadIds {
            if let ts = (try? await store.latestHRSampleTs(deviceId: id)) ?? nil {
                latest = max(latest ?? ts, ts)
            }
        }
        return latest
    }

    /// Latest durable biometric frontier across the active strap and canonical imported source. This is
    /// intentionally an indexed MAX query, not a row count or history load, so diagnostics can prove whether
    /// collection is advancing even when a large local library is the reason the user is reporting a hang.
    func latestPersistedHRSampleTs() async -> Int? {
        guard let store = await ensureStore() else { return nil }
        return await unionLatestHRSampleTs(store: store)
    }

    /// Today's row, by the device's LOGICAL local day , NOT just the newest stored row, which after a
    /// historical import was months-old data shown as today's hero (issue #23). The logical day rolls at
    /// 04:00 local (see `logicalDayKey`), so between midnight and 4am we keep resolving the prior logical
    /// day's row instead of an empty new-calendar-day row that blanks the dashboard (#144). nil if no row
    /// for that day yet (the dashboard then shows its empty/pending state). Presentation-only , stored
    /// row keys are untouched.
    ///
    /// Non-UTC pre-04:00 carve-out (#304): a user who falls asleep before midnight and wakes before the
    /// 04:00 rollover has the just-finished night banked under the NEW local calendar day (sleep is keyed
    /// by the local wake-day , `mergeSleep` / IntelligenceEngine), while `logicalDayKey` still points at
    /// yesterday. Resolving strictly by logical day would then surface the PREVIOUS night. So: if the
    /// local calendar day differs from the logical day AND a row for the local day has a banked night
    /// (`totalSleepMin != nil`), prefer that row. Otherwise fall back to the logical-day row , which keeps
    /// the #144 anti-blank guard (no night banked yet ⇒ keep yesterday's logical row, never blank).
    var today: DailyMetric? {
        let now = Date()
        return Repository.resolveToday(days: days,
                                       logicalKey: Repository.logicalDayKey(now),
                                       localKey: Repository.localDayKey(now))
    }

    /// Strict civil-calendar today. Local-day trackers such as hydration must not inherit the dashboard's
    /// deliberate pre-04:00 carry-over row, because that would apply yesterday's Effort to today's goal.
    var localCalendarToday: DailyMetric? {
        let key = Repository.localDayKey(Date())
        return days.last(where: { $0.day == key })
    }

    /// Pure resolver behind `today` (extracted so the #304 boundary is testable without a live clock):
    /// prefer the LOCAL-calendar-day row when it differs from the logical day AND has a banked night
    /// (`totalSleepMin != nil`); otherwise the logical-day row (preserving the #144 anti-blank guard).
    /// `localKey == logicalKey` (the common daytime case) collapses to the plain logical-day lookup.
    nonisolated static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }

    /// #911: the SINGLE anchor every off-dashboard surface (Home/Lock widget, the watch snapshot AND the
    /// iOS Live Activity) resolves the row it describes through, so a fourth surface can never drift its
    /// own way again. Pure + injectable so the boundary is testable without a live clock.
    ///
    /// It is exactly what Today does: resolve today's row (`resolveToday`, which carries the #304 pre-04:00
    /// local-day carve-out and the #144 anti-blank guard), then use that row when it's scored, else carry
    /// over the freshest STRICTLY-PRIOR scored day for the recovery-derived fields. Anchoring on today's
    /// row (not "the newest row with any recovery score") is what fixes the rollover drift: the new logical
    /// day exists but isn't scored yet, and the old `days.last(where: recovery != nil)` still pointed at
    /// yesterday's scored row, so the widget/wrist/Live Activity showed the older day while Today had moved
    /// on. The `$0.day < carriedKey` bound (`carriedKey` = today's own key) mirrors
    /// `TodayView.lastScoredRecoveryDay` + its #547 future-day guard, so a stale or stray future-dated
    /// scored row can never re-surface AS today.
    nonisolated static func widgetAnchor(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        let todayRow = resolveToday(days: days, logicalKey: logicalKey, localKey: localKey)
        if todayRow?.recovery != nil { return todayRow }
        let carriedKey = todayRow?.day ?? logicalKey
        return days.last(where: { $0.recovery != nil && $0.day < carriedKey })
    }

    /// Live-clock convenience over the pure `widgetAnchor`: resolves the anchor for `now` (defaults to the
    /// current instant) so every surface's call site reads as one line and can never partially re-derive
    /// the keys and drift. Inherits `Repository`'s MainActor isolation (like the `today` computed var)
    /// because it reads the MainActor-isolated `logicalDayKey` / `localDayKey`; every caller (the widget
    /// publish, the watch snapshot build, the Live Activity onReceive closures) already runs on the
    /// MainActor. Tests call the pure 3-arg overload above instead.
    static func widgetAnchor(days: [DailyMetric], now: Date = Date()) -> DailyMetric? {
        widgetAnchor(days: days, logicalKey: logicalDayKey(now), localKey: localDayKey(now))
    }

    /// Pure bookkeeping for high-frequency live surfaces. It never drives an observable update.
    private var widgetAnchorMemo = WidgetAnchorMemo()

    /// Resolve the shared widget/watch/Live Activity row once per repository refresh or day-key rollover.
    /// Live HR can arrive several times per second, while both the data and selected day usually remain
    /// unchanged for minutes; keeping the full-history scans out of that path protects the main actor.
    func cachedWidgetAnchor(now: Date = Date()) -> DailyMetric? {
        widgetAnchorMemo.resolve(
            days: days,
            seq: refreshSeq,
            logicalKey: Self.logicalDayKey(now),
            localKey: Self.localDayKey(now)
        ) { Self.widgetAnchor(days: $0, logicalKey: $1, localKey: $2) }
    }

    /// The recovery-INDEPENDENT overnight-vitals carry (the durable fix for the v8 Today rollover blank):
    /// the freshest strictly-prior day that recorded any of HRV / resting HR / respiratory, so the recovery
    /// VITALS keep reading through the post-04:00 window before tonight's sleep is scored, WITHOUT being
    /// gated on the prior night's recovery (a night with real HRV/RHR but null recovery is a valid source
    /// here, unlike `widgetAnchor`/`lastScoredRecoveryDay`). It is only the fallback — call sites read each
    /// vital today-first (`displayDay?.field ?? vitalsDay?.field`), so today's own value always wins.
    ///
    /// `todayKey` is the future-clock-safe today key — the LATER of the logical/local day key, exactly like
    /// `widgetAnchor`'s `carriedKey` — so a device whose local calendar has already ticked past the logical
    /// day still bounds the carry at true "today" and can't pick up today's own still-forming row. The pure
    /// filter lives on `DailyMetric` (package-side, unit-tested headlessly via `swift test`). Strictly a
    /// vitals selector: it must NEVER feed Charge/Effort/Rest or any recovery/strain-derived surface.
    static func lastVitalsDay(days: [DailyMetric], now: Date = Date()) -> DailyMetric? {
        lastVitalsDay(days: days, todayKey: max(logicalDayKey(now), localDayKey(now)))
    }

    /// Explicit-`todayKey` overload for call sites that already hold the resolved today key (e.g. Today,
    /// which passes `displayDay?.day ?? selectedDayKey`). Forwards to the pure package selector. Pass the
    /// future-clock-safe key (the later of logical/local) so the `< todayKey` bound is honest.
    nonisolated static func lastVitalsDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastVitalsDay(days: days, todayKey: todayKey)
    }

    /// PER-FIELD SpO₂ carry — the twin of `lastVitalsDay(days:todayKey:)` for the field its predicate does
    /// NOT check. The engine writes `spo2Pct = nil` on computed rows (only imported rows carry a percentage),
    /// so a whole-row carry lands on a null `spo2Pct`; this resolves the freshest strictly-prior row that
    /// actually has one. Forwards to the pure package selector — pass the future-clock-safe key (the later of
    /// logical/local) so the `< todayKey` bound is honest. See `DailyMetric.lastSpo2Day`.
    nonisolated static func lastSpo2Day(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastSpo2Day(days: days, todayKey: todayKey)
    }

    /// PER-FIELD skin-temperature-deviation carry — twin of the above. See `DailyMetric.lastSkinTempDay`.
    nonisolated static func lastSkinTempDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastSkinTempDay(days: days, todayKey: todayKey)
    }
    /// The trailing 7 CALENDAR days ending today (for the week strip), oldest→newest , not the last 7
    /// stored rows, which on a stale import were old data. ISO yyyy-MM-dd compares chronologically.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// Source-aware rows for vital-sign cards. During previews/tests that set `days` directly,
    /// fall back to the merged local cache so the component still renders.
    var vitalMetricRows: [SourcedDailyMetric] {
        vitalRows.isEmpty ? days.map { SourcedDailyMetric(metric: $0, source: .localCache) } : vitalRows
    }

    /// Canonical source ids the resolver knows how to cross-reference. The strap's actual id is
    /// `deviceId` (and its computed sibling `deviceId + "-noop"`); these are the FIXED ids.
    nonisolated static let whoopSource = "my-whoop"
    nonisolated static let appleHealthSource = "apple-health"
    nonisolated static let healthConnectSource = "health-connect"
    nonisolated static let activityFileSource = "activity-file"

    /// Imported wearable-export sources whose DAILY aggregates (HRV / resting HR / sleep) can be scored
    /// for a NOOP Charge/Rest on an import-only day, exactly like a live day (#823). These carry no raw HR
    /// stream, so the source-only fold in IntelligenceEngine scores them from the daily aggregate vs the
    /// person's own baseline. Matches `WearableBrand.sourceId` plus Health Connect (Android imports HC's
    /// daily metrics under the strap source, but a sideloaded/standalone HC source id is covered too).
    static let wearableImportSources = ["oura-import", "fitbit-import", "garmin-import", "oura-api", healthConnectSource]

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    nonisolated static let logicalDayRolloverHour = 4

    /// The LOGICAL local day for `now` , the calendar date of `now - rolloverHour hours`. Rolls at
    /// 04:00 local rather than midnight, so the small hours after midnight still resolve to the prior
    /// calendar date's row instead of an empty new-calendar-day row (#144). Pure + injectable so the
    /// boundary is testable (23:59 → same day, 01:00 → previous day, 04:01 → new day). Presentation-only:
    /// used solely to pick which stored row is Today and to anchor the Today HR-trend window start; stored
    /// row keys are never rewritten.
    static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        localDayKey(logicalDay(now, rolloverHour: rolloverHour))
    }

    /// Start of the logical day (its real calendar midnight) for `now`, in `calendar`'s zone , the anchor
    /// for the Today HR-trend window so it spans from the logical day's 00:00 rather than restarting at the
    /// new calendar midnight while we're still showing yesterday's logical day in the small hours (#144).
    static func logicalDayStart(_ now: Date, calendar: Calendar = .current,
                                rolloverHour: Int = logicalDayRolloverHour) -> Date {
        calendar.startOfDay(for: logicalDay(now, rolloverHour: rolloverHour))
    }

    /// In-flight open, so concurrent first-callers share ONE open instead of each opening their own.
    private var storeOpenTask: Task<WhoopStore?, Never>?

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        // SINGLE-FLIGHT (measured 2026-07-01 on a 5M-row DB): several screens ask for the store at once
        // on launch (RootView refresh, AppModel init, exploreSeries). ensureStore is async and `store`
        // is not set until after the `await WhoopStore(path:)` below, so without this guard every caller
        // races past the `if let store` check while the others are awaiting the open, and they ALL open a
        // fresh connection and re-run quarantineIncompatibleDatabase (a thundering herd of DB opens on a
        // large library at the worst moment). Cache the in-flight open Task so concurrent callers join it.
        if let storeOpenTask { return await storeOpenTask.value }
        let openTrace = AppDiagnosticsRecorder.shared.beginOperation("database.open")
        let task = Task { [deviceId, openTrace] () -> WhoopStore? in
            var outcome = "failed"
            var failureKind: String?
            defer {
                AppDiagnosticsRecorder.shared.endOperation(
                    openTrace,
                    outcome: outcome,
                    fields: failureKind.map { ["failure_kind": $0] } ?? [:],
                    includeResourceSnapshot: true
                )
            }
            // Don't swallow the open failure with `try?` (#222): an import-time open failure (e.g. the iOS
            // data-protected store while the device is locked) was previously invisible, surfacing only as
            // a generic "Couldn't open the local store." Log the real error so the cause is diagnosable.
            let path: String
            do {
                path = try StorePaths.defaultDatabasePath()
            } catch {
                outcome = "path_failed"
                failureKind = AppDiagnosticsRecorder.failureKind(error)
                return nil
            }
            let s: WhoopStore
            do {
                s = try await WhoopStore(path: path)
            } catch {
                outcome = "open_failed"
                failureKind = AppDiagnosticsRecorder.failureKind(error)
                return nil
            }
            try? await s.upsertDevice(id: deviceId, mac: nil, name: "Compatible band")
            outcome = "opened"
            return s
        }
        storeOpenTask = task
        let opened = await task.value
        if let opened { store = opened }
        storeOpenTask = nil
        return opened
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// CAPTURE-D (#797): the on-device DATA VOLUME read FRESH from the STORE (never the `@Published`
    /// dashboard caches), for the Display & Performance test mode's `dataVolume` line. dbRows is the raw
    /// decoded-stream footprint; importedDays is the count of imported daily-metric rows under the active
    /// strap id (the #799 import surface, the SAME `deviceId` rows `importedDays` is derived from);
    /// workouts is the recorded/detected workout-row count. Resolves the active strap id from `deviceId`
    /// (already re-pointed to the registry's activeDeviceId, #814) so it reads the right source, not the
    /// hardcoded legacy id. Returns nil when the store can't be opened. Pure store reads; no merge, no
    /// scoring, no @Published mutation, so calling it never perturbs the screens it is measuring.
    func dataVolumeSnapshot() async -> DataVolume? {
        guard let store = await ensureStore() else { return nil }
        let dbRows = (try? await store.storageStats().decodedRows) ?? 0
        // Imported daily-metric rows live under the UNION of the active strap + the canonical "my-whoop"
        // (computed scores are merged UNDER them from the computed siblings). A wide day range covers the
        // full local-history span an import can carry. Union-deduped per day so a re-add's history still counts.
        let imported = await unionDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        // Whole recordable epoch in unix seconds [0, ~2^31) so every recorded workout row is counted.
        var workouts: [WorkoutRow] = []
        for id in importedReadIds { workouts += (try? await store.workouts(deviceId: id, from: 0, to: 4_102_444_800, limit: 1_000_000)) ?? [] }
        workouts = Self.dedupWorkoutsByNaturalKey(workouts)
        // lastRenderRows = the size of the merged DAILY set the dashboard list/charts actually render: the
        // union of distinct days across the three daily sources (imported strap + on-device computed + Apple)
        // over the full local-history window. This is the read-set whose size drives the post-import list/
        // chart lag (#797) - so the trace pairs frame stats with "how many rows it was rendering over".
        let computed = await unionComputedDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: "0000-01-01", to: "9999-12-31")) ?? []
        var renderDays = Set<String>()
        for m in imported { renderDays.insert(m.day) }
        for m in computed { renderDays.insert(m.day) }
        for m in apple { renderDays.insert(m.day) }
        return DataVolume(dbRows: dbRows, importedDays: imported.count,
                          workouts: workouts.count, lastRenderRows: renderDays.count)
    }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet , the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// One refresh's fully-merged dashboard caches, computed OFF the main actor (FIX 3) and applied to the
    /// `@Published` props in a single main-actor batch. Every member is an `Equatable` value type. NOT
    /// marked `Sendable` (its `DailyMetric`/`CachedSleepSession` members aren't formally `Sendable`); it
    /// crosses the `Task.detached` boundary the same way the engine's `DayResult` already does under this
    /// project's `minimal` strict-concurrency setting (SWIFT_STRICT_CONCURRENCY: minimal, Swift 5 mode).
    private struct MergedCaches {
        let importedSleep: [String: ImportedSleepFigures]
        let days: [DailyMetric]
        let sleeps: [CachedSleepSession]
        let editedSleepDays: Set<String>
        let vitalRows: [SourcedDailyMetric]
        let freshness: RepositoryFreshness
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    ///
    /// FIX 3: a fresh-import / first-launch analyze tail fires `refresh()` many times in quick succession.
    /// Two costs made each one expensive: (1) the `mergeDaily`/`mergeSleep`/`sourceRows` O(n log n) sorts
    /// ran on the MAIN actor over thousands of rows, and (2) `refreshSeq` bumped UNCONDITIONALLY, so every
    /// bump re-fired `TodayView.loadAll()` (~28 sequential reads + 28 @State writes) even when nothing
    /// changed. Now the sorts run in a detached task and the merged result is DIFFED against the current
    /// caches , when nothing changed we skip BOTH the re-publish and the `refreshSeq` bump, so the redundant
    /// tail refreshes don't each detonate a full Today reload. The "one consistent publish per refresh"
    /// guarantee is kept: on a real change every prop + the seq are assigned in ONE main-actor batch.
    /// Monotonic ordering token (#review): refresh() now suspends on an off-actor merge between the store
    /// reads and the publish, so two overlapping refresh() calls (e.g. a 120-day backfill refresh and the
    /// 4000-day analyze-tail refresh) could resume + publish OUT OF ORDER, an older stale merge clobbering a
    /// newer one. Each call captures the token at entry and only publishes if it is still the latest. Not
    /// @Published (pure ordering, never drives the UI); race-free since Repository is @MainActor.
    private var refreshGen = 0

    /// #849: the `refreshSeq` value at which Today last ran its heavy history-wide reload (the ~40 reads +
    /// per-day raw-HR pass). Lives HERE, on the long-lived Repository, not in TodayView's `@State`, so it
    /// SURVIVES a Today re-mount (tab-away + return / an Apple-Health import that recreates the view). A bare
    /// re-mount resets TodayView's `@State` but `refreshSeq` is unchanged, so the screen re-ran the full
    /// reload for byte-identical data every time. Today now compares this against the live `refreshSeq` and
    /// skips the reload when nothing has changed since it last loaded. `-1` = never loaded this launch, so the
    /// first load (seq 0) always runs. Not @Published (pure load-bookkeeping, never drives the UI).
    var todayHistoryWideLoadedSeq = -1
    /// #849: the last history-wide snapshot Today built, so a re-mount can RESTORE it (in-memory, no queries)
    /// instead of re-running the heavy reload. Paired with `todayHistoryWideLoadedSeq`. Not @Published.
    var todayHistoryWideCache: TodayHistoryWideCache?

    /// #833 (Insights freeze): macOS destroys + cold-mounts the NavigationSplitView detail on every sidebar
    /// switch (RootView keys it with `.id`), so InsightsView's `@State` is torn down each time and its
    /// `load()` re-read full history off the @MainActor on every visit. Mirroring Today's #849 marker, this
    /// is the `refreshSeq` value at which Insights last ran its heavy load. Lives HERE on the long-lived
    /// Repository so it SURVIVES the re-mount; `-1` = never loaded this launch, so the first load always runs.
    /// Not @Published (pure load-bookkeeping, never drives the UI).
    var insightsLoadedSeq = -1
    /// #833: the dayKey Insights last loaded for, paired with `insightsLoadedSeq`. A day rollover (the journal
    /// chips re-key on it) must still re-load even at an unchanged `refreshSeq`, so the cache only short-
    /// circuits when BOTH the seq AND this dayKey match the current load. Not @Published.
    var insightsLoadedDayKey = ""
    /// #833: the computed dictionaries + activity costs InsightsView.load() last built, so a same-seq re-mount
    /// RESTORES them in-memory (no store queries) instead of re-running the heavy load. Not @Published.
    var insightsCache: InsightsLoadCache?

    /// #833/v7.7.2 (Apple Health per-source freeze): macOS cold-mounts the NavigationSplitView detail on every
    /// sidebar switch (RootView keys it with `.id`), tearing down AppleHealthView's `@State` so its `load()`
    /// re-read the whole apple-health history off the @MainActor every visit. The exact twin of the Insights
    /// trio above: these live HERE on the long-lived Repository so they SURVIVE the re-mount. `-1` / "" = never
    /// loaded this launch, so the first load always runs. Not @Published (pure load-bookkeeping, never drives
    /// the UI).
    var appleHealthLoadedSeq = -1
    /// #833/v7.7.2: the dayKey Apple Health last loaded for, paired with `appleHealthLoadedSeq`; a day rollover
    /// re-loads even at an unchanged seq. Not @Published.
    var appleHealthLoadedDayKey = ""
    /// #833/v7.7.2: the snapshot AppleHealthView.load() last built, so a same-seq re-mount RESTORES it
    /// in-memory (no store queries) instead of re-running the heavy load. Not @Published.
    var appleHealthCache: AppleHealthLoadCache?

    /// #849/#932 (Today day-scoped freeze): macOS cold-mounts the NavigationSplitView detail on every sidebar
    /// switch, so `TodayView.loadDayScoped()` re-ran its full-day heavy read (the selected day's 5-minute
    /// `hrBuckets` plus, on today, the raw per-sample `hrSamples` pass for the live Effort; 170k+ HR rows/day
    /// on a big library) on every visit even when nothing changed. The exact twin of the trios above: this is
    /// the `refreshSeq` value at which Today last ran its DAY-SCOPED load. Lives HERE on the long-lived
    /// Repository so it SURVIVES the re-mount. `-1` = never loaded this launch, so the first load always runs.
    /// Not @Published (pure load-bookkeeping, never drives the UI).
    var todayDayScopedLoadedSeq = -1
    /// #932: the day key the day-scoped set last loaded FOR (the VIEWED day, `TodayView.selectedDayKey`), so
    /// day navigation can never serve another day's snapshot: swiping to a different day misses (its key
    /// differs) and genuinely re-loads, and a day rollover re-loads even at an unchanged seq. Not @Published.
    var todayDayScopedLoadedDayKey = ""
    /// #932: the snapshot `loadDayScoped()` last built, so a same-(seq, day) re-mount RESTORES it in-memory
    /// (no store queries, no hrBuckets/hrSamples reads) instead of re-running the heavy load. Not @Published.
    var todayDayScopedCache: TodayDayScopedCache?

    #if DEBUG
    /// v7.7.2 regression guard: DEBUG-only tally of how many times each cached heavy load actually ran its
    /// store reads (keyed "appleHealth" / "xiaomi" / "todayDayScoped"). A same-state re-mount that restores
    /// from cache must NOT increment this, so a test can assert the cold-mount short-circuit holds.
    /// DEBUG-only, never shipped.
    var loadFireCounts: [String: Int] = [:]
    #endif

    func refresh(days nDays: Int = 4000) async {
        let refreshTrace = AppDiagnosticsRecorder.shared.beginOperation(
            "repository.refresh",
            fields: ["requested_days": String(nDays)]
        )
        var diagnosticOutcome = "store_unavailable"
        var diagnosticFields: [String: String] = [:]
        defer {
            AppDiagnosticsRecorder.shared.endOperation(
                refreshTrace,
                outcome: diagnosticOutcome,
                fields: diagnosticFields,
                includeResourceSnapshot: true
            )
        }
        guard let store = await ensureStore() else { return }
        diagnosticOutcome = "reading"
        refreshGen &+= 1
        let myGen = refreshGen
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        // UNION the active strap (live raw, #814) with the canonical "my-whoop" import so a re-added strap's
        // live data AND the canonical history both surface, deduped per day (active strap wins). Collapses to
        // a single id on a single-device install (byte-identical to before).
        let imported = await unionDailyMetrics(store: store, from: fromDay, to: toDay)
        let computedDailyBySource = await dailyMetricsBySource(
            store: store, ids: computedReadIds, from: fromDay, to: toDay)
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: fromDay, to: toDay)) ?? []
        let activityFile = (try? await store.dailyMetrics(deviceId: Self.activityFileSource, from: fromDay, to: toDay)) ?? []
        AppDiagnosticsRecorder.shared.record(
            "repository.refresh.checkpoint",
            fields: [
                "stage": "daily_loaded",
                "imported_rows": String(imported.count),
                "computed_rows": String(computedDailyBySource.values.reduce(0) { $0 + $1.count }),
                "apple_rows": String(apple.count),
                "activity_rows": String(activityFile.count),
            ]
        )
        let importedSleepBySource = await sleepSessionsBySource(
            store: store, ids: importedReadIds, from: lo, to: hi)
        let computedSleepBySource = await sleepSessionsBySource(
            store: store, ids: computedReadIds, from: lo, to: hi)
        let importedSourceOrder = importedReadIds
        let computedSourceOrder = computedReadIds
        let impSleep = Self.dedupBlocks(
            importedSourceOrder.flatMap { importedSleepBySource[$0] ?? [] })
        let compSleep = Self.dedupBlocks(
            computedSourceOrder.flatMap { computedSleepBySource[$0] ?? [] })
        AppDiagnosticsRecorder.shared.record(
            "repository.refresh.checkpoint",
            fields: [
                "stage": "sleep_loaded",
                "imported_sessions": String(impSleep.count),
                "computed_sessions": String(compSleep.count),
            ]
        )

        // Export-verbatim sleep figures (long-format metricSeries rows from WhoopImporter).
        // SleepView prefers these per day over its APPROXIMATE recomputations.
        let perf = await unionMetricSeries(store: store, key: "sleep_performance", from: fromDay, to: toDay)
        let cons = await unionMetricSeries(store: store, key: "sleep_consistency", from: fromDay, to: toDay)
        let need = await unionMetricSeries(store: store, key: "sleep_need_min", from: fromDay, to: toDay)
        let debt = await unionMetricSeries(store: store, key: "sleep_debt_min", from: fromDay, to: toDay)
        AppDiagnosticsRecorder.shared.record(
            "repository.refresh.checkpoint",
            fields: [
                "stage": "sleep_metrics_loaded",
                "series_rows": String(perf.count + cons.count + need.count + debt.count),
            ]
        )

        // Merge + sort OFF the main actor (FIX 3): the figures build, the two O(n log n) daily/sleep merges,
        // the source-row sort, and the freshness counts are all pure over the rows just read, so they run in
        // a detached task and the main actor stays free for SwiftUI during a deep-history refresh.
        let merged: MergedCaches = await Task.detached(priority: .utility) {
            let habitualMidsleep = Self.historicalHabitualMidsleepSec(
                Self.dedupBlocks(impSleep + compSleep))
            let detailedBySource = Dictionary(
                uniqueKeysWithValues: computedSourceOrder.map { id in
                    (
                        id,
                        Self.publishableDetailedStageMinutesByDay(
                            computedSleepBySource[id] ?? [],
                            habitualMidsleepSec: habitualMidsleep)
                    )
                })
            var computedByDay: [String: DailyMetric] = [:]
            for id in computedSourceOrder {
                for row in computedDailyBySource[id] ?? [] {
                    let sanitized = Self.replacingDetailedStageColumns(
                        row,
                        with: detailedBySource[id]?[row.day])
                    computedByDay[row.day] = computedByDay[row.day].map {
                        Self.coalesceDay($0, sanitized)
                    } ?? sanitized
                }
            }
            let computed = computedByDay.values.sorted { $0.day < $1.day }
            var fig: [String: ImportedSleepFigures] = [:]
            for p in perf { fig[p.day, default: ImportedSleepFigures()].performancePct = p.value }
            for p in cons { fig[p.day, default: ImportedSleepFigures()].consistencyPct = p.value }
            for p in need { fig[p.day, default: ImportedSleepFigures()].needMin = p.value }
            for p in debt { fig[p.day, default: ImportedSleepFigures()].debtMin = p.value }
            // H5 (#509): a night the user hand-edited (userEdited) must keep its corrected sleep figures even
            // when a WHOOP/Apple import also covers that day. The computed ("-noop") session carries the edit,
            // and IntelligenceEngine re-keys the computed DAILY row from it; collect those edited days so the
            // merge lets the computed row's SLEEP fields win there (imports still win on every un-edited day).
            let editedDays = Self.userEditedDays(computedSleepBySource)
            return MergedCaches(
                importedSleep: fig,
                days: Self.mergeActivityFileSteps(
                    into: Self.mergeDaily(imported: imported, computed: computed, userEditedDays: editedDays),
                    activityFile
                ),
                sleeps: Self.mergeSleep(imported: impSleep, computed: compSleep),
                editedSleepDays: editedDays,
                vitalRows: Self.sourceRows(imported: imported, computed: computed, apple: apple),
                freshness: Self.computeFreshness(imported: imported, computed: computed, apple: apple,
                                                 importedSleeps: impSleep, computedSleeps: compSleep))
        }.value
        AppDiagnosticsRecorder.shared.record(
            "repository.refresh.checkpoint",
            fields: [
                "stage": "merge_completed",
                "days": String(merged.days.count),
                "sleeps": String(merged.sleeps.count),
            ]
        )

        // Generation guard (#review): if a newer refresh() started while this one merged off-actor, drop
        // this now-stale result so it can't clobber the newer caches or re-fire loadAll out of order.
        guard myGen == refreshGen else {
            diagnosticOutcome = "superseded"
            return
        }

        // DIFF before publishing (FIX 3): if this refresh produced byte-identical caches AND we've already
        // loaded once, skip the re-publish and the `refreshSeq` bump entirely , assigning an equal value to
        // an @Published prop still fires objectWillChange, so the skip must cover the assignments too. This
        // is what stops the analyze-tail's burst of refresh() calls each re-firing TodayView.loadAll().
        let unchanged = loaded
            && merged.days == days
            && merged.sleeps == sleeps
            && merged.editedSleepDays == editedSleepDays
            && merged.importedSleep == importedSleep
            && merged.vitalRows == vitalRows
            && merged.freshness == freshness
        guard !unchanged else {
            diagnosticOutcome = "unchanged"
            diagnosticFields = [
                "days": String(merged.days.count),
                "sleeps": String(merged.sleeps.count),
            ]
            return
        }

        // One consistent publish per refresh: assign every cache, flip `loaded`, then bump `refreshSeq` so
        // the intraday-updating views reload exactly once for this real change.
        self.importedSleep = merged.importedSleep
        self.days = merged.days
        self.sleeps = merged.sleeps
        self.editedSleepDays = merged.editedSleepDays
        self.vitalRows = merged.vitalRows
        self.freshness = merged.freshness
        self.loaded = true
        self.refreshSeq += 1
        diagnosticOutcome = "published"
        diagnosticFields = [
            "days": String(merged.days.count),
            "sleeps": String(merged.sleeps.count),
            "vital_rows": String(merged.vitalRows.count),
        ]
    }

    /// Per-source coverage counts for the Freshness Pipeline card. Pure over the rows already read.
    /// `nonisolated` (FIX 3) so `refresh()`'s detached merge task can call it off the main actor.
    nonisolated private static func computeFreshness(imported: [DailyMetric], computed: [DailyMetric],
                                         apple: [DailyMetric], importedSleeps: [CachedSleepSession],
                                         computedSleeps: [CachedSleepSession]) -> RepositoryFreshness {
        let days = (imported + computed + apple).map(\.day)
        return RepositoryFreshness(
            importedDays: imported.count,
            computedDays: computed.count,
            appleDays: apple.count,
            importedSleeps: importedSleeps.count,
            computedSleeps: computedSleeps.count,
            earliestDay: days.min(),
            latestDay: days.max()
        )
    }

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields.
    /// This preserves official export/import values while allowing fresh local analysis to populate
    /// Charge, skin temperature deviation, activity totals, or other fields missing from that row.
    ///
    /// H5 (#509): a day in `userEditedDays` is one the user hand-edited the sleep of (a corrected
    /// bed/wake time, an added nap, a deleted night). For those days the COMPUTED row's SLEEP fields
    /// take precedence over the import , otherwise a re-imported WHOOP/Apple night would silently mask
    /// the user's correction. Non-sleep fields (recovery/strain/HRV/RHR/activity…) still follow the
    /// normal imports-win merge, and every NON-edited day is unchanged.
    nonisolated static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric],
                                       userEditedDays: Set<String> = []) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                let merged = d.fillingNilFields(from: existing)
                byDay[d.day] = userEditedDays.contains(d.day)
                    ? merged.takingSleepFields(from: existing)   // edited night: computed sleep wins
                    : merged
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    nonisolated static func mergeActivityFileSteps(into base: [DailyMetric],
                                                   _ activityFile: [DailyMetric]) -> [DailyMetric] {
        guard !activityFile.isEmpty else { return base }
        // Last-wins on a duplicate day rather than `uniqueKeysWithValues`, which TRAPS (crashes) if `base`
        // ever carries two rows for one day. Matches the Kotlin twin's graceful merge and this file's own
        // safe convention (the other `Dictionary(…, uniquingKeysWith:)` builders here).
        var byDay = Dictionary(base.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        for row in activityFile {
            guard let steps = row.steps, steps > 0 else { continue }
            if let existing = byDay[row.day] {
                if existing.steps == nil {
                    byDay[row.day] = DailyMetric(
                        day: existing.day,
                        totalSleepMin: existing.totalSleepMin,
                        efficiency: existing.efficiency,
                        deepMin: existing.deepMin,
                        remMin: existing.remMin,
                        lightMin: existing.lightMin,
                        disturbances: existing.disturbances,
                        restingHr: existing.restingHr,
                        avgHrv: existing.avgHrv,
                        recovery: existing.recovery,
                        strain: existing.strain,
                        exerciseCount: existing.exerciseCount,
                        spo2Pct: existing.spo2Pct,
                        skinTempDevC: existing.skinTempDevC,
                        respRateBpm: existing.respRateBpm,
                        steps: steps,
                        activeKcalEst: existing.activeKcalEst,
                        spo2Red: existing.spo2Red,
                        spo2Ir: existing.spo2Ir,
                        hrvMethod: existing.hrvMethod
                    )
                }
            } else {
                byDay[row.day] = row
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The set of LOCAL wake-days that carry a user-edited sleep session, keyed exactly as
    /// `DailyMetric.day` is (the engine's cached-offset local-day keyer, matching `mergeSleep.endDay`).
    /// This overload preserves source ownership so fragments from different devices can never bridge.
    nonisolated static func userEditedDays(
        _ sessionsBySource: [String: [CachedSleepSession]]
    ) -> Set<String> {
        sessionsBySource.values.reduce(into: Set<String>()) { days, sessions in
            days.formUnion(userEditedDays(sessions))
        }
    }

    /// Drives the H5 edit-merge precedence in `mergeDaily` for one complete source timeline.
    nonisolated static func userEditedDays(_ sessions: [CachedSleepSession]) -> Set<String> {
        var days = Set<String>()
        // Bridge every complete source timeline before assigning the wake day. An edited fragment that
        // ends before midnight may be the first half of a night whose unedited continuation wakes after
        // midnight; fragment-first attribution would give the edit precedence on the wrong daily row.
        for bucket in wakeDaySessionBuckets(sessions)
            where bucket.sessions.contains(where: \.userEdited) {
            days.insert(bucket.day)
        }
        return days
    }

    /// Daily rows tagged with the source that supplied them, for the source-aware vital-sign cards.
    /// One entry per (source, day) , the consumer resolves precedence per metric (imported > computed
    /// > Apple); ordered by day, then source priority, so a stable list reaches the UI.
    /// `nonisolated` (FIX 3) so `refresh()`'s detached merge task can call it off the main actor.
    nonisolated private static func sourceRows(imported: [DailyMetric], computed: [DailyMetric],
                                   apple: [DailyMetric]) -> [SourcedDailyMetric] {
        (imported.map { SourcedDailyMetric(metric: $0, source: .whoopImport) }
            + computed.map { SourcedDailyMetric(metric: $0, source: .noopComputed) }
            + apple.map { SourcedDailyMetric(metric: $0, source: .appleHealth) })
            .sorted { lhs, rhs in
                if lhs.metric.day == rhs.metric.day {
                    return lhs.source.vitalPriority < rhs.source.vitalPriority
                }
                return lhs.metric.day < rhs.metric.day
            }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    /// Keys through `AnalyticsEngine.dayString(_:offsetSec:)` , the canonical LOCAL-day keyer
    /// `analyzeDay` attributes sessions with , NOT the unzoned `Repository.dayFormatter`, which formats
    /// in whatever the live device zone is and so disagreed with the engine's cached-offset attribution
    /// across a midnight boundary for non-UTC users (the Swift half of #406; mirrors the Android #304 fix
    /// pinned by MergeSleepLocalDayTest).
    nonisolated static func mergeSleep(
        imported: [CachedSleepSession],
        computed: [CachedSleepSession]
    ) -> [CachedSleepSession] {
        func fallbackEndDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        func wakeDays(_ sessions: [CachedSleepSession]) -> [SleepSessionIdentity: String] {
            var result: [SleepSessionIdentity: String] = [:]
            for bucket in wakeDaySessionBuckets(sessions) {
                for session in bucket.sessions {
                    result[SleepSessionIdentity(session)] = bucket.day
                }
            }
            return result
        }
        let importedWakeDays = wakeDays(imported)
        let computedWakeDays = wakeDays(computed)
        // #715, preserve EVERY session (a day with a main night + a nap must keep both); imported still
        // wins per end-day. Shared, unit-tested grouping (WhoopStore.SleepMerge / SleepMergeTests) replaces
        // the old per-day dictionary that silently dropped a second same-day session.
        return SleepMerge.merge(
            imported: imported,
            computed: computed,
            importedEndDay: {
                importedWakeDays[SleepSessionIdentity($0)] ?? fallbackEndDay($0)
            },
            computedEndDay: {
                computedWakeDays[SleepSessionIdentity($0)] ?? fallbackEndDay($0)
            })
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return await unionDailyMetrics(store: store, from: fromDay, to: toDay)
    }

    /// Throwing counterpart for jobs that persist a "fully reconciled" marker. An empty result is valid;
    /// unavailable storage or any failed active/canonical query must be retried later.
    func dailyMetricsForReconciliation(
        fromDay: String, toDay: String
    ) async throws -> [DailyMetric] {
        #if DEBUG
        if let reader = reconciliationDailyMetricsReaderForTesting {
            return try await reader(fromDay, toDay)
        }
        #endif
        guard let store = await ensureStore() else {
            throw RepositoryReadError.storeUnavailable
        }
        return try await unionDailyMetricsStrict(store: store, from: fromDay, to: toDay)
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical so the HR trend renders whether the landed day's raw sits under
        // the re-added strap (live) or the canonical history. Deduped by ts (active strap wins) so an overlap
        // never double-counts; sorted ascending. Single-device install reads one id (byte-identical).
        guard deviceId != canonicalDeviceId else {
            return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }
        var byTs: [Int: HRSample] = [:]
        for id in importedReadIds {
            for s in (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [] where byTs[s.ts] == nil {
                byTs[s.ts] = s
            }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Clean R-R intervals over the active-strap/canonical union. Earlier source ids win, while a
    /// multiset merge preserves legitimate equal intervals emitted within the same whole-second stamp.
    func rrIntervals(from: Int, to: Int, limit: Int = 200_000) async -> [RRInterval] {
        guard let store = await ensureStore() else { return [] }
        guard deviceId != canonicalDeviceId else {
            return (try? await store.rrIntervals(
                deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }

        struct Key: Hashable {
            let ts: Int
            let rrMs: Int
            let source: Int?
        }

        var merged: [(order: Int, sample: RRInterval)] = []
        var maxOccurrences: [Key: Int] = [:]
        var order = 0
        for id in importedReadIds {
            let rows = (try? await store.rrIntervals(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
            var sourceOccurrences: [Key: Int] = [:]
            for sample in rows {
                let key = Key(
                    ts: sample.ts,
                    rrMs: sample.rrMs,
                    source: sample.srcChannel?.rawValue)
                let occurrence = sourceOccurrences[key, default: 0] + 1
                sourceOccurrences[key] = occurrence
                if occurrence > maxOccurrences[key, default: 0] {
                    merged.append((order, sample))
                    order += 1
                }
            }
            for (key, count) in sourceOccurrences {
                maxOccurrences[key] = max(maxOccurrences[key, default: 0], count)
            }
        }
        return merged
            .sorted { ($0.sample.ts, $0.order) < ($1.sample.ts, $1.order) }
            .map(\.sample)
    }

    /// Raw motion over the active-strap/canonical union, de-duplicated by timestamp with the active
    /// device winning. Auto-workout confirmation uses this when the device actually banks motion;
    /// HR-only devices simply return an empty list and retain the conservative HR fallback.
    func gravitySamples(from: Int, to: Int, limit: Int = 200_000) async -> [GravitySample] {
        guard let store = await ensureStore() else { return [] }
        guard deviceId != canonicalDeviceId else {
            return (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }
        var byTs: [Int: GravitySample] = [:]
        for id in importedReadIds {
            let rows = (try? await store.gravitySamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
            for row in rows where byTs[row.ts] == nil { byTs[row.ts] = row }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Logical day-start of the most recent day the active device has HR data for, or nil when the store is
    /// empty. Lets the Deep Timeline open on a day that actually has data instead of a possibly-empty today
    /// right after a history sync , the #597 root cause (the timeline was today-only with no way back).
    func latestDataDayStart() async -> Date? {
        guard let store = await ensureStore() else { return nil }
        guard let ts = await unionLatestHRSampleTs(store: store) else { return nil }
        return Self.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) for the strap, for a Today/24h trend chart.
    /// Aggregated in SQL so a full day never loads the raw ~1 Hz rows.
    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical for the trend chart. Per bucket-start the active strap wins; a
        // raw HR window almost never overlaps between the two namespaces (different time periods), so the
        // per-bucket mean stays faithful. Single-device install reads one id (byte-identical).
        guard deviceId != canonicalDeviceId else {
            return (try? await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: bucketSeconds)) ?? []
        }
        var byStart: [Int: HRBucket] = [:]
        for id in importedReadIds {
            for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: bucketSeconds)) ?? [] where byStart[b.ts] == nil {
                byStart[b.ts] = b
            }
        }
        return byStart.values.sorted { $0.ts < $1.ts }
    }

    /// The latest (greatest-ts) non-nil @63 activity class over `[from, to]`, read across the active strap +
    /// canonical UNION (`importedReadIds`), for the Steps tile icon (#316 / @63). A re-added strap banks its
    /// LIVE step samples (which carry `activityClass`) under its OWN fresh id via the Collector, exactly like
    /// HR, so a read pinned to the canonical "my-whoop" would return nothing and the tile icon would vanish for
    /// a re-added strap (the #904/#908 family). Reading the union keeps the icon whichever id the samples
    /// landed under; a single-device install reads one id (byte-identical). Ties on ts favour the active strap
    /// (its list is scanned first by `latestActivityClass`).
    func stepActivityClassLatest(from: Int, to: Int) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        var perId: [[StepSample]] = []
        for id in importedReadIds {   // active strap FIRST so it wins a ts tie
            perId.append((try? await store.stepSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? [])
        }
        return Self.latestActivityClass(perId)
    }

    /// Full step/activity-class series over the same active/canonical union used by HR and gravity.
    /// Auto-workout type hints need the window composition, not just the latest class. Active wins a
    /// timestamp tie; a single-device install remains a single indexed read.
    func stepSamplesUnion(from: Int, to: Int, limit: Int = 200_000) async -> [StepSample] {
        guard let store = await ensureStore() else { return [] }
        var byTs: [Int: StepSample] = [:]
        for id in importedReadIds {
            let rows = (try? await store.stepSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
            for row in rows where byTs[row.ts] == nil { byTs[row.ts] = row }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Raw strap step TICKS over `[from, to]` for a manual-workout summary (#398): the wrap-aware
    /// `step_motion_counter@57` delta-sum (shared `StepsCounter` kernel) from the FIRST id that has a
    /// countable window — the active strap wins, mirroring `stepActivityClassLatest`. Never MERGED across
    /// ids: two devices' cumulative counters must not be interleaved (that would fabricate huge deltas).
    /// `nil` when no strap counter covers the window — a WHOOP 4.0 (no @57 counter) or an MG/5.0 that hasn't
    /// offloaded the window yet. The caller applies `stepTicksPerStep` and reconciles with the phone pedometer.
    func strapStepTicks(from: Int, to: Int) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        for id in importedReadIds {   // active strap FIRST
            let samples = (try? await store.stepSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? []
            if let ticks = StepsCounter.stepsInWindow(samples) { return ticks }
        }
        return nil
    }

    /// Pure pick of the latest classed activity across the union's per-id step lists: the non-nil
    /// `activityClass` on the sample with the greatest ts, resolving a ts tie in favour of the FIRST list (the
    /// active strap, mirroring the union's active-wins rule). Static + pure so it's unit-testable without a
    /// store. A single non-empty list reduces to "last non-nil class in that list".
    nonisolated static func latestActivityClass(_ perId: [[StepSample]]) -> Int? {
        var bestTs = Int.min
        var bestClass: Int? = nil
        for list in perId {
            for s in list where s.activityClass != nil {
                // Strict `>` keeps the FIRST list's sample on an exact ts tie: earlier lists are scanned
                // first, so a later list's equal-ts sample never overwrites the active strap's.
                if s.ts > bestTs { bestTs = s.ts; bestClass = s.activityClass }
            }
        }
        return bestClass
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return await unionSleepSessions(store: store, from: from, to: to, limit: limit)
    }

    /// Resolve detailed-stage publication per exact stored session. The same-device requirement matters
    /// after a band re-add: evidence from the canonical computed source must not authorize a value from the
    /// active band (or vice versa). Active-source rows are visited first, matching the read-spine dedup rule.
    /// Locally computed permission comes from counts persisted on each session, never a wake-day flag.
    func detailedSleepStageEvidence(
        from: Int = 0,
        to: Int = Int.max,
        limit: Int = 100_000,
        habitualMidsleepSec: Int?
    ) async -> DetailedSleepStageEvidenceSnapshot {
        guard let store = await ensureStore() else { return .empty }

        var imported = Set<SleepStageEvidenceFingerprint>()
        for id in importedReadIds {
            let sessions = (try? await store.sleepSessions(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
            for session in sessions where Self.hasStagePayload(session.stagesJSON) {
                imported.insert(SleepStageEvidenceFingerprint(session))
            }
        }

        var localPermission: [SleepStageEvidenceFingerprint: Bool] = [:]
        for id in computedReadIds {
            guard let sessions = try? await store.sleepSessions(
                deviceId: id, from: from, to: to, limit: limit) else {
                continue
            }
            let publishable = Self.publishableDetailedStageSessionFingerprints(
                sessions,
                habitualMidsleepSec: habitualMidsleepSec)
            for session in sessions {
                let fingerprint = SleepStageEvidenceFingerprint(session)
                guard localPermission[fingerprint] == nil else { continue }
                localPermission[fingerprint] = publishable.contains(fingerprint)
            }
        }

        return DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: imported,
            localPermissionBySession: localPermission)
    }

    /// Strict source snapshot for HealthKit writeback. Unlike the presentation reads above, one failed
    /// source query aborts the snapshot. The caller must build this before deleting any app-authored
    /// HealthKit sleep records.
    func sleepWritebackSnapshot(
        from: Int,
        to: Int,
        limit: Int
    ) async throws -> SleepWritebackRepositorySnapshot {
        guard let store = await ensureStore() else { throw RepositoryReadError.storeUnavailable }
        let now = Int(Date().timeIntervalSince1970)
        let historyFrom = now - 4_000 * 86_400
        let historyTo = now + 86_400
        let historyLimit = 100_000
        let sourceIds = Array(Set(importedReadIds + computedReadIds)).sorted()

        let requestedBySource: [String: [CachedSleepSession]]
        let historyBySource: [String: [CachedSleepSession]]
        #if DEBUG
        if strictSleepSessionReaderForTesting != nil {
            requestedBySource = try await strictSleepSessions(
                store: store, ids: sourceIds, from: from, to: to, limit: limit)
            historyBySource = try await strictSleepSessions(
                store: store,
                ids: sourceIds,
                from: historyFrom,
                to: historyTo,
                limit: historyLimit)
        } else {
            let snapshot = try await store.sleepSessionReadSnapshot(
                deviceIds: sourceIds,
                requestedFrom: from,
                requestedTo: to,
                requestedLimit: limit,
                historyFrom: historyFrom,
                historyTo: historyTo,
                historyLimit: historyLimit)
            requestedBySource = snapshot.requestedByDevice
            historyBySource = snapshot.historyByDevice
        }
        #else
        let snapshot = try await store.sleepSessionReadSnapshot(
            deviceIds: sourceIds,
            requestedFrom: from,
            requestedTo: to,
            requestedLimit: limit,
            historyFrom: historyFrom,
            historyTo: historyTo,
            historyLimit: historyLimit)
        requestedBySource = snapshot.requestedByDevice
        historyBySource = snapshot.historyByDevice
        #endif

        guard requestedBySource.values.allSatisfy({ $0.count < limit }),
              historyBySource.values.allSatisfy({ $0.count < historyLimit }) else {
            throw RepositoryReadError.incompleteSleepSnapshot
        }

        let importedBySource = Dictionary(
            uniqueKeysWithValues: importedReadIds.map {
                ($0, requestedBySource[$0] ?? [])
            })
        let computedBySource = Dictionary(
            uniqueKeysWithValues: computedReadIds.map {
                ($0, requestedBySource[$0] ?? [])
            })
        let habitualMidsleepSec = Self.historicalHabitualMidsleepSec(
            Self.dedupBlocks(
                sourceIds.flatMap { historyBySource[$0] ?? [] }))

        var importedEvidence = Set<SleepStageEvidenceFingerprint>()
        for sessions in importedBySource.values {
            for session in sessions where Self.hasStagePayload(session.stagesJSON) {
                importedEvidence.insert(SleepStageEvidenceFingerprint(session))
            }
        }

        var localPermission: [SleepStageEvidenceFingerprint: Bool] = [:]
        for id in computedReadIds {
            let sessions = computedBySource[id] ?? []
            let publishable = Self.publishableDetailedStageSessionFingerprints(
                sessions,
                habitualMidsleepSec: habitualMidsleepSec)
            for session in sessions {
                let fingerprint = SleepStageEvidenceFingerprint(session)
                guard localPermission[fingerprint] == nil else { continue }
                localPermission[fingerprint] = publishable.contains(fingerprint)
            }
        }

        let imported = Self.dedupBlocks(
            importedReadIds.flatMap { importedBySource[$0] ?? [] })
        let computed = Self.dedupBlocks(
            computedReadIds.flatMap { computedBySource[$0] ?? [] })
        let merged = Self.mergeAllSleepSessions(imported: imported, computed: computed)
        return SleepWritebackRepositorySnapshot(
            sessions: merged,
            detailedStageEvidence: DetailedSleepStageEvidenceSnapshot(
                independentlyStagedImports: importedEvidence,
                localPermissionBySession: localPermission))
    }

    /// Every sleep BLOCK across BOTH sources, UN-deduplicated , so a split-sleep day (a nap
    /// + a main sleep, or any night recorded as multiple blocks) keeps ALL of its blocks.
    /// `sleeps` collapses each day to a single winner for the dashboard; this does not.
    ///
    /// Crucially this reads the on-device COMPUTED source (`computedDeviceId`) directly, not
    /// just the imported `deviceId`. A Bluetooth-only user (no WHOOP/Apple-Health import) has
    /// every block under the computed source, so a loader that only un-dedupes the imported
    /// device sees nothing to expand and silently falls back to the deduped one-per-day list ,
    /// hiding the day's extra blocks. Imported blocks still win on any day they cover (matching
    /// the dashboard's imported-wins merge); computed blocks fill days with no import.
    /// Oldest→newest by onset.
    func allSleepSessions(days: Int = 4000) async -> [CachedSleepSession] {
        let now = Int(Date().timeIntervalSince1970)
        return await allSleepSessions(
            from: now - days * 86_400,
            to: now + 86_400,
            limit: 100_000)
    }

    /// Full-range variant used by publication boundaries such as HealthKit writeback. Keeping the
    /// active/canonical union here prevents a re-paired band's older computed nights from being
    /// stranded when a one-time policy migration rewrites app-authored health records.
    func allSleepSessions(
        from: Int,
        to: Int,
        limit: Int = 100_000
    ) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical (imported) and their computed siblings, keeping ALL blocks (not
        // one per day, this view expands split sleeps), but dropping any block that appears under BOTH union
        // ids (same start+end key) so a day present in both namespaces isn't double-listed.
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(
            store: store, ids: importedReadIds, from: from, to: to, limit: limit))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(
            store: store, ids: computedReadIds, from: from, to: to, limit: limit))
        return Self.mergeAllSleepSessions(imported: imported, computed: computed)
    }

    /// The persisted per-epoch MOTION series for each of `starts` (detected session start keys), keyed by
    /// start (#407). Motion is written ONLY under the computed ("-noop") source by the engine, so we read
    /// there , and an imported-only night (no computed twin) simply has no motion (absent stays absent, an
    /// honest empty state, never a fabricated zero array). This does NOT resolve the night: the caller has
    /// already chosen the main-night GROUP (the 6.1.1 bridged group) and passes those blocks' starts; we
    /// only fetch each one's stored series so the Sleep tab can lay them along the hypnogram's timeline.
    /// A start with no stored series is omitted from the result (its key is absent).
    func sessionMotions(starts: [Int]) async -> [Int: [Double]] {
        guard !starts.isEmpty, let store = await ensureStore() else { return [:] }
        // One batched read keyed by startTs, not a single-row SELECT per session start. The store's
        // batched accessor keeps the exact contract of the old loop: starts with no (or an empty) series
        // are omitted from the result.
        return (try? await store.sessionMotions(deviceId: computedDeviceId, sessionStarts: starts)) ?? [:]
    }

    /// The user's learned habitual midsleep (local time-of-day seconds), or nil under
    /// `SleepStageTotals.habitualMinDays` of history (cold-start). Computed EXACTLY as
    /// `IntelligenceEngine.computeHabitualMidsleep` does , the SAME raw imported + computed ("-noop")
    /// sleep-session union, one `HistoryBlock` per session (effective bounds, dayKey = the LOCAL calendar
    /// day of the midpoint), deferring to the SAME shared `SleepStageTotals.habitualMidsleepSec` pure
    /// function , so the Sleep tab's main-night pick aligns to the same value the analytics rollup used.
    /// The whole point of #547: the UI hero and the analytics daily total resolve to the SAME block for a
    /// shift/late sleeper, not just at cold-start. Reads a wide window so the distinct-day count comfortably
    /// clears the threshold; `habitualMidsleepSec` keeps the longest block per day, so window/order/source
    /// merge differences wash out. (#547)
    func habitualMidsleepSec(days: Int = 4000) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION active strap + canonical (imported) and their computed siblings, de-duplicating identical
        // blocks recorded under both ids so a day present in both namespaces doesn't double-weight the learner.
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: importedReadIds, from: lo, to: hi))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: computedReadIds, from: lo, to: hi))
        return Self.historicalHabitualMidsleepSec(
            Self.dedupBlocks(imported + computed))
    }

    /// Hand-correct a night's bed (onset) and/or wake (end) time. `detectedStartTs` is the immutable
    /// detected key; the corrected onset is stored in `startTsAdjusted` so the key never moves (the
    /// recompute guard + daily override keep matching on it). The merged session list carries no source
    /// deviceId (same reason as the journal reads below), so this applies under BOTH the imported and
    /// computed sources , only the namespace that holds the night updates; the other is a no-op.
    ///
    /// Stages are **re-derived from the raw streams** for the corrected `[newStartTs, newEndTs]` window
    /// via `SleepStager.stageSession` , exactly what WHOOP does, so extending a boundary recovers real
    /// stages instead of a fabricated "awake" block. Only when the night has no raw data (an imported
    /// night) does it fall back to reshaping the stored summary (`SleepWindowReclip`). Refreshes so the
    /// hero re-reads the corrected night immediately.
    func editSleepTimes(detectedStartTs: Int, oldEndTs: Int, storedStagesJSON: String?,
                        newStartTs: Int, newEndTs: Int) async {
        guard let store = await ensureStore() else { return }
        // #940 belt-and-braces: never persist a future-ending or inverted corrected window, whatever
        // the UI sent. The editor's own guards (past-bounded bed picker + cross-midnight auto-correct
        // + the disjoint confirm) should make this unreachable; it is the last line so no client
        // misbehaviour can write a phantom night the display merge cannot render.
        guard let window = SleepEditGuard.clampedEditWindow(
            start: newStartTs, end: newEndTs, now: Int(Date().timeIntervalSince1970)) else { return }
        let (safeStartTs, safeEndTs) = window
        // Re-derive stages from the raw streams for the corrected window; fall back to reshaping the
        // stored summary when the strap has no dense data there yet. The fallback fires for a genuine
        // imported night (no strap data at all) AND for the transient case where the user edits BEFORE
        // a sync has imported this window , the latter then self-heals on the next post-sync
        // `analyzeRecent` (see `selfHealEditedStages`), which re-derives the real stages once raw lands.
        let restaged = await restageFromRaw(start: safeStartTs, end: safeEndTs)
        let stagesJSON = restaged?.stagesJSON
            ?? SleepWindowReclip.reclip(
                stagesJSON: storedStagesJSON,
                sessionStart: detectedStartTs,
                oldEnd: oldEndTs,
                newStart: safeStartTs,
                newEnd: safeEndTs)
        // Apply to the source that actually OWNS this block. Try the computed source first; only fall
        // back to the imported source when no computed row matched , so we never edit a coincidental
        // same-startTs row in the other namespace (which the old unconditional double-write could do).
        let computedChanged = (try? await store.applySleepEdit(
            deviceId: computedDeviceId, detectedStartTs: detectedStartTs,
            newStartTs: safeStartTs,
            newEndTs: safeEndTs,
            stagesJSON: stagesJSON,
            rrEligibleWindowCount: restaged?.rrEligibleWindowCount,
            rrValidWindowCount: restaged?.rrValidWindowCount)) ?? 0
        if computedChanged == 0 {
            _ = try? await store.applySleepEdit(
                deviceId: deviceId, detectedStartTs: detectedStartTs,
                newStartTs: safeStartTs,
                newEndTs: safeEndTs,
                stagesJSON: stagesJSON,
                rrEligibleWindowCount: nil,
                rrValidWindowCount: nil)
        }
        await refresh()
    }

    /// Delete ONE sleep session: the `editSleepTimes` path minus the re-stage/re-insert, so the user can
    /// clear a misread or spurious night and the day recomputes as if it were never recorded (#68; Android
    /// parity `WhoopRepository.deleteSleepSession`). `detectedStartTs` is the immutable detected key
    /// (`startTs`); `endTs` is the night's span, recorded in the tombstone so the engine's overlap test
    /// suppresses a re-detected onset that drifts second-to-second.
    ///
    /// Two durable effects, mirroring the workout-dismiss path:
    ///  1. delete the row from whichever namespace OWNS it: try the computed source first, fall back to
    ///     the imported `deviceId` only when no computed row matched, exactly as `editSleepTimes` applies
    ///     its edit (the merged session list carries no source deviceId, so we resolve the owner here and
    ///     never delete a coincidental same-startTs row in the other namespace);
    ///  2. persist a `dismissedSleep` span in UserDefaults so the next `analyzeRecent` re-detection doesn't
    ///     simply regenerate the night: the engine's sleep guard now skips any re-detected session
    ///     overlapping a dismissed span (just as the dismissed-WORKOUT spans hide a re-derived bout).
    /// Refreshes so the hero re-reads without the deleted night immediately.
    /// Returns the snapshot needed to UNDO the delete (the deleted row + which namespace owned it), or nil
    /// when no row matched. #65: a DETECTED night is tombstoned so `analyzeRecent` does not silently
    /// re-detect + re-insert it; a user-created/edited (`userEdited`) night is deleted WITHOUT a tombstone
    /// (it is never re-detected, so it needs no suppression). The undo re-inserts the snapshot into its
    /// ORIGINAL namespace and lifts the tombstone.
    @discardableResult
    func deleteSleepSession(detectedStartTs: Int, endTs: Int) async -> SleepDeletionSnapshot? {
        guard let store = await ensureStore() else { return nil }
        // Snapshot the owning row BEFORE deleting, resolving the owner exactly as the delete does below:
        // computed source first, imported deviceId as the fallback. A one-second-wide window around the
        // immutable detected key uniquely identifies the row (the key never moves).
        let snapshot = await ownedSleepRowSnapshot(store: store, detectedStartTs: detectedStartTs)
        // Record the durable tombstone ONLY for a DETECTED night. A `userEdited` row (a hand-corrected
        // night or a manually-added nap) is never re-detected, so suppressing its window would needlessly
        // block a real future night that happens to overlap it.
        if DismissedSleepSpans.writesTombstoneOnDelete(userEdited: snapshot?.session.userEdited ?? false) {
            dismissedSleepSpans = DismissedSleepSpans.adding(startTs: detectedStartTs, endTs: endTs,
                                                             to: dismissedSleepSpans)
        }
        // Delete from the namespace that actually owns the row: computed first, imported as a fallback.
        let computedDeleted = (try? await store.deleteSleepSession(
            deviceId: computedDeviceId, startTs: detectedStartTs)) ?? 0
        if computedDeleted == 0 {
            _ = try? await store.deleteSleepSession(deviceId: deviceId, startTs: detectedStartTs)
        }
        await refresh()
        return snapshot
    }

    /// Undo a `deleteSleepSession` (#65): lift the tombstone and restore the deleted row into its ORIGINAL
    /// owning namespace (computed vs imported), preserving `userEdited` so the next `analyzeRecent` does
    /// NOT treat a hand-corrected night as a fresh detected twin. Single-level and transient: the Sleep
    /// screen's undo banner calls this within a few seconds. Idempotent: a snapshot with no tombstone
    /// (a `userEdited` delete) still restores the row.
    func undoDeleteSleepSession(_ snapshot: SleepDeletionSnapshot) async {
        guard let store = await ensureStore() else { return }
        // Lift the tombstone so the restored night is not immediately re-suppressed on the next pass.
        dismissedSleepSpans = DismissedSleepSpans.removing(startTs: snapshot.session.startTs,
                                                           endTs: snapshot.endTs, from: dismissedSleepSpans)
        // Restore into the SAME namespace that owned it. upsertSleepSessions preserves userEdited.
        _ = try? await store.upsertSleepSessions([snapshot.session], deviceId: snapshot.ownerDeviceId)
        // Re-persist the per-epoch motion + band-state series the delete dropped (they're not carried on
        // CachedSleepSession). Must run AFTER the upsert (both are UPDATEs keyed on (deviceId, startTs)),
        // so a userEdited night keeps its Deep Timeline motion + Band Sleep State tracks (Android parity).
        // A nil series persists the empty array, which the store maps to NULL (absent stays absent).
        _ = try? await store.persistSessionMotion(deviceId: snapshot.ownerDeviceId,
                                                  sessionStart: snapshot.session.startTs,
                                                  motionEpochs: snapshot.motion ?? [])
        _ = try? await store.persistSessionSleepState(deviceId: snapshot.ownerDeviceId,
                                                     sessionStart: snapshot.session.startTs,
                                                     states: snapshot.sleepState ?? [])
        await refresh()
    }

    /// Read the single owned sleep row for `detectedStartTs`, resolving the namespace exactly as
    /// `deleteSleepSession` does (computed first, imported fallback). Returns the row plus the owning
    /// deviceId so undo can restore it into that same namespace.
    private func ownedSleepRowSnapshot(store: WhoopStore, detectedStartTs: Int) async -> SleepDeletionSnapshot? {
        func row(_ deviceId: String) async -> CachedSleepSession? {
            let rows = (try? await store.sleepSessions(deviceId: deviceId,
                                                       from: detectedStartTs, to: detectedStartTs,
                                                       limit: 4)) ?? []
            return rows.first { $0.startTs == detectedStartTs }
        }
        // Capture the per-epoch motion + band-state series alongside the row (they live in the same
        // sleepSession row but NOT on CachedSleepSession), so undo can re-persist them after the upsert.
        // Deleting the row drops those columns, so without this a userEdited night's Deep Timeline motion
        // + Band Sleep State tracks vanish on undo (Android preserves them). (#65 parity.)
        func snapshot(_ session: CachedSleepSession, owner: String) async -> SleepDeletionSnapshot {
            let motion = try? await store.sessionMotion(deviceId: owner, sessionStart: detectedStartTs)
            let sleepState = try? await store.sessionSleepState(deviceId: owner, sessionStart: detectedStartTs)
            return SleepDeletionSnapshot(session: session, ownerDeviceId: owner, endTs: session.endTs,
                                         motion: motion ?? nil, sleepState: sleepState ?? nil)
        }
        if let computed = await row(computedDeviceId) {
            return await snapshot(computed, owner: computedDeviceId)
        }
        if let imported = await row(deviceId) {
            return await snapshot(imported, owner: deviceId)
        }
        return nil
    }

    /// Durable "user deleted this night" tombstones as "startTs:endTs" strings, persisted in UserDefaults
    /// (the macOS `CachedSleepSession` lives in the WhoopStore Journal file, which this layer must not
    /// extend with a new table , the same reason dismissed WORKOUT spans live here, not in the DB). The
    /// re-detector in `IntelligenceEngine.analyzeRecent` consults `dismissedSleepWindows` so a deleted
    /// night that re-detects stays gone. Pure token/window logic lives in `DismissedSleepSpans` (the
    /// swift-test-reachable twin of Android's `DismissedSleepGuard`). (#65/#68; Android twin: the
    /// `dismissedSleep` Room table.)
    private var dismissedSleepSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Repository.dismissedSleepDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Repository.dismissedSleepDefaultsKey) }
    }

    /// UserDefaults key holding the dismissed-sleep spans (see `dismissedSleepSpans`).
    static let dismissedSleepDefaultsKey = "sleep.dismissedSessions"

    /// Parsed dismissed-sleep windows for the engine's re-detection guard. Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything (mirrors `WorkoutSource`'s parser).
    func dismissedSleepWindows() -> [(start: Int, end: Int)] {
        DismissedSleepSpans.windows(from: dismissedSleepSpans)
    }

    /// The user's deleted-sleep windows for the "Deleted sleep windows" management list (#65 escape hatch):
    /// each with its parsed window so the UI can render "d MMM, HH:mm-HH:mm" + an "Allow re-detection"
    /// action. Ordered newest-first by end-time.
    func dismissedSleepManagementWindows() -> [(start: Int, end: Int)] {
        dismissedSleepWindows().sorted { $0.end > $1.end }
    }

    /// Remove a tombstone by its window (#65 "Allow re-detection" / expiry escape hatch): the night
    /// regenerates from raw on the next `analyzeRecent` for a computed night. Imported nights cannot be
    /// re-created (there is no raw to re-derive); the caller shows that honest caption.
    func allowSleepReDetection(startTs: Int, endTs: Int) async {
        dismissedSleepSpans = DismissedSleepSpans.removing(startTs: startTs, endTs: endTs,
                                                           from: dismissedSleepSpans)
    }

    /// Manually ADD a missed sleep session , typically a daytime NAP the detector didn't pick up (#508).
    /// Stages it from the raw streams over `[startTs, endTs]` (exactly the editing path's `restageFromRaw`),
    /// falling back to a single "awake" block when the strap has no dense data there yet , the post-sync
    /// self-heal then swaps in real stages once the raw lands. Written under the COMPUTED source as its OWN
    /// separate session row with `userEdited = 1`, so the recompute overlap guard preserves it and it is
    /// NEVER folded into the night's main sleep (which would mislabel awake daytime as light sleep). Purely
    /// additive , `insertManualSleepSession` no-ops if a session already exists at that exact onset.
    func addManualNap(startTs: Int, endTs: Int) async {
        // #940 belt-and-braces (same rule as editSleepTimes): a manually-added session can't end in
        // the future or invert; a future nap would otherwise own the tab's newest day as an
        // all-awake phantom exactly like the bad edit did. The clamped end is used verbatim.
        guard let store = await ensureStore(),
              let window = SleepEditGuard.clampedEditWindow(
                  start: startTs, end: endTs, now: Int(Date().timeIntervalSince1970)) else { return }
        let (safeStartTs, safeEndTs) = window
        // Stage from raw over the chosen window; fall back to a single awake block when the strap has no
        // dense data there yet (the self-heal re-stages once raw arrives). A nap's efficiency is the asleep
        // fraction of the staged window; nil for the fallback (no real stages yet).
        let restaged = await restageFromRaw(start: safeStartTs, end: safeEndTs)
        let stagesJSON = restaged?.stagesJSON
            ?? AnalyticsEngine.encodeStages([
                StageSegment(start: safeStartTs, end: safeEndTs, stage: "wake"),
            ])
        let efficiency = sleepEfficiency(fromStagesJSON: stagesJSON)
        _ = try? await store.insertManualSleepSession(
            deviceId: computedDeviceId, startTs: safeStartTs, endTs: safeEndTs,
            efficiency: efficiency,
            stagesJSON: stagesJSON,
            rrEligibleWindowCount: restaged?.rrEligibleWindowCount,
            rrValidWindowCount: restaged?.rrValidWindowCount)
        await refresh()
    }

    /// Asleep fraction (light+deep+rem ÷ total in-bed) of a segment-array `stagesJSON`, or nil when the
    /// JSON is the fallback awake-only block / unparseable. Used to seed a manually-added nap's efficiency
    /// so its hypnogram footer reads sensibly before the next recompute re-derives it. (#508)
    private func sleepEfficiency(fromStagesJSON json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var asleep = 0.0, total = 0.0
        for seg in arr {
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String, e > s else { continue }
            let dur = Double(e - s)
            total += dur
            if stage != "wake" && stage != "awake" { asleep += dur }
        }
        return total > 0 && asleep > 0 ? asleep / total : nil
    }

    /// Re-derive stages from the raw streams for `[start, end]` (read under the strap `deviceId`),
    /// returning the encoded `stagesJSON`, or `nil` when the strap does NOT densely cover the window ,
    /// i.e. there isn't enough worn-night data to stage (a couple of stray samples must not trigger a
    /// degenerate `stageSession` that overwrites a good breakdown). ~1 sample / 2 min is the floor.
    /// Extracted from `editSleepTimes` so the post-sync self-heal reuses the exact density gate +
    /// staging. Stages OFF the main actor , Repository is `@MainActor` and a multi-hour window is tens of
    /// thousands of samples, which would otherwise freeze the UI.
    private struct RestagedSleep: Sendable {
        let stagesJSON: String
        let rrEligibleWindowCount: Int
        let rrValidWindowCount: Int
    }

    private func restageFromRaw(start: Int, end: Int) async -> RestagedSleep? {
        guard let store = await ensureStore() else { return nil }
        let lo = start - 3_600, hi = end + 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let inWindowGravity = grav.lazy.filter { $0.ts >= start && $0.ts <= end }.count
        let windowSeconds = max(1, end - start)
        guard inWindowGravity >= max(20, windowSeconds / 120) else { return nil }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        // Read only when the refinement below might actually use it (see `useMotionAwareWake`) — a plain
        // read cost, but no point paying it on the (default) off path.
        let useMotionAwareWake = PuffinExperiment.motionAwareWakeEnabled
        let steps = useMotionAwareWake
            ? ((try? await store.stepSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? [])
            : []
        // V2 staging ships enabled after cross-subject validation; disabling its setting selects the
        // retained V1 `SleepStager`. Read once here off the actor; the switch only chooses which engine
        // runs over the already-detected window. (V7 Pillar 3b)
        let useV2 = PuffinExperiment.experimentalSleepV2Enabled
        return await Task.detached(priority: .utility) {
            let staged = useV2
                ? SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
                : SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
            // #364 follow-up: motion-aware wake refinement post-pass, same toggle-shaped no-op when off
            // as every other Experimental switch here.
            let refined = WakeMotionRefinement.apply(
                staged,
                grav: grav,
                steps: steps,
                enabled: useMotionAwareWake)
            guard let stagesJSON = AnalyticsEngine.encodeStages(refined) else { return nil }
            let counts = ScoreConfidence.detailedStageRREvidenceCounts(
                session: SleepSession(
                    start: start,
                    end: end,
                    efficiency: 0,
                    stages: refined,
                    restingHR: nil,
                    avgHRV: nil),
                rr: rr)
            return RestagedSleep(
                stagesJSON: stagesJSON,
                rrEligibleWindowCount: counts.eligibleWindowCount,
                rrValidWindowCount: counts.validRRWindowCount)
        }.value
    }

    /// Self-heal pass for the edit-races-sync bug. A night edited BEFORE the strap sync imported its raw
    /// streams got fabricated `SleepWindowReclip` stages (a trailing "awake" block) at edit time, and the
    /// `userEdited` flag then froze that breakdown against every later sync. Here , invoked from
    /// `analyzeRecent`, which runs after each sync backfill , we re-derive stages from the now-available
    /// raw over each edited night's LOCKED bounds and rewrite the stage breakdown ONLY, never the user's
    /// bed/wake correction. Idempotent: a night already staged from raw re-derives to the same JSON
    /// (equality-skip, no write); a night edited-too-early heals the moment its raw arrives; a true
    /// imported night (raw never dense) is left untouched (`restageFromRaw` returns nil). Reads/writes the
    /// COMPUTED source , the same one `analyzeRecent` reads edited rows from. Returns the (possibly
    /// refreshed) edited rows so the caller recomputes daily aggregates from the corrected stages.
    func selfHealEditedStages(from windowStart: Int, to windowEnd: Int) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        func editedRows() async -> [CachedSleepSession] {
            ((try? await store.sleepSessions(deviceId: computedDeviceId, from: windowStart,
                                             to: windowEnd, limit: 100_000)) ?? [])
                .filter { $0.userEdited }
        }
        let edited = await editedRows()
        guard !edited.isEmpty else { return [] }
        var healed = false
        for row in edited {
            // Re-derive over the LOCKED corrected window (effective onset → wake). Skip when the raw
            // isn't dense yet, or when the result already matches what's stored (steady state , no write).
            guard let restaged = await restageFromRaw(
                start: row.effectiveStartTs,
                end: row.endTs
            ) else { continue }
            guard restaged.stagesJSON != row.stagesJSON
                    || restaged.rrEligibleWindowCount != row.rrEligibleWindowCount
                    || restaged.rrValidWindowCount != row.rrValidWindowCount
            else { continue }
            let n = (try? await store.updateSleepStages(deviceId: computedDeviceId,
                                                        detectedStartTs: row.startTs,
                                                        stagesJSON: restaged.stagesJSON,
                                                        rrEligibleWindowCount:
                                                            restaged.rrEligibleWindowCount,
                                                        rrValidWindowCount:
                                                            restaged.rrValidWindowCount)) ?? 0
            if n > 0 { healed = true }
        }
        return healed ? await editedRows() : edited
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    /// When `source` is the canonical WHOOP id, UNION the active strap so a series stored under a re-added
    /// strap's id ("whoop-<uuid>") still surfaces alongside the canonical history (deduped per day, active
    /// strap wins). Other sources (apple-health / xiaomi-band / lab-book) read that source verbatim.
    ///
    /// #833/v7.7.2: `fullHistory` is a full-range sentinel. When true the read spans the whole recordable
    /// epoch ("0000-01-01" ... "9999-12-31", the same literals `dataVolumeSnapshot` uses) REGARDLESS of
    /// `days`; when false (the default) `days` is honoured exactly as before, so every existing caller (all
    /// default `fullHistory: false`, keep `days: 4000`) is byte-identical. The per-source pages window their
    /// genuine reloads with `days` and force full range only for their ALL view via this flag.
    func series(key: String, source: String, days: Int = 4000, fullHistory: Bool = false) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))
        // Total Energy is a derived APPLE-ONLY series. Build it from paired active + basal points and
        // omit every partial day; never fill a missing Apple component with the strap's combined
        // `activeKcalEst` value, which would mix producers and double-count resting metabolism.
        if source == Self.appleHealthSource, key == "total_kcal" {
            let active = (try? await store.metricSeries(deviceId: source, key: "active_kcal",
                                                        from: from, to: to)) ?? []
            let resting = (try? await store.metricSeries(deviceId: source, key: "basal_kcal",
                                                         from: from, to: to)) ?? []
            return DailyEnergyBreakdown.appleTotalSeries(
                active: active.map { ($0.day, $0.value) },
                resting: resting.map { ($0.day, $0.value) }
            )
        }
        if source.hasSuffix("-noop"),
           ScoreConfidence.isDetailedSleepStageSeriesKey(key) {
            return await derivedDetailedStageRows(
                store: store,
                deviceId: source,
                key: key,
                from: from,
                to: to)
        }
        let pts: [MetricPoint]
        if source == canonicalDeviceId {
            pts = await unionMetricSeries(store: store, key: key, from: from, to: to)
        } else {
            pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        }
        return pts.map { ($0.day, $0.value) }
    }

    // MARK: - Deep Timeline (full-day full-resolution viewer , #575/#574/#582)
    //
    // The Deep Timeline draws a single metric across a zoomable time window at the resolution the zoom
    // demands: a whole day reads COARSE SQL buckets (a worn 24h is ~86k 1 Hz HR rows , drawing all of
    // them is the #1 risk, so we never load raw at day scale), while a zoomed-in window reads the RAW
    // per-second rows so the user can inspect real beats. The adaptive choice lives here in the read
    // layer (NOT the view) so the chart only ever receives ~targetPoints points regardless of zoom.

    /// A metric the Deep Timeline can plot. HR is the always-present hero (adaptively downsampled);
    /// the rest are lower-frequency raw-sample streams shown where the strap offloaded them.
    enum TimelineMetric: String, CaseIterable, Identifiable, Sendable {
        case hr, hrv, spo2, skinTemp, respiration, motion, bandSleepState
        var id: String { rawValue }

        /// User-facing pill label.
        var title: String {
            switch self {
            case .hr: return String(localized: "Heart Rate")
            // #803: the .hrv series is a TRAILING-WINDOW rMSSD moving across the session (HRVAnalyzer
            // .rollingRmssd), not one opaque "HRV" figure and not raw R-R ms. Label it honestly so the
            // pill names what the chart actually plots.
            case .hrv: return String(localized: "Windowed rMSSD")
            case .spo2: return "SpO₂"
            case .skinTemp: return String(localized: "Skin Temp")
            case .respiration: return String(localized: "Respiration")
            case .motion: return String(localized: "Motion")
            // #175: the strap's OWN band sleep_state track (0 wake/1 still/2 asleep/3 up), shown as a
            // distinct stepped track alongside the derived hypnogram. This is the band's reported state,
            // NOT a stage NOOP trusts as truth - the pill names it "Band Sleep State" so it can't be
            // mistaken for the derived stages.
            case .bandSleepState: return String(localized: "Band Sleep State")
            }
        }
    }

    /// One Deep-Timeline read: the plotted points plus whether they came from raw seconds or coarse
    /// buckets (the view shows the resolution honestly) and the bucket width used.
    struct TimelineSeries: Sendable {
        var points: [TrendPoint]
        var isRaw: Bool
        var bucketSeconds: Int
        static let empty = TimelineSeries(points: [], isRaw: false, bucketSeconds: 0)
    }

    /// Pure adaptive-resolution decision: the bucket width (seconds) to read for a `[from, to]` window
    /// that should yield ABOUT `targetPoints` points. A bucket of 1 means "read raw per-second rows".
    ///
    /// span/targetPoints is the natural bucket width; we floor it at 1 s (raw) and round to a friendly
    /// step so adjacent zoom levels share bucket edges (no shimmer while panning). The whole point: a
    /// day-scale window (≈86 400 s) at ~600 target points picks a coarse ~150 s bucket (never raw), while
    /// a few-minute zoom drops to bucket 1 and reads the real seconds. Static + pure so it's unit-testable
    /// without a store or a clock.
    nonisolated static func timelineBucketSeconds(spanSeconds: Int, targetPoints: Int) -> Int {
        let span = max(1, spanSeconds)
        let target = max(1, targetPoints)
        let ideal = span / target
        guard ideal > 1 else { return 1 }      // zoomed in enough that raw seconds already fit the budget
        // Snap up to a friendly step so neighbouring zoom levels reuse bucket boundaries.
        let steps = [2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        for s in steps where s >= ideal { return s }
        return steps.last!
    }

    /// The trailing-window width (seconds) for the #803 windowed-rMSSD `.hrv` series, chosen from the
    /// visible span: a tight 2-minute rMSSD when zoomed in so short autonomic swings show, widening with
    /// the span (capped at 10 min) so a whole-night/day view stays a readable line rather than a jagged
    /// per-2-min trace. ~1/30 of the span, clamped to [120 s, 600 s]. Pure + static so it's unit-testable.
    nonisolated static func hrvRollingWindowSec(spanSeconds: Int) -> Int {
        let span = max(1, spanSeconds)
        return min(600, max(120, span / 30))
    }

    /// Deep-Timeline read facade. Returns ~`targetPoints` points for `metric` over `[from, to]` from
    /// `source` (defaults to the user's own strap), choosing raw seconds vs coarse buckets adaptively so
    /// the chart never draws ~86k points (the #575 day-scale risk). HR rides the existing COALESCE reads
    /// (`hrBuckets`/`hrSamples`) so a PPG-only WHOOP 5 day still renders its ppgHrSample series (#156/#172)
    /// , at day scale `hrBuckets` averages PPG into its buckets, and zoomed-in `hrSamples` returns the raw
    /// PPG-derived seconds; neither is empty for a PPG-only night. Other metrics read their raw sample
    /// tables (low frequency, no 86k risk) and bin to the same bucket grid when zoomed out.
    func timelineSeries(metric: TimelineMetric, from: Int, to: Int,
                        targetPoints: Int = 600, source: String? = nil) async -> TimelineSeries {
        guard to > from, let store = await ensureStore() else { return .empty }
        // Default (no explicit source) → the user's own strap, UNIONed with the canonical "my-whoop" so the
        // Deep Timeline renders whether the landed day's raw sits under the re-added strap or the canonical
        // history. An explicit source (a per-source page) reads that source verbatim. `unionIds` is one id
        // on a single-device install (byte-identical) and dedups raw by ts (active strap wins).
        let unionIds: [String] = source.map { [$0] } ?? importedReadIds
        let bucket = Self.timelineBucketSeconds(spanSeconds: to - from, targetPoints: targetPoints)
        let isRaw = bucket <= 1

        if metric == .hr {
            // Both HR paths COALESCE measured + ppgHrSample (#156) , preserved by delegating to the
            // store reads rather than re-querying. Day scale → SQL-aggregated buckets; zoomed-in → raw.
            if isRaw {
                // Read each source's raw seconds (off the WhoopStore actor), then hand the union to the
                // pure helper on a utility task so the dedup + sort + map (up to 200k 1 Hz rows) runs OFF
                // the main actor and can't beach-ball a dense day. Mirrors `restageFromRaw`.
                var perId: [[HRSample]] = []
                for id in unionIds {
                    perId.append((try? await store.hrSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? [])
                }
                let points = await Task.detached(priority: .utility) {
                    Self.dedupSortRawHr(perId)
                }.value
                return TimelineSeries(points: points, isRaw: true, bucketSeconds: 1)
            }
            var byStart: [Int: HRBucket] = [:]
            for id in unionIds {
                for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: bucket)) ?? [] where byStart[b.ts] == nil { byStart[b.ts] = b }
            }
            return TimelineSeries(points: byStart.values.sorted { $0.ts < $1.ts }.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
            }, isRaw: false, bucketSeconds: bucket)
        }

        // Non-HR streams: read raw rows (these tables are far sparser than 1 Hz HR, so a day's worth is
        // safe to load) and, when zoomed out, downsample to the bucket grid for a clean line. The reads
        // run here (each `timelineRawMetric` awaits the store actor); the dedup + sort + downsample over
        // the union is handed to a utility task so it runs OFF the main actor on a dense window. Mirrors
        // `restageFromRaw`.
        // #938: resolve each source id's strap family ONCE (skin-temp raw→°C is family-specific: 5/MG
        // centidegrees vs a 4.0 v24 raw ADC). Cheap registry snapshot; a positively-identified 4.0 maps to
        // `.whoop4`, everything else (5/MG, imports, unknown) to `.whoop5` — the prior /100 behaviour.
        let familyById = Self.skinTempFamilies(store: store, ids: unionIds)
        var perId: [[TrendPoint]] = []
        for id in unionIds {
            perId.append(await timelineRawMetric(metric: metric, store: store, source: id,
                                                 family: familyById[id] ?? .whoop5, from: from, to: to))
        }
        let points = await Task.detached(priority: .utility) {
            Self.dedupSortDownsampleRaw(perId, isRaw: isRaw, bucketSeconds: bucket)
        }.value
        guard !points.isEmpty else { return TimelineSeries(points: [], isRaw: isRaw, bucketSeconds: bucket) }
        return TimelineSeries(points: points, isRaw: isRaw, bucketSeconds: isRaw ? 1 : bucket)
    }

    /// Map each device id to the strap family that wrote its rows (#938), for the family-aware skin-temp
    /// raw→°C conversion. Reads the registry ONCE; the model-label → family mapping (and the `.whoop5`
    /// fallback for unknowns) lives in `DeviceFamily.forRegistryModel` (#171). Best-effort: an unreadable
    /// registry yields an empty map, so every caller falls back to `.whoop5`.
    private static func skinTempFamilies(store: WhoopStore, ids: [String]) -> [String: DeviceFamily] {
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        var out: [String: DeviceFamily] = [:]
        for id in ids {
            out[id] = DeviceFamily.forRegistryModel(devices.first(where: { $0.id == id })?.model)
        }
        return out
    }

    /// Family of the ACTIVE strap (#623), for the deep timeline's family-specific empty-state copy. Reuses
    /// the canonical `DeviceFamily.forRegistryModel` (#171) with its `.whoop5` fallback for nil/unknown/
    /// ambiguous, matching Android's `FullDayChartScreen`. Best-effort: no store / unreadable registry → `.whoop5`.
    func activeStrapFamily() -> DeviceFamily {
        guard let store else { return .whoop5 }
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        return DeviceFamily.forRegistryModel(devices.first(where: { $0.id == deviceId })?.model)
    }

    /// Whether the active strap has EVER banked a sample of `metric` (#623) — distinguishes a strap that
    /// never produces it (honest "not supported on this strap" copy) from one with just an unsynced window.
    /// Only SpO₂/respiration are asked; any other metric returns true so the generic empty copy stands.
    /// Twin of the Android `FullDayChartScreen` `everSpo2`/`everResp` reads. Best-effort.
    func strapHasEverProduced(_ metric: TimelineMetric) async -> Bool {
        guard let store else { return true }
        let now = Int(Date().timeIntervalSince1970)
        switch metric {
        case .spo2:
            return !(((try? await store.spo2Samples(deviceId: deviceId, from: 0, to: now, limit: 1)) ?? []).isEmpty)
        case .respiration:
            return !(((try? await store.respSamples(deviceId: deviceId, from: 0, to: now, limit: 1)) ?? []).isEmpty)
        default:
            return true
        }
    }

    /// Raw points for a non-HR timeline metric, mapped to display units (skin temp → °C DEVICE-FAMILY-AWARE
    /// via `skinTempCelsius`: 5/MG centidegrees (#156), WHOOP 4.0 v24 raw ADC (#938); HRV → per-RR
    /// instantaneous from RR ms; respiration/SpO₂/motion as the stored signal). Empty when the strap
    /// offloaded nothing for the window. `family` is the strap that wrote `source`'s rows.
    private func timelineRawMetric(metric: TimelineMetric, store: WhoopStore, source: String,
                                   family: DeviceFamily, from: Int, to: Int) async -> [TrendPoint] {
        switch metric {
        case .hr:
            return []   // handled by the caller's HR path
        case .hrv:
            // #803: plot a TRAILING-WINDOW rMSSD that MOVES across the session, not raw R-R ms mislabelled
            // "HRV". Read the R-R rows (low frequency, safe to load for a window) and hand them to
            // HRVAnalyzer.rollingRmssd (the SAME range + Malik ectopic filtering the nightly path uses), so
            // each point is an honest windowed rMSSD (ms). A sparse/artifact-heavy window emits nothing
            // rather than a noisy spike. The `to - from` span chooses the window width: a 2-min rMSSD for a
            // zoomed-in look, widening with the visible span so a day-scale view stays readable. The thinning
            // stride keeps a 1 Hz R-R stream from emitting a point per beat.
            let rr = (try? await store.rrIntervals(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            let window = Self.hrvRollingWindowSec(spanSeconds: to - from)
            // rollingRmssd + the map over its output run OFF the main actor (mirrors the HR branch's
            // Task.detached in `timelineSeries`): only the already-read Sendable `rr` rows cross in.
            return await Task.detached(priority: .utility) {
                HRVAnalyzer.rollingRmssd(rr: rr, windowSec: window, stepSec: max(1, window / 8))
                    .map { Self.timelinePoint($0.ts, $0.rmssd) }
            }.value
        case .spo2:
            // The honest raw red/IR ratio proxy (#166: no calibrated %), shown as a unitless trend.
            let s = (try? await store.spo2Samples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            // The up-to-200k-row conversion runs OFF the main actor; only the Sendable `s` rows cross in.
            return await Task.detached(priority: .utility) {
                s.compactMap { $0.ir > 0 ? Self.timelinePoint($0.ts, Double($0.red) / Double($0.ir)) : nil }
            }.value
        case .skinTemp:
            let s = (try? await store.skinTempSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return await Task.detached(priority: .utility) {
                // #938: family-aware raw→°C — 5/MG centidegrees (raw/100, #156), 4.0 v24 raw ADC map.
                s.map { Self.timelinePoint($0.ts, skinTempCelsius(raw: $0.raw, family: family)) }
            }.value
        case .respiration:
            let s = (try? await store.respSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, Double($0.raw)) }
            }.value
        case .motion:
            // Gravity vector magnitude as a coarse movement signal (1 g at rest).
            let s = (try? await store.gravitySamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            // The sqrt-per-row magnitude over up to 200k gravity rows runs OFF the main actor.
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot()) }
            }.value
        case .bandSleepState:
            // #175: the strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up) as a stepped track. Read
            // the raw per-record stream (far sparser than 1 Hz HR, safe to load a day) and plot the 0-3 code
            // VERBATIM. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-offloaded window),
            // which the view renders as its honest "nothing here" state - never a fabricated flat line.
            let s = (try? await store.sleepStateSamples(deviceId: source, from: from, to: to)) ?? []
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, Double($0.state)) }
            }.value
        }
    }

    /// Build a `TrendPoint` from a unix-seconds `ts` + value. `nonisolated static` so the per-row
    /// timeline conversions can run inside `Task.detached` off the main actor (captures no self/actor state).
    nonisolated static func timelinePoint(_ ts: Int, _ v: Double) -> TrendPoint {
        TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(ts)), value: v)
    }

    /// Mean-bin an already-loaded raw point series onto a `bucketSeconds` grid (floor(ts/bucket)*bucket),
    /// ascending. The in-process twin of `hrBuckets` for the non-HR streams. Pure + static so it's testable.
    nonisolated static func downsampleToBuckets(_ points: [TrendPoint], bucketSeconds: Int) -> [TrendPoint] {
        let bucket = max(1, bucketSeconds)
        guard !points.isEmpty else { return [] }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for p in points {
            let key = (Int(p.date.timeIntervalSince1970) / bucket) * bucket
            let acc = sums[key] ?? (0, 0)
            sums[key] = (acc.sum + p.value, acc.n + 1)
        }
        return sums.keys.sorted().map { key in
            let acc = sums[key]!
            return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(key)),
                              value: acc.sum / Double(acc.n))
        }
    }

    /// Pure off-main post-processing for the zoomed-in (raw) HR Deep-Timeline path. Takes the per-source
    /// reads (`hrSamples` already ran off the WhoopStore actor) and does the heavy dedup + sort + map that
    /// would otherwise run on `@MainActor` and beach-ball a dense day (up to 200k 1 Hz rows). Dedup is
    /// "first id wins per ts" (active strap first in `unionIds`), then ascending by ts, then mapped to
    /// `TrendPoint`. Identical semantics to the in-line version it replaced. `nonisolated static` so it's
    /// callable from a `Task.detached` and unit-testable off the actor.
    nonisolated static func dedupSortRawHr(_ perId: [[HRSample]]) -> [TrendPoint] {
        var byTs: [Int: HRSample] = [:]
        for samples in perId {
            for s in samples where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        return byTs.values.sorted { $0.ts < $1.ts }.map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm))
        }
    }

    /// Pure off-main post-processing for the non-HR raw Deep-Timeline path. Takes the per-source raw point
    /// arrays (`timelineRawMetric` already ran its store reads), dedups by ts across the union (first id
    /// wins, preserving each source's read order), sorts ascending, and either returns the raw points
    /// (`isRaw`) or mean-bins them onto the `bucketSeconds` grid. Identical semantics to the in-line
    /// version it replaced , moved off `@MainActor` so a dense multi-hour window can't freeze the UI.
    /// `nonisolated static` so it's callable from a `Task.detached` and unit-testable off the actor.
    nonisolated static func dedupSortDownsampleRaw(_ perId: [[TrendPoint]], isRaw: Bool,
                                                   bucketSeconds: Int) -> [TrendPoint] {
        var raw: [TrendPoint] = []
        var seenTs = Set<Int>()
        for points in perId {
            for p in points {
                let ts = Int(p.date.timeIntervalSince1970)
                if seenTs.insert(ts).inserted { raw.append(p) }
            }
        }
        raw.sort { $0.date < $1.date }
        if isRaw { return raw }
        return downsampleToBuckets(raw, bucketSeconds: bucketSeconds)
    }

    // MARK: - Cross-source resolver (PR#196)

    /// Product-facing daily series for a metric across every COMPATIBLE source, freshest-wins. Use this
    /// on surfaces where the user expects the best available signal (Compare/Insights/Stress/Explore/
    /// Today); use `series(key:source:)` where a single source must be honoured verbatim. Precedence is
    /// explicit per `sourceCandidates`: imported WHOOP > NOOP-computed > declared-compatible Apple Health.
    /// #833/v7.7.2: `fullHistory` forces the full recordable epoch ("0000-01-01" ... "9999-12-31")
    /// regardless of `days`; false (the default) honours `days` exactly as before, so existing callers are
    /// byte-identical.
    func resolvedSeries(key: String, source preferredSource: String, days: Int = 4000, fullHistory: Bool = false) async -> MetricSeriesResolution {
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: preferredSource,
                                               actualWhoopSource: deviceId)
        guard let store = await ensureStore() else {
            return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: [])
        }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))

        // First candidate wins per day; later candidates only fill days no earlier one covered.
        var byDay: [String: ResolvedMetricPoint] = [:]
        for candidate in candidates {
            let rows = await resolvedRows(store: store, candidate: candidate, from: from, to: to)
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        let points = byDay.values.sorted { $0.day < $1.day }
        return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: points)
    }

    /// Read one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
    /// for any day the metricSeries doesn't carry (a Bluetooth-only WHOOP 5 user has values in the daily
    /// columns but not the long-format series). Ascending by day.
    ///
    /// The DailyMetric read uses a +1-day upper buffer (`Self.dayAfter(to)`). A night is keyed on its LOCAL
    /// WAKE day, so the row backing the SELECTED day's Rest can sort on the day AFTER the caller's `to`
    /// (a just-after-midnight wake, or a UTC+ user whose wake-day rolls a calendar day ahead of the
    /// requested bound). Without the buffer that banked row was excluded and Today fell back to the latest
    /// historical Rest (#614). The buffer only WIDENS the daily read; `byDay`'s metricSeries-first
    /// precedence is unchanged, so an imported series point still wins its day. Mirrors Android
    /// WhoopRepository.resolvedRows.
    private func resolvedRows(store: WhoopStore, candidate: MetricSourceCandidate,
                             from: String, to: String) async -> [(day: String, value: Double)] {
        if candidate.source.hasSuffix("-noop"),
           ScoreConfidence.isDetailedSleepStageSeriesKey(candidate.key) {
            return await derivedDetailedStageRows(
                store: store,
                deviceId: candidate.source,
                key: candidate.key,
                from: from,
                to: Self.dayAfter(to))
        }
        let metricRows = (try? await store.metricSeries(deviceId: candidate.source, key: candidate.key,
                                                        from: from, to: to)) ?? []
        var byDay = Dictionary(
            metricRows.map { ($0.day, $0.value) },
            uniquingKeysWith: { _, last in last })
        if let dailyRows = try? await store.dailyMetrics(deviceId: candidate.source,
                                                         from: from, to: Self.dayAfter(to)) {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Self.dailyColumn(key: candidate.key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    /// The candidate (source, key) pairs to try for `key`, in precedence order, given the user's
    /// `preferredSource`. The strap's real id is `actualWhoopSource` (`deviceId`), so the computed
    /// sibling is `actualWhoopSource + "-noop"`.
    ///  • strap-preferred → [imported strap, computed strap, compatible Apple] (Apple only for vitals
    ///    that have a declared 1:1 mapping);
    ///  • Apple-preferred → [Apple] (+ computed strap ONLY for steps/active_kcal, which the strap
    ///    estimates and Apple may not carry);
    ///  • nutrition-log → editable combined log, then legacy nutrition-csv as a migration fallback;
    ///  • any other source → itself only.
    static func sourceCandidates(forKey key: String, preferredSource: String,
                                 actualWhoopSource: String) -> [MetricSourceCandidate] {
        let computedSource = actualWhoopSource + "-noop"
        func uniqued(_ cs: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
            var seen = Set<MetricSourceCandidate>(); var out: [MetricSourceCandidate] = []
            for c in cs where !seen.contains(c) { seen.insert(c); out.append(c) }
            return out
        }

        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            // Active strap first (live/measured wins per day), then the CANONICAL "my-whoop" import, THEN
            // the computed siblings, so history banked under the canonical id before a re-add still
            // resolves (the union model) and imports outrank computed estimates — the documented
            // `imported WHOOP > NOOP-computed` order. The computed sibling used to sit ahead of the
            // canonical import, so after a device re-add (active != canonical) the new strap's computed
            // estimates shadowed richer imported my-whoop history (Swift twin of the Dhanunjay-Divi/Noop#240
            // precedence fix). `uniqued` collapses these to one pair per source on a single-device
            // install (active == canonical), so that path is byte-identical. Apple is the final
            // cross-source fallback.
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: whoopSource, key: key),
                MetricSourceCandidate(source: computedSource, key: key),
                MetricSourceCandidate(source: whoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        if preferredSource == appleHealthSource {
            var candidates = [MetricSourceCandidate(source: appleHealthSource, key: key)]
            // Health Connect is an Apple-equivalent body-metric source (Android only , harmless no-op on
            // iOS/Mac, which never write a "health-connect" series). Kept here so the resolver is
            // byte-identical to Android's, where it makes a Health-Connect-only weight history resolve in
            // Compare (#443). A real Apple export still wins per day; HC fills the rest.
            candidates.append(MetricSourceCandidate(source: healthConnectSource, key: key))
            if noopComputedCanFillAppleMetric(key) {
                candidates.append(MetricSourceCandidate(source: computedSource, key: key))
            }
            return uniqued(candidates)
        }
        if preferredSource == NutritionLogContract.deviceId {
            return [
                MetricSourceCandidate(source: NutritionLogContract.deviceId, key: key),
                MetricSourceCandidate(source: "nutrition-csv", key: key),
            ]
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    /// The Apple-Health series key that carries the SAME physiological quantity as a WHOOP key , used
    /// only for the declared-compatible vitals; nil means "no Apple equivalent, don't fall back to it".
    static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":              return "resting_hr"
        case "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal":
            return key
        case "sleep_total_min":  return "asleep_min"
        case "sleep_deep_min":   return "deep_min"
        case "sleep_rem_min":    return "rem_min"
        case "sleep_light_min":  return "core_min"
        default:                 return nil
        }
    }

    /// Whether the NOOP-computed strap source may fill an Apple-preferred metric. Only the two daily
    /// totals the strap genuinely estimates (steps, calories) , never a derived WHOOP score.
    private static func noopComputedCanFillAppleMetric(_ key: String) -> Bool {
        switch key {
        case "steps", "active_kcal": return true
        default:                     return false
        }
    }

    /// The Explore read path (#199). Like `series(key:source:)` but, for the strap source
    /// ("my-whoop"), falls back to the on-device COMPUTED dailies a Bluetooth-only WHOOP 5 user
    /// has (no CSV/Health import) , so Charge/Rest/Effort/Health metrics still resolve. Three layers,
    /// imported-wins per day:
    ///  1. the imported metricSeries under `deviceId` (a real WHOOP export);
    ///  2. the COMPUTED metricSeries under `computedDeviceId` , for keys written there but absent from
    ///     the DailyMetric columns (notably `sleep_performance`, IntelligenceEngine's Rest composite);
    ///  3. the merged daily metrics (`self.days`, imported ∪ computed) for keys with a DailyMetric
    ///     column , the same key→column map InsightsView.dailyOutcome / Android's dailyPick use,
    ///     extended to the full daily column set.
    /// Any OTHER source delegates to the resolver. Nutrition uses `nutrition-log` first and the legacy
    /// `nutrition-csv` partition only as a per-day fallback.
    /// #833/v7.7.2: `fullHistory` forces the full recordable epoch ("0000-01-01" ... "9999-12-31")
    /// regardless of `days`; false (the default) honours `days` exactly as before, so existing callers are
    /// byte-identical. The flag is forwarded to the non-strap `series(...)` delegation below so every source
    /// path honours it.
    func exploreSeries(key: String, source: String, days: Int = 4000, fullHistory: Bool = false) async -> [(day: String, value: Double)] {
        guard source == "my-whoop" else { return await series(key: key, source: source, days: days, fullHistory: fullHistory) }
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))

        if ScoreConfidence.isDetailedSleepStageSeriesKey(key) {
            // Derive each computed source from its own authorized session JSON before precedence merging.
            // A stale daily/series copy and another band's evidence can therefore authorize nothing.
            var detailedByDay: [String: Double] = [:]
            for id in computedReadIds.reversed() {
                for point in await derivedDetailedStageRows(
                    store: store,
                    deviceId: id,
                    key: key,
                    from: from,
                    to: Self.dayAfter(to)) {
                    detailedByDay[point.day] = point.value
                }
            }
            // Imported providers classify their own stages. Keep their daily fallback as well as their
            // long-format series, with the same active-over-canonical precedence as every Explore metric.
            for id in importedReadIds.reversed() {
                for row in (try? await store.dailyMetrics(
                    deviceId: id, from: from, to: Self.dayAfter(to))) ?? [] {
                    if let value = Self.dailyColumn(key: key, day: row) {
                        detailedByDay[row.day] = value
                    }
                }
                for point in (try? await store.metricSeries(
                    deviceId: id, key: key, from: from, to: to)) ?? [] {
                    detailedByDay[point.day] = point.value
                }
            }
            return detailedByDay.sorted { $0.key < $1.key }
                .map { (day: $0.key, value: $0.value) }
        }

        // day → value, lowest-priority source first; higher-priority sources overwrite per day so a
        // real import always wins over the computed strap value.
        var byDay: [String: Double] = [:]

        // Layer 3 (lowest): merged daily column for keys that have one. `self.days` is the published
        // imported ∪ computed daily cache (parameter `days` is the lookback window, not this).
        for d in self.days where byDay[d.day] == nil {
            if let v = Self.dailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        // Layer 2: computed metricSeries (covers sleep_performance, which has no daily column). UNION the
        // active strap's computed sibling + the canonical computed sibling (canonical first so the active
        // strap's value, applied last, wins per day).
        for id in computedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] {
                byDay[p.day] = p.value
            }
        }
        // Layer 1 (highest): the imported export's metricSeries. UNION active strap + canonical (canonical
        // first so the active strap's value wins per day).
        for id in importedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }

        return byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
    }

    /// Fail-closed detailed-stage read for one exact computed source. Values are decoded from the
    /// authorized sessions in this read, never from independently persisted daily/series copies.
    private func derivedDetailedStageRows(
        store: WhoopStore,
        deviceId: String,
        key: String,
        from: String,
        to: String
    ) async -> [(day: String, value: Double)] {
        do {
            let habitualMidsleepSec = try await strictHabitualMidsleepSec(store: store)
            let bySource = try await strictSleepSessions(
                store: store,
                ids: [deviceId],
                from: 0,
                to: Int.max,
                limit: 100_000)
            let minutesByDay = Self.publishableDetailedStageMinutesByDay(
                bySource[deviceId] ?? [],
                habitualMidsleepSec: habitualMidsleepSec)
            return minutesByDay.keys.sorted().compactMap { day in
                guard day >= from,
                      day <= to,
                      let minutes = minutesByDay[day],
                      let value = Self.detailedStageValue(
                        key: key,
                        minutes: minutes) else { return nil }
                return (day, value)
            }
        } catch {
            return []
        }
    }

    /// Exact sessions whose locally computed detail may publish. Every fragment in the selected
    /// main-night group must retain a stage payload and exact-session R-R counts.
    nonisolated static func publishableDetailedStageSessionFingerprints(
        _ sessions: [CachedSleepSession],
        habitualMidsleepSec: Int?
    ) -> Set<SleepStageEvidenceFingerprint> {
        var publishable = Set<SleepStageEvidenceFingerprint>()
        for bucket in wakeDaySessionBuckets(sessions) {
            let daySessions = bucket.sessions
            let offsetSec = daySessions.max(by: { $0.endTs < $1.endTs }).map {
                TimeZone.current.secondsFromGMT(
                    for: Date(timeIntervalSince1970: TimeInterval($0.endTs)))
            } ?? TimeZone.current.secondsFromGMT()
            let indices = ScoreConfidence.publishableDetailedSleepStageSessionIndices(
                blocks: daySessions.map {
                    SleepStageTotals.NightBlock(
                        start: $0.effectiveStartTs,
                        end: $0.endTs)
                },
                rrEligibleWindowCounts: daySessions.map(\.rrEligibleWindowCount),
                rrValidWindowCounts: daySessions.map(\.rrValidWindowCount),
                independentlyStagedImport: false,
                offsetSec: offsetSec,
                habitualMidsleepSec: habitualMidsleepSec)
            guard !indices.isEmpty,
                  indices.allSatisfy({
                      Self.detailedStageMinutes(for: daySessions[$0]) != nil
                  }) else { continue }
            for index in indices {
                publishable.insert(SleepStageEvidenceFingerprint(daySessions[index]))
            }
        }
        return publishable
    }

    /// Wake days whose selected local main-night group passes exact-session publication evidence.
    nonisolated static func publishableDetailedStageDays(
        _ sessions: [CachedSleepSession],
        habitualMidsleepSec: Int?,
        from: String = "0000-01-01",
        to: String = "9999-12-31"
    ) -> Set<String> {
        let publishable = publishableDetailedStageSessionFingerprints(
            sessions,
            habitualMidsleepSec: habitualMidsleepSec)
        return Set(wakeDaySessionBuckets(sessions).compactMap { bucket in
            guard bucket.day >= from,
                  bucket.day <= to,
                  bucket.sessions.contains(where: {
                      publishable.contains(SleepStageEvidenceFingerprint($0))
                  }) else { return nil }
            return bucket.day
        })
    }

    /// Detailed stage totals derived from the exact authorized session payloads. Persisted daily/series
    /// copies are intentionally ignored: a crash between session and day writes, or a later edit, must not
    /// expose stale deep/REM/light values merely because the wake-day key still matches.
    nonisolated static func publishableDetailedStageMinutesByDay(
        _ sessions: [CachedSleepSession],
        habitualMidsleepSec: Int?
    ) -> [String: SleepStageTotals.Minutes] {
        let publishable = publishableDetailedStageSessionFingerprints(
            sessions,
            habitualMidsleepSec: habitualMidsleepSec)
        var byDay: [String: SleepStageTotals.Minutes] = [:]
        for bucket in wakeDaySessionBuckets(sessions) {
            let selected = bucket.sessions.filter {
                publishable.contains(SleepStageEvidenceFingerprint($0))
            }
            guard !selected.isEmpty else { continue }
            let decoded = selected.compactMap { session in
                Self.detailedStageMinutes(for: session)
            }
            // A bridged main night is one customer-facing result. Never publish only the fragments
            // that happened to decode, even if a future policy refactor weakens the earlier guard.
            guard decoded.count == selected.count else { continue }
            var total = SleepStageTotals.Minutes()
            for minutes in decoded {
                total.awake += minutes.awake
                total.light += minutes.light
                total.deep += minutes.deep
                total.rem += minutes.rem
            }
            if total.inBed > 0 { byDay[bucket.day] = total }
        }
        return byDay
    }

    nonisolated static func detailedStageValue(
        key: String,
        minutes: SleepStageTotals.Minutes
    ) -> Double? {
        switch key {
        case "sleep_deep_min", "deep_min": return minutes.deep
        case "sleep_rem_min", "rem_min": return minutes.rem
        case "sleep_light_min", "core_min": return minutes.light
        case "sleep_awake_min", "awake_min": return minutes.awake
        case "restorative_min": return minutes.deep + minutes.rem
        case "restorative_pct":
            guard minutes.asleep > 0 else { return nil }
            return (minutes.deep + minutes.rem) / minutes.asleep * 100
        default: return nil
        }
    }

    /// Preserve every non-stage field while replacing local detailed stages with the session-derived
    /// snapshot. `nil` clears all three fields, preventing an unsupported or edited night from retaining
    /// a stale prior split.
    nonisolated static func replacingDetailedStageColumns(
        _ row: DailyMetric,
        with minutes: SleepStageTotals.Minutes?
    ) -> DailyMetric {
        DailyMetric(
            day: row.day,
            totalSleepMin: row.totalSleepMin,
            efficiency: row.efficiency,
            deepMin: minutes?.deep,
            remMin: minutes?.rem,
            lightMin: minutes?.light,
            disturbances: row.disturbances,
            restingHr: row.restingHr,
            avgHrv: row.avgHrv,
            recovery: row.recovery,
            strain: row.strain,
            exerciseCount: row.exerciseCount,
            spo2Pct: row.spo2Pct,
            skinTempDevC: row.skinTempDevC,
            respRateBpm: row.respRateBpm,
            steps: row.steps,
            activeKcalEst: row.activeKcalEst,
            spo2Red: row.spo2Red,
            spo2Ir: row.spo2Ir,
            hrvMethod: row.hrvMethod)
    }

    /// Bridge the complete source timeline before assigning local wake days. A split night can cross
    /// midnight between fragments; assigning each row first would let its early half publish alone.
    nonisolated static func wakeDaySessionBuckets(
        _ sessions: [CachedSleepSession],
        timeZone: TimeZone = .current
    ) -> [(day: String, sessions: [CachedSleepSession])] {
        let blocks = sessions.map {
            SleepStageTotals.NightBlock(
                start: $0.effectiveStartTs,
                end: $0.endTs)
        }
        return SleepStageTotals.wakeDayBuckets(
            blocks,
            offsetAtEpochSec: { epoch in
                timeZone.secondsFromGMT(
                    for: Date(timeIntervalSince1970: TimeInterval(epoch)))
            }
        ).map { bucket in
            let rows = bucket.groups
                .flatMap(\.indices)
                .map { sessions[$0] }
                .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            return (bucket.day, rows)
        }
    }

    nonisolated private static func hasStagePayload(_ json: String?) -> Bool {
        SleepStageTotals.minutes(fromStagesJSON: json) != nil
    }

    nonisolated private static func detailedStageMinutes(
        for session: CachedSleepSession
    ) -> SleepStageTotals.Minutes? {
        let clamped = SleepStageTotals.clampStagesToOnset(
            session.stagesJSON,
            onsetSec: session.effectiveStartTs)
        return SleepStageTotals.minutes(fromStagesJSON: clamped)
    }

    /// The merged DailyMetric column backing an Explore metric key, for the days the imported/computed
    /// metricSeries doesn't cover (strap-only WHOOP 5 users). Mirrors InsightsView.dailyOutcome and
    /// Android's dailyPick, extended to every Explore "my-whoop" key that maps to a daily column.
    /// Also handles the Apple-compatible sleep aliases (asleep_min / deep_min / rem_min / core_min) the
    /// resolver may request when filling an Apple candidate from its daily columns. Keys with no daily
    /// column (avg_hr / max_hr …) return nil , they resolve from metricSeries only.
    ///
    /// `sleep_performance` (the Rest composite, 0–100) is NOT a stored column: IntelligenceEngine persists
    /// it as a metricSeries point. But a Bluetooth-only WHOOP 5 user , and, crucially, the SELECTED
    /// (just-synced) day before the heavy daily pass has projected the series , has the night's totals
    /// banked on the DailyMetric row while the metricSeries point is still missing. Without this case the
    /// resolver returned no Rest for that day and Today borrowed the latest historical value (#614). Derive
    /// it on the fly from the same banked totals via the single source of truth
    /// `AnalyticsEngine.Rest.composite(daily:)` , the SAME composite the series carries (what
    /// IntelligenceEngine projects) , so the day resolves to its own Rest. Consistency is left to the
    /// scorer's neutral default here (the daily row carries no regularity term). Mirrors Android
    /// WhoopRepository.dailyColumn / RestScorer.restFromDaily.
    ///
    /// Internal + nonisolated (not private) so the pure `EditMergePrecedenceTests` can exercise the #614
    /// derivation directly off the main actor, the same way Android's `internal fun dailyColumn` is
    /// unit-tested. No non-test caller outside this type.
    nonisolated static func dailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery":         return d.recovery
        case "hrv":              return d.avgHrv
        case "rhr", "resting_hr": return d.restingHr.map(Double.init)
        case "strain":           return d.strain
        case "resp_rate":        return d.respRateBpm
        case "spo2":             return d.spo2Pct
        case "skin_temp":        return d.skinTempDevC
        case "sleep_total_min", "asleep_min": return d.totalSleepMin
        case "sleep_efficiency": return d.efficiency
        case "sleep_deep_min", "deep_min": return d.deepMin
        case "sleep_rem_min", "rem_min":   return d.remMin
        case "sleep_light_min", "core_min": return d.lightMin
        case "sleep_performance": return AnalyticsEngine.Rest.composite(daily: d)
        case "steps":            return d.steps.map(Double.init)
        case "active_kcal", "energy_kcal": return d.activeKcalEst
        default:                 return nil
        }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        // For the canonical WHOOP source, UNION the keys present under the active strap too, so a re-added
        // strap's series keys still list alongside the canonical history's. Other sources read verbatim.
        guard source == canonicalDeviceId, deviceId != canonicalDeviceId else {
            return (try? await store.metricKeys(deviceId: source)) ?? []
        }
        var keys = Set<String>()
        for id in importedReadIds { keys.formUnion((try? await store.metricKeys(deviceId: id)) ?? []) }
        return keys.sorted()
    }

    /// User-facing catalog values recorded on one exact local day. This is intentionally one bounded
    /// metric-series query, then the same source-precedence resolver used by Explore. DailyMetric-backed
    /// values are rendered by the day overview's core sections and do not need a second database read.
    func trackedMetrics(day: String) async -> [DayTrackedMetric] {
        guard let store = await ensureStore(),
              let rows = try? await store.metricSeries(day: day)
        else { return [] }

        let values = Dictionary(
            rows.filter { $0.value.isFinite }.map {
                ($0.deviceId + "\u{1F}" + $0.key, $0.value)
            },
            uniquingKeysWith: { _, newer in newer }
        )

        func value(source: String, key: String) -> Double? {
            values[source + "\u{1F}" + key]
        }

        let catalogMetrics = MetricCatalog.all.compactMap { descriptor in
            if descriptor.source == Self.appleHealthSource, descriptor.key == "total_kcal" {
                for source in [Self.appleHealthSource, Self.healthConnectSource] {
                    if let active = value(source: source, key: "active_kcal"),
                       let resting = value(source: source, key: "basal_kcal") {
                        return DayTrackedMetric(descriptor: descriptor, value: active + resting)
                    }
                }
                return nil
            }

            let candidates = Self.sourceCandidates(
                forKey: descriptor.key,
                preferredSource: descriptor.source,
                actualWhoopSource: deviceId
            )
            guard let resolved = candidates.lazy.compactMap({
                value(source: $0.source, key: $0.key)
            }).first else { return nil }
            return DayTrackedMetric(descriptor: descriptor, value: resolved)
        }

        let representedKeys = Set(catalogMetrics.map { $0.descriptor.key })
        let fallbackGroups = Dictionary(grouping: rows.filter {
            $0.value.isFinite && Self.isUserFacingDayMetric(source: $0.deviceId, key: $0.key)
        }, by: {
            Self.canonicalDayMetricKey($0.key)
        })
        let fallbackMetrics = fallbackGroups
        .keys
        .sorted()
        .compactMap { key -> DayTrackedMetric? in
            guard !representedKeys.contains(key),
                  let candidates = fallbackGroups[key],
                  let selected = candidates.min(by: {
                      Self.dayMetricSourceRank($0.deviceId, key: key, activeDeviceId: deviceId)
                          < Self.dayMetricSourceRank($1.deviceId, key: key, activeDeviceId: deviceId)
                  })
            else { return nil }
            return DayTrackedMetric(
                descriptor: Self.fallbackDayMetricDescriptor(
                    key: key,
                    source: selected.deviceId
                ),
                value: selected.value
            )
        }

        return catalogMetrics + fallbackMetrics
    }

    private static func canonicalDayMetricKey(_ key: String) -> String {
        switch key {
        case "weightKg": return "weight"
        case "heightCm": return "height"
        case "bodyFatPct": return "body_fat"
        default: return key
        }
    }

    private static func isUserFacingDayMetric(source: String, key: String) -> Bool {
        guard source != "cycle-tracking" else { return false }
        return !key.contains("_profile_") && !key.hasSuffix("_marker")
    }

    private static func dayMetricSourceRank(
        _ source: String,
        key: String,
        activeDeviceId: String
    ) -> Int {
        let preferred: [String]
        switch key {
        case "calories_in", "protein_g", "carbs_g", "fat_g":
            preferred = [NutritionLogContract.deviceId, "nutrition-csv"]
        case "mood":
            preferred = ["noop-mood"]
        case "weight", "height", "body_fat", "lean_mass", "bmi", "body_temp",
             "wrist_temp", "vo2max":
            preferred = [
                appleHealthSource,
                healthConnectSource,
                activeDeviceId,
                whoopSource,
                activeDeviceId + "-noop",
                whoopSource + "-noop",
            ]
        default:
            preferred = [
                activeDeviceId,
                whoopSource,
                activeDeviceId + "-noop",
                whoopSource + "-noop",
                appleHealthSource,
                healthConnectSource,
                "xiaomi-band",
            ]
        }
        return preferred.firstIndex(of: source) ?? preferred.count
    }

    private static func fallbackDayMetricDescriptor(key: String, source: String) -> MetricDescriptor {
        let title: String
        let unit: String
        switch key {
        case "weight":
            title = String(localized: "Weight")
            unit = "kg"
        case "height":
            title = String(localized: "Height")
            unit = "cm"
        case "body_fat":
            title = String(localized: "Body Fat")
            unit = "%"
        default:
            title = key.replacingOccurrences(of: "_", with: " ").capitalized
            unit = ""
        }
        return MetricDescriptor(
            key: key,
            title: title,
            category: "Health",
            unit: unit,
            source: source,
            icon: "chart.xyaxis.line",
            decimals: 1,
            higherIsBetter: nil
        )
    }

    /// Native journal answers live under this dedicated source id. The journal table has no
    /// `source` column (PK is (deviceId, day, question)), so writing native answers under the
    /// imported `deviceId` would let a CSV re-import silently overwrite them , and clears could
    /// then delete imported rows. A separate device id keeps the two streams independent.
    static let journalDeviceId = "noop-journal"

    /// Logged behaviours (imported WHOOP journal ∪ native noop-journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var imported: [JournalEntry] = []
        for id in importedReadIds { imported += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        let native = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                      from: from, to: to)) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Exact-day journal read for calendar summaries. Native answers win over imported answers for the
    /// same question, matching the editable Journal screen without loading years of history.
    func journalEntries(day: String) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        var imported: [JournalEntry] = []
        for id in importedReadIds {
            imported += (try? await store.journalEntries(
                deviceId: id,
                from: day,
                to: day
            )) ?? []
        }
        let native = (try? await store.journalEntries(
            deviceId: Self.journalDeviceId,
            from: day,
            to: day
        )) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Imported journal rows only (used by the logging card to adopt the export's exact question
    /// strings into the catalog, so logged and imported days group under one behaviour).
    func importedJournalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var rows: [JournalEntry] = []
        for id in importedReadIds { rows += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        return rows
    }

    /// One day's native answers (question → answeredYes) for the logging card's chip state. A
    /// targeted read , the merged list carries no deviceId, so it can't distinguish native rows.
    func nativeJournalAnswers(day: String) async -> [String: Bool] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        return Dictionary(rows.map { ($0.question, $0.answeredYes) },
                          uniquingKeysWith: { _, last in last })
    }

    /// One day's native numeric values (question → value) for the logging card's numeric fields.
    /// Only rows that carry a numericValue appear; a plain yes/no answer is absent.
    func nativeJournalNumeric(day: String) async -> [String: Double] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        var out: [String: Double] = [:]
        for r in rows { if let v = r.numericValue { out[r.question] = v } }
        return out
    }

    /// Distinct local-day keys (yyyy-MM-dd) in the inclusive range [from, to] that carry at least one
    /// NATIVE journal entry (the "noop-journal" device id only - matching the Android widget's
    /// `repo.journal(JOURNAL_DEVICE_ID, from, to)`). Backs the #627 Today journal widget's completion
    /// strip. Read-only.
    func nativeJournalDays(from: String, to: String) async -> Set<String> {
        guard let store = await ensureStore() else { return [] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: from, to: to)) ?? []
        return Set(rows.map { $0.day })
    }

    /// Union; the NATIVE row wins per (day, question) , the in-app answer is the user's most recent
    /// explicit action and stays editable, unlike the immutable imported history.
    nonisolated static func mergeJournal(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    /// Write one native answer (day per the importer's wake-day convention).
    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        do {
            _ = try await store.upsertJournal(
                [JournalEntry(day: day, question: question, answeredYes: answeredYes, notes: notes)],
                deviceId: Self.journalDeviceId)
            DailyReviewNotifications.setJournalCompleted(true, day: day)
        } catch {}
    }

    /// Write one native NUMERIC answer (#322): stores the value AND answeredYes=true, so the existing
    /// BehaviorInsights with/without split treats a numeric log as "behaviour occurred" unchanged,
    /// while the value is carried for dose-response. Day per the importer's wake-day convention.
    func saveJournalNumeric(day: String, question: String, value: Double, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        do {
            _ = try await store.upsertJournal(
                [JournalEntry(day: day, question: question, answeredYes: true, notes: notes,
                              numericValue: value)],
                deviceId: Self.journalDeviceId)
            DailyReviewNotifications.setJournalCompleted(true, day: day)
        } catch {}
    }

    /// Per-question numeric series (question → [day: value]) over the imported ∪ native union, native
    /// winning per (day, question). Only rows that carry a numericValue contribute, so a numeric
    /// journal item ("caffeine mg", "alcohol units") becomes a daily series the effect ranker can
    /// consume the same way it consumes any metric series. Behaviours logged only as yes/no never
    /// appear here (nil numericValue), so this is additive and never perturbs the boolean effects.
    func numericJournalSeries() async -> [String: [String: Double]] {
        let entries = await journalEntries()
        var out: [String: [String: Double]] = [:]
        for e in entries {
            if let v = e.numericValue { out[e.question, default: [:]][e.day] = v }
        }
        return out
    }

    /// Clear one native answer (never touches imported rows , scoped to the dedicated source id).
    func clearJournalAnswer(day: String, question: String) async {
        guard let store = await ensureStore() else { return }
        do {
            _ = try await store.deleteJournal(
                deviceId: Self.journalDeviceId,
                day: day,
                question: question
            )
            await reconcileDailyReviewJournalDay(day, store: store)
        } catch {}
    }

    /// Repair the bounded evening schedule after launch, restore, or an out-of-band data refresh.
    func reconcileDailyReviewJournalReminders(now: Date = Date()) async {
        let horizon = DailyReviewNotifications.journalHorizonDayKeys(now: now)
        guard let store = await ensureStore(),
              let first = horizon.first,
              let last = horizon.last
        else { return }
        guard let rows = try? await store.journalEntries(
            deviceId: Self.journalDeviceId,
            from: first,
            to: last
        ) else { return }
        DailyReviewNotifications.reconcileCompletedJournalDays(
            Set(rows.map(\.day)),
            now: now
        )
    }

    private func reconcileDailyReviewJournalDay(
        _ day: String,
        store: WhoopStore
    ) async {
        guard let rows = try? await store.journalEntries(
            deviceId: Self.journalDeviceId,
            from: day,
            to: day
        ) else { return }
        DailyReviewNotifications.setJournalCompleted(!rows.isEmpty, day: day)
    }

    /// All workouts (Whoop + Apple Health + on-device detected bouts), newest first.
    ///
    /// Detected bouts are surfaced with an honest "Detected" badge so the user can see , and
    /// dismiss or re-label , a duplicate the auto-detector created (#107). Dismissed detected spans
    /// are filtered HERE so every consumer (Workouts screen, Today, Coach context) agrees: the engine
    /// re-derives the detected rows each run, so a plain delete would resurrect them; the dismissed
    /// span list is the durable "not a workout" record.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION the active strap + canonical (and their computed siblings) so workouts banked under the
        // canonical "my-whoop" before a re-add still show, alongside the re-added strap's live workouts.
        // De-dup identical same-source rows that appear under both union ids by natural key (the cross-SOURCE
        // dedup below only collapses strap-vs-Apple twins, not a row present in two strap namespaces).
        var rows: [WorkoutRow] = []
        for id in importedReadIds { rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? [] }
        for id in computedReadIds { rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? [] }
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        // Imported lifting sessions (Hevy / Liftosaur) live under their own "lifting" source.
        rows += (try? await store.workouts(deviceId: "lifting", from: lo, to: hi, limit: 5000)) ?? []
        // #29: imported activity FILES (FIT / GPX / TCX) live under their own "activity-file" source - read
        // them too, or a successful file import never appears in the Workouts list (Data Sources counts it,
        // the load didn't). HR is reconciled from the strap trace at the end like every other row.
        rows += (try? await store.workouts(deviceId: "activity-file", from: lo, to: hi, limit: 5000)) ?? []
        rows = Self.dedupWorkoutsByNaturalKey(rows)
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        // #687: collapse the SAME activity tracked live under the strap AND imported from Health Connect /
        // Apple Health into one richer entry , they sit under different sources so without this they show
        // as two sessions. Dedup runs on the dismissed-filtered set, before the final newest-first sort.
        let filtered = rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
        // Workouts & GPS test mode: when on, run the dedup twin which returns the BYTE-IDENTICAL kept list
        // plus a trace line per collapsed cross-source pair, tagged `.workouts`. Zero-cost when off (the gate
        // is one UserDefaults bool read inside emitWorkouts), and the kept list equals dedupCrossSource(...)
        // exactly, so the workout list the screen shows is unchanged.
        let deduped: [WorkoutRow]
        if TestCentre.active(.workouts), workoutsLog != nil {
            let (kept, trace) = WorkoutSource.dedupCrossSourceTrace(filtered)
            for line in trace { emitWorkouts(line) }
            deduped = kept
        } else {
            deduped = WorkoutSource.dedupCrossSource(filtered)
        }
        let visible = deduped.sorted { $0.startTs > $1.startTs }
        return await reconcileWorkoutHrWithTrace(visible, store: store)
    }

    /// Workouts overlapping one exact half-open timestamp window, newest first.
    ///
    /// This is the daily-dashboard counterpart to `workoutRows(days:)`: it applies the same source union,
    /// dismissal, cross-source de-duplication, and trace reconciliation, but lets SQLite select the tiny
    /// requested window first. A Today swipe therefore cannot trigger a 4,000-day workout scan.
    func workoutRows(overlappingFrom from: Int, to: Int, limit: Int = 250) async -> [WorkoutRow] {
        guard to > from, let store = await ensureStore() else { return [] }
        var rows: [WorkoutRow] = []
        for id in importedReadIds {
            rows += (try? await store.workoutsOverlapping(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        for id in computedReadIds {
            rows += (try? await store.workoutsOverlapping(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        for id in [Self.appleHealthSource, "lifting", Self.activityFileSource] {
            rows += (try? await store.workoutsOverlapping(
                deviceId: id, from: from, to: to, limit: limit)) ?? []
        }

        rows = Self.dedupWorkoutsByNaturalKey(rows)
        let dismissed = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        let visible = rows.filter { !WorkoutSource.isDismissed($0, spans: dismissed) }
        let deduped = WorkoutSource.dedupCrossSource(visible).sorted { $0.startTs > $1.startTs }
        return await reconcileWorkoutHrWithTrace(deduped, store: store, cap: limit)
    }

    /// DISPLAY-ONLY: reconcile each workout's shown Avg/Max HR with the strap trace that actually drives
    /// its graph / zones / effort (#77, #499). The detail screen always charts (`workoutHrBuckets`) and
    /// zone-bins (`workoutZoneMinutes`) the strap's own ~1 Hz samples over `[startTs, endTs]`; the
    /// displayed Avg HR comes from the stored `avgHr`. Those can DIVERGE , a hand-edited Avg (128→139)
    /// changes the number but not the trace, so the average no longer matches the graph/zones/effort
    /// (#499). Here the stored field defers to the trace whenever the trace is present:
    ///
    ///  - STRAP-NATIVE rows (`manual` / detected `<id>-noop`) are charted/zoned/scored straight from this
    ///    strap trace, so their Avg HR is ALWAYS recomputed as the true mean of those samples (and Max →
    ///    true peak) , a manual edit can no longer drift them out of agreement with the graph.
    ///  - IMPORTED rows (Apple Health / Health Connect / Whoop CSV) carry their OWN avg/max; we only FILL
    ///    them when nil (and the strap happened to be worn), never overriding a real imported value.
    ///
    /// Requires `minSamples` (~1 min) so stray samples can't fabricate an average, and caps the per-row
    /// HR reads so a huge history can't jank first paint. NEVER persisted , a read-time projection of the
    /// trace (the workout PK upsert would wipe it anyway), recomputed on every load so display == graph
    /// == zones == effort by construction. Kotlin twin: `WhoopRepository.fillWorkoutHrFromStrap`.
    private func reconcileWorkoutHrWithTrace(_ rows: [WorkoutRow], store: WhoopStore,
                                             minSamples: Int = 60, cap: Int = 300) async -> [WorkoutRow] {
        // #833 (on-open freeze): this used to run a SEQUENTIAL per-row loop, each awaiting one
        // `store.hrSamples(.., limit: 8000)` then reducing up to 8000 ints SYNCHRONOUSLY on the @MainActor
        // (sum + max), for up to `cap` rows. On a deep history that beach-balled first paint. Two changes,
        // both output-preserving: (1) the eligible rows' reads run with BOUNDED concurrency (chunks of
        // `readChunk`) so the single-connection store isn't swamped, and (2) the per-row sum/max moved OFF
        // the main actor into the `nonisolated static` `reduceWorkoutHr`. Eligibility + the `cap` budget are
        // resolved FIRST in row order (identical to the old loop: budget is spent on eligible rows top-down
        // and reads stop once it hits 0), so exactly the same rows are read and the result is byte-identical.
        let readChunk = 8

        // Phase 1 , resolve eligibility + spend the `cap` budget in ORIGINAL row order, exactly as the old
        // sequential loop did. Only these indices get a trace read; everything else passes through verbatim.
        // (Strap-native is recomputed in Phase 3 from the same `classify`, so it isn't carried here.)
        var budget = cap
        var eligibleIndices: [Int] = []
        for (i, row) in rows.enumerated() {
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            // #961: a strap-native row whose Effort (strain) is nil is ALSO eligible even when its avgHr is
            // already present, so a session that ended with an HR but no strain (sparse live HR at save)
            // still gets its Effort backfilled once the strap trace covers the window. Needs the injected
            // profile; without it the strain fill is skipped and eligibility is unchanged from before.
            let needsStrainFill = strapNative && row.strain == nil && strainProfile != nil
            guard row.endTs > row.startTs, budget > 0,
                  strapNative || row.avgHr == nil || needsStrainFill else { continue }
            budget -= 1
            eligibleIndices.append(i)
        }

        // Phase 2 , read each eligible window with BOUNDED concurrency (chunks of `readChunk`) and reduce it
        // OFF the main actor, then return only PLAIN Ints (index, avg, peak) from the child tasks. Keeping the
        // `WorkoutRow` build out of the group means only Sendable scalars cross the task boundary; the row is
        // rebuilt on the main actor in Phase 3. The samples are the very ones the graph + zones + effort use
        // (strap deviceId, COALESCEd PPG fallback). Keyed by row index so reassembly stays in original order.
        // #961: capture the injected profile ONCE (a Sendable scalar pair) so each child task can compute a
        // backfill strain off the main actor. nil ⇒ no fill, and the strain slot always comes back nil.
        let strainProfile = self.strainProfile
        var reduced: [Int: (avg: Int, peak: Int, strain: Double?)] = [:]
        for chunkStart in stride(from: 0, to: eligibleIndices.count, by: readChunk) {
            let chunk = eligibleIndices[chunkStart..<min(chunkStart + readChunk, eligibleIndices.count)]
            await withTaskGroup(of: (index: Int, avg: Int, peak: Int, strain: Double?)?.self) { group in
                for idx in chunk {
                    let startTs = rows[idx].startTs
                    let endTs = rows[idx].endTs
                    // Only strap-native rows still missing a strain get one computed (the fill target); an
                    // imported row, or one that already has a strain, returns nil for the slot and keeps its
                    // own. Resolve this on the main actor (WorkoutSource.classify) and capture the plain Bool,
                    // so the child task crosses only Sendable scalars.
                    let cls = WorkoutSource.classify(rows[idx].source)
                    let wantStrain = (cls == .manual || cls == .detected) && rows[idx].strain == nil
                    // #510: read HR under the workout's OWN recording strap, not a single active id. A detected
                    // row's `source` IS its computed strap id ("<base>-noop"), so a bout auto-detected on a 2nd
                    // WHOOP reads "<base>" instead of the active strap's empty window. Resolved on the main actor;
                    // only the resulting Sendable String crosses into the task.
                    let hrDeviceId = Self.workoutHrDeviceId(source: rows[idx].source, activeStrapId: deviceId)
                    group.addTask { [hrDeviceId] in
                        let samples = (try? await store.hrSamples(deviceId: hrDeviceId,
                                                                  from: startTs, to: endTs,
                                                                  limit: 8000)) ?? []
                        guard samples.count >= minSamples else { return nil }
                        // Sum + max over up to 8000 ints , off the @MainActor (the freeze fix).
                        let (avg, peak) = Repository.reduceWorkoutHr(samples)
                        // #961: recompute Effort from the SAME samples the graph/zones use, off-main. Uses the
                        // app's StrainScorer with the injected HRmax + sex so it matches endWorkout's own score;
                        // StrainScorer returns nil on a still-too-thin window (never a fabricated number).
                        let strain: Double?
                        if wantStrain, let p = strainProfile {
                            strain = StrainScorer.strain(samples, maxHR: p.hrMax, sex: p.sex)
                        } else {
                            strain = nil
                        }
                        return (index: idx, avg: avg, peak: peak, strain: strain)
                    }
                }
                for await result in group {
                    if let r = result { reduced[r.index] = (avg: r.avg, peak: r.peak, strain: r.strain) }
                }
            }
        }

        // Phase 3 , reassemble in ORIGINAL order. For an eligible row that cleared `minSamples` apply the
        // off-main reduction (strap-native → trace IS the source: override avg + max; imported → fill avg,
        // keep imported max). Every other row passes through verbatim. Byte-identical to the old loop's row.
        return zip(rows.indices, rows).map { i, row in
            guard let r = reduced[i] else { return row }
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            let newMax = strapNative ? r.peak : (row.maxHr ?? r.peak)
            // #961: FILL a nil Effort from the recomputed strain (never override a stored one). Display-only,
            // like the avg/max reconcile , the workout-PK upsert would wipe it, and the backend rescore
            // persists the durable value on the next analyze tick.
            let newStrain = row.strain ?? r.strain
            return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                              source: row.source, durationS: row.durationS, energyKcal: row.energyKcal,
                              avgHr: r.avg, maxHr: newMax, strain: newStrain, distanceM: row.distanceM,
                              zonesJSON: row.zonesJSON, notes: row.notes)
        }
    }

    /// #510 (Kotlin twin: `WhoopRepository.workoutHrDeviceId`). The device id whose `hrSample` rows back a
    /// workout's Avg HR / Effort reconcile. A DETECTED row's own `source` IS its computed strap id
    /// ("<base>-noop"), so strip the suffix to read HR under the raw "<base>" - a bout auto-detected on a
    /// SECOND WHOOP no longer reads the active strap's empty window (which blanked its reconcile). MANUAL and
    /// IMPORTED rows carry no strap id in `source`, so they reconcile against the active strap [activeStrapId]
    /// as before; on a single-device install a detected "<base>-noop" strips to the active id, so the read is
    /// byte-identical. (The Kotlin twin also keys MANUAL rows on their stored deviceId; the Swift read-model
    /// `WorkoutRow` carries no deviceId, so a manual session created on a NON-active strap reconciles here
    /// against the active strap instead — a minor, display-only divergence, never persisted.)
    nonisolated static func workoutHrDeviceId(source: String, activeStrapId: String) -> String {
        guard WorkoutSource.classify(source) == .detected else { return activeStrapId }
        return source.hasSuffix("-noop") ? String(source.dropLast(5)) : source
    }

    /// #833: the per-workout HR reduction (mean bpm → rounded Int, peak bpm), pulled OUT of the @MainActor
    /// reconcile loop. `nonisolated static` so a `withTaskGroup` child task runs it OFF the main actor , a
    /// dense workout's up-to-8000 1 Hz samples no longer sum/max on the actor that drives SwiftUI. Pure +
    /// unit-testable. Byte-identical to the old inline `reduce(0,+)` / `max()`: same rounding, same peak.
    /// Caller guarantees `samples` is non-empty (the `minSamples` gate), so the mean divisor is never zero.
    nonisolated static func reduceWorkoutHr(_ samples: [HRSample]) -> (avg: Int, peak: Int) {
        var sum = 0
        var peak = 0
        for s in samples {
            sum += s.bpm
            if s.bpm > peak { peak = s.bpm }
        }
        let avg = Int((Double(sum) / Double(samples.count)).rounded())
        return (avg, peak)
    }

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete)
    //
    // Manual workouts live under the strap source (deviceId == `deviceId`, source "manual") , the same
    // place v1.67's live-tracked sessions already land (AppModel.endWorkout). Detected bouts live under
    // the computed `computedDeviceId` with sport "detected" and are wiped + re-derived each engine run,
    // so the only durable way to keep one hidden after a re-detect is the dismissed-span list below.

    /// The persisted dismissed detected spans ("startTs:endTs"). Read straight off UserDefaults so the
    /// read path and the write path share one source of truth (the engine never sees this , it always
    /// re-derives; only the read filter and these mutators consult it).
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// Persist a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from:
    ///  - editing a DETECTED bout ("Edit details…") replaces it with this manual row , the detected
    ///    original is dismissed durably so the re-detector doesn't bring it back (else both would show);
    ///  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale strap row
    ///    first (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
    ///  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add), so its
    ///    history is never touched.
    @discardableResult
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async -> Bool {
        guard let store = await ensureStore() else { return false }

        // Commit the replacement before retiring the old row. A database failure must never make an edit
        // destructive, and callers such as the auto-detect card need a truthful success value so they keep
        // the candidate visible when persistence fails.
        do {
            try await store.upsertWorkouts([row], deviceId: deviceId)
        } catch {
            return false
        }

        if let old, WorkoutSource.classify(old.source) == .detected {
            await dismissDetected(old)
        } else if let old, old.startTs != row.startTs || old.sport != row.sport {
            _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: old.sport,
                                                from: old.startTs, to: old.startTs)
            // #10: the GPS route lives in RouteStore keyed by the natural key (startTs + sport), NOT in the
            // DB row. Re-keying the DB row above without moving the route would orphan it under the OLD key,
            // so the detail view's route + distance vanish after a sport/start edit. Re-key the route too:
            // read it under the old key and, ONLY if one exists, store it under the new key then drop the old.
            if let route = RouteStore.load(startTs: old.startTs, sport: old.sport) {
                RouteStore.store(route, startTs: row.startTs, sport: row.sport)
                RouteStore.remove(startTs: old.startTs, sport: old.sport)
            }
        }
        noteWorkoutsChanged()
        return true
    }

    /// Re-label a detected bout: copy it to a manual strap row with the chosen sport, then delete the
    /// detected original. This survives analyzeRecent , the engine wipes + re-derives only sport
    /// "detected" rows under the computed id AND skips any re-derived bout overlapping a real strap
    /// workout, which this copy now is , so the same session is never re-created as a duplicate. (#107)
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await ensureStore() else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes)
        let recordingDeviceId = Self.workoutHrDeviceId(source: row.source, activeStrapId: deviceId)
        _ = try? await store.upsertWorkouts([manual], deviceId: recordingDeviceId)
        _ = try? await store.deleteWorkouts(deviceId: row.source, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
        AutoWorkoutReviewStore.clear(startSec: row.startTs)
        noteWorkoutsChanged()
    }

    /// Dismiss a DETECTED bout the user says isn't a workout. Records its span in the durable dismissed
    /// list (so a re-detect that recreates the same span stays hidden) AND deletes the current row so it
    /// disappears immediately. Idempotent: a span already present isn't duplicated. (#107)
    func dismissDetected(
        _ row: WorkoutRow,
        decisionAction: AutoWorkoutDecisionAction = .removedDetectedWorkout
    ) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        // The app has two detector pipelines with separate durable dismissal stores. Mark the canonical
        // automatic-activity identity too, or removing an auto-saved row would let the suggestion scan
        // recreate the same workout immediately after its database row disappeared.
        let candidate = DetectedWorkout(
            startSec: row.startTs, endSec: row.endTs,
            avgBpm: row.avgHr ?? 60, peakBpm: row.maxHr ?? row.avgHr ?? 60,
            durationMin: max(1, (row.endTs - row.startTs) / 60)
        )
        if rememberDismissedDetectedSuggestion(candidate) {
            AutoWorkoutDecisionHistory.recordSpan(
                startSec: row.startTs,
                endSec: row.endTs,
                action: decisionAction,
                activityName: row.sport
            )
        }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) { spans.append(token); dismissedDetectedSpans = spans }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: row.source, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
        AutoWorkoutReviewStore.clear(startSec: row.startTs)
        noteWorkoutsChanged()
    }

    /// Delete ONE workout by natural key. The read model has no deviceId, so reconstruct it from the
    /// source: detected rows live under the computed id (and also get their span dismissed so they don't
    /// come back); everything else the screen can delete (manual) lives under the strap id.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected { await dismissDetected(row); return }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
        noteWorkoutsChanged()
    }

    /// #64: merge two-or-more overlapping / adjacent MANUAL or DETECTED sessions into ONE manual session
    /// (`merged`, built by the pure `WorkoutMerge.merge`), then retire the originals. Imported history is
    /// NEVER passed here (the caller gates on `WorkoutMerge.canMerge`, and this only writes the manual-row
    /// path), so the imported-read-only invariant holds. Sequence:
    ///   1. re-key at most one GPS route onto the merged natural key (the longest, matching #10), dropping
    ///      the others so no route is orphaned;
    ///   2. save the merged row under the strap id (the manual path);
    ///   3. per original: a DETECTED bout is durably dismissed (so a re-detect can't resurrect it), a
    ///      MANUAL row is deleted by natural key, BUT never touch a source that equals the merged row's
    ///      own natural key (a detected original that shares the merged start/sport would otherwise dismiss
    ///      a span the merged row now occupies).
    /// The caller runs `analyzeRecent` (rescores the merged row's strain from the strap HR, the #598
    /// pattern) + reloads afterwards.
    func mergeWorkouts(_ rows: [WorkoutRow], into merged: WorkoutRow) async {
        guard rows.count >= 2 else { return }
        // Pick the richest route to carry onto the merged key BEFORE deleting the originals (the DB write
        // below doesn't drop routes, so we read + move them explicitly). Keep the longest polyline.
        var bestRoute: (route: WorkoutRoute, startTs: Int, sport: String)?
        for r in rows {
            guard let route = RouteStore.load(startTs: r.startTs, sport: r.sport) else { continue }
            if bestRoute == nil || route.polyline.count > bestRoute!.route.polyline.count {
                bestRoute = (route, r.startTs, r.sport)
            }
        }

        // Save the merged manual row.
        await saveManualWorkout(merged)

        // Retire each original. Skip any row whose natural key matches the merged row's, so we never
        // dismiss/delete the span the merged row now owns.
        for r in rows where !(r.startTs == merged.startTs && r.sport == merged.sport) {
            switch WorkoutSource.classify(r.source) {
            case .detected: await dismissDetected(r)
            case .manual:   await deleteWorkout(r)
            case .whoop, .apple, .lifting, .activityFile:
                // Defensive: canMerge already excludes imported rows; never rewrite imported history.
                continue
            }
            // Drop each original's route unless it's the one we're re-keeping onto the merged key.
            if !(bestRoute?.startTs == r.startTs && bestRoute?.sport == r.sport) {
                RouteStore.remove(startTs: r.startTs, sport: r.sport)
            }
        }

        // Move the kept route onto the merged natural key, then drop it from the old key.
        if let best = bestRoute, !(best.startTs == merged.startTs && best.sport == merged.sport) {
            RouteStore.store(best.route, startTs: merged.startTs, sport: merged.sport)
            RouteStore.remove(startTs: best.startTs, sport: best.sport)
        }
    }

    /// #64: bulk-delete the selected sessions, routing per class exactly like the single-row path
    /// (detected → durable dismiss, manual → delete). Imported rows are never selectable, so never reach
    /// here. The caller reloads afterwards.
    func bulkDeleteWorkouts(_ rows: [WorkoutRow]) async {
        for r in rows {
            switch WorkoutSource.classify(r.source) {
            case .detected: await dismissDetected(r)
            case .manual:   await deleteWorkout(r)
            case .whoop, .apple, .lifting, .activityFile: continue
            }
        }
    }

    // MARK: - Auto-detect workouts (opt-in MVP) , the "Looks like a workout?" Today prompt
    //
    // Pure read + suggestion path for the opt-in `AutoWorkoutDetector`. This is SEPARATE from the
    // gravity-gated detected-bouts pipeline above (which writes "detected" rows under the computed id):
    // nothing here is ever persisted as a workout until the user taps Save, and a dismissed suggestion
    // is remembered in its OWN durable span list (distinct key from `dismissedDetected`) so it never
    // re-prompts. The detector + thresholds are byte-mirrored in the Android twin.

    /// Dismissed AUTO-DETECT identities (`start:<startSec>`; legacy `start:end` is still accepted),
    /// kept apart from the gravity detector's
    /// `dismissedDetected` list so the two features never cross-suppress each other.
    private static let autoDetectDismissedKey = "workouts.autoDetectDismissed"
    private var autoDetectDismissedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.autoDetectDismissedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoDetectDismissedKey) }
    }

    /// Stable token for one auto-detect bout. Endpoint changes do not create a new identity.
    private func autoDetectToken(_ w: DetectedWorkout) -> String {
        AutoWorkoutSuggestionIdentity.token(startSec: w.startSec, endSec: w.endSec)
    }

    /// Hard cap on the dismissed-span list , a backstop so the UserDefaults array can't grow without
    /// bound even in pathological use. 200 most-recent (by span END) is far more than detection's ~2-day
    /// window can ever re-surface; the age prune below normally keeps it much shorter. Mirrors Android.
    private static let autoDetectDismissedMax = 200
    /// Spans whose END is older than this many seconds can never be re-suggested (detection only scans
    /// the last ~2 days), so we drop them. 30 days, matching the Android twin byte-for-byte.
    private static let autoDetectDismissedMaxAgeSec = 30 * 86_400

    /// Result cache shared by the background post-sync pass and Today's card. A sync pass can force one
    /// fresh read, then every visible surface reuses that exact answer instead of rescanning two days of
    /// raw HR/motion. The one-minute bucket bounds clock-only staleness; refreshSeq and decisionSeq
    /// invalidate immediately for real dashboard data or a user dismissal.
    private struct AutoDetectCandidateCacheKey: Equatable {
        let refreshSeq: Int
        let decisionSeq: Int
        let daysBack: Int
        let minuteBucket: Int
    }

    private struct AutoDetectCandidateCache {
        let key: AutoDetectCandidateCacheKey
        let candidate: DetectedWorkout?
    }

    private var autoDetectDecisionSeq = 0
    private var autoDetectCandidateCache: AutoDetectCandidateCache?
    private var autoDetectScanTask: Task<DetectedWorkout?, Never>?
    private var autoDetectScanTaskKey: AutoDetectCandidateCacheKey?
    private var autoDetectScanGeneration = 0

    /// Prune the dismissed list: drop identities whose reference time is older than ~30 days (they can never be
    /// re-suggested anyway), then hard-cap to the `autoDetectDismissedMax` most-recent (by END) as a
    /// backstop. Malformed tokens are kept (treated as newest) so we never silently lose data on a
    /// parse miss. Byte-mirrored in the Android `AutoWorkoutPrefs.prune`.
    private func prunedAutoDetectSpans(_ spans: [String], now: Int) -> [String] {
        let cutoff = now - Self.autoDetectDismissedMaxAgeSec
        // Drop anything that aged out; an unparseable token survives the age filter.
        let fresh = spans.filter { token in
            guard let reference = AutoWorkoutSuggestionIdentity.referenceSec(from: token) else { return true }
            return reference >= cutoff
        }
        guard fresh.count > Self.autoDetectDismissedMax else { return fresh }
        // Over the cap , keep the most-recent by END (unparseable sort as newest). Sort indices so we
        // preserve the original list order among the kept entries and never collapse equal tokens.
        let keepIdx = Set(fresh.indices
            .sorted {
                (AutoWorkoutSuggestionIdentity.referenceSec(from: fresh[$0]) ?? .max)
                    > (AutoWorkoutSuggestionIdentity.referenceSec(from: fresh[$1]) ?? .max)
            }
            .prefix(Self.autoDetectDismissedMax))
        return fresh.indices.filter { keepIdx.contains($0) }.map { fresh[$0] }
    }

    /// Bounded, span-only overlap read for the suggestion detector. The ordinary `workoutRows()` path is
    /// a display projection over ~11 years and may reconcile hundreds of rows against HR traces; the
    /// detector only needs timestamps around its two-day scan. One maximum-workout day of look-behind
    /// catches a saved session that starts before the scan boundary but overlaps it.
    private func autoDetectSavedSpans(from: Int, to: Int) async -> [SavedWorkoutSpan] {
        guard let store = await ensureStore() else { return [] }
        let queryFrom = max(0, from - 86_400)
        var rows: [WorkoutRow] = []
        for id in importedReadIds {
            rows += (try? await store.workouts(deviceId: id, from: queryFrom, to: to, limit: 5000)) ?? []
        }
        for id in computedReadIds {
            rows += (try? await store.workouts(deviceId: id, from: queryFrom, to: to, limit: 5000)) ?? []
        }
        for id in ["apple-health", "lifting", "activity-file"] {
            rows += (try? await store.workouts(deviceId: id, from: queryFrom, to: to, limit: 5000)) ?? []
        }
        return rows
            .filter { $0.endTs >= from && $0.startTs <= to }
            .map { SavedWorkoutSpan(startSec: $0.startTs, endSec: $0.endTs) }
    }

    /// Run the opt-in detector over the last `daysBack` days of HR and return the single best
    /// candidate to suggest , newest first , that is NOT already saved and NOT previously dismissed.
    /// Returns nil when the toggle is off, there's nothing to suggest, or detection finds nothing.
    /// PURE READ: never writes a workout. The window scans from `daysBack` days ago to now.
    func autoDetectCandidate(daysBack: Int = 2,
                             forceRefresh: Bool = false) async -> DetectedWorkout? {
        guard PuffinExperiment.autoDetectWorkoutsEnabled else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let key = AutoDetectCandidateCacheKey(
            refreshSeq: refreshSeq,
            decisionSeq: autoDetectDecisionSeq,
            daysBack: daysBack,
            minuteBucket: now / 60
        )
        if !forceRefresh,
           let cached = autoDetectCandidateCache,
           cached.key == key {
            return cached.candidate
        }
        if autoDetectScanTaskKey == key, let task = autoDetectScanTask {
            return await task.value
        }

        autoDetectScanGeneration &+= 1
        let generation = autoDetectScanGeneration
        let task = Task<DetectedWorkout?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.computeAutoDetectCandidate(daysBack: daysBack, now: now)
        }
        autoDetectScanTask = task
        autoDetectScanTaskKey = key
        let candidate = await task.value
        if autoDetectScanGeneration == generation {
            autoDetectCandidateCache = AutoDetectCandidateCache(key: key, candidate: candidate)
            autoDetectScanTask = nil
            autoDetectScanTaskKey = nil
        }
        return candidate
    }

    private func computeAutoDetectCandidate(daysBack: Int, now: Int) async -> DetectedWorkout? {
        let from = now - daysBack * 86_400
        let samples = await hrSamples(from: from, to: now, limit: 200_000)
        guard samples.count >= 2 else { return nil }
        let hr = samples.map { (ts: $0.ts, bpm: $0.bpm) }
        let gravity = await gravitySamples(from: from, to: now, limit: 200_000)
        let motion = gravity.isEmpty ? nil : AutoWorkoutDetector.motionPoints(gravity)

        // Resting HR: most recent nightly RHR in range, else the detector's own default (60).
        let restingBpm = days.last(where: { $0.restingHr != nil })?.restingHr

        // Exclude every already-saved workout window (any source , strap, manual, imported, detected).
        let savedSpans = await autoDetectSavedSpans(from: from, to: now)

        // Workouts & GPS test mode: when on, run the diagnostic twin which returns the SAME candidates
        // detect(...) does (it reuses detect verbatim) plus the inputs / thresholds / per-window why trace,
        // tagged `.workouts`. Zero-cost when off: the gate is one UserDefaults bool read inside emitWorkouts,
        // and detectTrace is only called on that branch, so the default path runs the untraced detect.
        let shouldTrace = TestCentre.active(.workouts) && workoutsLog != nil
        let detection = await Task.detached(priority: .utility) {
            if shouldTrace {
                let (results, trace) = AutoWorkoutDetector.detectTrace(
                    hr: hr, restingBpm: restingBpm, motion: motion,
                    savedSpans: savedSpans, path: "autoDetect")
                return (candidates: results, trace: trace)
            }
            return (
                candidates: AutoWorkoutDetector.detect(
                    hr: hr, restingBpm: restingBpm,
                    motion: motion, savedSpans: savedSpans
                ),
                trace: []
            )
        }.value
        for line in detection.trace { emitWorkouts(line) }
        // Drop anything the user already dismissed, then take the most recent.
        let dismissed = autoDetectDismissedSpans
        let visibleCandidates = detection.candidates.filter { candidate in
            !dismissed.contains {
                AutoWorkoutSuggestionIdentity.matches($0, startSec: candidate.startSec)
            }
        }
        guard let candidate = visibleCandidates.max(by: { $0.startSec < $1.startSec }) else { return nil }

        // Wire the existing broad-type classifier into the actual suggestion path. A type appears only
        // when the strap supplied decoded activity-class ticks across the window and the heuristic clears
        // its confidence floor; otherwise the candidate remains the honest generic "Workout". It is still
        // advisory: the card names it experimental and saving is an explicit acceptance.
        let steps = await stepSamplesUnion(from: candidate.startSec, to: candidate.endSec)
        let prediction: WorkoutClassPrediction? = await Task.detached(priority: .utility) {
            guard let features = WorkoutTypeFeatureExtractor.extract(
                hr: samples, gravity: gravity, steps: steps,
                start: candidate.startSec, end: candidate.endSec,
                restingHR: restingBpm.map(Double.init)
            ), features.tickCoverage >= WorkoutTypeClassifier.minTickCoverage else {
                return nil
            }
            let prediction = WorkoutTypeClassifier.classify(features)
            guard prediction.predictedClass != .other,
                  prediction.confidence >= WorkoutTypeClassifier.minAdvisoryConfidence else {
                return nil
            }
            return prediction
        }.value
        guard let prediction else { return candidate }
        return DetectedWorkout(
            startSec: candidate.startSec, endSec: candidate.endSec,
            avgBpm: candidate.avgBpm, peakBpm: candidate.peakBpm,
            durationMin: candidate.durationMin,
            suggestedClass: prediction.predictedClass,
            suggestionConfidence: prediction.confidence,
            detectorVersion: candidate.detectorVersion,
            eventConfidence: candidate.eventConfidence,
            confidenceStatus: candidate.confidenceStatus,
            evidenceProvenance: candidate.evidenceProvenance)
    }

    /// Persist a detector-qualified window under the computed `<strap>-noop` source so it is honestly
    /// classified as Detected rather than Manual. Both an explicitly accepted suggestion and an
    /// unattended confidence-gated save use this path; the latter also leaves a durable Today review.
    @discardableResult
    func saveDetectedWorkout(_ w: DetectedWorkout, markForReview: Bool = false,
                             sportOverride: String? = nil) async -> Bool {
        guard let store = await ensureStore() else { return false }
        let sport = Self.acceptedAutoDetectSport(
            w.suggestedClass,
            requestedSport: sportOverride
        )
        guard let row = WorkoutSource.buildDetectedSuggestionRow(
            startSec: w.startSec,
            endSec: w.endSec,
            sport: sport,
            avgHr: w.avgBpm,
            source: computedDeviceId
        ) else { return false }
        do {
            try await store.upsertWorkouts([row], deviceId: computedDeviceId)
        } catch {
            return false
        }
        AutoWorkoutDecisionHistory.record(
            candidate: w,
            action: markForReview ? .autoSaved : .accepted,
            actor: markForReview ? .automation : .user,
            activityName: sport
        )
        if markForReview {
            AutoWorkoutReviewStore.record(AutoWorkoutReview(
                startSec: w.startSec, endSec: w.endSec, sport: sport,
                source: computedDeviceId, avgBpm: w.avgBpm, peakBpm: w.peakBpm
            ))
        }
        noteWorkoutsChanged()
        return true
    }

    /// Validate the persisted review against the database before showing it. Editing/dismissing the row
    /// elsewhere clears a stale review instead of presenting an action for a workout that no longer exists.
    func pendingAutoWorkoutReview() async -> AutoWorkoutReview? {
        guard let review = AutoWorkoutReviewStore.current else { return nil }
        let exists = await workoutRows(days: 35).contains {
            $0.startTs == review.startSec && $0.sport == review.sport && $0.source == review.source
        }
        if !exists { AutoWorkoutReviewStore.clear(startSec: review.startSec); return nil }
        return review
    }

    nonisolated static func acceptedAutoDetectSport(_ hint: CoarseWorkoutClass?,
                                                    requestedSport: String? = nil) -> String {
        if let requestedSport,
           let catalogSport = WorkoutCatalog.sport(named: requestedSport) {
            return catalogSport.name
        }
        switch hint {
        case .walk: return "Walking"
        case .run: return "Running"
        case .strength: return "Strength Training"
        case .cycle: return "Cycling"
        case .ski: return "Skiing"
        case .other, .none: return "Workout"
        }
    }

    /// DISMISS a suggested window: record its span durably so it never re-prompts. Idempotent.
    /// Prunes the stored list on every add (drop spans older than ~30 days + hard-cap to 200 most-recent)
    /// so it can never grow unbounded. Byte-mirrored in the Android `AutoWorkoutPrefs.dismiss`.
    func dismissDetectedSuggestion(_ w: DetectedWorkout) {
        guard rememberDismissedDetectedSuggestion(w) else { return }
        AutoWorkoutDecisionHistory.record(
            candidate: w,
            action: .dismissed,
            actor: .user,
            activityName: nil
        )
    }

    @discardableResult
    private func rememberDismissedDetectedSuggestion(_ w: DetectedWorkout) -> Bool {
        let token = autoDetectToken(w)
        var spans = autoDetectDismissedSpans
        guard !spans.contains(where: {
            AutoWorkoutSuggestionIdentity.matches($0, startSec: w.startSec)
        }) else { return false }
        spans.append(token)
        autoDetectDismissedSpans = prunedAutoDetectSpans(spans, now: Int(Date().timeIntervalSince1970))
        autoDetectDecisionSeq &+= 1
        autoDetectCandidateCache = nil
        return true
    }

    func recordAutoWorkoutReviewDecision(
        _ review: AutoWorkoutReview,
        action: AutoWorkoutDecisionAction
    ) {
        AutoWorkoutDecisionHistory.recordSpan(
            startSec: review.startSec,
            endSec: review.endSec,
            action: action,
            activityName: review.sport
        )
    }

    func autoWorkoutDecisionExportRecords() -> [AutoWorkoutDecisionRecord] {
        AutoWorkoutDecisionHistory.exportRecords(
            legacyDismissedTokens: autoDetectDismissedSpans
        )
    }

    // MARK: - Workout detail (read-only helpers, additive) , #410
    //
    // The workout-detail screen needs two reads over a single session's [startTs, endTs] window:
    // a downsampled HR curve (for the ChartCard) and the raw HR samples binned into zone-minutes
    // (for the zones bar). Both reuse the existing HR reads; they're thin convenience wrappers that
    // keep the bucket size / sample cap consistent with the rest of the app and give the view one
    // call site to await. NEVER mutate , pure reads.

    /// Downsampled HR over a workout window for the detail HR-curve. A short session wants a finer
    /// bucket than the Today 24h chart (300 s would flatten a 30-min run to ~6 points), so the bucket
    /// scales with duration: ~120 buckets across the window, floored at 15 s and capped at 300 s.
    func workoutHrBuckets(from: Int, to: Int) async -> [HRBucket] {
        guard to > from else { return [] }
        let span = to - from
        let bucket = max(15, min(300, span / 120))
        return await hrBuckets(from: from, to: to, bucketSeconds: bucket)
    }

    /// Raw HR samples binned into per-zone MINUTES for a workout window, using the age-derived
    /// (Tanaka) %HRmax zones , the same display zone model `WorkoutsView` already uses for imported
    /// zone percentages, but computed here from the strap's own samples so a session WITHOUT imported
    /// `zonesJSON` still gets a real time-in-zone split. Returns nil when the window carries no HR (so
    /// the view shows nothing rather than five empty bars). `age <= 0` falls back to a 30 y default ,
    /// the zones are approximate either way and clearly labelled as such in the UI.
    func workoutZoneMinutes(from: Int, to: Int, age: Int) async -> [Double]? {
        guard to > from else { return nil }
        let samples = await hrSamples(from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let zoneSet = HRZones.zones(age: age > 0 ? Double(age) : 30)
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = tiz.seconds.map { $0 / 60.0 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }

    /// HRR for one workout (#516), derived from the final five minutes of recorded effort plus the five
    /// post-workout minutes. This is a narrow read (at most ~10 minutes), not a whole-workout scan, and the
    /// pure engine owns every eligibility/coverage guard. Missing post-workout HR therefore returns nil
    /// instead of fabricating a recovery value. Kotlin twin: `AppViewModel.workoutHeartRateRecovery`.
    func workoutHeartRateRecovery(from: Int, to: Int, maxHR: Double) async -> HeartRateRecovery.Result? {
        guard to > from, maxHR > 0 else { return nil }
        let readFrom = max(from, to - HeartRateRecovery.eligibilityLookbackSeconds)
        let readTo = to + 5 * 60 + HeartRateRecovery.measurementToleranceSeconds
        let samples = await hrSamples(from: readFrom, to: readTo, limit: 2_000)
        return HeartRateRecovery.calculate(samples: samples, workoutStart: from, workoutEnd: to,
                                           maxHR: maxHR)
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// #833/v7.7.2 (Apple Health per-source freeze): the SHARED heavy-load seam behind `AppleHealthView.load()`.
    /// It owns the cache short-circuit, the DEBUG fire tally, the whole-history store reads, and the write-back,
    /// so the freeze fix lives in ONE testable place instead of the view's `@State` (which can't be driven
    /// headlessly). The view calls this then copies the returned snapshot into its `@State`; the regression test
    /// calls it twice at an unchanged seq and asserts the second call short-circuited.
    ///
    /// When `allowCache` is set AND the live state is unchanged (`appleHealthLoadedSeq == refreshSeq` AND the
    /// same local dayKey) AND a snapshot exists, it RESTORES that snapshot with no store queries and does NOT
    /// bump the fire tally, that same-state re-mount is exactly the cold-mount the freeze fix must absorb. Any
    /// other call runs the genuine full read (bumping the tally AFTER the short-circuit), snapshots it onto the
    /// long-lived repo keyed by the seq + dayKey it loaded for, and returns it. (The whole class is `@MainActor`,
    /// so this seam is main-actor isolated like every other read facade here.)
    func performAppleHealthLoad(seriesKeys: [String], allowCache: Bool) async -> AppleHealthLoadCache {
        // #833/v7.7.2: same-state re-mount → restore the prior snapshot (no store queries), which is the freeze
        // fix. The dayKey guard mirrors the `.task(id:)` key so a day rollover still re-loads at an unchanged seq.
        if allowCache,
           appleHealthLoadedSeq == refreshSeq,
           appleHealthLoadedDayKey == Repository.localDayKey(Date()),
           let cached = appleHealthCache {
            return cached
        }

        #if DEBUG
        // v7.7.2 regression guard: count only genuine heavy loads (the cache restore above returned BEFORE this
        // and must not increment it).
        loadFireCounts["appleHealth", default: 0] += 1
        #endif

        async let rows = appleDailyRows()
        async let workouts = workoutRows()

        // The per-source page's data contract: ALL history is loaded ONCE and the range control windows it
        // client-side, anchored to the latest data point (not "now"). The client-side widen therefore needs the
        // WHOLE series in hand, so the fetch forces the full recordable epoch via `fullHistory` rather than a
        // `days` window that "now"-anchored windowing could truncate below the user's latest-point-relative ALL
        // view. `days` stays at its 4000 default but is IGNORED while `fullHistory` is true.
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in seriesKeys {
            fetched[key] = await series(key: key, source: "apple-health", days: 4000, fullHistory: true)
        }

        let loadedRows = await rows
        let appleWorkouts = await workouts.filter { WorkoutSource.isAppleHealth($0.source) }

        let snapshot = AppleHealthLoadCache(appleRows: loadedRows.sorted { $0.day < $1.day },
                                            workoutCount: appleWorkouts.count,
                                            series: fetched)
        // #833/v7.7.2: snapshot what we just read onto the long-lived repo, keyed by the seq + dayKey we loaded
        // for, so a later same-state re-mount restores it in-memory instead of re-querying.
        appleHealthCache = snapshot
        appleHealthLoadedSeq = refreshSeq
        appleHealthLoadedDayKey = Repository.localDayKey(Date())
        return snapshot
    }

    /// Shared formatter , created once. Hot read path (called per series window / refresh);
    /// allocating a DateFormatter per call was a measurable waste. Read-only use is thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// The "yyyy-MM-dd" day one calendar day AFTER `day`, or `day` verbatim when it isn't a parseable
    /// ISO date (e.g. a wide-open sentinel already past every real day, so no buffer is needed). Backs the
    /// +1-day daily read buffer in `resolvedRows` so a wake-day-keyed night that sorts just past the
    /// requested upper bound still resolves the selected day (#614). Mirrors Android
    /// WhoopRepository.bufferDayAfter.
    static func dayAfter(_ day: String) -> String {
        guard day < "9999-12-31",
              let d = dayFormatter.date(from: day),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d)
        else { return day }
        return dayFormatter.string(from: next)
    }
}

private extension DailyMetric {
    /// A copy of self where every nil field is backfilled from `fallback`. Used by the field-by-field
    /// daily merge so an imported export keeps its own values while a computed row fills the gaps it
    /// doesn't carry (e.g. on-device Charge / skin-temp deviation / activity totals).
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst,
            // Raw SpO2 is on-device only (imports never carry it), so the imported row's nil is
            // backfilled from the computed fallback — otherwise the nightly means would be lost. (#93)
            spo2Red: spo2Red ?? fallback.spo2Red,
            spo2Ir: spo2Ir ?? fallback.spo2Ir,
            hrvMethod: avgHrv == nil ? fallback.hrvMethod : hrvMethod
        )
    }

    /// A copy of self where the SLEEP fields are overridden by `source` , used by the H5 edit-merge so a
    /// hand-edited night's computed sleep figures win over the import for that day (#509). Only the sleep
    /// columns move; every other field (recovery/strain/HRV/RHR/activity/in-sleep vitals) is left as-is, so
    /// the import still wins for non-sleep metrics on the edited day.
    func takingSleepFields(from source: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: source.totalSleepMin,
            efficiency: source.efficiency,
            deepMin: source.deepMin,
            remMin: source.remMin,
            lightMin: source.lightMin,
            disturbances: source.disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst,
            spo2Red: spo2Red,   // non-sleep field: preserved as-is (#93)
            spo2Ir: spo2Ir,
            hrvMethod: hrvMethod
        )
    }
}
