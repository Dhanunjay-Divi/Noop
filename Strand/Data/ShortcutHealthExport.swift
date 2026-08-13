import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// #155 — Apple-Health-free export for sideloaded iOS installs. A free (7-day) signing identity
/// can't carry the HealthKit entitlement, so HealthKitBridge never runs for sideloaders. Instead,
/// NOOP drops a plain-text file at Documents/noop_sync.txt (exposed to Files/Shortcuts via
/// UIFileSharingEnabled) and the reporter's pre-built Siri Shortcut reads it and logs the rows into
/// Apple Health. One line per 15-minute window — `HR,[reserved],[reserved],yyyy-MM-dd HH:mm` —
/// en_US_POSIX, LOCAL time (the Shortcut parses dates in the device zone), empty fields keep their
/// commas so column positions are fixed, NO header. The legacy HRV column is always blank: strap HRV
/// here is RMSSD, while Apple's writable HealthKit type is SDNN. The legacy Steps column is also always
/// blank: WHOOP 5/MG `step_motion_counter@57` is a motion counter scaled by a user preference, not a
/// validated pedometer step count. Relabelling either value as an Apple Health quantity would be
/// semantic data corruption.
///
/// Reads ONLY the strap source (`repo.deviceId`) — never `apple-health` (a Shortcut-logged value
/// must not round-trip back in on the next HealthKit/export import) and never the `-noop` computed
/// source.
///
/// Mirrors CsvExport's shape: a platform-neutral enum in Strand/Data/ that compiles into the macOS
/// target too (no UIKit). The iOS-only pieces live in StrandiOS/ — the scenePhase trigger in
/// StrandiOSApp and the opt-in toggle in ShortcutExportSettingsView.
enum ShortcutHealthExport {

    /// Opt-in gate (default OFF — every automation in NOOP is optional).
    static let enabledKey = "noop.shortcutSync.enabled"
    /// Exclusive end of the last successfully written coverage, unix seconds. Advances ONLY after
    /// a successful file write, so a failed export retries the same span next time.
    static let watermarkKey = "noop.shortcutSync.lastExportTs"
    /// One-time migration marker for the 9.2 HR-only file contract. Older builds could leave a
    /// `noop_sync.txt` row whose third column contained WHOOP @57 motion ticks presented as steps.
    /// Clear that payload synchronously at launch before any Shortcut can consume it; subsequent
    /// HR-only exports safely replace the file through the normal differential path.
    static let hrOnlyMigrationKey = "noop.shortcutSync.hrOnlyFileMigratedV1"
    static let fileName = "noop_sync.txt"
    /// Aggregation window: 15 minutes, epoch-aligned — the same boundaries hrBuckets(900) groups by.
    static let windowSeconds = 900
    /// Catch-up bound: never reach further back than 7 days, even on a first run or after a long gap.
    static let lookbackSeconds = 7 * 86_400
    /// Reboot/reset guard for the legacy cumulative-u16 analyzer below. Retained only for its pure
    /// windowing contract; Shortcut export never reads or renders this stream as Apple Health Steps.
    static let maxStepDelta = 30_000
    /// Row cap retained for the legacy analyzer's bounded test contract. Production export reads HR only.
    static let readLimit = 2_000_000

    enum Outcome: Equatable {
        case written(lines: Int)
        case nothingNew
        case failure(String)
    }

    /// One 15-minute export window. All three values optional — a window is emitted iff ≥1 is set.
    struct Window: Equatable {
        let start: Int          // unix seconds, windowSeconds-aligned
        var hr: Int? = nil      // mean bpm over the window, rounded
        // Legacy/internal RMSSD aggregate. The Apple-Health renderer always suppresses this field;
        // retained only so the analyzer/windowing contract remains testable during format migration.
        var hrvMs: Double? = nil
        // Legacy/internal motion-counter aggregate. The Apple-Health renderer always suppresses this
        // field; retained only so the analyzer/windowing contract remains testable during format migration.
        var steps: Int? = nil
    }

    // MARK: - Entry points

    /// Background-transition hook (StrandiOSApp scenePhase). No-op until the user opts in.
    @MainActor
    static func writeIfEnabled(repo: Repository) async {
        // Also repair here in case launch-time Documents access was temporarily unavailable. This is
        // synchronous and runs before the opt-in gate or any sensor/store await.
        _ = migrateLegacyFileIfNeeded()
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        _ = await writeNow(repo: repo)
    }

    /// Atomically removes any pre-9.2 Shortcut payload exactly once. This deliberately runs even when
    /// export is disabled: an installed Siri Shortcut can still read a file left by an older build.
    /// The marker is written and the old export watermark is cleared only after the empty replacement
    /// succeeds. That keeps a transient filesystem failure fully retryable and lets the next HR-only
    /// export rebuild up to the normal seven-day catch-up bound instead of skipping safe HR rows whose
    /// prior file was just discarded.
    @discardableResult
    static func migrateLegacyFileIfNeeded(
        defaults: UserDefaults = .standard,
        directory: URL? = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask).first
    ) -> Bool {
        guard !defaults.bool(forKey: hrOnlyMigrationKey), let directory else { return false }
        do {
            try Data().write(to: directory.appendingPathComponent(fileName), options: .atomic)
            resetWatermark(defaults: defaults)
            defaults.set(true, forKey: hrOnlyMigrationKey)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    @discardableResult
    static func writeNow(repo: Repository) async -> Outcome {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure("No Documents directory.")
        }
        return await export(source: store, deviceId: repo.deviceId, now: Date(),
                            defaults: .standard, directory: docs, timeZone: .current)
    }

    /// Injectable core — store reads behind ShortcutExportReads, clock/defaults/destination/zone as
    /// parameters — so the watermark and file semantics are unit-testable without a live DB.
    @discardableResult
    static func export(source: ShortcutExportReads, deviceId: String, now: Date,
                       defaults: UserDefaults, directory: URL, timeZone: TimeZone) async -> Outcome {
        let nowTs = Int(now.timeIntervalSince1970)
        let span = coverageSpan(nowTs: nowTs, watermark: defaults.integer(forKey: watermarkKey))
        guard span.from < span.end else {
            // Nothing new — TRUNCATE the file rather than leaving the previous rows behind. The
            // Shortcut has no dedup and its automation fires on every app close, while most closes
            // complete no new 15-min window: a stale file would be re-imported into Apple Health on
            // every run (#167). An empty file imports nothing. (Trade-off, by design: rows the
            // Shortcut never read before the next truncate are skipped — strictly-differential
            // beats duplicating; resetWatermark() re-emits the 7-day window as the escape hatch.)
            try? Data().write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return .nothingNew
        }
        do {
            let hr = try await source.hrBuckets(deviceId: deviceId, from: span.from,
                                                to: span.end - 1, bucketSeconds: windowSeconds)
            // Do not read or export strap RMSSD or @57 motion-counter values for the Apple Health
            // Shortcut. Keep both legacy columns empty for compatibility with existing Shortcuts,
            // which already skip blank values at those fixed positions.
            let windows = aggregate(hr: hr, rr: [], steps: [], end: span.end,
                                    from: span.from)
            // Full-file replace even when 0 windows: the Shortcut has no dedup, so stale lines left
            // behind would be double-logged on its next run.
            try Data(render(windows, timeZone: timeZone).utf8)
                .write(to: directory.appendingPathComponent(fileName), options: .atomic)
            // Do not consume an empty interval. Strap/offload data can land after this background
            // export runs; keeping the old watermark lets the next export recover that late data.
            // The file is still replaced with an empty file above, preventing stale re-imports.
            if !windows.isEmpty {
                defaults.set(span.end, forKey: watermarkKey)   // only after the write landed
            }
            return .written(lines: windows.count)
        } catch {
            return .failure("Shortcut export failed: \(error.localizedDescription)")
        }
    }

    /// Drop the watermark so the next export re-emits the full 7-day window (e.g. after the user
    /// rebuilds their Shortcut or clears its Health entries).
    static func resetWatermark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: watermarkKey)
    }

    // MARK: - Pure logic

    /// Coverage `[from, end)`: `from` = watermark clamped to the 7-day lookback; `end` = the start
    /// of the still-open 15-minute window. The open window is EXCLUDED — exporting it would freeze
    /// a partial value (the watermark advances past it and the window is never revisited).
    static func coverageSpan(nowTs: Int, watermark: Int) -> (from: Int, end: Int) {
        ((max(watermark, nowTs - lookbackSeconds)), (nowTs / windowSeconds) * windowSeconds)
    }

    /// Fold the three streams into windowSeconds-aligned windows below `end`, ascending. Only
    /// windows holding ≥1 value are returned. `from` lets cumulative steps consume one earlier
    /// predecessor without emitting deltas whose later sample is outside the requested coverage.
    static func aggregate(hr: [HRBucket], rr: [RRInterval], steps: [StepSample], end: Int,
                          from: Int = Int.min) -> [Window] {
        var byStart: [Int: Window] = [:]
        func update(_ start: Int, _ mutate: (inout Window) -> Void) {
            var w = byStart[start] ?? Window(start: start)
            mutate(&w)
            byStart[start] = w
        }
        func windowStart(_ ts: Int) -> Int { (ts / windowSeconds) * windowSeconds }

        // HR — hrBuckets(900) already keys by floor(ts/900)*900, i.e. exactly our window starts.
        for b in hr where b.ts < end {
            update(b.ts) { $0.hr = Int(b.bpm.rounded()) }
        }

        // HRV — rolling RMSSD per window via the shared analyzer (Task Force RMSSD over Malik-cleaned
        // NN intervals). nil rmssd (< 20 clean beats in the window) leaves the field empty.
        var rrByWindow: [Int: [Double]] = [:]
        for s in rr.sortedByTsStable() where s.ts < end {
            rrByWindow[windowStart(s.ts), default: []].append(Double(s.rrMs))
        }
        for (start, values) in rrByWindow {
            if let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd {
                update(start) { $0.hrvMs = rmssd }
            }
        }

        // Steps — the established cumulative-u16 delta math (AnalyticsEngine's @57 daily total):
        // negative delta = u16 wrap → +65536; corrected deltas > maxStepDelta are firmware-reset
        // artifacts → dropped. Each delta lands in the window of the LATER sample (where the
        // increment was observed).
        let sorted = steps.sorted { $0.ts < $1.ts }
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                var delta = sorted[i].counter - sorted[i - 1].counter
                if delta < 0 { delta += 65_536 }  // u16 wraparound
                guard delta >= 1 && delta <= maxStepDelta else { continue }  // drop resets
                // A pre-watermark sample is read only as the cumulative-counter predecessor. Never
                // emit its own earlier deltas; only the first sample at/after `from` may bridge it.
                guard sorted[i].ts >= from else { continue }
                let start = windowStart(sorted[i].ts)
                guard start < end else { continue }
                update(start) { $0.steps = ($0.steps ?? 0) + delta }
            }
        }

        return byStart.values.sorted { $0.start < $1.start }
    }

    /// `HR,[reserved],[reserved],yyyy-MM-dd HH:mm` — empty fields keep their commas. The second field was
    /// historically RMSSD labelled generically as HRV; the third was fed from the @57 motion counter.
    /// Both remain blank so the companion Shortcut cannot write them into semantically different Apple
    /// Health quantities. Timestamp is the window START in local time.
    static func line(_ w: Window, timeZone: TimeZone) -> String {
        let hr = w.hr.map(String.init) ?? ""
        return "\(hr),,,\(timestamp(w.start, timeZone: timeZone))"
    }

    /// No header, no trailing newline — a trailing "\n" would give the Shortcut's split-by-newline
    /// an empty last row.
    static func render(_ windows: [Window], timeZone: TimeZone) -> String {
        windows.map { line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    // en_US_POSIX per the project's date contract; the zone is set per call (LOCAL in production,
    // injected in tests). Single shared instance — only ever used from one task at a time.
    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func timestamp(_ ts: Int, timeZone: TimeZone) -> String {
        lineFormatter.timeZone = timeZone
        return lineFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// The three store reads the export needs — a seam so the watermark/windowing logic is testable
/// without a live DB. WhoopStore's own methods match the signatures exactly.
protocol ShortcutExportReads {
    func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket]
    func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval]
    func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample]
}

extension WhoopStore: ShortcutExportReads {}
