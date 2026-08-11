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
        val calls = evaluateArguments(file!!.readText())

        assertTrue("expected at least the history and opt-in recompute paths", calls.size >= 2)
        assertTrue(
            "every V5HealthSignals.evaluate call must pass loggedPeriodStarts",
            calls.all { it.contains("loggedPeriodStarts =") },
        )
    }
}
