package com.noop.bandsdk

class VirtualBandStore {
    private val committed = mutableSetOf<BandSampleIdentity>()

    @Synchronized
    fun commit(acceptance: LiveAcceptance): DurableLiveReceipt {
        val identities =
            acceptance.acceptedSamples.map(BandSample::identity).toSet()
        committed.addAll(identities)
        return DurableLiveReceipt(
            acceptance = acceptance,
            committedSamples = identities.size,
            committed = true,
        )
    }

    @Synchronized
    fun commit(
        acceptance: HistoryAcceptance,
    ): DurableHistoryReceipt {
        val identities =
            acceptance.acceptedSamples.map {
                it.sample.identity
            }.toSet()
        committed.addAll(identities)
        return DurableHistoryReceipt(
            acceptance = acceptance,
            historyStateCommitted = true,
            committedSamples = identities.size,
            committed = true,
        )
    }
}

private fun BandSessionMachine.durablyCommitLiveBatch(
    batch: BandSampleBatch,
    token: BandLiveToken,
    callbackGeneration: Long,
): Int {
    val acceptance = stageLiveBatch(batch, token, callbackGeneration)
    val receipt = VirtualBandStore().commit(acceptance)
    acknowledgeLive(receipt, callbackGeneration)
    return acceptance.acceptedSamples.size
}

private fun BandSessionMachine.completeConnectionForConformance(
    identity: BandIdentity,
    token: BandConnectionToken,
    callbackGeneration: Long,
) {
    beginConnection(token, callbackGeneration)
    beginAuthentication(token, callbackGeneration)
    completeConnection(identity, token, callbackGeneration)
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
        reportRevision = "virtual-report-v1",
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
            BandCapability.ACCELEROMETER,
            BandCapability.HAPTICS,
            BandCapability.ALARMS,
        ),
        liveStreams = setOf(
            BandStreamKind.HEART_RATE,
            BandStreamKind.RR_INTERVAL,
            BandStreamKind.ACCELERATION,
        ),
        historyStreams = setOf(
            BandStreamKind.HEART_RATE,
            BandStreamKind.RR_INTERVAL,
        ),
        operationsAllowedDuringLive = BandOperationClass.entries
            .filterNot { it == BandOperationClass.FIRMWARE }
            .toSet(),
        streamSemantics = BandCapabilityReport.virtualStreamSemantics(
            liveStreams = setOf(
                BandStreamKind.HEART_RATE,
                BandStreamKind.RR_INTERVAL,
                BandStreamKind.ACCELERATION,
            ),
            historyStreams = setOf(
                BandStreamKind.HEART_RATE,
                BandStreamKind.RR_INTERVAL,
            ),
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
        retainedRange = BandHistoryRange(
            startDeviceTimeMilliseconds = 2_000,
            endDeviceTimeMilliseconds = 3_000,
        ),
        firstLostRange = null,
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
        retainedRange = historyChunk.retainedRange,
        firstLostRange = null,
        acknowledgementToken = "ack-2",
        batches = historyChunk.batches,
    )
}

private fun virtualCapabilityReport(
    schemaVersion: Int = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
    protocolVersion: String =
        BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
    hardwareRevision: String =
        VirtualBandFixtures.identity.hardwareRevision,
    firmwareVersion: String =
        VirtualBandFixtures.identity.firmwareVersion,
    historyDays: Int,
    capabilities: Set<BandCapability>,
    liveStreams: Set<BandStreamKind>,
    historyStreams: Set<BandStreamKind>,
    operationsAllowedDuringLive: Set<BandOperationClass> = emptySet(),
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
    operationsAllowedDuringLive = operationsAllowedDuringLive,
    streamSemantics = BandCapabilityReport.virtualStreamSemantics(
        liveStreams,
        historyStreams,
    ),
)

object BandConformanceRunner {
    val automatedScenarios = listOf(
        "happy_path",
        "single_command_queue",
        "stale_callback_rejected",
        "scan_callback_session_bound",
        "scan_callback_consumed_after_selection",
        "cross_session_credentials_rejected",
        "established_failure_session_bound",
        "reconnect_callback_session_bound",
        "reconnected_established_failure_authorized",
        "superseded_live_stop_rejected",
        "same_session_replay_rejected",
        "stale_terminal_callbacks_rejected",
        "history_requires_durable_receipt",
        "live_does_not_advance_history",
        "live_batch_deduplicated",
        "history_cursor_chain_rejected",
        "operation_capability_fail_closed",
        "oversized_metadata_rejected",
        "capability_unknown_fail_closed",
        "history_interrupted_resume",
        "history_checkpoint_restored",
        "history_checkpoint_survives_source_mismatch",
        "firmware_eligibility_specific",
        "unnegotiated_stream_rejected",
        "firmware_blocked_during_live",
        "history_state_requires_durable_receipt",
        "stale_capability_callback_rejected",
        "invalid_device_time_rejected",
        "history_operation_requires_own_receipt",
        "firmware_diagnostics_specific",
        "firmware_terminal_failure",
        "history_nonadvancing_cursor_rejected",
        "utf8_length_cross_platform",
        "sampling_requires_sensor_capability",
        "durable_identity_cache_bounded",
        "operation_terminal_paths",
        "connection_callbacks_generation_fenced",
        "connection_terminal_paths",
        "capability_terminal_paths",
        "history_pending_busy_diagnostics",
        "diagnostics_bounded",
        "fractional_steps_rejected",
        "live_callback_session_bound",
        "graceful_disconnect_to_idle",
        "close_active_phase_terminal",
        "closed_session_terminal",
        "live_operation_allowed",
        "live_operation_denied",
        "stream_semantics_mismatch_rejected",
        "live_staged_before_durable",
    )

    fun run(scenario: String): BandConformanceResult = when (scenario) {
        "happy_path" -> happyPath()
        "single_command_queue" -> singleCommandQueue()
        "stale_callback_rejected" -> staleCallbackRejected()
        "scan_callback_session_bound" -> scanCallbackSessionBound()
        "scan_callback_consumed_after_selection" ->
            scanCallbackConsumedAfterSelection()
        "cross_session_credentials_rejected" ->
            crossSessionCredentialsRejected()
        "established_failure_session_bound" ->
            establishedFailureSessionBound()
        "reconnect_callback_session_bound" ->
            reconnectCallbackSessionBound()
        "reconnected_established_failure_authorized" ->
            reconnectedEstablishedFailureAuthorized()
        "superseded_live_stop_rejected" ->
            supersededLiveStopRejected()
        "same_session_replay_rejected" ->
            sameSessionReplayRejected()
        "stale_terminal_callbacks_rejected" ->
            staleTerminalCallbacksRejected()
        "history_requires_durable_receipt" -> historyRequiresDurableReceipt()
        "live_does_not_advance_history" -> liveDoesNotAdvanceHistory()
        "live_batch_deduplicated" -> liveBatchDeduplicated()
        "history_cursor_chain_rejected" -> historyCursorChainRejected()
        "operation_capability_fail_closed" -> operationCapabilityFailsClosed()
        "oversized_metadata_rejected" -> oversizedMetadataRejected()
        "capability_unknown_fail_closed" -> capabilityUnknownFailsClosed()
        "history_interrupted_resume" -> historyInterruptedResume()
        "history_checkpoint_restored" -> historyCheckpointRestored()
        "history_checkpoint_survives_source_mismatch" ->
            historyCheckpointSurvivesSourceMismatch()
        "firmware_eligibility_specific" -> firmwareEligibilitySpecific()
        "unnegotiated_stream_rejected" -> unnegotiatedStreamRejected()
        "firmware_blocked_during_live" -> firmwareBlockedDuringLive()
        "history_state_requires_durable_receipt" ->
            historyStateRequiresDurableReceipt()
        "stale_capability_callback_rejected" ->
            staleCapabilityCallbackRejected()
        "invalid_device_time_rejected" -> invalidDeviceTimeRejected()
        "history_operation_requires_own_receipt" ->
            historyOperationRequiresOwnReceipt()
        "firmware_diagnostics_specific" -> firmwareDiagnosticsSpecific()
        "firmware_terminal_failure" -> firmwareTerminalFailure()
        "history_nonadvancing_cursor_rejected" ->
            historyNonadvancingCursorRejected()
        "utf8_length_cross_platform" -> utf8LengthCrossPlatform()
        "sampling_requires_sensor_capability" ->
            samplingRequiresSensorCapability()
        "durable_identity_cache_bounded" -> durableIdentityCacheBounded()
        "operation_terminal_paths" -> operationTerminalPaths()
        "connection_callbacks_generation_fenced" ->
            connectionCallbacksGenerationFenced()
        "connection_terminal_paths" -> connectionTerminalPaths()
        "capability_terminal_paths" -> capabilityTerminalPaths()
        "history_pending_busy_diagnostics" ->
            historyPendingBusyDiagnostics()
        "fractional_steps_rejected" -> fractionalStepsRejected()
        "diagnostics_bounded" -> diagnosticsBounded()
        "live_callback_session_bound" -> liveCallbackSessionBound()
        "graceful_disconnect_to_idle" -> gracefulDisconnectToIdle()
        "close_active_phase_terminal" -> closeActivePhaseTerminal()
        "closed_session_terminal" -> closedSessionTerminal()
        "live_operation_allowed" -> liveOperationAllowed()
        "live_operation_denied" -> liveOperationDenied()
        "stream_semantics_mismatch_rejected" ->
            streamSemanticsMismatchRejected()
        "live_staged_before_durable" -> liveStagedBeforeDurable()
        else -> fail(BandFailureCategory.INVALID_INPUT)
    }

    private fun readySession(
        capabilities: BandCapabilityReport = VirtualBandFixtures.capabilities,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    ): Pair<BandSessionMachine, Long> {
        val (session, generation) = readySessionWithToken(
            capabilities,
            diagnostics,
        )
        return session to generation
    }

    private fun readySessionWithToken(
        capabilities: BandCapabilityReport = VirtualBandFixtures.capabilities,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    ): Triple<BandSessionMachine, Long, BandConnectionToken> {
        val session = BandSessionMachine(diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(capabilities, connectionToken, generation)
        return Triple(session, generation, connectionToken)
    }

    private fun liveOperationCapabilities(
        allowed: Set<BandOperationClass>,
    ): BandCapabilityReport {
        val base = VirtualBandFixtures.capabilities
        return BandCapabilityReport(
            schemaVersion = base.schemaVersion,
            reportRevision = base.reportRevision,
            protocolVersion = base.protocolVersion,
            hardwareRevision = base.hardwareRevision,
            firmwareVersion = base.firmwareVersion,
            historyDays = base.historyDays,
            capabilities = base.capabilities,
            liveStreams = base.liveStreams,
            historyStreams = base.historyStreams,
            operationsAllowedDuringLive = allowed,
            streamSemantics = base.streamSemantics,
        )
    }

    private fun happyPath(): BandConformanceResult {
        val session = BandSessionMachine()
        val store = VirtualBandStore()
        val events = mutableListOf<String>()
        var accepted = 0

        val scanToken = session.beginScan()

        val generation = scanToken.generation
        events += "scan_started"
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        events += "candidate_selected"
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        events += "connected"
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            generation,
        )
        events += "capabilities_accepted"
        val liveToken = session.beginLive()
        accepted += session.durablyCommitLiveBatch(
            VirtualBandFixtures.liveBatch,
            liveToken,
            generation,
        )
        events += "live_committed"
        session.stopLive(liveToken)

        val token = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token,
            generation,
        )
        accepted += acceptance.acceptedSamples.size
        events += "history_received"
        val receipt = store.commit(acceptance)
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
        val (session, oldGeneration, connectionToken) =
            readySessionWithToken()
        val events = mutableListOf("ready")
        val staleLiveToken = session.beginLive()
        val reconnectToken =
            session.interruptForReconnect(connectionToken, oldGeneration)
        session.resumeAfterReconnect(
            reconnectToken,
            reconnectToken.generation,
        )
        events += "generation_advanced"
        var failure: BandFailureCategory? = null
        try {
            session.durablyCommitLiveBatch(
                VirtualBandFixtures.liveBatch,
                staleLiveToken,
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

    private fun scanCallbackSessionBound(): BandConformanceResult {
        val retiredSession = BandSessionMachine()
        val currentSession = BandSessionMachine()
        val retiredToken = retiredSession.beginScan()
        val currentToken = currentSession.beginScan()
        check(retiredToken.generation == currentToken.generation)

        val events = mutableListOf("scan_pair")
        var failure: BandFailureCategory? = null
        try {
            currentSession.selectCandidate(
                VirtualBandFixtures.candidate,
                retiredToken,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_select_rejected"
        }
        try {
            currentSession.cancelScan(retiredToken)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_cancel_rejected"
        }
        try {
            currentSession.failScan(
                BandFailureCategory.TIMEOUT,
                retiredToken,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_failure_rejected"
        }

        val preserved = currentSession.snapshot()
        check(preserved.state == BandSessionState.SCANNING)
        check(preserved.generation == currentToken.generation)
        events += "current_scan_preserved"

        val connectionToken = currentSession.selectCandidate(
            VirtualBandFixtures.candidate,
            currentToken,
        )
        events += "own_select_accepted"
        currentSession.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            currentToken.generation,
        )
        currentSession.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            currentToken.generation,
        )
        events += "current_session_ready"

        return result(
            "scan_callback_session_bound",
            events,
            currentSession.snapshot(),
            failure = failure,
        )
    }

    private fun scanCallbackConsumedAfterSelection(): BandConformanceResult {
        val session = BandSessionMachine()
        val scanToken = session.beginScan()
        val events = mutableListOf("scan_started")
        var failure: BandFailureCategory? = null

        val connectionToken = session.selectCandidate(
            VirtualBandFixtures.candidate,
            scanToken,
        )
        events += "candidate_selected"

        try {
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                scanToken,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "late_select_rejected"
        }
        try {
            session.cancelScan(scanToken)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "late_cancel_rejected"
        }
        try {
            session.failScan(
                BandFailureCategory.TIMEOUT,
                scanToken,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "late_failure_rejected"
        }

        val preserved = session.snapshot()
        check(preserved.state == BandSessionState.CANDIDATE_SELECTED)
        check(preserved.generation == scanToken.generation)
        events += "connection_preserved"

        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            scanToken.generation,
        )
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            scanToken.generation,
        )
        events += "current_session_ready"

        return result(
            "scan_callback_consumed_after_selection",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun liveCallbackSessionBound(): BandConformanceResult {
        val (first, firstGeneration) = readySession()
        val (second, secondGeneration) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready_pair")
        var failure: BandFailureCategory? = null

        val firstToken = first.beginLive()
        val secondToken = second.beginLive()
        try {
            second.stageLiveBatch(
                VirtualBandFixtures.liveBatch,
                firstToken,
                secondGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "foreign_live_callback_rejected"
        }
        val acceptance = second.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            secondToken,
            secondGeneration,
        )
        second.acknowledgeLive(
            store.commit(acceptance),
            secondGeneration,
        )
        first.stopLive(firstToken)
        second.stopLive(secondToken)
        events += "own_live_callback_accepted"
        check(firstGeneration == secondGeneration)
        return result(
            "live_callback_session_bound",
            events,
            second.snapshot(),
            acceptedSamples = acceptance.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun crossSessionCredentialsRejected(): BandConformanceResult {
        val (first, firstGeneration) = readySession()
        val (second, secondGeneration) = readySession()
        val firstStore = VirtualBandStore()
        val secondStore = VirtualBandStore()
        val events = mutableListOf("ready_pair")
        var failure: BandFailureCategory? = null

        val firstLiveToken = first.beginLive()
        val secondLiveToken = second.beginLive()
        val firstLive = first.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            firstLiveToken,
            firstGeneration,
        )
        val secondLive = second.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            secondLiveToken,
            secondGeneration,
        )
        val foreignLiveReceipt = firstStore.commit(firstLive)
        try {
            second.acknowledgeLive(
                foreignLiveReceipt,
                secondGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "foreign_live_receipt_rejected"
        }
        first.acknowledgeLive(foreignLiveReceipt, firstGeneration)
        val ownLiveReceipt = secondStore.commit(secondLive)
        second.acknowledgeLive(ownLiveReceipt, secondGeneration)
        first.stopLive(firstLiveToken)
        second.stopLive(secondLiveToken)
        events += "own_live_receipt_accepted"

        val firstToken = first.beginOperation(BandOperationClass.HISTORY)
        val secondToken = second.beginOperation(BandOperationClass.HISTORY)
        val firstHistory = first.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstToken,
            firstGeneration,
        )
        val secondHistory = second.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            secondToken,
            secondGeneration,
        )
        val foreignHistoryReceipt = firstStore.commit(firstHistory)
        try {
            second.acknowledgeHistory(
                foreignHistoryReceipt,
                secondToken,
                secondGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "foreign_history_receipt_rejected"
        }
        try {
            second.completeOperation(firstToken)
        } catch (error: BandException) {
            failure = error.category
            events += "foreign_operation_token_rejected"
        }
        val ownHistoryReceipt = secondStore.commit(secondHistory)
        second.acknowledgeHistory(
            ownHistoryReceipt,
            secondToken,
            secondGeneration,
        )
        second.completeOperation(secondToken)
        events += "own_history_completed"

        return result(
            "cross_session_credentials_rejected",
            events,
            second.snapshot(),
            acceptedSamples =
                secondLive.acceptedSamples.size +
                    secondHistory.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun staleTerminalCallbacksRejected(): BandConformanceResult {
        val scanSession = BandSessionMachine()
        val firstScan = scanSession.beginScan()
        scanSession.cancelScan(firstScan)
        val secondScan = scanSession.beginScan()
        val events = mutableListOf("scan_restarted")
        var failure: BandFailureCategory? = null
        try {
            scanSession.cancelScan(firstScan)
        } catch (error: BandException) {
            failure = error.category
            events += "stale_scan_cancel_rejected"
        }
        try {
            scanSession.failScan(
                BandFailureCategory.TIMEOUT,
                firstScan,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_scan_failure_rejected"
        }
        if (scanSession.snapshot().state != BandSessionState.SCANNING) {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        scanSession.cancelScan(secondScan)

        val (session, generation, connectionToken) = readySessionWithToken()
        events += "ready"
        try {
            session.interruptForReconnect(connectionToken, generation - 1)
        } catch (error: BandException) {
            failure = error.category
            events += "stale_reconnect_interrupt_rejected"
        }
        val firstReconnect =
            session.interruptForReconnect(connectionToken, generation)
        events += "reconnect_started"
        val firstConnectionToken = session.resumeAfterReconnect(
            firstReconnect,
            firstReconnect.generation,
        )
        events += "first_reconnect_completed"
        val secondReconnect =
            session.interruptForReconnect(
                firstConnectionToken,
                firstReconnect.generation,
            )
        events += "second_reconnect_started"
        try {
            session.resumeAfterReconnect(
                firstReconnect,
                firstReconnect.generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_reconnect_completion_rejected"
        }
        session.resumeAfterReconnect(
            secondReconnect,
            secondReconnect.generation,
        )
        events += "reconnected"
        return result(
            "stale_terminal_callbacks_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun establishedFailureSessionBound(): BandConformanceResult {
        val (_, firstGeneration, firstToken) = readySessionWithToken()
        val (second, secondGeneration, secondToken) = readySessionWithToken()
        check(firstGeneration == secondGeneration)

        val events = mutableListOf("ready_pair")
        var failure: BandFailureCategory? = null
        try {
            second.failEstablishedSession(
                BandFailureCategory.AUTHENTICATION,
                firstToken,
                secondGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_failure_rejected"
        }

        check(second.snapshot().state == BandSessionState.READY)
        events += "current_session_preserved"

        second.failEstablishedSession(
            BandFailureCategory.AUTHENTICATION,
            secondToken,
            secondGeneration,
        )
        events += "own_failure_accepted"

        return result(
            "established_failure_session_bound",
            events,
            second.snapshot(),
            failure = failure,
        )
    }

    private fun reconnectCallbackSessionBound(): BandConformanceResult {
        val (foreignSession, foreignGeneration, foreignConnectionToken) =
            readySessionWithToken()
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation, connectionToken) =
            readySessionWithToken(diagnostics = diagnostics)
        check(generation == foreignGeneration)

        val events = mutableListOf("ready_pair")
        var failure: BandFailureCategory? = null
        session.beginLive()
        try {
            session.interruptForReconnect(
                foreignConnectionToken,
                generation,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_interrupt_rejected"
        }

        val livePreserved = session.snapshot()
        check(livePreserved.state == BandSessionState.LIVE_COLLECTING)
        check(livePreserved.liveActive)
        events += "current_live_preserved"

        val eventCount = diagnostics.snapshot().size
        val reconnectToken =
            session.interruptForReconnect(connectionToken, generation)
        val foreignReconnectToken =
            foreignSession.interruptForReconnect(
                foreignConnectionToken,
                foreignGeneration,
            )
        check(reconnectToken.generation == foreignReconnectToken.generation)
        check(
            diagnostics.snapshot().drop(eventCount) == listOf(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.INTERRUPTED,
                ),
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.INTERRUPTED,
                ),
            ),
        )
        events += "live_interruption_ordered"

        try {
            session.resumeAfterReconnect(
                foreignReconnectToken,
                reconnectToken.generation,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "foreign_resume_rejected"
        }

        val recoveryPreserved = session.snapshot()
        check(recoveryPreserved.state == BandSessionState.RECOVERING)
        check(!recoveryPreserved.liveActive)
        events += "current_recovery_preserved"

        session.resumeAfterReconnect(
            reconnectToken,
            reconnectToken.generation,
        )
        events += "own_resume_accepted"
        return result(
            "reconnect_callback_session_bound",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun reconnectedEstablishedFailureAuthorized():
        BandConformanceResult {
        val (session, generation, originalToken) = readySessionWithToken()
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null

        val reconnectAuthority =
            session.interruptForReconnect(originalToken, generation)
        val reconnectToken =
            session.resumeAfterReconnect(
                reconnectAuthority,
                reconnectAuthority.generation,
            )
        events += "reconnected"

        try {
            session.failEstablishedSession(
                BandFailureCategory.AUTHENTICATION,
                originalToken,
                reconnectAuthority.generation,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "stale_previous_failure_rejected"
        }

        check(session.snapshot().state == BandSessionState.READY)
        events += "resumed_session_preserved"

        session.failEstablishedSession(
            BandFailureCategory.AUTHENTICATION,
            reconnectToken,
            reconnectAuthority.generation,
        )
        events += "resumed_failure_accepted"

        return result(
            "reconnected_established_failure_authorized",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun supersededLiveStopRejected(): BandConformanceResult {
        val (session, _) = readySession()
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null

        val firstToken = session.beginLive()
        session.stopLive(firstToken)
        events += "first_live_stopped"

        val secondToken = session.beginLive()
        try {
            session.stopLive(firstToken)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                fail(BandFailureCategory.INTERNAL_FAILURE)
            }
            failure = error.category
            events += "stale_stop_rejected"
        }

        val preserved = session.snapshot()
        check(preserved.state == BandSessionState.LIVE_COLLECTING)
        check(preserved.liveActive)
        events += "current_live_preserved"

        session.stopLive(secondToken)
        events += "current_stop_accepted"

        return result(
            "superseded_live_stop_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun sameSessionReplayRejected(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null

        val liveToken = session.beginLive()
        val firstLive = session.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            liveToken,
            generation,
        )
        val firstLiveReceipt = store.commit(firstLive)
        session.acknowledgeLive(firstLiveReceipt, generation)
        events += "first_live_committed"
        val secondLiveBatch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v1",
            calibrationRevision = "calibration-v1",
            samples = listOf(
                BandSample(
                    identity = BandSampleIdentity(
                        stream = BandStreamKind.HEART_RATE,
                        sequence = 100,
                        deviceTimeMilliseconds = 100_000,
                    ),
                    value = 73.0,
                    unit = BandUnit.BEATS_PER_MINUTE,
                    quality = BandSampleQuality.ACCEPTED,
                ),
            ),
        )
        val secondLive = session.stageLiveBatch(
            secondLiveBatch,
            liveToken,
            generation,
        )
        try {
            session.acknowledgeLive(firstLiveReceipt, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "stale_live_receipt_rejected"
        }
        session.acknowledgeLive(store.commit(secondLive), generation)
        session.stopLive(liveToken)
        events += "second_live_committed"

        val firstCommand =
            session.beginOperation(BandOperationClass.BATTERY)
        session.completeOperation(firstCommand)
        val secondCommand =
            session.beginOperation(BandOperationClass.BATTERY)
        try {
            session.completeOperation(firstCommand)
        } catch (error: BandException) {
            failure = error.category
            events += "stale_operation_token_rejected"
        }
        session.completeOperation(secondCommand)

        val firstHistoryToken =
            session.beginOperation(BandOperationClass.HISTORY)
        val firstHistory = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstHistoryToken,
            generation,
        )
        val firstHistoryReceipt = store.commit(firstHistory)
        session.acknowledgeHistory(
            firstHistoryReceipt,
            firstHistoryToken,
            generation,
        )
        session.completeOperation(firstHistoryToken)
        events += "first_history_committed"

        val secondHistoryChunk = BandHistoryChunk(
            chunkIdentity = "chunk-replay-2",
            previousCursor = "cursor-2",
            nextCursor = "cursor-3",
            complete = true,
            overflowed = false,
            retainedRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 101_000,
                endDeviceTimeMilliseconds = 101_000,
            ),
            firstLostRange = null,
            acknowledgementToken = "ack-replay-2",
            batches = listOf(
                BandSampleBatch(
                    sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
                    lane = BandProvenanceLane.HISTORY,
                    parserRevision = "parser-v1",
                    calibrationRevision = "calibration-v1",
                    samples = listOf(
                        BandSample(
                            identity = BandSampleIdentity(
                                stream = BandStreamKind.HEART_RATE,
                                sequence = 101,
                                deviceTimeMilliseconds = 101_000,
                            ),
                            value = 71.0,
                            unit = BandUnit.BEATS_PER_MINUTE,
                            quality = BandSampleQuality.ACCEPTED,
                        ),
                    ),
                ),
            ),
        )
        val secondHistoryToken =
            session.beginOperation(BandOperationClass.HISTORY)
        val secondHistory = session.stageHistoryChunk(
            secondHistoryChunk,
            secondHistoryToken,
            generation,
        )
        try {
            session.acknowledgeHistory(
                firstHistoryReceipt,
                secondHistoryToken,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_history_receipt_rejected"
        }
        val secondHistoryReceipt = store.commit(secondHistory)
        session.acknowledgeHistory(
            secondHistoryReceipt,
            secondHistoryToken,
            generation,
        )
        session.completeOperation(secondHistoryToken)
        events += "second_history_committed"

        return result(
            "same_session_replay_rejected",
            events,
            session.snapshot(),
            acceptedSamples =
                firstLive.acceptedSamples.size +
                    secondLive.acceptedSamples.size +
                    firstHistory.acceptedSamples.size +
                    secondHistory.acceptedSamples.size,
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
                    acceptance = acceptance,
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
        val retryAcceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token,
            generation,
        )
        val receipt = store.commit(retryAcceptance)
        events += "history_committed"
        session.acknowledgeHistory(receipt, token, generation)
        events += "history_acknowledged"
        session.completeOperation(token)
        return result(
            "history_requires_durable_receipt",
            events,
            session.snapshot(),
            acceptedSamples = retryAcceptance.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun liveDoesNotAdvanceHistory(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val before = session.snapshot().acknowledgedHistoryCursor
        val liveToken = session.beginLive()
        val accepted = session.durablyCommitLiveBatch(
            VirtualBandFixtures.liveBatch,
            liveToken,
            generation,
        )
        events += "live_committed"
        val after = session.snapshot().acknowledgedHistoryCursor
        if (before != after) {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        events += "cursor_unchanged"
        session.stopLive(liveToken)
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
        val liveToken = session.beginLive()
        val accepted = session.durablyCommitLiveBatch(
            VirtualBandFixtures.duplicateLiveBatch,
            liveToken,
            generation,
        )
        events += "live_committed"
        session.stopLive(liveToken)
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
        val firstReceipt = store.commit(firstAcceptance)
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
        session.cancelOperation(secondToken)
        events += "operation_cancelled"

        return result(
            "history_cursor_chain_rejected",
            events,
            session.snapshot(),
            acceptedSamples = firstAcceptance.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun operationCapabilityFailsClosed(): BandConformanceResult {
        val session = BandSessionMachine()
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            virtualCapabilityReport(
                schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
                protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
                hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
                firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
                historyDays = 7,
                capabilities = setOf(
                    BandCapability.BATTERY,
                    BandCapability.HEART_RATE,
                ),
                liveStreams = setOf(BandStreamKind.HEART_RATE),
                historyStreams = setOf(BandStreamKind.HEART_RATE),
            ),
            connectionToken,
            generation,
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
        val liveToken = session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.durablyCommitLiveBatch(batch, liveToken, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "oversized_metadata_rejected"
        }
        session.stopLive(liveToken)
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
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        events += "scan_started"
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        events += "candidate_selected"
        val identity = VirtualBandFixtures.identity.copy(
            protocolVersion = "noop-band-v2",
        )
        session.completeConnectionForConformance(
            identity,
            connectionToken,
            generation,
        )
        events += "connected"
        val report = virtualCapabilityReport(
            schemaVersion = 2,
            protocolVersion = "noop-band-v2",
            hardwareRevision = identity.hardwareRevision,
            firmwareVersion = identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
        )
        var failure: BandFailureCategory? = null
        try {
            session.acceptCapabilities(report, connectionToken, generation)
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
        val (session, generation, connectionToken) = readySessionWithToken()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        val firstToken = session.beginOperation(BandOperationClass.HISTORY)
        val firstAcceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstToken,
            generation,
        )
        events += "history_received"
        try {
            session.interruptForReconnect(connectionToken, generation)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.BUSY) {
                throw error
            }
            events += "persistence_drain_required"
        }
        try {
            session.acknowledgeHistory(
                DurableHistoryReceipt(
                    acceptance = firstAcceptance,
                    historyStateCommitted = false,
                    committedSamples = 0,
                    committed = false,
                ),
                firstToken,
                generation,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STORAGE) {
                throw error
            }
            events += "persistence_failed"
        }
        val reconnectToken =
            session.interruptForReconnect(connectionToken, generation)
        val failure = BandFailureCategory.DISCONNECTED
        events += "history_interrupted"
        session.resumeAfterReconnect(
            reconnectToken,
            reconnectToken.generation,
        )
        events += "reconnected"
        val secondToken = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            secondToken,
            reconnectToken.generation,
        )
        events += "history_resumed"
        val receipt = store.commit(acceptance)
        events += "history_committed"
        session.acknowledgeHistory(
            receipt,
            secondToken,
            reconnectToken.generation,
        )
        events += "history_acknowledged"
        session.completeOperation(secondToken)
        return result(
            "history_interrupted_resume",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples.size,
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
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            generation,
        )
        val events = mutableListOf("ready")
        if (session.snapshot().acknowledgedHistoryCursor != "cursor-2") {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        events += "checkpoint_restored"
        val token = session.beginOperation(BandOperationClass.HISTORY)
        try {
            session.completeOperation(token)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STORAGE) {
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
            retainedRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 2_000,
                endDeviceTimeMilliseconds = 4_000,
            ),
            firstLostRange = null,
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
        val receipt = VirtualBandStore().commit(acceptance)
        events += "history_committed"
        session.acknowledgeHistory(receipt, token, generation)
        events += "history_acknowledged"
        session.completeOperation(token)
        return result(
            "history_checkpoint_restored",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples.size,
        )
    }

    private fun historyCheckpointSurvivesSourceMismatch(): BandConformanceResult {
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
        val alternateIdentity = VirtualBandFixtures.identity.copy(
            sourceIdentity = "alternate-source",
            hardwareRevision = "alternate-hw-1",
            firmwareVersion = "alternate-fw-1",
        )
        val alternateCapabilities = VirtualBandFixtures.capabilities.copy(
            hardwareRevision = alternateIdentity.hardwareRevision,
            firmwareVersion = alternateIdentity.firmwareVersion,
        )

        var scanToken = session.beginScan()

        var generation = scanToken.generation
        var connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            alternateIdentity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            alternateCapabilities,
            connectionToken,
            generation,
        )
        val events = mutableListOf("alternate_source_ready")
        if (
            session.snapshot().acknowledgedHistoryCursor != null ||
            session.snapshot().durableSampleCount != 0
        ) {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }

        session.disconnect(
            BandDisconnectReason.COLLECTOR_HANDOFF,
            generation,
        )
        events += "alternate_source_disconnected"

        scanToken = session.beginScan()

        generation = scanToken.generation
        connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            generation,
        )
        val snapshot = session.snapshot()
        if (
            snapshot.acknowledgedHistoryCursor == "cursor-2" &&
            snapshot.durableSampleCount ==
            checkpoint.durableSampleIdentities.size
        ) {
            events += "checkpoint_restored"
        } else {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        return result(
            "history_checkpoint_survives_source_mismatch",
            events,
            snapshot,
            acceptedSamples = snapshot.durableSampleCount,
        )
    }

    private fun firmwareEligibilitySpecific(): BandConformanceResult {
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
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
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.HEART_RATE),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
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
        val liveToken = session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.durablyCommitLiveBatch(batch, liveToken, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "live_stream_rejected"
        }
        session.stopLive(liveToken)
        events += "live_stopped"
        val historyToken = session.beginOperation(BandOperationClass.HISTORY)
        val historyChunk = BandHistoryChunk(
            chunkIdentity = "chunk-unnegotiated",
            previousCursor = null,
            nextCursor = "cursor-unnegotiated",
            complete = true,
            overflowed = false,
            retainedRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 4_000,
                endDeviceTimeMilliseconds = 4_000,
            ),
            firstLostRange = null,
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
        session.cancelOperation(historyToken)
        events += "operation_cancelled"
        return result(
            "unnegotiated_stream_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun firmwareBlockedDuringLive(): BandConformanceResult {
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(
                BandCapability.HEART_RATE,
                BandCapability.FIRMWARE_UPDATE,
            ),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
        )
        val (session, _) = readySession(report)
        val events = mutableListOf("ready")
        val liveToken = session.beginLive()
        events += "live_started"
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(BandOperationClass.FIRMWARE)
        } catch (error: BandException) {
            failure = error.category
            events += "firmware_rejected"
        }
        session.stopLive(liveToken)
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
            retainedRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 4_000,
                endDeviceTimeMilliseconds = 4_000,
            ),
            firstLostRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 1_000,
                endDeviceTimeMilliseconds = 3_999,
            ),
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
        var firstAcceptance =
            session.stageHistoryChunk(firstChunk, token, generation)
        events += "history_received"
        try {
            session.acknowledgeHistory(
                DurableHistoryReceipt(
                    acceptance = firstAcceptance,
                    historyStateCommitted = false,
                    committedSamples = firstAcceptance.acceptedSamples.size,
                    committed = true,
                ),
                token,
                generation,
            )
        } catch (_: BandException) {
            events += "receipt_rejected"
        }
        firstAcceptance =
            session.stageHistoryChunk(firstChunk, token, generation)
        val firstReceipt = store.commit(firstAcceptance)
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
            retainedRange = BandHistoryRange(
                startDeviceTimeMilliseconds = 5_000,
                endDeviceTimeMilliseconds = 5_000,
            ),
            firstLostRange = null,
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
        val terminalReceipt = store.commit(terminalAcceptance)
        session.acknowledgeHistory(terminalReceipt, token, generation)
        events += "terminal_committed"
        try {
            session.stageHistoryChunk(terminalChunk, token, generation)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.INVALID_STATE) {
                throw error
            }
            events += "post_terminal_chunk_rejected"
        }
        session.completeOperation(token)
        events += "operation_completed"
        return result(
            "history_state_requires_durable_receipt",
            events,
            session.snapshot(),
            acceptedSamples =
                firstAcceptance.acceptedSamples.size +
                    terminalAcceptance.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun staleCapabilityCallbackRejected(): BandConformanceResult {
        val (session, oldGeneration, oldConnectionToken) =
            readySessionWithToken()
        val events = mutableListOf("ready")
        val reconnectToken =
            session.interruptForReconnect(
                oldConnectionToken,
                oldGeneration,
            )
        session.resumeAfterReconnect(
            reconnectToken,
            reconnectToken.generation,
        )
        events += "generation_advanced"
        var failure: BandFailureCategory? = null
        try {
            session.acceptCapabilities(
                VirtualBandFixtures.capabilities,
                oldConnectionToken,
                oldGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_capability_rejected"
        }
        if (session.snapshot().state != BandSessionState.READY) {
            fail(BandFailureCategory.INTERNAL_FAILURE)
        }
        return result(
            "stale_capability_callback_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun invalidDeviceTimeRejected(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val invalidSample = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.HEART_RATE,
                sequence = 10,
                deviceTimeMilliseconds = -1,
            ),
            value = 72.0,
            unit = BandUnit.BEATS_PER_MINUTE,
            quality = BandSampleQuality.ACCEPTED,
        )
        val batch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v1",
            calibrationRevision = "calibration-v1",
            samples = listOf(invalidSample),
        )
        val liveToken = session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.durablyCommitLiveBatch(batch, liveToken, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "invalid_device_time_rejected"
        }
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "invalid_device_time_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun historyOperationRequiresOwnReceipt(): BandConformanceResult {
        val (session, generation) = readySession()
        val store = VirtualBandStore()
        val events = mutableListOf("ready")
        val firstToken = session.beginOperation(BandOperationClass.HISTORY)
        val firstAcceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            firstToken,
            generation,
        )
        val firstReceipt = store.commit(firstAcceptance)
        session.acknowledgeHistory(firstReceipt, firstToken, generation)
        session.completeOperation(firstToken)
        events += "first_history_completed"

        val secondToken = session.beginOperation(BandOperationClass.HISTORY)
        var failure: BandFailureCategory? = null
        try {
            session.completeOperation(secondToken)
        } catch (error: BandException) {
            failure = error.category
            events += "own_receipt_required"
        }
        session.cancelOperation(secondToken)
        events += "operation_cancelled"
        return result(
            "history_operation_requires_own_receipt",
            events,
            session.snapshot(),
            acceptedSamples = firstAcceptance.acceptedSamples.size,
            failure = failure,
        )
    }

    private fun firmwareDiagnosticsSpecific(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        try {
            session.beginOperation(BandOperationClass.FIRMWARE)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.INVALID_STATE) {
                throw error
            }
        }
        val initialConnectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            initialConnectionToken,
            generation,
        )
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(
                BandCapability.HEART_RATE,
                BandCapability.FIRMWARE_UPDATE,
            ),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = setOf(BandStreamKind.HEART_RATE),
        )
        session.acceptCapabilities(
            report,
            initialConnectionToken,
            generation,
        )
        val events = mutableListOf("ready")
        val token = session.beginOperation(BandOperationClass.FIRMWARE)
        session.completeOperation(token)
        val postFirmwareScanToken = session.beginScan()
        val postFirmwareGeneration = postFirmwareScanToken.generation
        val postFirmwareConnectionToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                postFirmwareScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            postFirmwareConnectionToken,
            postFirmwareGeneration,
        )
        session.acceptCapabilities(
            report,
            postFirmwareConnectionToken,
            postFirmwareGeneration,
        )
        val liveToken = session.beginLive()
        try {
            session.beginOperation(BandOperationClass.FIRMWARE)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.BUSY) {
                throw error
            }
        }
        session.stopLive(liveToken)
        val staleToken = session.beginOperation(BandOperationClass.FIRMWARE)
        check(
            session.failOperation(
                staleToken,
                BandFailureCategory.DISCONNECTED,
            ) == null,
        )
        val recoveryScanToken = session.beginScan()
        val recoveryGeneration = recoveryScanToken.generation
        val recoveryConnectionToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                recoveryScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            recoveryConnectionToken,
            recoveryGeneration,
        )
        session.acceptCapabilities(
            report,
            recoveryConnectionToken,
            recoveryGeneration,
        )
        try {
            session.completeOperation(staleToken)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
        }
        val firmwareEvents = diagnostics.snapshot().filter {
            it.kind == BandDiagnosticKind.FIRMWARE
        }
        val firmwareEvidence = firmwareEvents.map {
            "${it.outcome.name.lowercase()}:${
                it.failureCategory?.wireValue ?: "none"
            }:${it.operationClass?.wireValue ?: "none"}"
        }
        if (
            firmwareEvidence == listOf(
                "rejected:invalidState:firmware",
                "began:none:firmware",
                "completed:none:firmware",
                "rejected:busy:firmware",
                "began:none:firmware",
                "interrupted:disconnected:firmware",
                "rejected:staleCallback:firmware",
            )
        ) {
            events += "firmware_diagnostics_specific"
        } else {
            events += "firmware_diagnostics_incorrect"
        }
        return result(
            "firmware_diagnostics_specific",
            events,
            session.snapshot(),
        )
    }

    private fun firmwareTerminalFailure(): BandConformanceResult {
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 0,
            capabilities = setOf(
                BandCapability.HEART_RATE,
                BandCapability.FIRMWARE_UPDATE,
            ),
            liveStreams = setOf(BandStreamKind.HEART_RATE),
            historyStreams = emptySet(),
        )
        val diagnostics = BandDiagnosticsRecorder()
        val (session, _, connectionToken) =
            readySessionWithToken(report, diagnostics)
        val events = mutableListOf("ready")
        val token = session.beginOperation(BandOperationClass.FIRMWARE)
        events += "firmware_started"
        session.failOperation(
            token,
            BandFailureCategory.UPDATE_VERIFICATION,
            BandFirmwareFailureDisposition.TERMINAL,
        )
        events += "firmware_terminal"
        val terminalGeneration = session.snapshot().generation

        try {
            session.interruptForReconnect(
                connectionToken,
                terminalGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "reconnect_rejected"
        }

        if (
            diagnostics.snapshot().last {
                it.kind == BandDiagnosticKind.FIRMWARE
            } == BandDiagnosticEvent(
                BandDiagnosticKind.FIRMWARE,
                BandDiagnosticOutcome.TERMINAL,
                failureCategory = BandFailureCategory.UPDATE_VERIFICATION,
                operationClass = BandOperationClass.FIRMWARE,
            )
        ) {
            events += "terminal_diagnostic_recorded"
        }

        var failure: BandFailureCategory? = null
        try {
            session.beginScan()
        } catch (error: BandException) {
            failure = error.category
            events += "same_session_restart_rejected"
        }

        BandSessionMachine().beginScan()
        events += "replacement_scan_started"
        return result(
            "firmware_terminal_failure",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun historyNonadvancingCursorRejected(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val chunk = BandHistoryChunk(
            chunkIdentity = "chunk-stalled",
            previousCursor = null,
            nextCursor = null,
            complete = false,
            overflowed = false,
            retainedRange = null,
            firstLostRange = null,
            acknowledgementToken = "ack-stalled",
            batches = emptyList(),
        )
        var failure: BandFailureCategory? = null
        try {
            session.stageHistoryChunk(chunk, token, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "nonadvancing_cursor_rejected"
        }
        session.cancelOperation(token)
        events += "operation_cancelled"
        return result(
            "history_nonadvancing_cursor_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun utf8LengthCrossPlatform(): BandConformanceResult {
        val (session, generation) = readySession()
        val events = mutableListOf("ready")
        val batch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "é".repeat(33),
            calibrationRevision = "calibration-v1",
            samples = VirtualBandFixtures.liveBatch.samples,
        )
        val liveToken = session.beginLive()
        var failure: BandFailureCategory? = null
        try {
            session.durablyCommitLiveBatch(batch, liveToken, generation)
        } catch (error: BandException) {
            failure = error.category
            events += "utf8_limit_rejected"
        }
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "utf8_length_cross_platform",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun samplingRequiresSensorCapability(): BandConformanceResult {
        val report = virtualCapabilityReport(
            schemaVersion = BandCapabilityReport.SUPPORTED_SCHEMA_VERSION,
            protocolVersion = BandCapabilityReport.SUPPORTED_PROTOCOL_VERSION,
            hardwareRevision = VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion = VirtualBandFixtures.identity.firmwareVersion,
            historyDays = 7,
            capabilities = setOf(BandCapability.BATTERY),
            liveStreams = emptySet(),
            historyStreams = emptySet(),
        )
        val (session, _) = readySession(report)
        val events = mutableListOf("ready")
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(BandOperationClass.SAMPLING)
        } catch (error: BandException) {
            failure = error.category
            events += "sampling_rejected"
        }
        return result(
            "sampling_requires_sensor_capability",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun durableIdentityCacheBounded(): BandConformanceResult {
        val samePositionStreams = listOf(
            BandStreamKind.HEART_RATE,
            BandStreamKind.RR_INTERVAL,
            BandStreamKind.STEPS,
            BandStreamKind.SPO2,
            BandStreamKind.RESPIRATION,
            BandStreamKind.TEMPERATURE,
            BandStreamKind.ACCELERATION,
        )
        val identities = samePositionStreams.map {
            BandSampleIdentity(
                stream = it,
                sequence = 0,
                deviceTimeMilliseconds = 0,
            )
        }.toMutableSet()
        val remaining =
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES -
                samePositionStreams.size
        (1..remaining).forEach {
            identities +=
                BandSampleIdentity(
                    stream = BandStreamKind.HEART_RATE,
                    sequence = it.toLong(),
                    deviceTimeMilliseconds = it.toLong(),
                )
        }
        val checkpoint = BandHistoryCheckpoint(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            acknowledgedCursor = null,
            lastHistoryComplete = null,
            durableSampleIdentities = identities,
        )
        val session = BandSessionMachine(restoredHistoryCheckpoint = checkpoint)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        val capabilities = VirtualBandFixtures.capabilities.copy(
            capabilities =
                VirtualBandFixtures.capabilities.capabilities +
                    BandCapability.ACCELEROMETER,
        )
        session.acceptCapabilities(capabilities, connectionToken, generation)
        val events = mutableListOf("ready")
        val next = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.HEART_RATE,
                sequence =
                    BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES.toLong(),
                deviceTimeMilliseconds =
                    BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES.toLong(),
            ),
            value = 72.0,
            unit = BandUnit.BEATS_PER_MINUTE,
            quality = BandSampleQuality.ACCEPTED,
        )
        val batch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v1",
            calibrationRevision = "calibration-v1",
            samples = listOf(next),
        )
        val liveToken = session.beginLive()
        val accepted =
            session.durablyCommitLiveBatch(batch, liveToken, generation)
        val evictedCandidate = BandSample(
            identity = BandSampleIdentity(
                stream = BandStreamKind.ACCELERATION,
                sequence = 0,
                deviceTimeMilliseconds = 0,
            ),
            value = 0.0,
            unit = BandUnit.GRAVITY,
            quality = BandSampleQuality.ACCEPTED,
        )
        val evictionProbe = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.identity.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v1",
            calibrationRevision = "calibration-v1",
            samples = listOf(evictedCandidate),
        )
        val evictionAccepted =
            session.durablyCommitLiveBatch(
                evictionProbe,
                liveToken,
                generation,
            )
        if (
            accepted == 1 &&
            evictionAccepted == 1 &&
            session.snapshot().durableSampleCount ==
            BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES
        ) {
            events += "identity_cache_bounded"
        } else {
            events += "identity_cache_unbounded"
        }
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "durable_identity_cache_bounded",
            events,
            session.snapshot(),
            acceptedSamples = accepted + evictionAccepted,
        )
    }

    private fun operationTerminalPaths(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            generation,
        )
        val events = mutableListOf("ready")
        val cancelled = session.beginOperation(BandOperationClass.BATTERY)
        session.cancelOperation(cancelled)
        events += "operation_cancelled"
        val failed = session.beginOperation(BandOperationClass.HAPTIC)
        session.failOperation(failed, BandFailureCategory.TIMEOUT)
        val lastEvent = diagnostics.snapshot().lastOrNull()
        if (
            lastEvent?.kind == BandDiagnosticKind.COMMAND &&
            lastEvent.outcome == BandDiagnosticOutcome.FAILED &&
            lastEvent.failureCategory == BandFailureCategory.TIMEOUT
        ) {
            events += "operation_failed"
        } else {
            events += "operation_failure_incorrect"
        }
        val liveToken = session.beginLive()
        val disconnected = session.beginOperation(BandOperationClass.BATTERY)
        val reconnectAuthority = session.failOperation(
            disconnected,
            BandFailureCategory.DISCONNECTED,
        ) ?: fail(BandFailureCategory.INTERNAL_FAILURE)
        val recovering = session.snapshot()
        if (
            recovering.state == BandSessionState.RECOVERING &&
            recovering.generation == generation + 1 &&
            !recovering.liveActive
        ) {
            events += "disconnect_recovery"
        } else {
            events += "disconnect_recovery_incorrect"
        }
        try {
            session.durablyCommitLiveBatch(
                VirtualBandFixtures.liveBatch,
                liveToken,
                generation,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "stale_callback_rejected"
        }
        session.resumeAfterReconnect(
            reconnectAuthority,
            reconnectAuthority.generation,
        )
        events += "reconnected"
        val securityGeneration = reconnectAuthority.generation
        val securityFailed = session.beginOperation(BandOperationClass.BATTERY)
        session.failOperation(
            securityFailed,
            BandFailureCategory.SECURITY_FAILURE,
        )
        val securityTerminal = session.snapshot()
        if (
            securityTerminal.state == BandSessionState.SECURITY_FAILURE &&
            securityTerminal.generation == securityGeneration + 1 &&
            securityTerminal.activeOperation == null &&
            !securityTerminal.liveActive
        ) {
            events += "security_failure_terminal"
        } else {
            events += "security_failure_not_terminal"
        }
        try {
            session.failOperation(securityFailed, BandFailureCategory.TIMEOUT)
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "security_failure_stale_token_rejected"
        }
        try {
            session.beginScan()
            events += "security_failure_restart_incorrect"
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.INVALID_STATE) {
                throw error
            }
            events += "security_failure_restart_rejected"
        }
        val replacement = BandSessionMachine(diagnostics)
        val replacementScanToken = replacement.beginScan()
        val replacementGeneration = replacementScanToken.generation
        val replacementConnectionToken =
            replacement.selectCandidate(
                VirtualBandFixtures.candidate,
                replacementScanToken,
            )
        replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            replacementConnectionToken,
            replacementGeneration,
        )
        replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            replacementConnectionToken,
            replacementGeneration,
        )
        events += "replacement_session_ready"
        return result(
            "operation_terminal_paths",
            events,
            replacement.snapshot(),
        )
    }

    private fun connectionCallbacksGenerationFenced(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val events = mutableListOf<String>()
        var failure: BandFailureCategory? = null

        val oldScanToken = session.beginScan()

        val oldGeneration = oldScanToken.generation
        val oldConnectionToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                oldScanToken,
            )
        session.beginConnection(oldConnectionToken, oldGeneration)
        events += "connection_started"
        session.failConnection(
            BandFailureCategory.TIMEOUT,
            oldConnectionToken,
            BandConnectionPhase.CONNECTION,
            oldGeneration,
        )
        if (session.snapshot().state == BandSessionState.RECOVERING) {
            events += "connection_failed"
        } else {
            events += "connection_failure_incorrect"
        }

        val currentScanToken = session.beginScan()

        val currentGeneration = currentScanToken.generation
        val currentConnectionToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                currentScanToken,
            )
        session.beginConnection(currentConnectionToken, currentGeneration)
        session.beginAuthentication(currentConnectionToken, currentGeneration)
        try {
            session.cancelConnection(
                oldConnectionToken,
                BandConnectionPhase.CONNECTION,
                oldGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "stale_cancel_rejected"
        }
        try {
            session.failConnection(
                BandFailureCategory.TIMEOUT,
                oldConnectionToken,
                BandConnectionPhase.CONNECTION,
                oldGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "stale_failure_rejected"
        }
        val beforeCompletion = session.snapshot()
        if (
            beforeCompletion.state == BandSessionState.AUTHENTICATING &&
            beforeCompletion.generation == currentGeneration
        ) {
            events += "stale_terminals_preserved_state"
        } else {
            events += "stale_terminals_mutated_state"
        }
        try {
            session.completeConnection(
                VirtualBandFixtures.identity,
                oldConnectionToken,
                oldGeneration,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_connection_rejected"
        }
        session.completeConnection(
            VirtualBandFixtures.identity,
            currentConnectionToken,
            currentGeneration,
        )
        events += "connected"
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            currentConnectionToken,
            currentGeneration,
        )
        events += "capabilities_accepted"

        val recorded = diagnostics.snapshot()
        val connectionStaleCount = recorded.count {
            it.kind == BandDiagnosticKind.CONNECTION &&
                it.outcome == BandDiagnosticOutcome.STALE &&
                it.failureCategory == BandFailureCategory.STALE_CALLBACK
        }
        val authenticationStaleCount = recorded.count {
            it.kind == BandDiagnosticKind.AUTHENTICATION &&
                it.outcome == BandDiagnosticOutcome.STALE &&
                it.failureCategory == BandFailureCategory.STALE_CALLBACK
        }
        if (connectionStaleCount == 2 && authenticationStaleCount == 1) {
            events += "stale_phases_preserved"
        } else {
            events += "stale_phases_incorrect"
        }
        if (
            recorded.any {
                it.kind == BandDiagnosticKind.CONNECTION &&
                    it.outcome == BandDiagnosticOutcome.TIMED_OUT &&
                    it.failureCategory == BandFailureCategory.TIMEOUT
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.AUTHENTICATION &&
                    it.outcome == BandDiagnosticOutcome.STALE &&
                    it.failureCategory == BandFailureCategory.STALE_CALLBACK
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.AUTHENTICATION &&
                    it.outcome == BandDiagnosticOutcome.BEGAN
            }
        ) {
            events += "connection_diagnostics_bounded"
        } else {
            events += "connection_diagnostics_incorrect"
        }
        return result(
            "connection_callbacks_generation_fenced",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun connectionTerminalPaths(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val events = mutableListOf<String>()

        val cancellationScanToken = session.beginScan()

        val cancellationGeneration = cancellationScanToken.generation
        val cancellationToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                cancellationScanToken,
            )
        session.beginConnection(cancellationToken, cancellationGeneration)
        session.cancelConnection(
            cancellationToken,
            BandConnectionPhase.CONNECTION,
            cancellationGeneration,
        )
        if (session.snapshot().state == BandSessionState.IDLE) {
            events += "connection_cancelled"
        } else {
            events += "connection_cancellation_incorrect"
        }

        val authenticationScanToken = session.beginScan()

        val authenticationGeneration = authenticationScanToken.generation
        val authenticationToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                authenticationScanToken,
            )
        session.beginConnection(authenticationToken, authenticationGeneration)
        session.beginAuthentication(
            authenticationToken,
            authenticationGeneration,
        )
        session.failConnection(
            BandFailureCategory.AUTHENTICATION,
            authenticationToken,
            BandConnectionPhase.AUTHENTICATION,
            authenticationGeneration,
        )
        if (session.snapshot().state == BandSessionState.REJECTED) {
            events += "authentication_rejected"
        } else {
            events += "authentication_state_incorrect"
        }

        val securityScanToken = session.beginScan()

        val securityGeneration = securityScanToken.generation
        val securityToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                securityScanToken,
            )
        session.beginConnection(securityToken, securityGeneration)
        session.beginAuthentication(securityToken, securityGeneration)
        session.failConnection(
            BandFailureCategory.SECURITY_FAILURE,
            securityToken,
            BandConnectionPhase.AUTHENTICATION,
            securityGeneration,
        )
        if (session.snapshot().state == BandSessionState.SECURITY_FAILURE) {
            events += "security_failure"
        } else {
            events += "security_state_incorrect"
        }

        try {
            session.beginScan()
            events += "security_failure_restart_incorrect"
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.INVALID_STATE) {
                throw error
            }
            events += "security_failure_restart_rejected"
        }
        val replacement = BandSessionMachine(diagnostics)
        val replacementScanToken = replacement.beginScan()
        val replacementGeneration = replacementScanToken.generation
        val replacementConnectionToken =
            replacement.selectCandidate(
                VirtualBandFixtures.candidate,
                replacementScanToken,
            )
        replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            replacementConnectionToken,
            replacementGeneration,
        )
        replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            replacementConnectionToken,
            replacementGeneration,
        )
        events += "replacement_session_ready"

        val recorded = diagnostics.snapshot()
        if (
            recorded.any {
                it.kind == BandDiagnosticKind.CONNECTION &&
                    it.outcome == BandDiagnosticOutcome.CANCELLED
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.AUTHENTICATION &&
                    it.outcome == BandDiagnosticOutcome.REJECTED &&
                    it.failureCategory == BandFailureCategory.AUTHENTICATION
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.AUTHENTICATION &&
                    it.outcome == BandDiagnosticOutcome.REJECTED &&
                    it.failureCategory == BandFailureCategory.SECURITY_FAILURE
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.AUTHENTICATION &&
                    it.outcome == BandDiagnosticOutcome.BEGAN
            }
        ) {
            events += "connection_diagnostics_bounded"
        } else {
            events += "connection_diagnostics_incorrect"
        }
        return result(
            "connection_terminal_paths",
            events,
            replacement.snapshot(),
            failure = BandFailureCategory.SECURITY_FAILURE,
        )
    }

    private fun historyPendingBusyDiagnostics(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val scanToken = session.beginScan()
        val generation = scanToken.generation
        val connectionToken =
            session.selectCandidate(VirtualBandFixtures.candidate, scanToken)
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            connectionToken,
            generation,
        )
        session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            connectionToken,
            generation,
        )
        val token = session.beginOperation(BandOperationClass.HISTORY)
        val acceptance = session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token,
            generation,
        )
        val events = mutableListOf("history_pending")
        var failure: BandFailureCategory? = null
        try {
            session.stageHistoryChunk(
                VirtualBandFixtures.historyChunk,
                token,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "second_chunk_rejected"
        }
        if (
            diagnostics.snapshot().lastOrNull() == BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.BUSY,
            )
        ) {
            events += "history_busy_recorded"
        } else {
            events += "history_busy_missing"
        }
        session.acknowledgeHistory(
            DurableHistoryReceipt(
                acceptance = acceptance,
                historyStateCommitted = true,
                committedSamples = acceptance.acceptedSamples.size,
                committed = true,
            ),
            token,
            generation,
        )
        session.cancelOperation(token)
        events += "operation_cancelled"
        return result(
            "history_pending_busy_diagnostics",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun capabilityTerminalPaths(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        val events = mutableListOf<String>()

        val cancellationScanToken = session.beginScan()

        val cancellationGeneration = cancellationScanToken.generation
        val cancellationToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                cancellationScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            cancellationToken,
            cancellationGeneration,
        )
        session.cancelCapabilities(cancellationToken, cancellationGeneration)
        events += "capability_cancelled"
        try {
            session.cancelCapabilities(
                cancellationToken,
                cancellationGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "stale_cancel_rejected"
        }

        val timeoutScanToken = session.beginScan()

        val timeoutGeneration = timeoutScanToken.generation
        val timeoutToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                timeoutScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            timeoutToken,
            timeoutGeneration,
        )
        session.failCapabilities(
            BandFailureCategory.TIMEOUT,
            timeoutToken,
            timeoutGeneration,
        )
        events += "capability_timed_out"
        try {
            session.failCapabilities(
                BandFailureCategory.INTERNAL_FAILURE,
                timeoutToken,
                timeoutGeneration,
            )
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.STALE_CALLBACK) {
                throw error
            }
            events += "stale_failure_rejected"
        }

        val authenticationScanToken = session.beginScan()

        val authenticationGeneration = authenticationScanToken.generation
        val authenticationToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                authenticationScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            authenticationToken,
            authenticationGeneration,
        )
        session.failCapabilities(
            BandFailureCategory.AUTHENTICATION,
            authenticationToken,
            authenticationGeneration,
        )
        events += "capability_authentication_rejected"

        val disconnectedScanToken = session.beginScan()

        val disconnectedGeneration = disconnectedScanToken.generation
        val disconnectedToken =
            session.selectCandidate(
                VirtualBandFixtures.candidate,
                disconnectedScanToken,
            )
        session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            disconnectedToken,
            disconnectedGeneration,
        )
        session.failCapabilities(
            BandFailureCategory.DISCONNECTED,
            disconnectedToken,
            disconnectedGeneration,
        )
        events += "capability_disconnected"

        val securitySession = BandSessionMachine(diagnostics)
        val securityScanToken = securitySession.beginScan()
        val securityGeneration = securityScanToken.generation
        val securityToken =
            securitySession.selectCandidate(
                VirtualBandFixtures.candidate,
                securityScanToken,
            )
        securitySession.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            securityToken,
            securityGeneration,
        )
        securitySession.failCapabilities(
            BandFailureCategory.SECURITY_FAILURE,
            securityToken,
            securityGeneration,
        )
        events += "capability_security_failure"
        try {
            securitySession.beginScan()
        } catch (error: BandException) {
            if (error.category != BandFailureCategory.INVALID_STATE) {
                throw error
            }
            events += "security_failure_restart_rejected"
        }

        val replacement = BandSessionMachine(diagnostics)
        val replacementScanToken = replacement.beginScan()
        val replacementGeneration = replacementScanToken.generation
        val replacementConnectionToken =
            replacement.selectCandidate(
                VirtualBandFixtures.candidate,
                replacementScanToken,
            )
        replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            replacementConnectionToken,
            replacementGeneration,
        )
        replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            replacementConnectionToken,
            replacementGeneration,
        )
        events += "replacement_session_ready"

        val recorded = diagnostics.snapshot()
        if (
            recorded.any {
                it.kind == BandDiagnosticKind.CAPABILITY &&
                    it.outcome == BandDiagnosticOutcome.CANCELLED
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.CAPABILITY &&
                    it.outcome == BandDiagnosticOutcome.TIMED_OUT &&
                    it.failureCategory == BandFailureCategory.TIMEOUT
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.CAPABILITY &&
                    it.outcome == BandDiagnosticOutcome.REJECTED &&
                    it.failureCategory == BandFailureCategory.AUTHENTICATION
            } &&
            recorded.any {
                it.kind == BandDiagnosticKind.CAPABILITY &&
                    it.outcome == BandDiagnosticOutcome.FAILED &&
                    it.failureCategory == BandFailureCategory.DISCONNECTED
            } &&
            recorded.count {
                it.kind == BandDiagnosticKind.CAPABILITY &&
                    it.outcome == BandDiagnosticOutcome.STALE &&
                    it.failureCategory == BandFailureCategory.STALE_CALLBACK
            } == 2
        ) {
            events += "capability_diagnostics_bounded"
        } else {
            events += "capability_diagnostics_incorrect"
        }

        return result(
            "capability_terminal_paths",
            events,
            replacement.snapshot(),
            failure = BandFailureCategory.SECURITY_FAILURE,
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

    private fun fractionalStepsRejected(): BandConformanceResult {
        val identity = BandSampleIdentity(
            stream = BandStreamKind.STEPS,
            sequence = 1,
            deviceTimeMilliseconds = 1,
        )
        listOf(0.0, 1.0, 1_000_000.0).forEach { value ->
            BandSample(
                identity = identity,
                value = value,
                unit = BandUnit.COUNT,
                quality = BandSampleQuality.ACCEPTED,
            ).validate()
        }

        var rejected = 0
        listOf(0.5, 1.5, 999_999.5).forEach { value ->
            try {
                BandSample(
                    identity = identity,
                    value = value,
                    unit = BandUnit.COUNT,
                    quality = BandSampleQuality.ACCEPTED,
                ).validate()
            } catch (error: BandException) {
                if (error.category == BandFailureCategory.INVALID_INPUT) {
                    rejected += 1
                } else {
                    throw error
                }
            }
        }
        return BandConformanceResult(
            scenario = "fractional_steps_rejected",
            events = listOf(
                "integer_steps_accepted",
                if (rejected == 3) {
                    "fractional_steps_rejected"
                } else {
                    "fractional_steps_accepted"
                },
            ),
            finalState = BandSessionState.IDLE.wireValue,
            acknowledgedCursor = null,
            acceptedSamples = 0,
            failure = if (rejected == 3) {
                BandFailureCategory.INVALID_INPUT.wireValue
            } else {
                BandFailureCategory.INTERNAL_FAILURE.wireValue
            },
        )
    }

    private fun gracefulDisconnectToIdle(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation) = readySession(diagnostics = diagnostics)
        session.beginLive()
        session.beginOperation(BandOperationClass.HISTORY)
        val events = mutableListOf("live_and_history_started")
        val beforeDisconnect = diagnostics.snapshot().size
        val idleGeneration = session.disconnect(
            BandDisconnectReason.COLLECTOR_HANDOFF,
            generation,
        )
        val disconnectEvents = diagnostics.snapshot().drop(beforeDisconnect)
        if (
            BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.CANCELLED,
                operationClass = BandOperationClass.HISTORY,
            ) in disconnectEvents
        ) {
            events += "history_cancelled"
        }
        if (
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.CANCELLED,
            ) in disconnectEvents
        ) {
            events += "live_cancelled"
        }
        if (
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCONNECT,
                BandDiagnosticOutcome.BEGAN,
                disconnectReason = BandDisconnectReason.COLLECTOR_HANDOFF,
            ) in disconnectEvents &&
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCONNECT,
                BandDiagnosticOutcome.COMPLETED,
                disconnectReason = BandDisconnectReason.COLLECTOR_HANDOFF,
            ) in disconnectEvents
        ) {
            events += "disconnect_completed"
        }

        var failure: BandFailureCategory? = null
        try {
            session.disconnect(
                BandDisconnectReason.USER_PAUSED,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "stale_callback_rejected"
        }

        val scanToken = session.beginScan()

        val scanGeneration = scanToken.generation
        session.cancelScan(scanToken)
        if (
            scanGeneration == idleGeneration + 1 &&
            session.snapshot().state == BandSessionState.IDLE
        ) {
            events += "session_reusable"
        }
        return result(
            "graceful_disconnect_to_idle",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun closeActivePhaseTerminal(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, _) = readySession(diagnostics = diagnostics)
        session.beginLive()
        session.beginOperation(BandOperationClass.HISTORY)
        val events = mutableListOf("live_and_history_started")
        val beforeClose = diagnostics.snapshot().size
        session.close()
        val closeEvents = diagnostics.snapshot().drop(beforeClose)
        if (closeEvents.any {
                it.kind == BandDiagnosticKind.HISTORY &&
                    it.outcome == BandDiagnosticOutcome.CANCELLED &&
                    it.operationClass == BandOperationClass.HISTORY
            }
        ) {
            events += "history_cancelled"
        }
        if (
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.CANCELLED,
            ) in closeEvents
        ) {
            events += "live_cancelled"
        }
        events += "session_closed"

        return result(
            "close_active_phase_terminal",
            events,
            session.snapshot(),
        )
    }

    private fun closedSessionTerminal(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val session = BandSessionMachine(diagnostics)
        session.close()
        val events = mutableListOf("session_closed")
        if (
            diagnostics.snapshot().none {
                it.kind == BandDiagnosticKind.CONNECTION &&
                    it.outcome == BandDiagnosticOutcome.CANCELLED
            }
        ) {
            events += "no_unmatched_connection_cancellation"
        }
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

    private fun liveOperationAllowed(): BandConformanceResult {
        val report = liveOperationCapabilities(
            setOf(BandOperationClass.BATTERY),
        )
        val (session, _) = readySession(report)
        val liveToken = session.beginLive()
        val events = mutableListOf("live_started")
        val operationToken = session.beginOperation(
            BandOperationClass.BATTERY,
            BandCapability.BATTERY,
        )
        events += "battery_allowed"
        session.completeOperation(operationToken)
        events += "operation_completed"
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "live_operation_allowed",
            events,
            session.snapshot(),
        )
    }

    private fun liveOperationDenied(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val report = liveOperationCapabilities(
            setOf(BandOperationClass.BATTERY),
        )
        val (session, _) = readySession(report, diagnostics)
        val liveToken = session.beginLive()
        val events = mutableListOf("live_started")
        var failure: BandFailureCategory? = null
        try {
            session.beginOperation(
                BandOperationClass.HAPTIC,
                BandCapability.HAPTICS,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "haptic_denied"
        }
        check(
            diagnostics.snapshot().last() == BandDiagnosticEvent(
                BandDiagnosticKind.COMMAND,
                BandDiagnosticOutcome.REJECTED,
                failureCategory = BandFailureCategory.BUSY,
                operationClass = BandOperationClass.HAPTIC,
            ),
        )
        events += "operation_class_recorded"
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "live_operation_denied",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun streamSemanticsMismatchRejected(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation) = readySession(diagnostics = diagnostics)
        val liveToken = session.beginLive()
        val events = mutableListOf("live_started")
        val mismatchedBatch = BandSampleBatch(
            sourceIdentity = VirtualBandFixtures.liveBatch.sourceIdentity,
            lane = BandProvenanceLane.LIVE,
            parserRevision = "parser-v2",
            calibrationRevision =
                VirtualBandFixtures.liveBatch.calibrationRevision,
            samples = VirtualBandFixtures.liveBatch.samples,
        )
        var failure: BandFailureCategory? = null
        try {
            session.stageLiveBatch(
                mismatchedBatch,
                liveToken,
                generation,
            )
        } catch (error: BandException) {
            failure = error.category
            events += "semantic_revision_rejected"
        }
        check(
            diagnostics.snapshot().none {
                it.kind == BandDiagnosticKind.LIVE &&
                    it.outcome == BandDiagnosticOutcome.STAGED
            },
        )
        events += "no_batch_staged"
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "stream_semantics_mismatch_rejected",
            events,
            session.snapshot(),
            failure = failure,
        )
    }

    private fun liveStagedBeforeDurable(): BandConformanceResult {
        val diagnostics = BandDiagnosticsRecorder()
        val (session, generation) = readySession(diagnostics = diagnostics)
        val store = VirtualBandStore()
        val liveToken = session.beginLive()
        val events = mutableListOf("live_started")
        val acceptance = session.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            liveToken,
            generation,
        )
        val stagedEvents = diagnostics.snapshot()
        check(
            stagedEvents.last() == BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.STAGED,
                BandCountBucket.ONE,
            ),
        )
        check(
            stagedEvents.none {
                it.kind == BandDiagnosticKind.LIVE &&
                    it.outcome == BandDiagnosticOutcome.COMPLETED
            },
        )
        events += "accepted_before_persistence"
        session.acknowledgeLive(store.commit(acceptance), generation)
        check(
            diagnostics.snapshot().last() == BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.ONE,
            ),
        )
        events += "durable_completion_recorded"
        val duplicateAcceptance = session.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            liveToken,
            generation,
        )
        check(duplicateAcceptance.acceptedSamples.isEmpty())
        check(
            diagnostics.snapshot().last() == BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.STAGED,
                BandCountBucket.ZERO,
            ),
        )
        check(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.ZERO,
            ) !in diagnostics.snapshot(),
        )
        events += "duplicate_zero_recorded"
        session.acknowledgeLive(
            store.commit(duplicateAcceptance),
            generation,
        )
        check(
            diagnostics.snapshot().last() == BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.ZERO,
            ),
        )
        session.stopLive(liveToken)
        events += "live_stopped"
        return result(
            "live_staged_before_durable",
            events,
            session.snapshot(),
            acceptedSamples = acceptance.acceptedSamples.size,
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
