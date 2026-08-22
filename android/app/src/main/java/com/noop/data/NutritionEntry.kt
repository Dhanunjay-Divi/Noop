package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.text.NumberFormat
import java.text.ParsePosition
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale

/**
 * Editable nutrition source of truth. `metricSeries` can store only one scalar per nutrient/day;
 * this row preserves individual meals, stable edit/delete ids, time/type, notes, nullable nutrients,
 * and origin. [WhoopDao] projects daily sums under [NutritionLogContract.DEVICE_ID].
 *
 * Field order intentionally matches Swift Database.swift v39 and the shared schema oracle.
 */
@Entity(
    tableName = "nutritionEntry",
    indices = [
        Index(
            name = "idx_nutritionEntry_device_day_occurredAt",
            value = ["deviceId", "day", "occurredAt"],
        ),
        Index(
            name = "idx_nutritionEntry_device_origin_day",
            value = ["deviceId", "origin", "day"],
        ),
    ],
)
data class NutritionEntryRow(
    @PrimaryKey val id: String,
    val deviceId: String = NutritionLogContract.DEVICE_ID,
    val origin: String,
    val day: String,
    val occurredAt: Long,
    val mealType: String,
    val label: String? = null,
    val caloriesKcal: Double? = null,
    val proteinG: Double? = null,
    val carbsG: Double? = null,
    val fatG: Double? = null,
    val note: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

data class NutritionDailyTotals(
    val caloriesKcal: Double?,
    val proteinG: Double?,
    val carbsG: Double?,
    val fatG: Double?,
    val importedEntryCount: Int = 0,
    val manualEntryCount: Int = 0,
) {
    val hasImportedSummary: Boolean get() = importedEntryCount > 0
    val hasManualEntries: Boolean get() = manualEntryCount > 0
    val hasMixedSources: Boolean get() = hasImportedSummary && hasManualEntries
}

/** Stable cross-platform validation and import identifiers for [NutritionEntryRow]. */
object NutritionLogContract {
    private data class RecentSignature(
        val mealType: String,
        val label: String?,
        val caloriesKcal: Double?,
        val proteinG: Double?,
        val carbsG: Double?,
        val fatG: Double?,
    )

    const val DEVICE_ID = "nutrition-log"
    const val MANUAL_ORIGIN = "manual"
    const val CSV_ORIGIN = "nutrition-csv"

    const val CALORIES_KEY = "calories_in"
    const val PROTEIN_KEY = "protein_g"
    const val CARBS_KEY = "carbs_g"
    const val FAT_KEY = "fat_g"
    val NUTRIENT_KEYS = setOf(CALORIES_KEY, PROTEIN_KEY, CARBS_KEY, FAT_KEY)

    const val MAX_LABEL_CHARACTERS = 80
    const val MAX_NOTE_CHARACTERS = 500
    const val MAX_CALORIES_PER_ENTRY = 20_000.0
    const val MAX_MACRO_GRAMS_PER_ENTRY = 2_000.0

    val MEAL_TYPES = setOf("breakfast", "lunch", "dinner", "snack", "other", "daily_total")

    fun validated(row: NutritionEntryRow): NutritionEntryRow {
        val id = row.id.trim()
        require(id.isNotEmpty() && id.length <= 128) { "invalid nutrition entry id" }
        require(row.deviceId == DEVICE_ID) { "invalid nutrition device id" }
        require(row.origin == MANUAL_ORIGIN || row.origin == CSV_ORIGIN) {
            "invalid nutrition origin"
        }
        require(isValidDay(row.day)) { "invalid nutrition day" }
        require(row.occurredAt > 0L) { "invalid nutrition occurrence time" }
        require(row.mealType in MEAL_TYPES) { "invalid nutrition meal type" }
        require(row.createdAt > 0L && row.updatedAt >= row.createdAt) {
            "invalid nutrition timestamps"
        }

        validateNutrient(row.caloriesKcal, CALORIES_KEY, MAX_CALORIES_PER_ENTRY)
        validateNutrient(row.proteinG, PROTEIN_KEY, MAX_MACRO_GRAMS_PER_ENTRY)
        validateNutrient(row.carbsG, CARBS_KEY, MAX_MACRO_GRAMS_PER_ENTRY)
        validateNutrient(row.fatG, FAT_KEY, MAX_MACRO_GRAMS_PER_ENTRY)

        val label = boundedText(row.label, MAX_LABEL_CHARACTERS, singleLine = true)
        val note = boundedText(row.note, MAX_NOTE_CHARACTERS, singleLine = false)
        val hasNutrient =
            row.caloriesKcal != null || row.proteinG != null || row.carbsG != null || row.fatG != null
        require(hasNutrient || label != null || note != null) { "empty nutrition entry" }
        return row.copy(id = id, label = label, note = note)
    }

    fun csvEntryId(day: String): String = "$CSV_ORIGIN:$day"

    /** Stable noon-UTC instant for a daily import that contains no meal time. */
    fun importedOccurredAt(day: String): Long? =
        runCatching {
            val date = LocalDate.parse(day)
            if (date.toString() != day) return null
            date.atTime(12, 0).toEpochSecond(ZoneOffset.UTC)
        }.getOrNull()

    /**
     * Resolve one day without adding an imported whole-day summary to manual meals that summary
     * usually already includes. Imported values win per nutrient; manual sums fill missing fields.
     */
    fun resolvedTotals(
        entries: List<NutritionEntryRow>,
        day: String,
        deviceId: String = DEVICE_ID,
    ): NutritionDailyTotals {
        val dayRows = entries.filter { it.deviceId == deviceId && it.day == day }
        val imported = dayRows
            .filter { it.origin == CSV_ORIGIN }
            .sortedWith(compareByDescending<NutritionEntryRow> { it.updatedAt }.thenByDescending { it.id })
        val manual = dayRows.filter { it.origin == MANUAL_ORIGIN }

        fun importedValue(field: (NutritionEntryRow) -> Double?): Double? =
            imported.firstNotNullOfOrNull(field)

        fun manualSum(field: (NutritionEntryRow) -> Double?): Double? {
            val values = manual.mapNotNull(field)
            return if (values.isEmpty()) null else values.sum()
        }

        fun resolve(field: (NutritionEntryRow) -> Double?): Double? =
            importedValue(field) ?: manualSum(field)

        return NutritionDailyTotals(
            caloriesKcal = resolve { it.caloriesKcal },
            proteinG = resolve { it.proteinG },
            carbsG = resolve { it.carbsG },
            fatG = resolve { it.fatG },
            importedEntryCount = imported.size,
            manualEntryCount = manual.size,
        )
    }

    /** Newest unique manual meals suitable for one-action logging. Imported summaries are excluded. */
    fun recentManualEntries(
        entries: List<NutritionEntryRow>,
        limit: Int,
        deviceId: String = DEVICE_ID,
    ): List<NutritionEntryRow> {
        val safeLimit = limit.coerceIn(0, 20)
        if (safeLimit == 0) return emptyList()
        return entries
            .asSequence()
            .filter { it.deviceId == deviceId && it.origin == MANUAL_ORIGIN }
            .sortedWith(
                compareByDescending<NutritionEntryRow> { it.occurredAt }
                    .thenByDescending { it.updatedAt }
                    .thenByDescending { it.id },
            )
            .distinctBy {
                RecentSignature(
                    mealType = it.mealType,
                    label = it.label?.trim()?.lowercase(Locale.ROOT),
                    caloriesKcal = it.caloriesKcal,
                    proteinG = it.proteinG,
                    carbsG = it.carbsG,
                    fatG = it.fatG,
                )
            }
            .take(safeLimit)
            .toList()
    }

    /** Build a fresh manual row from a prior manual meal; whole-day imports cannot be repeated. */
    fun repeatedManualEntry(
        source: NutritionEntryRow,
        id: String,
        day: String,
        occurredAt: Long,
        timestamp: Long,
    ): NutritionEntryRow {
        require(source.origin == MANUAL_ORIGIN) {
            "imported nutrition entries cannot be repeated as meals"
        }
        return validated(
            NutritionEntryRow(
                id = id,
                origin = MANUAL_ORIGIN,
                day = day,
                occurredAt = occurredAt,
                mealType = source.mealType,
                label = source.label,
                caloriesKcal = source.caloriesKcal,
                proteinG = source.proteinG,
                carbsG = source.carbsG,
                fatG = source.fatG,
                note = source.note,
                createdAt = timestamp,
                updatedAt = timestamp,
            ),
        )
    }

    /** Parse the complete user value with locale separators; reject valid prefixes plus trailing text. */
    fun parseUserNumber(raw: String, locale: Locale = Locale.getDefault()): Double? {
        val clean = raw.trim()
        if (clean.isEmpty()) return null
        val position = ParsePosition(0)
        val number = NumberFormat.getNumberInstance(locale).apply {
            isParseIntegerOnly = false
        }.parse(clean, position) ?: return null
        if (position.index != clean.length) return null
        return number.toDouble().takeIf(Double::isFinite)
    }

    private fun validateNutrient(value: Double?, key: String, maximum: Double) {
        if (value == null) return
        require(value.isFinite() && value >= 0.0 && value <= maximum) {
            "invalid nutrition nutrient: $key"
        }
    }

    private fun isValidDay(day: String): Boolean =
        runCatching { LocalDate.parse(day).toString() == day }.getOrDefault(false)

    private fun boundedText(value: String?, maximum: Int, singleLine: Boolean): String? {
        val cleaned = value
            ?.mapNotNull { char ->
                when {
                    singleLine && (char == '\n' || char == '\r') -> ' '
                    Character.isISOControl(char) && !(char == '\n' && !singleLine) -> null
                    else -> char
                }
            }
            ?.joinToString("")
            ?.trim()
            ?.take(maximum)
        return cleaned?.takeIf { it.isNotEmpty() }
    }
}
