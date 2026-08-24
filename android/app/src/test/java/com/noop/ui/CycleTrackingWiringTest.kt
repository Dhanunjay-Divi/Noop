package com.noop.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Pins every Android v5 adapter invocation to the locally logged cycle-day-1 anchors. */
class CycleTrackingWiringTest {

    private fun appViewModelSource(): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/AppViewModel.kt"),
            File(root, "app/src/main/java/com/noop/ui/AppViewModel.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/AppViewModel.kt"),
        ).firstOrNull(File::isFile)
    }

    private fun evaluateArguments(source: String): List<String> {
        val calls = mutableListOf<String>()
        var cursor = 0
        val needle = "V5HealthSignals.evaluate("
        while (true) {
            val at = source.indexOf(needle, cursor)
            if (at < 0) break
            val open = at + needle.length - 1
            var depth = 0
            var end = open
            while (end < source.length) {
                when (source[end]) {
                    '(' -> depth++
                    ')' -> {
                        depth--
                        if (depth == 0) break
                    }
                }
                end++
            }
            calls += source.substring(open + 1, end)
            cursor = end + 1
        }
        return calls
    }

    @Test
    fun everyV5EvaluationThreadsLoggedPeriodStarts() {
        val file = appViewModelSource()
        assumeTrue("AppViewModel source unavailable from ${System.getProperty("user.dir")}", file != null)
        val source = file!!.readText()
        val calls = evaluateArguments(source)

        assertTrue("expected one serialized V5 publication path", calls.size == 1)
        assertTrue(
            "every V5HealthSignals.evaluate call must pass loggedPeriodStarts",
            calls.all { it.contains("loggedPeriodStarts =") },
        )
        assertTrue(
            "foreground resume must advance cycle state even when recent wearable days do not change",
            source.contains("viewModelScope.launch { refreshCycleTracking() }"),
        )
        val refreshStart = source.indexOf("private suspend fun refreshCycleTracking()")
        val refreshEnd = source.indexOf("private suspend fun refreshHealthSignalState()", refreshStart)
        assertTrue("cycle refresh implementation must remain discoverable", refreshStart >= 0 && refreshEnd > refreshStart)
        val refresh = source.substring(refreshStart, refreshEnd)
        assertTrue(
            "foreground cycle refresh must use the shared health-state publisher",
            refresh.contains("refreshHealthSignalState()"),
        )

        val sharedStart = refreshEnd
        val sharedEnd = source.indexOf("private fun currentIllnessDayKey()", sharedStart)
        assertTrue("shared health publisher must remain discoverable", sharedEnd > sharedStart)
        val shared = source.substring(sharedStart, sharedEnd)
        assertTrue(
            "overlapping refreshes must serialize one matching banner and V5 assessment",
            shared.contains("healthSignalRefreshMutex.withLock {") &&
                shared.contains("_healthAlert.value = currentAlert") &&
                shared.contains("_v5Signals.value = currentSignals") &&
                shared.contains("illnessAssessment = assessment"),
        )
        assertTrue(
            "Room cycle reads must retain state without swallowing cancellation",
            shared.contains("repository.periodStarts()") &&
                shared.contains("repository.cycleDailyLogs()") &&
                shared.contains("_periodStarts.value") &&
                shared.contains("_cycleDailyLogs.value") &&
                Regex("""catch \(cancelled: CancellationException\)""")
                    .findAll(shared).count() >= 3,
        )
        assertTrue(
            "the shared publisher must be the only writer for each assessment surface",
            Regex("""_healthAlert\.value\s*=""").findAll(source).count() == 1 &&
                Regex("""_v5Signals\.value\s*=""").findAll(source).count() == 1,
        )
    }
}
