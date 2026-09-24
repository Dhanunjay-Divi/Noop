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

    private func capabilityReport(
        schemaVersion: Int,
        protocolVersion: String,
        hardwareRevision: String,
        firmwareVersion: String,
        historyDays: Int,
        capabilities: Set<BandCapability>,
        liveStreams: Set<BandStreamKind>,
        historyStreams: Set<BandStreamKind>
    ) -> BandCapabilityReport {
        func semantics(
            lane: BandProvenanceLane,
            stream: BandStreamKind
        ) -> BandStreamSemantics {
            let unit: BandUnit
            switch stream {
            case .heartRate:
                unit = .beatsPerMinute
            case .rrInterval:
                unit = .milliseconds
            case .steps:
                unit = .count
            case .spo2:
                unit = .percent
            case .respiration:
                unit = .breathsPerMinute
            case .temperature:
                unit = .celsius
            case .acceleration:
                unit = .gravity
            }

            let cadence: BandCadenceKind
            let nominalIntervalMilliseconds: Int?
            switch stream {
            case .rrInterval:
                cadence = .eventDriven
                nominalIntervalMilliseconds = nil
            case .steps:
                cadence = .aggregateWindow
                nominalIntervalMilliseconds = 60_000
            case .acceleration:
                cadence = .periodic
                nominalIntervalMilliseconds = 40
            default:
                cadence = .periodic
                nominalIntervalMilliseconds = stream == .heartRate
                    ? 1_000
                    : 60_000
            }

            return BandStreamSemantics(
                lane: lane,
                stream: stream,
                unit: unit,
                cadence: cadence,
                nominalIntervalMilliseconds: nominalIntervalMilliseconds,
                quality: .acceptedOrDegraded,
                timestamp: .deviceMilliseconds,
                parserRevision: "parser-v1",
                calibrationRevision: "calibration-v1"
            )
        }

        return BandCapabilityReport(
            schemaVersion: schemaVersion,
            reportRevision: "virtual-report-v1",
            protocolVersion: protocolVersion,
            hardwareRevision: hardwareRevision,
            firmwareVersion: firmwareVersion,
            historyDays: historyDays,
            capabilities: capabilities,
            liveStreams: liveStreams,
            historyStreams: historyStreams,
            operationsAllowedDuringLive: Set(
                BandOperationClass.allCases.filter { $0 != .firmware }
            ),
            streamSemantics: liveStreams.map {
                semantics(lane: .live, stream: $0)
            } + historyStreams.map {
                semantics(lane: .history, stream: $0)
            }
        )
    }

    private func readyHistorySession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        report: BandCapabilityReport? = nil
    ) async throws -> (
        BandSessionMachine,
        UInt64,
        BandConnectionToken
    ) {
        let session = NoopBandSDKBoundary.makeSession(diagnostics: diagnostics)
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
        let identity = BandIdentity(
            sourceIdentity: "synthetic-source",
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-823930f"
        )
        try await completeConnection(
            session,
            identity: identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            report ?? capabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate],
                liveStreams: [.heartRate],
                historyStreams: [.heartRate]
            ),
            token: connectionToken,
            callbackGeneration: generation
        )
        return (session, generation, connectionToken)
    }

    func testPinnedAppBoundaryCreatesNeutralSession() async throws {
        XCTAssertEqual(
            NoopBandSDKBoundary.pinnedSourceRevision,
            "b02808372b7c537f22058c7ebc75d92c750373be"
        )
        let session = NoopBandSDKBoundary.makeSession()
        let scanToken = try await session.beginScan()
        XCTAssertEqual(scanToken.generation, 1)
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
        let identity = BandIdentity(
            sourceIdentity: checkpoint.sourceIdentity,
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-823930f"
        )
        try await completeConnection(
            session,
            identity: identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            capabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate],
                liveStreams: [.heartRate],
                historyStreams: [.heartRate]
            ),
            token: connectionToken,
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
                    failureCategory: .storage,
                    operationClass: .history
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
        let identity = BandIdentity(
            sourceIdentity: "synthetic-source",
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-823930f"
        )
        try await completeConnection(
            session,
            identity: identity,
            token: connectionToken,
            callbackGeneration: generation
        )
        try await session.acceptCapabilities(
            capabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.battery],
                liveStreams: [],
                historyStreams: []
            ),
            token: connectionToken,
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
                    failureCategory: .disconnected,
                    operationClass: .battery
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
        let (session, generation, _) = try await readyHistorySession(
            diagnostics: diagnostics
        )
        let supersededToken = try await session.beginOperation(.history)
        try await session.cancelOperation(supersededToken)
        let activeToken = try await session.beginOperation(.history)
        let (foreignSession, _, _) = try await readyHistorySession()
        let foreignToken = try await foreignSession.beginOperation(.history)
        let chunk = BandHistoryChunk(
            chunkIdentity: "synthetic-chunk",
            previousCursor: nil,
            nextCursor: "cursor-1",
            complete: true,
            overflowed: false,
            retainedRange: nil,
            firstLostRange: nil,
            acknowledgementToken: "ack-1",
            batches: [
                BandSampleBatch(
                    sourceIdentity: "synthetic-source",
                    lane: .history,
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
            committedSamples: acceptance.acceptedSamples.count,
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

    func testPendingLiveReceiptDefersEstablishedAuthenticationFailure()
        async throws
    {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation, connectionToken) =
            try await readyHistorySession(
            diagnostics: diagnostics
        )
        let liveToken = try await session.beginLive()
        let acceptance = try await session.stageLiveBatch(
            liveBatch(sequence: 30),
            token: liveToken,
            callbackGeneration: generation
        )

        do {
            try await session.failEstablishedSession(
                .authentication,
                token: connectionToken,
                callbackGeneration: generation
            )
            XCTFail("Pending persistence must defer session invalidation")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .busy)
        }
        let pending = await session.snapshot()
        XCTAssertEqual(pending.state, .liveCollecting)
        XCTAssertEqual(pending.generation, generation)
        XCTAssertTrue(pending.liveActive)
        let pendingEvents = await diagnostics.snapshot()
        XCTAssertEqual(
            pendingEvents.last,
            BandDiagnosticEvent(
                kind: .authentication,
                outcome: .rejected,
                failureCategory: .busy
            )
        )

        try await session.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: acceptance,
                committedSamples: acceptance.acceptedSamples.count,
                committed: true
            ),
            callbackGeneration: generation
        )
        try await session.failEstablishedSession(
            .authentication,
            token: connectionToken,
            callbackGeneration: generation
        )
        let rejected = await session.snapshot()
        XCTAssertEqual(rejected.state, .rejected)
    }

    func testRestartedLiveCollectionRejectsPriorSameSessionToken()
        async throws
    {
        let diagnostics = BandDiagnosticsRecorder()
        let (session, generation, _) = try await readyHistorySession(
            diagnostics: diagnostics
        )
        let priorToken = try await session.beginLive()
        try await session.stopLive(token: priorToken)
        let currentToken = try await session.beginLive()

        do {
            _ = try await session.stageLiveBatch(
                liveBatch(sequence: 31),
                token: priorToken,
                callbackGeneration: generation
            )
            XCTFail("A prior live token must not authorize restarted collection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .staleCallback)
        }
        let events = await diagnostics.snapshot()
        XCTAssertEqual(
            events.last,
            BandDiagnosticEvent(
                kind: .live,
                outcome: .stale,
                failureCategory: .staleCallback
            )
        )

        let acceptance = try await session.stageLiveBatch(
            liveBatch(sequence: 31),
            token: currentToken,
            callbackGeneration: generation
        )
        try await session.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: acceptance,
                committedSamples: acceptance.acceptedSamples.count,
                committed: true
            ),
            callbackGeneration: generation
        )
        try await session.stopLive(token: currentToken)
    }

    func testLiveAndHistoryStreamsAreAuthorizedIndependently() async throws {
        let historyOnly = capabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            historyDays: 7,
            capabilities: [.heartRate],
            liveStreams: [],
            historyStreams: [.heartRate]
        )
        let (historySession, historyGeneration, _) =
            try await readyHistorySession(report: historyOnly)
        do {
            _ = try await historySession.beginLive()
            XCTFail("A history-only stream must not authorize live delivery")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .unsupported)
        }
        let historyToken = try await historySession.beginOperation(.history)
        let historyAcceptance = try await historySession.stageHistoryChunk(
            historyChunk(),
            token: historyToken,
            callbackGeneration: historyGeneration
        )
        try await historySession.acknowledgeHistory(
            receipt: DurableHistoryReceipt(
                acceptance: historyAcceptance,
                historyStateCommitted: true,
                committedSamples: historyAcceptance.acceptedSamples.count,
                committed: true
            ),
            token: historyToken,
            callbackGeneration: historyGeneration
        )
        try await historySession.completeOperation(historyToken)

        let liveOnly = capabilityReport(
            schemaVersion: BandCapabilityReport.supportedSchemaVersion,
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            historyDays: 7,
            capabilities: [.heartRate],
            liveStreams: [.heartRate],
            historyStreams: []
        )
        let (liveSession, liveGeneration, _) =
            try await readyHistorySession(report: liveOnly)
        let liveToken = try await liveSession.beginLive()
        let liveAcceptance = try await liveSession.stageLiveBatch(
            liveBatch(sequence: 31),
            token: liveToken,
            callbackGeneration: liveGeneration
        )
        try await liveSession.acknowledgeLive(
            receipt: DurableLiveReceipt(
                acceptance: liveAcceptance,
                committedSamples: liveAcceptance.acceptedSamples.count,
                committed: true
            ),
            callbackGeneration: liveGeneration
        )
        try await liveSession.stopLive(token: liveToken)
        do {
            _ = try await liveSession.beginOperation(.history)
            XCTFail("A live-only stream must not authorize history collection")
        } catch let failure as BandFailureCategory {
            XCTAssertEqual(failure, .unsupported)
        }
    }

    func testOverflowRangesSurviveThePublicDurableReceiptBoundary()
        async throws
    {
        let retained = BandHistoryRange(
            startDeviceTimeMilliseconds: 40_000,
            endDeviceTimeMilliseconds: 49_999
        )
        let firstLost = BandHistoryRange(
            startDeviceTimeMilliseconds: 30_000,
            endDeviceTimeMilliseconds: 39_999
        )
        let (session, generation, _) = try await readyHistorySession()
        let token = try await session.beginOperation(.history)
        let acceptance = try await session.stageHistoryChunk(
            historyChunk(
                overflowed: true,
                retainedRange: retained,
                firstLostRange: firstLost
            ),
            token: token,
            callbackGeneration: generation
        )
        XCTAssertEqual(acceptance.retainedRange, retained)
        XCTAssertEqual(acceptance.firstLostRange, firstLost)

        let receipt = DurableHistoryReceipt(
            acceptance: acceptance,
            historyStateCommitted: true,
            committedSamples: acceptance.acceptedSamples.count,
            committed: true
        )
        XCTAssertEqual(receipt.retainedRange, retained)
        XCTAssertEqual(receipt.firstLostRange, firstLost)
        try await session.acknowledgeHistory(
            receipt: receipt,
            token: token,
            callbackGeneration: generation
        )
        try await session.completeOperation(token)
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
                sourceKind: .veepoo,
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

    @MainActor
    func testUnavailableSupplierFactoryDoesNotPauseWhoop() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(
            store: DeviceRegistryStore(dbQueue: store.registryWriter)
        )
        registry.reload()
        registry.add(
            PairedDevice(
                id: "veepoo-unavailable",
                brand: "Veepoo-compatible",
                model: "Compatible supplier band",
                peripheralId: UUID().uuidString,
                sourceKind: .veepoo,
                capabilities: [.hr],
                status: .paired,
                addedAt: 1,
                lastSeenAt: 1
            )
        )

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
            connectedPeripheralUUID:
                Empty<String?, Never>().eraseToAnyPublisher(),
            noopBandSourceFactory: { _ in nil }
        )

        coordinator.activeDeviceChanged(to: "veepoo-unavailable")
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
    }

    private func liveBatch(sequence: UInt64) -> BandSampleBatch {
        BandSampleBatch(
            sourceIdentity: "synthetic-source",
            lane: .live,
            parserRevision: "parser-v1",
            calibrationRevision: "calibration-v1",
            samples: [
                BandSample(
                    identity: BandSampleIdentity(
                        stream: .heartRate,
                        sequence: sequence,
                        deviceTimeMilliseconds: Int64(sequence) * 1_000
                    ),
                    value: 72,
                    unit: .beatsPerMinute,
                    quality: .accepted
                ),
            ]
        )
    }

    private func historyChunk(
        overflowed: Bool = false,
        retainedRange: BandHistoryRange? = nil,
        firstLostRange: BandHistoryRange? = nil
    ) -> BandHistoryChunk {
        BandHistoryChunk(
            chunkIdentity: "synthetic-chunk-\(overflowed)",
            previousCursor: nil,
            nextCursor: "cursor-\(overflowed)",
            complete: true,
            overflowed: overflowed,
            retainedRange: retainedRange,
            firstLostRange: firstLostRange,
            acknowledgementToken: "ack-\(overflowed)",
            batches: [
                BandSampleBatch(
                    sourceIdentity: "synthetic-source",
                    lane: .history,
                    parserRevision: "parser-v1",
                    calibrationRevision: "calibration-v1",
                    samples: [
                        BandSample(
                            identity: BandSampleIdentity(
                                stream: .heartRate,
                                sequence: overflowed ? 41 : 40,
                                deviceTimeMilliseconds: overflowed
                                    ? 41_000
                                    : 40_000
                            ),
                            value: 70,
                            unit: .beatsPerMinute,
                            quality: .accepted
                        ),
                    ]
                ),
            ]
        )
    }
}
