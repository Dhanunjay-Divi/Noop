package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class AnalysisInputGateContractTest {
    @Test
    fun launchResumeLoopClaimsBoundedSourcesAndDoesNotScanHistory() {
        val source = appViewModelSource()
        assumeTrue("AppViewModel source unavailable", source != null)
        val loopStart = source!!.indexOf("val analysisSourceId = deviceId")
        val loopEnd = source.indexOf("// Opt-in writeback:", loopStart)
        assertTrue(loopStart >= 0 && loopEnd > loopStart)
        val loop = source.substring(loopStart, loopEnd)

        assertTrue(loop.contains("repository.analysisDirtySourceIds("))
        assertTrue(loop.contains("sourceIds = analysisSourceIds"))
        assertTrue(loop.contains("explicitRescorePending"))
        assertTrue(loop.contains("activeZoneUpgradePending ||"))
        assertTrue(loop.contains("\"change_gate_ok\""))
        assertTrue(loop.contains("repository.runClaimedAnalysis(analysisLease)"))
        assertTrue(loop.contains("IntelligenceEngine.analysisScoringPlan("))
        assertTrue(loop.contains("claims = analysisLease.claims"))
        assertTrue(loop.contains("maxDays = analysisPlan.maxDays"))
        assertTrue(loop.contains("nowSeconds = analysisPlan.anchorNowSeconds"))
        assertTrue(loop.contains("historicalCatchUp = analysisPlan.isHistoricalCatchUp"))
        assertTrue(loop.contains("importedDeviceId = analysisSourceId"))
        assertTrue(loop.contains("activeDeviceId = analysisSourceId"))
        assertTrue(loop.contains("remove(NoopPrefs.KEY_ANALYZE_WATERMARK)"))
        assertFalse(loop.contains("analysisFingerprint("))
        assertFalse(loop.contains("countAnalysisFingerprintRows"))
        assertFalse(loop.contains("maxAnalysisFingerprintTs"))
        assertFalse(loop.contains("setAnalyzeWatermark("))
    }

    @Test
    fun repositorySnapshotsWithoutClearingAndAcknowledgesOnlyAfterSuccess() {
        val source = sourceFile("com/noop/data/WhoopRepository.kt")
        assumeTrue("WhoopRepository source unavailable", source != null)
        val claimStart = source!!.indexOf("internal suspend fun claimAnalysisInput(")
        val claimEnd = source.indexOf("internal suspend fun <R> runClaimedAnalysis(", claimStart)
        val runEnd = source.indexOf("// MARK: - Server-derived caches", claimEnd)
        assertTrue(claimStart >= 0 && claimEnd > claimStart && runEnd > claimEnd)

        val claim = source.substring(claimStart, claimEnd)
        val run = source.substring(claimEnd, runEnd)
        assertTrue(claim.contains("dao.pendingAnalysisInputClaims(normalized)"))
        assertFalse(claim.contains("DELETE"))
        assertFalse(claim.contains("consumeAnalysisDirtySources"))

        val block = run.indexOf("val result = block(consumption)")
        val progress = run.indexOf("val progress = consumption.progressFor(lease.claims)")
        val transaction = run.indexOf("transactor.run")
        val acknowledge = run.indexOf("dao.acknowledgeExactAnalysisInputGeneration(")
        val shrink = run.indexOf("dao.shrinkExactAnalysisInputNewestTail(")
        val returned = run.indexOf("return result")
        assertTrue(
            block >= 0 &&
                progress > block &&
                transaction > progress &&
                acknowledge > transaction &&
                shrink > acknowledge &&
                returned > shrink,
        )
        assertTrue(run.contains("dao.hasAnyScoreBearingHistory()"))
        assertTrue(run.contains("dao.hasScoreBearingHistory(claim.deviceId)"))
        assertFalse(run.contains("NonCancellable"))
        assertFalse(run.contains("rearm"))
    }

    @Test
    fun postBackfillPathUsesGenerationGateWithoutLegacyWatermark() {
        val source = sourceFile("com/noop/ble/WhoopBleClient.kt")
        assumeTrue("WhoopBleClient source unavailable", source != null)
        val start = source!!.indexOf("private suspend fun runPostBackfillAnalysisPass(")
        val end = source.indexOf("\n    private ", start + 1).takeIf { it > start } ?: source.length
        assertTrue(start >= 0 && end > start)
        val pass = source.substring(start, end)

        assertTrue(pass.contains("repository.claimAnalysisInput("))
        assertTrue(pass.contains("repository.runClaimedAnalysis(analysisLease)"))
        assertTrue(pass.contains("IntelligenceEngine.analysisScoringPlan("))
        assertTrue(pass.contains("claims = analysisLease.claims"))
        assertTrue(pass.contains("maxDays = analysisPlan.maxDays"))
        assertTrue(pass.contains("nowSeconds = analysisPlan.anchorNowSeconds"))
        assertTrue(pass.contains("historicalCatchUp = analysisPlan.isHistoricalCatchUp"))
        assertTrue(pass.contains("IntelligenceEngine.boundDayOwnerSource(sourceId, dayOwnerSource)"))
        assertTrue(pass.contains("sourceConsumed = analysisConsumption::markSourceConsumed"))
        assertTrue(
            pass.contains(
                "sourcesEvaluatedForOwnership =\n" +
                    "                        analysisConsumption::markSourcesEvaluatedForOwnership",
            ),
        )
        assertFalse(pass.contains("analysisFingerprint("))
        assertFalse(pass.contains("analyzeWatermark("))
        assertFalse(pass.contains("setAnalyzeWatermark("))
        assertFalse(pass.contains("failure.message"))
    }

    @Test
    fun postBackfillDurableQueueDiagnosticsDoNotExposeIdentifiersOrExceptionMessages() {
        val source = sourceFile("com/noop/ble/WhoopBleClient.kt")
        assumeTrue("WhoopBleClient source unavailable", source != null)
        val start = source!!.indexOf("private val postBackfillAnalysisWorker")
        val end = source.indexOf(
            "/** True while a historical offload is in progress",
            start,
        )
        assertTrue(start >= 0 && end > start)
        val queue = source.substring(start, end)

        assertTrue(queue.contains("onFailure = { _, failure ->"))
        assertFalse(queue.contains("failure.message"))
        assertFalse(queue.contains("for \$sourceId"))
    }

    @Test
    fun activeDeviceSwitchDurablyInvalidatesOwnershipAndKicksAnalysis() {
        val registry = sourceFile("com/noop/data/DeviceRegistry.kt")
        val viewModel = appViewModelSource()
        assumeTrue("active-device sources unavailable", registry != null && viewModel != null)

        val registryStart = registry!!.indexOf("suspend fun setActive(")
        val registryEnd = registry.indexOf("suspend fun archive(id: String)", registryStart)
        assertTrue(registryStart >= 0 && registryEnd > registryStart)
        val registryPath = registry.substring(registryStart, registryEnd)
        assertTrue(registryPath.contains("markOwnershipDirty()"))
        assertTrue(registryPath.contains("if (previous == id)"))
        val invalidationStart = registry.indexOf("private suspend fun markOwnershipDirty(")
        val invalidationEnd = registry.indexOf("/** All paired devices", invalidationStart)
        assertTrue(invalidationStart >= 0 && invalidationEnd > invalidationStart)
        val invalidationPath = registry.substring(invalidationStart, invalidationEnd)
        assertTrue(invalidationPath.contains("ownershipAnalysisInputRange()"))
        assertTrue(invalidationPath.contains("earliest"))
        assertTrue(invalidationPath.contains("latest"))
        assertTrue(
            invalidationPath.contains(
                "advanceAnalysisInvalidation(",
            ),
        )
        assertTrue(invalidationPath.contains("AnalysisInvalidationSource.OWNERSHIP"))
        assertTrue(invalidationPath.contains("insertAnalysisInvalidationIfAbsent"))

        val viewModelStart = viewModel!!.indexOf("suspend fun setActiveDevice(")
        val viewModelEnd = viewModel.indexOf("/** The active band's display name", viewModelStart)
        val viewModelPath = viewModel.substring(viewModelStart, viewModelEnd)
        assertTrue(viewModelPath.contains("noopApp.deviceRegistry.setActive(id)"))
        assertTrue(viewModelPath.contains("if (changed)"))
        assertTrue(viewModelPath.contains("analyzeKick.trySend(Unit)"))
    }

    @Test
    fun archiveLifecycleClearsOwnershipAndKicksOneRecompute() {
        val registry = sourceFile("com/noop/data/DeviceRegistry.kt")
        val viewModel = appViewModelSource()
        assumeTrue("archive lifecycle sources unavailable", registry != null && viewModel != null)

        val archiveStart = registry!!.indexOf("suspend fun archive(id: String)")
        val archiveEnd = registry.indexOf("/** Atomically update", archiveStart)
        val archivePath = registry.substring(archiveStart, archiveEnd)
        assertTrue(archivePath.contains("dao.deleteDayOwnershipFor(id)"))
        assertTrue(archivePath.contains("markOwnershipDirty()"))

        val viewModelStart = viewModel!!.indexOf("suspend fun archivePairedDevice(")
        val viewModelEnd = viewModel.indexOf("/** Rename a device", viewModelStart)
        val viewModelPath = viewModel.substring(viewModelStart, viewModelEnd)
        assertTrue(viewModelPath.contains("if (wasEligible)"))
        assertTrue(viewModelPath.contains("analyzeKick.trySend(Unit)"))
    }

    private fun appViewModelSource(): String? {
        return sourceFile("com/noop/ui/AppViewModel.kt")
    }

    private fun sourceFile(relativePath: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/$relativePath"),
            File(root, "app/src/main/java/$relativePath"),
            File(root, "android/app/src/main/java/$relativePath"),
        ).firstOrNull(File::isFile)?.readText()
    }
}
