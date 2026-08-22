package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class OpenFoodFactsParserTest {
    @Test
    fun parsesServingNutrientsWithoutInventingMissingValues() {
        val item = OpenFoodFactsParser.parse(
            data = """
                {
                  "status": 1,
                  "product": {
                    "product_name": "Test yogurt",
                    "brands": "Example",
                    "serving_quantity": 150,
                    "serving_quantity_unit": "g",
                    "nutriments": {
                      "energy-kcal_serving": 120,
                      "proteins_serving": 12,
                      "fat_serving": 3.5
                    }
                  }
                }
            """.trimIndent(),
            rawBarcode = "3017620422003",
            now = 1_777_000_000,
        )

        assertEquals("barcode:3017620422003", item.id)
        assertEquals("Test yogurt", item.name)
        assertEquals(150.0, item.servingQuantity)
        assertEquals(120.0, item.caloriesKcal)
        assertEquals(12.0, item.proteinG)
        assertNull(item.carbsG)
        assertEquals(3.5, item.fatG)
    }

    @Test
    fun scalesPerHundredGramValuesToServing() {
        val item = OpenFoodFactsParser.parse(
            data = """
                {
                  "status": 1,
                  "product": {
                    "product_name": "Test cereal",
                    "serving_quantity": 40,
                    "serving_quantity_unit": "g",
                    "nutriments": {
                      "energy-kcal_100g": 400,
                      "proteins_100g": 10,
                      "carbohydrates_100g": 70
                    }
                  }
                }
            """.trimIndent(),
            rawBarcode = "12345678",
            now = 1_777_000_000,
        )

        assertEquals(160.0, item.caloriesKcal)
        assertEquals(4.0, item.proteinG)
        assertEquals(28.0, item.carbsG)
        assertNull(item.fatG)
    }

    @Test
    fun rejectsNotFoundAndMalformedProducts() {
        val notFound = assertThrows(NutritionBarcodeLookupException::class.java) {
            OpenFoodFactsParser.parse(
                """{"status":0}""",
                "3017620422003",
                1_777_000_000,
            )
        }
        assertEquals(NutritionBarcodeLookupFailure.ProductNotFound, notFound.failure)

        val malformed = assertThrows(NutritionBarcodeLookupException::class.java) {
            OpenFoodFactsParser.parse(
                """{"status":1,"product":{"product_name":12}}""",
                "3017620422003",
                1_777_000_000,
            )
        }
        assertEquals(NutritionBarcodeLookupFailure.InvalidResponse, malformed.failure)
    }
}
