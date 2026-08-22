package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "nutritionCatalogItem",
    indices = [
        Index(
            name = "idx_nutritionCatalogItem_barcode",
            value = ["barcode"],
            unique = true,
        ),
        Index(
            name = "idx_nutritionCatalogItem_saved_used",
            value = ["isSaved", "lastUsedAt", "updatedAt"],
        ),
    ],
)
data class NutritionCatalogItemRow(
    @PrimaryKey val id: String,
    val kind: String,
    val name: String,
    val brand: String? = null,
    val barcode: String? = null,
    val servingQuantity: Double? = null,
    val servingUnit: String? = null,
    val caloriesKcal: Double? = null,
    val proteinG: Double? = null,
    val carbsG: Double? = null,
    val fatG: Double? = null,
    val mealType: String = "other",
    val source: String,
    val isSaved: Boolean,
    val lastUsedAt: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
)

object NutritionCatalogContract {
    const val FOOD_KIND = "food"
    const val MEAL_KIND = "meal"
    const val MANUAL_SOURCE = "manual"
    const val OPEN_FOOD_FACTS_SOURCE = "open_food_facts"

    const val MAX_NAME_CHARACTERS = 160
    const val MAX_BRAND_CHARACTERS = 120
    const val MAX_SERVING_UNIT_CHARACTERS = 40
    const val MAX_SERVING_QUANTITY = 100_000.0

    fun normalizedBarcode(raw: String): String? {
        val compact = raw.filterNot { it.isWhitespace() || it == '-' }
        return compact.takeIf { it.length in 4..32 && it.all(Char::isDigit) }
    }

    fun barcodeId(raw: String): String =
        "barcode:${requireNotNull(normalizedBarcode(raw)) { "invalid barcode" }}"

    fun validated(row: NutritionCatalogItemRow): NutritionCatalogItemRow {
        val id = row.id.trim()
        require(id.isNotEmpty() && id.length <= 128) { "invalid nutrition catalog id" }
        require(row.kind == FOOD_KIND || row.kind == MEAL_KIND) {
            "invalid nutrition catalog kind"
        }
        val name = boundedText(row.name, MAX_NAME_CHARACTERS)
        require(name != null) { "nutrition catalog name is required" }
        val brand = boundedText(row.brand, MAX_BRAND_CHARACTERS)
        val barcode = row.barcode?.let {
            requireNotNull(normalizedBarcode(it)) { "invalid barcode" }
        }
        val servingUnit = boundedText(row.servingUnit, MAX_SERVING_UNIT_CHARACTERS)
        row.servingQuantity?.let {
            require(it.isFinite() && it > 0.0 && it <= MAX_SERVING_QUANTITY) {
                "invalid serving quantity"
            }
        }
        require(row.mealType in NutritionLogContract.MEAL_TYPES && row.mealType != "daily_total") {
            "invalid nutrition catalog meal type"
        }
        require(row.source == MANUAL_SOURCE || row.source == OPEN_FOOD_FACTS_SOURCE) {
            "invalid nutrition catalog source"
        }
        require(
            row.createdAt > 0L &&
                row.updatedAt >= row.createdAt &&
                (row.lastUsedAt == null || row.lastUsedAt > 0L),
        ) { "invalid nutrition catalog timestamps" }

        validateNutrient(
            row.caloriesKcal,
            NutritionLogContract.MAX_CALORIES_PER_ENTRY,
            NutritionLogContract.CALORIES_KEY,
        )
        validateNutrient(
            row.proteinG,
            NutritionLogContract.MAX_MACRO_GRAMS_PER_ENTRY,
            NutritionLogContract.PROTEIN_KEY,
        )
        validateNutrient(
            row.carbsG,
            NutritionLogContract.MAX_MACRO_GRAMS_PER_ENTRY,
            NutritionLogContract.CARBS_KEY,
        )
        validateNutrient(
            row.fatG,
            NutritionLogContract.MAX_MACRO_GRAMS_PER_ENTRY,
            NutritionLogContract.FAT_KEY,
        )
        return row.copy(
            id = id,
            name = name,
            brand = brand,
            barcode = barcode,
            servingUnit = servingUnit,
        )
    }

    private fun validateNutrient(value: Double?, maximum: Double, key: String) {
        if (value == null) return
        require(value.isFinite() && value >= 0.0 && value <= maximum) {
            "invalid nutrition catalog nutrient: $key"
        }
    }

    private fun boundedText(value: String?, maximum: Int): String? =
        value
            ?.mapNotNull { char ->
                when {
                    char == '\n' || char == '\r' -> ' '
                    Character.isISOControl(char) -> null
                    else -> char
                }
            }
            ?.joinToString("")
            ?.trim()
            ?.take(maximum)
            ?.takeIf(String::isNotEmpty)
}
