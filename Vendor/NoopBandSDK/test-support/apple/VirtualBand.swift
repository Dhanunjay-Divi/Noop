import Foundation

public actor VirtualBandStore {
    private var committed: Set<BandSampleIdentity> = []

    public init() {}

    public func commit(
        acceptance: HistoryAcceptance,
        samples: [BandSample]
    ) -> DurableHistoryReceipt {
        let identities = Set(samples.map(\.identity))
        committed.formUnion(identities)
        return DurableHistoryReceipt(
            chunkIdentity: acceptance.chunkIdentity,
            acknowledgementToken: acceptance.acknowledgementToken,
            nextCursor: acceptance.nextCursor,
            committedSamples: identities.count,
            committed: true
        )
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
            .haptics,
            .alarms,
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
        acknowledgementToken: "ack-2",
        batches: historyChunk.batches
    )
}

public enum BandConformanceRunner {
    public static let automatedScenarios = [
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
        "diagnostics_bounded",
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
        case "diagnostics_bounded":
            return await diagnosticsBounded()
        case "closed_session_terminal":
            return await closedSessionTerminal()
        default:
            throw BandFailureCategory.invalidInput
        }
    }

    private static func readySession()
        async throws -> (BandSessionMachine, UInt64)
    {
        let session = BandSessionMachine()
        let generation = try await session.beginScan()
        try await session.selectCandidate(VirtualBandFixtures.candidate)
        try await session.connect(VirtualBandFixtures.identity)
        try await session.acceptCapabilities(VirtualBandFixtures.capabilities)
        return (session, generation)
    }

    private static func happyPath() async throws -> BandConformanceResult {
        let session = BandSessionMachine()
        let store = VirtualBandStore()
        var events: [String] = []
        var accepted = 0

        let generation = try await session.beginScan()
        events.append("scan_started")
        try await session.selectCandidate(VirtualBandFixtures.candidate)
        events.append("candidate_selected")
        try await session.connect(VirtualBandFixtures.identity)
        events.append("connected")
        try await session.acceptCapabilities(VirtualBandFixtures.capabilities)
        events.append("capabilities_accepted")
        try await session.beginLive()
        accepted += try await session.commitLiveBatch(
            VirtualBandFixtures.liveBatch,
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
        accepted += acceptance.acceptedSamples
        events.append("history_received")
        let receipt = await store.commit(
            acceptance: acceptance,
            samples: VirtualBandFixtures.historyChunk.batches.flatMap(\.samples)
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
        let (session, oldGeneration) = try await readySession()
        var events = ["ready"]
        _ = try await session.interruptForReconnect()
        try await session.resumeAfterReconnect()
        events.append("generation_advanced")
        var failure: BandFailureCategory?
        do {
            _ = try await session.commitLiveBatch(
                VirtualBandFixtures.liveBatch,
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
            chunkIdentity: acceptance.chunkIdentity,
            acknowledgementToken: acceptance.acknowledgementToken,
            nextCursor: acceptance.nextCursor,
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
        let receipt = await store.commit(
            acceptance: acceptance,
            samples: VirtualBandFixtures.historyChunk.batches.flatMap(\.samples)
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
            scenario: "history_requires_durable_receipt",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: acceptance.acceptedSamples,
            failure: failure
        )
    }

    private static func liveDoesNotAdvanceHistory() async throws -> BandConformanceResult {
        let (session, generation) = try await readySession()
        var events = ["ready"]
        let before = await session.snapshot().acknowledgedHistoryCursor
        try await session.beginLive()
        let accepted = try await session.commitLiveBatch(
            VirtualBandFixtures.liveBatch,
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
        try await session.beginLive()
        let accepted = try await session.commitLiveBatch(
            VirtualBandFixtures.duplicateLiveBatch,
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
        let firstReceipt = await store.commit(
            acceptance: firstAcceptance,
            samples: VirtualBandFixtures.historyChunk.batches.flatMap(\.samples)
        )
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
        try await session.completeOperation(secondToken)
        events.append("operation_completed")

        return result(
            scenario: "history_cursor_chain_rejected",
            events: events,
            snapshot: await session.snapshot(),
            acceptedSamples: firstAcceptance.acceptedSamples,
            failure: failure
        )
    }

    private static func operationCapabilityFailsClosed()
        async throws -> BandConformanceResult
    {
        let session = BandSessionMachine()
        _ = try await session.beginScan()
        try await session.selectCandidate(VirtualBandFixtures.candidate)
        try await session.connect(VirtualBandFixtures.identity)
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.battery, .heartRate]
        )
        try await session.acceptCapabilities(report)
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
        try await session.beginLive()
        var failure: BandFailureCategory?
        do {
            _ = try await session.commitLiveBatch(
                batch,
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
        _ = try await session.beginScan()
        events.append("scan_started")
        try await session.selectCandidate(VirtualBandFixtures.candidate)
        events.append("candidate_selected")
        let identity = BandIdentity(
            sourceIdentity: VirtualBandFixtures.identity.sourceIdentity,
            hardwareRevision: VirtualBandFixtures.identity.hardwareRevision,
            firmwareVersion: VirtualBandFixtures.identity.firmwareVersion,
            protocolVersion: "noop-band-v2",
            wrapperRevision: VirtualBandFixtures.identity.wrapperRevision
        )
        try await session.connect(identity)
        events.append("connected")
        let report = BandCapabilityReport(
            schemaVersion: 2,
            protocolVersion: "noop-band-v2",
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate]
        )
        var failure: BandFailureCategory?
        do {
            try await session.acceptCapabilities(report)
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
        _ = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: firstToken,
            callbackGeneration: generation
        )
        events.append("history_received")
        _ = try await session.interruptForReconnect()
        failure = .disconnected
        events.append("history_interrupted")
        let resumedGeneration = await session.snapshot().generation
        try await session.resumeAfterReconnect()
        events.append("reconnected")
        let secondToken = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            VirtualBandFixtures.historyChunk,
            token: secondToken,
            callbackGeneration: resumedGeneration
        )
        events.append("history_resumed")
        let receipt = await store.commit(
            acceptance: acceptance,
            samples: VirtualBandFixtures.historyChunk.batches.flatMap(\.samples)
        )
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
            acceptedSamples: acceptance.acceptedSamples,
            failure: failure
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

    private static func closedSessionTerminal() async -> BandConformanceResult {
        let session = BandSessionMachine()
        await session.close()
        var events = ["session_closed"]
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
