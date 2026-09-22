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
import com.noop.bandsdk.BandHistoryChunk
import com.noop.bandsdk.BandIdentity
import com.noop.bandsdk.BandOperationClass
import com.noop.bandsdk.BandPairingCandidate
import com.noop.bandsdk.BandProvenanceLane
import com.noop.bandsdk.BandSample
import com.noop.bandsdk.BandSampleBatch
import com.noop.bandsdk.BandSampleIdentity
import com.noop.bandsdk.BandSampleQuality
import com.noop.bandsdk.BandSessionMachine
import com.noop.bandsdk.BandSessionState
import com.noop.bandsdk.BandStreamKind
import com.noop.bandsdk.BandUnit
import com.noop.bandsdk.DurableHistoryReceipt
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopBandSdkIntegrationTest {
    @Test
    fun appBoundaryCreatesPinnedNeutralSession() {
        assertEquals(
            "c254cb329963eb262d18c43ae6b25a8340fe77f6",
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
            wrapperRevision = "artifact-55fdd89",
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
            wrapperRevision = "artifact-55fdd89",
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
    fun invalidHistoryTokensRecordBoundedRejections() {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation) = readyHistorySession(diagnostics)
        val supersededToken =
            session.beginOperation(BandOperationClass.HISTORY)
        session.cancelOperation(supersededToken)
        val activeToken = session.beginOperation(BandOperationClass.HISTORY)
        val (foreignSession, _) = readyHistorySession()
        val foreignToken =
            foreignSession.beginOperation(BandOperationClass.HISTORY)
        val chunk = BandHistoryChunk(
            chunkIdentity = "synthetic-chunk",
            previousCursor = null,
            nextCursor = "cursor-1",
            complete = true,
            overflowed = false,
            acknowledgementToken = "ack-1",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = "synthetic-source",
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-1",
                    calibrationRevision = "calibration-1",
                    samples = listOf(
                        BandSample(
                            identity = BandSampleIdentity(
                                stream = BandStreamKind.HEART_RATE,
                                sequence = 1,
                                deviceTimeMilliseconds = 1_000,
                            ),
                            value = 72.0,
                            unit = BandUnit.BEATS_PER_MINUTE,
                            quality = BandSampleQuality.ACCEPTED,
                        ),
                    ),
                ),
            ),
        )

        var eventCount = diagnostics.snapshot().size
        val stageFailure = try {
            session.stageHistoryChunk(chunk, supersededToken, generation)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.INVALID_STATE, stageFailure)
        var events = diagnostics.snapshot()
        assertEquals(eventCount + 1, events.size)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.HISTORY,
                outcome = BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.INVALID_STATE,
            ),
            events.last(),
        )

        eventCount = events.size
        val foreignStageFailure = try {
            session.stageHistoryChunk(chunk, foreignToken, generation)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.STALE_CALLBACK, foreignStageFailure)
        events = diagnostics.snapshot()
        assertEquals(eventCount + 1, events.size)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.HISTORY,
                outcome = BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.STALE_CALLBACK,
            ),
            events.last(),
        )

        val acceptance =
            session.stageHistoryChunk(chunk, activeToken, generation)
        val receipt = DurableHistoryReceipt(
            acceptance = acceptance,
            historyStateCommitted = true,
            committedSamples = acceptance.acceptedSamples,
            committed = true,
        )

        eventCount = diagnostics.snapshot().size
        val acknowledgeFailure = try {
            session.acknowledgeHistory(
                receipt,
                supersededToken,
                generation,
            )
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.INVALID_STATE, acknowledgeFailure)
        events = diagnostics.snapshot()
        assertEquals(eventCount + 1, events.size)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.HISTORY,
                outcome = BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.INVALID_STATE,
            ),
            events.last(),
        )

        eventCount = events.size
        val foreignAcknowledgeFailure = try {
            session.acknowledgeHistory(receipt, foreignToken, generation)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(
            BandFailureCategory.STALE_CALLBACK,
            foreignAcknowledgeFailure,
        )
        events = diagnostics.snapshot()
        assertEquals(eventCount + 1, events.size)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.HISTORY,
                outcome = BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.STALE_CALLBACK,
            ),
            events.last(),
        )
        val unchanged = session.snapshot()
        assertEquals(BandSessionState.HISTORY_COLLECTING, unchanged.state)
        assertEquals(BandOperationClass.HISTORY, unchanged.activeOperation)

        session.acknowledgeHistory(receipt, activeToken, generation)
        session.completeOperation(activeToken)
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
            wrapperRevision = "artifact-55fdd89",
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

        assertEquals(34, automated.size)
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

    private fun readyHistorySession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    ): Pair<BandSessionMachine, Long> {
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
            wrapperRevision = "artifact-55fdd89",
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
        return session to generation
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
