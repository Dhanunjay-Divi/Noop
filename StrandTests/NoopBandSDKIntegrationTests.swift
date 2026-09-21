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
            "0abd9a3ce4f808b51bdc93ad28504ac810914631"
        )
        let session = NoopBandSDKBoundary.makeSession()
        let generation = try await session.beginScan()
        XCTAssertEqual(generation, 1)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .scanning)
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
