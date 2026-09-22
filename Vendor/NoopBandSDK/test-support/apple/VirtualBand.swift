import Foundation

public actor VirtualBandStore {
    private var committed: Set<BandSampleIdentity> = []

    public init() {}

    public func commit(
        acceptance: LiveAcceptance
    ) -> DurableLiveReceipt {
        let identities = Set(acceptance.acceptedSamples.map(\.identity))
        committed.formUnion(identities)
        return DurableLiveReceipt(
            acceptance: acceptance,
            committedSamples: identities.count,
            committed: true
        )
    }

    public func commit(
        acceptance: HistoryAcceptance
    ) -> DurableHistoryReceipt {
        let identities = Set(
            acceptance.acceptedSamples.map(\.sample.identity)
        )
        committed.formUnion(identities)
        return DurableHistoryReceipt(
            acceptance: acceptance,
            historyStateCommitted: true,
            committedSamples: identities.count,
            committed: true
        )
    }
}

private extension BandSessionMachine {
    func completeConnectionForConformance(
        _ identity: BandIdentity,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try await beginConnection(
            token: token,
            callbackGeneration: callbackGeneration
        )
        try await beginAuthentication(
            token: token,
            callbackGeneration: callbackGeneration
        )
        try await completeConnection(
            identity,
            token: token,
            callbackGeneration: callbackGeneration
        )
    }

    func durablyCommitLiveBatch(
        _ batch: BandSampleBatch,
        token: BandLiveToken,
        callbackGeneration: UInt64
    ) async throws -> Int {
        let acceptance = try await stageLiveBatch(
            batch,
            token: token,
            callbackGeneration: callbackGeneration
        )
        let receipt = await VirtualBandStore().commit(
            acceptance: acceptance
        )
        try await acknowledgeLive(
            receipt: receipt,
            callbackGeneration: callbackGeneration
        )
        return acceptance.acceptedSamples.count
    }
}

public struct BandConformanceResult: Equatable, Codable, Sendable {
    public let scenario: String
    public let events: [String]
    public let finalState: String
    public let acknowledgedCursor: String?
    public let acceptedSamples: Int
    public let failure: String?

    public init(
        scenario: String,
        events: [String],
        finalState: String,
        acknowledgedCursor: String?,
        acceptedSamples: Int,
        failure: String?
    ) {
        self.scenario = scenario
        self.events = events
        self.finalState = finalState
        self.acknowledgedCursor = acknowledgedCursor
        self.acceptedSamples = acceptedSamples
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case scenario
        case events
        case finalState
        case acknowledgedCursor
        case acceptedSamples
        case failure
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(events, forKey: .events)
        try container.encode(finalState, forKey: .finalState)
        if let acknowledgedCursor {
            try container.encode(acknowledgedCursor, forKey: .acknowledgedCursor)
        } else {
            try container.encodeNil(forKey: .acknowledgedCursor)
        }
        try container.encode(acceptedSamples, forKey: .acceptedSamples)
        if let failure {
            try container.encode(failure, forKey: .failure)
        } else {
            try container.encodeNil(forKey: .failure)
        }
    }
}

public enum VirtualBandFixtures {
    public static let candidate = BandPairingCandidate(
        handle: "virtual-candidate",
        compatible: true,
        identifyEligible: true
    )

    public static let identity = BandIdentity(
        sourceIdentity: "virtual-source",
        hardwareRevision: "virtual-hw-1",
        firmwareVersion: "virtual-fw-1",
        protocolVersion: BandCapabilityReport.supportedProtocolVersion,
        wrapperRevision: "virtual-wrapper-1"
    )

    public static let capabilities = BandCapabilityReport(
        schemaVersion: BandCapabilityReport.supportedSchemaVersion,
        protocolVersion: BandCapabilityReport.supportedProtocolVersion,
        hardwareRevision: identity.hardwareRevision,
        firmwareVersion: identity.firmwareVersion,
        historyDays: 7,
        capabilities: [
            .battery,
            .charging,
            .wearState,
            .heartRate,
            .rrIntervals,
            .accelerometer,
            .haptics,
            .alarms,
        ],
        liveStreams: [
            .heartRate,
            .rrInterval,
            .acceleration,
        ],
        historyStreams: [
            .heartRate,
            .rrInterval,
        ]
    )

    public static let liveBatch = BandSampleBatch(
        sourceIdentity: identity.sourceIdentity,
        lane: .live,
        parserRevision: "parser-v1",
        calibrationRevision: "calibration-v1",
        samples: [
            BandSample(
                identity: BandSampleIdentity(
                    stream: .heartRate,
                    sequence: 1,
                    deviceTimeMilliseconds: 1_000
                ),
                value: 72,
                unit: .beatsPerMinute,
                quality: .accepted
            ),
        ]
    )

    public static let historyChunk = BandHistoryChunk(
        chunkIdentity: "chunk-1",
        previousCursor: nil,
        nextCursor: "cursor-2",
        complete: true,
        overflowed: false,
        retainedRange: BandHistoryRange(
            startDeviceTimeMilliseconds: 2_000,
            endDeviceTimeMilliseconds: 3_000
        ),
        firstLostRange: nil,
        acknowledgementToken: "ack-1",
        batches: [
            BandSampleBatch(
                sourceIdentity: identity.sourceIdentity,
                lane: .history,
                parserRevision: "parser-v1",
                calibrationRevision: "calibration-v1",
                samples: [
                    BandSample(
                        identity: BandSampleIdentity(
                            stream: .heartRate,
                            sequence: 2,
                            deviceTimeMilliseconds: 2_000
                        ),
                        value: 70,
                        unit: .beatsPerMinute,
                        quality: .accepted
                    ),
                    BandSample(
                        identity: BandSampleIdentity(
                            stream: .heartRate,
                            sequence: 3,
                            deviceTimeMilliseconds: 3_000
                        ),
                        value: 68,
                        unit: .beatsPerMinute,
                        quality: .accepted
                    ),
                ]
            ),
        ]
    )

    public static let duplicateLiveBatch = BandSampleBatch(
        sourceIdentity: identity.sourceIdentity,
        lane: .live,
        parserRevision: "parser-v1",
        calibrationRevision: "calibration-v1",
        samples: [
            liveBatch.samples[0],
            liveBatch.samples[0],
        ]
    )

    public static let mismatchedCursorChunk = BandHistoryChunk(
        chunkIdentity: "chunk-2",
        previousCursor: nil,
        nextCursor: "cursor-3",
        complete: true,
        overflowed: false,
        retainedRange: historyChunk.retainedRange,
        firstLostRange: nil,
        acknowledgementToken: "ack-2",
        batches: historyChunk.batches
    )
}

public enum BandConformanceRunner {
    public static let automatedScenarios = [
        "happy_path",
        "single_command_queue",
        "stale_callback_rejected",
        "cross_session_credentials_rejected",
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
        "close_active_phase_terminal",
        "closed_session_terminal",
    ]

    public static func run(_ scenario: String) async throws -> BandConformanceResult {
        switch scenario {
        case "happy_path":
            return try await happyPath()
        case "single_command_queue":
            return try await singleCommandQueue()
        case "stale_callback_rejected":
            return try await staleCallbackRejected()
        case "cross_session_credentials_rejected":
            return try await crossSessionCredentialsRejected()
        case "same_session_replay_rejected":
            return try await sameSessionReplayRejected()
        case "stale_terminal_callbacks_rejected":
            return try await staleTerminalCallbacksRejected()
        case "history_requires_durable_receipt":
            return try await historyRequiresDurableReceipt()
        case "live_does_not_advance_history":
            return try await liveDoesNotAdvanceHistory()
        case "live_batch_deduplicated":
            return try await liveBatchDeduplicated()
        case "history_cursor_chain_rejected":
            return try await historyCursorChainRejected()
        case "operation_capability_fail_closed":
            return try await operationCapabilityFailsClosed()
        case "oversized_metadata_rejected":
            return try await oversizedMetadataRejected()
        case "capability_unknown_fail_closed":
            return try await capabilityUnknownFailsClosed()
        case "history_interrupted_resume":
            return try await historyInterruptedResume()
        case "history_checkpoint_restored":
            return try await historyCheckpointRestored()
        case "firmware_eligibility_specific":
            return try await firmwareEligibilitySpecific()
        case "unnegotiated_stream_rejected":
            return try await unnegotiatedStreamRejected()
        case "firmware_blocked_during_live":
            return try await firmwareBlockedDuringLive()
        case "history_state_requires_durable_receipt":
            return try await historyStateRequiresDurableReceipt()
        case "stale_capability_callback_rejected":
            return try await staleCapabilityCallbackRejected()
        case "invalid_device_time_rejected":
            return try await invalidDeviceTimeRejected()
        case "history_operation_requires_own_receipt":
            return try await historyOperationRequiresOwnReceipt()
        case "firmware_diagnostics_specific":
            return try await firmwareDiagnosticsSpecific()
        case "firmware_terminal_failure":
            return try await firmwareTerminalFailure()
        case "history_nonadvancing_cursor_rejected":
            return try await historyNonadvancingCursorRejected()
        case "utf8_length_cross_platform":
            return try await utf8LengthCrossPlatform()
        case "sampling_requires_sensor_capability":
            return try await samplingRequiresSensorCapability()
        case "durable_identity_cache_bounded":
            return try await durableIdentityCacheBounded()
        case "operation_terminal_paths":
            return try await operationTerminalPaths()
        case "connection_callbacks_generation_fenced":
            return try await connectionCallbacksGenerationFenced()
        case "connection_terminal_paths":
            return try await connectionTerminalPaths()
        case "capability_terminal_paths":
            return try await capabilityTerminalPaths()
        case "history_pending_busy_diagnostics":
            return try await historyPendingBusyDiagnostics()
        case "fractional_steps_rejected":
            return try fractionalStepsRejected()
        case "diagnostics_bounded":
            return await diagnosticsBounded()
        case "live_callback_session_bound":
            return try await liveCallbackSessionBound()
        case "close_active_phase_terminal":
            return try await closeActivePhaseTerminal()
        case "closed_session_terminal":
            return try await closedSessionTerminal()
        default:
            throw BandFailureCategory.invalidInput
        }
    }

    private static func readySession(
        capabilities: BandCapabilityReport = VirtualBandFixtures.capabilities,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    )
        async throws -> (BandSessionMachine, UInt64)
    {
        let (session, generation, _) = try await readySessionWithToken(
            capabilities: capabilities,
            diagnostics: diagnostics
        )
        return (session, generation)
    }

    private static func readySessionWithToken(
        capabilities: BandCapabilityReport = VirtualBandFixtures.capabilities,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    )
        async throws -> (BandSessionMachine, UInt64, BandConnectionToken)
    {
        let session = BandSessionMachine(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        return (session, generation, connectionToken)
    }

    private static func happyPath() async throws -> BandConformanceResult {
        let session = BandSessionMachine()
        let store = VirtualBandStore()
        var events: [String] = []
        var accepted = 0

        let generation = try await session.beginScan()
        events.append("scan_started")
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        events.append("candidate_selected")
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        events.append("connected")
        try await session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        events.append("capabilities_accepted")
        let liveToken = try await session.beginLive()
        accepted += try await session.durablyCommitLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        events.append("live_committed")
        try await session.stopLive()

        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: token,
            callbackGeneration: generation
        )
        accepted += acceptance.acceptedSamples.count
        events.append("history_received")
        let receipt = await store.commit(acceptance: acceptance)
        events.append("history_committed")
        try await session.acknowledgeHistory(
            receipt: receipt,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_acknowledged")
        try await session.completeOperation(token)

        return result(
            scenario: "happy_path",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: accepted
        )
    }

    private static func singleCommandQueue() async throws -> BandConformanceResult {
        let (session, _) = try await readySession()
        var events = ["ready"]
        let token = try await session.beginOperation(
            .battery,
            requiredCapability: .battery
        )
        events.append("command_started")
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginOperation(
                .haptic,
                requiredCapability: .haptics
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("second_command_rejected")
        }
        try await session.completeOperation(token)
        events.append("command_completed")
        return result(
            scenario: "single_command_queue",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func staleCallbackRejected() async throws -> BandConformanceResult {
        let (session, oldGeneration, _) =
            try await readySessionWithToken()
        var events = ["ready"]
        let staleLiveToken = try await session.beginLive()
        let reconnectGeneration = try await session.interruptForReconnect(
            callbackGeneration: oldGeneration
        )
        try await session.resumeAfterReconnect(
            callbackGeneration: reconnectGeneration
        )
        events.append("generation_advanced")
        var failure: BandFailureCategory?
        do {
            _ = try await session.durablyCommitLiveBatch(
                VirtualBandFixtures.liveBatch,
                token: staleLiveToken,
                callbackGeneration: oldGeneration
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_callback_rejected")
        }
        return result(
            scenario: "stale_callback_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func crossSessionCredentialsRejected()
        async throws -> BandConformanceResult
    {
        let (first, firstGeneration) = try await readySession()
        let (second, secondGeneration) = try await readySession()
        let firstStore = VirtualBandStore()
        let secondStore = VirtualBandStore()
        var events = ["ready_pair"]
        var failure: BandFailureCategory?

        let firstLiveToken = try await first.beginLive()
        let secondLiveToken = try await second.beginLive()
        let firstLive = try await first.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: firstLiveToken,
            callbackGeneration: firstGeneration
        )
        let secondLive = try await second.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: secondLiveToken,
            callbackGeneration: secondGeneration
        )
        let foreignLiveReceipt = await firstStore.commit(
            acceptance: firstLive
        )
        do {
            try await second.acknowledgeLive(
                receipt: foreignLiveReceipt,
                callbackGeneration: secondGeneration
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("foreign_live_receipt_rejected")
        }
        try await first.acknowledgeLive(
            receipt: foreignLiveReceipt,
            callbackGeneration: firstGeneration
        )
        let ownLiveReceipt = await secondStore.commit(
            acceptance: secondLive
        )
        try await second.acknowledgeLive(
            receipt: ownLiveReceipt,
            callbackGeneration: secondGeneration
        )
        try await first.stopLive()
        try await second.stopLive()
        events.append("own_live_receipt_accepted")

        let firstToken = try await first.beginOperation(.history)
        let secondToken = try await second.beginOperation(.history)
        let firstHistory = try await first.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstToken,
            callbackGeneration: firstGeneration
        )
        let secondHistory = try await second.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: secondToken,
            callbackGeneration: secondGeneration
        )
        let foreignHistoryReceipt = await firstStore.commit(
            acceptance: firstHistory
        )
        do {
            try await second.acknowledgeHistory(
                receipt: foreignHistoryReceipt,
                token: secondToken,
                callbackGeneration: secondGeneration
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("foreign_history_receipt_rejected")
        }
        do {
            try await second.completeOperation(firstToken)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("foreign_operation_token_rejected")
        }
        let ownHistoryReceipt = await secondStore.commit(
            acceptance: secondHistory
        )
        try await second.acknowledgeHistory(
            receipt: ownHistoryReceipt,
            token: secondToken,
            callbackGeneration: secondGeneration
        )
        try await second.completeOperation(secondToken)
        events.append("own_history_completed")

        return result(
            scenario: "cross_session_credentials_rejected",
            events: events,
            snapshot: await second.snapshot(),
            acceptedSamples:
                secondLive.acceptedSamples.count
                    + secondHistory.acceptedSamples.count,
            failure: failure
        )
    }

    private static func staleTerminalCallbacksRejected()
        async throws -> BandConformanceResult
    {
        let scanSession = BandSessionMachine()
        let firstScan = try await scanSession.beginScan()
        try await scanSession.cancelScan(callbackGeneration: firstScan)
        let secondScan = try await scanSession.beginScan()
        var events = ["scan_restarted"]
        var failure: BandFailureCategory?
        do {
            try await scanSession.cancelScan(callbackGeneration: firstScan)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_scan_cancel_rejected")
        }
        do {
            try await scanSession.failScan(
                .timeout,
                callbackGeneration: firstScan
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_scan_failure_rejected")
        }
        guard await scanSession.snapshot().state == .scanning else {
            throw BandFailureCategory.internalFailure
        }
        try await scanSession.cancelScan(callbackGeneration: secondScan)

        let (session, generation) = try await readySession()
        events.append("ready")
        do {
            _ = try await session.interruptForReconnect(
                callbackGeneration: generation - 1
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_reconnect_interrupt_rejected")
        }
        let firstReconnect = try await session.interruptForReconnect(
            callbackGeneration: generation
        )
        events.append("reconnect_started")
        try await session.resumeAfterReconnect(
            callbackGeneration: firstReconnect
        )
        events.append("first_reconnect_completed")
        let secondReconnect = try await session.interruptForReconnect(
            callbackGeneration: firstReconnect
        )
        events.append("second_reconnect_started")
        do {
            try await session.resumeAfterReconnect(
                callbackGeneration: firstReconnect
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_reconnect_completion_rejected")
        }
        try await session.resumeAfterReconnect(
            callbackGeneration: secondReconnect
        )
        events.append("reconnected")
        return result(
            scenario: "stale_terminal_callbacks_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func sameSessionReplayRejected()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]
        var failure: BandFailureCategory?

        let liveToken = try await session.beginLive()
        let firstLive = try await session.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        let firstLiveReceipt = await store.commit(acceptance: firstLive)
        try await session.acknowledgeLive(
            receipt: firstLiveReceipt,
            callbackGeneration: generation
        )
        events.append("first_live_committed")
        let secondLiveBatch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [
                BandSample(
                    identity: BandSampleIdentity(
                        stream: .heartRate,
                        sequence: 100,
                        deviceTimeMilliseconds: 100_000
                    ),
                    value: 73,
                    unit: .beatsPerMinute,
                    quality: .accepted
                ),
            ]
        )
        let secondLive = try await session.stageLiveBatch(
            secondLiveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        do {
            try await session.acknowledgeLive(
                receipt: firstLiveReceipt,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_live_receipt_rejected")
        }
        try await session.acknowledgeLive(
            receipt: await store.commit(acceptance: secondLive),
            callbackGeneration: generation
        )
        try await session.stopLive()
        events.append("second_live_committed")

        let firstCommand = try await session.beginOperation(.battery)
        try await session.completeOperation(firstCommand)
        let secondCommand = try await session.beginOperation(.battery)
        do {
            try await session.completeOperation(firstCommand)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_operation_token_rejected")
        }
        try await session.completeOperation(secondCommand)

        let firstHistoryToken = try await session.beginOperation(.history)
        let firstHistory = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstHistoryToken,
            callbackGeneration: generation
        )
        let firstHistoryReceipt = await store.commit(
            acceptance: firstHistory
        )
        try await session.acknowledgeHistory(
            receipt: firstHistoryReceipt,
            token: firstHistoryToken,
            callbackGeneration: generation
        )
        try await session.completeOperation(firstHistoryToken)
        events.append("first_history_committed")

        let secondHistoryChunk = BandHistoryChunk(
            chunkIdentity: "chunk-replay-2",
            previousCursor: "cursor-2",
            nextCursor: "cursor-3",
            complete: true,
            overflowed: false,
            retainedRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 101_000,
                endDeviceTimeMilliseconds: 101_000
            ),
            firstLostRange: nil,
            acknowledgementToken: "ack-replay-2",
            batches: [
                BandSampleBatch(
                    sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
                    lane: .history,
                    parserRevision: "parser-v1",
                    calibrationRevision: "calibration-v1",
                    samples: [
                        BandSample(
                            identity: BandSampleIdentity(
                                stream: .heartRate,
                                sequence: 101,
                                deviceTimeMilliseconds: 101_000
                            ),
                            value: 71,
                            unit: .beatsPerMinute,
                            quality: .accepted
                        ),
                    ]
                ),
            ]
        )
        let secondHistoryToken = try await session.beginOperation(.history)
        let secondHistory = try await session.stageHistoryChunk(
            secondHistoryChunk,
            token: secondHistoryToken,
            callbackGeneration: generation
        )
        do {
            try await session.acknowledgeHistory(
                receipt: firstHistoryReceipt,
                token: secondHistoryToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_history_receipt_rejected")
        }
        let secondHistoryReceipt = await store.commit(
            acceptance: secondHistory
        )
        try await session.acknowledgeHistory(
            receipt: secondHistoryReceipt,
            token: secondHistoryToken,
            callbackGeneration: generation
        )
        try await session.completeOperation(secondHistoryToken)
        events.append("second_history_committed")

        return result(
            scenario: "same_session_replay_rejected",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples:
                firstLive.acceptedSamples.count
                    + secondLive.acceptedSamples.count
                    + firstHistory.acceptedSamples.count
                    + secondHistory.acceptedSamples.count,
            failure: failure
        )
    }

    private static func historyRequiresDurableReceipt()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_received")
        let rejectedReceipt = DurableHistoryReceipt(
            acceptance: acceptance,
            historyStateCommitted: false,
            committedSamples: 0,
            committed: false
        )
        var failure: BandFailureCategory?
        do {
            try await session.acknowledgeHistory(
                receipt: rejectedReceipt,
                token: token,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("ack_rejected")
        }
        let retryAcceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: token,
            callbackGeneration: generation
        )
        let receipt = await store.commit(acceptance: retryAcceptance)
        events.append("history_committed")
        try await session.acknowledgeHistory(
            receipt: receipt,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_acknowledged")
        try await session.completeOperation(token)
        return result(
            scenario: "history_requires_durable_receipt",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: retryAcceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func liveDoesNotAdvanceHistory() async throws -> BandConformanceResult {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let before = await session.snapshot().acknowledgedHistoryCursor
        let liveToken = try await session.beginLive()
        let accepted = try await session.durablyCommitLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        events.append("live_committed")
        let after = await session.snapshot().acknowledgedHistoryCursor
        guard before == after else {
            throw BandFailureCategory.internalFailure
        }
        events.append("cursor_unchanged")
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "live_does_not_advance_history",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: accepted
        )
    }

    private static func liveBatchDeduplicated() async throws -> BandConformanceResult {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let liveToken = try await session.beginLive()
        let accepted = try await session.durablyCommitLiveBatch(
            VirtualBandFixtures.duplicateLiveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        events.append("live_committed")
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "live_batch_deduplicated",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: accepted
        )
    }

    private static func historyCursorChainRejected()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]

        let firstToken = try await session.beginOperation(.history)
        let firstAcceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstToken,
            callbackGeneration: generation
        )
        let firstReceipt = await store.commit(acceptance: firstAcceptance)
        try await session.acknowledgeHistory(
            receipt: firstReceipt,
            token: firstToken,
            callbackGeneration: generation
        )
        try await session.completeOperation(firstToken)
        events.append("first_history_committed")

        let secondToken = try await session.beginOperation(.history)
        var failure: BandFailureCategory?
        do {
            _ = try await session.stageHistoryChunk(
                VirtualBandFixtures.mismatchedCursorChunk,
                token: secondToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("cursor_chain_rejected")
        }
        try await session.cancelOperation(secondToken)
        events.append("operation_cancelled")

        return result(
            scenario: "history_cursor_chain_rejected",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: firstAcceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func operationCapabilityFailsClosed()
        async throws -> BandConformanceResult
    {
        let session = BandSessionMachine()
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.battery, .heartRate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        try await session.acceptCapabilities(
            report,
            token: connectionToken,
            callbackGeneration: generation
        )
        var events = ["ready"]
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginOperation(.haptic)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("unsupported_operation_rejected")
        }
        return result(
            scenario: "operation_capability_fail_closed",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func oversizedMetadataRejected()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let batch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: String(
                repeating: "x",
                count: BandContractLimits.revisionLength + 1
            ),
            calibrationRevision: "calibration-v1",
            samples: VirtualBandFixtures.liveBatch.samples
        )
        let liveToken = try await session.beginLive()
        var failure: BandFailureCategory?
        do {
            _ = try await session.durablyCommitLiveBatch(
                batch,
                token: liveToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("oversized_metadata_rejected")
        }
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "oversized_metadata_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func capabilityUnknownFailsClosed()
        async throws -> BandConformanceResult
    {
        let session = BandSessionMachine()
        var events: [String] = []
        let generation = try await session.beginScan()
        events.append("scan_started")
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        events.append("candidate_selected")
        let identity = BandIdentity(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            protocolVersion: "noop-band-v2",
            wrapperRevision: VirtualBandFixtures.identity.wrapperRevision
        )
        try await session.completeConnectionForConformance(
            identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        events.append("connected")
        let report = BandCapabilityReport(
            schemaVersion: 2,
            protocolVersion: "noop-band-v2",
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        var failure: BandFailureCategory?
        do {
            try await session.acceptCapabilities(
                report,
                token: connectionToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("capability_rejected")
        }
        return result(
            scenario: "capability_unknown_fail_closed",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func historyInterruptedResume() async throws -> BandConformanceResult {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]
        var failure: BandFailureCategory?

        let firstToken = try await session.beginOperation(.history)
        let firstAcceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstToken,
            callbackGeneration: generation
        )
        events.append("history_received")
        do {
            _ = try await session.interruptForReconnect(
                callbackGeneration: generation
            )
        } catch BandFailureCategory.busy {
            events.append("persistence_drain_required")
        }
        do {
            try await session.acknowledgeHistory(
                receipt: DurableHistoryReceipt(
                    acceptance: firstAcceptance,
                    historyStateCommitted: false,
                    committedSamples: 0,
                    committed: false
                ),
                token: firstToken,
                callbackGeneration: generation
            )
        } catch BandFailureCategory.storage {
            events.append("persistence_failed")
        }
        let resumedGeneration = try await session.interruptForReconnect(
            callbackGeneration: generation
        )
        failure = .disconnected
        events.append("history_interrupted")
        try await session.resumeAfterReconnect(
            callbackGeneration: resumedGeneration
        )
        events.append("reconnected")
        let secondToken = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: secondToken,
            callbackGeneration: resumedGeneration
        )
        events.append("history_resumed")
        let receipt = await store.commit(acceptance: acceptance)
        events.append("history_committed")
        try await session.acknowledgeHistory(
            receipt: receipt,
            token: secondToken,
            callbackGeneration: resumedGeneration
        )
        events.append("history_acknowledged")
        try await session.completeOperation(secondToken)
        return result(
            scenario: "history_interrupted_resume",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: acceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func historyCheckpointRestored()
        async throws -> BandConformanceResult
    {
        let checkpoint = BandHistoryCheckpoint(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            acknowledgedCursor: "cursor-2",
            lastHistoryComplete: false,
            durableSampleIdentities: Set(
                VirtualBandFixtures.historyChunk.batches
                    .flatMap(\.samples)
                    .map(\.identity)
            )
        )
        let session = BandSessionMachine(historyCheckpoint: checkpoint)
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        var events = ["ready"]
        guard await session.snapshot().acknowledgedHistoryCursor == "cursor-2" else {
            throw BandFailureCategory.internalFailure
        }
        events.append("checkpoint_restored")
        let token = try await session.beginOperation(.history)
        do {
            try await session.completeOperation(token)
        } catch BandFailureCategory.storage {
            events.append("range_resume_required")
        }

        let duplicate = VirtualBandFixtures.historyChunk.batches[0].samples[1]
        let newSample = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: 4,
                deviceTimeMilliseconds: 4_000
            ),
            value: 67,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        let chunk = BandHistoryChunk(
            chunkIdentity: "chunk-2",
            previousCursor: "cursor-2",
            nextCursor: "cursor-3",
            complete: true,
            overflowed: false,
            retainedRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 2_000,
                endDeviceTimeMilliseconds: 4_000
            ),
            firstLostRange: nil,
            acknowledgementToken: "ack-2",
            batches: [
                BandSampleBatch(
                    sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
                    lane: .history,
                    parserRevision: "parser-v1",
                    calibrationRevision: "calibration-v1",
                    samples: [duplicate, newSample]
                ),
            ]
        )
        let acceptance = try await session.stageHistoryChunk(
            chunk,
            token: token,
            callbackGeneration: generation
        )
        let receipt = await VirtualBandStore().commit(
            acceptance: acceptance
        )
        events.append("history_committed")
        try await session.acknowledgeHistory(
            receipt: receipt,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_acknowledged")
        try await session.completeOperation(token)
        return result(
            scenario: "history_checkpoint_restored",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: acceptance.acceptedSamples.count
        )
    }

    private static func firmwareEligibilitySpecific()
        async throws -> BandConformanceResult
    {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        let (session, _) = try await readySession(capabilities: report)
        var events = ["ready"]
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginOperation(.firmware)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("firmware_rejected")
        }
        return result(
            scenario: "firmware_eligibility_specific",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func unnegotiatedStreamRejected()
        async throws -> BandConformanceResult
    {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        let (session, generation) = try await readySession(capabilities: report)
        var events = ["ready"]
        let sample = BandSample(
            identity: BandSampleIdentity(
                stream: .spo2,
                sequence: 4,
                deviceTimeMilliseconds: 4_000
            ),
            value: 98,
            unit: .percent,
            quality: .accepted
        )
        let batch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [sample]
        )
        let liveToken = try await session.beginLive()
        var failure: BandFailureCategory?
        do {
            _ = try await session.durablyCommitLiveBatch(
                batch,
                token: liveToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("live_stream_rejected")
        }
        try await session.stopLive()
        events.append("live_stopped")
        let historyToken = try await session.beginOperation(.history)
        let historyChunk = BandHistoryChunk(
            chunkIdentity: "chunk-unnegotiated",
            previousCursor: nil,
            nextCursor: "cursor-unnegotiated",
            complete: true,
            overflowed: false,
            retainedRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 4_000,
                endDeviceTimeMilliseconds: 4_000
            ),
            firstLostRange: nil,
            acknowledgementToken: "ack-unnegotiated",
            batches: [
                BandSampleBatch(
                    sourceIdentity: batch.sourceIdentity,
                    lane: .history,
                    parserRevision: batch.parserRevision,
                    calibrationRevision: batch.calibrationRevision,
                    samples: batch.samples
                ),
            ]
        )
        do {
            _ = try await session.stageHistoryChunk(
                historyChunk,
                token: historyToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("history_stream_rejected")
        }
        try await session.cancelOperation(historyToken)
        events.append("operation_cancelled")
        return result(
            scenario: "unnegotiated_stream_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func firmwareBlockedDuringLive()
        async throws -> BandConformanceResult
    {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .firmwareUpdate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        let (session, _) = try await readySession(capabilities: report)
        var events = ["ready"]
        _ = try await session.beginLive()
        events.append("live_started")
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginOperation(.firmware)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("firmware_rejected")
        }
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "firmware_blocked_during_live",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func historyStateRequiresDurableReceipt()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]
        var failure: BandFailureCategory?
        let firstSample = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: 4,
                deviceTimeMilliseconds: 4_000
            ),
            value: 67,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        let firstChunk = BandHistoryChunk(
            chunkIdentity: "chunk-incomplete",
            previousCursor: nil,
            nextCursor: "cursor-2",
            complete: false,
            overflowed: true,
            retainedRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 4_000,
                endDeviceTimeMilliseconds: 4_000
            ),
            firstLostRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 1_000,
                endDeviceTimeMilliseconds: 3_999
            ),
            acknowledgementToken: "ack-incomplete",
            batches: [
                BandSampleBatch(
                    sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
                    lane: .history,
                    parserRevision: "parser-v1",
                    calibrationRevision: "calibration-v1",
                    samples: [firstSample]
                ),
            ]
        )
        let token = try await session.beginOperation(.history)
        var firstAcceptance = try await session.stageHistoryChunk(
            firstChunk,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_received")
        do {
            try await session.acknowledgeHistory(
                receipt: DurableHistoryReceipt(
                    acceptance: firstAcceptance,
                    historyStateCommitted: false,
                    committedSamples: firstAcceptance.acceptedSamples.count,
                    committed: true
                ),
                token: token,
                callbackGeneration: generation
            )
        } catch {
            events.append("receipt_rejected")
        }
        firstAcceptance = try await session.stageHistoryChunk(
            firstChunk,
            token: token,
            callbackGeneration: generation
        )
        let firstReceipt = await store.commit(
            acceptance: firstAcceptance
        )
        try await session.acknowledgeHistory(
            receipt: firstReceipt,
            token: token,
            callbackGeneration: generation
        )
        events.append("history_committed")
        do {
            try await session.completeOperation(token)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("range_incomplete")
        }

        let terminalSample = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: 5,
                deviceTimeMilliseconds: 5_000
            ),
            value: 66,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        let terminalChunk = BandHistoryChunk(
            chunkIdentity: "chunk-terminal",
            previousCursor: "cursor-2",
            nextCursor: "cursor-3",
            complete: true,
            overflowed: false,
            retainedRange: BandHistoryRange(
                startDeviceTimeMilliseconds: 5_000,
                endDeviceTimeMilliseconds: 5_000
            ),
            firstLostRange: nil,
            acknowledgementToken: "ack-terminal",
            batches: [
                BandSampleBatch(
                    sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
                    lane: .history,
                    parserRevision: "parser-v1",
                    calibrationRevision: "calibration-v1",
                    samples: [terminalSample]
                ),
            ]
        )
        let terminalAcceptance = try await session.stageHistoryChunk(
            terminalChunk,
            token: token,
            callbackGeneration: generation
        )
        events.append("terminal_received")
        let terminalReceipt = await store.commit(
            acceptance: terminalAcceptance
        )
        try await session.acknowledgeHistory(
            receipt: terminalReceipt,
            token: token,
            callbackGeneration: generation
        )
        events.append("terminal_committed")
        do {
            _ = try await session.stageHistoryChunk(
                terminalChunk,
                token: token,
                callbackGeneration: generation
            )
        } catch BandFailureCategory.invalidState {
            events.append("post_terminal_chunk_rejected")
        }
        try await session.completeOperation(token)
        events.append("operation_completed")
        return result(
            scenario: "history_state_requires_durable_receipt",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples:
                firstAcceptance.acceptedSamples.count
                    + terminalAcceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func staleCapabilityCallbackRejected()
        async throws -> BandConformanceResult
    {
        let (session, oldGeneration, oldConnectionToken) =
            try await readySessionWithToken()
        var events = ["ready"]
        let reconnectGeneration = try await session.interruptForReconnect(
            callbackGeneration: oldGeneration
        )
        try await session.resumeAfterReconnect(
            callbackGeneration: reconnectGeneration
        )
        events.append("generation_advanced")
        var failure: BandFailureCategory?
        do {
            try await session.acceptCapabilities(
                VirtualBandFixtures.capabilities,
                token: oldConnectionToken,
                callbackGeneration: oldGeneration
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_capability_rejected")
        }
        guard await session.snapshot().state == .ready else {
            throw BandFailureCategory.internalFailure
        }
        return result(
            scenario: "stale_capability_callback_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func invalidDeviceTimeRejected()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let invalidSample = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: 10,
                deviceTimeMilliseconds: -1
            ),
            value: 72,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        let batch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [invalidSample]
        )
        let liveToken = try await session.beginLive()
        var failure: BandFailureCategory?
        do {
            _ = try await session.durablyCommitLiveBatch(
                batch,
                token: liveToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("invalid_device_time_rejected")
        }
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "invalid_device_time_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func historyOperationRequiresOwnReceipt()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        let store = VirtualBandStore()
        var events = ["ready"]
        let firstToken = try await session.beginOperation(.history)
        let firstAcceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstToken,
            callbackGeneration: generation
        )
        let firstReceipt = await store.commit(
            acceptance: firstAcceptance
        )
        try await session.acknowledgeHistory(
            receipt: firstReceipt,
            token: firstToken,
            callbackGeneration: generation
        )
        try await session.completeOperation(firstToken)
        events.append("first_history_completed")

        let secondToken = try await session.beginOperation(.history)
        var failure: BandFailureCategory?
        do {
            try await session.completeOperation(secondToken)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("own_receipt_required")
        }
        try await session.cancelOperation(secondToken)
        events.append("operation_cancelled")
        return result(
            scenario: "history_operation_requires_own_receipt",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: firstAcceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func firmwareDiagnosticsSpecific()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        do {
            _ = try await session.beginOperation(.firmware)
        } catch BandFailureCategory.invalidState {
            // The diagnostic assertion below verifies this rejection family.
        }
        let initialConnectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: initialConnectionToken,
            callbackGeneration: generation
        )
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .firmwareUpdate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        try await session.acceptCapabilities(
            report,
            token: initialConnectionToken,
            callbackGeneration: generation
        )
        var events = ["ready"]
        let token = try await session.beginOperation(.firmware)
        try await session.completeOperation(token)
        let postFirmwareGeneration = try await session.beginScan()
        let postFirmwareConnectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: postFirmwareGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: postFirmwareConnectionToken,
            callbackGeneration: postFirmwareGeneration
        )
        try await session.acceptCapabilities(
            report,
            token: postFirmwareConnectionToken,
            callbackGeneration: postFirmwareGeneration
        )
        _ = try await session.beginLive()
        do {
            _ = try await session.beginOperation(.firmware)
        } catch BandFailureCategory.busy {
            // The diagnostic assertion below verifies the rejection family.
        }
        try await session.stopLive()
        let staleToken = try await session.beginOperation(.firmware)
        _ = try await session.interruptForReconnect(
            callbackGeneration: postFirmwareGeneration
        )
        let recoveryGeneration = try await session.beginScan()
        let recoveryConnectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: recoveryGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: recoveryConnectionToken,
            callbackGeneration: recoveryGeneration
        )
        try await session.acceptCapabilities(
            report,
            token: recoveryConnectionToken,
            callbackGeneration: recoveryGeneration
        )
        do {
            try await session.completeOperation(staleToken)
        } catch BandFailureCategory.staleCallback {
            // The diagnostic assertion below verifies this rejection family.
        }
        let firmwareEvents = await diagnostics.snapshot().filter {
            $0.kind == .firmware
        }
        let firmwareEvidence = firmwareEvents.map {
            "\($0.outcome.rawValue):"
                + ($0.failureCategory?.rawValue ?? "none")
        }
        if firmwareEvidence == [
            "rejected:invalidState",
            "began:none",
            "completed:none",
            "rejected:busy",
            "began:none",
            "interrupted:disconnected",
            "rejected:staleCallback",
        ]
        {
            events.append("firmware_diagnostics_specific")
        } else {
            events.append("firmware_diagnostics_incorrect")
        }
        return result(
            scenario: "firmware_diagnostics_specific",
            events: events,
            snapshot: await session.snapshot()
        )
    }

    private static func firmwareTerminalFailure()
        async throws -> BandConformanceResult
    {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 0,
            capabilities: [.heartRate, .firmwareUpdate],
            liveStreams: [.heartRate],
            historyStreams: []
        )
        let diagnostics = BandDiagnosticsRecorder()
        let (session, _) = try await readySession(
            capabilities: report,
            diagnostics: diagnostics
        )
        var events = ["ready"]
        let token = try await session.beginOperation(.firmware)
        events.append("firmware_started")
        try await session.failOperation(
            token,
            category: .updateVerification,
            firmwareDisposition: .terminal
        )
        events.append("firmware_terminal")
        let terminalGeneration = await session.snapshot().generation

        do {
            _ = try await session.interruptForReconnect(
                callbackGeneration: terminalGeneration
            )
        } catch BandFailureCategory.invalidState {
            events.append("reconnect_rejected")
        }

        if await diagnostics.snapshot().last == BandDiagnosticEvent(
            kind: .firmware,
            outcome: .terminal,
            failureCategory: .updateVerification
        ) {
            events.append("terminal_diagnostic_recorded")
        }

        var failure: BandFailureCategory?
        do {
            _ = try await session.beginScan()
        } catch let error as BandFailureCategory {
            failure = error
            events.append("same_session_restart_rejected")
        }

        let replacement = BandSessionMachine()
        _ = try await replacement.beginScan()
        events.append("replacement_scan_started")
        return result(
            scenario: "firmware_terminal_failure",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func historyNonadvancingCursorRejected()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let token = try await session.beginOperation(.history)
        let chunk = BandHistoryChunk(
            chunkIdentity: "chunk-stalled",
            previousCursor: nil,
            nextCursor: nil,
            complete: false,
            overflowed: false,
            retainedRange: nil,
            firstLostRange: nil,
            acknowledgementToken: "ack-stalled",
            batches: []
        )
        var failure: BandFailureCategory?
        do {
            _ = try await session.stageHistoryChunk(
                chunk,
                token: token,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("nonadvancing_cursor_rejected")
        }
        try await session.cancelOperation(token)
        events.append("operation_cancelled")
        return result(
            scenario: "history_nonadvancing_cursor_rejected",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func utf8LengthCrossPlatform()
        async throws -> BandConformanceResult
    {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let batch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: String(repeating: "é", count: 33),
            calibrationRevision: "calibration-v1",
            samples: VirtualBandFixtures.liveBatch.samples
        )
        let liveToken = try await session.beginLive()
        var failure: BandFailureCategory?
        do {
            _ = try await session.durablyCommitLiveBatch(
                batch,
                token: liveToken,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("utf8_limit_rejected")
        }
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "utf8_length_cross_platform",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func samplingRequiresSensorCapability()
        async throws -> BandConformanceResult
    {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.battery],
            liveStreams: [],
            historyStreams: []
        )
        let (session, _) = try await readySession(capabilities: report)
        var events = ["ready"]
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginOperation(.sampling)
        } catch let error as BandFailureCategory {
            failure = error
            events.append("sampling_rejected")
        }
        return result(
            scenario: "sampling_requires_sensor_capability",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func durableIdentityCacheBounded()
        async throws -> BandConformanceResult
    {
        let samePositionStreams: [BandStreamKind] = [
            .heartRate,
            .rrInterval,
            .steps,
            .spo2,
            .respiration,
            .temperature,
            .acceleration,
        ]
        var identities = Set(
            samePositionStreams.map {
                BandSampleIdentity(
                    stream: $0,
                    sequence: 0,
                    deviceTimeMilliseconds: 0
                )
            }
        )
        let remaining =
            BandContractLimits.historyCheckpointIdentities
                - samePositionStreams.count
        for index in 1 ... remaining {
            identities.insert(
                BandSampleIdentity(
                    stream: .heartRate,
                    sequence: UInt64(index),
                    deviceTimeMilliseconds: Int64(index)
                )
            )
        }
        let checkpoint = BandHistoryCheckpoint(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            acknowledgedCursor: nil,
            lastHistoryComplete: nil,
            durableSampleIdentities: identities
        )
        let session = BandSessionMachine(historyCheckpoint: checkpoint)
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        let capabilities = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities:
                VirtualBandFixtures.capabilities.capabilities
                    .union([.accelerometer]),
            liveStreams:
                VirtualBandFixtures.capabilities.liveStreams
                    .union([.acceleration]),
            historyStreams:
                VirtualBandFixtures.capabilities.historyStreams
        )
        try await session.acceptCapabilities(
            capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        var events = ["ready"]
        let next = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: UInt64(BandContractLimits.historyCheckpointIdentities),
                deviceTimeMilliseconds:
                    Int64(BandContractLimits.historyCheckpointIdentities)
            ),
            value: 72,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        let batch = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [next]
        )
        let liveToken = try await session.beginLive()
        let accepted = try await session.durablyCommitLiveBatch(
            batch,
            token: liveToken,
            callbackGeneration: generation
        )
        let evictedCandidate = BandSample(
            identity: BandSampleIdentity(
                stream: .acceleration,
                sequence: 0,
                deviceTimeMilliseconds: 0
            ),
            value: 0,
            unit: .gravity,
            quality: .accepted
        )
        let evictionProbe = BandSampleBatch(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [evictedCandidate]
        )
        let evictionAccepted = try await session.durablyCommitLiveBatch(
            evictionProbe,
            token: liveToken,
            callbackGeneration: generation
        )
        if accepted == 1,
           evictionAccepted == 1,
           await session.snapshot().durableSampleCount
             == BandContractLimits.historyCheckpointIdentities
        {
            events.append("identity_cache_bounded")
        } else {
            events.append("identity_cache_unbounded")
        }
        try await session.stopLive()
        events.append("live_stopped")
        return result(
            scenario: "durable_identity_cache_bounded",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: accepted + evictionAccepted
        )
    }

    private static func operationTerminalPaths()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        var events = ["ready"]
        let cancelled = try await session.beginOperation(.battery)
        try await session.cancelOperation(cancelled)
        events.append("operation_cancelled")
        let failed = try await session.beginOperation(.haptic)
        try await session.failOperation(failed, category: .timeout)
        let lastEvent = await diagnostics.snapshot().last
        if lastEvent?.kind == .command,
           lastEvent?.outcome == .failed,
           lastEvent?.failureCategory == .timeout
        {
            events.append("operation_failed")
        } else {
            events.append("operation_failure_incorrect")
        }
        let liveToken = try await session.beginLive()
        let disconnected = try await session.beginOperation(.battery)
        try await session.failOperation(disconnected, category: .disconnected)
        let recovering = await session.snapshot()
        if recovering.state == .recovering,
           recovering.generation == generation + 1,
           !recovering.liveActive
        {
            events.append("disconnect_recovery")
        } else {
            events.append("disconnect_recovery_incorrect")
        }
        do {
            _ = try await session.durablyCommitLiveBatch(
                VirtualBandFixtures.liveBatch,
                token: liveToken,
                callbackGeneration: generation
            )
        } catch BandFailureCategory.staleCallback {
            events.append("stale_callback_rejected")
        }
        try await session.resumeAfterReconnect(
            callbackGeneration: recovering.generation
        )
        events.append("reconnected")
        let securityGeneration = await session.snapshot().generation
        let securityFailed = try await session.beginOperation(.battery)
        try await session.failOperation(
            securityFailed,
            category: .securityFailure
        )
        let securityTerminal = await session.snapshot()
        if securityTerminal.state == .securityFailure,
           securityTerminal.generation == securityGeneration + 1,
           securityTerminal.activeOperation == nil,
           !securityTerminal.liveActive
        {
            events.append("security_failure_terminal")
        } else {
            events.append("security_failure_not_terminal")
        }
        do {
            try await session.failOperation(
                securityFailed,
                category: .timeout
            )
        } catch BandFailureCategory.staleCallback {
            events.append("security_failure_stale_token_rejected")
        }
        do {
            _ = try await session.beginScan()
            events.append("security_failure_restart_incorrect")
        } catch BandFailureCategory.invalidState {
            events.append("security_failure_restart_rejected")
        }
        let replacement = BandSessionMachine(diagnostics: diagnostics)
        let replacementGeneration = try await replacement.beginScan()
        let replacementConnectionToken = try await replacement.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: replacementGeneration
        )
        try await replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        try await replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        events.append("replacement_session_ready")
        return result(
            scenario: "operation_terminal_paths",
            events: events,
            snapshot: await replacement.snapshot()
        )
    }

    private static func connectionCallbacksGenerationFenced()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        var events: [String] = []
        var failure: BandFailureCategory?

        let oldGeneration = try await session.beginScan()
        let oldConnectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: oldGeneration
        )
        try await session.beginConnection(
            token: oldConnectionToken,
            callbackGeneration: oldGeneration
        )
        events.append("connection_started")
        try await session.failConnection(
            .timeout,
            token: oldConnectionToken,
            phase: .connection,
            callbackGeneration: oldGeneration
        )
        if await session.snapshot().state == .recovering {
            events.append("connection_failed")
        } else {
            events.append("connection_failure_incorrect")
        }

        let currentGeneration = try await session.beginScan()
        let currentConnectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: currentGeneration
        )
        try await session.beginConnection(
            token: currentConnectionToken,
            callbackGeneration: currentGeneration
        )
        try await session.beginAuthentication(
            token: currentConnectionToken,
            callbackGeneration: currentGeneration
        )
        do {
            try await session.cancelConnection(
                token: oldConnectionToken,
                phase: .connection,
                callbackGeneration: oldGeneration
            )
        } catch BandFailureCategory.staleCallback {
            events.append("stale_cancel_rejected")
        }
        do {
            try await session.failConnection(
                .timeout,
                token: oldConnectionToken,
                phase: .connection,
                callbackGeneration: oldGeneration
            )
        } catch BandFailureCategory.staleCallback {
            events.append("stale_failure_rejected")
        }
        let beforeCompletion = await session.snapshot()
        if beforeCompletion.state == .authenticating,
           beforeCompletion.generation == currentGeneration
        {
            events.append("stale_terminals_preserved_state")
        } else {
            events.append("stale_terminals_mutated_state")
        }
        do {
            try await session.completeConnection(
                VirtualBandFixtures.identity,
                token: oldConnectionToken,
                callbackGeneration: oldGeneration
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("stale_connection_rejected")
        }
        try await session.completeConnection(
            VirtualBandFixtures.identity,
            token: currentConnectionToken,
            callbackGeneration: currentGeneration
        )
        events.append("connected")
        try await session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: currentConnectionToken,
            callbackGeneration: currentGeneration
        )
        events.append("capabilities_accepted")

        let recorded = await diagnostics.snapshot()
        let connectionStaleCount = recorded.filter {
            $0.kind == .connection
                && $0.outcome == .stale
                && $0.failureCategory == .staleCallback
        }.count
        let authenticationStaleCount = recorded.filter {
            $0.kind == .authentication
                && $0.outcome == .stale
                && $0.failureCategory == .staleCallback
        }.count
        if connectionStaleCount == 2, authenticationStaleCount == 1 {
            events.append("stale_phases_preserved")
        } else {
            events.append("stale_phases_incorrect")
        }
        if recorded.contains(where: {
            $0.kind == .connection
                && $0.outcome == .timedOut
                && $0.failureCategory == .timeout
        }), recorded.contains(where: {
            $0.kind == .authentication
                && $0.outcome == .stale
                && $0.failureCategory == .staleCallback
        }), recorded.contains(where: {
            $0.kind == .authentication
                && $0.outcome == .began
        }) {
            events.append("connection_diagnostics_bounded")
        } else {
            events.append("connection_diagnostics_incorrect")
        }
        return result(
            scenario: "connection_callbacks_generation_fenced",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func connectionTerminalPaths()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        var events: [String] = []

        let cancellationGeneration = try await session.beginScan()
        let cancellationToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: cancellationGeneration
        )
        try await session.beginConnection(
            token: cancellationToken,
            callbackGeneration: cancellationGeneration
        )
        try await session.cancelConnection(
            token: cancellationToken,
            phase: .connection,
            callbackGeneration: cancellationGeneration
        )
        if await session.snapshot().state == .idle {
            events.append("connection_cancelled")
        } else {
            events.append("connection_cancellation_incorrect")
        }

        let authenticationGeneration = try await session.beginScan()
        let authenticationToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: authenticationGeneration
        )
        try await session.beginConnection(
            token: authenticationToken,
            callbackGeneration: authenticationGeneration
        )
        try await session.beginAuthentication(
            token: authenticationToken,
            callbackGeneration: authenticationGeneration
        )
        try await session.failConnection(
            .authentication,
            token: authenticationToken,
            phase: .authentication,
            callbackGeneration: authenticationGeneration
        )
        if await session.snapshot().state == .rejected {
            events.append("authentication_rejected")
        } else {
            events.append("authentication_state_incorrect")
        }

        let securityGeneration = try await session.beginScan()
        let securityToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: securityGeneration
        )
        try await session.beginConnection(
            token: securityToken,
            callbackGeneration: securityGeneration
        )
        try await session.beginAuthentication(
            token: securityToken,
            callbackGeneration: securityGeneration
        )
        try await session.failConnection(
            .securityFailure,
            token: securityToken,
            phase: .authentication,
            callbackGeneration: securityGeneration
        )
        if await session.snapshot().state == .securityFailure {
            events.append("security_failure")
        } else {
            events.append("security_state_incorrect")
        }

        do {
            _ = try await session.beginScan()
            events.append("security_failure_restart_incorrect")
        } catch BandFailureCategory.invalidState {
            events.append("security_failure_restart_rejected")
        }
        let replacement = BandSessionMachine(diagnostics: diagnostics)
        let replacementGeneration = try await replacement.beginScan()
        let replacementConnectionToken = try await replacement.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: replacementGeneration
        )
        try await replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        try await replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        events.append("replacement_session_ready")

        let recorded = await diagnostics.snapshot()
        if recorded.contains(where: {
            $0.kind == .connection && $0.outcome == .cancelled
        }), recorded.contains(where: {
            $0.kind == .authentication
                && $0.outcome == .rejected
                && $0.failureCategory == .authentication
        }), recorded.contains(where: {
            $0.kind == .authentication
                && $0.outcome == .rejected
                && $0.failureCategory == .securityFailure
        }), recorded.contains(where: {
            $0.kind == .authentication && $0.outcome == .began
        }) {
            events.append("connection_diagnostics_bounded")
        } else {
            events.append("connection_diagnostics_incorrect")
        }
        return result(
            scenario: "connection_terminal_paths",
            events: events,
            snapshot: await replacement.snapshot(),
            failure: .securityFailure
        )
    }

    private static func historyPendingBusyDiagnostics()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        let connectionToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: generation
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: token,
            callbackGeneration: generation
        )
        var events = ["history_pending"]
        var failure: BandFailureCategory?
        do {
            _ = try await session.stageHistoryChunk(
                VirtualBandFixtures.historyChunk,
                token: token,
                callbackGeneration: generation
            )
        } catch let error as BandFailureCategory {
            failure = error
            events.append("second_chunk_rejected")
        }
        if (await diagnostics.snapshot()).last == BandDiagnosticEvent(
            kind: .history,
            outcome: .rejected,
            failureCategory: .busy
        ) {
            events.append("history_busy_recorded")
        } else {
            events.append("history_busy_missing")
        }
        try await session.acknowledgeHistory(
            receipt: DurableHistoryReceipt(
                acceptance: acceptance,
                historyStateCommitted: true,
                committedSamples: acceptance.acceptedSamples.count,
                committed: true
            ),
            token: token,
            callbackGeneration: generation
        )
        try await session.cancelOperation(token)
        events.append("operation_cancelled")
        return result(
            scenario: "history_pending_busy_diagnostics",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func capabilityTerminalPaths()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        var events: [String] = []

        let cancellationGeneration = try await session.beginScan()
        let cancellationToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: cancellationGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: cancellationToken,
            callbackGeneration: cancellationGeneration
        )
        try await session.cancelCapabilities(
            token: cancellationToken,
            callbackGeneration: cancellationGeneration
        )
        events.append("capability_cancelled")
        do {
            try await session.cancelCapabilities(
                token: cancellationToken,
                callbackGeneration: cancellationGeneration
            )
        } catch BandFailureCategory.staleCallback {
            events.append("stale_cancel_rejected")
        }

        let timeoutGeneration = try await session.beginScan()
        let timeoutToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: timeoutGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: timeoutToken,
            callbackGeneration: timeoutGeneration
        )
        try await session.failCapabilities(
            .timeout,
            token: timeoutToken,
            callbackGeneration: timeoutGeneration
        )
        events.append("capability_timed_out")
        do {
            try await session.failCapabilities(
                .internalFailure,
                token: timeoutToken,
                callbackGeneration: timeoutGeneration
            )
        } catch BandFailureCategory.staleCallback {
            events.append("stale_failure_rejected")
        }

        let authenticationGeneration = try await session.beginScan()
        let authenticationToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: authenticationGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: authenticationToken,
            callbackGeneration: authenticationGeneration
        )
        try await session.failCapabilities(
            .authentication,
            token: authenticationToken,
            callbackGeneration: authenticationGeneration
        )
        events.append("capability_authentication_rejected")

        let disconnectedGeneration = try await session.beginScan()
        let disconnectedToken = try await session.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: disconnectedGeneration
        )
        try await session.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: disconnectedToken,
            callbackGeneration: disconnectedGeneration
        )
        try await session.failCapabilities(
            .disconnected,
            token: disconnectedToken,
            callbackGeneration: disconnectedGeneration
        )
        events.append("capability_disconnected")

        let securitySession = BandSessionMachine(diagnostics: diagnostics)
        let securityGeneration = try await securitySession.beginScan()
        let securityToken = try await securitySession.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: securityGeneration
        )
        try await securitySession.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: securityToken,
            callbackGeneration: securityGeneration
        )
        try await securitySession.failCapabilities(
            .securityFailure,
            token: securityToken,
            callbackGeneration: securityGeneration
        )
        events.append("capability_security_failure")
        do {
            _ = try await securitySession.beginScan()
        } catch BandFailureCategory.invalidState {
            events.append("security_failure_restart_rejected")
        }

        let replacement = BandSessionMachine(diagnostics: diagnostics)
        let replacementGeneration = try await replacement.beginScan()
        let replacementConnectionToken = try await replacement.selectCandidate(
            VirtualBandFixtures.candidate,
            callbackGeneration: replacementGeneration
        )
        try await replacement.completeConnectionForConformance(
            VirtualBandFixtures.identity,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        try await replacement.acceptCapabilities(
            VirtualBandFixtures.capabilities,
            token: replacementConnectionToken,
            callbackGeneration: replacementGeneration
        )
        events.append("replacement_session_ready")

        let recorded = await diagnostics.snapshot()
        if recorded.contains(where: {
            $0.kind == .capability && $0.outcome == .cancelled
        }), recorded.contains(where: {
            $0.kind == .capability
                && $0.outcome == .timedOut
                && $0.failureCategory == .timeout
        }), recorded.contains(where: {
            $0.kind == .capability
                && $0.outcome == .rejected
                && $0.failureCategory == .authentication
        }), recorded.contains(where: {
            $0.kind == .capability
                && $0.outcome == .failed
                && $0.failureCategory == .disconnected
        }), recorded.filter({
            $0.kind == .capability
                && $0.outcome == .stale
                && $0.failureCategory == .staleCallback
        }).count == 2 {
            events.append("capability_diagnostics_bounded")
        } else {
            events.append("capability_diagnostics_incorrect")
        }

        return result(
            scenario: "capability_terminal_paths",
            events: events,
            snapshot: await replacement.snapshot(),
            failure: .securityFailure
        )
    }

    private static func diagnosticsBounded() async -> BandConformanceResult {
        let diagnostics = BandDiagnosticsRecorder(capacity: 4)
        for index in 0 ..< 10 {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .command,
                    outcome: index.isMultiple(of: 2) ? .completed : .rejected,
                    countBucket: BandCountBucket(count: index)
                )
            )
        }
        let snapshot = await diagnostics.snapshot()
        let events = [
            "diagnostics_recorded",
            snapshot.count == 4 ? "diagnostics_bounded" : "diagnostics_unbounded",
        ]
        return BandConformanceResult(
            scenario: "diagnostics_bounded",
            events: events,
            finalState: BandSessionState.idle.rawValue,
            acknowledgedCursor: nil,
            acceptedSamples: 0,
            failure: nil
        )
    }

    private static func fractionalStepsRejected() throws
        -> BandConformanceResult
    {
        let identity = BandSampleIdentity(
            stream: .steps,
            sequence: 1,
            deviceTimeMilliseconds: 1
        )
        for value in [0.0, 1.0, 1_000_000.0] {
            try BandSample(
                identity: identity,
                value: value,
                unit: .count,
                quality: .accepted
            ).validate()
        }

        var rejected = 0
        for value in [0.5, 1.5, 999_999.5] {
            do {
                try BandSample(
                    identity: identity,
                    value: value,
                    unit: .count,
                    quality: .accepted
                ).validate()
            } catch BandFailureCategory.invalidInput {
                rejected += 1
            }
        }
        return BandConformanceResult(
            scenario: "fractional_steps_rejected",
            events: [
                "integer_steps_accepted",
                rejected == 3
                    ? "fractional_steps_rejected"
                    : "fractional_steps_accepted",
            ],
            finalState: BandSessionState.idle.rawValue,
            acknowledgedCursor: nil,
            acceptedSamples: 0,
            failure: (
                rejected == 3
                    ? BandFailureCategory.invalidInput
                    : BandFailureCategory.internalFailure
            ).rawValue
        )
    }

    private static func closedSessionTerminal()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        try await session.close()
        var events = ["session_closed"]
        if (await cancelledKinds(in: diagnostics)).isEmpty {
            events.append("no_unmatched_connection_cancellation")
        } else {
            events.append("unmatched_connection_cancellation")
        }
        var failure: BandFailureCategory?
        do {
            _ = try await session.beginScan()
        } catch let error as BandFailureCategory {
            failure = error
            events.append("operation_rejected")
        } catch {
            failure = .internalFailure
        }
        return result(
            scenario: "closed_session_terminal",
            events: events,
            snapshot: await session.snapshot(),
            failure: failure
        )
    }

    private static func liveCallbackSessionBound()
        async throws -> BandConformanceResult
    {
        let (first, firstGeneration) = try await readySession()
        let (second, secondGeneration) = try await readySession()
        let store = VirtualBandStore()
        let firstToken = try await first.beginLive()
        let secondToken = try await second.beginLive()
        var events = ["ready_pair"]
        var failure: BandFailureCategory?

        do {
            _ = try await second.stageLiveBatch(
                VirtualBandFixtures.liveBatch,
                token: firstToken,
                callbackGeneration: secondGeneration
            )
            events.append("foreign_live_callback_accepted")
        } catch let error as BandFailureCategory {
            failure = error
            events.append("foreign_live_callback_rejected")
        }

        let acceptance = try await second.stageLiveBatch(
            VirtualBandFixtures.liveBatch,
            token: secondToken,
            callbackGeneration: secondGeneration
        )
        try await second.acknowledgeLive(
            receipt: await store.commit(acceptance: acceptance),
            callbackGeneration: secondGeneration
        )
        try await first.stopLive()
        try await second.stopLive()
        if firstGeneration == secondGeneration,
           acceptance.acceptedSamples.count == 1
        {
            events.append("own_live_callback_accepted")
        } else {
            events.append("own_live_callback_incorrect")
        }
        return result(
            scenario: "live_callback_session_bound",
            events: events,
            snapshot: await second.snapshot(),
            acceptedSamples: acceptance.acceptedSamples.count,
            failure: failure
        )
    }

    private static func closeActivePhaseTerminal()
        async throws -> BandConformanceResult
    {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, _) = try await readySession(diagnostics: diagnostics)
        _ = try await session.beginLive()
        _ = try await session.beginOperation(.history)
        var events = ["live_and_history_started"]
        let beforeClose = await diagnostics.snapshot().count
        try await session.close()
        let closeEvents = Array(
            (await diagnostics.snapshot()).dropFirst(beforeClose)
        )
        if closeEvents.contains(
            BandDiagnosticEvent(kind: .history, outcome: .cancelled)
        ) {
            events.append("history_cancelled")
        }
        if closeEvents.contains(
            BandDiagnosticEvent(kind: .live, outcome: .cancelled)
        ) {
            events.append("live_cancelled")
        }
        events.append("session_closed")
        return result(
            scenario: "close_active_phase_terminal",
            events: events,
            snapshot: await session.snapshot()
        )
    }

    private static func cancelledKinds(
        in recorder: BandDiagnosticsRecorder
    ) async -> [BandDiagnosticKind] {
        await recorder.snapshot()
            .filter { $0.outcome == .cancelled }
            .map(\.kind)
    }

    private static func result(
        scenario: String,
        events: [String],
        snapshot: BandSessionSnapshot,
        acceptedSamples: Int = 0,
        failure: BandFailureCategory? = nil
    ) -> BandConformanceResult {
        BandConformanceResult(
            scenario: scenario,
            events: events,
            finalState: snapshot.state.rawValue,
            acknowledgedCursor: snapshot.acknowledgedHistoryCursor,
            acceptedSamples: acceptedSamples,
            failure: failure?.rawValue
        )
    }
}
