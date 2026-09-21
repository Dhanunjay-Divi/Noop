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

    func testPinnedAppBoundaryCreatesNeutralSession() async throws {
        XCTAssertEqual(
            NoopBandSDKBoundary.pinnedSourceRevision,
            "f2c1e189d6e703ceecea3502e1ba9ea77d8e2bd7"
        )
        let session = NoopBandSDKBoundary.makeSession()
        let generation = try await session.beginScan()
        XCTAssertEqual(generation, 1)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .scanning)
    }

    func testPinnedBoundaryRestoresSourceScopedHistoryCheckpoint() async throws {
        let checkpoint = BandHistoryCheckpoint(
            sourceIdentity: "synthetic-source",
            acknowledgedCursor: "cursor-2",
            lastHistoryComplete: false,
            durableSampleIdentities: []
        )
        let session = NoopBandSDKBoundary.makeSession(
            historyCheckpoint: checkpoint
        )
        _ = try await session.beginScan()
        try await session.selectCandidate(
            BandPairingCandidate(
                handle: "synthetic-candidate",
                compatible: true,
                identifyEligible: true
            )
        )
        let identity = BandIdentity(
            sourceIdentity: checkpoint.sourceIdentity,
            hardwareRevision: "synthetic-hw-1",
            firmwareVersion: "synthetic-fw-1",
            protocolVersion: BandCapabilityReport.supportedProtocolVersion,
            wrapperRevision: "artifact-f2c1e189"
        )
        try await session.connect(identity)
        try await session.acceptCapabilities(
            BandCapabilityReport(
                schemaVersion: BandCapabilityReport.supportedSchemaVersion,
                protocolVersion: identity.protocolVersion,
                hardwareRevision: identity.hardwareRevision,
                firmwareVersion: identity.firmwareVersion,
                historyDays: 7,
                capabilities: [.heartRate]
            )
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
            XCTAssertEqual(error, .historyStalled)
        }
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
