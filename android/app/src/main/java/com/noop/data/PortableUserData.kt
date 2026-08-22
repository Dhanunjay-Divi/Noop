package com.noop.data

import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets

/**
 * Open, versioned records that do not fit NOOP's WHOOP-shaped portable CSV files.
 *
 * The field names and validation rules are byte-for-byte schema peers of Swift
 * `WhoopStore.PortableUserData`. Unknown object keys are tolerated for additive evolution, while a
 * future schema version fails closed so an older app cannot silently discard newer fields.
 */
data class PortableUserData(
    val format: String = PortableUserDataCodec.FORMAT_ID,
    val schemaVersion: Int = PortableUserDataCodec.CURRENT_SCHEMA_VERSION,
    val exportedAt: Long,
    val nutritionEntries: List<NutritionEntryRow>,
    val nutritionCatalogItems: List<NutritionCatalogItemRow> = emptyList(),
    val strengthExercises: List<PortableStrengthExercise>,
    val strengthRoutines: List<StrengthRoutineRow>,
    val strengthRoutineExercises: List<StrengthRoutineExerciseRow>,
    val strengthSessions: List<StrengthSessionRow>,
    val strengthSets: List<StrengthSetRow>,
) {
    val recordCount: Int
        get() = nutritionEntries.size + nutritionCatalogItems.size +
            strengthExercises.size + strengthRoutines.size +
            strengthRoutineExercises.size + strengthSessions.size + strengthSets.size
}

/** Human-readable exercise shape: secondary muscles are a real JSON array, not JSON-in-JSON. */
data class PortableStrengthExercise(
    val id: String,
    val name: String,
    val primaryMuscle: String,
    val secondaryMuscles: List<String>,
    val equipment: String,
    val movementPattern: String,
    val isCustom: Boolean,
    val archivedAt: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
) {
    constructor(row: StrengthExerciseRow) : this(
        id = row.id,
        name = row.name,
        primaryMuscle = row.primaryMuscle,
        secondaryMuscles = requireNotNull(
            StrengthTrainingContract.secondaryMuscles(row.secondaryMusclesJSON),
        ) { "invalid secondary muscles for ${row.id}" },
        equipment = row.equipment,
        movementPattern = row.movementPattern,
        isCustom = row.isCustom,
        archivedAt = row.archivedAt,
        createdAt = row.createdAt,
        updatedAt = row.updatedAt,
    )

    fun toRow(): StrengthExerciseRow = StrengthExerciseRow(
        id = id,
        name = name,
        primaryMuscle = primaryMuscle,
        secondaryMusclesJSON = StrengthTrainingContract.encodeMuscles(secondaryMuscles),
        equipment = equipment,
        movementPattern = movementPattern,
        isCustom = isCustom,
        archivedAt = archivedAt,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )
}

data class PortableUserDataImportSummary(
    val nutritionEntries: Int,
    val nutritionCatalogItems: Int,
    val strengthExercises: Int,
    val strengthRoutines: Int,
    val strengthRoutineExercises: Int,
    val strengthSessions: Int,
    val strengthSets: Int,
) {
    val total: Int
        get() = nutritionEntries + nutritionCatalogItems + strengthExercises + strengthRoutines +
            strengthRoutineExercises + strengthSessions + strengthSets
}

object PortableUserDataCodec {
    const val FILE_NAME = "noop_user_data.json"
    const val FORMAT_ID = "noop.user-data"
    const val CURRENT_SCHEMA_VERSION = 2
    const val OLDEST_SUPPORTED_SCHEMA_VERSION = 1
    const val MAX_FILE_BYTES = 64 shl 20

    private const val MAX_ROWS_PER_COLLECTION = 500_000
    private const val MAX_TOTAL_ROWS = 1_000_000

    fun encode(payload: PortableUserData): ByteArray {
        val clean = validated(payload)
        return toJson(clean).toString(2).toByteArray(StandardCharsets.UTF_8)
    }

    fun decode(bytes: ByteArray): PortableUserData {
        require(bytes.size <= MAX_FILE_BYTES) {
            "NOOP user data is larger than the supported 64 MB portable-data limit"
        }
        val root = runCatching {
            JSONObject(String(bytes, StandardCharsets.UTF_8))
        }.getOrElse { throw IllegalArgumentException("invalid NOOP portable-data JSON", it) }
        return validated(
            PortableUserData(
                format = root.requiredString("format"),
                schemaVersion = root.requiredInt("schemaVersion"),
                exportedAt = root.requiredLong("exportedAt"),
                nutritionEntries = root.requiredObjectArray("nutritionEntries", ::decodeNutrition),
                nutritionCatalogItems = root.optionalObjectArray(
                    "nutritionCatalogItems",
                    ::decodeNutritionCatalogItem,
                ),
                strengthExercises = root.requiredObjectArray("strengthExercises", ::decodeExercise),
                strengthRoutines = root.requiredObjectArray("strengthRoutines", ::decodeRoutine),
                strengthRoutineExercises = root.requiredObjectArray(
                    "strengthRoutineExercises",
                    ::decodeRoutineExercise,
                ),
                strengthSessions = root.requiredObjectArray("strengthSessions", ::decodeSession),
                strengthSets = root.requiredObjectArray("strengthSets", ::decodeSet),
            ),
        )
    }

    /**
     * Normalize rows, reject duplicate identities/order cells, then verify the complete relationship
     * graph. Callers validate before opening a transaction and the transaction entry point validates
     * again, so malformed input can never produce a partial restore.
     */
    fun validated(payload: PortableUserData): PortableUserData {
        require(payload.format == FORMAT_ID) { "unsupported NOOP portable-data format" }
        require(payload.schemaVersion in OLDEST_SUPPORTED_SCHEMA_VERSION..CURRENT_SCHEMA_VERSION) {
            "unsupported NOOP portable-data schema ${payload.schemaVersion}"
        }
        require(payload.exportedAt > 0L) { "invalid portable-data export timestamp" }

        val counts = listOf(
            payload.nutritionEntries.size,
            payload.nutritionCatalogItems.size,
            payload.strengthExercises.size,
            payload.strengthRoutines.size,
            payload.strengthRoutineExercises.size,
            payload.strengthSessions.size,
            payload.strengthSets.size,
        )
        require(counts.all { it <= MAX_ROWS_PER_COLLECTION } && counts.sum() <= MAX_TOTAL_ROWS) {
            "NOOP portable data exceeds the supported record limit"
        }

        val nutrition = payload.nutritionEntries.map(NutritionLogContract::validated)
        val nutritionCatalog =
            payload.nutritionCatalogItems.map(NutritionCatalogContract::validated)
        val exerciseRows = payload.strengthExercises.map {
            StrengthTrainingContract.validated(it.toRow())
        }
        val exercises = exerciseRows.map(::PortableStrengthExercise)
        val routines = payload.strengthRoutines.map(StrengthTrainingContract::validated)
        val routineExercises =
            payload.strengthRoutineExercises.map(StrengthTrainingContract::validated)
        val sessions = payload.strengthSessions.map(StrengthTrainingContract::validated)
        val sets = payload.strengthSets.map(StrengthTrainingContract::validated)

        requireUnique(nutrition.map { it.id }, "nutritionEntries")
        requireUnique(nutritionCatalog.map { it.id }, "nutritionCatalogItems")
        requireUnique(nutritionCatalog.mapNotNull { it.barcode }, "nutritionCatalogItems.barcode")
        requireUnique(exercises.map { it.id }, "strengthExercises")
        requireUnique(routines.map { it.id }, "strengthRoutines")
        requireUnique(routineExercises.map { it.id }, "strengthRoutineExercises")
        requireUnique(sessions.map { it.id }, "strengthSessions")
        requireUnique(sets.map { it.id }, "strengthSets")

        val exerciseIds = exercises.mapTo(HashSet()) { it.id }
        val routineIds = routines.mapTo(HashSet()) { it.id }
        val sessionIds = sessions.mapTo(HashSet()) { it.id }
        val routinePositions = HashSet<Pair<String, Int>>()
        for (row in routineExercises) {
            require(row.routineId in routineIds && row.exerciseId in exerciseIds) {
                "broken strengthRoutineExercises relationship"
            }
            require(routinePositions.add(row.routineId to row.position)) {
                "duplicate strengthRoutineExercises position"
            }
        }
        for (row in sessions) {
            require(row.routineId == null || row.routineId in routineIds) {
                "broken strengthSessions relationship"
            }
        }
        val setPositions = HashSet<Triple<String, Int, Int>>()
        for (row in sets) {
            require(row.sessionId in sessionIds && row.exerciseId in exerciseIds) {
                "broken strengthSets relationship"
            }
            require(
                setPositions.add(Triple(row.sessionId, row.exercisePosition, row.setPosition)),
            ) { "duplicate strengthSets position" }
        }

        return payload.copy(
            schemaVersion = CURRENT_SCHEMA_VERSION,
            nutritionEntries = nutrition.sortedWith(
                compareBy({ it.day }, { it.occurredAt }, { it.id }),
            ),
            nutritionCatalogItems = nutritionCatalog.sortedBy { it.id },
            strengthExercises = exercises.sortedBy { it.id },
            strengthRoutines = routines.sortedBy { it.id },
            strengthRoutineExercises = routineExercises.sortedWith(
                compareBy({ it.routineId }, { it.position }, { it.id }),
            ),
            strengthSessions = sessions.sortedWith(compareBy({ it.startedAt }, { it.id })),
            strengthSets = sets.sortedWith(
                compareBy({ it.sessionId }, { it.exercisePosition }, { it.setPosition }, { it.id }),
            ),
        )
    }

    private fun requireUnique(ids: List<String>, category: String) {
        require(ids.toSet().size == ids.size) { "duplicate identifiers in $category" }
    }

    private fun toJson(payload: PortableUserData): JSONObject = JSONObject()
        .put("format", payload.format)
        .put("schemaVersion", payload.schemaVersion)
        .put("exportedAt", payload.exportedAt)
        .put("nutritionEntries", JSONArray().also { out ->
            payload.nutritionEntries.forEach { out.put(encodeNutrition(it)) }
        })
        .put("nutritionCatalogItems", JSONArray().also { out ->
            payload.nutritionCatalogItems.forEach { out.put(encodeNutritionCatalogItem(it)) }
        })
        .put("strengthExercises", JSONArray().also { out ->
            payload.strengthExercises.forEach { out.put(encodeExercise(it)) }
        })
        .put("strengthRoutines", JSONArray().also { out ->
            payload.strengthRoutines.forEach { out.put(encodeRoutine(it)) }
        })
        .put("strengthRoutineExercises", JSONArray().also { out ->
            payload.strengthRoutineExercises.forEach { out.put(encodeRoutineExercise(it)) }
        })
        .put("strengthSessions", JSONArray().also { out ->
            payload.strengthSessions.forEach { out.put(encodeSession(it)) }
        })
        .put("strengthSets", JSONArray().also { out ->
            payload.strengthSets.forEach { out.put(encodeSet(it)) }
        })

    private fun encodeNutrition(row: NutritionEntryRow): JSONObject = JSONObject()
        .put("id", row.id)
        .put("deviceId", row.deviceId)
        .put("origin", row.origin)
        .put("day", row.day)
        .put("occurredAt", row.occurredAt)
        .put("mealType", row.mealType)
        .putOptional("label", row.label)
        .putOptional("caloriesKcal", row.caloriesKcal)
        .putOptional("proteinG", row.proteinG)
        .putOptional("carbsG", row.carbsG)
        .putOptional("fatG", row.fatG)
        .putOptional("note", row.note)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeNutritionCatalogItem(row: NutritionCatalogItemRow): JSONObject = JSONObject()
        .put("id", row.id)
        .put("kind", row.kind)
        .put("name", row.name)
        .putOptional("brand", row.brand)
        .putOptional("barcode", row.barcode)
        .putOptional("servingQuantity", row.servingQuantity)
        .putOptional("servingUnit", row.servingUnit)
        .putOptional("caloriesKcal", row.caloriesKcal)
        .putOptional("proteinG", row.proteinG)
        .putOptional("carbsG", row.carbsG)
        .putOptional("fatG", row.fatG)
        .put("mealType", row.mealType)
        .put("source", row.source)
        .put("isSaved", row.isSaved)
        .putOptional("lastUsedAt", row.lastUsedAt)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeExercise(row: PortableStrengthExercise): JSONObject = JSONObject()
        .put("id", row.id)
        .put("name", row.name)
        .put("primaryMuscle", row.primaryMuscle)
        .put("secondaryMuscles", JSONArray(row.secondaryMuscles))
        .put("equipment", row.equipment)
        .put("movementPattern", row.movementPattern)
        .put("isCustom", row.isCustom)
        .putOptional("archivedAt", row.archivedAt)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeRoutine(row: StrengthRoutineRow): JSONObject = JSONObject()
        .put("id", row.id)
        .put("name", row.name)
        .putOptional("note", row.note)
        .putOptional("archivedAt", row.archivedAt)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeRoutineExercise(row: StrengthRoutineExerciseRow): JSONObject = JSONObject()
        .put("id", row.id)
        .put("routineId", row.routineId)
        .put("exerciseId", row.exerciseId)
        .put("position", row.position)
        .put("targetSets", row.targetSets)
        .putOptional("targetRepsMin", row.targetRepsMin)
        .putOptional("targetRepsMax", row.targetRepsMax)
        .putOptional("targetRPE", row.targetRPE)
        .put("restSeconds", row.restSeconds)
        .putOptional("note", row.note)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeSession(row: StrengthSessionRow): JSONObject = JSONObject()
        .put("id", row.id)
        .putOptional("routineId", row.routineId)
        .putOptional("name", row.name)
        .put("startedAt", row.startedAt)
        .putOptional("endedAt", row.endedAt)
        .putOptional("note", row.note)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun encodeSet(row: StrengthSetRow): JSONObject = JSONObject()
        .put("id", row.id)
        .put("sessionId", row.sessionId)
        .put("exerciseId", row.exerciseId)
        .put("exercisePosition", row.exercisePosition)
        .put("setPosition", row.setPosition)
        .put("setType", row.setType)
        .putOptional("reps", row.reps)
        .putOptional("loadKg", row.loadKg)
        .putOptional("durationS", row.durationS)
        .putOptional("rpe", row.rpe)
        .putOptional("restSeconds", row.restSeconds)
        .putOptional("completedAt", row.completedAt)
        .putOptional("note", row.note)
        .put("createdAt", row.createdAt)
        .put("updatedAt", row.updatedAt)

    private fun decodeNutrition(o: JSONObject) = NutritionEntryRow(
        id = o.requiredString("id"),
        deviceId = o.requiredString("deviceId"),
        origin = o.requiredString("origin"),
        day = o.requiredString("day"),
        occurredAt = o.requiredLong("occurredAt"),
        mealType = o.requiredString("mealType"),
        label = o.optionalString("label"),
        caloriesKcal = o.optionalDouble("caloriesKcal"),
        proteinG = o.optionalDouble("proteinG"),
        carbsG = o.optionalDouble("carbsG"),
        fatG = o.optionalDouble("fatG"),
        note = o.optionalString("note"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeNutritionCatalogItem(o: JSONObject) = NutritionCatalogItemRow(
        id = o.requiredString("id"),
        kind = o.requiredString("kind"),
        name = o.requiredString("name"),
        brand = o.optionalString("brand"),
        barcode = o.optionalString("barcode"),
        servingQuantity = o.optionalDouble("servingQuantity"),
        servingUnit = o.optionalString("servingUnit"),
        caloriesKcal = o.optionalDouble("caloriesKcal"),
        proteinG = o.optionalDouble("proteinG"),
        carbsG = o.optionalDouble("carbsG"),
        fatG = o.optionalDouble("fatG"),
        mealType = o.requiredString("mealType"),
        source = o.requiredString("source"),
        isSaved = o.requiredBoolean("isSaved"),
        lastUsedAt = o.optionalLong("lastUsedAt"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeExercise(o: JSONObject) = PortableStrengthExercise(
        id = o.requiredString("id"),
        name = o.requiredString("name"),
        primaryMuscle = o.requiredString("primaryMuscle"),
        secondaryMuscles = o.requiredStringArray("secondaryMuscles"),
        equipment = o.requiredString("equipment"),
        movementPattern = o.requiredString("movementPattern"),
        isCustom = o.requiredBoolean("isCustom"),
        archivedAt = o.optionalLong("archivedAt"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeRoutine(o: JSONObject) = StrengthRoutineRow(
        id = o.requiredString("id"),
        name = o.requiredString("name"),
        note = o.optionalString("note"),
        archivedAt = o.optionalLong("archivedAt"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeRoutineExercise(o: JSONObject) = StrengthRoutineExerciseRow(
        id = o.requiredString("id"),
        routineId = o.requiredString("routineId"),
        exerciseId = o.requiredString("exerciseId"),
        position = o.requiredInt("position"),
        targetSets = o.requiredInt("targetSets"),
        targetRepsMin = o.optionalInt("targetRepsMin"),
        targetRepsMax = o.optionalInt("targetRepsMax"),
        targetRPE = o.optionalDouble("targetRPE"),
        restSeconds = o.requiredInt("restSeconds"),
        note = o.optionalString("note"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeSession(o: JSONObject) = StrengthSessionRow(
        id = o.requiredString("id"),
        routineId = o.optionalString("routineId"),
        name = o.optionalString("name"),
        startedAt = o.requiredLong("startedAt"),
        endedAt = o.optionalLong("endedAt"),
        note = o.optionalString("note"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun decodeSet(o: JSONObject) = StrengthSetRow(
        id = o.requiredString("id"),
        sessionId = o.requiredString("sessionId"),
        exerciseId = o.requiredString("exerciseId"),
        exercisePosition = o.requiredInt("exercisePosition"),
        setPosition = o.requiredInt("setPosition"),
        setType = o.requiredString("setType"),
        reps = o.optionalInt("reps"),
        loadKg = o.optionalDouble("loadKg"),
        durationS = o.optionalInt("durationS"),
        rpe = o.optionalDouble("rpe"),
        restSeconds = o.optionalInt("restSeconds"),
        completedAt = o.optionalLong("completedAt"),
        note = o.optionalString("note"),
        createdAt = o.requiredLong("createdAt"),
        updatedAt = o.requiredLong("updatedAt"),
    )

    private fun JSONObject.putOptional(key: String, value: Any?): JSONObject {
        if (value != null) put(key, value)
        return this
    }

    private fun JSONObject.rawRequired(key: String): Any {
        require(has(key) && !isNull(key)) { "missing required field: $key" }
        return get(key)
    }

    private fun JSONObject.requiredString(key: String): String =
        (rawRequired(key) as? String) ?: throw IllegalArgumentException("$key must be a string")

    private fun JSONObject.optionalString(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return (get(key) as? String) ?: throw IllegalArgumentException("$key must be a string")
    }

    private fun JSONObject.requiredBoolean(key: String): Boolean =
        (rawRequired(key) as? Boolean) ?: throw IllegalArgumentException("$key must be a boolean")

    private fun JSONObject.requiredLong(key: String): Long = strictLong(rawRequired(key), key)

    private fun JSONObject.optionalLong(key: String): Long? {
        if (!has(key) || isNull(key)) return null
        return strictLong(get(key), key)
    }

    private fun JSONObject.requiredInt(key: String): Int =
        strictLong(rawRequired(key), key).also {
            require(it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) { "$key is outside Int range" }
        }.toInt()

    private fun JSONObject.optionalInt(key: String): Int? {
        val value = optionalLong(key) ?: return null
        require(value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
            "$key is outside Int range"
        }
        return value.toInt()
    }

    private fun strictLong(value: Any, key: String): Long = when (value) {
        is Byte, is Short, is Int, is Long -> (value as Number).toLong()
        else -> throw IllegalArgumentException("$key must be an integer")
    }

    private fun JSONObject.optionalDouble(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        val value = get(key)
        require(value is Number) { "$key must be a number" }
        return value.toDouble().also { require(it.isFinite()) { "$key must be finite" } }
    }

    private fun JSONObject.requiredStringArray(key: String): List<String> {
        val array = rawRequired(key) as? JSONArray
            ?: throw IllegalArgumentException("$key must be an array")
        return List(array.length()) { index ->
            array.get(index) as? String
                ?: throw IllegalArgumentException("$key[$index] must be a string")
        }
    }

    private fun <T> JSONObject.requiredObjectArray(
        key: String,
        decode: (JSONObject) -> T,
    ): List<T> {
        val array = rawRequired(key) as? JSONArray
            ?: throw IllegalArgumentException("$key must be an array")
        return List(array.length()) { index ->
            val objectValue = array.get(index) as? JSONObject
                ?: throw IllegalArgumentException("$key[$index] must be an object")
            decode(objectValue)
        }
    }

    private fun <T> JSONObject.optionalObjectArray(
        key: String,
        decode: (JSONObject) -> T,
    ): List<T> {
        if (!has(key) || isNull(key)) return emptyList()
        val array = get(key) as? JSONArray
            ?: throw IllegalArgumentException("$key must be an array")
        return List(array.length()) { index ->
            val objectValue = array.get(index) as? JSONObject
                ?: throw IllegalArgumentException("$key[$index] must be an object")
            decode(objectValue)
        }
    }
}
