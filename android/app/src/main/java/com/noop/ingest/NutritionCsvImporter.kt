package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.R
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * Imports a nutrition CSV (daily calories / macros / body weight) into the local Room store.
 *
 * Kotlin mirror of the macOS Swift nutrition lane: SAME source id and SAME long-format
 * metricSeries keys, so charts and the AI coach read one vocabulary on both platforms:
 *
 *   source (deviceId) : "nutrition-csv"
 *   keys              : calories_in (kcal), protein_g, carbs_g, fat_g, weight (kg)
 *
 * Three header shapes are recognised explicitly (after [HeaderNorm] normalization):
 *
 *   1. NOOP native      — `date, calories_in, protein_g, carbs_g, fat_g, weight_kg`
 *   2. MyFitnessPal     — `Date, Meal, Calories, Protein (g), Carbohydrates (g), Fat (g)`
 *                          (per-meal rows; intake values are SUMMED per day)
 *   3. Cronometer daily — `Date, Completed, Energy (kcal), Protein (g), Carbs (g), Fat (g)`
 *
 * plus a tolerant fallback: any CSV with a recognisable date column and at least one column
 * whose normalized header *contains* calorie/energy, protein, carb, fat or weight imports too.
 * "Saturated/trans/poly/mono/body fat" are never mistaken for total fat, and "burned"/"goal"
 * energy columns are never mistaken for intake. Weight requires kg/lb in either its header or cell,
 * and pounds are converted to kilograms so the stored `weight` key is always kg. Bare numeric
 * values under an ambiguous `Weight` header are rejected rather than silently assumed to be kg.
 *
 * The whole pipeline is tolerant: rows without a parsable date are skipped, blank cells
 * contribute nothing, duplicate-day intake rows (meal logs) sum, and the last weight of a
 * day wins. Parsing is pure ([parse]) so it is JVM unit-testable (NutritionCsvImporterTest).
 */
object NutritionCsvImporter {

    /** Room deviceId for everything this importer writes — identical to the Swift lane. */
    const val SOURCE_ID = "nutrition-csv"

    private const val SOURCE_LABEL = "Nutrition"

    /** metricSeries keys — identical to the Swift lane. */
    internal const val KEY_CALORIES_IN = "calories_in"
    internal const val KEY_PROTEIN_G = "protein_g"
    internal const val KEY_CARBS_G = "carbs_g"
    internal const val KEY_FAT_G = "fat_g"
    internal const val KEY_WEIGHT = "weight"

    /** Pounds → kilograms (exact avoirdupois definition). */
    internal const val LB_TO_KG = 0.45359237

    internal enum class WeightUnit { KILOGRAMS, POUNDS, AMBIGUOUS }

    internal data class WeightColumn(val header: String, val unit: WeightUnit)

    internal sealed class WeightValue {
        data class Kilograms(val value: Double) : WeightValue()
        object MissingOrInvalid : WeightValue()
        object Ambiguous : WeightValue()
    }

    /** Input ceiling — a nutrition CSV is tiny; 64 MB is already absurdly generous. */
    private const val MAX_BYTES = 64L shl 20

    /**
     * Public entry point the UI calls. Reads the SAF [uri] via the content resolver,
     * parses it with the shared tolerant [CsvTable], upserts long-format rows through
     * [repo] under [deviceId] (defaults to "nutrition-csv") and returns an [ImportSummary].
     */
    suspend fun importCsv(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = SOURCE_ID,
    ): ImportSummary {
        val bytes: ByteArray = try {
            context.contentResolver.openInputStream(uri)?.use { it.readCapped(MAX_BYTES) }
                ?: throw IllegalStateException("Could not open input stream for $uri")
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read CSV: ${e.message ?: "unknown error"}")
        }

        val table = CsvTable.fromData(bytes)
        if (table.rows.isEmpty()) {
            return ImportSummary.failure(SOURCE_LABEL, "CSV contained no data rows.")
        }
        if (resolveColumns(table.normalizedHeaders) == null) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "Couldn't recognise the columns - expected a date column plus any of " +
                    "calories / protein / carbs / fat / weight.",
            )
        }

        val parsed = parseDetailed(table, deviceId)
        val rows = parsed.rows
        if (rows.isEmpty()) {
            if (parsed.ambiguousWeightRows > 0) {
                return ImportSummary.failure(
                    SOURCE_LABEL,
                    context.getString(R.string.nutrition_weight_unit_missing_failure),
                )
            }
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No usable nutrition rows (check the date column format).",
            )
        }

        repo.upsertDevice(deviceId, name = "Nutrition CSV")
        repo.upsertMetricSeries(rows)

        val days = rows.map { it.day }
        val firstDay = days.minOrNull()
        val lastDay = days.maxOrNull()
        val dayCount = days.toHashSet().size

        return ImportSummary(
            source = SOURCE_LABEL,
            counts = linkedMapOf("metricSeries" to rows.size),
            firstDay = firstDay,
            lastDay = lastDay,
            message = buildString {
                append("Imported ${rows.size} nutrition values across $dayCount day")
                if (dayCount != 1) append("s")
                if (firstDay != null && lastDay != null) append(" ($firstDay → $lastDay)")
                append(".")
                if (parsed.ambiguousWeightRows > 0) {
                    append(" ")
                    append(
                        context.resources.getQuantityString(
                            R.plurals.nutrition_weight_values_skipped,
                            parsed.ambiguousWeightRows,
                            parsed.ambiguousWeightRows,
                        )
                    )
                }
            },
        )
    }

    // MARK: - Column resolution (3 explicit shapes + tolerant fallback)

    /** Which normalized header feeds which metric key. Null = column absent. */
    internal data class NutritionColumns(
        val date: String,
        val calories: String?,
        val protein: String?,
        val carbs: String?,
        val fat: String?,
        val weight: String?,
        /** Declared header unit; AMBIGUOUS requires a unit-bearing value cell. */
        val weightUnit: WeightUnit,
    )

    /**
     * Resolve which columns carry which metric. Exact (alias) matches are tried first so the
     * three known shapes bind deterministically; substring fallbacks then catch everything else.
     * Returns null when there is no date column or no value column at all.
     */
    internal fun resolveColumns(normalizedHeaders: List<String>): NutritionColumns? {
        val headers = normalizedHeaders.filter { it.isNotEmpty() }
        val set = headers.toHashSet()
        fun exact(vararg names: String): String? = names.firstOrNull { it in set }
        fun fallback(predicate: (String) -> Boolean): String? = headers.firstOrNull(predicate)

        val date = exact("date", "day", "log_date", "entry_date", "logged_date")
            ?: fallback { "date" in it }
            ?: fallback { it == "time" || "timestamp" in it }
            ?: return null

        // Intake energy. Never bind "burned"/"goal" columns (e.g. "Energy burned (cal)").
        val calories = exact(
            "calories_in", "calories", "energy_kcal", "calories_kcal", "energy",
            "calories_consumed", "kcal",
        ) ?: fallback {
            ("calorie" in it || "energy" in it || "kcal" in it) && "burn" !in it && "goal" !in it
        }

        val protein = exact("protein_g", "protein")
            ?: fallback { "protein" in it && "goal" !in it }

        val carbs = exact(
            "carbs_g", "carbohydrates_g", "carbs", "carbohydrates", "net_carbs_g",
            "net_carbs", "total_carbohydrate_g",
        ) ?: fallback { "carb" in it && "goal" !in it }

        // Total fat only — saturated/trans/poly/mono splits and body-fat % must not bind here.
        val fat = exact("fat_g", "fat", "total_fat_g", "fats_g")
            ?: fallback {
                "fat" in it && "saturated" !in it && "trans" !in it && "poly" !in it &&
                    "mono" !in it && "body" !in it && "goal" !in it
            }

        val weightColumn = resolveWeightColumn(headers)
        val weight = weightColumn?.header

        if (calories == null && protein == null && carbs == null && fat == null && weight == null) {
            return null
        }
        return NutritionColumns(
            date, calories, protein, carbs, fat, weight,
            weightColumn?.unit ?: WeightUnit.AMBIGUOUS,
        )
    }

    /**
     * Resolve body-weight/body-mass without guessing its unit. Explicit-unit columns win over a bare
     * `weight`; conflicting kg/lb columns make the selected column ambiguous and therefore safe-skip
     * plain numeric cells.
     */
    internal fun resolveWeightColumn(headers: List<String>): WeightColumn? {
        val candidates = headers.filter {
            ("weight" in it || "body_mass" in it) && "goal" !in it
        }
        if (candidates.isEmpty()) return null

        val explicit = candidates.mapNotNull { header ->
            val unit = weightUnitFromNormalizedText(header)
            if (unit == WeightUnit.AMBIGUOUS) null else WeightColumn(header, unit)
        }
        if (explicit.map { it.unit }.toSet().size > 1) {
            return WeightColumn(candidates.first(), WeightUnit.AMBIGUOUS)
        }
        return explicit.firstOrNull() ?: WeightColumn(candidates.first(), WeightUnit.AMBIGUOUS)
    }

    /**
     * Parse one weight cell into kilograms. A unitless value under an ambiguous header, or a cell
     * whose explicit unit conflicts with its header, returns [WeightValue.Ambiguous] and is never
     * written. Invalid/non-positive numerics remain a separate non-warning result.
     */
    internal fun parseWeightKilograms(raw: String, headerUnit: WeightUnit, numeric: Double?): WeightValue {
        if (numeric == null || !numeric.isFinite() || numeric <= 0) return WeightValue.MissingOrInvalid
        val cellUnit = weightUnitFromCell(raw)
        val resolved = when {
            headerUnit != WeightUnit.AMBIGUOUS &&
                cellUnit != WeightUnit.AMBIGUOUS &&
                headerUnit != cellUnit -> return WeightValue.Ambiguous
            headerUnit != WeightUnit.AMBIGUOUS -> headerUnit
            cellUnit != WeightUnit.AMBIGUOUS -> cellUnit
            else -> return WeightValue.Ambiguous
        }
        val kilograms = if (resolved == WeightUnit.POUNDS) numeric * LB_TO_KG else numeric
        return WeightValue.Kilograms(kilograms)
    }

    private fun weightUnitFromNormalizedText(text: String): WeightUnit {
        val tokens = text.split('_').toSet()
        val kilograms = tokens.any { it == "kg" || it == "kgs" || it == "kilogram" || it == "kilograms" }
        val pounds = tokens.any { it == "lb" || it == "lbs" || it == "pound" || it == "pounds" }
        if (kilograms == pounds) return WeightUnit.AMBIGUOUS
        return if (kilograms) WeightUnit.KILOGRAMS else WeightUnit.POUNDS
    }

    private fun weightUnitFromCell(raw: String): WeightUnit {
        val lowered = raw.lowercase().trim()
        val tokenUnit = weightUnitFromNormalizedText(HeaderNorm.normalize(lowered))
        if (tokenUnit != WeightUnit.AMBIGUOUS) return tokenUnit

        // Compact forms such as `180lb` and `81.5kg` do not produce a standalone normalized token.
        val compact = lowered.replace(" ", "")
        val kgSuffix = listOf("kg", "kgs", "kilogram", "kilograms").any(compact::endsWith)
        val lbSuffix = listOf("lb", "lbs", "pound", "pounds").any(compact::endsWith)
        if (kgSuffix == lbSuffix) return WeightUnit.AMBIGUOUS
        return if (kgSuffix) WeightUnit.KILOGRAMS else WeightUnit.POUNDS
    }

    // MARK: - Pure row parsing (JVM unit-testable)

    private class DayAcc {
        var calories: Double? = null
        var protein: Double? = null
        var carbs: Double? = null
        var fat: Double? = null
        var weight: Double? = null
    }

    internal data class NutritionParseResult(
        val rows: List<MetricSeriesRow>,
        val ambiguousWeightRows: Int,
    )

    /**
     * CSV table → long-format metricSeries rows. Intake values SUM across rows that share a
     * day (per-meal exports); weight takes the day's last non-blank value. Rows with no
     * parsable date and blank/negative/non-finite cells are skipped.
     */
    internal fun parse(table: CsvTable, deviceId: String): List<MetricSeriesRow> {
        return parseDetailed(table, deviceId).rows
    }

    /** Detailed parse result used by import UI to disclose rejected ambiguous weight values. */
    internal fun parseDetailed(table: CsvTable, deviceId: String): NutritionParseResult {
        val cols = resolveColumns(table.normalizedHeaders)
            ?: return NutritionParseResult(emptyList(), ambiguousWeightRows = 0)

        val byDay = LinkedHashMap<String, DayAcc>()
        var ambiguousWeightRows = 0
        for (row in table.rows) {
            val day = parseDay(row.cell(cols.date)) ?: continue
            val acc = byDay.getOrPut(day) { DayAcc() }

            fun intake(header: String?, get: () -> Double?, put: (Double) -> Unit) {
                header ?: return
                val v = row.double(header) ?: return
                if (!v.isFinite() || v < 0) return
                put((get() ?: 0.0) + v)
            }
            intake(cols.calories, { acc.calories }) { acc.calories = it }
            intake(cols.protein, { acc.protein }) { acc.protein = it }
            intake(cols.carbs, { acc.carbs }) { acc.carbs = it }
            intake(cols.fat, { acc.fat }) { acc.fat = it }

            cols.weight?.let { header ->
                val rawCell = row.cell(header)
                if (rawCell != null) {
                    when (val weight = parseWeightKilograms(rawCell, cols.weightUnit, row.double(header))) {
                        is WeightValue.Kilograms -> acc.weight = weight.value
                        WeightValue.Ambiguous -> ambiguousWeightRows += 1
                        WeightValue.MissingOrInvalid -> Unit
                    }
                }
            }
        }

        val out = ArrayList<MetricSeriesRow>(byDay.size * 5)
        for ((day, acc) in byDay) {
            fun add(key: String, v: Double?) {
                if (v != null) out.add(MetricSeriesRow(deviceId, day, key, v))
            }
            add(KEY_CALORIES_IN, acc.calories)
            add(KEY_PROTEIN_G, acc.protein)
            add(KEY_CARBS_G, acc.carbs)
            add(KEY_FAT_G, acc.fat)
            add(KEY_WEIGHT, acc.weight)
        }
        return NutritionParseResult(out, ambiguousWeightRows)
    }

    // MARK: - Day parsing

    private val ISO_PREFIX = Regex("""^(\d{4})[-/](\d{1,2})[-/](\d{1,2})""")
    private val DMY_OR_MDY = Regex("""^(\d{1,2})[./-](\d{1,2})[./-](\d{4})""")

    /**
     * Parse a nutrition CSV date cell into "YYYY-MM-DD".
     *
     *   - "2026-06-01", "2026/6/1", "2026-06-01 08:30" → ISO prefix wins.
     *   - "06/02/2026" → month-first (US convention — MyFitnessPal et al), unless the first
     *     number is > 12 ("13/02/2026"), which forces day-first.
     *   - Full ISO-8601 datetimes (with Z / offsets) fall through to [WhoopTime] at UTC.
     */
    internal fun parseDay(raw: String?): String? {
        val s = raw?.trim() ?: return null
        if (s.isEmpty()) return null

        ISO_PREFIX.find(s)?.let { m ->
            val (y, mo, d) = m.destructured
            return validDay(y.toInt(), mo.toInt(), d.toInt())
        }
        DMY_OR_MDY.find(s)?.let { m ->
            val a = m.groupValues[1].toInt()
            val b = m.groupValues[2].toInt()
            val y = m.groupValues[3].toInt()
            // a > 12 can only be a day; otherwise default to US month-first.
            val (month, dayOfMonth) = if (a > 12) b to a else a to b
            return validDay(y, month, dayOfMonth)
        }
        WhoopTime.parseEpochSeconds(s, 0)?.let {
            return Instant.ofEpochSecond(it).atOffset(ZoneOffset.UTC).toLocalDate().toString()
        }
        return null
    }

    /** "YYYY-MM-DD" if the components form a real calendar date, else null. */
    private fun validDay(year: Int, month: Int, dayOfMonth: Int): String? = try {
        LocalDate.of(year, month, dayOfMonth).toString()
    } catch (_: Exception) {
        null
    }
}
