package com.noop.bandsdk

import java.util.ArrayDeque

class BandSessionMachine(
    private val diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    private val restoredHistoryCheckpoint: BandHistoryCheckpoint? = null,
) {
    private data class PendingHistory(
        val acceptance: HistoryAcceptance,
        val sampleIdentities: List<BandSampleIdentity>,
    )

    private var state = BandSessionState.IDLE
    private var generation = 0L
    private var nextOperationSequence = 0L
    private var activeOperation: BandOperationToken? = null
    private var liveActive = false
    private var identity: BandIdentity? = null
    private var capabilityReport: BandCapabilityReport? = null
    private var pendingHistory: PendingHistory? = null
    private var lastDurableHistoryComplete: Boolean? = null
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Boolean? = null
    private val durableSampleIdentities = mutableSetOf<BandSampleIdentity>()
    private val durableSampleIdentityOrder = ArrayDeque<BandSampleIdentity>()
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
        val sourceIdentity = identity?.sourceIdentity ?: return null
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
        if (state != BandSessionState.IDLE && state != BandSessionState.RECOVERING) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        clearOperationTracking()
        liveActive = false
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
    fun selectCandidate(candidate: BandPairingCandidate) {
        ensureNotClosed()
        try {
            candidate.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
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
    fun connect(newIdentity: BandIdentity) {
        ensureNotClosed()
        if (state != BandSessionState.CANDIDATE_SELECTED) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        newIdentity.validate()
        if (
            identity == null &&
            restoredHistoryCheckpoint?.sourceIdentity == newIdentity.sourceIdentity
        ) {
            restoredHistoryCheckpoint.validate()
            restoreDurableSampleIdentities(
                restoredHistoryCheckpoint.durableSampleIdentities,
            )
            acknowledgedHistoryCursor =
                restoredHistoryCheckpoint.acknowledgedCursor
            lastDurableHistoryComplete =
                restoredHistoryCheckpoint.lastHistoryComplete
        } else if (identity?.sourceIdentity != newIdentity.sourceIdentity) {
            clearDurableSampleIdentities()
            acknowledgedHistoryCursor = null
            lastDurableHistoryComplete = null
        }
        capabilityReport = null
        state = BandSessionState.CONNECTING
        identity = newIdentity
        state = BandSessionState.AUTHENTICATING
        state = BandSessionState.NEGOTIATING_CAPABILITIES
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CONNECTION,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun acceptCapabilities(
        report: BandCapabilityReport,
        callbackGeneration: Long,
    ) {
        ensureNotClosed()
        validateCallbackGeneration(callbackGeneration)
        val currentIdentity = identity
        if (
            state != BandSessionState.NEGOTIATING_CAPABILITIES ||
            currentIdentity?.hardwareRevision != report.hardwareRevision ||
            currentIdentity.firmwareVersion != report.firmwareVersion ||
            currentIdentity.protocolVersion != report.protocolVersion
        ) {
            rejectCapabilities()
        }
        try {
            report.validate()
        } catch (_: BandException) {
            rejectCapabilities()
        }
        capabilityReport = report
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(report.capabilities.size),
            ),
        )
    }

    @Synchronized
    fun beginLive() {
        ensureReadyForOperation()
        if (liveActive) {
            fail(BandFailureCategory.BUSY)
        }
        if (capabilityReport?.capabilities?.contains(BandCapability.HEART_RATE) != true) {
            fail(BandFailureCategory.UNSUPPORTED)
        }
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
        if (!liveActive || activeOperation != null) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        liveActive = false
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun commitLiveBatch(
        batch: BandSampleBatch,
        callbackGeneration: Long,
    ): Int {
        validateCallbackGeneration(callbackGeneration)
        if (
            !liveActive ||
            (state != BandSessionState.LIVE_COLLECTING && activeOperation == null) ||
            batch.sourceIdentity != identity?.sourceIdentity
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        batch.validate(BandProvenanceLane.LIVE)
        validateNegotiatedStreams(batch.samples, BandDiagnosticKind.LIVE)
        val acceptedIdentities = mutableSetOf<BandSampleIdentity>()
        val unique = batch.samples.filter {
            it.identity !in durableSampleIdentities &&
                acceptedIdentities.add(it.identity)
        }
        rememberDurableSampleIdentities(unique.map(BandSample::identity))
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(unique.size),
            ),
        )
        return unique.size
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
        validateCallbackGeneration(callbackGeneration)
        validateActiveToken(token, BandOperationClass.HISTORY)
        if (pendingHistory != null) {
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
        chunk.validate()
        validateNegotiatedStreams(
            chunk.batches.flatMap(BandSampleBatch::samples),
            BandDiagnosticKind.HISTORY,
        )
        if (chunk.previousCursor != acknowledgedHistoryCursor) {
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
            !chunk.complete &&
            (chunk.nextCursor == null || chunk.nextCursor == chunk.previousCursor)
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
        if (chunk.batches.any { it.sourceIdentity != identity?.sourceIdentity }) {
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val uniqueSet = mutableSetOf<BandSampleIdentity>()
        val unique = mutableListOf<BandSampleIdentity>()
        var duplicates = 0
        chunk.batches.flatMap(BandSampleBatch::samples).forEach { sample ->
            if (
                sample.identity in durableSampleIdentities ||
                !uniqueSet.add(sample.identity)
            ) {
                duplicates += 1
            } else {
                unique += sample.identity
            }
        }
        val acceptance = HistoryAcceptance(
            chunkIdentity = chunk.chunkIdentity,
            acknowledgementToken = chunk.acknowledgementToken,
            nextCursor = chunk.nextCursor,
            complete = chunk.complete,
            overflowed = chunk.overflowed,
            acceptedSamples = unique.size,
            duplicateSamples = duplicates,
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
        validateCallbackGeneration(callbackGeneration)
        validateActiveToken(token, BandOperationClass.HISTORY)
        val pending = pendingHistory
        if (
            pending == null ||
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
        clearActiveOperation()
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
        clearActiveOperation()
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
        if (category == BandFailureCategory.DISCONNECTED) {
            clearOperationTracking()
            liveActive = false
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
    fun interruptForReconnect(): Long {
        ensureNotClosed()
        if (
            state == BandSessionState.IDLE ||
            state == BandSessionState.INCOMPATIBLE ||
            state == BandSessionState.REJECTED ||
            state == BandSessionState.SECURITY_FAILURE
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        clearOperationTracking()
        liveActive = false
        generation += 1
        state = BandSessionState.RECOVERING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.RECONNECT,
                BandDiagnosticOutcome.INTERRUPTED,
            ),
        )
        return generation
    }

    @Synchronized
    fun resumeAfterReconnect() {
        ensureNotClosed()
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
        liveActive = false
        state = BandSessionState.CLOSED
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CONNECTION,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    private fun rejectCapabilities(): Nothing {
        state = BandSessionState.INCOMPATIBLE
        capabilityReport = null
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.REJECTED,
            ),
        )
        fail(BandFailureCategory.INCOMPATIBLE)
    }

    private fun validateCallbackGeneration(callbackGeneration: Long) {
        if (callbackGeneration != generation) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CONNECTION,
                    BandDiagnosticOutcome.STALE,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateActiveToken(
        token: BandOperationToken,
        expected: BandOperationClass,
    ) {
        if (token.generation != generation) {
            fail(BandFailureCategory.STALE_CALLBACK)
        }
        if (token.operationClass != expected || token != activeOperation) {
            fail(BandFailureCategory.INVALID_STATE)
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

    private fun clearOperationTracking() {
        activeOperation = null
        pendingHistory = null
        historyOperationReceivedDurableReceipt = false
        historyOperationLastReceiptComplete = null
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
    ) {
        val capabilities = capabilityReport?.capabilities
        if (
            capabilities == null ||
            samples.any { requiredCapability(it.identity.stream) !in capabilities }
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
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
