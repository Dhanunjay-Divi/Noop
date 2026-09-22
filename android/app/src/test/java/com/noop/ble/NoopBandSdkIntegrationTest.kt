package com.noop.ble

import com.noop.bandsdk.BandConformanceRunner
import com.noop.bandsdk.BandCapability
import com.noop.bandsdk.BandCapabilityReport
import com.noop.bandsdk.BandDiagnosticEvent
import com.noop.bandsdk.BandDiagnosticKind
import com.noop.bandsdk.BandDiagnosticOutcome
import com.noop.bandsdk.BandDiagnosticsRecorder
import com.noop.bandsdk.BandException
import com.noop.bandsdk.BandFailureCategory
import com.noop.bandsdk.BandHistoryCheckpoint
import com.noop.bandsdk.BandIdentity
import com.noop.bandsdk.BandOperationClass
import com.noop.bandsdk.BandPairingCandidate
import com.noop.bandsdk.BandSessionMachine
import com.noop.bandsdk.BandSessionState
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopBandSdkIntegrationTest {
    @Test
    fun appBoundaryCreatesPinnedNeutralSession() {
        assertEquals(
            "78c17cbd495353f33b5ef169bd1200ee9a0c35df",
            NoopBandSdkBoundary.PINNED_SOURCE_REVISION,
        )
        val session = NoopBandSdkBoundary.newSession()
        assertEquals(1L, session.beginScan())
        assertEquals(BandSessionState.SCANNING, session.snapshot().state)
    }

    @Test
    fun appBoundaryRestoresSourceScopedHistoryCheckpoint() {
        val diagnostics = BandDiagnosticsRecorder()
        val checkpoint = BandHistoryCheckpoint(
            sourceIdentity = "synthetic-source",
            acknowledgedCursor = "cursor-2",
            lastHistoryComplete = false,
            durableSampleIdentities = emptySet(),
        )
        val session = NoopBandSdkBoundary.newSession(
            diagnostics = diagnostics,
            historyCheckpoint = checkpoint,
        )
        val generation = session.beginScan()
        session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            generation,
        )
        val identity = BandIdentity(
            sourceIdentity = checkpoint.sourceIdentity,
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-78c17cb",
        )
        completeConnection(session, identity, generation)
        session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
            ),
            generation,
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
        assertEquals(BandFailureCategory.STORAGE, failure)
        assertEquals(
            true,
            diagnostics.snapshot().contains(
                BandDiagnosticEvent(
                    kind = BandDiagnosticKind.HISTORY,
                    outcome = BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            ),
        )
        session.cancelOperation(token)
        assertEquals(BandSessionState.READY, session.snapshot().state)
    }

    @Test
    fun operationFailureAdvancesGenerationAndRecordsBoundedCategory() {
        val diagnostics = BandDiagnosticsRecorder()
        val session = NoopBandSdkBoundary.newSession(diagnostics = diagnostics)
        val generation = session.beginScan()
        session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            generation,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-78c17cb",
        )
        completeConnection(session, identity, generation)
        session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.BATTERY),
            ),
            generation,
        )

        val token = session.beginOperation(BandOperationClass.BATTERY)
        session.failOperation(token, BandFailureCategory.DISCONNECTED)

        val snapshot = session.snapshot()
        assertEquals(BandSessionState.RECOVERING, snapshot.state)
        assertEquals(generation + 1, snapshot.generation)
        val events = diagnostics.snapshot()
        assertEquals(
            true,
            events.contains(
                BandDiagnosticEvent(
                    kind = BandDiagnosticKind.COMMAND,
                    outcome = BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.DISCONNECTED,
                ),
            ),
        )
        assertEquals(
            true,
            events.contains(
                BandDiagnosticEvent(
                    kind = BandDiagnosticKind.RECONNECT,
                    outcome = BandDiagnosticOutcome.INTERRUPTED,
                    failureCategory = BandFailureCategory.DISCONNECTED,
                ),
            ),
        )
    }

    @Test
    fun capabilityAuthorizationUsesImmutableIdempotentSnapshot() {
        val session = NoopBandSdkBoundary.newSession()
        val generation = session.beginScan()
        session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            generation,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-78c17cb",
        )
        completeConnection(session, identity, generation)
        val mutableCapabilities = mutableSetOf(BandCapability.HEART_RATE)
        val report = BandCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = identity.protocolVersion,
            hardwareRevision = identity.hardwareRevision,
            firmwareVersion = identity.firmwareVersion,
            historyDays = 7,
            capabilities = mutableCapabilities,
        )
        session.acceptCapabilities(report, generation)
        session.acceptCapabilities(report, generation)
        mutableCapabilities += BandCapability.FIRMWARE_UPDATE

        val failure = try {
            session.beginOperation(BandOperationClass.FIRMWARE)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.UPDATE_NOT_ELIGIBLE, failure)
        assertEquals(BandSessionState.READY, session.snapshot().state)
    }

    @Test
    fun allExportedConformanceScenariosMatchContractInAppModule() {
        val contract = JSONObject(contractFile().readText())
        assertEquals(1, contract.getInt("schemaVersion"))
        val scenarios = contract.getJSONArray("scenarios")
        val automated = (0 until scenarios.length())
            .map { scenarios.getJSONObject(it) }
            .filter { it.getBoolean("automated") }

        assertEquals(33, automated.size)
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

    private fun completeConnection(
        session: BandSessionMachine,
        identity: BandIdentity,
        callbackGeneration: Long,
    ) {
        session.beginConnection(callbackGeneration)
        session.beginAuthentication(callbackGeneration)
        session.completeConnection(identity, callbackGeneration)
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else getString(key)
}
