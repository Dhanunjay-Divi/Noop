import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WhoopStore
import StrandImport
import StrandAnalytics

/// Settings → Backup & restore → "Export CSV…": serialize the merged WHOOP history (imported wins
/// per day — exactly what the dashboards show; Apple Health rows are deliberately EXCLUDED so a
/// re-import can't mis-attribute them as WHOOP data) into WHOOP's 4-CSV zip via
/// StrandImport.WhoopCsvExporter. The same archive carries the versioned `noop_user_data.json`
/// contract for editable nutrition and normalized Strength Trainer records. The zip re-imports into
/// NOOP on Mac/iPhone/Android. On-device computed rows are marked "noop (APPROXIMATE)" in the Source
/// column so both importers route them to a computed namespace, never the official WHOOP-reference
/// namespace; the native encrypted backup remains the same-platform full-device restore path.
///
/// #458 (the Android twin's bug, mirror-image here): every read goes through the repository's
/// active∪canonical union ids (`importedReadIds`/`computedReadIds`, #814) — reading the ACTIVE id
/// alone dropped the canonical "my-whoop" rows (a prior CSV import + the canonical engine history)
/// after a strap remove+re-add moved the active id to "whoop-<uuid>". Per-row dedup keeps the
/// active-first copy; a single-canonical install collapses to one id per side, byte-identical.
///
/// Self-contained: it reads through the store handle and reconstructs Repository's merge precedence
/// inline rather than depending on Repository's private merge helpers, so the export is decoupled
/// from the dashboard read path.
enum CsvExport {
    /// `CachedSleepSession` intentionally carries no source id on Apple. Keep enough immutable row
    /// identity beside it while merging so publication evidence cannot leak across source namespaces.
    struct SleepExportIdentity: Hashable, Sendable {
        let startTs: Int
        let effectiveStartTs: Int
        let endTs: Int
        let stagesJSON: String?

        init(_ session: CachedSleepSession) {
            startTs = session.startTs
            effectiveStartTs = session.effectiveStartTs
            endTs = session.endTs
            stagesJSON = session.stagesJSON
        }
    }

    /// Assign every fragment to the final wake day of its bridged physical night, independently for
    /// each persisted source. Keeping source partitions intact prevents evidence or attribution from
    /// crossing an active/canonical namespace boundary.
    nonisolated static func bridgedWakeDayBySleep(
        _ sessions: [CachedSleepSession],
        sourceBySession: [SleepExportIdentity: String],
        timeZone: TimeZone = .current
    ) -> [SleepExportIdentity: String] {
        var result: [SleepExportIdentity: String] = [:]
        let bySource = Dictionary(grouping: sessions) {
            sourceBySession[SleepExportIdentity($0)] ?? ""
        }
        for sourceSessions in bySource.values {
            for bucket in Repository.wakeDaySessionBuckets(
                sourceSessions,
                timeZone: timeZone
            ) {
                for session in bucket.sessions {
                    result[SleepExportIdentity(session)] = bucket.day
                }
            }
        }
        return result
    }

    enum ExportResult {
        case exported(URL)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func run(repo: Repository) async -> ExportResult {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        // #458: the active∪canonical union ids (active FIRST, so per-row dedup keeps the live copy);
        // a single-canonical install collapses to one id per side and reads byte-identically.
        let importedIds = repo.importedReadIds
        let computedIds = repo.computedReadIds
        let fromDay = "0000-01-01", toDay = "9999-12-31"
        let hi = Int(Date().timeIntervalSince1970) + 86_400

        do {
            // Fetch every source off the WhoopStore actor (each `await store.*` already hops off main).
            // Dailies: per side, the FIRST union id that has a day wins (active first).
            var importedByDay: [String: DailyMetric] = [:]
            for id in importedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where importedByDay[d.day] == nil {
                    importedByDay[d.day] = d
                }
            }
            var computedByDay: [String: DailyMetric] = [:]
            var computedSourceByDay: [String: String] = [:]
            for id in computedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where computedByDay[d.day] == nil {
                    computedByDay[d.day] = d
                    computedSourceByDay[d.day] = id
                }
            }
            let imported = importedByDay.values.sorted { $0.day < $1.day }
            let computed = computedByDay.values.sorted { $0.day < $1.day }
            // Cycles series: per (key, day) the first union id with a value wins.
            var seriesRaw: [String: [MetricPoint]] = [:]
            for key in ["sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min",
                        "in_bed_min", "awake_min", "energy_kcal", "avg_hr", "max_hr"] {
                var byDay: [String: MetricPoint] = [:]
                for id in importedIds {
                    for p in try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                    where byDay[p.day] == nil { byDay[p.day] = p }
                }
                seriesRaw[key] = byDay.values.sorted { $0.day < $1.day }
            }
            // Sleeps / workouts: per side, exact-duplicate rows dropped on the natural key,
            // active-first (mirrors the Kotlin dedupSleepBlocks / dedupWorkoutsByKey unions).
            var seenSleep = Set<String>(), seenComp = Set<String>()
            var impSleep: [CachedSleepSession] = [], compSleep: [CachedSleepSession] = []
            var importedSleepSource: [SleepExportIdentity: String] = [:]
            var computedSleepSource: [SleepExportIdentity: String] = [:]
            for id in importedIds {
                for s in try await store.sleepSessions(
                    deviceId: id, from: 0, to: hi, limit: 100_000
                ) where seenSleep.insert("\(s.startTs)|\(s.endTs)").inserted {
                    impSleep.append(s)
                    importedSleepSource[SleepExportIdentity(s)] = id
                }
            }
            for id in computedIds {
                for s in try await store.sleepSessions(
                    deviceId: id, from: 0, to: hi, limit: 100_000
                ) where seenComp.insert("\(s.startTs)|\(s.endTs)").inserted {
                    compSleep.append(s)
                    computedSleepSource[SleepExportIdentity(s)] = id
                }
            }
            var seenImpW = Set<String>(), seenCompW = Set<String>()
            var impWorkouts: [WorkoutRow] = [], compWorkouts: [WorkoutRow] = []
            for id in importedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenImpW.insert("\(w.startTs)|\(w.sport)").inserted { impWorkouts.append(w) }
            }
            for id in computedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenCompW.insert("\(w.startTs)|\(w.sport)").inserted { compWorkouts.append(w) }
            }
            // Journal: natural key (day, question), active-first.
            var seenJournal = Set<String>()
            var journal: [JournalEntry] = []
            for id in importedIds {
                for j in try await store.journalEntries(deviceId: id, from: fromDay, to: toDay)
                where seenJournal.insert("\(j.day)|\(j.question)").inserted { journal.append(j) }
            }
            // Sidecar: every metricSeries row under EVERY NOOP source id, full fidelity (rows keep
            // their own deviceId, so union entries stay distinguishable on re-import).
            var sidecar: [String: [MetricPoint]] = [:]
            for id in importedIds + computedIds {
                var points: [MetricPoint] = []
                for key in (try await store.metricKeys(deviceId: id)) {
                    points += try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                }
                if !points.isEmpty { sidecar[id] = points }
            }
            // Portable user-authored data that cannot fit the WHOOP-shaped CSV rows. Fetch complete
            // archived catalogs and in-progress sessions so export never silently drops hidden history.
            let nutritionEntries = try await store.nutritionEntries(from: fromDay, to: toDay)
            let nutritionCatalogItems = try await store.nutritionCatalogItems(
                savedOnly: false,
                limit: 500_000
            )
            let strengthExercises = try await store.strengthExercises(includeArchived: true)
            let strengthRoutines = try await store.strengthRoutines(includeArchived: true)
            let strengthSessions = try await store.strengthSessions(includeInProgress: true)
            let autoWorkoutDecisions = repo.autoWorkoutDecisionExportRecords()

            // Bridge each source timeline before assigning cycle days. These plain Sendable maps keep the
            // detached serializer off Repository's actor and ensure every fragment of a cross-midnight
            // physical night points to the same final wake day.
            let importedWakeDayBySleep = bridgedWakeDayBySleep(
                impSleep,
                sourceBySession: importedSleepSource)
            let computedWakeDayBySleep = bridgedWakeDayBySleep(
                compSleep,
                sourceBySession: computedSleepSource)
            var offsetBySleep: [SleepExportIdentity: Int] = [:]
            for s in impSleep + compSleep {
                let identity = SleepExportIdentity(s)
                let wakeDate = Date(timeIntervalSince1970: TimeInterval(s.endTs))
                offsetBySleep[identity] = TimeZone.current.secondsFromGMT(for: wakeDate)
            }
            let habitualMidsleepSec = Repository.historicalHabitualMidsleepSec(
                impSleep + compSleep)
            let name = defaultName()
            let generatedAt = comparisonUTC(
                Int(Date().timeIntervalSince1970),
                formatter: comparisonUTCFormatter()
            )
            #if os(macOS)
            let comparisonPlatform = "macOS"
            #else
            let comparisonPlatform = "iOS"
            #endif
            let comparisonContext = ComparisonContext(
                generatedAtUTC: generatedAt,
                platform: comparisonPlatform,
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown"
            )

            // Assembly + serialization + zip deflate run OFF the main actor (mirrors the timelineSeries
            // Task.detached): only Sendable value types (the fetched rows, the precomputed day-key map)
            // cross in, and the result (a temp file URL / the archive on disk) comes back. WhoopCsvExporter
            // and SleepMerge are pure package statics; workoutSource is a pure static; endDay is now a pure
            // dictionary lookup. Byte-identical output to the in-line version.
            let tmp = try await Task.detached(priority: .utility) {
                let importedEndDay: (CachedSleepSession) -> String = {
                    importedWakeDayBySleep[SleepExportIdentity($0)] ?? ""
                }
                let computedEndDay: (CachedSleepSession) -> String = {
                    computedWakeDayBySleep[SleepExportIdentity($0)] ?? ""
                }
                var publishableComputedSleep = Set<SleepExportIdentity>()
                var publishableComputedMinutesByDay:
                    [String: [String: SleepStageTotals.Minutes]] = [:]
                for source in computedIds {
                    let sourceSessions = compSleep.filter {
                        computedSleepSource[SleepExportIdentity($0)] == source
                    }
                    for (day, daySessions) in Dictionary(
                        grouping: sourceSessions,
                        by: computedEndDay
                    ) {
                        let representative = daySessions.max { $0.endTs < $1.endTs }
                        let historicalOffsetSec = representative.flatMap {
                            offsetBySleep[SleepExportIdentity($0)]
                        } ?? 0
                        let indices =
                            ScoreConfidence.publishableDetailedSleepStageSessionIndices(
                                blocks: daySessions.map {
                                    SleepStageTotals.NightBlock(
                                        start: $0.effectiveStartTs,
                                        end: $0.endTs)
                                },
                                rrEligibleWindowCounts:
                                    daySessions.map(\.rrEligibleWindowCount),
                                rrValidWindowCounts:
                                    daySessions.map(\.rrValidWindowCount),
                                independentlyStagedImport: false,
                                offsetSec: historicalOffsetSec,
                                habitualMidsleepSec: habitualMidsleepSec)
                        guard !indices.isEmpty else { continue }
                        let selected = indices.sorted()
                        let selectedMinutes = selected.compactMap { index in
                            let session = daySessions[index]
                            let clamped = SleepStageTotals.clampStagesToOnset(
                                session.stagesJSON,
                                onsetSec: session.effectiveStartTs)
                            return SleepStageTotals.minutes(fromStagesJSON: clamped)
                        }
                        guard selectedMinutes.count == selected.count else { continue }
                        var total = SleepStageTotals.Minutes()
                        for minutes in selectedMinutes {
                            total.awake += minutes.awake
                            total.light += minutes.light
                            total.deep += minutes.deep
                            total.rem += minutes.rem
                        }
                        publishableComputedMinutesByDay[source, default: [:]][day] = total
                        for index in selected {
                            publishableComputedSleep.insert(
                                SleepExportIdentity(daySessions[index]))
                        }
                    }
                }

                // Merged exactly like Repository.mergeDaily: computed first, imported overwrites, so a
                // real WHOOP import always wins and the strap-only user still exports a full history.
                var byDay: [String: DailyMetric] = [:]
                var sourceByDay: [String: String] = [:]
                var publishStagesByDay: [String: Bool] = [:]
                for d in computed {
                    let source = computedSourceByDay[d.day]
                    let minutes = source.flatMap {
                        publishableComputedMinutesByDay[$0]?[d.day]
                    }
                    byDay[d.day] = Repository.replacingDetailedStageColumns(
                        d,
                        with: minutes)
                    sourceByDay[d.day] = "noop (APPROXIMATE)"
                    publishStagesByDay[d.day] = minutes != nil
                }
                for d in imported {
                    byDay[d.day] = d
                    sourceByDay[d.day] = "import"
                    publishStagesByDay[d.day] = true
                }
                let days = byDay.values.sorted { $0.day < $1.day }

                // The cycles columns DailyMetric lacks, recovered from the imported metricSeries.
                var series: [String: [String: Double]] = [:]
                for (key, points) in seriesRaw {
                    for p in points { series[p.day, default: [:]][key] = p.value }
                }

                // Sleep: merged per bridged wake day, imported wins (Repository.mergeSleep semantics).
                // #715: keep EVERY session, naps and main nights each export as their own sleeps.csv row.
                // Imported still wins per end-day. Shared, unit-tested grouping (WhoopStore.SleepMerge) replaces
                // the per-day dict that silently dropped a second same-day session.
                let sleeps = SleepMerge.merge(
                    imported: impSleep,
                    computed: compSleep,
                    importedEndDay: importedEndDay,
                    computedEndDay: computedEndDay)

                // Workouts: imported WHOOP ∪ on-device detected. Apple-Health workouts are intentionally
                // omitted (read only the two NOOP sources), matching the cycles/sleep exclusion.
                // Dedup by (startTs, sport), imported (deviceId) first so it wins. The same session can
                // exist under both ids (e.g. a reimported export + BLE re-detection), which double-counted
                // it in the CSV and inflated totals on reimport. (PR #97 review, tigercraft4.)
                var seenWorkouts = Set<String>()
                let workouts = (impWorkouts + compWorkouts)
                    .filter { seenWorkouts.insert("\($0.startTs)|\($0.sport)").inserted }

                let portable = try PortableUserData(
                    nutritionEntries: nutritionEntries,
                    nutritionCatalogItems: nutritionCatalogItems,
                    strengthExercises: strengthExercises,
                    strengthRoutineSnapshots: strengthRoutines,
                    strengthSessionSnapshots: strengthSessions
                ).encodedData()
                let comparisonDaily = imported.map {
                    ComparisonDailyRow(
                        source: .wearableImport,
                        metric: $0,
                        publishDetailedStages: true
                    )
                } + computed.map { row in
                    let source = computedSourceByDay[row.day]
                    let minutes = source.flatMap {
                        publishableComputedMinutesByDay[$0]?[row.day]
                    }
                    return ComparisonDailyRow(
                        source: .noopComputed,
                        metric: Repository.replacingDetailedStageColumns(row, with: minutes),
                        publishDetailedStages: minutes != nil
                    )
                }
                let comparisonSleeps = impSleep.map {
                    ComparisonSleepRow(
                        source: .wearableImport,
                        session: $0,
                        publishDetailedStages: true
                    )
                } + compSleep.map {
                    ComparisonSleepRow(
                        source: .noopComputed,
                        session: $0,
                        publishDetailedStages:
                            publishableComputedSleep.contains(SleepExportIdentity($0))
                    )
                }
                let comparisonWorkouts = impWorkouts.map {
                    ComparisonWorkoutRow(
                        source: $0.source == "manual" ? .noopManual : .wearableImport,
                        workout: $0
                    )
                } + compWorkouts.map {
                    ComparisonWorkoutRow(source: .noopComputed, workout: $0)
                }
                var comparisonSeries: [ComparisonMetricRow] = []
                var seenComparisonSeries = Set<String>()
                for (source, ids) in [
                    (ComparisonSource.wearableImport, importedIds),
                    (ComparisonSource.noopComputed, computedIds),
                ] {
                    for id in ids {
                        for point in sidecar[id] ?? [] {
                            let key = "\(source.rawValue)|\(point.day)|\(point.key)"
                            guard seenComparisonSeries.insert(key).inserted else { continue }
                            comparisonSeries.append(
                                ComparisonMetricRow(
                                    source: source,
                                    day: point.day,
                                    key: point.key,
                                    value: point.value
                                )
                            )
                        }
                    }
                }
                var entries: [(name: String, data: Data)] = [
                    ("physiological_cycles.csv",
                     Data(WhoopCsvExporter.cyclesCSV(
                        days: days,
                        series: series,
                        sourceByDay: sourceByDay,
                        publishDetailedSleepStages: {
                            publishStagesByDay[$0.day] == true
                        },
                        detailedAwakeMinutes: { day in
                            guard sourceByDay[day.day] == "noop (APPROXIMATE)",
                                  let source = computedSourceByDay[day.day]
                            else { return nil }
                            return publishableComputedMinutesByDay[source]?[day.day]?.awake
                        }).utf8)),
                    ("sleeps.csv",
                     Data(WhoopCsvExporter.sleepsCSV(
                        sleeps,
                        // Every fragment of a bridged night uses the group's final local wake day, matching
                        // cycle aggregation even when the interruption straddles midnight.
                        cycleStart: { session in
                            let identity = SleepExportIdentity(session)
                            let day = importedWakeDayBySleep[identity]
                                ?? computedWakeDayBySleep[identity]
                                ?? ""
                            return day + " 00:00:00"
                        },
                        publishDetailedStages: { session in
                            let identity = SleepExportIdentity(session)
                            if importedSleepSource[identity] != nil { return true }
                            return publishableComputedSleep.contains(identity)
                        },
                        sourceBySession: { session in
                            let identity = SleepExportIdentity(session)
                            if importedSleepSource[identity] != nil { return "import" }
                            return computedSleepSource[identity] == nil
                                ? "" : "noop (APPROXIMATE)"
                        }).utf8)),
                    ("workouts.csv",
                     Data(WhoopCsvExporter.workoutsCSV(workouts, sourceLabel: { workoutSource($0, computedIds: computedIds) }).utf8)),
                    ("journal_entries.csv", Data(WhoopCsvExporter.journalCSV(journal).utf8)),
                    ("noop_metric_series.json", WhoopCsvExporter.metricSeriesJSON(sidecar)),
                    (PortableUserData.fileName, portable),
                ]
                entries += try comparisonEntries(
                    context: comparisonContext,
                    daily: comparisonDaily,
                    sleeps: comparisonSleeps,
                    workouts: comparisonWorkouts,
                    metricSeries: comparisonSeries,
                    detectorDecisions: autoWorkoutDecisions
                )
                // Deflate to a temp path off main; the cheap atomic swap into the user's chosen destination
                // stays on main (it needs the panel/picker result).
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".zip")
                try WhoopCsvExporter.writeArchive(entries: entries, to: out)
                return out
            }.value

            #if os(macOS)
            // Save panel — DataBackup.runExport precedent (NSSavePanel + .zip content type).
            let panel = NSSavePanel()
            panel.title = String(localized: "Export NOOP portable data")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else {
                try? FileManager.default.removeItem(at: tmp)
                return .cancelled
            }

            // Swap the freshly-written temp zip into place. Deleting the destination before a write that
            // can throw destroyed the user's previous export on failure (PR #97 review, tigercraft4).
            // replaceItemAt is atomic on APFS; the original survives a failed write.
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            return .exported(dest)
            #else
            // iOS: move the staged zip to its user-facing name, then hand it to the system document picker
            // so the user can save it into Files / iCloud Drive (DataBackup.runExport precedent). Clear any
            // stale staged copy first.
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: tmp, to: staged)
            guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
            return .exported(dest)
            #endif
        } catch {
            return .failure("Portable export failed: \(error.localizedDescription)")
        }
    }

    /// Classify a workout row for the provenance-aware Source column. The strings match how each row
    /// is written on this Mac: WhoopImporter uses source "whoop"; AppModel manual logging uses
    /// "manual"; IntelligenceEngine's on-device detected workouts use the computed source id with
    /// sport "detected". #458: a detected row's source may be EITHER computed union id (active-noop
    /// or canonical-noop), so membership replaces the single-id compare.
    private static func workoutSource(_ w: WorkoutRow, computedIds: [String]) -> String {
        if w.source == "manual" { return "manual" }
        if computedIds.contains(w.source) || w.sport == "detected" { return "noop (APPROXIMATE)" }
        return "import"
    }

    // MARK: - Parallel-wear comparison sidecars

    enum ComparisonSource: String, Sendable {
        case wearableImport = "wearable_import"
        case noopComputed = "noop_computed"
        case noopManual = "noop_manual"
    }

    struct ComparisonContext: Sendable {
        let generatedAtUTC: String
        let platform: String
        let appVersion: String
    }

    struct ComparisonDailyRow: Sendable {
        let source: ComparisonSource
        let metric: DailyMetric
        let publishDetailedStages: Bool
    }

    struct ComparisonSleepRow: Sendable {
        let source: ComparisonSource
        let session: CachedSleepSession
        let publishDetailedStages: Bool
    }

    struct ComparisonWorkoutRow: Sendable {
        let source: ComparisonSource
        let workout: WorkoutRow
    }

    struct ComparisonMetricRow: Sendable {
        let source: ComparisonSource
        let day: String
        let key: String
        let value: Double
    }

    /// Readable, source-separated study files carried inside every portable export. These entries are
    /// additive: NOOP's importer ignores the `comparison/` directory, while a tester can inspect or
    /// analyze it beside the original unmodified export from another wearable.
    static func comparisonEntries(
        context: ComparisonContext,
        daily: [ComparisonDailyRow],
        sleeps: [ComparisonSleepRow],
        workouts: [ComparisonWorkoutRow],
        metricSeries: [ComparisonMetricRow],
        detectorDecisions: [AutoWorkoutDecisionRecord] = []
    ) throws -> [(name: String, data: Data)] {
        let files = [
            "comparison/daily_metrics.csv": daily.count,
            "comparison/sleep_sessions.csv": sleeps.count,
            "comparison/workouts.csv": workouts.count,
            "comparison/metric_series.csv": metricSeries.count,
            "comparison/detector_decisions.csv": detectorDecisions.count,
        ]
        let manifest: [String: Any] = [
            "schema": "noop.parallel_wear.v1",
            "generated_at_utc": context.generatedAtUTC,
            "platform": context.platform,
            "app_version": context.appVersion,
            "contains_device_identifiers": false,
            "missing_value_encoding": "blank CSV field",
            "timestamp_encoding": "UTC ISO-8601",
            "day_encoding": "stored local calendar day (YYYY-MM-DD)",
            "sources": [
                ComparisonSource.wearableImport.rawValue:
                    "Values parsed from a user-supplied wearable export.",
                ComparisonSource.noopComputed.rawValue:
                    "Values estimated locally by NOOP from recorded sensor data.",
                ComparisonSource.noopManual.rawValue:
                    "Values explicitly entered or confirmed by the user in NOOP.",
            ],
            "score_scales": [
                "recovery_score": "0-100",
                "effort_score": "0-100",
                "sleep_score": "0-100",
                "sleep_efficiency": "fraction 0-1",
            ],
            "algorithm_revisions": [
                "charge": NoopScoreAlgorithmRevision.charge,
                "effort": NoopScoreAlgorithmRevision.effort,
                "rest": NoopScoreAlgorithmRevision.rest,
                "auto_workout_detector": AutoWorkoutDetector.detectorVersion,
            ],
            "detector_decisions_schema": "noop.detector_decisions.v1",
            "files": files,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        let detector: [String: Any] = [
            "detector_version": AutoWorkoutDetector.detectorVersion,
            "event_confidence_status": AutoWorkoutConfidenceStatus.uncalibrated.rawValue,
            "unattended_save_permitted": false,
            "decision_history": [
                "schema": "noop.detector_decisions.v1",
                "maximum_persisted_records": AutoWorkoutDecisionHistory.maxRecords,
                "computed_workout_rows_imply_acceptance": false,
                "legacy_tombstones_have_unknown_fields": true,
            ],
            "evidence": [
                "heart_rate": "required",
                "motion": "Dense motion confirms or rejects; sparse or absent motion falls back to heart-rate-only.",
                "workout_type": "Advisory broad class only; the user confirms the saved activity.",
            ],
            "rules": [
                "elevated_margin_bpm": AutoWorkoutDetector.elevatedMarginBPM,
                "minimum_sustained_minutes": AutoWorkoutDetector.minSustainedMin,
                "maximum_dip_seconds": AutoWorkoutDetector.maxDipS,
                "merge_gap_seconds": AutoWorkoutDetector.mergeGapS,
                "minimum_hr_samples": AutoWorkoutDetector.minHRSamples,
                "maximum_hr_sample_gap_seconds": AutoWorkoutDetector.maxHRSampleGapS,
                "maximum_seconds_per_hr_sample": AutoWorkoutDetector.maxSecondsPerHRSample,
                "motion_confirmation_mean": AutoWorkoutDetector.motionConfirmMean,
                "motion_confirmation_minimum_samples":
                    AutoWorkoutDetector.motionConfirmationMinSamples,
                "motion_confirmation_maximum_gap_seconds":
                    AutoWorkoutDetector.motionConfirmationMaxGapS,
            ],
        ]
        let detectorData = try JSONSerialization.data(
            withJSONObject: detector,
            options: [.prettyPrinted, .sortedKeys]
        )
        let readme = """
        NOOP PARALLEL-WEAR COMPARISON DATA

        Keep the other wearable's original export ZIP unchanged. Share that original ZIP and this
        NOOP ZIP together; do not replace either one with a re-zipped or spreadsheet-edited copy.

        The comparison directory separates imported wearable outcomes from NOOP estimates. Blank CSV
        fields mean the value was not recorded or was not eligible for publication; zero is never used
        as a substitute for missing data. Timestamps are UTC. Day keys preserve the local calendar day
        stored by the source. Score scales and algorithm revisions are listed in manifest.json.

        daily_metrics.csv contains one wide daily row per source and day.
        sleep_sessions.csv contains source-separated sleep windows and eligible stage totals.
        workouts.csv contains imported, manually confirmed, and NOOP-computed workout records.
        metric_series.csv contains the complete source-separated scalar series with explicit units.
        workout_detector.json records the detector version, thresholds, and confidence limitations.
        detector_decisions.csv records only durable accept, dismiss, automation, and review events.
        A saved computed workout is never inferred to mean the user accepted a detector suggestion.
        Older dismissals may appear as legacy tombstones with blank endpoint, decision-time, and
        evidence fields because those values were not historically stored.

        These files contain sensitive health data. NOOP creates them locally and does not upload them.
        Device identifiers, account identifiers, credentials, notes, and workout routes are excluded.
        """

        return [
            ("comparison/README.txt", Data((readme + "\n").utf8)),
            ("comparison/manifest.json", manifestData),
            ("comparison/daily_metrics.csv", Data(comparisonDailyCSV(daily).utf8)),
            ("comparison/sleep_sessions.csv", Data(comparisonSleepCSV(sleeps).utf8)),
            ("comparison/workouts.csv", Data(comparisonWorkoutCSV(workouts).utf8)),
            ("comparison/metric_series.csv", Data(comparisonMetricSeriesCSV(metricSeries).utf8)),
            ("comparison/detector_decisions.csv",
             Data(comparisonDetectorDecisionsCSV(detectorDecisions).utf8)),
            ("comparison/workout_detector.json", detectorData),
        ]
    }

    private static func comparisonDailyCSV(_ rows: [ComparisonDailyRow]) -> String {
        var out = "source,day,recovery_score_0_100,effort_score_0_100,total_sleep_min,"
            + "sleep_efficiency_fraction,light_sleep_min,deep_sleep_min,rem_sleep_min,"
            + "disturbances_count,resting_hr_bpm,hrv_ms,hrv_method,spo2_pct,"
            + "skin_temperature_value_c,skin_temperature_semantics,respiratory_rate_per_min,"
            + "steps_count,energy_kcal,raw_spo2_red_adc,raw_spo2_ir_adc,"
            + "detailed_sleep_stages_status\r\n"
        for row in rows.sorted(by: {
            ($0.source.rawValue, $0.metric.day) < ($1.source.rawValue, $1.metric.day)
        }) {
            let d = row.metric
            let hasStages = d.lightMin != nil || d.deepMin != nil || d.remMin != nil
            let stageStatus = row.publishDetailedStages
                ? (hasStages ? "available" : "not_recorded")
                : "withheld_insufficient_evidence"
            let skinSemantics: String
            if d.skinTempDevC == nil {
                skinSemantics = ""
            } else {
                skinSemantics = row.source == .wearableImport
                    ? "absolute_temperature" : "deviation_from_personal_baseline"
            }
            out += [
                row.source.rawValue,
                d.day,
                comparisonNumber(d.recovery),
                comparisonNumber(d.strain),
                comparisonNumber(d.totalSleepMin),
                comparisonNumber(d.efficiency),
                comparisonNumber(row.publishDetailedStages ? d.lightMin : nil),
                comparisonNumber(row.publishDetailedStages ? d.deepMin : nil),
                comparisonNumber(row.publishDetailedStages ? d.remMin : nil),
                comparisonNumber(d.disturbances),
                comparisonNumber(d.restingHr),
                comparisonNumber(d.avgHrv),
                comparisonField(d.avgHrv == nil ? nil : d.hrvMethod?.rawValue),
                comparisonNumber(d.spo2Pct),
                comparisonNumber(d.skinTempDevC),
                skinSemantics,
                comparisonNumber(d.respRateBpm),
                comparisonNumber(d.steps),
                comparisonNumber(d.activeKcalEst),
                comparisonNumber(d.spo2Red),
                comparisonNumber(d.spo2Ir),
                stageStatus,
            ].joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func comparisonSleepCSV(_ rows: [ComparisonSleepRow]) -> String {
        let formatter = comparisonUTCFormatter()
        var out = "source,session_start_utc,session_end_utc,duration_s,sleep_efficiency_fraction,"
            + "resting_hr_bpm,hrv_ms,light_sleep_min,deep_sleep_min,rem_sleep_min,awake_min,"
            + "user_edited,rr_eligible_window_count,rr_valid_window_count,"
            + "detailed_sleep_stages_status\r\n"
        for row in rows.sorted(by: {
            ($0.source.rawValue, $0.session.effectiveStartTs)
                < ($1.source.rawValue, $1.session.effectiveStartTs)
        }) {
            let s = row.session
            let stages = row.publishDetailedStages
                ? SleepStageTotals.minutes(fromStagesJSON: s.stagesJSON) : nil
            let stageStatus = row.publishDetailedStages
                ? (stages == nil ? "not_recorded" : "available")
                : "withheld_insufficient_evidence"
            let duration = s.endTs > s.effectiveStartTs ? s.endTs - s.effectiveStartTs : nil
            out += [
                row.source.rawValue,
                comparisonUTC(s.effectiveStartTs, formatter: formatter),
                comparisonUTC(s.endTs, formatter: formatter),
                comparisonNumber(duration),
                comparisonNumber(s.efficiency),
                comparisonNumber(s.restingHr),
                comparisonNumber(s.avgHrv),
                comparisonNumber(stages?.light),
                comparisonNumber(stages?.deep),
                comparisonNumber(stages?.rem),
                comparisonNumber(stages?.awake),
                s.userEdited ? "true" : "false",
                comparisonNumber(s.rrEligibleWindowCount),
                comparisonNumber(s.rrValidWindowCount),
                stageStatus,
            ].joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func comparisonWorkoutCSV(_ rows: [ComparisonWorkoutRow]) -> String {
        let formatter = comparisonUTCFormatter()
        var out = "source,workout_start_utc,workout_end_utc,duration_s,activity_name,"
            + "effort_score_0_100,energy_kcal,average_hr_bpm,max_hr_bpm,distance_m,"
            + "steps_count,hr_zone_1_pct,hr_zone_2_pct,hr_zone_3_pct,hr_zone_4_pct,"
            + "hr_zone_5_pct\r\n"
        for row in rows.sorted(by: {
            ($0.source.rawValue, $0.workout.startTs)
                < ($1.source.rawValue, $1.workout.startTs)
        }) {
            let w = row.workout
            let duration = w.durationS
                ?? (w.endTs > w.startTs ? Double(w.endTs - w.startTs) : nil)
            let zones = comparisonZonePercents(w.zonesJSON)
            out += [
                row.source.rawValue,
                comparisonUTC(w.startTs, formatter: formatter),
                comparisonUTC(w.endTs, formatter: formatter),
                comparisonNumber(duration),
                comparisonField(w.sport),
                comparisonNumber(w.strain),
                comparisonNumber(w.energyKcal),
                comparisonNumber(w.avgHr),
                comparisonNumber(w.maxHr),
                comparisonNumber(w.distanceM),
                comparisonNumber(w.steps),
                comparisonNumber(zones?[0]),
                comparisonNumber(zones?[1]),
                comparisonNumber(zones?[2]),
                comparisonNumber(zones?[3]),
                comparisonNumber(zones?[4]),
            ].joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func comparisonMetricSeriesCSV(_ rows: [ComparisonMetricRow]) -> String {
        var out = "source,day,metric_key,value,unit\r\n"
        for row in rows.filter({ $0.value.isFinite }).sorted(by: {
            ($0.source.rawValue, $0.day, $0.key)
                < ($1.source.rawValue, $1.day, $1.key)
        }) {
            out += [
                row.source.rawValue,
                row.day,
                comparisonField(row.key),
                comparisonNumber(row.value),
                comparisonField(comparisonUnit(for: row.key, source: row.source)),
            ].joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func comparisonDetectorDecisionsCSV(
        _ rows: [AutoWorkoutDecisionRecord]
    ) -> String {
        let formatter = comparisonUTCFormatter()
        var out = "candidate_start_utc,candidate_end_utc,decision_recorded_utc,action,actor,"
            + "activity_name,detector_version,average_hr_bpm,peak_hr_bpm,"
            + "event_confidence_0_1,type_hint_class,type_hint_confidence_0_1,"
            + "confidence_status,evidence_provenance,record_origin\r\n"
        for row in rows.sorted(by: {
            ($0.candidateStartSec, $0.recordedAtSec ?? .min, $0.action.rawValue)
                < ($1.candidateStartSec, $1.recordedAtSec ?? .min, $1.action.rawValue)
        }) {
            out += [
                comparisonUTC(row.candidateStartSec, formatter: formatter),
                row.candidateEndSec.map {
                    comparisonUTC($0, formatter: formatter)
                } ?? "",
                row.recordedAtSec.map {
                    comparisonUTC($0, formatter: formatter)
                } ?? "",
                row.action.rawValue,
                row.actor.rawValue,
                comparisonField(row.activityName),
                comparisonField(row.detectorVersion),
                comparisonNumber(row.averageBpm),
                comparisonNumber(row.peakBpm),
                comparisonNumber(row.eventConfidence),
                comparisonField(row.suggestedClass),
                comparisonNumber(row.suggestionConfidence),
                comparisonField(row.confidenceStatus),
                comparisonField(row.evidenceProvenance),
                row.origin,
            ].joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func comparisonUnit(for key: String, source: ComparisonSource) -> String {
        switch key {
        case "recovery", "strain", "sleep_performance":
            return "score_0_100"
        case "sleep_efficiency":
            return "fraction_0_1"
        case "sleep_consistency", "hours_vs_needed_pct", "restorative_pct", "spo2",
             "body_fat":
            return "percent_0_100"
        case "avg_hr", "max_hr", "rhr":
            return "bpm"
        case "hrv":
            return "ms"
        case "resp_rate":
            return "breaths_per_min"
        case "skin_temp":
            return source == .wearableImport
                ? "celsius_absolute" : "celsius_delta_from_baseline"
        case let value where value.hasSuffix("_min"):
            return "min"
        case "energy_kcal", "active_kcal", "basal_kcal", "total_kcal", "calories_in":
            return "kcal"
        case "steps", "steps_est", "disturbances", "exercise_count":
            return "count"
        case "distance_m":
            return "m"
        case "weight", "lean_mass":
            return "kg"
        case "height":
            return "cm"
        case "vo2max", "vo2max_est":
            return "mL_per_kg_per_min"
        case "fitness_age", "body_age":
            return "decimal_years"
        case "mood":
            return "score_1_5"
        case "stress":
            return "score_0_3"
        case "rest_evidence_flags":
            return "bitmask"
        case "spo2_red", "spo2_ir":
            return "adc"
        default:
            return "unspecified"
        }
    }

    private static func comparisonZonePercents(_ json: String?) -> [Double]? {
        guard let json, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let values = (1...5).map { index in
            ((object["z\(index)"] ?? object["zone\(index)"]) as? NSNumber)?.doubleValue ?? 0
        }
        return values.contains(where: { $0 > 0 }) ? values : nil
    }

    private static func comparisonField(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var safe = raw
        if let first = safe.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            safe = "'" + safe
        }
        guard safe.contains(",") || safe.contains("\"")
                || safe.contains("\n") || safe.contains("\r")
        else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func comparisonNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return value == value.rounded() && abs(value) < 1e12
            ? String(Int64(value)) : String(value)
    }

    private static func comparisonNumber(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func comparisonUTCFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }

    private static func comparisonUTC(_ ts: Int, formatter: DateFormatter) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // @MainActor: Repository.localDayKey is MainActor-isolated (Repository is @MainActor); only
    // called from `run`, which already is.
    @MainActor
    private static func defaultName() -> String {
        "noop-export-\(Repository.localDayKey(Date())).zip"
    }
}
