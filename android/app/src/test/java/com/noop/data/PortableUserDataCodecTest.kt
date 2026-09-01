package com.noop.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PortableUserDataCodecTest {
    private val now = 1_777_000_000L

    private fun payload(): PortableUserData {
        val exercise = StrengthExerciseRow(
            id = "custom_split_squat",
            name = "Split Squat",
            primaryMuscle = "quadriceps",
            secondaryMusclesJSON = """["glutes"]""",
            equipment = "dumbbell",
            movementPattern = "lunge",
            isCustom = true,
            createdAt = now,
            updatedAt = now + 100,
        )
        val routine = StrengthRoutineRow(
            id = "routine-1",
            name = "Lower A",
            note = "Controlled tempo",
            scheduledWeekdaysJSON = "[1,4]",
            createdAt = now,
            updatedAt = now + 100,
        )
        val session = StrengthSessionRow(
            id = "session-1",
            routineId = routine.id,
            name = "Lower A",
            startedAt = now + 1_000,
            endedAt = now + 2_800,
            note = "Felt strong",
            createdAt = now + 1_000,
            updatedAt = now + 2_800,
        )
        return PortableUserData(
            exportedAt = now + 3_000,
            nutritionEntries = listOf(
                NutritionEntryRow(
                    id = "meal-1",
                    origin = NutritionLogContract.MANUAL_ORIGIN,
                    day = "2026-08-22",
                    occurredAt = now,
                    mealType = "lunch",
                    label = "Tofu bowl",
                    proteinG = 30.0,
                    note = "No fabricated macros",
                    createdAt = now,
                    updatedAt = now + 100,
                ),
            ),
            nutritionCatalogItems = listOf(
                NutritionCatalogItemRow(
                    id = "meal:tofu-bowl",
                    kind = NutritionCatalogContract.MEAL_KIND,
                    name = "Tofu bowl",
                    caloriesKcal = 640.0,
                    proteinG = 30.0,
                    mealType = "lunch",
                    source = NutritionCatalogContract.MANUAL_SOURCE,
                    isSaved = true,
                    createdAt = now,
                    updatedAt = now + 100,
                ),
            ),
            strengthExercises = listOf(PortableStrengthExercise(exercise)),
            strengthRoutines = listOf(routine),
            strengthRoutineExercises = listOf(
                StrengthRoutineExerciseRow(
                    id = "routine-exercise-1",
                    routineId = routine.id,
                    exerciseId = exercise.id,
                    position = 0,
                    targetSets = 3,
                    targetRepsMin = 8,
                    targetRepsMax = 10,
                    targetRPE = 8.0,
                    restSeconds = 120,
                    planJSON = StrengthTrainingContract.encodeExercisePlan(
                        StrengthExercisePlan(
                            targetLoadKg = 24.0,
                            warmupSets = 2,
                            supersetGroup = 1,
                            setStyle = "drop",
                            dropPercent = 20,
                        ),
                    ),
                    createdAt = now,
                    updatedAt = now + 100,
                ),
            ),
            strengthSessions = listOf(session),
            strengthSets = listOf(
                StrengthSetRow(
                    id = "set-1",
                    sessionId = session.id,
                    exerciseId = exercise.id,
                    exercisePosition = 0,
                    setPosition = 0,
                    reps = 9,
                    loadKg = 24.0,
                    rpe = 8.5,
                    restSeconds = 120,
                    completedAt = now + 1_300,
                    note = "Each side",
                    createdAt = now + 1_000,
                    updatedAt = now + 2_800,
                ),
            ),
        )
    }

    @Test
    fun readableRoundTripPreservesNullsAndCompleteGraph() {
        val original = PortableUserDataCodec.validated(payload())
        val bytes = PortableUserDataCodec.encode(original)
        val text = bytes.toString(Charsets.UTF_8)

        assertTrue(text.contains("\"format\": \"noop.user-data\""))
        assertTrue(text.contains("\"schemaVersion\": 2"))
        assertTrue(text.contains("\"secondaryMuscles\": ["))
        assertFalse(text.contains("secondaryMusclesJSON"))
        assertFalse(
            JSONObject(text)
                .getJSONArray("nutritionEntries")
                .getJSONObject(0)
                .has("caloriesKcal"),
        )

        val decoded = PortableUserDataCodec.decode(bytes)
        assertEquals(original, decoded)
        assertNull(decoded.nutritionEntries.single().caloriesKcal)
        assertEquals(30.0, decoded.nutritionEntries.single().proteinG)
        assertEquals("Tofu bowl", decoded.nutritionCatalogItems.single().name)
        assertEquals(8.0, decoded.strengthRoutineExercises.single().targetRPE)
        assertEquals("[1,4]", decoded.strengthRoutines.single().scheduledWeekdaysJSON)
        assertEquals(
            "drop",
            StrengthTrainingContract.exercisePlan(
                decoded.strengthRoutineExercises.single().planJSON,
            ).setStyle,
        )
        assertEquals(120, decoded.strengthSets.single().restSeconds)
        assertEquals(8.5, decoded.strengthSets.single().rpe)
    }

    @Test
    fun rejectsFutureSchemaDuplicateIdsPositionsAndBrokenReferences() {
        assertThrows(IllegalArgumentException::class.java) {
            PortableUserDataCodec.validated(payload().copy(schemaVersion = 3))
        }
        assertThrows(IllegalArgumentException::class.java) {
            val row = payload().nutritionEntries.single()
            PortableUserDataCodec.validated(
                payload().copy(nutritionEntries = listOf(row, row)),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            val first = payload().strengthSets.single()
            PortableUserDataCodec.validated(
                payload().copy(strengthSets = listOf(first, first.copy(id = "set-2"))),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            PortableUserDataCodec.validated(
                payload().copy(
                    strengthSets = listOf(
                        payload().strengthSets.single().copy(exerciseId = "missing"),
                    ),
                ),
            )
        }
    }

    @Test
    fun decoderRejectsWrongJsonTypesWithoutCoercion() {
        val root = JSONObject(String(PortableUserDataCodec.encode(payload()), Charsets.UTF_8))
        root.put("exportedAt", "1777003000")
        assertThrows(IllegalArgumentException::class.java) {
            PortableUserDataCodec.decode(root.toString().toByteArray())
        }

        val validRoot = JSONObject(String(PortableUserDataCodec.encode(payload()), Charsets.UTF_8))
        validRoot.getJSONArray("strengthExercises").getJSONObject(0).put("isCustom", "true")
        assertThrows(IllegalArgumentException::class.java) {
            PortableUserDataCodec.decode(validRoot.toString().toByteArray())
        }
    }

    @Test
    fun decodesSwiftCompatibleCamelCaseFixture() {
        val decoded = PortableUserDataCodec.decode(
            """
            {
              "exportedAt": 1777003000,
              "format": "noop.user-data",
              "nutritionEntries": [{
                "createdAt": 1777000000,
                "day": "2026-08-22",
                "deviceId": "nutrition-log",
                "id": "swift-meal",
                "mealType": "lunch",
                "occurredAt": 1777000000,
                "origin": "manual",
                "proteinG": 25,
                "updatedAt": 1777000100
              }],
              "schemaVersion": 1,
              "strengthExercises": [],
              "strengthRoutineExercises": [],
              "strengthRoutines": [],
              "strengthSessions": [],
              "strengthSets": []
            }
            """.trimIndent().toByteArray(),
        )
        assertEquals("swift-meal", decoded.nutritionEntries.single().id)
        assertEquals(25.0, decoded.nutritionEntries.single().proteinG)
        assertNull(decoded.nutritionEntries.single().caloriesKcal)
        assertEquals(2, decoded.schemaVersion)
        assertTrue(decoded.nutritionCatalogItems.isEmpty())
    }
}
