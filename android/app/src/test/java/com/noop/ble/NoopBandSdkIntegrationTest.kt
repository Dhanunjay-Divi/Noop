package com.noop.ble

import com.noop.bandsdk.BandConformanceRunner
import com.noop.bandsdk.BandCapability
import com.noop.bandsdk.BandCapabilityReport
import com.noop.bandsdk.BandException
import com.noop.bandsdk.BandFailureCategory
import com.noop.bandsdk.BandHistoryCheckpoint
import com.noop.bandsdk.BandIdentity
import com.noop.bandsdk.BandOperationClass
import com.noop.bandsdk.BandPairingCandidate
import com.noop.bandsdk.BandSessionState
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopBandSdkIntegrationTest {
    @Test
    fun appBoundaryCreatesPinnedNeutralSession() {
        assertEquals(
            "f2c1e189d6e703ceecea3502e1ba9ea77d8e2bd7",
            NoopBandSdkBoundary.PINNED_SOURCE_REVISION,
        )
        val session = NoopBandSdkBoundary.newSession()
        assertEquals(1L, session.beginScan())
        assertEquals(BandSessionState.SCANNING, session.snapshot().state)
    }

    @Test
    fun appBoundaryRestoresSourceScopedHistoryCheckpoint() {
        val checkpoint = BandHistoryCheckpoint(
            sourceIdentity = "synthetic-source",
            acknowledgedCursor = "cursor-2",
            lastHistoryComplete = false,
            durableSampleIdentities = emptySet(),
        )
        val session = NoopBandSdkBoundary.newSession(
            historyCheckpoint = checkpoint,
        )
        session.beginScan()
        session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
        )
        val identity = BandIdentity(
            sourceIdentity = checkpoint.sourceIdentity,
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-f2c1e189",
        )
        session.connect(identity)
        session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
            ),
        )
        assertEquals(
            checkpoint.acknowledgedCursor,
            session.snapshot().acknowledgedHistoryCursor,
        )
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val failure = try {
            session.completeOperation(token)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.HISTORY_STALLED, failure)
    }

    @Test
    fun allExportedConformanceScenariosMatchContractInAppModule() {
        val contract = JSONObject(contractFile().readText())
        assertEquals(1, contract.getInt("schemaVersion"))
        val scenarios = contract.getJSONArray("scenarios")
        val automated = (0 until scenarios.length())
            .map { scenarios.getJSONObject(it) }
            .filter { it.getBoolean("automated") }

        assertEquals(
            automated.map { it.getString("id") },
            BandConformanceRunner.automatedScenarios,
        )

        automated.forEach { scenario ->
            val scenarioId = scenario.getString("id")
            val expected = scenario.getJSONObject("expected")
            val actual = BandConformanceRunner.run(scenarioId)
            assertEquals(scenarioId, actual.scenario)
            assertEquals(
                expected.getJSONArray("events").toStringList(),
                actual.events,
            )
            assertEquals(expected.getString("finalState"), actual.finalState)
            assertEquals(
                expected.nullableString("acknowledgedCursor"),
                actual.acknowledgedCursor,
            )
            assertEquals(
                expected.getInt("acceptedSamples"),
                actual.acceptedSamples,
            )
            assertEquals(expected.nullableString("failure"), actual.failure)
        }
    }

    private fun contractFile(): File {
        val workingDirectory = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(
                workingDirectory,
                "../Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
            File(
                workingDirectory,
                "Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
            File(
                workingDirectory,
                "../../Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
        ).firstOrNull(File::isFile) ?: error(
            "NOOP Band SDK conformance contract is unavailable",
        )
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else getString(key)
}
