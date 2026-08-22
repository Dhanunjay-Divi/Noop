package com.noop.data

import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

enum class NutritionBarcodeLookupFailure {
    InvalidBarcode,
    ProductNotFound,
    InvalidResponse,
    ServiceBusy,
    RequestFailed,
}

class NutritionBarcodeLookupException(
    val failure: NutritionBarcodeLookupFailure,
    cause: Throwable? = null,
) : IOException(failure.name, cause)

object OpenFoodFactsParser {
    fun parse(data: String, rawBarcode: String, now: Long): NutritionCatalogItemRow {
        val barcode = NutritionCatalogContract.normalizedBarcode(rawBarcode)
            ?: throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidBarcode)
        if (now <= 0L) {
            throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
        }
        val root = runCatching { JSONObject(data) }.getOrElse {
            throw NutritionBarcodeLookupException(
                NutritionBarcodeLookupFailure.InvalidResponse,
                it,
            )
        }
        if (root.optInt("status", 0) != 1) {
            throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.ProductNotFound)
        }
        val product = root.optJSONObject("product")
            ?: throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
        val name = product.strictOptionalString("product_name")?.trim().orEmpty()
        if (name.isEmpty()) {
            throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
        }
        val nutriments = product.optJSONObject("nutriments")
        val rawQuantity = product.strictOptionalDouble("serving_quantity")
            ?.takeIf { it.isFinite() && it > 0.0 }
        val hasServingNutrients = listOf(
            nutriments.strictOptionalDouble("energy-kcal_serving"),
            nutriments.strictOptionalDouble("proteins_serving"),
            nutriments.strictOptionalDouble("carbohydrates_serving"),
            nutriments.strictOptionalDouble("fat_serving"),
        ).any { it != null && it.isFinite() && it >= 0.0 }
        val quantity = rawQuantity ?: if (hasServingNutrients) 1.0 else 100.0
        val unit = product.strictOptionalString("serving_quantity_unit")
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: if (hasServingNutrients) "serving" else "g"

        fun nutrient(servingKey: String, per100Key: String): Double? {
            nutriments.strictOptionalDouble(servingKey)
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.let { return it }
            val per100 = nutriments.strictOptionalDouble(per100Key)
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?: return null
            return rawQuantity?.let { per100 * it / 100.0 } ?: per100
        }

        return NutritionCatalogContract.validated(
            NutritionCatalogItemRow(
                id = NutritionCatalogContract.barcodeId(barcode),
                kind = NutritionCatalogContract.FOOD_KIND,
                name = name,
                brand = product.strictOptionalString("brands"),
                barcode = barcode,
                servingQuantity = quantity,
                servingUnit = unit,
                caloriesKcal = nutrient("energy-kcal_serving", "energy-kcal_100g"),
                proteinG = nutrient("proteins_serving", "proteins_100g"),
                carbsG = nutrient("carbohydrates_serving", "carbohydrates_100g"),
                fatG = nutrient("fat_serving", "fat_100g"),
                mealType = "other",
                source = NutritionCatalogContract.OPEN_FOOD_FACTS_SOURCE,
                isSaved = false,
                createdAt = now,
                updatedAt = now,
            ),
        )
    }

    private fun JSONObject?.strictOptionalString(key: String): String? {
        if (this == null || !has(key) || isNull(key)) return null
        return get(key) as? String
            ?: throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
    }

    private fun JSONObject?.strictOptionalDouble(key: String): Double? {
        if (this == null || !has(key) || isNull(key)) return null
        val value = get(key)
        if (value !is Number) {
            throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
        }
        return value.toDouble().takeIf(Double::isFinite)
            ?: throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidResponse)
    }
}

object OpenFoodFactsClient {
    private const val MINIMUM_REQUEST_INTERVAL_MS = 4_100L
    private const val USER_AGENT =
        "NOOP/9.2.0 (https://github.com/Dhanunjay-Divi/Noop)"
    private val client = OkHttpClient()
    private val requestMutex = Mutex()
    private var lastRequestAtMs = 0L

    suspend fun product(rawBarcode: String): NutritionCatalogItemRow = requestMutex.withLock {
        val barcode = NutritionCatalogContract.normalizedBarcode(rawBarcode)
            ?: throw NutritionBarcodeLookupException(NutritionBarcodeLookupFailure.InvalidBarcode)
        val nowMs = System.currentTimeMillis()
        val remaining = MINIMUM_REQUEST_INTERVAL_MS - (nowMs - lastRequestAtMs)
        if (remaining > 0L) delay(remaining)
        lastRequestAtMs = System.currentTimeMillis()

        val url =
            "https://world.openfoodfacts.org/api/v2/product/$barcode.json" +
                "?fields=code,product_name,brands,serving_quantity," +
                "serving_quantity_unit,nutriments"
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", USER_AGENT)
            .header("Accept", "application/json")
            .build()
        val responseBody = try {
            withContext(Dispatchers.IO) {
                client.newCall(request).execute().use { response ->
                    if (response.code == 429) {
                        throw NutritionBarcodeLookupException(
                            NutritionBarcodeLookupFailure.ServiceBusy,
                        )
                    }
                    if (!response.isSuccessful) {
                        throw NutritionBarcodeLookupException(
                            NutritionBarcodeLookupFailure.RequestFailed,
                        )
                    }
                    response.body?.string()
                        ?: throw NutritionBarcodeLookupException(
                            NutritionBarcodeLookupFailure.InvalidResponse,
                        )
                }
            }
        } catch (error: NutritionBarcodeLookupException) {
            throw error
        } catch (error: IOException) {
            throw NutritionBarcodeLookupException(
                NutritionBarcodeLookupFailure.RequestFailed,
                error,
            )
        }
        OpenFoodFactsParser.parse(
            data = responseBody,
            rawBarcode = barcode,
            now = System.currentTimeMillis() / 1_000L,
        )
    }
}
