package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source and resource contracts for the production Strength Trainer. */
class StrengthTrainerUiContractTest {
    private fun source(relative: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/$relative"),
            File(root, "app/src/main/java/com/noop/ui/$relative"),
            File(root, "android/app/src/main/java/com/noop/ui/$relative"),
        ).firstOrNull(File::isFile)?.readText()
    }

    private fun resource(relative: String): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/res/$relative"),
            File(root, "app/src/main/res/$relative"),
            File(root, "android/app/src/main/res/$relative"),
        ).firstOrNull(File::isFile)
    }

    private fun strengthStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(strength_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    @Test
    fun workoutsEntryAndHonestManualContractStayMounted() {
        val workouts = source("WorkoutsScreen.kt")
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("Strength sources unavailable", workouts != null && trainer != null)

        assertTrue(workouts!!.contains("showStrengthTrainer = true"))
        assertTrue(workouts.contains("R.string.strength_title"))
        assertTrue(trainer!!.contains("R.string.strength_manual_authority_body"))
        assertTrue(trainer.contains("R.string.strength_numbers_meaning_body"))
        assertTrue(trainer.contains("containerColor = Palette.surfaceBase"))
        assertTrue(trainer.contains("LiquidScreenSky(fillHeight = true)"))
        assertFalse(trainer.contains("SceneScreenBackground(maxAlpha = 0.82f)"))
        assertTrue(trainer.contains("Icons.Filled.Bedtime"))
        assertFalse(trainer.contains("Text(\""))
        assertFalse(trainer.contains("contentDescription = \""))
    }

    @Test
    fun editorCannotDismissBeforeAConfirmedSave() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)
        val text = trainer!!

        assertTrue(text.contains("target != SheetValue.Hidden"))
        assertTrue(text.contains("routineEditor == null &&"))
        assertTrue(text.contains("!programBuilder &&"))
        assertTrue(text.contains("!customExerciseEditor"))
        assertTrue(text.contains("onDismiss()"))
        assertTrue(text.contains("if (persist() != null) onClose()"))
        assertTrue(text.contains("var pendingSave by remember"))
        assertTrue(text.contains("} while (pendingSave)"))
        assertTrue(text.contains("var blocks by remember(initial.session.id)"))
        assertTrue(text.contains("val completedAt = session.endedAt ?: now"))
    }

    @Test
    fun guidedPlayerAndRichTodayPlanStayMounted() {
        val trainer = source("StrengthTrainerScreen.kt")
        val motion = source("StrengthExerciseMotionView.kt")
        val media = source("StrengthNativeMedia.kt")
        assumeTrue(
            "Strength guided-player sources unavailable",
            trainer != null && motion != null && media != null,
        )

        assertTrue(trainer!!.contains("StrengthExerciseMotionView("))
        assertTrue(trainer.contains("var currentBlockKey by rememberSaveable"))
        assertTrue(trainer.contains("finishTimedSet(useTargetDuration = true)"))
        assertTrue(trainer.contains("strengthTodayPlans(routine, exercises, history)"))
        assertTrue(trainer.contains("showHeader = false"))
        assertTrue(trainer.contains("StrengthAdaptivePlanner.recommendation("))
        assertTrue(trainer.contains("StrengthProgramBuilder("))
        assertTrue(trainer.contains("sourceRoutineExerciseId"))
        assertTrue(trainer.contains("updateRoutine: Boolean"))
        assertTrue(trainer.contains("TextToSpeech(context)"))
        assertTrue(trainer.contains("completePacedSet(setId)"))
        assertTrue(trainer.contains("StrengthExercisePerformanceContext("))
        assertTrue(trainer.contains("var exerciseGuideId by rememberSaveable"))
        assertTrue(trainer.contains("onGuide = { exerciseGuideId = it.id }"))
        assertTrue(trainer.contains("StrengthExerciseGuidePanel("))
        assertTrue(trainer.contains("presentation = StrengthExerciseMediaPresentation.DETAIL"))
        assertTrue(trainer.contains("StrengthExerciseThumbnail("))
        assertTrue(trainer.contains("onGuide(plan.exercise)"))
        assertTrue(trainer.contains("onGuide = onGuide"))
        assertTrue(trainer.contains("Modifier.clickable { onGuide(exercise) }"))
        assertFalse(motion!!.contains("withFrameNanos"))
        assertFalse(motion.contains("drawStrengthMotion("))
        assertTrue(motion.contains("StrengthNativeExerciseMedia("))
        assertFalse(motion.contains("StrengthMotionWebView("))
        assertTrue(
            media!!.contains("STRENGTH_DEMO_MEDIA_HOST = \"https://static.exercisedb.dev/media\""),
        )
        assertTrue(media.contains("BuildConfig.STRENGTH_MEDIA_URL_TEMPLATE"))
        assertTrue(media.contains("BuildConfig.DEBUG && BuildConfig.ALLOW_DEMO_STRENGTH_MEDIA"))
        assertTrue(media.contains("STRENGTH_MAXIMUM_DOWNLOAD_BYTES"))
        assertTrue(media.contains("StrengthMediaDownloadCapInterceptor"))
        assertTrue(media.contains("StrengthMediaValidationDecoderFactory"))
        assertTrue(media.contains("STRENGTH_MINIMUM_PIXELS_PARAMETER"))
        assertTrue(media.contains("coil.compose.AsyncImage"))
        assertTrue(media.contains("diskCacheKey(\"strength-exercise-v2-\$mediaId\")"))
        assertTrue(media.contains("exercise-guidance.json"))
        assertTrue(media.contains("StrengthExerciseFormGuide"))
        assertTrue(media.contains("delay(6_000)"))
        assertTrue(media.contains("requestVersion += 1"))
        assertTrue(media.contains("BoxWithConstraints("))
        assertTrue(media.contains("maxHeight - 12.dp"))
        assertTrue(media.contains("maxWidth - (controlRailWidth * 2) - 16.dp"))
        assertTrue(media.contains(".size(mediaSize)"))
        assertTrue(media.contains(".background(Color.White)"))
        assertTrue(media.contains("StrengthExerciseThumbnail("))
        assertTrue(motion.contains("strength.exerciseMediaCompact.v2"))
        assertTrue(motion.contains("StrengthExerciseMediaPresentation.DETAIL"))
        assertFalse(media.contains("WebView"))
        assertFalse(motion.contains("pair.second,\n        exercise.primaryMuscle"))
    }

    @Test
    fun instructorProfileAndInteractiveBodyMapStayMounted() {
        val trainer = source("StrengthTrainerScreen.kt")
        val motion = source("StrengthExerciseMotionView.kt")
        val media = source("StrengthNativeMedia.kt")
        assumeTrue(
            "Strength instructor sources unavailable",
            trainer != null && motion != null && media != null,
        )

        assertTrue(trainer!!.contains("StrengthProgramRequest("))
        assertTrue(trainer.contains("STRENGTH_PROFILE_EXPERIENCE"))
        assertTrue(trainer.contains("STRENGTH_PROFILE_STYLE"))
        assertTrue(trainer.contains("STRENGTH_PROFILE_SESSION_MINUTES"))
        assertTrue(trainer.contains("STRENGTH_PROFILE_DAY_COUNT"))
        assertTrue(trainer.contains("STRENGTH_PROFILE_WEEKDAYS"))
        assertTrue(trainer.contains("STRENGTH_PROFILE_FOCUS_MUSCLES"))
        assertTrue(trainer.contains("didOfferProgramBuilder"))
        assertTrue(trainer.contains("val draft = StrengthSessionSnapshot(session, sets)"))
        assertTrue(trainer.contains("StrengthMuscleCoach("))
        assertTrue(trainer.contains("StrengthBodyMapView("))
        assertTrue(trainer.contains("startFocusSession("))
        assertTrue(trainer.contains("selectedFocusExerciseIds"))
        assertTrue(trainer.contains("var selectedFocusMuscles by rememberSaveable"))
        assertTrue(trainer.contains("selectedMuscles = selectedFocusMuscles"))
        assertTrue(trainer.contains("if (muscle in selectedFocusMuscles)"))
        assertTrue(trainer.contains("for (candidates in rankedByMuscle)"))
        assertTrue(trainer.contains("val retained = selectedFocusExerciseIds.intersect(candidateIds)"))
        assertTrue(motion!!.contains("enum class StrengthBodyMapMode"))
        assertTrue(motion.contains("StrengthNativeBodyMap("))
        assertTrue(media!!.contains("body-map-native.svg"))
        assertTrue(media.contains("if (muscle in selectedMuscles)"))
        assertTrue(media.contains("detectTapGestures"))
        assertTrue(media.contains("strengthBodyMapHit("))
    }

    @Test
    fun restTargetIsNormalizedAndAutosaved() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)
        val text = trainer!!

        assertTrue(text.contains("StrengthWorkoutPlanner.resolvedRestSeconds("))
        assertTrue(text.contains("continuesSuperset = continuesSuperset"))
        assertTrue(text.contains("first.restSeconds ?: prescription?.restSeconds ?: 120"))
        assertTrue(text.contains("restSeconds = block.restSeconds"))
        assertTrue(text.contains("sets = candidate.sets.map { it.copy(restSeconds = seconds) }"))
        assertTrue(text.contains("autosave()"))
    }

    @Test
    fun recentSessionTotalsExcludeWarmupSets() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)

        assertTrue(
            Regex(
                """val completed = item\.sets\.filter\s*\{\s*"""
                    + """it\.completedAt != null && it\.setType != "warmup"\s*\}""",
            ).containsMatchIn(trainer!!),
        )
    }

    @Test
    fun strengthResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values",
            "values-de",
            "values-es",
            "values-fr",
            "values-it",
            "values-pt-rPT",
            "values-ru",
            "values-zh",
            "values-zh-rTW",
        )
        val files = folders.associateWith { resource("$it/strings.xml") }
        assumeTrue("Strength locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { strengthStrings(it.value!!) }
        val base = values.getValue("values")

        assertEquals(256, base.size)
        val placeholder = Regex("""%\d+\$[dsf]""")
        for ((folder, localized) in values) {
            assertEquals("$folder Strength key parity", base.keys, localized.keys)
            for (key in base.keys) {
                assertEquals(
                    "$folder placeholder parity for $key",
                    placeholder.findAll(base.getValue(key)).map { it.value }.sorted().toList(),
                    placeholder.findAll(localized.getValue(key)).map { it.value }.sorted().toList(),
                )
                assertTrue("$folder has blank $key", localized.getValue(key).isNotBlank())
            }
        }

        assertEquals("Schiena", values.getValue("values-it").getValue("strength_descriptor_back"))
        assertEquals("Подход %1\$d", values.getValue("values-ru").getValue("strength_set_number"))
        assertEquals("彈力帶", values.getValue("values-zh-rTW").getValue("strength_descriptor_band"))
    }
}
