package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NutritionCatalogContractTest {
    private val now = 1_777_000_000L

    private fun item(
        id: String = "meal-oats",
        kind: String = NutritionCatalogContract.MEAL_KIND,
        name: String = "Overnight oats",
        barcode: String? = null,
        source: String = NutritionCatalogContract.MANUAL_SOURCE,
        saved: Boolean = true,
    ) = NutritionCatalogItemRow(
        id = id,
        kind = kind,
        name = name,
        brand = "  NOOP Kitchen  ",
        barcode = barcode,
        servingQuantity = 1.0,
        servingUnit = "bowl",
        caloriesKcal = 420.0,
        proteinG = 28.0,
        carbsG = 52.0,
        fatG = 12.0,
        mealType = "breakfast",
        source = source,
        isSaved = saved,
        createdAt = now,
        updatedAt = now,
    )

    @Test
    fun validationNormalizesBarcodeAndBoundsText() {
        val clean = NutritionCatalogContract.validated(
            item(
                id = "barcode:3017620422003",
                kind = NutritionCatalogContract.FOOD_KIND,
                name = "  Hazelnut spread\n",
                barcode = "3017-6204 22003",
                source = NutritionCatalogContract.OPEN_FOOD_FACTS_SOURCE,
                saved = false,
            ).copy(brand = "B".repeat(200)),
        )
        assertEquals("Hazelnut spread", clean.name)
        assertEquals("3017620422003", clean.barcode)
        assertEquals(NutritionCatalogContract.MAX_BRAND_CHARACTERS, clean.brand!!.length)
        assertEquals(
            "barcode:3017620422003",
            NutritionCatalogContract.barcodeId("3017620422003"),
        )
        assertThrows(IllegalArgumentException::class.java) {
            NutritionCatalogContract.barcodeId("not-a-code")
        }
    }

    @Test
    fun validationRejectsInvalidRangesKindsAndTimestamps() {
        assertThrows(IllegalArgumentException::class.java) {
            NutritionCatalogContract.validated(item(kind = "recipe"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NutritionCatalogContract.validated(item().copy(caloriesKcal = -1.0))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NutritionCatalogContract.validated(item().copy(servingQuantity = 0.0))
        }
        assertTrue(NutritionCatalogContract.normalizedBarcode("1234") != null)
        assertFalse(NutritionCatalogContract.normalizedBarcode("123") != null)
    }
}
