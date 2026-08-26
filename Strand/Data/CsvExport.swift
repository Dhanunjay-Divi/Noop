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
                let entries: [(name: String, data: Data)] = [
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

    // @MainActor: Repository.localDayKey is MainActor-isolated (Repository is @MainActor); only
    // called from `run`, which already is.
    @MainActor
    private static func defaultName() -> String {
        "noop-export-\(Repository.localDayKey(Date())).zip"
    }
}
