package com.noop.bandsdk

import java.util.ArrayDeque
import java.util.UUID

class BandSessionMachine(
    private val diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    restoredHistoryCheckpoint: BandHistoryCheckpoint? = null,
) {
    private data class PendingLive(
        val acceptance: LiveAcceptance,
        val sampleIdentities: List<BandSampleIdentity>,
    )

    private data class PendingHistory(
        val acceptance: HistoryAcceptance,
        val sampleIdentities: List<BandSampleIdentity>,
    )

    private val restoredHistoryCheckpoint =
        restoredHistoryCheckpoint?.immutableSnapshot()
    private val sessionNonce = UUID.randomUUID()
    private var state = BandSessionState.IDLE
    private var generation = 0L
    private var nextOperationSequence = 0L
    private var nextLiveReceiptSequence = 0L
    private var nextHistoryReceiptSequence = 0L
    private var activeOperation: BandOperationToken? = null
    private var liveActive = false
    private var liveStreams = emptySet<BandStreamKind>()
    private var identity: BandIdentity? = null
    private var capabilityReport: BandCapabilityReport? = null
    private var pendingLive: PendingLive? = null
    private var pendingHistory: PendingHistory? = null
    private var lastDurableHistoryComplete: Boolean? = null
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Boolean? = null
    private val durableSampleIdentities = mutableSetOf<BandSampleIdentity>()
    private val durableSampleIdentityOrder = ArrayDeque<BandSampleIdentity>()
    private var durableSourceIdentity: String? = null
    private var restoredHistoryCheckpointConsumed = false
    private var acknowledgedHistoryCursor: String? = null

    @Synchronized
    fun snapshot(): BandSessionSnapshot = BandSessionSnapshot(
        state = state,
        generation = generation,
        activeOperation = activeOperation?.operationClass,
        liveActive = liveActive,
        acknowledgedHistoryCursor = acknowledgedHistoryCursor,
        durableSampleCount = durableSampleIdentities.size,
    )

    @Synchronized
    fun historyCheckpoint(): BandHistoryCheckpoint? {
        val sourceIdentity =
            durableSourceIdentity ?: identity?.sourceIdentity ?: return null
        return BandHistoryCheckpoint(
            sourceIdentity = sourceIdentity,
            acknowledgedCursor = acknowledgedHistoryCursor,
            lastHistoryComplete = lastDurableHistoryComplete,
            durableSampleIdentities = durableSampleIdentities.toSet(),
        )
    }

    @Synchronized
    fun beginScan(): Long {
        ensureNotClosed()
        if (
            state != BandSessionState.IDLE &&
            state != BandSessionState.RECOVERING &&
            state != BandSessionState.REJECTED
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        clearOperationTracking()
        clearLiveTracking()
        identity = null
        capabilityReport = null
        state = BandSessionState.SCANNING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
        return generation
    }

    @Synchronized
    fun selectCandidate(
        candidate: BandPairingCandidate,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        try {
            candidate.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        if (
            state != BandSessionState.SCANNING ||
            !candidate.compatible ||
            !candidate.identifyEligible
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.REJECTED,
                ),
            )
            fail(BandFailureCategory.REJECTED)
        }
        state = BandSessionState.CANDIDATE_SELECTED
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.ONE,
            ),
        )
    }

    @Synchronized
    fun cancelScan(callbackGeneration: Long) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        if (state != BandSessionState.SCANNING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        state = BandSessionState.IDLE
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failScan(
        category: BandFailureCategory,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        if (state != BandSessionState.SCANNING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (category !in scanFailureCategories) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        generation += 1
        state = BandSessionState.IDLE
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                if (category == BandFailureCategory.TIMEOUT) {
                    BandDiagnosticOutcome.TIMED_OUT
                } else {
                    BandDiagnosticOutcome.FAILED
                },
                failureCategory = category,
            ),
        )
    }

    @Synchronized
    fun beginConnection(callbackGeneration: Long) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.CONNECTION,
        )
        if (state != BandSessionState.CANDIDATE_SELECTED) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CONNECTION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        state = BandSessionState.CONNECTING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CONNECTION,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
    }

    @Synchronized
    fun beginAuthentication(callbackGeneration: Long) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.AUTHENTICATION,
        )
        if (state != BandSessionState.CONNECTING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        state = BandSessionState.AUTHENTICATING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.AUTHENTICATION,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
    }

    @Synchronized
    fun completeConnection(
        newIdentity: BandIdentity,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.AUTHENTICATION,
        )
        if (state != BandSessionState.AUTHENTICATING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        try {
            newIdentity.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        prepareDurableState(newIdentity.sourceIdentity)
        capabilityReport = null
        identity = newIdentity
        state = BandSessionState.NEGOTIATING_CAPABILITIES
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.AUTHENTICATION,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun cancelConnection(
        phase: BandConnectionPhase,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        val diagnosticKind = diagnosticKind(phase)
        validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind,
        )
        if (state != sessionState(phase)) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        clearConnectionAttempt(BandSessionState.IDLE)
        diagnostics.record(
            BandDiagnosticEvent(
                diagnosticKind,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failConnection(
        category: BandFailureCategory,
        phase: BandConnectionPhase,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        val diagnosticKind = diagnosticKind(phase)
        validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind,
        )
        if (state != sessionState(phase)) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (category !in connectionFailureCategories) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        val terminalState = when (category) {
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            -> BandSessionState.REJECTED
            BandFailureCategory.SECURITY_FAILURE ->
                BandSessionState.SECURITY_FAILURE
            else -> BandSessionState.RECOVERING
        }
        clearConnectionAttempt(terminalState)
        val outcome = when (category) {
            BandFailureCategory.TIMEOUT -> BandDiagnosticOutcome.TIMED_OUT
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            -> BandDiagnosticOutcome.REJECTED
            else -> BandDiagnosticOutcome.FAILED
        }
        diagnostics.record(
            BandDiagnosticEvent(
                diagnosticKind,
                outcome,
                failureCategory = category,
            ),
        )
    }

    @Synchronized
    fun acceptCapabilities(
        report: BandCapabilityReport,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.CAPABILITY,
        )
        val immutableReport = report.immutableSnapshot()
        val currentIdentity = identity
        val identityMatches =
            currentIdentity?.hardwareRevision == immutableReport.hardwareRevision &&
                currentIdentity.firmwareVersion == immutableReport.firmwareVersion &&
                currentIdentity.protocolVersion == immutableReport.protocolVersion
        if (state != BandSessionState.NEGOTIATING_CAPABILITIES) {
            if (identityMatches && capabilityReport == immutableReport) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.CAPABILITY,
                        BandDiagnosticOutcome.STALE,
                    ),
                )
                return
            }
            rejectCapabilities(mutateSession = false)
        }
        if (
            !identityMatches
        ) {
            rejectCapabilities(mutateSession = true)
        }
        try {
            immutableReport.validate()
        } catch (_: BandException) {
            rejectCapabilities(mutateSession = true)
        }
        capabilityReport = immutableReport
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(immutableReport.capabilities.size),
            ),
        )
    }

    @Synchronized
    fun beginLive(requestedStreams: Set<BandStreamKind>? = null) {
        try {
            ensureReadyForOperation()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        val negotiatedStreams = BandStreamKind.entries.filterTo(mutableSetOf()) {
            requiredCapability(it) in capabilityReport?.capabilities.orEmpty()
        }
        val selectedStreams = requestedStreams?.toSet() ?: negotiatedStreams
        if (
            selectedStreams.isEmpty() ||
            !negotiatedStreams.containsAll(selectedStreams)
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
        liveStreams = selectedStreams
        liveActive = true
        state = BandSessionState.LIVE_COLLECTING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
    }

    @Synchronized
    fun stopLive() {
        ensureNotClosed()
        if (!liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (pendingLive != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (activeOperation != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        clearLiveTracking()
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun stageLiveBatch(
        batch: BandSampleBatch,
        callbackGeneration: Long,
    ): LiveAcceptance {
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.LIVE,
        )
        val immutableBatch = batch.immutableSnapshot()
        if (
            !liveActive ||
            (state != BandSessionState.LIVE_COLLECTING && activeOperation == null)
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (immutableBatch.sourceIdentity != identity?.sourceIdentity) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        if (pendingLive != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        try {
            immutableBatch.validate(BandProvenanceLane.LIVE)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        validateNegotiatedStreams(
            immutableBatch.samples,
            BandDiagnosticKind.LIVE,
            liveStreams,
        )
        val acceptedIdentities = mutableSetOf<BandSampleIdentity>()
        val unique = immutableBatch.samples.filter {
            it.identity !in durableSampleIdentities &&
                acceptedIdentities.add(it.identity)
        }
        nextLiveReceiptSequence += 1
        val acceptance = LiveAcceptance(
            acceptedSamples = unique,
            duplicateSamples = immutableBatch.samples.size - unique.size,
            sessionNonce = sessionNonce,
            generation = generation,
            receiptSequence = nextLiveReceiptSequence,
        )
        pendingLive = PendingLive(
            acceptance = acceptance,
            sampleIdentities = unique.map(BandSample::identity),
        )
        return acceptance
    }

    @Synchronized
    fun acknowledgeLive(
        receipt: DurableLiveReceipt,
        callbackGeneration: Long,
    ) {
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.LIVE,
        )
        validateSessionNonce(
            receipt.sessionNonce,
            BandDiagnosticKind.LIVE,
        )
        val pending = pendingLive
        if (
            pending == null ||
            receipt.generation != pending.acceptance.generation ||
            receipt.receiptSequence != pending.acceptance.receiptSequence
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            !receipt.committed ||
            receipt.committedSamples < pending.acceptance.acceptedSamples.size
        ) {
            pendingLive = null
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        rememberDurableSampleIdentities(pending.sampleIdentities)
        pendingLive = null
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(receipt.committedSamples),
            ),
        )
    }

    @Synchronized
    fun beginOperation(
        operationClass: BandOperationClass,
        requiredCapability: BandCapability? = null,
    ): BandOperationToken {
        val operationDiagnosticKind = diagnosticKind(operationClass)
        try {
            ensureNotClosed()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (activeOperation != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        try {
            ensureReadyForOperation()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (operationClass == BandOperationClass.FIRMWARE && liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (
            operationClass == BandOperationClass.FIRMWARE &&
            capabilityReport?.capabilities?.contains(BandCapability.FIRMWARE_UPDATE) != true
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UPDATE_NOT_ELIGIBLE,
                ),
            )
            fail(BandFailureCategory.UPDATE_NOT_ELIGIBLE)
        }
        if (
            operationClass == BandOperationClass.HISTORY &&
            (capabilityReport?.historyDays ?: 0) <= 0
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
        if (operationClass == BandOperationClass.SAMPLING) {
            val negotiated = capabilityReport?.capabilities.orEmpty()
            val eligible = if (requiredCapability != null) {
                requiredCapability in samplingCapabilities &&
                    requiredCapability in negotiated
            } else {
                negotiated.any { it in samplingCapabilities }
            }
            if (!eligible) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        operationDiagnosticKind,
                        BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.UNSUPPORTED,
                    ),
                )
                fail(BandFailureCategory.UNSUPPORTED)
            }
        } else {
            listOfNotNull(
                impliedCapability(operationClass),
                requiredCapability,
            ).forEach { capability ->
                if (capabilityReport?.capabilities?.contains(capability) != true) {
                    diagnostics.record(
                        BandDiagnosticEvent(
                            operationDiagnosticKind,
                            BandDiagnosticOutcome.REJECTED,
                            failureCategory = BandFailureCategory.UNSUPPORTED,
                        ),
                    )
                    fail(BandFailureCategory.UNSUPPORTED)
                }
            }
        }

        nextOperationSequence += 1
        val token = BandOperationToken(
            sessionNonce,
            generation,
            nextOperationSequence,
            operationClass,
        )
        activeOperation = token
        state = when (operationClass) {
            BandOperationClass.HISTORY -> {
                historyOperationReceivedDurableReceipt = false
                historyOperationLastReceiptComplete = null
                BandSessionState.HISTORY_COLLECTING
            }
            BandOperationClass.FIRMWARE -> BandSessionState.UPDATING_FIRMWARE
            else -> BandSessionState.EXECUTING_COMMAND
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
        return token
    }

    @Synchronized
    fun stageHistoryChunk(
        chunk: BandHistoryChunk,
        token: BandOperationToken,
        callbackGeneration: Long,
    ): HistoryAcceptance {
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.HISTORY,
        )
        validateActiveToken(token, BandOperationClass.HISTORY)
        val immutableChunk = chunk.immutableSnapshot()
        if (pendingHistory != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (historyOperationLastReceiptComplete == true) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        try {
            immutableChunk.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        validateNegotiatedStreams(
            immutableChunk.batches.flatMap(BandSampleBatch::samples),
            BandDiagnosticKind.HISTORY,
        )
        if (immutableChunk.previousCursor != acknowledgedHistoryCursor) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (
            !immutableChunk.complete &&
            (
                immutableChunk.nextCursor == null ||
                    immutableChunk.nextCursor == immutableChunk.previousCursor
                )
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (
            immutableChunk.batches.any {
                it.sourceIdentity != identity?.sourceIdentity
            }
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val uniqueSet = mutableSetOf<BandSampleIdentity>()
        val unique = mutableListOf<BandSampleIdentity>()
        var duplicates = 0
        immutableChunk.batches
            .flatMap(BandSampleBatch::samples)
            .forEach { sample ->
            if (
                sample.identity in durableSampleIdentities ||
                !uniqueSet.add(sample.identity)
            ) {
                duplicates += 1
            } else {
                unique += sample.identity
            }
        }
        nextHistoryReceiptSequence += 1
        val acceptance = HistoryAcceptance(
            chunkIdentity = immutableChunk.chunkIdentity,
            acknowledgementToken = immutableChunk.acknowledgementToken,
            nextCursor = immutableChunk.nextCursor,
            complete = immutableChunk.complete,
            overflowed = immutableChunk.overflowed,
            acceptedSamples = unique.size,
            duplicateSamples = duplicates,
            sessionNonce = sessionNonce,
            receiptSequence = nextHistoryReceiptSequence,
        )
        pendingHistory = PendingHistory(acceptance, unique)
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(unique.size),
            ),
        )
        return acceptance
    }

    @Synchronized
    fun acknowledgeHistory(
        receipt: DurableHistoryReceipt,
        token: BandOperationToken,
        callbackGeneration: Long,
    ) {
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.HISTORY,
        )
        validateSessionNonce(
            receipt.sessionNonce,
            BandDiagnosticKind.HISTORY,
        )
        validateActiveToken(token, BandOperationClass.HISTORY)
        val pending = pendingHistory
        if (
            pending == null ||
            receipt.receiptSequence != pending.acceptance.receiptSequence ||
            !receipt.committed ||
            receipt.chunkIdentity != pending.acceptance.chunkIdentity ||
            receipt.acknowledgementToken != pending.acceptance.acknowledgementToken ||
            receipt.nextCursor != pending.acceptance.nextCursor ||
            receipt.complete != pending.acceptance.complete ||
            receipt.overflowed != pending.acceptance.overflowed ||
            !receipt.historyStateCommitted ||
            receipt.committedSamples < pending.acceptance.acceptedSamples
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }

        rememberDurableSampleIdentities(pending.sampleIdentities)
        acknowledgedHistoryCursor = receipt.nextCursor
        lastDurableHistoryComplete = pending.acceptance.complete
        historyOperationReceivedDurableReceipt = true
        historyOperationLastReceiptComplete = pending.acceptance.complete
        pendingHistory = null
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(receipt.committedSamples),
            ),
        )
    }

    @Synchronized
    fun completeOperation(token: BandOperationToken) {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            pendingHistory != null
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            !historyOperationReceivedDurableReceipt
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            historyOperationLastReceiptComplete != true
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun cancelOperation(token: BandOperationToken) {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failOperation(
        token: BandOperationToken,
        category: BandFailureCategory,
    ) {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (category == BandFailureCategory.SECURITY_FAILURE) {
            invalidateAuthenticatedSession(BandSessionState.SECURITY_FAILURE)
        } else if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else if (category == BandFailureCategory.DISCONNECTED) {
            clearOperationTracking()
            clearLiveTracking()
            generation += 1
            state = BandSessionState.RECOVERING
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.FAILED,
                failureCategory = category,
            ),
        )
        if (category == BandFailureCategory.DISCONNECTED) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.INTERRUPTED,
                    failureCategory = BandFailureCategory.DISCONNECTED,
                ),
            )
        }
    }

    @Synchronized
    fun interruptForReconnect(callbackGeneration: Long): Long {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.RECONNECT,
        )
        if (
            state == BandSessionState.IDLE ||
            state == BandSessionState.INCOMPATIBLE ||
            state == BandSessionState.REJECTED ||
            state == BandSessionState.SECURITY_FAILURE
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        val interruptedOperationKind = activeOperation?.let {
            diagnosticKind(it.operationClass)
        }
        val firmwareWasActive =
            activeOperation?.operationClass == BandOperationClass.FIRMWARE
        clearOperationTracking()
        clearLiveTracking()
        if (firmwareWasActive) {
            identity = null
            capabilityReport = null
        }
        generation += 1
        state = BandSessionState.RECOVERING
        interruptedOperationKind?.let {
            diagnostics.record(
                BandDiagnosticEvent(
                    it,
                    BandDiagnosticOutcome.INTERRUPTED,
                    failureCategory = BandFailureCategory.DISCONNECTED,
                ),
            )
        }
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.RECONNECT,
                BandDiagnosticOutcome.INTERRUPTED,
            ),
        )
        return generation
    }

    @Synchronized
    fun resumeAfterReconnect(callbackGeneration: Long) {
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.RECONNECT,
        )
        if (
            state != BandSessionState.RECOVERING ||
            identity == null ||
            capabilityReport == null
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.RECONNECT,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun close() {
        generation += 1
        clearOperationTracking()
        clearLiveTracking()
        identity = null
        capabilityReport = null
        state = BandSessionState.CLOSED
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CONNECTION,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    private fun rejectCapabilities(mutateSession: Boolean): Nothing {
        if (mutateSession) {
            state = BandSessionState.INCOMPATIBLE
            capabilityReport = null
        }
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.REJECTED,
                failureCategory = if (mutateSession) {
                    BandFailureCategory.INCOMPATIBLE
                } else {
                    BandFailureCategory.INVALID_STATE
                },
            ),
        )
        fail(
            if (mutateSession) {
                BandFailureCategory.INCOMPATIBLE
            } else {
                BandFailureCategory.INVALID_STATE
            },
        )
    }

    private fun validateCallbackGeneration(
        callbackGeneration: Long,
        diagnosticKind: BandDiagnosticKind,
    ) {
        if (callbackGeneration != generation) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateActiveToken(
        token: BandOperationToken,
        expected: BandOperationClass,
    ) {
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation
        ) {
            fail(BandFailureCategory.STALE_CALLBACK)
        }
        if (token.operationClass != expected || token != activeOperation) {
            fail(BandFailureCategory.INVALID_STATE)
        }
    }

    private fun validateSessionNonce(
        candidate: UUID,
        diagnosticKind: BandDiagnosticKind,
    ) {
        if (candidate != sessionNonce) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun ensureReadyForOperation() {
        ensureNotClosed()
        if (
            state != BandSessionState.READY &&
            state != BandSessionState.LIVE_COLLECTING
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
    }

    private fun ensureNotClosed() {
        if (state == BandSessionState.CLOSED) {
            fail(BandFailureCategory.CLOSED)
        }
    }

    private val samplingCapabilities: Set<BandCapability>
        get() = setOf(
            BandCapability.HEART_RATE,
            BandCapability.RR_INTERVALS,
            BandCapability.STEPS,
            BandCapability.SPO2,
            BandCapability.RESPIRATION,
            BandCapability.TEMPERATURE,
            BandCapability.ACCELEROMETER,
        )

    private val scanFailureCategories: Set<BandFailureCategory>
        get() = setOf(
            BandFailureCategory.NO_RESULT,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.PERMISSION,
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.INTERNAL_FAILURE,
        )

    private val connectionFailureCategories: Set<BandFailureCategory>
        get() = setOf(
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.PERMISSION,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            BandFailureCategory.DISCONNECTED,
            BandFailureCategory.INTERNAL_FAILURE,
        )

    private fun diagnosticKind(
        operationClass: BandOperationClass,
    ): BandDiagnosticKind = when (operationClass) {
        BandOperationClass.HISTORY -> BandDiagnosticKind.HISTORY
        BandOperationClass.FIRMWARE -> BandDiagnosticKind.FIRMWARE
        else -> BandDiagnosticKind.COMMAND
    }

    private fun clearActiveOperation() {
        clearOperationTracking()
        state = if (liveActive) {
            BandSessionState.LIVE_COLLECTING
        } else {
            BandSessionState.READY
        }
    }

    private fun invalidateNegotiationAfterFirmware() {
        invalidateAuthenticatedSession(BandSessionState.RECOVERING)
    }

    private fun clearLiveTracking() {
        liveActive = false
        liveStreams = emptySet()
        pendingLive = null
    }

    private fun clearOperationTracking() {
        activeOperation = null
        pendingHistory = null
        historyOperationReceivedDurableReceipt = false
        historyOperationLastReceiptComplete = null
    }

    private fun clearConnectionAttempt(nextState: BandSessionState) {
        invalidateAuthenticatedSession(nextState)
    }

    private fun invalidateAuthenticatedSession(nextState: BandSessionState) {
        clearOperationTracking()
        clearLiveTracking()
        identity = null
        capabilityReport = null
        generation += 1
        state = nextState
    }

    private fun diagnosticKind(
        phase: BandConnectionPhase,
    ): BandDiagnosticKind = when (phase) {
        BandConnectionPhase.CONNECTION -> BandDiagnosticKind.CONNECTION
        BandConnectionPhase.AUTHENTICATION ->
            BandDiagnosticKind.AUTHENTICATION
    }

    private fun sessionState(
        phase: BandConnectionPhase,
    ): BandSessionState = when (phase) {
        BandConnectionPhase.CONNECTION -> BandSessionState.CONNECTING
        BandConnectionPhase.AUTHENTICATION ->
            BandSessionState.AUTHENTICATING
        }

    private fun clearDurableSampleIdentities() {
        durableSampleIdentities.clear()
        durableSampleIdentityOrder.clear()
    }

    private fun restoreDurableSampleIdentities(
        identities: Set<BandSampleIdentity>,
    ) {
        clearDurableSampleIdentities()
        rememberDurableSampleIdentities(
            identities.sortedWith(
                compareBy<BandSampleIdentity> {
                    it.deviceTimeMilliseconds
                }.thenBy {
                    it.sequence
                }.thenBy {
                    it.stream.wireValue
                },
            ),
        )
    }

    private fun prepareDurableState(sourceIdentity: String) {
        if (
            durableSourceIdentity == null &&
            !restoredHistoryCheckpointConsumed &&
            restoredHistoryCheckpoint?.sourceIdentity == sourceIdentity
        ) {
            try {
                restoredHistoryCheckpoint.validate()
            } catch (_: BandException) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.HISTORY,
                        BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.INVALID_INPUT,
                    ),
                )
                fail(BandFailureCategory.INVALID_INPUT)
            }
            restoreDurableSampleIdentities(
                restoredHistoryCheckpoint.durableSampleIdentities,
            )
            acknowledgedHistoryCursor =
                restoredHistoryCheckpoint.acknowledgedCursor
            lastDurableHistoryComplete =
                restoredHistoryCheckpoint.lastHistoryComplete
            durableSourceIdentity = sourceIdentity
            restoredHistoryCheckpointConsumed = true
        } else if (durableSourceIdentity != sourceIdentity) {
            clearDurableSampleIdentities()
            acknowledgedHistoryCursor = null
            lastDurableHistoryComplete = null
            durableSourceIdentity = sourceIdentity
            restoredHistoryCheckpointConsumed = true
        }
    }

    private fun rememberDurableSampleIdentities(
        identities: List<BandSampleIdentity>,
    ) {
        identities.forEach { identity ->
            if (identity !in durableSampleIdentities) {
                if (
                    durableSampleIdentities.size ==
                    BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES
                ) {
                    durableSampleIdentities.remove(
                        durableSampleIdentityOrder.removeFirst(),
                    )
                }
                durableSampleIdentities.add(identity)
                durableSampleIdentityOrder.addLast(identity)
            }
        }
    }

    private fun validateNegotiatedStreams(
        samples: List<BandSample>,
        diagnosticKind: BandDiagnosticKind,
        allowedStreams: Set<BandStreamKind>? = null,
    ) {
        val capabilities = capabilityReport?.capabilities
        if (
            capabilities == null ||
            samples.any {
                requiredCapability(it.identity.stream) !in capabilities ||
                    (
                        allowedStreams != null &&
                            it.identity.stream !in allowedStreams
                        )
            }
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
    }

    private fun requiredCapability(
        stream: BandStreamKind,
    ): BandCapability = when (stream) {
        BandStreamKind.HEART_RATE -> BandCapability.HEART_RATE
        BandStreamKind.RR_INTERVAL -> BandCapability.RR_INTERVALS
        BandStreamKind.STEPS -> BandCapability.STEPS
        BandStreamKind.SPO2 -> BandCapability.SPO2
        BandStreamKind.RESPIRATION -> BandCapability.RESPIRATION
        BandStreamKind.TEMPERATURE -> BandCapability.TEMPERATURE
        BandStreamKind.ACCELERATION -> BandCapability.ACCELEROMETER
    }

    private fun impliedCapability(
        operationClass: BandOperationClass,
    ): BandCapability? = when (operationClass) {
        BandOperationClass.BATTERY -> BandCapability.BATTERY
        BandOperationClass.WEAR_STATE -> BandCapability.WEAR_STATE
        BandOperationClass.HAPTIC -> BandCapability.HAPTICS
        BandOperationClass.ALARM -> BandCapability.ALARMS
        BandOperationClass.HISTORY,
        BandOperationClass.SAMPLING,
        BandOperationClass.FIRMWARE,
        -> null
    }
}
