package com.noop.bandsdk

class BandSessionMachine(
    private val diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
) {
    private data class PendingHistory(
        val acceptance: HistoryAcceptance,
        val sampleIdentities: Set<BandSampleIdentity>,
    )

    private var state = BandSessionState.IDLE
    private var generation = 0L
    private var nextOperationSequence = 0L
    private var activeOperation: BandOperationToken? = null
    private var liveActive = false
    private var identity: BandIdentity? = null
    private var capabilityReport: BandCapabilityReport? = null
    private var pendingHistory: PendingHistory? = null
    private val durableSampleIdentities = mutableSetOf<BandSampleIdentity>()
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
    fun beginScan(): Long {
        ensureNotClosed()
        if (state != BandSessionState.IDLE && state != BandSessionState.RECOVERING) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        activeOperation = null
        pendingHistory = null
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
        if (identity?.sourceIdentity != newIdentity.sourceIdentity) {
            durableSampleIdentities.clear()
            acknowledgedHistoryCursor = null
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
    fun acceptCapabilities(report: BandCapabilityReport) {
        ensureNotClosed()
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
        val acceptedIdentities = mutableSetOf<BandSampleIdentity>()
        val unique = batch.samples.filter {
            it.identity !in durableSampleIdentities &&
                acceptedIdentities.add(it.identity)
        }
        durableSampleIdentities.addAll(unique.map(BandSample::identity))
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
        ensureNotClosed()
        if (activeOperation != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.COMMAND,
                    BandDiagnosticOutcome.REJECTED,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        ensureReadyForOperation()
        listOfNotNull(
            impliedCapability(operationClass),
            requiredCapability,
        ).forEach { capability ->
            if (capabilityReport?.capabilities?.contains(capability) != true) {
                fail(BandFailureCategory.UNSUPPORTED)
            }
        }
        if (
            operationClass == BandOperationClass.FIRMWARE &&
            capabilityReport?.capabilities?.contains(BandCapability.FIRMWARE_UPDATE) != true
        ) {
            fail(BandFailureCategory.UPDATE_NOT_ELIGIBLE)
        }

        nextOperationSequence += 1
        val token = BandOperationToken(
            generation,
            nextOperationSequence,
            operationClass,
        )
        activeOperation = token
        state = when (operationClass) {
            BandOperationClass.HISTORY -> BandSessionState.HISTORY_COLLECTING
            BandOperationClass.FIRMWARE -> BandSessionState.UPDATING_FIRMWARE
            else -> BandSessionState.EXECUTING_COMMAND
        }
        diagnostics.record(
            BandDiagnosticEvent(
                if (operationClass == BandOperationClass.HISTORY) {
                    BandDiagnosticKind.HISTORY
                } else {
                    BandDiagnosticKind.COMMAND
                },
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
        chunk.validate()
        if (chunk.previousCursor != acknowledgedHistoryCursor) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (chunk.batches.any { it.sourceIdentity != identity?.sourceIdentity }) {
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val unique = mutableSetOf<BandSampleIdentity>()
        var duplicates = 0
        chunk.batches.flatMap(BandSampleBatch::samples).forEach { sample ->
            if (
                sample.identity in durableSampleIdentities ||
                !unique.add(sample.identity)
            ) {
                duplicates += 1
            }
        }
        val acceptance = HistoryAcceptance(
            chunkIdentity = chunk.chunkIdentity,
            acknowledgementToken = chunk.acknowledgementToken,
            nextCursor = chunk.nextCursor,
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

        durableSampleIdentities.addAll(pending.sampleIdentities)
        acknowledgedHistoryCursor = receipt.nextCursor
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
        validateActiveToken(token, token.operationClass)
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            pendingHistory != null
        ) {
            fail(BandFailureCategory.STORAGE)
        }
        activeOperation = null
        state = if (liveActive) {
            BandSessionState.LIVE_COLLECTING
        } else {
            BandSessionState.READY
        }
        diagnostics.record(
            BandDiagnosticEvent(
                if (token.operationClass == BandOperationClass.HISTORY) {
                    BandDiagnosticKind.HISTORY
                } else {
                    BandDiagnosticKind.COMMAND
                },
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
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
        activeOperation = null
        pendingHistory = null
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
        activeOperation = null
        pendingHistory = null
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

    private fun impliedCapability(
        operationClass: BandOperationClass,
    ): BandCapability? = when (operationClass) {
        BandOperationClass.BATTERY -> BandCapability.BATTERY
        BandOperationClass.WEAR_STATE -> BandCapability.WEAR_STATE
        BandOperationClass.HAPTIC -> BandCapability.HAPTICS
        BandOperationClass.ALARM -> BandCapability.ALARMS
        BandOperationClass.FIRMWARE -> BandCapability.FIRMWARE_UPDATE
        BandOperationClass.HISTORY,
        BandOperationClass.SAMPLING,
        -> null
    }
}
