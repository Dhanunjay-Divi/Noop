package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.DailyHrvMethod
import com.noop.data.DailyMetric
import com.noop.data.ImportSummary
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.PortableUserData
import com.noop.data.PortableUserDataCodec
import com.noop.data.PortableUserDataImportSummary
import com.noop.data.SleepEfficiencyUnits
import com.noop.data.SleepSession
import com.noop.data.WhoopCsvDayRange
import com.noop.data.WhoopCsvDeviceRegistration
import com.noop.data.WhoopCsvImportBatch
import com.noop.data.WhoopCsvJournalReplacement
import com.noop.data.WhoopCsvMetricSeriesReplacement
import com.noop.data.WhoopCsvTimestampRange
import com.noop.data.WHOOP_CSV_IMPORTED_WORKOUT_SOURCE
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.ZipInputStream
import kotlin.math.roundToInt

/**
 * Imports a WHOOP CSV export (the four-CSV bundle, zipped or loose) plus NOOP's optional versioned
 * user-data sidecar into the local Room store.
 *
 * This is the Android port of the macOS source of truth
 * `Packages/StrandImport/Sources/StrandImport/WhoopExportImporter.swift`
 * (with `CSVParsing.swift` ported in [CsvParser.kt]). The CSV column mapping is reproduced
 * faithfully: same columns -> same fields, same header normalization + aliases, same
 * timezone-aware date parsing, same "(cal)" == kcal unit handling, same row-skip rules.
 *
 * Differences are only in the SINK: the Swift importer returns normalized model arrays;
 * here we map those same rows onto the verified Room entities (com.noop.data) and upsert
 * through [WhoopRepository]. Official/blank-source rows are written under "my-whoop"; rows marked
 * as NOOP-local are routed to "my-whoop-noop", and unknown producer labels are quarantined.
 *
 * Recognised filenames (case-insensitive, matched anywhere in a zip tree, exactly as Swift):
 *   physiological_cycles.csv  -> DailyMetric  (master daily summary)
 *   sleeps.csv                -> SleepSession + folds sleep fields into DailyMetric
 *   workouts.csv              -> WorkoutRow(source = "my-whoop")
 *   journal_entries.csv       -> JournalEntry
 *
 * The whole pipeline is tolerant: missing files / columns / blank cells degrade gracefully.
 */
object WhoopCsvImporter {

    private const val WHOOP_DEVICE = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE
    private const val SOURCE_LABEL = "Wearable export"

    private const val CYCLES_NAME = "physiological_cycles.csv"
    private const val SLEEPS_NAME = "sleeps.csv"
    private const val WORKOUTS_NAME = "workouts.csv"
    private const val JOURNAL_NAME = "journal_entries.csv"

    private val CYCLE_SERIES_KEYS = setOf(
        "recovery", "strain", "rhr", "hrv", "spo2", "skin_temp", "resp_rate",
        "energy_kcal", "avg_hr", "max_hr", "sleep_total_min", "in_bed_min",
        "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "awake_min",
        "sleep_efficiency", "sleep_performance", "sleep_consistency", "sleep_need_min",
        "sleep_debt_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct",
        // Legacy importer output. Current imports intentionally write no stress proxy.
        "stress",
    )
    private val WORKOUT_SERIES_KEYS = setOf(
        "hr_zone1_min", "hr_zone2_min", "hr_zone3_min", "hr_zone4_min", "hr_zone5_min",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min",
    )

    /**
     * A genuine WHOOP export has no Source column. NOOP exports append one so a round-trip can keep
     * local approximations out of the official-reference namespace. Unknown producers are dropped
     * rather than silently treated as WHOOP ground truth.
     */
    internal enum class RowProvenance {
        OfficialReference,
        NoopApproximate,
        NoopLocal,
        Unknown,
    }

    internal fun classifySourceLabel(sourceLabel: String?): RowProvenance {
        val normalized = sourceLabel?.trim()?.lowercase().orEmpty()
        if (normalized.isEmpty() || normalized == "import" || normalized == "whoop") {
            return RowProvenance.OfficialReference
        }
        if (normalized == "noop (approximate)") return RowProvenance.NoopApproximate
        if (normalized == "manual") return RowProvenance.NoopLocal
        return RowProvenance.Unknown
    }

    internal fun rowsForProvenance(
        table: CsvTable,
        vararg accepted: RowProvenance,
    ): CsvTable {
        val allowed = accepted.toSet()
        return table.filterRows { row -> classifySourceLabel(row.cell("source")) in allowed }
    }

    /** Per-CSV uncompressed ceiling (zip-bomb guard). Mirrors Swift maxEntryBytes = 256 MB. */
    private const val MAX_ENTRY_BYTES = 256L shl 20

    /** Aggregate RAM ceiling across ALL retained CSVs from one import. The per-entry cap bounds a single
     *  file but NOT the sum of the retained set — this backstops a crafted export from accumulating
     *  unbounded ByteArray in the map before parsing. A real WHOOP bundle is a few MB, so 1 GB never trips
     *  in practice. Mirrors the Swift WhoopExportImporter.maxTotalBytes (#70). */
    internal const val MAX_TOTAL_BYTES = 1L shl 30

    /**
     * Charge/Effort/Rest redesign (2026-06-12): WHOOP "Day Strain" is on WHOOP's 0–21 scale, but
     * NOOP's "Effort" score lives on 0–100 (StrainScorer.maxStrain = 100). Rescale an imported Day
     * Strain by 100/21 when writing the `strain` metric so imported history sits on the same axis as
     * live-computed Effort. Keep byte-identical to Swift
     * (WhoopExportImporter.dayStrainToEffortScale).
     */
    private const val DAY_STRAIN_TO_EFFORT_SCALE = 100.0 / 21.0

    /**
     * WHOOP CSVs carry "Sleep efficiency %" on a 0–100 scale, but NOOP's `efficiency` columns store
     * the 0–1 fraction the native pipeline writes (AnalyticsEngine: actual-sleep ÷ in-bed). Divide at
     * the WRITE boundary — the verbatim parsed value stays untouched, same shape as the Day Strain
     * rescale above. Keep byte-identical to Swift (WhoopExportImporter.fractionFromImportedEfficiencyPct).
     */
    private fun efficiencyFractionFromPct(pct: Double?): Double? =
        SleepEfficiencyUnits.fractionFromPercent(pct)

    private fun effortFromImportedStrain(strain: Double?): Double? {
        val effort = strain?.times(DAY_STRAIN_TO_EFFORT_SCALE) ?: return null
        return effort.takeIf(Double::isFinite)
    }

    private fun roundedIntOrNull(value: Double?): Int? {
        if (value == null || !value.isFinite() ||
            value < Int.MIN_VALUE.toDouble() || value > Int.MAX_VALUE.toDouble()
        ) {
            return null
        }
        return value.roundToInt()
    }

    private fun derivedSleepEnd(startTs: Long, durationMin: Double?): Long {
        val seconds = durationMin?.times(60.0) ?: return startTs
        if (!seconds.isFinite() || seconds <= 0.0 ||
            seconds > Long.MAX_VALUE.toDouble() ||
            startTs > Long.MAX_VALUE - seconds.toLong()
        ) {
            return startTs
        }
        return startTs + seconds.toLong()
    }

    private val DAY_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    /**
     * Public entry point the UI calls.
     *
     * Accepts either a `.zip` containing the WHOOP CSVs, or a single `.csv` (routed by
     * its filename, falling back to header sniffing when the name is unrecognised).
     * Reads the SAF [uri] via the content resolver. Upserts everything via [repo] under
     * [deviceId] (defaults to "my-whoop"), provenance-routes any NOOP-local rows to its `-noop`
     * sibling, then returns an [ImportSummary] keyed by table.
     */
    suspend fun importZip(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = WHOOP_DEVICE,
    ): ImportSummary {
        val loaded = try {
            loadCsvData(context, uri)
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read export: ${e.message ?: "unknown error"}")
        }
        val csvData = loaded.csvData
        val truncated = loaded.truncated
        val portable: PortableUserData? = try {
            loaded.portableData?.let(PortableUserDataCodec::decode)
        } catch (e: Exception) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "NOOP user data could not be validated: ${e.message ?: "invalid portable data"}",
            )
        }

        if (csvData.isEmpty() && portable == null) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No supported data found (expected WHOOP CSVs or ${PortableUserDataCodec.FILE_NAME})."
            )
        }

        val computedDeviceId = if (deviceId.endsWith("-noop")) deviceId else "$deviceId-noop"
        val cyclesTable = csvData[CYCLES_NAME]?.let { CsvTable.fromData(it) }
        val sleepsTable = csvData[SLEEPS_NAME]?.let { CsvTable.fromData(it) }
        val workoutsTable = csvData[WORKOUTS_NAME]?.let { CsvTable.fromData(it) }

        val officialCyclesTable = cyclesTable?.let {
            rowsForProvenance(it, RowProvenance.OfficialReference)
        }
        val localCyclesTable = cyclesTable?.let {
            rowsForProvenance(it, RowProvenance.NoopApproximate, RowProvenance.NoopLocal)
        }
        val officialSleepsTable = sleepsTable?.let {
            rowsForProvenance(it, RowProvenance.OfficialReference)
        }
        val localSleepsTable = sleepsTable?.let {
            rowsForProvenance(it, RowProvenance.NoopApproximate, RowProvenance.NoopLocal)
        }
        val officialWorkoutsTable = workoutsTable?.let {
            rowsForProvenance(it, RowProvenance.OfficialReference)
        }
        val localWorkoutsTable = workoutsTable?.let {
            rowsForProvenance(it, RowProvenance.NoopApproximate, RowProvenance.NoopLocal)
        }

        val cycles = officialCyclesTable?.let { parseCycles(it, deviceId) }.orEmpty()
        val localCycles = localCyclesTable?.let { parseCycles(it, computedDeviceId) }.orEmpty()
        val cycleSeries = officialCyclesTable
            ?.let { parseCycleSeries(it, deviceId) }
            .orEmpty()
        val localCycleSeries = localCyclesTable
            ?.let { parseCycleSeries(it, computedDeviceId) }
            .orEmpty()
        val sleepParse = officialSleepsTable?.let { parseSleeps(it, deviceId) }
        val localSleepParse = localSleepsTable?.let { parseSleeps(it, computedDeviceId) }
        val sleepSessions = sleepParse?.sessions.orEmpty()
        val localSleepSessions = localSleepParse?.sessions.orEmpty()
        val sleepDaily = sleepParse?.daily.orEmpty()
        val localSleepDaily = localSleepParse?.daily.orEmpty()
        val workouts = officialWorkoutsTable?.let { parseWorkouts(it, deviceId) }.orEmpty()
        val localWorkouts = localWorkoutsTable
            ?.let { parseWorkouts(it, computedDeviceId) }
            .orEmpty()
        val workoutSeries = officialWorkoutsTable
            ?.let { parseWorkoutSeries(it, deviceId) }
            .orEmpty()
        val localWorkoutSeries = localWorkoutsTable
            ?.let { parseWorkoutSeries(it, computedDeviceId) }
            .orEmpty()
        // #136: journal rows key only by cycle_start; map that to the cycle's wake day so entries land on
        // the same day as their recovery/sleep outcome (else they read one day early and never correlate).
        val acceptedCyclesTable = cyclesTable?.let {
            rowsForProvenance(
                it,
                RowProvenance.OfficialReference,
                RowProvenance.NoopApproximate,
                RowProvenance.NoopLocal,
            )
        }
        val journalWake = acceptedCyclesTable?.let(::journalWakeDayMap).orEmpty()
        val journalParse = csvData[JOURNAL_NAME]
            ?.let { parseJournalResult(CsvTable.fromData(it), deviceId, journalWake) }
        val journal = journalParse?.entries.orEmpty()

        // Only accepted official cycle rows own whole-row replacement. A standalone sleeps.csv still
        // contributes architecture, but does so through fill-only storage so it cannot erase recovery,
        // HRV, RHR, or Effort already stored for that day.
        val officialDailyProjection = officialDailyProjection(cycles, sleepDaily, deviceId)
        val daily = officialDailyProjection.allRows
        val localDaily = mergeDaily(localCycles, localSleepDaily)

        if (daily.isEmpty() && localDaily.isEmpty() &&
            sleepSessions.isEmpty() && localSleepSessions.isEmpty() &&
            workouts.isEmpty() && localWorkouts.isEmpty() && journal.isEmpty() &&
            journalParse?.firstDay == null && (portable?.recordCount ?: 0) == 0
        ) {
            return ImportSummary.failure(SOURCE_LABEL, "Export contained no usable wearable rows.")
        }

        val hasOfficialRows =
            daily.isNotEmpty() || sleepSessions.isNotEmpty() || workouts.isNotEmpty() ||
            journalParse?.firstDay != null || cycleSeries.isNotEmpty() || workoutSeries.isNotEmpty()
        val hasLocalRows =
            localDaily.isNotEmpty() || localSleepSessions.isNotEmpty() ||
            localWorkouts.isNotEmpty() || localCycleSeries.isNotEmpty() ||
            localWorkoutSeries.isNotEmpty()
        val officialSeries = cycleSeries + workoutSeries
        val localSeries = localCycleSeries + localWorkoutSeries
        fun replacement(
            source: String,
            rows: List<MetricSeriesRow>,
            days: Collection<String>,
            keys: Set<String>,
        ): WhoopCsvMetricSeriesReplacement? {
            val first = days.minOrNull() ?: return null
            val last = days.maxOrNull() ?: return null
            return WhoopCsvMetricSeriesReplacement(
                deviceId = source,
                fromDay = first,
                toDay = last,
                managedKeys = keys.sorted(),
                rows = rows,
            )
        }
        val officialReplacements = listOfNotNull(
            replacement(deviceId, cycleSeries, cycles.map(DailyMetric::day), CYCLE_SERIES_KEYS),
            replacement(
                deviceId,
                workoutSeries,
                officialWorkoutsTable?.let(::workoutSeriesDays).orEmpty(),
                WORKOUT_SERIES_KEYS,
            ),
        )
        val journalReplacement =
            if (journalParse?.firstDay != null && journalParse.lastDay != null) {
                WhoopCsvJournalReplacement(
                    deviceId = deviceId,
                    fromDay = journalParse.firstDay,
                    toDay = journalParse.lastDay,
                    rows = journal,
                )
            } else {
                null
            }
        val sleepRange = sleepSessions.map(SleepSession::startTs).let { starts ->
            if (starts.isEmpty()) null else WhoopCsvTimestampRange(
                deviceId = deviceId,
                fromTs = starts.min(),
                toTs = starts.max(),
            )
        }
        val workoutRange = workouts.map(WorkoutRow::startTs).let { starts ->
            if (starts.isEmpty()) null else WhoopCsvTimestampRange(
                deviceId = deviceId,
                fromTs = starts.min(),
                toTs = starts.max(),
            )
        }
        val csvBatch = WhoopCsvImportBatch(
            officialDailyMetrics = officialDailyProjection.authoritativeRows,
            officialDailyMetricRange = officialDailyProjection.authoritativeRange,
            fillOnlyDailyMetrics = officialDailyProjection.fillOnlyRows + localDaily,
            officialSleepSessions = sleepSessions,
            officialSleepSessionRange = sleepRange,
            fillOnlySleepSessions = localSleepSessions,
            officialMetricSeriesReplacements = officialReplacements,
            fillOnlyMetricSeries = localSeries,
            journalReplacement = journalReplacement,
            officialWorkouts = workouts,
            officialWorkoutRange = workoutRange,
            officialWorkoutSource = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
            fillOnlyWorkouts = localWorkouts,
        )
        val devices = buildList {
            if (hasOfficialRows) add(WhoopCsvDeviceRegistration(deviceId, "Noop Band"))
            if (hasLocalRows) {
                add(WhoopCsvDeviceRegistration(computedDeviceId, "NOOP (Approximate)"))
            }
        }

        // Every Room-backed projection commits together. The SAF read above and caller-side UI
        // receipt, diagnostic log, and Test Centre SharedPreferences trace occur outside SQLite;
        // failure there can omit the receipt, but cannot partially commit these health rows.
        val portableSummary: PortableUserDataImportSummary? = try {
            repo.importWhoopArchive(
                portableUserData = portable,
                devices = devices,
                csvBatch = csvBatch,
            )
        } catch (e: Exception) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "Export could not be imported; no archive rows were saved: " +
                    (e.message ?: "database error"),
            )
        }

        val counts = LinkedHashMap<String, Int>()
        if (daily.isNotEmpty() || localDaily.isNotEmpty()) {
            counts["dailyMetric"] = daily.size + localDaily.size
        }
        if (sleepSessions.isNotEmpty() || localSleepSessions.isNotEmpty()) {
            counts["sleepSession"] = sleepSessions.size + localSleepSessions.size
        }
        if (workouts.isNotEmpty() || localWorkouts.isNotEmpty()) {
            counts["workout"] = workouts.size + localWorkouts.size
        }
        if (journal.isNotEmpty()) counts["journal"] = journal.size
        if (officialSeries.isNotEmpty() || localSeries.isNotEmpty()) {
            counts["metricSeries"] = officialSeries.size + localSeries.size
        }
        portableSummary?.let { summary ->
            if (summary.nutritionEntries > 0) counts["nutritionEntries"] = summary.nutritionEntries
            if (summary.strengthExercises > 0) counts["strengthExercises"] = summary.strengthExercises
            if (summary.strengthRoutines > 0) counts["strengthRoutines"] = summary.strengthRoutines
            if (summary.strengthRoutineExercises > 0) {
                counts["strengthRoutineExercises"] = summary.strengthRoutineExercises
            }
            if (summary.strengthSessions > 0) counts["strengthSessions"] = summary.strengthSessions
            if (summary.strengthSets > 0) counts["strengthSets"] = summary.strengthSets
        }

        // Date span across everything we wrote.
        val days = ArrayList<String>()
        days.addAll(daily.map { it.day })
        days.addAll(localDaily.map { it.day })
        days.addAll(journal.map { it.day })
        journalParse?.firstDay?.let(days::add)
        journalParse?.lastDay?.let(days::add)
        days.addAll(sleepSessions.map { epochSecondsToDay(it.startTs) })
        days.addAll(localSleepSessions.map { epochSecondsToDay(it.startTs) })
        days.addAll(workouts.map { epochSecondsToDay(it.startTs) })
        days.addAll(localWorkouts.map { epochSecondsToDay(it.startTs) })
        portable?.let { data ->
            days.addAll(data.nutritionEntries.map { it.day })
            days.addAll(data.strengthSessions.map { epochSecondsToDay(it.startedAt) })
        }
        val firstDay = days.minOrNull()
        val lastDay = days.maxOrNull()

        val total = counts.values.sum()
        val message = buildString {
            append("Imported ")
            append(total)
            append(" portable rows")
            if (firstDay != null && lastDay != null) append(" ($firstDay → $lastDay)")
            append(".")
            // #70: never silently truncate. If the aggregate RAM budget tripped, the retained CSV set was
            // partial — say so plainly instead of reporting a clean import over incomplete data.
            if (truncated) append(" (partial - export exceeded the ${MAX_TOTAL_BYTES shr 30} GB import memory budget)")
        }

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = counts,
            firstDay = firstDay,
            lastDay = lastDay,
            message = message,
        )
    }

    // MARK: - Locate + load CSVs

    /**
     * Return `[lowercasedFilename -> rawBytes]` for every recognised WHOOP CSV in the input.
     * Accepts a `.zip` (iterated with [ZipInputStream], routed by base filename) or a single
     * `.csv`. Mirrors Swift `loadCSVData` filename routing.
     */
    internal data class LoadedImportData(
        val csvData: Map<String, ByteArray>,
        val portableData: ByteArray?,
        val truncated: Boolean,
    )

    private fun loadCsvData(
        context: Context,
        uri: Uri,
        maxTotalBytes: Long = MAX_TOTAL_BYTES,
    ): LoadedImportData {
        val bytes = context.contentResolver.openInputStream(uri)?.use {
            it.readAllCapped(MAX_ENTRY_BYTES)
        } ?: throw IllegalStateException("Could not open input stream for $uri")
        return loadCsvData(bytes, displayName(context, uri), maxTotalBytes)
    }

    /**
     * Byte-level production loader shared by the Android URI entry point and opt-in real-archive tests.
     * [displayName] is only needed to route a loose CSV; ZIP entries are routed by their own names/headers.
     */
    internal fun loadCsvData(
        firstBytes: ByteArray,
        displayName: String? = null,
        maxTotalBytes: Long = MAX_TOTAL_BYTES,
    ): LoadedImportData {
        require(firstBytes.size.toLong() <= MAX_ENTRY_BYTES) {
            "Input exceeds $MAX_ENTRY_BYTES bytes"
        }
        val wanted = setOf(CYCLES_NAME, SLEEPS_NAME, WORKOUTS_NAME, JOURNAL_NAME)
        val result = LinkedHashMap<String, ByteArray>()
        var portableData: ByteArray? = null
        var total = 0L
        var truncated = false

        // First attempt: treat as a zip. WHOOP exports are zips; this also covers a .zip Uri
        // whose displayName we cannot read. If the stream is not a valid zip, ZipInputStream
        // yields no entries and we fall through to single-CSV handling.
        if (looksLikeZip(firstBytes)) {
            firstBytes.inputStream().use { raw ->
                ZipInputStream(raw).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        if (!entry.isDirectory) {
                            val base = baseName(entry.name).lowercase()
                            if (base == PortableUserDataCodec.FILE_NAME && portableData == null) {
                                val declared = entry.size
                                if (declared > PortableUserDataCodec.MAX_FILE_BYTES) {
                                    throw IllegalArgumentException(
                                        "${PortableUserDataCodec.FILE_NAME} exceeds the 64 MB limit",
                                    )
                                }
                                val bytes = zis.readEntryCapped(
                                    PortableUserDataCodec.MAX_FILE_BYTES.toLong(),
                                ) ?: throw IllegalArgumentException(
                                    "${PortableUserDataCodec.FILE_NAME} exceeds the 64 MB limit",
                                )
                                if (total + bytes.size > maxTotalBytes) {
                                    truncated = true
                                    break
                                }
                                portableData = bytes
                                total += bytes.size
                            // Only inspect CSVs (skip the export's GPX/ECG/other files).
                            } else if (base.endsWith(".csv")) {
                                val declared = entry.size // -1 when unknown
                                if (declared <= MAX_ENTRY_BYTES) {
                                    val bytes = zis.readEntryCapped(MAX_ENTRY_BYTES)
                                    if (bytes != null && bytes.isNotEmpty()) {
                                        // Route by English name, then a localized filename alias
                                        // (e.g. German Schlaf.csv), then by header content. This is
                                        // what lets non-English WHOOP exports import (issue #3).
                                        val canonical = when {
                                            base in wanted -> base
                                            else -> localizedAlias(base) ?: sniffCsvKind(bytes)
                                        }
                                        if (canonical != null && !result.containsKey(canonical)) {
                                            if (total + bytes.size > maxTotalBytes) { truncated = true; break }
                                            result[canonical] = bytes
                                            total += bytes.size
                                        }
                                    }
                                }
                            }
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                    }
                }
            }
            if (result.isNotEmpty() || portableData != null) {
                return LoadedImportData(result, portableData, truncated)
            }
        }

        // Not a (useful) zip — treat the input as a single CSV. Route by display name; if the
        // name is unknown, sniff the header row to identify which WHOOP CSV it is.
        val name = displayName?.lowercase()
        val routed = when {
            name != null && baseName(name) in wanted -> baseName(name)
            name != null && localizedAlias(baseName(name)) != null -> localizedAlias(baseName(name))
            else -> sniffCsvKind(firstBytes)
        }
        if (name != null && baseName(name) == PortableUserDataCodec.FILE_NAME) {
            require(firstBytes.size <= PortableUserDataCodec.MAX_FILE_BYTES) {
                "${PortableUserDataCodec.FILE_NAME} exceeds the 64 MB limit"
            }
            portableData = firstBytes
        } else if (routed != null) {
            result[routed] = firstBytes
        }
        // Single-file input holds one retained file — the aggregate budget cannot trip here.
        return LoadedImportData(result, portableData, truncated = false)
    }

    /** Whether the leading bytes are a local-file-header zip signature ("PK"). */
    private fun looksLikeZip(bytes: ByteArray): Boolean =
        bytes.size >= 4 &&
            bytes[0] == 0x50.toByte() && bytes[1] == 0x4B.toByte() &&
            bytes[2] == 0x03.toByte() && bytes[3] == 0x04.toByte()

    /** Identify a loose CSV by its header columns when the filename is unhelpful. */
    private fun sniffCsvKind(bytes: ByteArray): String? {
        val table = CsvTable.fromData(bytes)
        val h = table.normalizedHeaders.toHashSet()
        return when {
            "activity_name" in h || "workout_start_time" in h -> WORKOUTS_NAME
            "question_text" in h || "answered_yes_no" in h || "question" in h -> JOURNAL_NAME
            "nap" in h && ("sleep_onset" in h || "wake_onset" in h) -> SLEEPS_NAME
            "cycle_start_time" in h || "recovery_score_pct" in h || "day_strain" in h -> CYCLES_NAME
            "sleep_onset" in h || "asleep_duration_min" in h -> SLEEPS_NAME
            else -> null
        }
    }

    /**
     * Map a known localized WHOOP export filename to its canonical English name. WHOOP localizes
     * the CSV filenames in non-English exports (issue #3), so a German export ships Schlaf.csv,
     * Trainings.csv, physiologische_zyklen.csv and logbuch_eintraege.csv. Header-content sniffing
     * still covers any language whose column headers stay English.
     */
    private fun localizedAlias(base: String): String? = when (base) {
        // German (app.whoop.com → Daten exportieren)
        "physiologische_zyklen.csv" -> CYCLES_NAME
        "schlaf.csv" -> SLEEPS_NAME
        "trainings.csv" -> WORKOUTS_NAME
        "logbuch_eintraege.csv" -> JOURNAL_NAME
        // Spanish (issue #76): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        // Folded + unfolded variants — the filename is lowercased but not diacritic-folded.
        "sueño.csv", "sueno.csv" -> SLEEPS_NAME
        "entrenamientos.csv" -> WORKOUTS_NAME
        // French (issue #79): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        "sommeil.csv" -> SLEEPS_NAME
        "entrainements.csv", "entraînements.csv" -> WORKOUTS_NAME
        // Brazilian Portuguese (issue #692): unlike es/fr, WHOOP localizes ALL FOUR filenames here,
        // cycles included. Names from a real pt-BR export. Folded + unfolded variants because the
        // filename is lowercased but not diacritic-folded; header sniffing is the backstop if it mojibakes.
        "ciclos_fisiológicos.csv", "ciclos_fisiologicos.csv" -> CYCLES_NAME
        "sonos.csv" -> SLEEPS_NAME
        "treinos.csv" -> WORKOUTS_NAME
        "entradas_diário.csv", "entradas_diario.csv" -> JOURNAL_NAME
        else -> null
    }

    private fun baseName(path: String): String {
        val cleaned = path.replace('\\', '/')
        val slash = cleaned.lastIndexOf('/')
        return if (slash >= 0) cleaned.substring(slash + 1) else cleaned
    }

    private fun displayName(context: Context, uri: Uri): String? {
        // Try the OpenableColumns display name; fall back to the last path segment.
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    val n = c.getString(idx)
                    if (!n.isNullOrEmpty()) return n
                }
            }
        } catch (_: Exception) {
            // ignore — fall through
        }
        return uri.lastPathSegment
    }

    // MARK: - physiological_cycles.csv -> DailyMetric

    internal fun parseCycles(table: CsvTable, deviceId: String): List<DailyMetric> {
        val out = ArrayList<DailyMetric>(table.rows.size)
        for (row in table.rows) {
            if (classifySourceLabel(row.cell("source")) == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val cycleEnd = WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)

            // Skip rows with no usable timestamp at all.
            if (cycleStart == null && cycleEnd == null && wakeOnset == null) continue
            // WHOOP cycles are onset-to-onset: cycle_start_time == the sleep onset (the EVENING). Key
            // the day off the WAKE (wake_onset), then cycle_end (the next onset, same wake-day), then
            // the start. Matches parseSleeps + mergeSleep + macOS; keying off the start put scores a day
            // early and blanked Today for import-only users (import day-shift, v8.2.1).
            val day = epochSecondsToDay(wakeOnset ?: cycleEnd ?: cycleStart!!, tz)

            // Same aliases / unit handling as Swift parseCycles.
            val recovery = row.double("recovery_score_pct")
            val restingHr = row.double("resting_heart_rate_bpm", "resting_heart_rate")
            val avgHrv = row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms")
            val hrvMethod = if (avgHrv == null) {
                null
            } else {
                val explicit = row.cell("hrv_method")
                if (explicit == null) DailyHrvMethod.RMSSD
                else DailyHrvMethod.normalized(explicit)
            }
            val skinTemp = importedSkinTemperatureCelsius(row)
            val spo2 = row.double("blood_oxygen_pct", "blood_oxygen_pct_pct")
            val strain = row.double("day_strain")
            val resp = row.double("respiratory_rate_rpm", "respiratory_rate")

            val asleepMin = row.double("asleep_duration_min")
            val lightMin = row.double("light_sleep_duration_min")
            val deepMin = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            val remMin = row.double("rem_duration_min")
            val efficiency = row.double("sleep_efficiency_pct")

            out.add(
                DailyMetric(
                    deviceId = deviceId,
                    day = day,
                    totalSleepMin = asleepMin,
                    efficiency = efficiencyFractionFromPct(efficiency),
                    deepMin = deepMin,
                    remMin = remMin,
                    lightMin = lightMin,
                    // Awake duration is minutes, while this field is an event count. The export does
                    // not provide that count, so preserve the unknown instead of mixing units.
                    disturbances = null,
                    restingHr = roundedIntOrNull(restingHr),
                    avgHrv = avgHrv,
                    recovery = recovery,
                    // Rescale WHOOP's 0–21 Day Strain onto NOOP's 0–100 Effort axis (see
                    // DAY_STRAIN_TO_EFFORT_SCALE). nil passes through.
                    strain = effortFromImportedStrain(strain),
                    exerciseCount = null, // not present in physiological_cycles.csv
                    spo2Pct = spo2,
                    skinTempDevC = skinTemp,
                    respRateBpm = resp,
                    hrvMethod = hrvMethod,
                )
            )
        }
        return out
    }

    /**
     * Normalize an imported absolute skin-temperature field to Celsius. Prefer an explicit Celsius
     * column when both are present; Fahrenheit must be converted at this boundary so no downstream
     * screen or health calculation can mistake (for example) 95 °F for 95 °C.
     */
    internal fun importedSkinTemperatureCelsius(row: Map<String, String>): Double? {
        row.double("skin_temp_celsius")?.takeIf(Double::isFinite)?.let { return it }
        val fahrenheit = row.double("skin_temp_f", "skin_temp_fahrenheit")
            ?.takeIf(Double::isFinite)
            ?: return null
        return ((fahrenheit - 32.0) * 5.0 / 9.0).takeIf(Double::isFinite)
    }

    /**
     * physiological_cycles.csv -> the complete long-format metricSeries projection imported on
     * Apple. Scores and derived percentages are 0–100, durations are minutes, Effort is on NOOP's
     * 0–100 axis, and `sleep_efficiency` follows the database-wide 0–1 fraction contract.
     */
    internal fun parseCycleSeries(table: CsvTable, deviceId: String): List<MetricSeriesRow> {
        val out = ArrayList<MetricSeriesRow>()
        for (row in table.rows) {
            if (classifySourceLabel(row.cell("source")) == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val cycleEnd = WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)
            if (cycleStart == null && cycleEnd == null && wakeOnset == null) continue   // same skip rule as parseCycles
            // Wake-day keying — see parseCycles (WHOOP cycle_start is the evening onset, v8.2.1).
            val day = epochSecondsToDay(wakeOnset ?: cycleEnd ?: cycleStart!!, tz)
            fun add(key: String, value: Double?) {
                if (value != null && value.isFinite()) {
                    out.add(MetricSeriesRow(deviceId, day, key, value))
                }
            }

            val strain = effortFromImportedStrain(row.double("day_strain"))
            val asleep = row.double("asleep_duration_min")
            val inBed = row.double("in_bed_duration_min")
            val deep = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            val rem = row.double("rem_duration_min")
            val light = row.double("light_sleep_duration_min")
            val awake = row.double("awake_duration_min")
            val sleepNeed = row.double("sleep_need_min")

            add("recovery", row.double("recovery_score_pct"))
            add("strain", strain)
            add("rhr", row.double("resting_heart_rate_bpm", "resting_heart_rate"))
            add("hrv", row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms"))
            add("spo2", row.double("blood_oxygen_pct", "blood_oxygen_pct_pct"))
            add("skin_temp", importedSkinTemperatureCelsius(row))
            add("resp_rate", row.double("respiratory_rate_rpm", "respiratory_rate"))
            add("energy_kcal", row.double("energy_burned_cal"))
            add("avg_hr", row.double("average_hr_bpm", "average_heart_rate_bpm"))
            add("max_hr", row.double("max_hr_bpm", "max_heart_rate_bpm"))
            add("sleep_total_min", asleep)
            add("in_bed_min", inBed)
            add("sleep_deep_min", deep)
            add("sleep_rem_min", rem)
            add("sleep_light_min", light)
            add("awake_min", awake)
            add(
                SleepEfficiencyUnits.SERIES_KEY,
                efficiencyFractionFromPct(row.double("sleep_efficiency_pct")),
            )
            add("sleep_performance", row.double("sleep_performance_pct"))
            add("sleep_consistency", row.double("sleep_consistency_pct"))
            add("sleep_need_min", sleepNeed)
            add("sleep_debt_min", row.double("sleep_debt_min"))

            if (deep != null && rem != null) {
                val restorative = deep + rem
                add("restorative_min", restorative)
                if (asleep != null && asleep > 0.0) {
                    add("restorative_pct", restorative / asleep * 100.0)
                }
            }
            if (asleep != null && sleepNeed != null && sleepNeed > 0.0) {
                add("hours_vs_needed_pct", asleep / sleepNeed * 100.0)
            }
        }
        return out
    }

    // MARK: - sleeps.csv -> SleepSession (+ DailyMetric sleep fields)

    internal class SleepParse(
        val sessions: List<SleepSession>,
        val daily: List<DailyMetric>,
    )

    internal fun parseSleeps(table: CsvTable, deviceId: String): SleepParse {
        val sessions = ArrayList<SleepSession>(table.rows.size)
        val daily = ArrayList<DailyMetric>()
        for (row in table.rows) {
            if (classifySourceLabel(row.cell("source")) == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val cycleStart = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz)
            val sleepOnset = WhoopTime.parseEpochSeconds(row.cell("sleep_onset"), tz)
            val wakeOnset = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)

            // Swift skip rule: cycleStart == nil && sleepOnset == nil && wakeOnset == nil.
            if (cycleStart == null && sleepOnset == null && wakeOnset == null) continue

            val isNap = row.bool("nap") ?: false

            val efficiency = row.double("sleep_efficiency_pct")
            val resp = row.double("respiratory_rate_rpm", "respiratory_rate")
            val asleepMin = row.double("asleep_duration_min")
            val lightMin = row.double("light_sleep_duration_min")
            val deepMin = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            val remMin = row.double("rem_duration_min")
            val awakeMin = row.double("awake_duration_min")

            // SleepSession PK is (deviceId, startTs). Prefer the actual sleep onset, then cycle
            // start. endTs prefers wake_onset; if absent derive from in-bed/asleep minutes.
            val startTs = sleepOnset ?: cycleStart
            if (startTs != null) {
                val inBedMin = row.double("in_bed_duration_min")
                val derivedEnd = derivedSleepEnd(startTs, inBedMin ?: asleepMin)
                val endTs = wakeOnset ?: derivedEnd
                sessions.add(
                    SleepSession(
                        deviceId = deviceId,
                        startTs = startTs,
                        endTs = if (endTs >= startTs) endTs else startTs,
                        efficiency = efficiencyFractionFromPct(efficiency),
                        restingHr = null, // resting HR is a cycles/recovery field, not in sleeps.csv
                        avgHrv = null,    // HRV likewise is a recovery field, not in sleeps.csv
                        stagesJSON = stagesJson(lightMin, deepMin, remMin, awakeMin),
                    )
                )
            }

            // Fold the MAIN sleep (not naps) into a DailyMetric keyed on the sleep's WAKE day, so the
            // sleep-architecture columns are populated even when physiological_cycles.csv is absent.
            // Key off wake_onset: sleep_onset (== cycle_start_time in a WHOOP export) is the PREVIOUS
            // evening, and mergeDaily groups by day-string. parseCycles now keys its cycle rows off the
            // wake too (v8.2.1), so the two align on the same wake-day and merge into one row; keying
            // either off the onset landed the night a day early and split it across two rows. Every
            // convention (sleep-session mergeSleep, the AppleHealth importer, macOS) uses the local
            // wake-day; align with it. Naps stay excluded above.
            if (!isNap) {
                val dayTs = wakeOnset ?: cycleStart ?: sleepOnset
                if (dayTs != null) {
                    daily.add(
                        DailyMetric(
                            deviceId = deviceId,
                            day = epochSecondsToDay(dayTs, tz),
                            totalSleepMin = asleepMin,
                            efficiency = efficiencyFractionFromPct(efficiency),
                            deepMin = deepMin,
                            remMin = remMin,
                            lightMin = lightMin,
                            disturbances = null,
                            restingHr = null,
                            avgHrv = null,
                            recovery = null,
                            strain = null,
                            exerciseCount = null,
                            spo2Pct = null,
                            skinTempDevC = null,
                            respRateBpm = resp,
                        )
                    )
                }
            }
        }
        return SleepParse(sessions, daily)
    }

    // MARK: - workouts.csv -> WorkoutRow

    internal fun parseWorkouts(table: CsvTable, deviceId: String): List<WorkoutRow> {
        val out = ArrayList<WorkoutRow>(table.rows.size)
        for (row in table.rows) {
            val provenance = classifySourceLabel(row.cell("source"))
            if (provenance == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val workoutStart =
                WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), tz) ?: continue
            val workoutEnd =
                WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), tz) ?: continue
            if (workoutEnd <= workoutStart) continue
            val sport = row.cell("activity_name") ?: "Workout" // PK component; never blank.

            // Workout strain is also WHOOP's 0–21 scale → rescale onto NOOP's 0–100 Effort axis so
            // imported workouts match detected/manual ones (StrainScorer now scores 0–100).
            val strain = effortFromImportedStrain(row.double("activity_strain"))
            val energyKcal = row.double("energy_burned_cal") // CSV "(cal)" == kcal
            val avgHr = row.double("average_hr_bpm", "average_heart_rate_bpm")
            val maxHr = row.double("max_hr_bpm", "max_heart_rate_bpm")

            val z1 = row.double("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct")
            val z2 = row.double("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct")
            val z3 = row.double("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct")
            val z4 = row.double("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct")
            val z5 = row.double("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct")

            val distance = row.double("distance_meters", "distance_meter")

            val durationS = (workoutEnd - workoutStart).toDouble()

            out.add(
                WorkoutRow(
                    deviceId = deviceId,
                    startTs = workoutStart,
                    endTs = workoutEnd,
                    sport = sport,
                    source = when (provenance) {
                        RowProvenance.NoopLocal -> "manual"
                        RowProvenance.NoopApproximate -> deviceId
                        RowProvenance.OfficialReference -> WHOOP_CSV_IMPORTED_WORKOUT_SOURCE
                        RowProvenance.Unknown -> error("Unknown provenance was filtered above")
                    },
                    durationS = durationS,
                    energyKcal = energyKcal,
                    avgHr = roundedIntOrNull(avgHr),
                    maxHr = roundedIntOrNull(maxHr),
                    strain = strain,
                    distanceM = distance,
                    zonesJSON = zonesJson(z1, z2, z3, z4, z5),
                    notes = null,
                )
            )
        }
        return out
    }

    /**
     * Derive the daily workout aggregates Apple persists from the same CSV rows.
     *
     * Exported Zone 1...5 percentages cover only time at or above Zone 1. Their sum may therefore be
     * below 100%; the remainder is below Zone 1 and must not be redistributed across the five zones.
     */
    internal fun parseWorkoutSeries(table: CsvTable, deviceId: String): List<MetricSeriesRow> {
        data class ZoneDay(
            val minutes: DoubleArray = DoubleArray(5),
            val observed: BooleanArray = BooleanArray(5),
            val complete: BooleanArray = BooleanArray(5) { true },
        )

        val zonesByDay = LinkedHashMap<String, ZoneDay>()
        val strengthMinutesByDay = LinkedHashMap<String, Double>()

        for (row in table.rows) {
            if (classifySourceLabel(row.cell("source")) == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val start = WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), tz) ?: continue
            val end = WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), tz) ?: continue
            if (end <= start) continue

            val durationMin = (end - start) / 60.0
            val day = epochSecondsToDay(start, tz)
            fun zone(vararg keys: String): Double? =
                row.double(*keys)?.takeIf { it.isFinite() && it in 0.0..100.0 }

            val percentages = listOf(
                zone("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct"),
                zone("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct"),
                zone("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct"),
                zone("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct"),
                zone("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct"),
            )
            val accumulator = zonesByDay.getOrPut(day, ::ZoneDay)
            val reportedSum = percentages.filterNotNull().sum()
            val allReported = percentages.all { it != null }
            val impossibleTotal =
                reportedSum > 101.0 || (!allReported && reportedSum > 100.0)
            if (impossibleTotal) {
                // One impossible workout makes the whole day's zone aggregate incomplete. Keeping
                // only its individually plausible columns would understate the same workout.
                for (index in percentages.indices) accumulator.complete[index] = false
            } else {
                // Independently rounded integer percentages can total 101. Scale that narrow,
                // complete case back to 100 so zoned minutes never exceed workout duration.
                val scale =
                    if (allReported && reportedSum > 100.0) 100.0 / reportedSum else 1.0
                for (index in percentages.indices) {
                    val percent = percentages[index]
                    if (percent == null) {
                        accumulator.complete[index] = false
                    } else {
                        accumulator.minutes[index] += durationMin * percent * scale / 100.0
                        accumulator.observed[index] = true
                    }
                }
            }

            val activity = row.cell("activity_name")?.lowercase().orEmpty()
            if ("strength" in activity || "weight" in activity) {
                strengthMinutesByDay[day] =
                    strengthMinutesByDay.getOrDefault(day, 0.0) + durationMin
            }
        }

        val out = ArrayList<MetricSeriesRow>(
            zonesByDay.size * 8 + strengthMinutesByDay.size,
        )
        fun add(day: String, key: String, value: Double) {
            out.add(MetricSeriesRow(deviceId, day, key, value))
        }
        for ((day, accumulator) in zonesByDay) {
            val available = BooleanArray(5) {
                accumulator.complete[it] && accumulator.observed[it]
            }
            for (index in available.indices) {
                if (available[index]) {
                    add(day, "hr_zone${index + 1}_min", accumulator.minutes[index])
                }
            }
            if ((0..2).all { available[it] }) {
                add(day, "hr_zones13_min", (0..2).sumOf { accumulator.minutes[it] })
            }
            if ((3..4).all { available[it] }) {
                add(day, "hr_zones45_min", (3..4).sumOf { accumulator.minutes[it] })
            }
            if (available.all { it }) {
                add(day, "hr_zones_all_min", accumulator.minutes.sum())
            }
        }
        for ((day, minutes) in strengthMinutesByDay) add(day, "strength_min", minutes)
        return out
    }

    /** Every valid workout day represented by this provenance-filtered CSV, even when the row has no
     * zone percentages. Import replacement uses this span to remove previously imported aggregates. */
    internal fun workoutSeriesDays(table: CsvTable): Set<String> {
        val days = LinkedHashSet<String>()
        for (row in table.rows) {
            if (classifySourceLabel(row.cell("source")) == RowProvenance.Unknown) continue
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val start =
                WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), tz) ?: continue
            val end =
                WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), tz) ?: continue
            if (end > start) days.add(epochSecondsToDay(start, tz))
        }
        return days
    }

    // MARK: - journal_entries.csv -> JournalEntry

    /** #136: map each cycle's onset (cycle_start_time epoch) to its WAKE day, so journal entries — which
     *  the export keys only by cycle_start — store on the same wake day as the cycle's recovery/sleep
     *  outcome (and the native journal), not the onset evening. Same day rule as parseCycles. */
    internal fun journalWakeDayMap(cycles: CsvTable): Map<Long, String> {
        val out = HashMap<Long, String>()
        for (row in cycles.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            val start = WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz) ?: continue
            val wake = WhoopTime.parseEpochSeconds(row.cell("wake_onset"), tz)
                ?: WhoopTime.parseEpochSeconds(row.cell("cycle_end_time"), tz)
                ?: continue
            out[start] = epochSecondsToDay(wake, tz)
        }
        return out
    }

    internal data class JournalParseResult(
        val entries: List<JournalEntry>,
        val firstDay: String?,
        val lastDay: String?,
    )

    internal fun parseJournal(
        table: CsvTable,
        deviceId: String,
        wakeDayByStart: Map<Long, String> = emptyMap(),
    ): List<JournalEntry> = parseJournalResult(table, deviceId, wakeDayByStart).entries

    internal fun parseJournalResult(
        table: CsvTable,
        deviceId: String,
        wakeDayByStart: Map<Long, String> = emptyMap(),
    ): JournalParseResult {
        data class Candidate(
            val cycleStart: Long,
            val timezoneOffsetMin: Int,
            val entry: JournalEntry,
            val explicitAnswer: Boolean,
        )
        data class ExactKey(
            val cycleStart: Long,
            val timezoneOffsetMin: Int,
            val question: String,
            val answer: Boolean,
            val notes: String?,
        )
        data class DayQuestion(val day: String, val question: String)

        val candidates = ArrayList<Candidate>(table.rows.size)
        val sourceDays = ArrayList<String>(table.rows.size)
        for (row in table.rows) {
            val tz = WhoopTime.tzOffsetMinutes(row["cycle_timezone"])
            // A missing timestamp cannot be assigned to a defensible journal day. In particular,
            // never project it onto the current date, which fabricates a recent user answer.
            val cycleStart =
                WhoopTime.parseEpochSeconds(row.cell("cycle_start_time"), tz) ?: continue
            val question = row.cell("question_text", "question")
            // #631: the REAL WHOOP export header is "Answered yes" (-> answered_yes), not the
            // "Answered yes/no" NOOP's own exporter writes (-> answered_yes_no). Every real WHOOP
            // journal import silently zeroed out to "without" because neither of the old keys ever
            // matched, regardless of the account's actual answers.
            val answer = row.cell("answered_yes", "answered_yes_no", "answer", "answer_text")
            val notes = row.cell("notes")

            // Swift: a journal row is only meaningful if it has a question/answer/notes.
            if (question == null && answer == null && notes == null) continue
            // Our JournalEntry PK is (deviceId, day, question); a question is required to store.
            if (question == null) continue

            // #136: journal_entries.csv carries only cycle_start (the onset evening), no wake time. Key the
            // entry to the cycle's WAKE day — the same day parseCycles/parseSleeps and the native journal
            // use — via wakeDayByStart, so it lines up with the recovery/sleep outcome Insights correlates
            // it against. Without this every imported entry sat one day early and never matched its outcome,
            // so all historic days collapsed into "Without". Fall back to the onset day only when the cycle
            // row isn't in the export.
            val onsetDay = epochSecondsToDay(cycleStart, tz)
            val day = wakeDayByStart[cycleStart] ?: onsetDay
            // Include both keying schemes in the authoritative replacement range. Older builds
            // persisted the same source row on its onset day; deleting only wake days left the
            // earliest legacy row behind after re-import.
            sourceDays.add(onsetDay)
            sourceDays.add(day)

            // Persistence has a Boolean column. A blank, malformed, or notes-only answer is unknown,
            // not false; omit it rather than fabricating a "No" behavior signal.
            val explicitAnswer = parseYesNoOrNull(answer) ?: continue

            candidates.add(
                Candidate(
                    cycleStart = cycleStart,
                    timezoneOffsetMin = tz,
                    explicitAnswer = explicitAnswer,
                    entry = JournalEntry(
                        deviceId = deviceId,
                        day = day,
                        question = question,
                        answeredYes = explicitAnswer,
                        notes = notes,
                    ),
                )
            )
        }

        val exactRows = HashSet<ExactKey>()
        val unique = candidates.filter { candidate ->
            exactRows.add(
                ExactKey(
                    cycleStart = candidate.cycleStart,
                    timezoneOffsetMin = candidate.timezoneOffsetMin,
                    question = candidate.entry.question,
                    answer = candidate.explicitAnswer,
                    notes = candidate.entry.notes,
                )
            )
        }
        val answersByKey = HashMap<DayQuestion, MutableSet<Boolean>>()
        for (candidate in unique) {
            val key = DayQuestion(candidate.entry.day, candidate.entry.question)
            answersByKey.getOrPut(key, ::LinkedHashSet).add(candidate.explicitAnswer)
        }
        val contradictory = answersByKey
            .filterValues { it.size > 1 }
            .keys
        val accepted = unique
            .asSequence()
            .filter { DayQuestion(it.entry.day, it.entry.question) !in contradictory }
            .toList()
        val byNaturalKey = LinkedHashMap<DayQuestion, MutableList<Candidate>>()
        for (candidate in accepted) {
            val key = DayQuestion(candidate.entry.day, candidate.entry.question)
            byNaturalKey.getOrPut(key, ::ArrayList).add(candidate)
        }
        val entries = byNaturalKey.values.map { group ->
            val notes = group
                .mapNotNull { it.entry.notes?.trim()?.takeIf { note -> note.isNotEmpty() } }
                .distinct()
                .sorted()
            group.first().entry.copy(
                notes = notes.takeIf { it.isNotEmpty() }?.joinToString("\n"),
            )
        }
        return JournalParseResult(
            entries = entries,
            firstDay = sourceDays.minOrNull(),
            lastDay = sourceDays.maxOrNull(),
        )
    }

    // MARK: - Merge helpers

    internal data class OfficialDailyProjection(
        val allRows: List<DailyMetric>,
        val authoritativeRows: List<DailyMetric>,
        val fillOnlyRows: List<DailyMetric>,
        val authoritativeRange: WhoopCsvDayRange?,
    )

    /**
     * Partition official daily data by ownership.
     *
     * A physiological-cycle row is the authoritative daily summary. Sleep-derived rows enrich a
     * matching cycle row, but a day represented only by sleeps.csv is fill-only. This distinction is
     * what lets loose sleeps.csv imports coexist with an existing complete daily row.
     */
    internal fun officialDailyProjection(
        cycles: List<DailyMetric>,
        sleepDaily: List<DailyMetric>,
        deviceId: String,
    ): OfficialDailyProjection {
        val allRows = mergeDaily(cycles, sleepDaily)
        val cycleDays = cycles.mapTo(LinkedHashSet(), DailyMetric::day)
        val authoritativeRows = allRows.filter { it.day in cycleDays }
        val fillOnlyRows = allRows.filterNot { it.day in cycleDays }
        val first = cycleDays.minOrNull()
        val last = cycleDays.maxOrNull()
        return OfficialDailyProjection(
            allRows = allRows,
            authoritativeRows = authoritativeRows,
            fillOnlyRows = fillOnlyRows,
            authoritativeRange =
                if (first == null || last == null) null
                else WhoopCsvDayRange(deviceId, first, last),
        )
    }

    /**
     * Merge cycle-derived and sleep-derived daily rows on (deviceId, day). Cycle fields take
     * precedence (they carry recovery/strain/RHR/HRV/SpO2/skin-temp); sleep rows fill any sleep
     * architecture columns the cycle row left null. One row per (deviceId, day) to honour the PK.
     */
    internal fun mergeDaily(cycles: List<DailyMetric>, sleepDaily: List<DailyMetric>): List<DailyMetric> {
        if (sleepDaily.isEmpty()) return dedupeByDay(cycles, preferFirst = true)
        if (cycles.isEmpty()) return dedupeByDay(sleepDaily, preferFirst = true)

        val byDay = LinkedHashMap<String, DailyMetric>()
        // Seed with sleep rows first (lower precedence), then overlay cycle rows.
        for (s in sleepDaily) {
            val key = s.day
            byDay[key] = byDay[key]?.let { mergeRow(it, s) } ?: s
        }
        for (c in cycles) {
            val key = c.day
            val existing = byDay[key]
            byDay[key] = if (existing == null) c else mergeRow(existing, c)
        }
        return byDay.values.toList()
    }

    /** Collapse rows that share a day, keeping the first non-null field per column. */
    private fun dedupeByDay(rows: List<DailyMetric>, preferFirst: Boolean): List<DailyMetric> {
        val byDay = LinkedHashMap<String, DailyMetric>()
        for (r in rows) {
            val existing = byDay[r.day]
            byDay[r.day] = if (existing == null) r else if (preferFirst) mergeRow(existing, r) else mergeRow(r, existing)
        }
        return byDay.values.toList()
    }

    /** [base] wins for every non-null field; [fill] supplies values only where [base] is null. */
    private fun mergeRow(base: DailyMetric, fill: DailyMetric): DailyMetric = DailyMetric(
        deviceId = base.deviceId,
        day = base.day,
        totalSleepMin = base.totalSleepMin ?: fill.totalSleepMin,
        efficiency = base.efficiency ?: fill.efficiency,
        deepMin = base.deepMin ?: fill.deepMin,
        remMin = base.remMin ?: fill.remMin,
        lightMin = base.lightMin ?: fill.lightMin,
        disturbances = base.disturbances ?: fill.disturbances,
        restingHr = base.restingHr ?: fill.restingHr,
        avgHrv = base.avgHrv ?: fill.avgHrv,
        recovery = base.recovery ?: fill.recovery,
        strain = base.strain ?: fill.strain,
        exerciseCount = base.exerciseCount ?: fill.exerciseCount,
        spo2Pct = base.spo2Pct ?: fill.spo2Pct,
        skinTempDevC = base.skinTempDevC ?: fill.skinTempDevC,
        respRateBpm = base.respRateBpm ?: fill.respRateBpm,
        hrvMethod = if (base.avgHrv == null) fill.hrvMethod else base.hrvMethod,
    )

    // MARK: - JSON encoders (match DemoSeeder shapes)

    /** Stage-segments array `[{stage, min}]` (minutes), null if no stage data present. */
    private fun stagesJson(lightMin: Double?, deepMin: Double?, remMin: Double?, awakeMin: Double?): String? {
        if (lightMin == null && deepMin == null && remMin == null && awakeMin == null) return null
        val arr = JSONArray()
        fun seg(stage: String, min: Double?) {
            if (min != null) arr.put(JSONObject().put("stage", stage).put("min", min))
        }
        seg("light", lightMin)
        seg("deep", deepMin)
        seg("rem", remMin)
        seg("awake", awakeMin)
        return if (arr.length() == 0) null else arr.toString()
    }

    /** HR-zone-percentage object `{zone1..zone5}`, null if no zone data present. */
    private fun zonesJson(z1: Double?, z2: Double?, z3: Double?, z4: Double?, z5: Double?): String? {
        if (z1 == null && z2 == null && z3 == null && z4 == null && z5 == null) return null
        val obj = JSONObject()
        if (z1 != null) obj.put("zone1", z1)
        if (z2 != null) obj.put("zone2", z2)
        if (z3 != null) obj.put("zone3", z3)
        if (z4 != null) obj.put("zone4", z4)
        if (z5 != null) obj.put("zone5", z5)
        return if (obj.length() == 0) null else obj.toString()
    }

    private fun parseYesNoOrNull(raw: String?): Boolean? {
        return when (raw?.trim()?.lowercase()) {
            "true", "yes", "1", "y" -> true
            "false", "no", "0", "n" -> false
            else -> null
        }
    }

    // MARK: - Day-string derivation

    /**
     * Convert wall-clock unix SECONDS to a "YYYY-MM-DD" day string at the given UTC offset
     * (minutes). The offset re-applies the source local-day boundary so a cycle that starts
     * at 23:30 local does not roll to the next UTC day.
     */
    private fun epochSecondsToDay(epochSeconds: Long, offsetMinutes: Int = 0): String {
        val offset = try {
            ZoneOffset.ofTotalSeconds(offsetMinutes * 60)
        } catch (_: Exception) {
            ZoneOffset.UTC
        }
        return Instant.ofEpochSecond(epochSeconds).atOffset(offset).toLocalDate().format(DAY_FMT)
    }
}

// MARK: - Stream helpers

/** Read a whole stream, throwing if it exceeds [cap] bytes (memory guard). */
private fun InputStream.readAllCapped(cap: Long): ByteArray {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        total += n
        if (total > cap) throw IllegalStateException("Input exceeds $cap bytes")
        buffer.write(chunk, 0, n)
    }
    return buffer.toByteArray()
}

/** Read the current zip entry, capping at [cap] bytes; returns null if it overflows. */
private fun ZipInputStream.readEntryCapped(cap: Long): ByteArray? {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        total += n
        if (total > cap) return null
        buffer.write(chunk, 0, n)
    }
    return buffer.toByteArray()
}
