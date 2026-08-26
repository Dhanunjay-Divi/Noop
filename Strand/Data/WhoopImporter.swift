import Foundation
import WhoopStore
import StrandImport

/// Maps a parsed Whoop CSV export into the on-device WhoopStore tables the UI reads
/// (dailyMetric + sleepSession), so importing lights up the full history immediately.
enum WhoopImporter {

    /// The WHOOP CSV mapping revision, stamped into the Import test-mode parser line. Bump when this
    /// importer's column->store mapping changes so a shared report's parser version is unambiguous.
    static let importerVersion = 5
    /// Shared provenance stamp for comparison/calibration. Keep this derived from `importerVersion`
    /// so UI call sites cannot drift from the importer that actually wrote the reference rows.
    static var schemaRevision: String { "whoop-csv-import-v\(importerVersion)" }

    /// Complete generic-series ownership for each CSV projection. Re-import replaces these keys over
    /// the source file's represented day range, including values that disappeared from a newer export.
    private static let cycleSeriesKeys: Set<String> = [
        "recovery", "strain", "rhr", "hrv", "spo2", "skin_temp", "resp_rate",
        "energy_kcal", "avg_hr", "max_hr", "sleep_total_min", "in_bed_min",
        "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "awake_min",
        "sleep_efficiency", "sleep_performance", "sleep_consistency", "sleep_need_min",
        "sleep_debt_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct",
        // Importer v2 wrote this derived proxy. It is intentionally absent from current rows, so
        // including it in replacement removes stale values without a separate non-atomic cleanup.
        "stress",
    ]
    private static let workoutSeriesKeys: Set<String> = [
        "hr_zone1_min", "hr_zone2_min", "hr_zone3_min", "hr_zone4_min", "hr_zone5_min",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min",
    ]

    private static func roundedInt(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    private static func unixSecond(_ date: Date?) -> Int? {
        guard let seconds = date?.timeIntervalSince1970, seconds.isFinite else { return nil }
        return Int(exactly: seconds.rounded(.towardZero))
    }

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore, deviceId: String,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> ImportSummary {
        let result = try ImportCoordinator().importWhoopExport(from: url)
        let computedDeviceId = deviceId.hasSuffix("-noop") ? deviceId : deviceId + "-noop"

        // Genuine WHOOP CSVs have no Source column. NOOP exports add one so their local estimates can
        // round-trip without ever entering the official-reference namespace. Unknown non-empty producers
        // are quarantined rather than silently promoted to official WHOOP data.
        let officialCycles = result.cycles.filter {
            WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel) == .officialReference
        }
        let approximateCycles = result.cycles.filter {
            let provenance = WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel)
            return provenance == .noopApproximate || provenance == .noopLocal
        }
        let officialSleeps = result.sleeps.filter {
            WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel) == .officialReference
        }
        let approximateSleeps = result.sleeps.filter {
            let provenance = WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel)
            return provenance == .noopApproximate || provenance == .noopLocal
        }
        let officialWorkouts = result.workouts.filter {
            WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel) == .officialReference
        }
        let approximateWorkouts = result.workouts.filter {
            let provenance = WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel)
            return provenance == .noopApproximate || provenance == .noopLocal
        }

        // physiological_cycles → DailyMetric (one row per sleep-to-sleep day)
        var metrics: [DailyMetric] = []
        var approximateMetrics: [DailyMetric] = []
        func appendMetric(_ c: WhoopCycleRow, to target: inout [DailyMetric]) {
            guard let day = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                     tzOffsetMin: c.tzOffsetMin) else { return }
            target.append(DailyMetric(
                day: day,
                totalSleepMin: c.asleepDurationMin,
                // CSV "Sleep efficiency %" (0–100) → the store's native 0–1 fraction at the boundary.
                efficiency: WhoopExportImporter.fractionFromImportedEfficiencyPct(c.sleepEfficiencyPct),
                deepMin: c.deepSleepDurationMin,
                remMin: c.remDurationMin,
                lightMin: c.lightSleepDurationMin,
                disturbances: nil,
                restingHr: roundedInt(c.restingHeartRate),
                avgHrv: c.hrvMs,
                recovery: c.recoveryScore,
                // WHOOP Day Strain (0–21) → NOOP's 0–100 Effort axis at the store boundary.
                strain: WhoopExportImporter.effortFromImportedDayStrain(c.dayStrain),
                exerciseCount: nil,
                spo2Pct: c.bloodOxygenPct,
                skinTempDevC: c.skinTempCelsius,   // NOTE: Whoop export gives absolute °C, not a baseline deviation
                respRateBpm: c.respiratoryRate))
        }
        for c in officialCycles { appendMetric(c, to: &metrics) }
        for c in approximateCycles { appendMetric(c, to: &approximateMetrics) }

        // sleeps → CachedSleepSession (stage durations encoded as JSON; export has no per-epoch timeline)
        var sessions: [CachedSleepSession] = []
        var approximateSessions: [CachedSleepSession] = []
        func appendSession(_ s: WhoopSleepRow, to target: inout [CachedSleepSession]) {
            guard !s.isNap, let onset = s.sleepOnset, let wake = s.wakeOnset else { return }
            let stages: [String: Double] = [
                "light": s.lightSleepDurationMin ?? 0,
                "deep": s.deepSleepDurationMin ?? 0,
                "rem": s.remDurationMin ?? 0,
                "awake": s.awakeDurationMin ?? 0,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: stages))
                .flatMap { String(data: $0, encoding: .utf8) }
            guard let startTs = unixSecond(onset), let endTs = unixSecond(wake) else { return }
            target.append(CachedSleepSession(
                startTs: startTs,
                endTs: endTs,
                efficiency: WhoopExportImporter.fractionFromImportedEfficiencyPct(s.sleepEfficiencyPct),
                restingHr: nil, avgHrv: nil, stagesJSON: json))
        }
        for s in officialSleeps { appendSession(s, to: &sessions) }
        for s in approximateSleeps { appendSession(s, to: &approximateSessions) }

        // Generic metric series — every cycle field, keyed, for the explorer + correlations.
        var points: [MetricPoint] = []
        var approximatePoints: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?, approximate: Bool) {
            guard let v, v.isFinite else { return }
            let point = MetricPoint(day: day, key: key, value: v)
            if approximate {
                approximatePoints.append(point)
            } else {
                points.append(point)
            }
        }
        func appendCyclePoints(_ cycles: [WhoopCycleRow], approximate: Bool) {
            for c in cycles {
                guard let day = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                         tzOffsetMin: c.tzOffsetMin) else { continue }
                add(day, "recovery", c.recoveryScore, approximate: approximate)
                add(day, "strain", WhoopExportImporter.effortFromImportedDayStrain(c.dayStrain),
                    approximate: approximate)
                add(day, "rhr", c.restingHeartRate, approximate: approximate)
                add(day, "hrv", c.hrvMs, approximate: approximate)
                add(day, "spo2", c.bloodOxygenPct, approximate: approximate)
                add(day, "skin_temp", c.skinTempCelsius, approximate: approximate)
                add(day, "resp_rate", c.respiratoryRate, approximate: approximate)
                add(day, "energy_kcal", c.energyKcal, approximate: approximate)
                add(day, "avg_hr", c.avgHeartRate, approximate: approximate)
                add(day, "max_hr", c.maxHeartRate, approximate: approximate)
                add(day, "sleep_total_min", c.asleepDurationMin, approximate: approximate)
                add(day, "in_bed_min", c.inBedDurationMin, approximate: approximate)
                add(day, "sleep_deep_min", c.deepSleepDurationMin, approximate: approximate)
                add(day, "sleep_rem_min", c.remDurationMin, approximate: approximate)
                add(day, "sleep_light_min", c.lightSleepDurationMin, approximate: approximate)
                add(day, "awake_min", c.awakeDurationMin, approximate: approximate)
                add(
                    day,
                    "sleep_efficiency",
                    WhoopExportImporter.fractionFromImportedEfficiencyPct(c.sleepEfficiencyPct),
                    approximate: approximate
                )
                add(day, "sleep_performance", c.sleepPerformancePct, approximate: approximate)
                add(day, "sleep_consistency", c.sleepConsistencyPct, approximate: approximate)
                add(day, "sleep_need_min", c.sleepNeedMin, approximate: approximate)
                add(day, "sleep_debt_min", c.sleepDebtMin, approximate: approximate)
                if let deep = c.deepSleepDurationMin, let rem = c.remDurationMin {
                    add(day, "restorative_min", deep + rem, approximate: approximate)
                    if let asleep = c.asleepDurationMin, asleep > 0 {
                        add(day, "restorative_pct", (deep + rem) / asleep * 100,
                            approximate: approximate)
                    }
                }
                if let asleep = c.asleepDurationMin, let need = c.sleepNeedMin, need > 0 {
                    add(day, "hours_vs_needed_pct", asleep / need * 100, approximate: approximate)
                }
            }
        }
        appendCyclePoints(officialCycles, approximate: false)
        appendCyclePoints(approximateCycles, approximate: true)
        let officialCyclePoints = points
        let approximateCyclePoints = approximatePoints
        points.removeAll(keepingCapacity: true)
        approximatePoints.removeAll(keepingCapacity: true)
        // WHOOP's export does not include its proprietary Stress Monitor series here. Do not derive a
        // NOOP proxy from the full export and write it back into WHOOP's official namespace: that both
        // misstates provenance and lets future days influence older scores. The causal NOOP estimate is
        // derived at read time from strictly prior days by DailyAutonomicLoad instead.
        // Derived: daily HR-zone minutes + strength-activity time from workouts.
        func appendWorkoutPoints(_ sourceRows: [WhoopWorkoutRow], approximate: Bool) {
            struct ZoneDay {
                var minutes = Array(repeating: 0.0, count: 5)
                var observed = Array(repeating: false, count: 5)
                var complete = Array(repeating: true, count: 5)
            }
            var zoneByDay: [String: ZoneDay] = [:]
            var strengthByDay: [String: Double] = [:]
            for w in sourceRows {
                guard let s = w.workoutStart, let e = w.workoutEnd, e > s else { continue }
                let day = dayString(s, tzOffsetMin: w.tzOffsetMin)
                let dur = e.timeIntervalSince(s) / 60.0
                let zp = [w.hrZone1Pct, w.hrZone2Pct, w.hrZone3Pct, w.hrZone4Pct, w.hrZone5Pct]
                var accumulator = zoneByDay[day] ?? ZoneDay()
                let valid = zp.map { value -> Double? in
                    guard let value, value.isFinite, (0...100).contains(value) else {
                        return nil
                    }
                    return value
                }
                let reportedSum = valid.compactMap { $0 }.reduce(0, +)
                let allReported = valid.allSatisfy { $0 != nil }
                let impossibleTotal = reportedSum > 101 || (!allReported && reportedSum > 100)
                if impossibleTotal {
                    // Keeping individually plausible columns from an impossible row would
                    // understate that same workout. Mark the complete day aggregate unavailable.
                    accumulator.complete = Array(repeating: false, count: 5)
                } else {
                    // Integer percentages can round to 101. Scale only that narrow, complete case
                    // so zoned minutes never exceed the workout duration.
                    let scale = allReported && reportedSum > 100 ? 100 / reportedSum : 1
                    for i in 0..<5 {
                        guard let p = valid[i] else {
                            accumulator.complete[i] = false
                            continue
                        }
                        accumulator.minutes[i] += dur * p * scale / 100.0
                        accumulator.observed[i] = true
                    }
                }
                zoneByDay[day] = accumulator
                if let n = w.activityName?.lowercased(), n.contains("strength") || n.contains("weight") {
                    strengthByDay[day, default: 0] += dur
                }
            }
            for (day, accumulator) in zoneByDay {
                let available = zip(accumulator.complete, accumulator.observed).map { $0 && $1 }
                for i in 0..<5 where available[i] {
                    add(day, "hr_zone\(i + 1)_min", accumulator.minutes[i],
                        approximate: approximate)
                }
                if available[0...2].allSatisfy({ $0 }) {
                    add(day, "hr_zones13_min",
                        accumulator.minutes[0...2].reduce(0, +), approximate: approximate)
                }
                if available[3...4].allSatisfy({ $0 }) {
                    add(day, "hr_zones45_min",
                        accumulator.minutes[3...4].reduce(0, +), approximate: approximate)
                }
                if available.allSatisfy({ $0 }) {
                    add(day, "hr_zones_all_min",
                        accumulator.minutes.reduce(0, +), approximate: approximate)
                }
            }
            for (day, m) in strengthByDay {
                add(day, "strength_min", m, approximate: approximate)
            }
        }
        appendWorkoutPoints(officialWorkouts, approximate: false)
        appendWorkoutPoints(approximateWorkouts, approximate: true)
        let officialWorkoutPoints = points
        let approximateWorkoutPoints = approximatePoints
        points = officialCyclePoints + officialWorkoutPoints
        approximatePoints = approximateCyclePoints + approximateWorkoutPoints

        func cycleDays(_ cycles: [WhoopCycleRow]) -> Set<String> {
            Set(cycles.compactMap {
                cycleDay(wake: $0.wakeOnset, end: $0.cycleEnd, start: $0.cycleStart,
                         tzOffsetMin: $0.tzOffsetMin)
            })
        }
        func workoutDays(_ workouts: [WhoopWorkoutRow]) -> Set<String> {
            Set(workouts.compactMap { workout in
                guard let start = workout.workoutStart,
                      let end = workout.workoutEnd,
                      end > start else { return nil }
                return dayString(start, tzOffsetMin: workout.tzOffsetMin)
            })
        }
        func range(_ days: Set<String>) -> ClosedRange<String>? {
            guard let first = days.min(), let last = days.max() else { return nil }
            return first...last
        }
        var officialSeriesReplacements: [WhoopCSVMetricSeriesReplacement] = []
        let officialCycleSpan = range(cycleDays(officialCycles))
        if let span = officialCycleSpan {
            officialSeriesReplacements.append(
                WhoopCSVMetricSeriesReplacement(
                    rows: officialCyclePoints,
                    deviceId: deviceId,
                    from: span.lowerBound,
                    to: span.upperBound,
                    managedKeys: Self.cycleSeriesKeys
                )
            )
        }
        if let span = range(workoutDays(officialWorkouts)) {
            officialSeriesReplacements.append(
                WhoopCSVMetricSeriesReplacement(
                    rows: officialWorkoutPoints,
                    deviceId: deviceId,
                    from: span.lowerBound,
                    to: span.upperBound,
                    managedKeys: Self.workoutSeriesKeys
                )
            )
        }

        // Journal behaviours → correlation insights.
        // #136: journal_entries.csv keys only by cycle_start (the onset evening). Map each cycle's onset to
        // its WAKE day so an entry lands on the same day as the recovery/sleep it correlates against — the
        // day parseCycles and the native journal use. Keying off the onset put every entry one day early,
        // so it never matched its outcome and all historic days collapsed into "Without" (issue #136).
        var wakeDayByStart: [Int: String] = [:]
        for c in officialCycles + approximateCycles {
            guard let start = c.cycleStart,
                  let wake = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                      tzOffsetMin: c.tzOffsetMin) else { continue }
            guard let startTs = unixSecond(start) else { continue }
            wakeDayByStart[startTs] = wake
        }
        let journal: [JournalEntry] = result.journal.compactMap { j in
            guard let start = j.cycleStart, let q = j.question else { return nil }
            let answeredYes: Bool
            switch j.answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "y": answeredYes = true
            case "false", "no", "0", "n": answeredYes = false
            default: return nil
            }
            // Fall back to the onset day only when the cycle isn't in the export.
            let day = unixSecond(start).flatMap { wakeDayByStart[$0] }
                ?? dayString(start, tzOffsetMin: j.tzOffsetMin)
            return JournalEntry(day: day,
                                question: q,
                                answeredYes: answeredYes,
                                notes: j.notes)
        }
        // #136: the wake-day fix moves an entry's day, so a naive re-import would leave the pre-fix
        // onset-keyed rows behind as duplicates. Atomically clear + re-write EXACTLY the day span we
        // import, so journal outside the imported range (e.g. from an earlier, wider export) is never
        // touched, and a crash mid-import can't drop the range. Same "re-import replaces this period"
        // semantics daily/sleep already have. The range comes from source rows BEFORE ambiguous and
        // contradictory answers are filtered, so re-importing an empty/conflicted key clears stale data.
        let journalReplacement = result.journalImportRange.map {
            WhoopCSVJournalReplacement(
                rows: journal,
                deviceId: deviceId,
                from: $0.lowerBound,
                to: $0.upperBound
            )
        }

        // Workouts.
        func mappedWorkouts(_ sourceRows: [WhoopWorkoutRow], approximate: Bool) -> [WorkoutRow] {
            sourceRows.compactMap { w in
                guard let s = w.workoutStart, let e = w.workoutEnd, e > s else { return nil }
                let zones = ["z1": w.hrZone1Pct, "z2": w.hrZone2Pct, "z3": w.hrZone3Pct,
                             "z4": w.hrZone4Pct, "z5": w.hrZone5Pct].compactMapValues { $0 }
                let zjson = (try? JSONSerialization.data(withJSONObject: zones))
                    .flatMap { String(data: $0, encoding: .utf8) }
                guard let startTs = unixSecond(s), let endTs = unixSecond(e) else { return nil }
                return WorkoutRow(
                    startTs: startTs,
                    endTs: endTs,
                    sport: w.activityName ?? "Workout",
                    source: approximate
                        ? (WhoopCSVRowProvenance.classify(sourceLabel: w.sourceLabel) == .noopLocal
                           ? "manual" : computedDeviceId)
                        : "whoop",
                    durationS: e.timeIntervalSince(s),
                    energyKcal: w.energyKcal,
                    avgHr: roundedInt(w.avgHeartRate),
                    maxHr: roundedInt(w.maxHeartRate),
                    strain: WhoopExportImporter.effortFromImportedDayStrain(w.activityStrain),
                    distanceM: w.distanceMeters,
                    zonesJSON: zjson,
                    notes: nil)
            }
        }
        let workouts = mappedWorkouts(officialWorkouts, approximate: false)
        let approximateMappedWorkouts = mappedWorkouts(approximateWorkouts, approximate: true)
        let officialDailyMetricRange = officialCycleSpan.map {
            WhoopCSVDayRange(from: $0.lowerBound, to: $0.upperBound)
        }
        let officialSleepStarts = officialSleeps.compactMap { unixSecond($0.sleepOnset) }
        let officialSleepSessionRange: WhoopCSVTimestampRange? = {
            guard let first = officialSleepStarts.min(), let last = officialSleepStarts.max() else {
                return nil
            }
            return WhoopCSVTimestampRange(from: first, to: last)
        }()
        let officialWorkoutStarts = officialWorkouts.compactMap { unixSecond($0.workoutStart) }
        let officialWorkoutRange: WhoopCSVTimestampRange? = {
            guard let first = officialWorkoutStarts.min(), let last = officialWorkoutStarts.max() else {
                return nil
            }
            return WhoopCSVTimestampRange(from: first, to: last)
        }()

        // Commit the complete relational CSV projection together. Official rows remain authoritative.
        // Local daily rows fill missing fields/rows; other approximate projections remain insert-only
        // in the analytics-owned `-noop` namespace.
        let writeCounts = try await store.importWhoopCSV(
            WhoopCSVImportBatch(
                officialDailyMetrics: metrics,
                officialDailyMetricRange: officialDailyMetricRange,
                fillOnlyDailyMetrics: approximateMetrics,
                officialSleepSessions: sessions,
                officialSleepSessionRange: officialSleepSessionRange,
                fillOnlySleepSessions: approximateSessions,
                officialMetricSeriesReplacements: officialSeriesReplacements,
                fillOnlyMetricSeries: approximatePoints,
                journalReplacement: journalReplacement,
                officialWorkouts: workouts,
                officialWorkoutRange: officialWorkoutRange,
                fillOnlyWorkouts: approximateMappedWorkouts,
                officialDeviceId: deviceId,
                fillOnlyDeviceId: computedDeviceId
            )
        )

        // `noop_user_data.json` was decoded and its complete relationship graph validated before this
        // method began writing. Merge the accepted nutrition/strength rows atomically by stable ID;
        // newer/equal local edits and built-in exercise definitions remain authoritative.
        let portableSummary: PortableUserDataImportSummary?
        if let portable = result.portableUserData {
            portableSummary = try await store.importPortableUserData(portable)
        } else {
            portableSummary = nil
        }

        // Stamp only rows that actually traversed the provenance-aware official path. Legacy rows already
        // in the namespace remain untouched but unverified, so Compare cannot silently relabel them.
        let referenceManifest = WhoopReferenceImportManifest()
        for replacement in officialSeriesReplacements {
            referenceManifest.replaceOfficialMetrics(
                replacement.rows.map { (day: $0.day, metricKey: $0.key) },
                deviceId: deviceId,
                schemaRevision: schemaRevision,
                from: replacement.from,
                to: replacement.to,
                managedKeys: replacement.managedKeys
            )
        }

        // Import & Data Ingest test mode (Test Centre): emit the per-stage / reject / day-delta trace iff
        // the mode is on. The caller passes a non-nil `trace` ONLY when TestCentre.active(.dataImport), so
        // nothing here runs when the mode is off (zero cost). The numbers are the SAME ones the import just
        // produced (parsed counts + the rows the store reported writing), so emitting them changes nothing
        // about what was saved. No raw cell value or file name is in any of these lines.
        if let trace {
            let c = result.summary.countsByCategory
            // Per-stage rowsIn is the rows actually HANDED to the store (after the app's mapping drops), so
            // rowsOut < rowsIn isolates the STORE-write delta - the day-owner-collision / "didn't save" tell
            // (#601 / #749) - rather than conflating it with the parser/map drop, which the reject line owns.
            // dailyMetric is keyed by (deviceId, day), so metrics.count == the mapped distinct days.
            let daysMapped = Set((metrics + approximateMetrics).map { $0.day }).count
            // Rows the PARSER produced but the app map then dropped (a cycle with no cycleStart, a non-nap
            // sleep with no onset/wake, a workout with no start/end): the genuine ingest reject count.
            let parsedCycles = c["cycles"] ?? 0
            let parsedSleeps = c["sleeps"] ?? 0
            let parsedWorkouts = c["workouts"] ?? 0
            let acceptedMetricCount = metrics.count + approximateMetrics.count
            let acceptedSessionCount = sessions.count + approximateSessions.count
            let acceptedWorkoutCount = workouts.count + approximateMappedWorkouts.count
            let droppedInMap = max(0, parsedCycles - acceptedMetricCount)
                + max(0, parsedSleeps - acceptedSessionCount)
                + max(0, parsedWorkouts - acceptedWorkoutCount)
            let totalMetricsWritten = writeCounts.dailyMetrics
            let totalSessionsWritten = writeCounts.sleepSessions
            let totalWorkoutsWritten = writeCounts.workouts
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: .whoopExport, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "cycles", rowsIn: acceptedMetricCount,
                                      rowsOut: totalMetricsWritten),
                ImportTrace.stageLine(category: "sleeps", rowsIn: acceptedSessionCount,
                                      rowsOut: totalSessionsWritten),
                ImportTrace.stageLine(category: "workouts", rowsIn: acceptedWorkoutCount,
                                      rowsOut: totalWorkoutsWritten),
                ImportTrace.rejectLine(droppedRows: droppedInMap, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "cycles", daysMapped: daysMapped,
                                         daysPersisted: totalMetricsWritten),
            ]
            trace(lines)
        }

        var summary = result.summary
        if let portableSummary {
            let portableCounts = [
                "nutritionEntries": portableSummary.nutritionEntries,
                "strengthExercises": portableSummary.strengthExercises,
                "strengthRoutines": portableSummary.strengthRoutines,
                "strengthRoutineExercises": portableSummary.strengthRoutineExercises,
                "strengthSessions": portableSummary.strengthSessions,
                "strengthSets": portableSummary.strengthSets,
            ]
            for (category, count) in portableCounts where count > 0 {
                summary.countsByCategory[category] = count
            }
            summary.recordCount += portableSummary.total
            if let portable = result.portableUserData {
                summary.earliest = [summary.earliest, portable.earliestDate].compactMap { $0 }.min()
                summary.latest = [summary.latest, portable.latestDate].compactMap { $0 }.max()
            }
        }
        return summary
    }

    /// The NOOP day a WHOOP cycle belongs to: the local calendar day you WOKE. See
    /// `WhoopDayKeying.wakeDayKey` for the full rationale (WHOOP exports are onset-to-onset, so a
    /// cycle's start is the evening before; keying off it blanked Today for import-only users, v8.2.1).
    private static func cycleDay(wake: Date?, end: Date?, start: Date?, tzOffsetMin: Int) -> String? {
        WhoopDayKeying.wakeDayKey(wake: wake, end: end, start: start, tzOffsetMin: tzOffsetMin)
    }

    /// Local-calendar day string for the cycle's own UTC offset.
    private static func dayString(_ d: Date, tzOffsetMin: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
