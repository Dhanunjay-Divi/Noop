package com.noop.ble

import com.noop.bandsdk.BandConformanceRunner
import com.noop.bandsdk.BandCapability
import com.noop.bandsdk.BandCapabilityReport
import com.noop.bandsdk.BandConnectionToken
import com.noop.bandsdk.BandDiagnosticEvent
import com.noop.bandsdk.BandDiagnosticKind
import com.noop.bandsdk.BandDiagnosticOutcome
import com.noop.bandsdk.BandDiagnosticsRecorder
import com.noop.bandsdk.BandDisconnectReason
import com.noop.bandsdk.BandException
import com.noop.bandsdk.BandFailureCategory
import com.noop.bandsdk.BandHistoryCheckpoint
import com.noop.bandsdk.BandHistoryChunk
import com.noop.bandsdk.BandHistoryRange
import com.noop.bandsdk.BandIdentity
import com.noop.bandsdk.BandOperationClass
import com.noop.bandsdk.BandPairingCandidate
import com.noop.bandsdk.BandProvenanceLane
import com.noop.bandsdk.BandReconnectToken
import com.noop.bandsdk.BandSample
import com.noop.bandsdk.BandSampleBatch
import com.noop.bandsdk.BandSampleIdentity
import com.noop.bandsdk.BandSampleQuality
import com.noop.bandsdk.BandScanToken
import com.noop.bandsdk.BandSessionMachine
import com.noop.bandsdk.BandSessionState
import com.noop.bandsdk.BandStreamKind
import com.noop.bandsdk.BandUnit
import com.noop.bandsdk.DurableHistoryReceipt
import com.noop.bandsdk.DurableLiveReceipt
import java.io.File
import java.util.ConcurrentModificationException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopBandSdkIntegrationTest {
    private class TraversalFailureSet<T>(
        private val value: T,
    ) : AbstractSet<T>() {
        override val size: Int = 1

        override fun iterator(): Iterator<T> = object : Iterator<T> {
            override fun hasNext(): Boolean = true
            override fun next(): T = throw ConcurrentModificationException()
        }
    }

    private class MutationDuringTraversalSet<T>(
        private val initialValue: T,
        private val addedValue: T,
    ) : AbstractSet<T>() {
        override val size: Int = 1

        override fun iterator(): Iterator<T> =
            listOf(initialValue, addedValue).iterator()
    }

    private class ReentrantTraversalSet<T>(
        private val values: Set<T>,
        private val onFirstElement: () -> Unit,
    ) : AbstractSet<T>() {
        override val size: Int
            get() = values.size

        override fun iterator(): Iterator<T> {
            val delegate = values.iterator()
            var invoked = false
            return object : Iterator<T> {
                override fun hasNext(): Boolean = delegate.hasNext()

                override fun next(): T {
                    val value = delegate.next()
                    if (!invoked) {
                        invoked = true
                        onFirstElement()
                    }
                    return value
                }
            }
        }
    }

    @Test
    fun appBoundaryCreatesPinnedNeutralSession() {
        assertEquals(
            "b02808372b7c537f22058c7ebc75d92c750373be",
            NoopBandSdkBoundary.PINNED_SOURCE_REVISION,
        )
        val session = NoopBandSdkBoundary.newSession()
        assertEquals(1L, session.beginScan().generation)
        assertEquals(BandSessionState.SCANNING, session.snapshot().state)
    }

    @Test
    fun appModuleCannotForgeScanCallbackAuthority() {
        val session = NoopBandSdkBoundary.newSession()
        val issuedToken = session.beginScan()
        val forgedToken = BandScanToken(
            sessionNonce = issuedToken.sessionNonce,
            generation = issuedToken.generation,
        )
        val candidate = BandPairingCandidate(
            handle = "synthetic-candidate",
            compatible = true,
            identifyEligible = true,
        )

        val forgedFailure = try {
            session.selectCandidate(candidate, forgedToken)
            null
        } catch (error: BandException) {
            error.category
        }

        assertEquals(BandFailureCategory.STALE_CALLBACK, forgedFailure)
        session.selectCandidate(candidate, issuedToken)
        assertEquals(BandSessionState.CANDIDATE_SELECTED, session.snapshot().state)
    }

    @Test
    fun appModuleCannotForgeReconnectCallbackAuthority() {
        val (session, generation, connectionToken) = readySessionWithStreams()
        session.beginLive()
        val issuedToken =
            session.interruptForReconnect(connectionToken, generation)
        val forgedToken = BandReconnectToken(
            sessionNonce = issuedToken.sessionNonce,
            generation = issuedToken.generation,
            sequence = issuedToken.sequence,
        )

        val forgedFailure = try {
            session.resumeAfterReconnect(
                forgedToken,
                forgedToken.generation,
            )
            null
        } catch (error: BandException) {
            error.category
        }

        assertEquals(BandFailureCategory.STALE_CALLBACK, forgedFailure)
        assertEquals(BandSessionState.RECOVERING, session.snapshot().state)
        session.resumeAfterReconnect(issuedToken, issuedToken.generation)
        assertEquals(BandSessionState.READY, session.snapshot().state)
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
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken = session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            scanToken,
        )
        val identity = BandIdentity(
            sourceIdentity = checkpoint.sourceIdentity,
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-823930f",
        )
        completeConnection(session, identity, connectionToken, generation)
        session.acceptCapabilities(
            capabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
                liveStreams = setOf(BandStreamKind.HEART_RATE),
                historyStreams = setOf(BandStreamKind.HEART_RATE),
            ),
            connectionToken,
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
                    operationClass = BandOperationClass.HISTORY,
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
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken = session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            scanToken,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-823930f",
        )
        completeConnection(session, identity, connectionToken, generation)
        session.acceptCapabilities(
            capabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.BATTERY),
                liveStreams = emptySet(),
                historyStreams = emptySet(),
            ),
            connectionToken,
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
                    operationClass = BandOperationClass.BATTERY,
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
    fun pendingLiveReceiptMakesEstablishedAuthenticationFailureBusyUntilAcknowledged() {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation, connectionToken) = readySessionWithStreams(
            diagnostics = diagnostics,
        )
        val liveToken = session.beginLive()
        val acceptance = session.stageLiveBatch(
            heartRateBatch(
                lane = BandProvenanceLane.LIVE,
                sequence = 10,
                deviceTimeMilliseconds = 10_000,
            ),
            liveToken,
            generation,
        )

        val failure = try {
            session.failEstablishedSession(
                BandFailureCategory.AUTHENTICATION,
                connectionToken,
                generation,
            )
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.BUSY, failure)
        val pending = session.snapshot()
        assertEquals(generation, pending.generation)
        assertEquals(BandSessionState.LIVE_COLLECTING, pending.state)
        assertEquals(true, pending.liveActive)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.AUTHENTICATION,
                outcome = BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.BUSY,
            ),
            diagnostics.snapshot().last(),
        )

        session.acknowledgeLive(
            DurableLiveReceipt(
                acceptance = acceptance,
                committedSamples = acceptance.acceptedSamples.size,
                committed = true,
            ),
            generation,
        )
        session.failEstablishedSession(
            BandFailureCategory.AUTHENTICATION,
            connectionToken,
            generation,
        )
        assertEquals(BandSessionState.REJECTED, session.snapshot().state)
    }

    @Test
    fun restartedLiveCollectionRejectsPriorSameSessionToken() {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation, _) = readySessionWithStreams(
            diagnostics = diagnostics,
        )
        val priorToken = session.beginLive()
        session.stopLive(priorToken)
        val currentToken = session.beginLive()

        val failure = try {
            session.stageLiveBatch(
                heartRateBatch(
                    lane = BandProvenanceLane.LIVE,
                    sequence = 11,
                    deviceTimeMilliseconds = 11_000,
                ),
                priorToken,
                generation,
            )
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.STALE_CALLBACK, failure)
        assertEquals(
            BandDiagnosticEvent(
                kind = BandDiagnosticKind.LIVE,
                outcome = BandDiagnosticOutcome.STALE,
                failureCategory = BandFailureCategory.STALE_CALLBACK,
            ),
            diagnostics.snapshot().last(),
        )

        val acceptance = session.stageLiveBatch(
            heartRateBatch(
                lane = BandProvenanceLane.LIVE,
                sequence = 11,
                deviceTimeMilliseconds = 11_000,
            ),
            currentToken,
            generation,
        )
        session.acknowledgeLive(
            DurableLiveReceipt(
                acceptance = acceptance,
                committedSamples = acceptance.acceptedSamples.size,
                committed = true,
            ),
            generation,
        )
        session.stopLive(currentToken)
    }

    @Test
    fun liveAndHistoryStreamSetsAuthorizeLanesIndependently() {
        val (historySession, historyGeneration, _) = readySessionWithStreams(
            liveStreams = emptySet(),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
        )
        val liveFailure = try {
            historySession.beginLive()
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.UNSUPPORTED, liveFailure)

        val historyToken =
            historySession.beginOperation(BandOperationClass.HISTORY)
        val historyAcceptance = historySession.stageHistoryChunk(
            heartRateHistoryChunk(
                chunkIdentity = "history-only-chunk",
                nextCursor = "history-only-cursor",
                acknowledgementToken = "history-only-ack",
                sequence = 20,
                deviceTimeMilliseconds = 20_000,
            ),
            historyToken,
            historyGeneration,
        )
        historySession.acknowledgeHistory(
            DurableHistoryReceipt(
                acceptance = historyAcceptance,
                historyStateCommitted = true,
                committedSamples = historyAcceptance.acceptedSamples.size,
                committed = true,
            ),
            historyToken,
            historyGeneration,
        )
        historySession.completeOperation(historyToken)

        val (liveSession, liveGeneration, _) = readySessionWithStreams(
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = emptySet(),
        )
        val liveToken = liveSession.beginLive()
        val liveAcceptance = liveSession.stageLiveBatch(
            heartRateBatch(
                lane = BandProvenanceLane.LIVE,
                sequence = 30,
                deviceTimeMilliseconds = 30_000,
            ),
            liveToken,
            liveGeneration,
        )
        liveSession.acknowledgeLive(
            DurableLiveReceipt(
                acceptance = liveAcceptance,
                committedSamples = liveAcceptance.acceptedSamples.size,
                committed = true,
            ),
            liveGeneration,
        )
        liveSession.stopLive(liveToken)

        val historyFailure = try {
            liveSession.beginOperation(BandOperationClass.HISTORY)
            null
        } catch (error: BandException) {
            error.category
        }
        assertEquals(BandFailureCategory.UNSUPPORTED, historyFailure)
    }

    @Test
    fun overflowRangesSurviveAcceptanceAndDurableReceipt() {
        val (session, generation, _) = readySessionWithStreams()
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val retainedRange = BandHistoryRange(
            startDeviceTimeMilliseconds = 40_000,
            endDeviceTimeMilliseconds = 49_999,
        )
        val firstLostRange = BandHistoryRange(
            startDeviceTimeMilliseconds = 30_000,
            endDeviceTimeMilliseconds = 39_999,
        )
        val acceptance = session.stageHistoryChunk(
            heartRateHistoryChunk(
                chunkIdentity = "overflow-chunk",
                nextCursor = "overflow-cursor",
                acknowledgementToken = "overflow-ack",
                sequence = 40,
                deviceTimeMilliseconds = 40_000,
                overflowed = true,
                retainedRange = retainedRange,
                firstLostRange = firstLostRange,
            ),
            token,
            generation,
        )
        assertEquals(retainedRange, acceptance.retainedRange)
        assertEquals(firstLostRange, acceptance.firstLostRange)

        val receipt = DurableHistoryReceipt(
            acceptance = acceptance,
            historyStateCommitted = true,
            committedSamples = acceptance.acceptedSamples.size,
            committed = true,
        )
        assertEquals(retainedRange, receipt.retainedRange)
        assertEquals(firstLostRange, receipt.firstLostRange)
        session.acknowledgeHistory(receipt, token, generation)
        session.completeOperation(token)
    }

    @Test
    fun callerMutableStreamSetsAreSnapshotted() {
        val liveStreams = mutableSetOf(BandStreamKind.HEART_RATE)
        val historyStreams = mutableSetOf(BandStreamKind.HEART_RATE)
        val (session, generation, _) = readySessionWithStreams(
            liveStreams = liveStreams,
            historyStreams = historyStreams,
        )
        liveStreams.clear()
        historyStreams.clear()

        val liveToken =
            session.beginLive(setOf(BandStreamKind.HEART_RATE))
        val liveAcceptance = session.stageLiveBatch(
            heartRateBatch(
                lane = BandProvenanceLane.LIVE,
                sequence = 50,
                deviceTimeMilliseconds = 50_000,
            ),
            liveToken,
            generation,
        )
        session.acknowledgeLive(
            DurableLiveReceipt(
                acceptance = liveAcceptance,
                committedSamples = liveAcceptance.acceptedSamples.size,
                committed = true,
            ),
            generation,
        )
        session.stopLive(liveToken)

        val historyToken = session.beginOperation(BandOperationClass.HISTORY)
        val historyAcceptance = session.stageHistoryChunk(
            heartRateHistoryChunk(
                chunkIdentity = "snapshot-chunk",
                nextCursor = "snapshot-cursor",
                acknowledgementToken = "snapshot-ack",
                sequence = 51,
                deviceTimeMilliseconds = 51_000,
            ),
            historyToken,
            generation,
        )
        session.acknowledgeHistory(
            DurableHistoryReceipt(
                acceptance = historyAcceptance,
                historyStateCommitted = true,
                committedSamples = historyAcceptance.acceptedSamples.size,
                committed = true,
            ),
            historyToken,
            generation,
        )
        session.completeOperation(historyToken)
    }

    @Test
    fun invalidHistoryTokensRecordBoundedRejections() {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation, _) = readyHistorySession(diagnostics)
        val supersededToken =
            session.beginOperation(BandOperationClass.HISTORY)
        session.cancelOperation(supersededToken)
        val activeToken = session.beginOperation(BandOperationClass.HISTORY)
        val (foreignSession, _, _) = readyHistorySession()
        val foreignToken =
            foreignSession.beginOperation(BandOperationClass.HISTORY)
        val chunk = BandHistoryChunk(
            chunkIdentity = "synthetic-chunk",
            previousCursor = null,
            nextCursor = "cursor-1",
            complete = true,
            overflowed = false,
            retainedRange = null,
            firstLostRange = null,
            acknowledgementToken = "ack-1",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = "synthetic-source",
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
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
            committedSamples = acceptance.acceptedSamples.size,
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
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken = session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            scanToken,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-823930f",
        )
        completeConnection(session, identity, connectionToken, generation)
        val mutableCapabilities = mutableSetOf(BandCapability.HEART_RATE)
        val report = capabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = identity.protocolVersion,
            hardwareRevision = identity.hardwareRevision,
            firmwareVersion = identity.firmwareVersion,
            historyDays = 7,
            capabilities = mutableCapabilities,
            liveStreams = mutableSetOf(BandStreamKind.HEART_RATE),
            historyStreams = mutableSetOf(BandStreamKind.HEART_RATE),
        )
        session.acceptCapabilities(report, connectionToken, generation)
        session.acceptCapabilities(report, connectionToken, generation)
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
    fun malformedLateCapabilityCallbackPreservesReadySession() {
        val malformedCapabilities = listOf(
            TraversalFailureSet(BandCapability.BATTERY),
            MutationDuringTraversalSet(
                BandCapability.BATTERY,
                BandCapability.HAPTICS,
            ),
        )

        malformedCapabilities.forEach { capabilities ->
            val diagnostics = BandDiagnosticsRecorder()
            val session = NoopBandSdkBoundary.newSession(diagnostics = diagnostics)
            val scanToken = session.beginScan()
            val generation = scanToken.generation
            val connectionToken = session.selectCandidate(
                BandPairingCandidate(
                    handle = "synthetic-candidate",
                    compatible = true,
                    identifyEligible = true,
                ),
                scanToken,
            )
            val identity = BandIdentity(
                sourceIdentity = "synthetic-source",
                hardwareRevision = "synthetic-hw-1",
                firmwareVersion = "synthetic-fw-1",
                protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
                wrapperRevision = "artifact-9bc2eed",
            )
            completeConnection(session, identity, connectionToken, generation)
            val report = capabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
                liveStreams = setOf(BandStreamKind.HEART_RATE),
                historyStreams = setOf(BandStreamKind.HEART_RATE),
            )
            session.acceptCapabilities(report, connectionToken, generation)
            val before = session.snapshot()

            val failure = try {
                session.acceptCapabilities(
                    report.copy(capabilities = capabilities),
                    connectionToken,
                    generation,
                )
                null
            } catch (error: BandException) {
                error.category
            }

            assertEquals(BandFailureCategory.INVALID_INPUT, failure)
            assertEquals(before, session.snapshot())
            assertEquals(
                BandDiagnosticEvent(
                    kind = BandDiagnosticKind.CAPABILITY,
                    outcome = BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
                diagnostics.snapshot().last(),
            )

            session.beginLive()
            assertEquals(
                BandSessionState.LIVE_COLLECTING,
                session.snapshot().state,
            )
        }
    }

    @Test
    fun requestedStreamsRejectSessionMutationReentry() {
        fun verifyRejectedMutation(
            mutate: (BandSessionMachine, Long) -> Unit,
        ) {
            val diagnostics = BandDiagnosticsRecorder()
            val (session, generation, _) =
                readySessionWithStreams(diagnostics)
            val before = session.snapshot()
            val eventCount = diagnostics.snapshot().size
            val requested = ReentrantTraversalSet(
                setOf(BandStreamKind.HEART_RATE),
            ) {
                mutate(session, generation)
            }

            val failure = try {
                session.beginLive(requested)
                null
            } catch (error: BandException) {
                error.category
            }

            assertEquals(BandFailureCategory.INVALID_INPUT, failure)
            assertEquals(before, session.snapshot())
            assertEquals(
                listOf(
                    BandDiagnosticEvent(
                        kind = BandDiagnosticKind.DISCONNECT,
                        outcome = BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.INVALID_INPUT,
                    ),
                    BandDiagnosticEvent(
                        kind = BandDiagnosticKind.LIVE,
                        outcome = BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.INVALID_INPUT,
                    ),
                ),
                diagnostics.snapshot().drop(eventCount),
            )

            session.beginLive()
            assertEquals(
                BandSessionState.LIVE_COLLECTING,
                session.snapshot().state,
            )
        }

        verifyRejectedMutation { session, _ ->
            session.close()
        }
        verifyRejectedMutation { session, generation ->
            session.disconnect(
                BandDisconnectReason.USER_PAUSED,
                generation,
            )
        }
    }

    @Test
    fun allExportedConformanceScenariosMatchContractInAppModule() {
        val contract = JSONObject(contractFile().readText())
        assertEquals(1, contract.getInt("schemaVersion"))
        val scenarios = contract.getJSONArray("scenarios")
        val automated = (0 until scenarios.length())
            .map { scenarios.getJSONObject(it) }
            .filter { it.getBoolean("automated") }

        assertEquals(50, automated.size)
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

    private fun readySessionWithStreams(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        liveStreams: Set<BandStreamKind> =
            setOf(BandStreamKind.HEART_RATE),
        historyStreams: Set<BandStreamKind> =
            setOf(BandStreamKind.HEART_RATE),
    ): Triple<BandSessionMachine, Long, BandConnectionToken> {
        val session = NoopBandSdkBoundary.newSession(diagnostics = diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken = session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            scanToken,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-823930f",
        )
        completeConnection(session, identity, connectionToken, generation)
        session.acceptCapabilities(
            capabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
                liveStreams = liveStreams,
                historyStreams = historyStreams,
            ),
            connectionToken,
            generation,
        )
        return Triple(session, generation, connectionToken)
    }

    private fun heartRateBatch(
        lane: BandProvenanceLane,
        sequence: Long,
        deviceTimeMilliseconds: Long,
    ): BandSampleBatch = BandSampleBatch(
        sourceIdentity = "synthetic-source",
        lane = lane,
        parserRevision = "parser-v1",
        calibrationRevision = "calibration-v1",
        samples = listOf(
            BandSample(
                identity = BandSampleIdentity(
                    stream = BandStreamKind.HEART_RATE,
                    sequence = sequence,
                    deviceTimeMilliseconds = deviceTimeMilliseconds,
                ),
                value = 72.0,
                unit = BandUnit.BEATS_PER_MINUTE,
                quality = BandSampleQuality.ACCEPTED,
            ),
        ),
    )

    private fun heartRateHistoryChunk(
        chunkIdentity: String,
        nextCursor: String,
        acknowledgementToken: String,
        sequence: Long,
        deviceTimeMilliseconds: Long,
        overflowed: Boolean = false,
        retainedRange: BandHistoryRange? = null,
        firstLostRange: BandHistoryRange? = null,
    ): BandHistoryChunk = BandHistoryChunk(
        chunkIdentity = chunkIdentity,
        previousCursor = null,
        nextCursor = nextCursor,
        complete = true,
        overflowed = overflowed,
        retainedRange = retainedRange,
        firstLostRange = firstLostRange,
        acknowledgementToken = acknowledgementToken,
        batches = listOf(
            heartRateBatch(
                lane = BandProvenanceLane.HISTORY,
                sequence = sequence,
                deviceTimeMilliseconds = deviceTimeMilliseconds,
            ),
        ),
    )

    private fun readyHistorySession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    ): Triple<BandSessionMachine, Long, BandConnectionToken> {
        val session = NoopBandSdkBoundary.newSession(diagnostics = diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken = session.selectCandidate(
            BandPairingCandidate(
                handle = "synthetic-candidate",
                compatible = true,
                identifyEligible = true,
            ),
            scanToken,
        )
        val identity = BandIdentity(
            sourceIdentity = "synthetic-source",
            hardwareRevision = "synthetic-hw-1",
            firmwareVersion = "synthetic-fw-1",
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            wrapperRevision = "artifact-823930f",
        )
        completeConnection(session, identity, connectionToken, generation)
        session.acceptCapabilities(
            capabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = identity.protocolVersion,
                hardwareRevision = identity.hardwareRevision,
                firmwareVersion = identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(BandCapability.HEART_RATE),
                liveStreams = setOf(BandStreamKind.HEART_RATE),
                historyStreams = setOf(BandStreamKind.HEART_RATE),
            ),
            connectionToken,
            generation,
        )
        return Triple(session, generation, connectionToken)
    }

    private fun capabilityReport(
        schemaVersion: Int,
        protocolVersion: String,
        hardwareRevision: String,
        firmwareVersion: String,
        historyDays: Int,
        capabilities: Set<BandCapability>,
        liveStreams: Set<BandStreamKind>,
        historyStreams: Set<BandStreamKind>,
    ): BandCapabilityReport = BandCapabilityReport(
        schemaVersion = schemaVersion,
        reportRevision = "virtual-report-v1",
        protocolVersion = protocolVersion,
        hardwareRevision = hardwareRevision,
        firmwareVersion = firmwareVersion,
        historyDays = historyDays,
        capabilities = capabilities,
        liveStreams = liveStreams,
        historyStreams = historyStreams,
        operationsAllowedDuringLive = BandOperationClass.entries
            .filterTo(mutableSetOf()) { it != BandOperationClass.FIRMWARE },
        streamSemantics = BandCapabilityReport.virtualStreamSemantics(
            liveStreams = liveStreams,
            historyStreams = historyStreams,
        ),
    )

    private fun completeConnection(
        session: BandSessionMachine,
        identity: BandIdentity,
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        session.beginConnection(token, callbackGeneration)
        session.beginAuthentication(token, callbackGeneration)
        session.completeConnection(identity, token, callbackGeneration)
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else getString(key)
}
