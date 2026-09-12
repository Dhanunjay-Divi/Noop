package com.noop.ui

import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AgeMetricReconciliationRunnerTest {
    private fun sourceFile(relativePath: String): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/$relativePath"),
            File(root, "app/src/main/java/$relativePath"),
            File(root, "android/app/src/main/java/$relativePath"),
        ).firstOrNull(File::isFile)
    }

    @Test
    fun `both focused age metrics share one scorer serialization gate`() {
        val file = sourceFile("com/noop/analytics/IntelligenceEngine.kt")
        assumeTrue("IntelligenceEngine source unavailable", file != null)
        val source = file!!.readText()
        val start = source.indexOf("suspend fun recomputeAgeMetricsOnly(")
        val end = source.indexOf("private suspend fun ageMetricOperationFinished", start)
        assertTrue(start >= 0 && end > start)
        val body = source.substring(start, end)
        assertTrue(body.contains("): AgeMetricRecomputeOutcome = analyzeGate.withLock {"))
        assertTrue(body.contains("recomputeFitnessAgeOnlyInsideGate("))
        assertTrue(body.contains("recomputeVitalityOnlyInsideGate("))
    }

    @Test
    fun `queued runtime scorers resolve the profile only after entering the shared gate`() {
        val engineFile = sourceFile("com/noop/analytics/IntelligenceEngine.kt")
        val appFile = sourceFile("com/noop/ui/AppViewModel.kt")
        val bleFile = sourceFile("com/noop/ble/WhoopBleClient.kt")
        assumeTrue("runtime scorer sources unavailable", engineFile != null && appFile != null && bleFile != null)

        val engine = engineFile!!.readText()
        val analyzeStart = engine.indexOf("suspend fun analyzeRecent(")
        val analyzeEnd = engine.indexOf("const val EFFORT_RESCORE_HISTORY_DAYS", analyzeStart)
        assertTrue(analyzeStart >= 0 && analyzeEnd > analyzeStart)
        val analyze = engine.substring(analyzeStart, analyzeEnd)
        val gate = analyze.indexOf("analyzeGate.withLock {")
        val resolve = analyze.indexOf("val resolvedProfile = profileProvider?.invoke() ?: profile")
        val score = analyze.indexOf("analyzeRecentOnCpu(repo, resolvedProfile")
        assertTrue("profile must be resolved after the scorer owns the gate", gate >= 0 && resolve > gate)
        assertTrue("the resolved profile must feed the scorer", score > resolve)

        val app = appFile!!.readText()
        assertTrue(
            "periodic, edit, and upgrade scorers must supply a live profile provider",
            Regex("""profileProvider = ::currentProfile""").findAll(app).count() >= 5,
        )
        val ble = bleFile!!.readText()
        val postBackfillStart = ble.indexOf("private suspend fun runPostBackfillAnalysisPass(")
        val postBackfillEnd = ble.indexOf("\n    private ", postBackfillStart + 1)
            .takeIf { it > postBackfillStart } ?: ble.length
        val postBackfill = ble.substring(postBackfillStart, postBackfillEnd)
        assertTrue(
            "post-offload scoring must read ProfileStore from inside a provider",
            postBackfill.contains("profileProvider = {") &&
                postBackfill.contains("age = profileStore.age.toDouble()"),
        )
        assertTrue(
            "one committed source snapshot must drive generation claim, scoring, and writeback",
            postBackfill.contains("sourceIds = listOf(sourceId)") &&
                postBackfill.contains("repository.runClaimedAnalysis(analysisLease)") &&
                postBackfill.contains("importedDeviceId = sourceId") &&
                postBackfill.contains("HealthConnectWriter.write(context, repository, sourceId)"),
        )
        assertTrue(
            "post-offload scoring must not use the legacy history fingerprint or watermark",
            !postBackfill.contains("analysisFingerprint(") &&
                !postBackfill.contains("setAnalyzeWatermark("),
        )
        assertTrue(
            "post-offload scoring must not capture a UserProfile before queueing",
            !postBackfill.contains("val profile = UserProfile("),
        )
    }

    @Test
    fun `device switch cancels old work and persists only the new target`() = runTest {
        var current = AgeMetricReconciliationTarget("profile", "band-a")
        val firstStarted = CompletableDeferred<Unit>()
        val devices = mutableListOf<String>()
        val persisted = mutableListOf<AgeMetricReconciliationTarget>()
        var publications = 0
        val runner = AgeMetricReconciliationRunner(
            scope = this,
            debounceMillis = 0,
            currentTarget = { current },
            profileSnapshot = { "snapshot" },
            recomputeMetrics = { _, deviceId ->
                devices += deviceId
                if (deviceId == "band-a") {
                    firstStarted.complete(Unit)
                    awaitCancellation()
                }
                AgeMetricReconciliationOutcome(true, true)
            },
            publishCompletedWork = { publications += 1 },
            persistCompletedTarget = {
                persisted += it
                true
            },
        )

        runner.schedule()
        runCurrent()
        firstStarted.await()
        current = AgeMetricReconciliationTarget("profile", "band-b")
        runner.schedule()
        advanceUntilIdle()

        assertEquals(listOf("band-a", "band-b"), devices)
        assertEquals(listOf(current), persisted)
        assertEquals(1, publications)
    }

    @Test
    fun `both metrics use captured device and stale completion cannot publish`() = runTest {
        var current = AgeMetricReconciliationTarget("profile", "band-a")
        val devices = mutableListOf<String>()
        var publications = 0
        val persisted = mutableListOf<AgeMetricReconciliationTarget>()
        val runner = AgeMetricReconciliationRunner(
            scope = this,
            debounceMillis = 0,
            currentTarget = { current },
            profileSnapshot = { Unit },
            recomputeMetrics = { _, deviceId ->
                devices += deviceId
                current = AgeMetricReconciliationTarget("profile", "band-b")
                AgeMetricReconciliationOutcome(true, true)
            },
            publishCompletedWork = { publications += 1 },
            persistCompletedTarget = {
                persisted += it
                true
            },
        )

        runner.schedule()
        advanceUntilIdle()

        assertEquals(listOf("band-a"), devices)
        assertEquals(0, publications)
        assertTrue(persisted.isEmpty())
    }

    @Test
    fun `one failed metric publishes completed work but keeps target pending`() = runTest {
        val target = AgeMetricReconciliationTarget("profile", "band-a")
        var publications = 0
        val persisted = mutableListOf<AgeMetricReconciliationTarget>()
        val runner = AgeMetricReconciliationRunner(
            scope = this,
            debounceMillis = 0,
            currentTarget = { target },
            profileSnapshot = { Unit },
            recomputeMetrics = { _, _ -> AgeMetricReconciliationOutcome(true, false) },
            publishCompletedWork = { publications += 1 },
            persistCompletedTarget = {
                persisted += it
                true
            },
        )

        runner.schedule()
        advanceUntilIdle()

        assertEquals(1, publications)
        assertTrue(persisted.isEmpty())
    }

    @Test
    fun `successful no-value results still persist completed target`() = runTest {
        val target = AgeMetricReconciliationTarget("profile", "band-a")
        val persisted = mutableListOf<AgeMetricReconciliationTarget>()
        val runner = AgeMetricReconciliationRunner(
            scope = this,
            debounceMillis = 0,
            currentTarget = { target },
            profileSnapshot = { Unit },
            recomputeMetrics = { _, _ -> AgeMetricReconciliationOutcome(true, true) },
            publishCompletedWork = {},
            persistCompletedTarget = {
                persisted += it
                true
            },
        )

        runner.schedule()
        advanceUntilIdle()

        assertEquals(listOf(target), persisted)
    }

    @Test
    fun `failed completion marker stays retryable and marks only after success`() = runTest {
        val target = AgeMetricReconciliationTarget("profile", "band-a")
        var persistenceAttempts = 0
        val marked = mutableListOf<AgeMetricReconciliationTarget>()
        val runner = AgeMetricReconciliationRunner(
            scope = this,
            debounceMillis = 0,
            currentTarget = { target },
            profileSnapshot = { Unit },
            recomputeMetrics = { _, _ -> AgeMetricReconciliationOutcome(true, true) },
            publishCompletedWork = {},
            persistCompletedTarget = {
                persistenceAttempts += 1
                persistenceAttempts > 1
            },
            markCompletedTarget = { marked += it },
        )

        runner.schedule()
        advanceUntilIdle()
        assertEquals(1, persistenceAttempts)
        assertTrue(marked.isEmpty())

        runner.schedule()
        advanceUntilIdle()
        assertEquals(2, persistenceAttempts)
        assertEquals(listOf(target), marked)
    }
}
