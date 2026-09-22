import Combine
import XCTest
import NoopBandSDK
import WhoopStore
@testable import Strand

final class NoopBandSDKIntegrationTests: XCTestCase {
    @MainActor
    private final class FakeNoopBandSource: LiveHRSource {
        private(set) var scans = 0
        private(set) var connects: [UUID] = []
        private(set) var stops = 0

        func scan() {
            scans += 1
        }

        func connect(_ id: UUID) {
            connects.append(id)
        }

        func stop() {
            stops += 1
        }
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

    private func readyHistorySession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    ) async throws -> (BandSessionMachine, UInt64) {
        let session = NoopBandSDKBoundary.makeSession(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: generation
        )
        let identity = BandIdentity(
            sourceIdentity: "synthetic-source",
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-55fdd89"
        )
        try await completeConnection(
            session,
            identity: identity,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate]
            ),
            callbackGeneration: generation
        )
        return (session, generation)
    }

    func testPinnedAppBoundaryCreatesNeutralSession() async throws {
        XCTAssertEqual(
            NoopBandSDKBoundary.pinnedSourceRevision,
            "bdeddf876af4a83c1f9607ea3b6345b969152ab4"
        )
        let session = NoopBandSDKBoundary.makeSession()
        let generation = try await session.beginScan()
        XCTAssertEqual(generation, 1)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .scanning)
    }

    func testPinnedBoundaryRestoresSourceScopedHistoryCheckpoint() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let checkpoint = BandHistoryCheckpoint(
            sourceIdentity: "synthetic-source",
            acknowledgedCursor: "cursor-2",
            lastHistoryComplete: false,
            durableSampleIdentities: []
        )
        let session = NoopBandSDKBoundary.makeSession(
            diagnostics: diagnostics,
            historyCheckpoint: checkpoint
        )
        let generation = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: generation
        )
        let identity = BandIdentity(
            sourceIdentity: checkpoint.sourceIdentity,
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-55fdd89"
        )
        try await completeConnection(
            session,
            identity: identity,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate]
            ),
            callbackGeneration: generation
        )
        let restoredSnapshot = await session.snapshot()
        XCTAssertEqual(
            restoredSnapshot.acknowledgedHistoryCursor,
            checkpoint.acknowledgedCursor
        )
        let token = try await session.beginOperation(.history)
        do {
            try await session.completeOperation(token)
            XCTFail("An incomplete restored range must require a terminal chunk")
        } catch let error as BandFailureCategory {
            XCTAssertEqual(error, .storage)
        }
        let events = await diagnostics.snapshot()
        XCTAssertTrue(
            events.contains(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .failed,
                    failureCategory: .storage
                )
            )
        )
        try await session.cancelOperation(token)
        let cancelledSnapshot = await session.snapshot()
        XCTAssertEqual(cancelledSnapshot.state, .ready)
    }

    func testOperationFailureAdvancesGenerationAndRecordsBoundedCategory() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let session = NoopBandSDKBoundary.makeSession(diagnostics: diagnostics)
        let generation = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            ),
            callbackGeneration: generation
        )
        let identity = BandIdentity(
            sourceIdentity: "synthetic-source",
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-55fdd89"
        )
        try await completeConnection(
            session,
            identity: identity,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.battery]
            ),
            callbackGeneration: generation
        )

        let token = try await session.beginOperation(.battery)
        try await session.failOperation(token, category: .disconnected)

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .recovering)
        XCTAssertEqual(snapshot.generation, generation + 1)
        let events = await diagnostics.snapshot()
        XCTAssertTrue(
            events.contains(
                BandDiagnosticEvent(
                    kind: .command,
                    outcome: .failed,
                    failureCategory: .disconnected
                )
            )
        )
        XCTAssertTrue(
            events.contains(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                )
            )
        )
    }

    func testInvalidHistoryTokensRecordBoundedRejections() async throws {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation) = try await readyHistorySession(
            diagnostics: diagnostics
        )
        let supersededToken = try await session.beginOperation(.history)
        try await session.cancelOperation(supersededToken)
        let activeToken = try await session.beginOperation(.history)
        let (foreignSession, _) = try await readyHistorySession()
        let foreignToken = try await foreignSession.beginOperation(.history)
        let chunk = BandHistoryChunk(
            chunkIdentity: "synthetic-chunk",
            previousCursor: nil,
            nextCursor: "cursor-1",
            complete: true,
            overflowed: false,
            acknowledgementToken: "ack-1",
            batches: [
                BandSampleBatch(
                    sourceIdentity: "synthetic-source",
                    lane: .history,
                    parserRevision: "parser-1",
                    calibrationRevision: "calibration-1",
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
                ),
            ]
        )

        var eventCount = await diagnostics.snapshot().count
        do {
            _ = try await session.stageHistoryChunk(
                chunk,
                token: supersededToken,
                callbackGeneration: generation
            )
            XCTFail("Expected superseded stage token rejection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .invalidState)
        } catch {
            XCTFail("Expected a typed history rejection")
        }
        var events = await diagnostics.snapshot()
        XCTAssertEqual(events.count, eventCount + 1)
        XCTAssertEqual(
            events.last,
            BandDiagnosticEvent(
                kind: .history,
                outcome: .rejected,
                failureCategory: .invalidState
            )
        )

        eventCount = events.count
        do {
            _ = try await session.stageHistoryChunk(
                chunk,
                token: foreignToken,
                callbackGeneration: generation
            )
            XCTFail("Expected foreign stage token rejection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .staleCallback)
        } catch {
            XCTFail("Expected a typed history rejection")
        }
        events = await diagnostics.snapshot()
        XCTAssertEqual(events.count, eventCount + 1)
        XCTAssertEqual(
            events.last,
            BandDiagnosticEvent(
                kind: .history,
                outcome: .rejected,
                failureCategory: .staleCallback
            )
        )

        let acceptance = try await session.stageHistoryChunk(
            chunk,
            token: activeToken,
            callbackGeneration: generation
        )
        let receipt = DurableHistoryReceipt(
            acceptance: acceptance,
            historyStateCommitted: true,
            committedSamples: acceptance.acceptedSamples,
            committed: true
        )

        eventCount = await diagnostics.snapshot().count
        do {
            try await session.acknowledgeHistory(
                receipt: receipt,
                token: supersededToken,
                callbackGeneration: generation
            )
            XCTFail("Expected superseded acknowledgement token rejection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .invalidState)
        } catch {
            XCTFail("Expected a typed history rejection")
        }
        events = await diagnostics.snapshot()
        XCTAssertEqual(events.count, eventCount + 1)
        XCTAssertEqual(
            events.last,
            BandDiagnosticEvent(
                kind: .history,
                outcome: .rejected,
                failureCategory: .invalidState
            )
        )

        eventCount = events.count
        do {
            try await session.acknowledgeHistory(
                receipt: receipt,
                token: foreignToken,
                callbackGeneration: generation
            )
            XCTFail("Expected foreign acknowledgement token rejection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .staleCallback)
        } catch {
            XCTFail("Expected a typed history rejection")
        }
        events = await diagnostics.snapshot()
        XCTAssertEqual(events.count, eventCount + 1)
        XCTAssertEqual(
            events.last,
            BandDiagnosticEvent(
                kind: .history,
                outcome: .rejected,
                failureCategory: .staleCallback
            )
        )
        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged.state, .historyCollecting)
        XCTAssertEqual(unchanged.activeOperation, .history)

        try await session.acknowledgeHistory(
            receipt: receipt,
            token: activeToken,
            callbackGeneration: generation
        )
        try await session.completeOperation(activeToken)
    }

    @MainActor
    func testExplicitFactoryCanOwnNonWhoopLifecycle() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(
            store: DeviceRegistryStore(dbQueue: store.registryWriter)
        )
        registry.reload()
        registry.add(
            PairedDevice(
                id: "noop-band-synthetic",
                brand: "NOOP",
                model: "Synthetic",
                peripheralId: nil,
                sourceKind: .liveBLE,
                capabilities: [.hr],
                status: .paired,
                addedAt: 1,
                lastSeenAt: 1
            )
        )

        let source = FakeNoopBandSource()
        var factoryRequests: [String] = []
        var starts = 0
        var stops = 0
        let coordinator = SourceCoordinator(
            registry: registry,
            live: LiveState(),
            storeHandle: { nil },
            startWhoop: { starts += 1 },
            stopWhoop: { stops += 1 },
            setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            noopBandSourceFactory: { id in
                factoryRequests.append(id)
                return source
            }
        )

        coordinator.activeDeviceChanged(to: "noop-band-synthetic")
        XCTAssertEqual(factoryRequests, ["noop-band-synthetic"])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(source.scans, 1)
        XCTAssertTrue(source.connects.isEmpty)

        coordinator.activeDeviceChanged(to: "my-whoop")
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testWhoopDefaultNeverRequestsNoopBandFactory() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(
            store: DeviceRegistryStore(dbQueue: store.registryWriter)
        )
        registry.reload()

        var factoryCalls = 0
        var starts = 0
        var stops = 0
        let coordinator = SourceCoordinator(
            registry: registry,
            live: LiveState(),
            storeHandle: { nil },
            startWhoop: { starts += 1 },
            stopWhoop: { stops += 1 },
            setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            noopBandSourceFactory: { _ in
                factoryCalls += 1
                return FakeNoopBandSource()
            }
        )

        coordinator.activeDeviceChanged(to: "my-whoop")
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
    }
}
