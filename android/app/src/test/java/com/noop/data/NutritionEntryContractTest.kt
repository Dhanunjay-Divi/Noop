package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class NutritionEntryContractTest {
    private fun row(
        id: String = "meal-1",
        deviceId: String = NutritionLogContract.DEVICE_ID,
        day: String = "2026-08-22",
        origin: String = NutritionLogContract.MANUAL_ORIGIN,
        occurredAt: Long = 1_777_000_000,
        mealType: String = "lunch",
        label: String? = "Lunch",
        calories: Double? = null,
        protein: Double? = null,
        carbs: Double? = null,
        fat: Double? = null,
        note: String? = null,
    ) = NutritionEntryRow(
        id = id,
        deviceId = deviceId,
        origin = origin,
        day = day,
        occurredAt = occurredAt,
        mealType = mealType,
        label = label,
        caloriesKcal = calories,
        proteinG = protein,
        carbsG = carbs,
        fatG = fat,
        note = note,
        createdAt = 1_777_000_000,
        updatedAt = 1_777_000_100,
    )

    @Test
    fun trimsBoundsAndPreservesMissingNutrients() {
        val clean = NutritionLogContract.validated(
            row(
                label = "  ${"A".repeat(100)}\n ",
                protein = 25.0,
                note = "  useful note  ",
            ),
        )
        assertEquals(NutritionLogContract.MAX_LABEL_CHARACTERS, clean.label!!.length)
        assertFalse(clean.label!!.contains('\n'))
        assertEquals("useful note", clean.note)
        assertNull(clean.caloriesKcal)
        assertEquals(25.0, clean.proteinG)
        assertNull(clean.carbsG)
        assertNull(clean.fatG)
    }

    @Test
    fun rejectsEmptyNegativeInfiniteAndInvalidDayRows() {
        assertThrows(IllegalArgumentException::class.java) {
            NutritionLogContract.validated(row(label = null))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NutritionLogContract.validated(row(label = null, calories = -1.0))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NutritionLogContract.validated(row(label = null, protein = Double.POSITIVE_INFINITY))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NutritionLogContract.validated(row(day = "2026-02-31", calories = 100.0))
        }
    }

    @Test
    fun importedIdentityAndTimestampAreDeterministic() {
        assertEquals("nutrition-csv:2026-08-22", NutritionLogContract.csvEntryId("2026-08-22"))
        assertEquals(
            NutritionLogContract.importedOccurredAt("2026-08-22"),
            NutritionLogContract.importedOccurredAt("2026-08-22"),
        )
        assertTrue(NutritionLogContract.importedOccurredAt("2026-08-22")!! > 0L)
        assertNull(NutritionLogContract.importedOccurredAt("2026-02-31"))
    }

    @Test
    fun importedValuesWinPerNutrientWithoutDoubleCountingManualMeals() {
        val totals = NutritionLogContract.resolvedTotals(
            entries = listOf(
                row(
                    id = "imported",
                    origin = NutritionLogContract.CSV_ORIGIN,
                    mealType = "daily_total",
                    label = null,
                    calories = 1_900.0,
                    protein = 125.0,
                ),
                row(
                    id = "snack",
                    calories = 200.0,
                    protein = 10.0,
                    carbs = 40.0,
                ),
            ),
            day = "2026-08-22",
        )

        assertEquals(1_900.0, totals.caloriesKcal)
        assertEquals(125.0, totals.proteinG)
        assertEquals(40.0, totals.carbsG)
        assertEquals(1, totals.importedEntryCount)
        assertEquals(1, totals.manualEntryCount)
        assertTrue(totals.hasMixedSources)
    }

    @Test
    fun recentMealsDeduplicateAndImportedRowsCannotRepeat() {
        val imported = row(
            id = "imported",
            origin = NutritionLogContract.CSV_ORIGIN,
            occurredAt = 1_777_000_400,
            mealType = "daily_total",
            label = null,
            calories = 2_000.0,
        )
        val recent = NutritionLogContract.recentManualEntries(
            entries = listOf(
                row(id = "older", occurredAt = 1_777_000_100, label = "Oats", calories = 400.0),
                row(id = "newer", occurredAt = 1_777_000_300, label = " oats ", calories = 400.0),
                row(id = "shake", occurredAt = 1_777_000_200, label = "Shake", protein = 30.0),
                imported,
            ),
            limit = 4,
        )

        assertEquals(listOf("newer", "shake"), recent.map { it.id })
        val repeated = NutritionLogContract.repeatedManualEntry(
            source = recent.first(),
            id = "repeat",
            day = "2026-08-22",
            occurredAt = 1_787_395_200,
            timestamp = 1_787_395_200,
        )
        assertEquals("repeat", repeated.id)
        assertEquals(NutritionLogContract.MANUAL_ORIGIN, repeated.origin)
        assertEquals("oats", repeated.label)
        assertEquals(400.0, repeated.caloriesKcal)
        assertThrows(IllegalArgumentException::class.java) {
            NutritionLogContract.repeatedManualEntry(
                source = imported,
                id = "bad-repeat",
                day = "2026-08-22",
                occurredAt = 1_787_395_200,
                timestamp = 1_787_395_200,
            )
        }
    }

    @Test
    fun resolutionAndRecentsRespectTheRequestedDevice() {
        val secondaryDevice = "nutrition-secondary"
        val canonical = row(id = "canonical", calories = 400.0)
        val secondary = row(id = "secondary", deviceId = secondaryDevice, calories = 725.0)

        val totals = NutritionLogContract.resolvedTotals(
            entries = listOf(canonical, secondary),
            day = "2026-08-22",
            deviceId = secondaryDevice,
        )
        assertEquals(725.0, totals.caloriesKcal)
        assertEquals(1, totals.manualEntryCount)

        val recent = NutritionLogContract.recentManualEntries(
            entries = listOf(canonical, secondary),
            limit = 4,
            deviceId = secondaryDevice,
        )
        assertEquals(listOf("secondary"), recent.map { it.id })
    }

    @Test
    fun localeNumbersRequireACompleteValidParse() {
        assertEquals(
            1_200.5,
            NutritionLogContract.parseUserNumber("1,200.5", Locale.US),
        )
        assertEquals(
            1_200.5,
            NutritionLogContract.parseUserNumber("1.200,5", Locale.GERMANY),
        )
        assertEquals(
            1_200.5,
            NutritionLogContract.parseUserNumber("1\u202F200,5", Locale.FRANCE),
        )
        assertNull(NutritionLogContract.parseUserNumber("12 kcal", Locale.US))
        assertNull(NutritionLogContract.parseUserNumber("not a number", Locale.US))
    }
}
