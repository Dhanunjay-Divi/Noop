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
        wrapperRevision: "artifact-823930f"
    )

    private var capabilities: BandCapabilityReport {
        BandCapabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: identity.hardwareRevision,
            firmwareVersion: identity.firmwareVersion,
            historyDays: 7,
            capabilities: [.heartRate, .rrIntervals, .battery],
            liveStreams: [.heartRate, .rrInterval],
            historyStreams: [.heartRate, .rrInterval]
        )
    }

    private func completeConnection(
        _ session: BandSessionMachine,
        identity: BandIdentity,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try await session.beginConnection(
            token: token,
            callbackGeneration: callbackGeneration
        )
        try await session.beginAuthentication(
            token: token,
            callbackGeneration: callbackGeneration
        )
        try await session.completeConnection(
            identity,
            token: token,
            callbackGeneration: callbackGeneration
        )
    }

    private func readySession(
        report: BandCapabilityReport? = nil,
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    ) async throws -> (BandSessionMachine, UInt64, BandConnectionToken) {
        let session = BandSessionMachine(diagnostics: diagnostics)
        let scanToken = try await session.beginScan()
        let generation = scanToken.generation
        let connectionToken = try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: scanToken
        )
        try await completeConnection(
            session,
            identity: identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            report ?? capabilities,
            token: connectionToken,
            callbackGeneration: generation
        )
        return (session, generation, connectionToken)
    }

    func testLiveAndHistoryUseOneDurableIdentitySet() async throws {
        let (session, generation, _) = try await readySession()
        let liveSample = sample(sequence: 1, time: 1_000, value: 72)
        let liveBatch = batch(lane: .live, samples: [liveSample, liveSample])

        let liveToken = try await session.beginLive()
        let acceptedLive = try await durablyCommitLive(
            session: session,
            batch: liveBatch,
            token: liveToken,
            callbackGeneration: generation
        )
        XCTAssertEqual(acceptedLive, 1)
        try await session.stopLive(token: liveToken)

        let historySample = sample(sequence: 2, time: 2_000, value: 70)
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            BandHistoryChunk(
                chunkIdentity: "synthetic-chunk",
                previousCursor: nil,
                nextCursor: "cursor-1",
                complete: true,
                overflowed: false,
                retainedRange: nil,
                firstLostRange: nil,
                acknowledgementToken: "ack-1",
                batches: [batch(lane: .history, samples: [historySample])]
            ),
            token: token,
            callbackGeneration: generation
        )
        XCTAssertEqual(acceptance.acceptedSamples.count, 1)

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
        try await session.completeOperation(token)

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.acknowledgedHistoryCursor, "cursor-1")
        XCTAssertEqual(snapshot.durableSampleCount, 2)
    }

    func testHistoryCannotAdvanceWithoutMatchingDurableReceipt() async throws {
        let (session, generation, _) = try await readySession()
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            BandHistoryChunk(
                chunkIdentity: "synthetic-chunk",
                previousCursor: nil,
                nextCursor: "cursor-1",
                complete: true,
                overflowed: false,
                retainedRange: nil,
                firstLostRange: nil,
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
        let (session, oldGeneration, _) = try await readySession()
        let reconnectGeneration = try await session.interruptForReconnect(
            callbackGeneration: oldGeneration
        )
        try await session.resumeAfterReconnect(
            callbackGeneration: reconnectGeneration
        )
        let liveToken = try await session.beginLive()

        do {
            _ = try await session.stageLiveBatch(
                batch(
                    lane: .live,
                    samples: [sample(sequence: 1, time: 1_000, value: 72)]
                ),
                token: liveToken,
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
        let firstScanToken = try await session.beginScan()
        let firstGeneration = firstScanToken.generation

        try await session.failScan(
            .timeout,
            callbackGeneration: firstScanToken
        )
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.generation, firstGeneration + 1)

        let retryScanToken = try await session.beginScan()
        do {
            _ = try await session.selectCandidate(
                BandPairingCandidate(
                    handle: "stale-candidate",
                    compatible: true,
                    identifyEligible: true
                ),
                callbackGeneration: firstScanToken
            )
            XCTFail("A candidate from an earlier scan must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .staleCallback)
        }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .scanning)

        _ = try await session.selectCandidate(
            BandPairingCandidate(
                handle: "current-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: retryScanToken
        )
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .candidateSelected)

        let cancelled = BandSessionMachine(diagnostics: diagnostics)
        let cancelledScanToken = try await cancelled.beginScan()
        try await cancelled.cancelScan(
            callbackGeneration: cancelledScanToken
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
        let (session, generation, connectionToken) = try await readySession(
            diagnostics: diagnostics
        )

        try await session.acceptCapabilities(
            capabilities,
            token: connectionToken,
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
            capabilities: capabilities.capabilities.union([.steps]),
            liveStreams: capabilities.liveStreams.union([.steps]),
            historyStreams: capabilities.historyStreams
        )
        do {
            try await session.acceptCapabilities(
                changed,
                token: connectionToken,
                callbackGeneration: generation
            )
            XCTFail("A changed late report must require fresh negotiation")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidState)
        }
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)

        let liveToken = try await session.beginLive()
        try await session.stopLive(token: liveToken)
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
            capabilities: [.spo2],
            liveStreams: [.spo2],
            historyStreams: []
        )
        let (session, generation, _) = try await readySession(report: report)
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

        let liveToken = try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: BandSampleBatch(
                sourceIdentity: identity.sourceIdentity,
                lane: .live,
                parserRevision: "parser-v1",
                calibrationRevision: "calibration-v1",
                samples: [spo2]
            ),
            token: liveToken,
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive(token: liveToken)
    }

    func testLiveDeduplicationWaitsForDurableReceipt() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation, _) = try await readySession(
            diagnostics: diagnostics
        )
        let liveBatch = batch(
            lane: .live,
            samples: [sample(sequence: 10, time: 10_000, value: 72)]
        )
        let liveToken = try await session.beginLive()

        let first = try await session.stageLiveBatch(
            liveBatch,
            token: liveToken,
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
            token: liveToken,
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
            token: liveToken,
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
        try await session.stopLive(token: liveToken)

        let liveEvents = await diagnostics.snapshot().filter {
            $0.kind == .live
        }
        XCTAssertTrue(liveEvents.contains {
            $0.outcome == .failed && $0.failureCategory == .storage
        })
        XCTAssertTrue(liveEvents.contains {
            $0.outcome == .completed && $0.countBucket == .zero
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
            capabilities: [.heartRate],
            liveStreams: [.heartRate],
            historyStreams: []
        )
        let (session, _, _) = try await readySession(
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
            capabilities: [.heartRate, .firmwareUpdate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )
        let (session, generation, _) = try await readySession(
            report: firmwareCapabilities
        )
        let liveToken = try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: batch(
                lane: .live,
                samples: [sample(sequence: 20, time: 20_000, value: 71)]
            ),
            token: liveToken,
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive(token: liveToken)

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

        let postFirmwareScanToken = try await session.beginScan()
        let postFirmwareGeneration = postFirmwareScanToken.generation
        let postFirmwareConnectionToken = try await session.selectCandidate(
            BandPairingCandidate(
                handle: "post-firmware-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: postFirmwareScanToken
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
            token: postFirmwareConnectionToken,
            callbackGeneration: postFirmwareGeneration
        )
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: BandCapabilityReport.supportedProtocolVersion,
                hardwareRevision: updatedIdentity.hardwareRevision,
                firmwareVersion: updatedIdentity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate, .firmwareUpdate],
                liveStreams: [.heartRate],
                historyStreams: [.heartRate]
            ),
            token: postFirmwareConnectionToken,
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
            capabilities: [.heartRate, .firmwareUpdate],
            liveStreams: [.heartRate],
            historyStreams: [.heartRate]
        )

        let (cancelledSession, _, _) = try await readySession(report: report)
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

        let (failedSession, _, _) = try await readySession(report: report)
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
        let (interruptedSession, _, _) = try await readySession(
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
        let (session, generation, _) = try await readySession(
            diagnostics: diagnostics
        )
        let invalid = sample(sequence: 30, time: -1, value: 72)

        let liveToken = try await session.beginLive()
        do {
            _ = try await session.stageLiveBatch(
                batch(lane: .live, samples: [invalid]),
                token: liveToken,
                callbackGeneration: generation
            )
            XCTFail("Malformed live samples must be rejected")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .invalidInput)
        }
        try await session.stopLive(token: liveToken)

        let history = try await session.beginOperation(.history)
        do {
            _ = try await session.stageHistoryChunk(
                BandHistoryChunk(
                    chunkIdentity: "invalid-history",
                    previousCursor: nil,
                    nextCursor: "cursor-invalid",
                    complete: true,
                    overflowed: false,
                    retainedRange: nil,
                    firstLostRange: nil,
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
        let (session, generation, _) = try await readySession()
        let liveToken = try await session.beginLive()
        let accepted = try await durablyCommitLive(
            session: session,
            batch: batch(
                lane: .live,
                samples: [sample(sequence: 40, time: 40_000, value: 70)]
            ),
            token: liveToken,
            callbackGeneration: generation
        )
        XCTAssertEqual(accepted, 1)
        try await session.stopLive(token: liveToken)

        _ = try await session.interruptForReconnect(
            callbackGeneration: generation
        )
        let recoveryScanToken = try await session.beginScan()
        let scanGeneration = recoveryScanToken.generation
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

        let recoveryConnectionToken = try await session.selectCandidate(
            BandPairingCandidate(
                handle: "recovery-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: recoveryScanToken
        )
        try await completeConnection(
            session,
            identity: identity,
            token: recoveryConnectionToken,
            callbackGeneration: scanGeneration
        )
        try await session.acceptCapabilities(
            capabilities,
            token: recoveryConnectionToken,
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
        token: BandLiveToken,
        callbackGeneration: UInt64
    ) async throws -> Int {
        let acceptance = try await session.stageLiveBatch(
            batch,
            token: token,
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
