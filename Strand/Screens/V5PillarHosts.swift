import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// V5PillarHosts.swift — the thin Wave-3 host wrappers that feed the two PURE v5 pillar screens
// (FusedRecordView + RhythmView) the engine results they take by init. The views own only
// presentation and previews from a fixture; these hosts do the I/O — they load the rows the store
// already holds, run the pure engine, and hand the result down. Self-contained: each takes the
// Repository / AppModel via the environment, exactly like every other screen.
//
// Mounted as reachable nav destinations by RootView (macOS sidebar) + RootTabView (iOS More list)
// and reachable via NavRouter deep-links from the Health / Devices&Sources hubs.

// MARK: - Fused record host ("Your Data, Fused")

/// Loads today's fused record via `AppModel.buildTodayFusedRecord()` (the additive multi-device
/// adapter) and feeds `FusedRecordView`. Re-loads when fresh data lands (`repo.refreshSeq`).
struct FusedRecordHost: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository

    @State private var record = FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                FusedRecordView(record: record)
            } else {
                ScreenScaffold(title: "Your Data, Fused",
                               subtitle: "Building your best-sourced record…") {
                    ComingSoon(what: "Reading your sources…", symbol: "square.stack.3d.up")
                }
            }
        }
        .task(id: repo.refreshSeq) {
            record = await model.buildTodayFusedRecord()
            loaded = true
        }
    }
}

// MARK: - Rhythm host (experimental beat-to-beat visualization)

/// Loads the most recent banked night's R-R windows, runs the pure `RhythmScreener` over each
/// still, resting window, and feeds `RhythmView` (which self-gates on its own consent before it
/// shows anything). All math is on-device; nothing is computed until the user passes the gate.
struct RhythmHost: View {
    @EnvironmentObject private var repo: Repository
    /// Optional dismissal hook when presented as a sheet (iOS / drill-in).
    var onClose: (() -> Void)? = nil

    @AppStorage(RhythmConsent.acceptedVersionKey) private var acceptedVersion = ""
    @AppStorage(RhythmConsent.enabledKey) private var enabled = false

    @State private var night: RhythmScreener.NightRhythmSummary?
    @State private var windows: [RhythmScreener.WindowResult] = []

    private var consentGiven: Bool { enabled && RhythmConsent.isAccepted(acceptedVersion) }

    var body: some View {
        RhythmView(night: night, windows: windows, onClose: onClose)
            // Compute only after consent, then recompute whenever fresh history lands.
            .task(id: "\(consentGiven)|\(repo.refreshSeq)") {
                guard consentGiven else { return }
                await load()
            }
    }

    /// Read the most recent banked sleep session, pull its R-R + gravity, split into ~5-minute windows,
    /// gate each on stillness + resting rate, and screen it. Descriptive stats only — never a verdict.
    private func load() async {
        guard let store = await repo.storeHandle(),
              let lastSleep = (await repo.allSleepSessions(days: 14)).last else { return }
        let lo = lastSleep.effectiveStartTs
        let hi = lastSleep.endTs
        guard hi > lo else { return }
        // Active and canonical ids can diverge after a remove/re-add. Read every distinct imported and
        // computed namespace so a complete pre-repair night is not orphaned.
        let sourceIds = (repo.importedReadIds + repo.computedReadIds).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        var rrSources: [[RRInterval]] = []
        for sourceId in sourceIds {
            let rows = (try? await store.rrIntervals(
                deviceId: sourceId,
                from: lo,
                to: hi,
                limit: 200_000
            )) ?? []
            if !rows.isEmpty { rrSources.append(rows) }
        }
        guard !rrSources.isEmpty else { return }
        let grav = await repo.gravitySamples(from: lo, to: hi, limit: 200_000)
        let workouts = await repo.workoutRows(overlappingFrom: lo, to: hi)

        // Keep one beat train rather than merging duplicate sources. Prefer the source yielding more
        // readable resting windows, then attempted-window coverage, then in-range beats.
        var results: [RhythmScreener.WindowResult] = []
        var selectedBeatCount = -1
        for rows in rrSources {
            let candidate = Self.screen(rr: rows, grav: grav, workouts: workouts, from: lo, to: hi)
            // Store reads include `hi`; screening uses half-open windows and excludes that boundary.
            let candidateBeatCount = rows.lazy.filter { $0.ts >= lo && $0.ts < hi }.count
            if selectedBeatCount < 0 || Self.isBetterResultSource(
                candidate,
                candidateBeats: candidateBeatCount,
                than: results,
                currentBeats: selectedBeatCount
            ) {
                results = candidate
                selectedBeatCount = candidateBeatCount
            }
        }
        windows = results
        night = RhythmScreener.summarizeNight(results)
    }

    private static func screen(
        rr: [RRInterval],
        grav: [GravitySample],
        workouts: [WorkoutRow],
        from: Int,
        to: Int
    ) -> [RhythmScreener.WindowResult] {
        // Window the night into five-minute slices; a slice is still when gravity variance is small.
        let windowSec = 5 * 60
        var results: [RhythmScreener.WindowResult] = []
        var t = from
        while t < to {
            let wEnd = min(t + windowSec, to)
            let wRR = rr.filter { $0.ts >= t && $0.ts < wEnd }
            if wRR.count >= RhythmScreener.windowMinBeats {
                let wGrav = grav.filter { $0.ts >= t && $0.ts < wEnd }
                let still = Self.isStill(wGrav)
                let activityActive = workouts.contains { workout in
                    workout.startTs < wEnd && max(workout.endTs, workout.startTs + 1) > t
                }
                let input = RhythmScreener.WindowInput(
                    rr: wRR,
                    motionStill: still,
                    activityActive: activityActive
                )
                results.append(RhythmScreener.screenWindow(input))
            }
            t = wEnd
        }
        return results
    }

    private static func isBetterResultSource(
        _ candidate: [RhythmScreener.WindowResult],
        candidateBeats: Int,
        than current: [RhythmScreener.WindowResult],
        currentBeats: Int
    ) -> Bool {
        let candidateReadable = candidate.lazy.filter { $0.label != .unreadable }.count
        let currentReadable = current.lazy.filter { $0.label != .unreadable }.count
        return candidateReadable > currentReadable
            || (candidateReadable == currentReadable && candidate.count > current.count)
            || (candidateReadable == currentReadable && candidate.count == current.count
                && candidateBeats > currentBeats)
    }

    /// A window is "still" when its accelerometer magnitude varies little (a resting wrist). A coarse,
    /// conservative gate — movement is the single biggest false signal for a regularity read, so we err
    /// toward NOT reading a window rather than describing a moving one.
    private static func isStill(_ grav: [GravitySample]) -> Bool {
        guard grav.count >= 4 else { return false }
        let mags = grav.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }
        let mean = mags.reduce(0, +) / Double(mags.count)
        guard mean > 0 else { return false }
        let variance = mags.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mags.count)
        // Normalised standard deviation below ~3% of the mean magnitude reads as a still wrist.
        return (variance.squareRoot() / mean) < 0.03
    }
}
