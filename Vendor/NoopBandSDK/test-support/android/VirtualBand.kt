package com.noop.bandsdk

class VirtualBandStore {
    private val committed = mutableSetOf<BandSampleIdentity>()

    @Synchronized
    fun commit(
        acceptance: HistoryAcceptance,
        samples: List<BandSample>,
    ): DurableHistoryReceipt {
        val identities = samples.map(BandSample::identity).toSet()
        committed.addAll(identities)
        return DurableHistoryReceipt(
            chunkIdentity = acceptance.chunkIdentity,
            acknowledgementToken = acceptance.acknowledgementToken,
            nextCursor = acceptance.nextCursor,
            complete = acceptance.complete,
            overflowed = acceptance.overflowed,
            historyStateCommitted = true,
            committedSamples = identities.size,
            committed = true,
        )
    }
}

data class BandConformanceResult(
    val scenario: String,
    val events: List<String>,
    val finalState: String,
    val acknowledgedCursor: String?,
    val acceptedSamples: Int,
    val failure: String?,
) {
    fun toJson(): String = buildString {
        append("{\"acceptedSamples\":")
        append(acceptedSamples)
        append(",\"acknowledgedCursor\":")
        append(acknowledgedCursor?.quoted() ?: "null")
        append(",\"events\":[")
        append(events.joinToString(",") { it.quoted() })
        append("],\"failure\":")
        append(failure?.quoted() ?: "null")
        append(",\"finalState\":")
        append(finalState.quoted())
        append(",\"scenario\":")
        append(scenario.quoted())
        append("}")
    }
}

object VirtualBandFixtures {
    val candidate = BandPairingCandidate(
        handle = "virtual-candidate",
        compatible = true,
        identifyEligible = true,
    )

    val identity = BandIdentity(
        sourceIdentity = "virtual-source",
        hardwareRevision = "virtual-hw-1",
        firmwareVersion = "virtual-fw-1",
        protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
        wrapperRevision = "virtual-wrapper-1",
    )

    val capabilities = BandCapabilityReport(
        schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
        protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
        hardwareRevision = identity.hardwareRevision,
        firmwareVersion = identity.firmwareVersion,
        historyDays = 7,
        capabilities = setOf(
            BandCapability.BATTERY,
            BandCapability.CHARGING,
            BandCapability.WEAR_STATE,
            BandCapability.HEART_RATE,
            BandCapability.RR_INTERVALS,
            BandCapability.HAPTICS,
            BandCapability.ALARMS,
        ),
    )

    val liveBatch = BandSampleBatch(
        sourceIdentity = identity.sourceIdentity,
        lane = BandProvenanceLane.LIVE,
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
    )

    val historyChunk = BandHistoryChunk(
        chunkIdentity = "chunk-1",
        previousCursor = null,
        nextCursor = "cursor-2",
        complete = true,
        overflowed = false,
        acknowledgementToken = "ack-1",
        batches = listOf(
            BandSampleBatch(
                sourceIdentity = identity.sourceIdentity,
                lane = BandProvenanceLane.HISTORY,
                parserRevision = "parser-v1",
                calibrationRevision = "calibration-v1",
                samples = listOf(
                    BandSample(
                        identity = BandSampleIdentity(
                            stream = BandStreamKind.HEART_RATE,
                            sequence = 2,
                            deviceTimeMilliseconds = 2_000,
                        ),
                        value = 70.0,
                        unit = BandUnit.BEATS_PER_MINUTE,
                        quality = BandSampleQuality.ACCEPTED,
                    ),
                    BandSample(
                        identity = BandSampleIdentity(
                            stream = BandStreamKind.HEART_RATE,
                            sequence = 3,
                            deviceTimeMilliseconds = 3_000,
                        ),
                        value = 68.0,
                        unit = BandUnit.BEATS_PER_MINUTE,
                        quality = BandSampleQuality.ACCEPTED,
                    ),
                ),
            ),
        ),
    )

    val duplicateLiveBatch = BandSampleBatch(
        sourceIdentity = identity.sourceIdentity,
        lane = BandProvenanceLane.LIVE,
        parserRevision = "parser-v1",
        calibrationRevision = "calibration-v1",
        samples = listOf(
            liveBatch.samples[0],
            liveBatch.samples[0],
        ),
    )

    val mismatchedCursorChunk = BandHistoryChunk(
        chunkIdentity = "chunk-2",
        previousCursor = null,
        nextCursor = "cursor-3",
        complete = true,
        overflowed = false,
        acknowledgementToken = "ack-2",
        batches = historyChunk.batches,
    )
}

object BandConformanceRunner {
    val automatedScenarios = listOf(
        "happy_path",
        "single_command_queue",
        "stale_callback_rejected",
        "history_requires_durable_receipt",
        "live_does_not_advance_history",
        "live_batch_deduplicated",
        "history_cursor_chain_rejected",
        "operation_capability_fail_closed",
        "oversized_metadata_rejected",
        "capability_unknown_fail_closed",
        "history_interrupted_resume",
        "history_checkpoint_restored",
        "firmware_eligibility_specific",
        "unnegotiated_stream_rejected",
        "firmware_blocked_during_live",
        "history_state_requires_durable_receipt",
        "diagnostics_bounded",
        "closed_session_terminal",
    )

    fun run(scenario: String): BandConformanceResult = when (scenario) {
        "happy_path" -> happyPath()
        "single_command_queue" -> singleCommandQueue()
        "stale_callback_rejected" -> staleCallbackRejected()
        "history_requires_durable_receipt" -> historyRequiresDurableReceipt()
        "live_does_not_advance_history" -> liveDoesNotAdvanceHistory()
        "live_batch_deduplicated" -> liveBatchDeduplicated()
        "history_cursor_chain_rejected" -> historyCursorChainRejected()
        "operation_capability_fail_closed" -> operationCapabilityFailsClosed()
        "oversized_metadata_rejected" -> oversizedMetadataRejected()
        "capability_unknown_fail_closed" -> capabilityUnknownFailsClosed()
        "history_interrupted_resume" -> historyInterruptedResume()
        "history_checkpoint_restored" -> historyCheckpointRestored()
        "firmware_eligibility_specific" -> firmwareEligibilitySpecific()
        "unnegotiated_stream_rejected" -> unnegotiatedStreamRejected()
        "firmware_blocked_during_live" -> firmwareBlockedDuringLive()
        "history_state_requires_durable_receipt" ->
            historyStateRequiresDurableReceipt()
        "diagnostics_bounded" -> diagnosticsBounded()
        "closed_session_terminal" -> closedSessionTerminal()
        else -> fail(BandFailureCategory.INVALID_INPUT)
    }

    private fun readySession(
        capabilities: BandCapabilityReport = VirtualBandFixtures.capabilities,
    ): Pair<BandSessionMachine, Long> {
        val session = BandSessionMachine()
        val generation = session.beginScan()
        session.selectCandidate(VirtualBandFixtures.candidate)
        session.connect(VirtualBandFixtures.identity)
        session.acceptCapabilities(capabilities)
        return session to generation
    }

    private fun happyPath(): BandConformanceResult {
        val session = BandSessionMachine()
        val store = VirtualBandStore()
        val events = mutableListOf<String>()
        var accepted = 0

        val generation = session.beginScan()
        events += "scan_started"
        session.selectCandidate(VirtualBandFixtures.candidate)
        events += "candidate_selected"
        session.connect(VirtualBandFixtures.identity)
        events += "connected"
        session.acceptCapabilities(VirtualBandFixtures.capabilities)
        events += "capabilities_accepted"
        session.beginLive()
        accepted += session.commitLiveBatch(
            VirtualBandFixtures.liveBatch,
            generation,
        )
        events += "live_committed"
        session.stopLive()

        val token = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token,
            generation,
        )
        accepted += acceptance.acceptedSamples
        events += "history_received"
        val receipt = store.commit(
            acceptance,
            VirtualBandFixtures.historyChunk.batches.flatMap(
                BandSampleBatch::samples,
            ),
        )
        events += "history_committed"
        session.acknowledgeHistory(receipt, token, generation)
        events += "history_acknowledged"
        session.completeOperation(token)
        return result(
            "happy_path",
            events,
            session.snapshot(),
            acceptedSamples = accepted,
        )
    }

    private fun singleCommandQueue(): BandConformanceResult {
        val (session, _) = readySession()
        val events = mutableListOf("ready")
        val token = session.beginOperation(
            BandOperationClass.BATTERY,
            BandCapability.BATTERY,
        )
        events += "command_started"
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(
                BandOperationClass.HAPTIC,
                BandCapability.HAPTICS,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "second_command_rejected"
        }
        session.completeOperation(token)
        events += "command_completed"
        return result(
            "single_command_queue",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun staleCallbackRejected(): BandConformanceResult {
        val (session, oldGeneration) = readySession()
        val events = mutableListOf("ready")
        session.interruptForReconnect()
        session.resumeAfterReconnect()
        events += "generation_advanced"
        var failure: BandFailureCategory? = null
        try {
            session.commitLiveBatch(
                VirtualBandFixtures.liveBatch,
                oldGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_callback_rejected"
        }
        return result(
            "stale_callback_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun historyRequiresDurableReceipt(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token,
            generation,
        )
        events += "history_received"
        var failure: BandFailureCategory? = null
        try {
            session.acknowledgeHistory(
                DurableHistoryReceipt(
                    chunkIdentity = acceptance.chunkIdentity,
                    acknowledgementToken = acceptance.acknowledgementToken,
                    nextCursor = acceptance.nextCursor,
                    complete = acceptance.complete,
                    overflowed = acceptance.overflowed,
                    historyStateCommitted = false,
                    committedSamples = 0,
                    committed = false,
                ),
                token,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "ack_rejected"
        }
        val receipt = store.commit(
            acceptance,
            VirtualBandFixtures.historyChunk.batches.flatMap(
                BandSampleBatch::samples,
            ),
        )
        events += "history_committed"
        session.acknowledgeHistory(receipt, token, generation)
        events += "history_acknowledged"
        session.completeOperation(token)
        return result(
            "history_requires_durable_receipt",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples,
            failure = failure,
        )
    }

    private fun liveDoesNotAdvanceHistory(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val before = session.snapshot().acknowledgedHistoryCursor
        session.beginLive()
        val accepted = session.commitLiveBatch(
            VirtualBandFixtures.liveBatch,
            generation,
        )
        events += "live_committed"
        val after = session.snapshot().acknowledgedHistoryCursor
        if (before != after) {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        events += "cursor_unchanged"
        session.stopLive()
        events += "live_stopped"
        return result(
            "live_does_not_advance_history",
            events,
            session.snapshot(),
            acceptedSamples = accepted,
        )
    }

    private fun liveBatchDeduplicated(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        session.beginLive()
        val accepted = session.commitLiveBatch(
            VirtualBandFixtures.duplicateLiveBatch,
            generation,
        )
        events += "live_committed"
        session.stopLive()
        events += "live_stopped"
        return result(
            "live_batch_deduplicated",
            events,
            session.snapshot(),
            acceptedSamples = accepted,
        )
    }

    private fun historyCursorChainRejected(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")

        val firstToken = session.beginOperation(BandOperationClass.HISTORY)
        val firstAcceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstToken,
            generation,
        )
        val firstReceipt = store.commit(
            firstAcceptance,
            VirtualBandFixtures.historyChunk.batches.flatMap(
                BandSampleBatch::samples,
            ),
        )
        session.acknowledgeHistory(firstReceipt, firstToken, generation)
        session.completeOperation(firstToken)
        events += "first_history_committed"

        val secondToken = session.beginOperation(BandOperationClass.HISTORY)
        var failure: BandFailureCategory? = null
        try {
            session.stageHistoryChunk(
                VirtualBandFixtures.mismatchedCursorChunk,
                secondToken,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "cursor_chain_rejected"
        }
        session.completeOperation(secondToken)
        events += "operation_completed"

        return result(
            "history_cursor_chain_rejected",
            events,
            session.snapshot(),
            acceptedSamples = firstAcceptance.acceptedSamples,
            failure = failure,
        )
    }

    private fun operationCapabilityFailsClosed(): BandConformanceResult {
        val session = BandSessionMachine()
        session.beginScan()
        session.selectCandidate(VirtualBandFixtures.candidate)
        session.connect(VirtualBandFixtures.identity)
        session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
                hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
                firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(
                    BandCapability.BATTERY,
                    BandCapability.HEART_RATE,
                ),
            ),
        )
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(BandOperationClass.HAPTIC)
        } catch (error: BandException) {
            failure = error.category
            events += "unsupported_operation_rejected"
        }
        return result(
            "operation_capability_fail_closed",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun oversizedMetadataRejected(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val batch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "x".repeat(
                BandContractLimits.REVISION_LENGTH + 1,
            ),
            calibrationRevision = "calibration-v1",
            samples = VirtualBandFixtures.liveBatch.samples,
        )
        session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.commitLiveBatch(batch, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "oversized_metadata_rejected"
        }
        session.stopLive()
        events += "live_stopped"
        return result(
            "oversized_metadata_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun capabilityUnknownFailsClosed(): BandConformanceResult {
        val session = BandSessionMachine()
        val events = mutableListOf<String>()
        session.beginScan()
        events += "scan_started"
        session.selectCandidate(VirtualBandFixtures.candidate)
        events += "candidate_selected"
        val identity = VirtualBandFixtures.identity.copy(
            protocolVersion = "noop-band-v2",
        )
        session.connect(identity)
        events += "connected"
        val report = BandCapabilityReport(
            schemaVersion = 2,
            protocolVersion = "noop-band-v2",
            hardwareRevision = identity.hardwareRevision,
            firmwareVersion = identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
        )
        var failure: BandFailureCategory? = null
        try {
            session.acceptCapabilities(report)
        } catch (error: BandException) {
            failure = error.category
            events += "capability_rejected"
        }
        return result(
            "capability_unknown_fail_closed",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun historyInterruptedResume(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        val firstToken = session.beginOperation(BandOperationClass.HISTORY)
        session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstToken,
            generation,
        )
        events += "history_received"
        session.interruptForReconnect()
        val failure = BandFailureCategory.DISCONNECTED
        events += "history_interrupted"
        val resumedGeneration = session.snapshot().generation
        session.resumeAfterReconnect()
        events += "reconnected"
        val secondToken = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            secondToken,
            resumedGeneration,
        )
        events += "history_resumed"
        val receipt = store.commit(
            acceptance,
            VirtualBandFixtures.historyChunk.batches.flatMap(
                BandSampleBatch::samples,
            ),
        )
        events += "history_committed"
        session.acknowledgeHistory(
            receipt,
            secondToken,
            resumedGeneration,
        )
        events += "history_acknowledged"
        session.completeOperation(secondToken)
        return result(
            "history_interrupted_resume",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples,
            failure = failure,
        )
    }

    private fun historyCheckpointRestored(): BandConformanceResult {
        val checkpoint = BandHistoryCheckpoint(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            acknowledgedCursor = "cursor-2",
            lastHistoryComplete = false,
            durableSampleIdentities =
                VirtualBandFixtures.historyChunk.batches
                    .flatMap(BandSampleBatch::samples)
                    .map(BandSample::identity)
                    .toSet(),
        )
        val session = BandSessionMachine(restoredHistoryCheckpoint = checkpoint)
        val generation = session.beginScan()
        session.selectCandidate(VirtualBandFixtures.candidate)
        session.connect(VirtualBandFixtures.identity)
        session.acceptCapabilities(VirtualBandFixtures.capabilities)
        val events = mutableListOf("ready")
        if (session.snapshot().acknowledgedHistoryCursor != "cursor-2") {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        events += "checkpoint_restored"
        val token = session.beginOperation(BandOperationClass.HISTORY)
        try {
            session.completeOperation(token)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.HISTORY_STALLED) {
                throw error
            }
            events += "range_resume_required"
        }

        val duplicate = VirtualBandFixtures.historyChunk.batches[0].samples[1]
        val newSample = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.HEART_RATE,
                sequence = 4,
                deviceTimeMilliseconds = 4_000,
            ),
            value = 67.0,
            unit = BandUnit.BEATS_PER_MINUTE,
            quality = BandSampleQuality.ACCEPTED,
        )
        val chunk = BandHistoryChunk(
            chunkIdentity = "chunk-2",
            previousCursor = "cursor-2",
            nextCursor = "cursor-3",
            complete = true,
            overflowed = false,
            acknowledgementToken = "ack-2",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
                    samples = listOf(duplicate, newSample),
                ),
            ),
        )
        val acceptance = session.stageHistoryChunk(chunk, token, generation)
        val receipt = VirtualBandStore().commit(
            acceptance,
            chunk.batches.flatMap(BandSampleBatch::samples),
        )
        events += "history_committed"
        session.acknowledgeHistory(receipt, token, generation)
        events += "history_acknowledged"
        session.completeOperation(token)
        return result(
            "history_checkpoint_restored",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples,
        )
    }

    private fun firmwareEligibilitySpecific(): BandConformanceResult {
        val report = BandCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
        )
        val (session, _) = readySession(report)
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(BandOperationClass.FIRMWARE)
        } catch (error: BandException) {
            failure = error.category
            events += "firmware_rejected"
        }
        return result(
            "firmware_eligibility_specific",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun unnegotiatedStreamRejected(): BandConformanceResult {
        val report = BandCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
        )
        val (session, generation) = readySession(report)
        val events = mutableListOf("ready")
        val sample = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.SPO2,
                sequence = 4,
                deviceTimeMilliseconds = 4_000,
            ),
            value = 98.0,
            unit = BandUnit.PERCENT,
            quality = BandSampleQuality.ACCEPTED,
        )
        val batch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v1",
            calibrationRevision = "calibration-v1",
            samples = listOf(sample),
        )
        session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.commitLiveBatch(batch, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "live_stream_rejected"
        }
        session.stopLive()
        events += "live_stopped"
        val historyToken = session.beginOperation(BandOperationClass.HISTORY)
        val historyChunk = BandHistoryChunk(
            chunkIdentity = "chunk-unnegotiated",
            previousCursor = null,
            nextCursor = "cursor-unnegotiated",
            complete = true,
            overflowed = false,
            acknowledgementToken = "ack-unnegotiated",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = batch.sourceIdentity,
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = batch.parserRevision,
                    calibrationRevision = batch.calibrationRevision,
                    samples = batch.samples,
                ),
            ),
        )
        try {
            session.stageHistoryChunk(historyChunk, historyToken, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "history_stream_rejected"
        }
        session.completeOperation(historyToken)
        events += "operation_completed"
        return result(
            "unnegotiated_stream_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun firmwareBlockedDuringLive(): BandConformanceResult {
        val report = BandCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(
                BandCapability.HEART_RATE,
                BandCapability.FIRMWARE_UPDATE,
            ),
        )
        val (session, _) = readySession(report)
        val events = mutableListOf("ready")
        session.beginLive()
        events += "live_started"
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(BandOperationClass.FIRMWARE)
        } catch (error: BandException) {
            failure = error.category
            events += "firmware_rejected"
        }
        session.stopLive()
        events += "live_stopped"
        return result(
            "firmware_blocked_during_live",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun historyStateRequiresDurableReceipt(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null
        val firstSample = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.HEART_RATE,
                sequence = 4,
                deviceTimeMilliseconds = 4_000,
            ),
            value = 67.0,
            unit = BandUnit.BEATS_PER_MINUTE,
            quality = BandSampleQuality.ACCEPTED,
        )
        val firstChunk = BandHistoryChunk(
            chunkIdentity = "chunk-incomplete",
            previousCursor = null,
            nextCursor = "cursor-2",
            complete = false,
            overflowed = true,
            acknowledgementToken = "ack-incomplete",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
                    samples = listOf(firstSample),
                ),
            ),
        )
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val firstAcceptance =
            session.stageHistoryChunk(firstChunk, token, generation)
        events += "history_received"
        try {
            session.acknowledgeHistory(
                DurableHistoryReceipt(
                    chunkIdentity = firstAcceptance.chunkIdentity,
                    acknowledgementToken = firstAcceptance.acknowledgementToken,
                    nextCursor = firstAcceptance.nextCursor,
                    complete = firstAcceptance.complete,
                    overflowed = false,
                    historyStateCommitted = true,
                    committedSamples = firstAcceptance.acceptedSamples,
                    committed = true,
                ),
                token,
                generation,
            )
        } catch (_: BandException) {
            events += "receipt_rejected"
        }
        val firstReceipt = store.commit(
            firstAcceptance,
            firstChunk.batches.flatMap(BandSampleBatch::samples),
        )
        session.acknowledgeHistory(firstReceipt, token, generation)
        events += "history_committed"
        try {
            session.completeOperation(token)
        } catch (error: BandException) {
            failure = error.category
            events += "range_incomplete"
        }

        val terminalSample = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.HEART_RATE,
                sequence = 5,
                deviceTimeMilliseconds = 5_000,
            ),
            value = 66.0,
            unit = BandUnit.BEATS_PER_MINUTE,
            quality = BandSampleQuality.ACCEPTED,
        )
        val terminalChunk = BandHistoryChunk(
            chunkIdentity = "chunk-terminal",
            previousCursor = "cursor-2",
            nextCursor = "cursor-3",
            complete = true,
            overflowed = false,
            acknowledgementToken = "ack-terminal",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
                    samples = listOf(terminalSample),
                ),
            ),
        )
        val terminalAcceptance =
            session.stageHistoryChunk(terminalChunk, token, generation)
        events += "terminal_received"
        val terminalReceipt = store.commit(
            terminalAcceptance,
            terminalChunk.batches.flatMap(BandSampleBatch::samples),
        )
        session.acknowledgeHistory(terminalReceipt, token, generation)
        events += "terminal_committed"
        session.completeOperation(token)
        events += "operation_completed"
        return result(
            "history_state_requires_durable_receipt",
            events,
            session.snapshot(),
            acceptedSamples =
                firstAcceptance.acceptedSamples +
                    terminalAcceptance.acceptedSamples,
            failure = failure,
        )
    }

    private fun diagnosticsBounded(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder(4)
        repeat(10) { index ->
            diagnostics.record(
                BandDiagnosticEvent(
                    kind = BandDiagnosticKind.COMMAND,
                    outcome = if (index % 2 == 0) {
                        BandDiagnosticOutcome.COMPLETED
                    } else {
                        BandDiagnosticOutcome.REJECTED
                    },
                    countBucket = BandCountBucket.from(index),
                ),
            )
        }
        val events = listOf(
            "diagnostics_recorded",
            if (diagnostics.snapshot().size == 4) {
                "diagnostics_bounded"
            } else {
                "diagnostics_unbounded"
            },
        )
        return BandConformanceResult(
            scenario = "diagnostics_bounded",
            events = events,
            finalState = BandSessionState.IDLE.wireValue,
            acknowledgedCursor = null,
            acceptedSamples = 0,
            failure = null,
        )
    }

    private fun closedSessionTerminal(): BandConformanceResult {
        val session = BandSessionMachine()
        session.close()
        val events = mutableListOf("session_closed")
        var failure: BandFailureCategory? = null
        try {
            session.beginScan()
        } catch (error: BandException) {
            failure = error.category
            events += "operation_rejected"
        }
        return result(
            "closed_session_terminal",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun result(
        scenario: String,
        events: List<String>,
        snapshot: BandSessionSnapshot,
        acceptedSamples: Int = 0,
        failure: BandFailureCategory? = null,
    ) = BandConformanceResult(
        scenario = scenario,
        events = events,
        finalState = snapshot.state.wireValue,
        acknowledgedCursor = snapshot.acknowledgedHistoryCursor,
        acceptedSamples = acceptedSamples,
        failure = failure?.wireValue,
    )
}

private fun String.quoted(): String = buildString {
    append('"')
    for (character in this@quoted) {
        when (character) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> append(character)
        }
    }
    append('"')
}
