import XCTest
@_exported import NoopBandSDK

final class NoopBandSDKArtifactTests: XCTestCase {
    private struct ConformanceContract: Decodable {
        let schemaVersion: Int
        let scenarios: [ConformanceScenario]
    }

    private struct ConformanceScenario: Decodable {
        let id: String
        let automated: Bool
        let expected: ExpectedConformanceResult?
    }

    private struct ExpectedConformanceResult: Decodable {
        let events: [String]
        let finalState: String
        let acknowledgedCursor: String?
        let acceptedSamples: Int
        let failure: String?
    }

    private let identity = BandIdentity(
        sourceIdentity: "synthetic-source",
        hardwareRevision: "synthetic-hw-1",
        firmwareVersion: "synthetic-fw-1",
        protocolVersion: BandCapabilityReport.supportedProtocolVersion,
        wrapperRevision: "artifact-55fdd89"
    )

    private var capabilities: BandCapabilityReport {
        BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .rrIntervals, .battery]
        )
    }

    private func completeConnection(
        _ session: BandSessionMachine,
        identity: BandIdentity,
        callbackGeneration: UInt64
    ) async throws {
        try await session.beginConnection(
            callbackGeneration: callbackGeneration
        )
        try await session.beginAuthentication(
            callbackGeneration: callbackGeneration
        )
        try await session.completeConnection(
            identity,
            callbackGeneration: callbackGeneration
        )
    }

    private func readySession(
        report: BandCapabilityReport? = nil,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    ) async throws -> (BandSessionMachine, UInt64) {
        let session = BandSessionMachine(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: generation
        )
        try await completeConnection(
            session,
            identity: identity,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            report ?? capabilities,
            callbackGeneration: generation
        )
        return (session, generation)
    }

    func testLiveAndHistoryUseOneDurableIdentitySet() async throws {
        let (session, generation) = try await readySession()
        let liveSample = sample(sequence: 1, time: 1_000, value: 72)
        let liveBatch = batch(lane: .live, samples: [liveSample, liveSample])

        try await session.beginLive()
        let acceptedLive = try await durablyCommitLive(
            session: session,
            batch: liveBatch,
            callbackGeneration: generation
        )
        XCTAssertEqual(acceptedLive, 1)
        try await session.stopLive()

        let historySample = sample(sequence: 2, time: 2_000, value: 70)
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            BandHistoryChunk(
                chunkIdentity: "synthetic-chunk",
                previousCursor: nil,
                nextCursor: "cursor-1",
                complete: true,
                overflowed: false,
                acknowledgementToken: "ack-1",
                batches: [batch(lane: .history, samples: [historySample])]
            ),
            token: token,
            callbackGeneration: generation
        )
        XCTAssertEqual(acceptance.acceptedSamples, 1)

        try await session.acknowledgeHistory(
            receipt: DurableHistoryReceipt(
                acceptance: acceptance,
                historyStateCommitted: true,
                committedSamples: acceptance.acceptedSamples,
                committed: true
            ),
            token: token,
            callbackGeneration: generation
        )
        try await session.completeOperation(token)

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.acknowledgedHistoryCursor, "cursor-1")
        XCTAssertEqual(snapshot.durableSampleCount, 2)
    }

    func testHistoryCannotAdvanceWithoutMatchingDurableReceipt() async throws {
        let (session, generation) = try await readySession()
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            BandHistoryChunk(
                chunkIdentity: "synthetic-chunk",
                previousCursor: nil,
                nextCursor: "cursor-1",
                complete: true,
                overflowed: false,
                acknowledgementToken: "ack-1",
                batches: [batch(
                    lane: .history,
                    samples: [sample(sequence: 1, time: 1_000, value: 70)]
                )]
            ),
            token: token,
            callbackGeneration: generation
        )

        do {
            try await session.acknowledgeHistory(
                receipt: DurableHistoryReceipt(
                    acceptance: acceptance,
                    historyStateCommitted: false,
                    committedSamples: 0,
                    committed: false
                ),
                token: token,
                callbackGeneration: generation
            )
            XCTFail("A non-durable receipt must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .storage)
        }

        let snapshot = await session.snapshot()
        XCTAssertNil(snapshot.acknowledgedHistoryCursor)
        XCTAssertEqual(snapshot.durableSampleCount, 0)
        try await session.cancelOperation(token)
        let cancelledSnapshot = await session.snapshot()
        XCTAssertEqual(cancelledSnapshot.state, .ready)
    }

    func testReconnectRejectsStaleCallbacks() async throws {
        let (session, oldGeneration) = try await readySession()
        let reconnectGeneration = try await session.interruptForReconnect(
            callbackGeneration: oldGeneration
        )
        try await session.resumeAfterReconnect(
            callbackGeneration: reconnectGeneration
        )
        try await session.beginLive()

        do {
            _ = try await session.stageLiveBatch(
                batch(
                    lane: .live,
                    samples: [sample(sequence: 1, time: 1_000, value: 72)]
                ),
                callbackGeneration: oldGeneration
            )
            XCTFail("A callback from the old session generation must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .staleCallback)
        }
    }

    func testDiscoveryGenerationAndTerminalPathsRemainRetryable() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let session = BandSessionMachine(diagnostics: diagnostics)
        let firstGeneration = try await session.beginScan()

        try await session.failScan(
            .timeout,
            callbackGeneration: firstGeneration
        )
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.generation, firstGeneration + 1)

        let retryGeneration = try await session.beginScan()
        do {
            try await session.selectCandidate(
                BandPairingCandidate(
                    handle: "stale-candidate",
                    compatible: true,
                    identifyEligible: true
                ),
                callbackGeneration: firstGeneration
            )
            XCTFail("A candidate from an earlier scan must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .staleCallback)
        }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .scanning)

        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "current-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: retryGeneration
        )
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .candidateSelected)

        let cancelled = BandSessionMachine(diagnostics: diagnostics)
        let cancelledGeneration = try await cancelled.beginScan()
        try await cancelled.cancelScan(
            callbackGeneration: cancelledGeneration
        )
        snapshot = await cancelled.snapshot()
        XCTAssertEqual(snapshot.state, .idle)

        let discoveryEvents = await diagnostics.snapshot().filter {
            $0.kind == .discovery
        }
        XCTAssertTrue(discoveryEvents.contains {
            $0.outcome == .timedOut && $0.failureCategory == .timeout
        })
        XCTAssertTrue(discoveryEvents.contains {
            $0.outcome == .stale
                && $0.failureCategory == .staleCallback
        })
        XCTAssertTrue(discoveryEvents.contains {
            $0.outcome == .cancelled
        })
    }

    func testDuplicateCapabilityCallbacksCannotDestroyReadySession() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation) = try await readySession(
            diagnostics: diagnostics
        )

        try await session.acceptCapabilities(
            capabilities,
            callbackGeneration: generation
        )
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)

        let changed = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: capabilities.historyDays,
            capabilities: capabilities.capabilities.union([.steps])
        )
        do {
            try await session.acceptCapabilities(
                changed,
                callbackGeneration: generation
            )
            XCTFail("A changed late report must require fresh negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)

        try await session.beginLive()
        try await session.stopLive()
        let capabilityEvents = await diagnostics.snapshot().filter {
            $0.kind == .capability
        }
        XCTAssertTrue(capabilityEvents.contains { $0.outcome == .stale })
        XCTAssertTrue(capabilityEvents.contains {
            $0.outcome == .rejected
                && $0.failureCategory == .invalidState
        })
    }

    func testLiveSupportsNegotiatedNonHeartRateStreams() async throws {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.spo2]
        )
        let (session, generation) = try await readySession(report: report)
        let spo2 = BandSample(
            identity: BandSampleIdentity(
                stream: .spo2,
                sequence: 1,
                deviceTimeMilliseconds: 1_000
            ),
            value: 98,
            unit: .percent,
            quality: .accepted
        )

        try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: BandSampleBatch(
                sourceIdentity: identity.sourceIdentity,
                lane: .live,
                parserRevision: "parser-v1",
                calibrationRevision: "calibration-v1",
                samples: [spo2]
            ),
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive()
    }

    func testLiveDeduplicationWaitsForDurableReceipt() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation) = try await readySession(
            diagnostics: diagnostics
        )
        let liveBatch = batch(
            lane: .live,
            samples: [sample(sequence: 10, time: 10_000, value: 72)]
        )
        try await session.beginLive()

        let first = try await session.stageLiveBatch(
            liveBatch,
            callbackGeneration: generation
        )
        XCTAssertEqual(first.acceptedSamples.count, 1)
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.durableSampleCount, 0)

        do {
            try await session.acknowledgeLive(
                receipt: DurableLiveReceipt(
                    acceptance: first,
                    committedSamples: 0,
                    committed: false
                ),
                callbackGeneration: generation
            )
            XCTFail("A failed store write must not become durable")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .storage)
        }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.durableSampleCount, 0)

        let retried = try await session.stageLiveBatch(
            liveBatch,
            callbackGeneration: generation
        )
        XCTAssertEqual(retried.acceptedSamples.count, 1)
        try await session.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: retried,
                committedSamples: 1,
                committed: true
            ),
            callbackGeneration: generation
        )
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.durableSampleCount, 1)

        let duplicate = try await session.stageLiveBatch(
            liveBatch,
            callbackGeneration: generation
        )
        XCTAssertEqual(duplicate.acceptedSamples.count, 0)
        XCTAssertEqual(duplicate.duplicateSamples, 1)
        try await session.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: duplicate,
                committedSamples: 0,
                committed: true
            ),
            callbackGeneration: generation
        )
        try await session.stopLive()

        let liveEvents = await diagnostics.snapshot().filter {
            $0.kind == .live
        }
        XCTAssertTrue(liveEvents.contains {
            $0.outcome == .failed && $0.failureCategory == .storage
        })
        XCTAssertTrue(liveEvents.contains {
            $0.outcome == .completed && $0.countBucket == .one
        })
    }

    func testHistoryRequiresReportedAvailability() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 0,
            capabilities: [.heartRate]
        )
        let (session, _) = try await readySession(
            report: report,
            diagnostics: diagnostics
        )

        do {
            _ = try await session.beginOperation(.history)
            XCTFail("History must be unavailable when the report says zero days")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .unsupported)
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains {
            $0.kind == .history
                && $0.outcome == .rejected
                && $0.failureCategory == .unsupported
        })
    }

    func testFirmwareCompletionRequiresFreshNegotiationAndPreservesCheckpoint()
        async throws
    {
        let firmwareCapabilities = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .firmwareUpdate]
        )
        let (session, generation) = try await readySession(
            report: firmwareCapabilities
        )
        try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: batch(
                lane: .live,
                samples: [sample(sequence: 20, time: 20_000, value: 71)]
            ),
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive()

        let firmware = try await session.beginOperation(.firmware)
        try await session.completeOperation(firmware)
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .recovering)
        XCTAssertEqual(snapshot.generation, generation + 1)
        XCTAssertEqual(snapshot.durableSampleCount, 1)

        do {
            try await session.resumeAfterReconnect(
                callbackGeneration: snapshot.generation
            )
            XCTFail("Firmware completion must invalidate prior negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }

        let postFirmwareGeneration = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "post-firmware-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: postFirmwareGeneration
        )
        let updatedIdentity = BandIdentity(
            sourceIdentity: identity.sourceIdentity,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: "synthetic-fw-2",
            protocolVersion: identity.protocolVersion,
            wrapperRevision: identity.wrapperRevision
        )
        try await completeConnection(
            session,
            identity: updatedIdentity,
            callbackGeneration: postFirmwareGeneration
        )
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: BandCapabilityReport.supportedProtocolVersion,
                hardwareRevision: updatedIdentity.hardwareRevision,
                firmwareVersion: updatedIdentity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate, .firmwareUpdate]
            ),
            callbackGeneration: postFirmwareGeneration
        )
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.durableSampleCount, 1)
    }

    func testEveryFirmwareTerminalInvalidatesNegotiation() async throws {
        let report = BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .firmwareUpdate]
        )

        let (cancelledSession, _) = try await readySession(report: report)
        let cancelledToken = try await cancelledSession.beginOperation(.firmware)
        try await cancelledSession.cancelOperation(cancelledToken)
        var snapshot = await cancelledSession.snapshot()
        XCTAssertEqual(snapshot.state, .recovering)
        do {
            try await cancelledSession.resumeAfterReconnect(
                callbackGeneration: snapshot.generation
            )
            XCTFail("Cancelled firmware must require fresh negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }

        let (failedSession, _) = try await readySession(report: report)
        let failedToken = try await failedSession.beginOperation(.firmware)
        try await failedSession.failOperation(failedToken, category: .timeout)
        snapshot = await failedSession.snapshot()
        XCTAssertEqual(snapshot.state, .recovering)
        do {
            try await failedSession.resumeAfterReconnect(
                callbackGeneration: snapshot.generation
            )
            XCTFail("Failed firmware must require fresh negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }

        let diagnostics = BandDiagnosticsRecorder()
        let (interruptedSession, _) = try await readySession(
            report: report,
            diagnostics: diagnostics
        )
        _ = try await interruptedSession.beginOperation(.firmware)
        let interruptedGeneration =
            try await interruptedSession.interruptForReconnect(
                callbackGeneration: (await interruptedSession.snapshot()).generation
            )
        snapshot = await interruptedSession.snapshot()
        XCTAssertEqual(snapshot.state, .recovering)
        do {
            try await interruptedSession.resumeAfterReconnect(
                callbackGeneration: interruptedGeneration
            )
            XCTFail("Interrupted firmware must require fresh negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains {
            $0.kind == .firmware
                && $0.outcome == .interrupted
                && $0.failureCategory == .disconnected
        })
    }

    func testMalformedLiveAndHistoryInputsEmitBoundedRejections() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation) = try await readySession(
            diagnostics: diagnostics
        )
        let invalid = sample(sequence: 30, time: -1, value: 72)

        try await session.beginLive()
        do {
            _ = try await session.stageLiveBatch(
                batch(lane: .live, samples: [invalid]),
                callbackGeneration: generation
            )
            XCTFail("Malformed live samples must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidInput)
        }
        try await session.stopLive()

        let history = try await session.beginOperation(.history)
        do {
            _ = try await session.stageHistoryChunk(
                BandHistoryChunk(
                    chunkIdentity: "invalid-history",
                    previousCursor: nil,
                    nextCursor: "cursor-invalid",
                    complete: true,
                    overflowed: false,
                    acknowledgementToken: "ack-invalid",
                    batches: [batch(lane: .history, samples: [invalid])]
                ),
                token: history,
                callbackGeneration: generation
            )
            XCTFail("Malformed history samples must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidInput)
        }
        try await session.cancelOperation(history)

        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains {
            $0.kind == .live
                && $0.outcome == .rejected
                && $0.failureCategory == .invalidInput
        })
        XCTAssertTrue(events.contains {
            $0.kind == .history
                && $0.outcome == .rejected
                && $0.failureCategory == .invalidInput
        })
    }

    func testRecoveryScanClearsNegotiationWithoutDiscardingCheckpoint()
        async throws
    {
        let (session, generation) = try await readySession()
        try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: batch(
                lane: .live,
                samples: [sample(sequence: 40, time: 40_000, value: 70)]
            ),
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive()

        _ = try await session.interruptForReconnect(
            callbackGeneration: generation
        )
        let scanGeneration = try await session.beginScan()
        do {
            try await session.resumeAfterReconnect(
                callbackGeneration: scanGeneration
            )
            XCTFail("A new scan must discard prior negotiation state")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }

        let restoredCheckpoint = await session.historyCheckpoint()
        let checkpoint = try XCTUnwrap(restoredCheckpoint)
        XCTAssertEqual(checkpoint.durableSampleIdentities.count, 1)

        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "recovery-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: scanGeneration
        )
        try await completeConnection(
            session,
            identity: identity,
            callbackGeneration: scanGeneration
        )
        try await session.acceptCapabilities(
            capabilities,
            callbackGeneration: scanGeneration
        )
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.durableSampleCount, 1)
    }

    func testSampleIdentityUsesTheSigned64CrossPlatformDomain() throws {
        let maximum = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: BandContractLimits.maximumSampleSequence,
                deviceTimeMilliseconds: Int64.max
            ),
            value: 72,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        XCTAssertNoThrow(try maximum.validate())

        let overflow = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: BandContractLimits.maximumSampleSequence + 1,
                deviceTimeMilliseconds: 0
            ),
            value: 72,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        XCTAssertThrowsError(try overflow.validate()) { error in
            XCTAssertEqual(error as? BandFailureCategory, .invalidInput)
        }

        let negativeTime = BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: 0,
                deviceTimeMilliseconds: -1
            ),
            value: 72,
            unit: .beatsPerMinute,
            quality: .accepted
        )
        XCTAssertThrowsError(try negativeTime.validate()) { error in
            XCTAssertEqual(error as? BandFailureCategory, .invalidInput)
        }
    }

    func testOperationTokenConstructionIsNotPublic() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let models = try String(
            contentsOf: packageRoot
                .appendingPathComponent("production")
                .appendingPathComponent("apple")
                .appendingPathComponent("NoopBandModels.swift"),
            encoding: .utf8
        )
        let tokenStart = try XCTUnwrap(
            models.range(of: "public struct BandOperationToken")
        )
        let liveStart = try XCTUnwrap(
            models.range(
                of: "public struct LiveAcceptance",
                range: tokenStart.upperBound ..< models.endIndex
            )
        )
        let declaration = String(
            models[tokenStart.lowerBound ..< liveStart.lowerBound]
        )
        XCTAssertFalse(declaration.contains("public let generation"))
        XCTAssertFalse(declaration.contains("public let sequence"))
        XCTAssertFalse(declaration.contains("public init("))
    }

    private func durablyCommitLive(
        session: BandSessionMachine,
        batch: BandSampleBatch,
        callbackGeneration: UInt64
    ) async throws -> Int {
        let acceptance = try await session.stageLiveBatch(
            batch,
            callbackGeneration: callbackGeneration
        )
        try await session.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: acceptance,
                committedSamples: acceptance.acceptedSamples.count,
                committed: true
            ),
            callbackGeneration: callbackGeneration
        )
        return acceptance.acceptedSamples.count
    }

    func testAllAutomatedScenariosMatchTheExportedContract() async throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractURL = packageRoot
            .appendingPathComponent("contract")
            .appendingPathComponent("conformance")
            .appendingPathComponent("scenarios.json")
        let contract = try JSONDecoder().decode(
            ConformanceContract.self,
            from: Data(contentsOf: contractURL)
        )
        XCTAssertEqual(contract.schemaVersion, 1)

        let automated = contract.scenarios.filter(\.automated)
        XCTAssertEqual(
            automated.map(\.id),
            BandConformanceRunner.automatedScenarios
        )

        for scenario in automated {
            let expected = try XCTUnwrap(
                scenario.expected,
                "Missing expected result for \(scenario.id)"
            )
            let actual = try await BandConformanceRunner.run(scenario.id)
            XCTAssertEqual(
                actual,
                BandConformanceResult(
                    scenario: scenario.id,
                    events: expected.events,
                    finalState: expected.finalState,
                    acknowledgedCursor: expected.acknowledgedCursor,
                    acceptedSamples: expected.acceptedSamples,
                    failure: expected.failure
                ),
                "Conformance mismatch for \(scenario.id)"
            )
        }
    }

    private func sample(sequence: UInt64, time: Int64, value: Double) -> BandSample {
        BandSample(
            identity: BandSampleIdentity(
                stream: .heartRate,
                sequence: sequence,
                deviceTimeMilliseconds: time
            ),
            value: value,
            unit: .beatsPerMinute,
            quality: .accepted
        )
    }

    private func batch(
        lane: BandProvenanceLane,
        samples: [BandSample]
    ) -> BandSampleBatch {
        BandSampleBatch(
            sourceIdentity: identity.sourceIdentity,
            lane: lane,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: samples
        )
    }
}
