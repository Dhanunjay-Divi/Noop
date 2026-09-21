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
        wrapperRevision: "artifact-0abd9a3c"
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

    private func readySession() async throws -> (BandSessionMachine, UInt64) {
        let session = BandSessionMachine()
        let generation = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            )
        )
        try await session.connect(identity)
        try await session.acceptCapabilities(capabilities)
        return (session, generation)
    }

    func testLiveAndHistoryUseOneDurableIdentitySet() async throws {
        let (session, generation) = try await readySession()
        let liveSample = sample(sequence: 1, time: 1_000, value: 72)
        let liveBatch = batch(lane: .live, samples: [liveSample, liveSample])

        try await session.beginLive()
        let acceptedLive = try await session.commitLiveBatch(
            liveBatch,
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
                chunkIdentity: acceptance.chunkIdentity,
                acknowledgementToken: acceptance.acknowledgementToken,
                nextCursor: acceptance.nextCursor,
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
                    chunkIdentity: acceptance.chunkIdentity,
                    acknowledgementToken: acceptance.acknowledgementToken,
                    nextCursor: acceptance.nextCursor,
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
    }

    func testReconnectRejectsStaleCallbacks() async throws {
        let (session, oldGeneration) = try await readySession()
        _ = try await session.interruptForReconnect()
        try await session.resumeAfterReconnect()
        try await session.beginLive()

        do {
            _ = try await session.commitLiveBatch(
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
