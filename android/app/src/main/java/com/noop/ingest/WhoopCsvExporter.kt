package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.analytics.AutoWorkoutDetector
import com.noop.data.DailyHrvMethod
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.PortableStrengthExercise
import com.noop.data.PortableUserData
import com.noop.data.PortableUserDataCodec
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.sync.RemoteNoopAlgorithmRevision
import com.noop.ui.AutoWorkoutPrefs
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.time.Instant
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round

/**
 * Serializes NOOP's own cached rows back into WHOOP's 4-CSV export shape so NOOP's OWN importer
 * (WhoopCsvImporter here, WhoopExportImporter on macOS) re-imports them losslessly. The round-trip
 * is the point and is pinned by the test suite (Android exporter test + the macOS suite, which
 * re-parses this output with the REAL importer) so header/format drift fails a test rather than
 * silently producing an un-reimportable zip.
 *
 * Header strings are byte-identical to a real WHOOP export — the importer normalises them down to
 * keys like `recovery_score_pct`, so they must match exactly. Everything is emitted in UTC with a
 * literal "UTC+00:00" timezone column: NOOP stores epoch seconds and tz-less day strings, so UTC is
 * the only encoding that round-trips a timestamp back to the same instant. A trailing "Source"
 * column (which both parsers provably ignore — they key off named columns, never position) marks
 * on-device computed rows as "noop (APPROXIMATE)" per the house rules. A noop_metric_series.json
 * sidecar carries the full metricSeries for inspection. A separate versioned
 * `noop_user_data.json` sidecar round-trips editable nutrition and normalized Strength Trainer
 * records across Apple and Android; the native encrypted backup remains the same-platform
 * full-device restore path.
 */
object WhoopCsvExporter {

    private val UTC_FMT: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
            .withZone(java.time.ZoneOffset.UTC)

    internal fun utc(epochSeconds: Long): String =
        UTC_FMT.format(java.time.Instant.ofEpochSecond(epochSeconds))

    /**
     * RFC-4180: only quote when the field carries a comma, quote, CR or LF; escape `"` by doubling.
     *
     * Formula-injection guard: a free-text value starting with `=`, `+`, `-`, `@`, tab or CR is
     * executed as a formula by Excel/Sheets/LibreOffice when the CSV is opened there (quoting alone
     * does NOT prevent that). Neutralise with a leading apostrophe — the spreadsheet convention for
     * "literal text". Numbers never pass through csvField (they use num()), so this only ever
     * touches free text such as source names. Mirrors the Swift exporter's field().
     */
    internal fun csvField(raw: String?): String {
        if (raw.isNullOrEmpty()) return ""
        val safe = if (raw.first() in "=+-@\t\r") "'$raw" else raw
        if (safe.none { it == ',' || it == '"' || it == '\n' || it == '\r' }) return safe
        return "\"" + safe.replace("\"", "\"\"") + "\""
    }

    /** Locale-proof numbers: integral Doubles print without a trailing ".0"; Double.toString uses
     *  '.' regardless of locale, so the importer's parse can't be defeated by a comma decimal. */
    internal fun num(v: Double?): String = when {
        v == null -> ""
        v == floor(v) && abs(v) < 1e12 -> v.toLong().toString()
        else -> v.toString()
    }

    internal fun num(v: Int?): String = v?.toString() ?: ""

    internal data class DailyExportRow(
        val metric: DailyMetric,
        val source: String,
    )

    /**
     * Select complete daily rows for a portable CSV export.
     *
     * Source lists are ordered by precedence (active device before canonical fallback). The first
     * complete row in each bucket wins that day, then an imported row replaces a computed row as a
     * whole. Deliberately do not use the dashboard's field-wise union here: doing so can copy
     * computed fields into a row labelled "import", which promotes approximate values to official
     * provenance when the CSV is re-imported. This is the Android twin of CsvExport.swift.
     */
    internal fun selectDailyRowsForExport(
        importedBySource: List<List<DailyMetric>>,
        computedBySource: List<List<DailyMetric>>,
    ): List<DailyExportRow> {
        val imported = firstWholeDailyRowByDay(importedBySource)
        val computed = firstWholeDailyRowByDay(computedBySource)
        return (imported.keys + computed.keys).toSortedSet().map { day ->
            imported[day]?.let { DailyExportRow(it, "import") }
                ?: DailyExportRow(computed.getValue(day), "noop (APPROXIMATE)")
        }
    }

    private fun firstWholeDailyRowByDay(
        sources: List<List<DailyMetric>>,
    ): Map<String, DailyMetric> {
        val rows = LinkedHashMap<String, DailyMetric>()
        for (source in sources) {
            for (row in source) rows.putIfAbsent(row.day, row)
        }
        return rows
    }

    // --- Tolerant decoders for the cache's polymorphic JSON columns ---

    internal data class StageMinutes(
        val light: Double?, val deep: Double?, val rem: Double?, val awake: Double?,
    ) {
        /** Asleep = light+deep+rem, but only when at least one is present. */
        val asleep: Double? get() =
            if (light == null && deep == null && rem == null) null
            else (light ?: 0.0) + (deep ?: 0.0) + (rem ?: 0.0)
    }

    /**
     * Stage minutes recovered from any persisted stagesJSON shape NOOP has ever written:
     *   {"light":min,…}            - macOS WHOOP import
     *   [{"stage","min"}]          - Android import / demo seeds
     *   [{"start","end","stage"}]  - the on-device sleep stager ("wake" == awake)
     * Unusable / empty input → all-null, so the column exports blank rather than a bogus zero.
     */
    internal fun stageMinutes(stagesJSON: String?): StageMinutes {
        val none = StageMinutes(null, null, null, null)
        if (stagesJSON.isNullOrBlank()) return none
        return runCatching {
            val t = stagesJSON.trim()
            if (t.startsWith("{")) {
                val o = JSONObject(t)
                fun g(k: String): Double? =
                    if (o.has(k)) o.optDouble(k).takeIf { !it.isNaN() } else null
                StageMinutes(g("light"), g("deep"), g("rem"), g("awake") ?: g("wake"))
            } else if (t.startsWith("[")) {
                val arr = JSONArray(t)
                var l = 0.0; var d = 0.0; var r = 0.0; var a = 0.0; var any = false
                for (i in 0 until arr.length()) {
                    val seg = arr.optJSONObject(i) ?: continue
                    val stage = seg.optString("stage", "").lowercase()
                    val min: Double = if (seg.has("min")) {
                        seg.optDouble("min", 0.0)
                    } else if (seg.has("start") && seg.has("end")) {
                        (seg.optLong("end") - seg.optLong("start")) / 60.0
                    } else {
                        continue
                    }
                    any = true
                    when (stage) {
                        "light" -> l += min
                        "deep", "sws" -> d += min
                        "rem" -> r += min
                        "awake", "wake" -> a += min
                        else -> {}   // unknown stage: counted as nothing
                    }
                }
                if (any) StageMinutes(l, d, r, a) else none
            } else {
                none
            }
        }.getOrDefault(none)
    }

    /**
     * Z1–Z5 percents from zonesJSON. macOS import writes "z1"…"z5"; Android writes "zone1"…"zone5".
     * Self-contained on purpose (own decoder, not the Workouts-screen helper) so the exporter is
     * decoupled from the UI layer. null when there's no usable zone data → the columns export blank.
     */
    internal fun zonePercents(zonesJSON: String?): List<Double>? {
        if (zonesJSON.isNullOrBlank()) return null
        return runCatching {
            val o = JSONObject(zonesJSON.trim())
            val out = MutableList(5) { i ->
                val k1 = "z${i + 1}"; val k2 = "zone${i + 1}"
                when {
                    o.has(k1) -> o.optDouble(k1, 0.0)
                    o.has(k2) -> o.optDouble(k2, 0.0)
                    else -> 0.0
                }
            }
            if (out.any { it > 0.0 }) out else null
        }.getOrNull()
    }

    // --- The four CSVs (headers byte-identical to a real WHOOP export) ---

    /**
     * physiological_cycles.csv. [seriesByDay] is day -> (metricSeries key -> value), carrying the
     * cycles-only columns DailyMetric doesn't store (sleep performance/consistency/need/debt). The
     * Android daily row also lacks energy / avg-HR / max-HR / in-bed, which export blank and
     * re-import as null by design. [sourceByDay] feeds the trailing, parser-ignored Source column.
     */
    internal fun cyclesCsv(
        daily: List<DailyMetric>,
        seriesByDay: Map<String, Map<String, Double>>,
        sourceByDay: Map<String, String> = emptyMap(),
        publishDetailedSleepStages: (DailyMetric) -> Boolean = { true },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle end time,Cycle timezone,Recovery score %,")
            .append("Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),")
            .append("Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),")
            .append("Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),")
            .append("Asleep duration (min),In bed duration (min),Light sleep duration (min),")
            .append("Deep (SWS) duration (min),REM duration (min),Awake duration (min),")
            .append("Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min),")
            .append("HRV method,Source\r\n")
        for (d in daily.sortedBy { it.day }) {
            val s = seriesByDay[d.day].orEmpty()
            val publishStages = publishDetailedSleepStages(d)
            sb.append(
                listOf(
                    d.day + " 00:00:00", "", "UTC+00:00",
                    num(d.recovery), num(d.restingHr), num(d.avgHrv), num(d.skinTempDevC),
                    // Day Strain column is WHOOP's 0–21 scale → down-convert our 0–100 Effort so the CSV
                    // is WHOOP-format and a NOOP→NOOP round-trip is lossless (import scales back ×100/21).
                    // Divide by the SAME 100.0/21.0 constant the importer multiplies by (and that Swift's
                    // whoopDayStrainFromEffort uses) so the byte output matches macOS/iOS exactly.
                    num(d.spo2Pct), num(d.strain?.let { it / (100.0 / 21.0) }),
                    "", "", "",            // energy / max HR / avg HR - not on the Android daily row
                    "", "",                // sleep/wake onset live in sleeps.csv
                    num(s["sleep_performance"]), num(d.respRateBpm), num(d.totalSleepMin),
                    "",                    // in-bed not stored on the Android daily row
                    num(d.lightMin.takeIf { publishStages }),
                    num(d.deepMin.takeIf { publishStages }),
                    num(d.remMin.takeIf { publishStages }),
                    // "Awake duration (min)" is MINUTES - the daily row doesn't carry it, so leave
                    // the cell empty. (Writing the disturbance COUNT here exported a wrong unit
                    // that round-tripped on reimport — PR #97 review, tigercraft4. Swift parity.)
                    "",
                    // "Sleep efficiency %" is WHOOP's 0–100 column → lift the stored 0–1 fraction,
                    // rounded to 4 decimals of a percent so num()'s shortest-round-trip Double
                    // printing can't leak FP dust into the cell. Keep byte-identical to Swift
                    // (WhoopExportImporter.whoopEfficiencyPctFromFraction).
                    num(d.efficiency?.let { round(it * 100.0 * 10_000) / 10_000 }),
                    num(s["sleep_consistency"]), num(s["sleep_need_min"]),
                    num(s["sleep_debt_min"]),
                    csvField(d.avgHrv?.let { DailyHrvMethod.normalized(d.hrvMethod) }),
                    csvField(sourceByDay[d.day]),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /**
     * sleeps.csv. Stage durations from the tolerant decoder; in-bed derived from the span.
     *
     * [cycleStart] returns the "Cycle start time" for a session - the LOCAL day-midnight of the cycle the
     * sleep belongs to (the caller passes `AnalyticsEngine.dayString(endTs, offset) + " 00:00:00"`, the same
     * end-day key analyze/mergeSleep use). It MUST match the corresponding physiological_cycles row's
     * "Cycle start time" so the two CSVs reconcile by cycle; the previous `utc(startTs)` put a non-UTC user's
     * night on a different date than its cycle (#715). Onset/Wake stay the real UTC session times, so the
     * NOOP→NOOP round-trip is unchanged (the importer keys on sleep_onset, not Cycle start time).
     */
    internal fun sleepsCsv(
        sessions: List<SleepSession>,
        cycleStart: (SleepSession) -> String,
        publishDetailedStages: (SleepSession) -> Boolean = { true },
        sourceBySession: (SleepSession) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,")
            .append("Respiratory rate (rpm),Asleep duration (min),In bed duration (min),")
            .append("Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),")
            .append("Awake duration (min),Sleep efficiency %,Sleep consistency %,")
            .append("Sleep need (min),Sleep debt (min),Source\r\n")
        for (s in sessions.sortedBy { it.startTs }) {
            // Publication-only projection: raw stagesJSON remains in Room, native backup, sidecars,
            // and self-hosted sync. Unsupported local detail is decoded as absent for this CSV only.
            val stages = stageMinutes(s.stagesJSON.takeIf { publishDetailedStages(s) })
            val inBedMin = if (s.endTs > s.startTs) (s.endTs - s.startTs) / 60.0 else null
            sb.append(
                listOf(
                    cycleStart(s), utc(s.startTs), utc(s.endTs), "UTC+00:00",
                    // NOOP never stores a nap flag — everything exports as a main sleep so the
                    // importer keeps it (it drops nap rows).
                    "false", "", "",
                    num(stages.asleep), num(inBedMin),
                    num(stages.light), num(stages.deep), num(stages.rem), num(stages.awake),
                    num(s.efficiency?.let { round(it * 100.0 * 10_000) / 10_000 }), "", "", "",
                    csvField(sourceBySession(s)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** workouts.csv. [sourceLabel] classifies each row for the trailing Source column. */
    internal fun workoutsCsv(
        rows: List<WorkoutRow>,
        sourceLabel: (WorkoutRow) -> String = { "" },
    ): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Workout start time,Workout end time,Cycle timezone,")
            .append("Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),")
            .append("Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,")
            .append("HR Zone 5 %,Distance (meters),Source\r\n")
        for (w in rows.sortedBy { it.startTs }) {
            val zones = zonePercents(w.zonesJSON)
            sb.append(
                listOf(
                    utc(w.startTs), utc(w.startTs), utc(w.endTs), "UTC+00:00",
                    csvField(w.sport), num(w.strain?.let { it / (100.0 / 21.0) }), num(w.energyKcal), num(w.maxHr), num(w.avgHr),
                    num(zones?.get(0)), num(zones?.get(1)), num(zones?.get(2)),
                    num(zones?.get(3)), num(zones?.get(4)),
                    num(w.distanceM), csvField(sourceLabel(w)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** journal_entries.csv. The importer reads the answer as a yes/no parse where "true" → true,
     *  so the answer column MUST be the literal "true"/"false" - never prettify it to Yes/No. */
    internal fun journalCsv(rows: List<JournalEntry>): String {
        val sb = StringBuilder()
        sb.append("Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes\r\n")
        for (e in rows.sortedWith(compareBy({ it.day }, { it.question }))) {
            sb.append(
                listOf(
                    e.day + " 00:00:00", "UTC+00:00", csvField(e.question),
                    if (e.answeredYes) "true" else "false",
                    csvField(e.notes),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    /** Full-fidelity metricSeries dump ({deviceId, day, key, value}). Sidecar only — the importers
     *  deliberately ignore it (they read only the four CSVs). Sorted for a stable, diffable file. */
    internal fun metricSeriesJson(rows: List<MetricSeriesRow>): String {
        val arr = JSONArray()
        for (r in rows.sortedWith(compareBy({ it.deviceId }, { it.day }, { it.key }))) {
            arr.put(
                JSONObject()
                    .put("deviceId", r.deviceId)
                    .put("day", r.day)
                    .put("key", r.key)
                    .put("value", r.value),
            )
        }
        return arr.toString(2)
    }

    // --- Parallel-wear comparison sidecars ---

    internal enum class ComparisonSource(val wireValue: String) {
        WEARABLE_IMPORT("wearable_import"),
        NOOP_COMPUTED("noop_computed"),
        NOOP_MANUAL("noop_manual"),
    }

    internal data class ComparisonContext(
        val generatedAtUtc: String,
        val platform: String,
        val appVersion: String,
    )

    internal data class ComparisonDailyRow(
        val source: ComparisonSource,
        val metric: DailyMetric,
        val publishDetailedStages: Boolean,
    )

    internal data class ComparisonSleepRow(
        val source: ComparisonSource,
        val session: SleepSession,
        val publishDetailedStages: Boolean,
    )

    internal data class ComparisonWorkoutRow(
        val source: ComparisonSource,
        val workout: WorkoutRow,
    )

    internal data class ComparisonMetricRow(
        val source: ComparisonSource,
        val day: String,
        val key: String,
        val value: Double,
    )

    /**
     * Source-separated, identifier-free study files carried inside every portable export. NOOP's
     * importer ignores this directory, so the existing cross-platform restore contract is unchanged.
     */
    internal fun comparisonEntries(
        context: ComparisonContext,
        daily: List<ComparisonDailyRow>,
        sleeps: List<ComparisonSleepRow>,
        workouts: List<ComparisonWorkoutRow>,
        metricSeries: List<ComparisonMetricRow>,
        detectorDecisions: List<AutoWorkoutPrefs.DecisionRecord> = emptyList(),
    ): LinkedHashMap<String, ByteArray> {
        val files = JSONObject()
            .put("comparison/daily_metrics.csv", daily.size)
            .put("comparison/sleep_sessions.csv", sleeps.size)
            .put("comparison/workouts.csv", workouts.size)
            .put("comparison/metric_series.csv", metricSeries.size)
            .put("comparison/detector_decisions.csv", detectorDecisions.size)
        val manifest = JSONObject()
            .put("schema", "noop.parallel_wear.v1")
            .put("generated_at_utc", context.generatedAtUtc)
            .put("platform", context.platform)
            .put("app_version", context.appVersion)
            .put("contains_device_identifiers", false)
            .put("missing_value_encoding", "blank CSV field")
            .put("timestamp_encoding", "UTC ISO-8601")
            .put("day_encoding", "stored local calendar day (YYYY-MM-DD)")
            .put(
                "sources",
                JSONObject()
                    .put(
                        ComparisonSource.WEARABLE_IMPORT.wireValue,
                        "Values parsed from a user-supplied wearable export.",
                    )
                    .put(
                        ComparisonSource.NOOP_COMPUTED.wireValue,
                        "Values estimated locally by NOOP from recorded sensor data.",
                    )
                    .put(
                        ComparisonSource.NOOP_MANUAL.wireValue,
                        "Values explicitly entered or confirmed by the user in NOOP.",
                    ),
            )
            .put(
                "score_scales",
                JSONObject()
                    .put("recovery_score", "0-100")
                    .put("effort_score", "0-100")
                    .put("sleep_score", "0-100")
                    .put("sleep_efficiency", "fraction 0-1"),
            )
            .put(
                "algorithm_revisions",
                JSONObject()
                    .put("charge", RemoteNoopAlgorithmRevision.CHARGE)
                    .put("effort", RemoteNoopAlgorithmRevision.EFFORT)
                    .put("rest", RemoteNoopAlgorithmRevision.REST)
                    .put("auto_workout_detector", AutoWorkoutDetector.detectorVersion),
            )
            .put("detector_decisions_schema", "noop.detector_decisions.v1")
            .put("files", files)
        val detector = JSONObject()
            .put("detector_version", AutoWorkoutDetector.detectorVersion)
            .put("event_confidence_status", "uncalibrated")
            .put("unattended_save_permitted", false)
            .put(
                "decision_history",
                JSONObject()
                    .put("schema", "noop.detector_decisions.v1")
                    .put(
                        "maximum_persisted_records",
                        AutoWorkoutPrefs.DECISION_HISTORY_MAX,
                    )
                    .put("computed_workout_rows_imply_acceptance", false)
                    .put("legacy_tombstones_have_unknown_fields", true),
            )
            .put(
                "evidence",
                JSONObject()
                    .put("heart_rate", "required")
                    .put(
                        "motion",
                        "Dense motion confirms or rejects; sparse or absent motion falls back to heart-rate-only.",
                    )
                    .put(
                        "workout_type",
                        "Advisory broad class only; the user confirms the saved activity.",
                    ),
            )
            .put(
                "rules",
                JSONObject()
                    .put("elevated_margin_bpm", AutoWorkoutDetector.elevatedMarginBPM)
                    .put("minimum_sustained_minutes", AutoWorkoutDetector.minSustainedMin)
                    .put("maximum_dip_seconds", AutoWorkoutDetector.maxDipS)
                    .put("merge_gap_seconds", AutoWorkoutDetector.mergeGapS)
                    .put("minimum_hr_samples", AutoWorkoutDetector.minHRSamples)
                    .put("maximum_hr_sample_gap_seconds", AutoWorkoutDetector.maxHRSampleGapS)
                    .put(
                        "maximum_seconds_per_hr_sample",
                        AutoWorkoutDetector.maxSecondsPerHRSample,
                    )
                    .put("motion_confirmation_mean", AutoWorkoutDetector.motionConfirmMean)
                    .put(
                        "motion_confirmation_minimum_samples",
                        AutoWorkoutDetector.motionConfirmationMinSamples,
                    )
                    .put(
                        "motion_confirmation_maximum_gap_seconds",
                        AutoWorkoutDetector.motionConfirmationMaxGapS,
                    ),
            )
        val readme = """
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
        """.trimIndent() + "\n"

        return linkedMapOf(
            "comparison/README.txt" to readme.toByteArray(),
            "comparison/manifest.json" to manifest.toString(2).toByteArray(),
            "comparison/daily_metrics.csv" to comparisonDailyCsv(daily).toByteArray(),
            "comparison/sleep_sessions.csv" to comparisonSleepCsv(sleeps).toByteArray(),
            "comparison/workouts.csv" to comparisonWorkoutCsv(workouts).toByteArray(),
            "comparison/metric_series.csv" to comparisonMetricSeriesCsv(metricSeries).toByteArray(),
            "comparison/detector_decisions.csv" to
                comparisonDetectorDecisionsCsv(detectorDecisions).toByteArray(),
            "comparison/workout_detector.json" to detector.toString(2).toByteArray(),
        )
    }

    private fun comparisonDailyCsv(rows: List<ComparisonDailyRow>): String {
        val sb = StringBuilder()
        sb.append("source,day,recovery_score_0_100,effort_score_0_100,total_sleep_min,")
            .append("sleep_efficiency_fraction,light_sleep_min,deep_sleep_min,rem_sleep_min,")
            .append("disturbances_count,resting_hr_bpm,hrv_ms,hrv_method,spo2_pct,")
            .append("skin_temperature_value_c,skin_temperature_semantics,respiratory_rate_per_min,")
            .append("steps_count,energy_kcal,raw_spo2_red_adc,raw_spo2_ir_adc,")
            .append("detailed_sleep_stages_status\r\n")
        for (row in rows.sortedWith(compareBy({ it.source.wireValue }, { it.metric.day }))) {
            val d = row.metric
            val hasStages = d.lightMin != null || d.deepMin != null || d.remMin != null
            val stageStatus = if (!row.publishDetailedStages) {
                "withheld_insufficient_evidence"
            } else if (hasStages) {
                "available"
            } else {
                "not_recorded"
            }
            val skinSemantics = when {
                d.skinTempDevC == null -> ""
                row.source == ComparisonSource.WEARABLE_IMPORT -> "absolute_temperature"
                else -> "deviation_from_personal_baseline"
            }
            sb.append(
                listOf(
                    row.source.wireValue,
                    d.day,
                    num(d.recovery),
                    num(d.strain),
                    num(d.totalSleepMin),
                    num(d.efficiency),
                    num(d.lightMin.takeIf { row.publishDetailedStages }),
                    num(d.deepMin.takeIf { row.publishDetailedStages }),
                    num(d.remMin.takeIf { row.publishDetailedStages }),
                    num(d.disturbances),
                    num(d.restingHr),
                    num(d.avgHrv),
                    csvField(d.avgHrv?.let { DailyHrvMethod.normalized(d.hrvMethod) }),
                    num(d.spo2Pct),
                    num(d.skinTempDevC),
                    skinSemantics,
                    num(d.respRateBpm),
                    num(d.steps),
                    num(d.activeKcalEst),
                    num(d.spo2Red),
                    num(d.spo2Ir),
                    stageStatus,
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    private fun comparisonSleepCsv(rows: List<ComparisonSleepRow>): String {
        val sb = StringBuilder()
        sb.append("source,session_start_utc,session_end_utc,duration_s,sleep_efficiency_fraction,")
            .append("resting_hr_bpm,hrv_ms,light_sleep_min,deep_sleep_min,rem_sleep_min,awake_min,")
            .append("user_edited,rr_eligible_window_count,rr_valid_window_count,")
            .append("detailed_sleep_stages_status\r\n")
        for (row in rows.sortedWith(compareBy({ it.source.wireValue }, { it.session.effectiveStartTs }))) {
            val s = row.session
            val stages = stageMinutes(s.stagesJSON.takeIf { row.publishDetailedStages })
            val hasStages = listOf(stages.light, stages.deep, stages.rem, stages.awake).any { it != null }
            val stageStatus = if (!row.publishDetailedStages) {
                "withheld_insufficient_evidence"
            } else if (hasStages) {
                "available"
            } else {
                "not_recorded"
            }
            val duration = (s.endTs - s.effectiveStartTs).takeIf { it > 0 }?.toDouble()
            sb.append(
                listOf(
                    row.source.wireValue,
                    comparisonUtc(s.effectiveStartTs),
                    comparisonUtc(s.endTs),
                    num(duration),
                    num(s.efficiency),
                    num(s.restingHr),
                    num(s.avgHrv),
                    num(stages.light),
                    num(stages.deep),
                    num(stages.rem),
                    num(stages.awake),
                    s.userEdited.toString(),
                    num(s.rrEligibleWindowCount),
                    num(s.rrValidWindowCount),
                    stageStatus,
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    private fun comparisonWorkoutCsv(rows: List<ComparisonWorkoutRow>): String {
        val sb = StringBuilder()
        sb.append("source,workout_start_utc,workout_end_utc,duration_s,activity_name,")
            .append("effort_score_0_100,energy_kcal,average_hr_bpm,max_hr_bpm,distance_m,")
            .append("steps_count,hr_zone_1_pct,hr_zone_2_pct,hr_zone_3_pct,hr_zone_4_pct,")
            .append("hr_zone_5_pct\r\n")
        for (row in rows.sortedWith(compareBy({ it.source.wireValue }, { it.workout.startTs }))) {
            val w = row.workout
            val duration = w.durationS ?: (w.endTs - w.startTs).takeIf { it > 0 }?.toDouble()
            val zones = zonePercents(w.zonesJSON)
            sb.append(
                listOf(
                    row.source.wireValue,
                    comparisonUtc(w.startTs),
                    comparisonUtc(w.endTs),
                    num(duration),
                    csvField(w.sport),
                    num(w.strain),
                    num(w.energyKcal),
                    num(w.avgHr),
                    num(w.maxHr),
                    num(w.distanceM),
                    num(w.steps),
                    num(zones?.get(0)),
                    num(zones?.get(1)),
                    num(zones?.get(2)),
                    num(zones?.get(3)),
                    num(zones?.get(4)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    private fun comparisonMetricSeriesCsv(rows: List<ComparisonMetricRow>): String {
        val sb = StringBuilder("source,day,metric_key,value,unit\r\n")
        for (row in rows.filter { it.value.isFinite() }.sortedWith(
            compareBy({ it.source.wireValue }, { it.day }, { it.key }),
        )) {
            sb.append(
                listOf(
                    row.source.wireValue,
                    row.day,
                    csvField(row.key),
                    num(row.value),
                    csvField(comparisonUnit(row.key, row.source)),
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    private fun comparisonDetectorDecisionsCsv(
        rows: List<AutoWorkoutPrefs.DecisionRecord>,
    ): String {
        val sb = StringBuilder()
        sb.append("candidate_start_utc,candidate_end_utc,decision_recorded_utc,action,actor,")
            .append("activity_name,detector_version,average_hr_bpm,peak_hr_bpm,")
            .append("event_confidence_0_1,type_hint_class,type_hint_confidence_0_1,")
            .append("confidence_status,evidence_provenance,record_origin\r\n")
        for (row in rows.sortedWith(
            compareBy(
                { it.candidateStartSec },
                { it.recordedAtSec ?: Long.MIN_VALUE },
                { it.action.wireValue },
            ),
        )) {
            sb.append(
                listOf(
                    comparisonUtc(row.candidateStartSec),
                    row.candidateEndSec?.let(::comparisonUtc).orEmpty(),
                    row.recordedAtSec?.let(::comparisonUtc).orEmpty(),
                    row.action.wireValue,
                    row.actor.wireValue,
                    csvField(row.activityName),
                    csvField(row.detectorVersion),
                    num(row.averageBpm),
                    num(row.peakBpm),
                    num(row.eventConfidence),
                    csvField(row.suggestedClass),
                    num(row.suggestionConfidence),
                    csvField(row.confidenceStatus),
                    csvField(row.evidenceProvenance),
                    row.origin,
                ).joinToString(","),
            ).append("\r\n")
        }
        return sb.toString()
    }

    private fun comparisonUnit(key: String, source: ComparisonSource): String = when {
        key in setOf("recovery", "strain", "sleep_performance") -> "score_0_100"
        key == "sleep_efficiency" -> "fraction_0_1"
        key in setOf(
            "sleep_consistency",
            "hours_vs_needed_pct",
            "restorative_pct",
            "spo2",
            "body_fat",
        ) -> "percent_0_100"
        key in setOf("avg_hr", "max_hr", "rhr") -> "bpm"
        key == "hrv" -> "ms"
        key == "resp_rate" -> "breaths_per_min"
        key == "skin_temp" && source == ComparisonSource.WEARABLE_IMPORT -> "celsius_absolute"
        key == "skin_temp" -> "celsius_delta_from_baseline"
        key.endsWith("_min") -> "min"
        key in setOf("energy_kcal", "active_kcal", "basal_kcal", "total_kcal", "calories_in") -> "kcal"
        key in setOf("steps", "steps_est", "disturbances", "exercise_count") -> "count"
        key == "distance_m" -> "m"
        key in setOf("weight", "lean_mass") -> "kg"
        key == "height" -> "cm"
        key in setOf("vo2max", "vo2max_est") -> "mL_per_kg_per_min"
        key in setOf("fitness_age", "body_age") -> "decimal_years"
        key == "mood" -> "score_1_5"
        key == "stress" -> "score_0_3"
        key == "rest_evidence_flags" -> "bitmask"
        key in setOf("spo2_red", "spo2_ir") -> "adc"
        else -> "unspecified"
    }

    private fun comparisonUtc(epochSeconds: Long): String =
        java.time.format.DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(epochSeconds))

    /** Zip the named entries into a single byte array (everything is already in memory). */
    internal fun zipBytes(entries: Map<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            for ((name, bytes) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    /**
     * UI entry point: serialize the merged WHOOP history (imported wins per day — exactly what the
     * dashboards show; Apple Health / Health Connect rows are deliberately EXCLUDED so a re-import
     * can't mis-attribute them as WHOOP data) and write a zip to [uri]. Returns a human summary for
     * the toast.
     *
     * [deviceId] is the registry's ACTIVE strap id (SPINE / #814) and has NO default on purpose
     * (#458): the old `= "my-whoop"` default meant a live-BLE install - whose engine banks computed
     * scores under `"<strapId>-noop"` - exported `0 days, 0 sleeps, 0 journal entries` while the app
     * displayed months of history. It survived the #359 sweep because that grep targeted the
     * hardcoded `"my-whoop-noop"` string, not default parameters. Every read below goes through the
     * active∪canonical union resolvers ([WhoopRepository.importedSourceIds] /
     * [WhoopRepository.computedSourceIds]), so BOTH install shapes export in full: live-BLE rows
     * under the strap id AND canonical `"my-whoop"` rows from a prior CSV import (a single-canonical
     * install collapses to one id, byte-identical to before).
     */
    suspend fun exportZip(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String,
    ): String {
        val hi = System.currentTimeMillis() / 1000 + 86_400
        // The active∪canonical union ids (#458): active strap FIRST, so a per-row dedup keeps the
        // live/measured copy; a single-canonical install collapses to one id each.
        val importedIds = repo.importedSourceIds(deviceId)
        val computedIds = repo.computedSourceIds(deviceId)
        val publishedStageMinutesBySource = computedIds.associateWith { source ->
            repo.detailedSleepStageMinutes(
                source,
                "0000-01-01",
                "9999-12-31",
            )
        }

        // Daily export uses whole source rows, matching Apple. Dashboard reads intentionally
        // coalesce fields for presentation; exporting that hybrid and labelling it "import" would
        // turn computed fields into official values on re-import.
        val importedDailySources = importedIds.map { repo.days(it) }
        val computedDailySources = computedIds.map { repo.days(it) }
        val selectedDaily = selectDailyRowsForExport(
            importedBySource = importedDailySources,
            computedBySource = computedDailySources,
        ).map { row ->
            val minutes = publishedStageMinutesBySource[row.metric.deviceId]?.get(row.metric.day)
            if (!row.metric.deviceId.endsWith("-noop") || minutes == null) {
                row
            } else {
                row.copy(
                    metric = row.metric.copy(
                        deepMin = minutes.deep,
                        remMin = minutes.rem,
                        lightMin = minutes.light,
                    ),
                )
            }
        }
        val daily = selectedDaily.map(DailyExportRow::metric)
        val sourceByDay = selectedDaily.associate { it.metric.day to it.source }
        val publishStagesByDay = selectedDaily.associate { row ->
            row.metric.day to (
                !row.metric.deviceId.endsWith("-noop") ||
                    publishedStageMinutesBySource[row.metric.deviceId]?.containsKey(row.metric.day) == true
                )
        }
        val comparisonDaily = firstWholeDailyRowByDay(importedDailySources).values.map {
            ComparisonDailyRow(
                source = ComparisonSource.WEARABLE_IMPORT,
                metric = it,
                publishDetailedStages = true,
            )
        } + firstWholeDailyRowByDay(computedDailySources).values.map { metric ->
            val minutes = publishedStageMinutesBySource[metric.deviceId]?.get(metric.day)
            ComparisonDailyRow(
                source = ComparisonSource.NOOP_COMPUTED,
                metric = metric.copy(
                    deepMin = minutes?.deep,
                    remMin = minutes?.rem,
                    lightMin = minutes?.light,
                ),
                publishDetailedStages = minutes != null,
            )
        }

        val sleeps = repo.sleepSessionsMerged(deviceId, 0L, hi)
        val wakeDayBySession = WhoopRepository.wakeDayBySession(sleeps)
        val habitualMidsleepSec = repo.habitualMidsleepSec(deviceId)
        val publishableLocalSleepSessions = WhoopRepository.projectPublishableDetailedStages(
            sessions = sleeps,
            habitualMidsleepSec = habitualMidsleepSec,
        ).authorizedSessionKeys
        val importedComparisonSleeps = importedIds
            .flatMap { repo.sleepSessions(it, 0L, hi, 100_000) }
            .distinctBy { it.startTs to it.endTs }
        val computedComparisonSleeps = computedIds
            .flatMap { repo.sleepSessions(it, 0L, hi, 100_000) }
            .distinctBy { it.startTs to it.endTs }
        val comparisonPublishableSleepSessions =
            WhoopRepository.projectPublishableDetailedStages(
                sessions = computedComparisonSleeps,
                habitualMidsleepSec = habitualMidsleepSec,
            ).authorizedSessionKeys
        val comparisonSleeps = importedComparisonSleeps.map {
            ComparisonSleepRow(
                source = ComparisonSource.WEARABLE_IMPORT,
                session = it,
                publishDetailedStages = true,
            )
        } + computedComparisonSleeps.map {
            ComparisonSleepRow(
                source = ComparisonSource.NOOP_COMPUTED,
                session = it,
                publishDetailedStages =
                    com.noop.analytics.DetailedSleepStagePublication.key(it) in
                        comparisonPublishableSleepSessions,
            )
        }
        // Workouts: imported WHOOP ∪ on-device detected (which carries the "-noop" device id), each
        // side read across its union ids (#458). Apple Health / Health Connect workouts are
        // intentionally omitted, matching the cycles/sleep cut. Dedup by (startTs, sport), imported
        // first so it wins — the same session can exist under both sides (e.g. a reimported export +
        // BLE re-detection), which double-counted it in the CSV and inflated totals on reimport.
        // (PR #97 review, tigercraft4. Swift parity.)
        val seenWorkouts = HashSet<String>()
        val importedWorkouts = repo.workoutsUnion(deviceId, 0L, hi)
        val computedWorkouts = repo.detectedWorkoutsUnion(deviceId, 0L, hi)
        val workouts = (importedWorkouts + computedWorkouts)
            .filter { seenWorkouts.add("${it.startTs}|${it.sport}") }
        val comparisonWorkouts = importedWorkouts.map {
            ComparisonWorkoutRow(
                source = if (it.source == "manual") {
                    ComparisonSource.NOOP_MANUAL
                } else {
                    ComparisonSource.WEARABLE_IMPORT
                },
                workout = it,
            )
        } + computedWorkouts.map {
            ComparisonWorkoutRow(ComparisonSource.NOOP_COMPUTED, it)
        }
        // Journal lives under the imported ids. Native in-app journal logging (a separate feature on
        // its own device id) isn't read here, keeping the exporter self-contained; the imported
        // journal is the WHOOP-sourced history the round-trip targets. Dedup by the row's natural key
        // (day, question), active-first.
        val seenJournal = HashSet<String>()
        val journal = importedIds.flatMap { repo.journal(it, "0000-01-01", "9999-12-31") }
            .filter { seenJournal.add("${it.day}|${it.question}") }

        // Cycles columns recovered from the imported metricSeries: per (day, key) the FIRST union id
        // that has a value wins (active strap first), mirroring the read-side precedence.
        val seriesByDay = HashMap<String, MutableMap<String, Double>>()
        for (key in listOf("sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min")) {
            for (id in importedIds) {
                for (p in repo.metricSeries(id, key, "0000-01-01", "9999-12-31")) {
                    val row = seriesByDay.getOrPut(p.day) { HashMap() }
                    if (key !in row) row[key] = p.value
                }
            }
        }
        // Sidecar: every metricSeries row under every NOOP source id, full fidelity (rows carry their
        // own deviceId, so union duplicates stay distinguishable on re-import).
        val sidecarRows = ArrayList<MetricSeriesRow>()
        val comparisonMetricRows = ArrayList<ComparisonMetricRow>()
        val seenComparisonMetrics = HashSet<String>()
        for ((source, ids) in listOf(
            ComparisonSource.WEARABLE_IMPORT to importedIds,
            ComparisonSource.NOOP_COMPUTED to computedIds,
        )) {
            for (id in ids) {
                for (key in repo.metricKeys(id)) {
                    val rows = repo.metricSeriesForPortablePayload(
                        id,
                        key,
                        "0000-01-01",
                        "9999-12-31",
                    )
                    sidecarRows.addAll(rows)
                    for (row in rows) {
                        val identity = "${source.wireValue}|${row.day}|${row.key}"
                        if (seenComparisonMetrics.add(identity)) {
                            comparisonMetricRows += ComparisonMetricRow(
                                source = source,
                                day = row.day,
                                key = row.key,
                                value = row.value,
                            )
                        }
                    }
                }
            }
        }
        val nutritionEntries = repo.nutritionEntries("0000-01-01", "9999-12-31")
        val nutritionCatalogItems = repo.nutritionCatalogItems(
            savedOnly = false,
            limit = 500_000,
        )
        val strengthExercises = repo.strengthExercises(includeArchived = true)
        val strengthRoutines = repo.strengthRoutines(includeArchived = true)
        val strengthSessions = repo.strengthSessions(includeInProgress = true)
        val portable = PortableUserDataCodec.encode(
            PortableUserData(
                exportedAt = System.currentTimeMillis() / 1_000L,
                nutritionEntries = nutritionEntries,
                nutritionCatalogItems = nutritionCatalogItems,
                strengthExercises = strengthExercises.map(::PortableStrengthExercise),
                strengthRoutines = strengthRoutines.map { it.routine },
                strengthRoutineExercises = strengthRoutines.flatMap { it.exercises },
                strengthSessions = strengthSessions.map { it.session },
                strengthSets = strengthSessions.flatMap { it.sets },
            ),
        )

        // Classify a workout for the parser-ignored Source column. The on-device detected workouts
        // carry the "-noop" device id; manual logging uses source "manual"; everything else is an
        // imported WHOOP row.
        fun workoutSource(w: WorkoutRow): String = when {
            w.deviceId.endsWith("-noop") -> "noop (APPROXIMATE)"
            w.source == "manual" -> "manual"
            else -> "import"
        }

        val archiveEntries = linkedMapOf(
                "physiological_cycles.csv" to cyclesCsv(
                    daily,
                    seriesByDay,
                    sourceByDay,
                    publishDetailedSleepStages = {
                        publishStagesByDay[it.day] == true
                    },
                ).toByteArray(),
                "sleeps.csv" to sleepsCsv(
                    sleeps,
                    cycleStart = {
                        val day = wakeDayBySession[it.deviceId to it.startTs] ?: run {
                            val wakeOffsetSec =
                                WhoopRepository.historicalOffsetSeconds(it.endTs)
                            com.noop.analytics.AnalyticsEngine.dayString(
                                it.endTs,
                                wakeOffsetSec,
                            )
                        }
                        "$day 00:00:00"
                    },
                    publishDetailedStages = { session ->
                        !session.deviceId.endsWith("-noop") ||
                            com.noop.analytics.DetailedSleepStagePublication.key(session) in
                            publishableLocalSleepSessions
                    },
                    sourceBySession = { session ->
                        if (session.deviceId.endsWith("-noop")) {
                            "noop (APPROXIMATE)"
                        } else {
                            "import"
                        }
                    },
                ).toByteArray(),
                "workouts.csv" to workoutsCsv(workouts, ::workoutSource).toByteArray(),
                "journal_entries.csv" to journalCsv(journal).toByteArray(),
                "noop_metric_series.json" to metricSeriesJson(sidecarRows).toByteArray(),
                PortableUserDataCodec.FILE_NAME to portable,
        )
        val appVersion = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "unknown"
        archiveEntries.putAll(
            comparisonEntries(
                context = ComparisonContext(
                    generatedAtUtc = Instant.now().toString(),
                    platform = "Android",
                    appVersion = appVersion,
                ),
                daily = comparisonDaily,
                sleeps = comparisonSleeps,
                workouts = comparisonWorkouts,
                metricSeries = comparisonMetricRows,
                detectorDecisions = AutoWorkoutPrefs.exportDecisionRecords(context),
            ),
        )
        val zip = zipBytes(archiveEntries)
        context.contentResolver.openOutputStream(uri)?.use { it.write(zip); it.flush() }
            ?: throw IOException("Could not open the chosen file for writing.")
        return "Exported ${daily.size} days, ${sleeps.size} sleeps, ${workouts.size} workouts, " +
            "${journal.size} journal entries, ${nutritionEntries.size} nutrition entries, and " +
            "${strengthSessions.size} strength sessions. Comparison-ready source files are included."
    }
}
