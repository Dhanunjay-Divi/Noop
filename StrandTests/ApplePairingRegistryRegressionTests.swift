import Combine
import GRDB
import XCTest
import WhoopStore
@testable import Strand

final class ApplePairingRegistryRegressionTests: XCTestCase {
    @MainActor
    private final class FakePairingAdapter: VeepooBandAdapterControlling {
        var eventHandler: ((VeepooBandAdapterEvent) -> Void)?
        var state: VeepooBandAdapterState = .idle
        private(set) var disconnectCount = 0
        private(set) var discoveries: [UUID?] = []
        var onDisconnect: (() -> Void)?

        func startDiscovery(targetPeripheralID: UUID?) {
            discoveries.append(targetPeripheralID)
        }
        func stopDiscovery() {}
        func connect(
            candidateHandle: UInt64,
            confirmedPrintedIdentifier: String
        ) {}
        func reconnect(candidateHandle: UInt64) {}
        func disconnect() {
            disconnectCount += 1
            onDisconnect?()
        }
        func verifyPassword(_ password: String) {}
        func startLiveHeartRate() {}
        func stopLiveHeartRate() {}

        func emit(_ event: VeepooBandAdapterEvent) {
            eventHandler?(event)
        }
    }

    @MainActor
    private final class FakeLiveSource: LiveHRSource {
        let id: String
        var onConnect: (() -> Void)?
        var onStop: (() -> Void)?
        private(set) var scans = 0
        private(set) var connects: [UUID] = []
        private(set) var stops = 0

        init(id: String) {
            self.id = id
        }

        func scan() {
            scans += 1
            onConnect?()
        }

        func connect(_ id: UUID) {
            connects.append(id)
            onConnect?()
        }

        func stop() {
            stops += 1
            onStop?()
        }
    }

    @MainActor
    func testTransientCredentialWaitKeepsActiveSupplierAndStartsOnProtectedData()
        async throws
    {
        let (store, registry) = try await makeRegistry()
        let device = supplierDevice(id: "supplier-transient")
        registry.add(device)

        let protectedData = PassthroughSubject<Void, Never>()
        let adapter = FakePairingAdapter()
        var credentialResults: [VeepooCredentialLoadResult] = [
            .unavailable,
            .available("2468"),
        ]
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            credentialLoader: {
                credentialResults.removeFirst()
            },
            protectedDataAvailablePublisher:
                protectedData.eraseToAnyPublisher(),
            credentialRetryDelaysNanoseconds: [],
            onCredentialRejected: {},
            onCredentialPermanentlyUnavailable: {
                XCTFail("Transient secure storage must not be permanent")
            }
        )
        var whoopStops = 0
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [device.id: source],
            stopWhoop: { whoopStops += 1 }
        )
        coordinator.start()

        registry.setActive(device.id)
        await Task.yield()

        XCTAssertEqual(registry.activeDeviceId, device.id)
        XCTAssertEqual(
            try DeviceRegistryStore(
                dbQueue: store.registryWriter
            ).activeDeviceId(),
            device.id
        )
        XCTAssertEqual(whoopStops, 1)
        XCTAssertTrue(adapter.discoveries.isEmpty)

        protectedData.send()
        await Task.yield()

        XCTAssertEqual(adapter.discoveries, [UUID(uuidString: device.peripheralId!)])
        XCTAssertEqual(registry.activeDeviceId, device.id)
        source.stop()
    }

    @MainActor
    func testSynchronousPermanentCredentialFailureRestoresWhoopOwnership()
        async throws
    {
        let (store, registry) = try await makeRegistry()
        let device = supplierDevice(
            id: "supplier-missing-credential",
            status: .paired
        )
        XCTAssertTrue(registry.addAndSetActive(device))

        let adapter = FakePairingAdapter()
        var permanentFailures = 0
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            credentialLoader: { .missing },
            credentialRetryDelaysNanoseconds: [],
            onCredentialRejected: {},
            onCredentialPermanentlyUnavailable: {
                permanentFailures += 1
                XCTAssertTrue(
                    registry.reconcileUnavailableSupplier(device.id)
                )
            }
        )
        var whoopStarts = 0
        var whoopStops = 0
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [device.id: source],
            startWhoop: { whoopStarts += 1 },
            stopWhoop: { whoopStops += 1 }
        )
        coordinator.start()

        XCTAssertEqual(permanentFailures, 1)
        XCTAssertEqual(registry.activeDeviceId, "my-whoop")
        XCTAssertEqual(
            try DeviceRegistryStore(
                dbQueue: store.registryWriter
            ).activeDeviceId(),
            "my-whoop"
        )
        XCTAssertEqual(whoopStops, 1)
        XCTAssertEqual(whoopStarts, 1)
        XCTAssertEqual(adapter.disconnectCount, 2)
        XCTAssertTrue(adapter.discoveries.isEmpty)
    }

    @MainActor
    func testPairingCancelStartsCurrentSupplierOnlyAfterAdapterDisconnect()
        async throws
    {
        let (_, registry) = try await makeRegistry()
        let first = supplierDevice(id: "supplier-first")
        let second = supplierDevice(id: "supplier-second")
        registry.add(first)
        registry.add(second)
        let firstSource = FakeLiveSource(id: first.id)
        let secondSource = FakeLiveSource(id: second.id)
        var events: [String] = []
        secondSource.onConnect = { events.append("second-start") }
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [
                first.id: firstSource,
                second.id: secondSource,
            ]
        )
        coordinator.start()
        registry.setActive(first.id)
        XCTAssertEqual(firstSource.connects.count, 1)

        let adapter = FakePairingAdapter()
        adapter.onDisconnect = { events.append("pairing-disconnect") }
        let session = VeepooBandPairingSession(adapter: adapter)
        var handoff = VeepooPairingTransportHandoff()
        XCTAssertNotNil(
            handoff.begin(
                acquireLease: {
                    coordinator.acquireSupplierPairingLease()
                },
                makeSession: { session },
                cancelLease: {
                    _ = coordinator.cancelSupplierPairingLease($0)
                }
            )
        )
        XCTAssertEqual(firstSource.stops, 1)

        registry.setActive(second.id)
        XCTAssertTrue(secondSource.connects.isEmpty)

        handoff.endPairing(
            cancelPairing: { session.cancel() },
            cancelLease: {
                _ = coordinator.cancelSupplierPairingLease($0)
            }
        )

        XCTAssertEqual(
            events,
            ["pairing-disconnect", "second-start"]
        )
        XCTAssertEqual(secondSource.connects.count, 1)
        XCTAssertEqual(registry.activeDeviceId, second.id)
        XCTAssertNil(handoff.lease)
    }

    @MainActor
    func testPairingCancelDoesNotRestartArchivedSupplier() async throws {
        let (_, registry) = try await makeRegistry()
        let device = supplierDevice(id: "supplier-archived")
        registry.add(device)
        let source = FakeLiveSource(id: device.id)
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [device.id: source]
        )
        coordinator.start()
        registry.setActive(device.id)
        XCTAssertEqual(source.connects.count, 1)

        let lease = try XCTUnwrap(
            coordinator.acquireSupplierPairingLease()
        )
        XCTAssertEqual(source.stops, 1)
        XCTAssertTrue(registry.archive(device.id))

        XCTAssertTrue(coordinator.cancelSupplierPairingLease(lease))
        XCTAssertEqual(source.connects.count, 1)
        XCTAssertEqual(
            registry.devices.first { $0.id == device.id }?.status,
            .archived
        )
    }

    @MainActor
    func testPairingCommitStartsReplacementOnlyAfterPairingRelease()
        async throws
    {
        let (_, registry) = try await makeRegistry()
        let first = supplierDevice(id: "supplier-old")
        let replacement = supplierDevice(
            id: "supplier-new",
            status: .paired
        )
        registry.add(first)
        let firstSource = FakeLiveSource(id: first.id)
        let replacementSource = FakeLiveSource(id: replacement.id)
        var events: [String] = []
        replacementSource.onConnect = {
            events.append("replacement-start")
        }
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [
                first.id: firstSource,
                replacement.id: replacementSource,
            ]
        )
        coordinator.start()
        registry.setActive(first.id)

        let adapter = FakePairingAdapter()
        adapter.onDisconnect = {
            events.append("pairing-disconnect")
        }
        let session = VeepooBandPairingSession(adapter: adapter)
        var handoff = VeepooPairingTransportHandoff()
        XCTAssertNotNil(
            handoff.begin(
                acquireLease: {
                    coordinator.acquireSupplierPairingLease()
                },
                makeSession: { session },
                cancelLease: {
                    _ = coordinator.cancelSupplierPairingLease($0)
                }
            )
        )

        XCTAssertTrue(registry.addAndSetActive(replacement))
        XCTAssertTrue(replacementSource.connects.isEmpty)
        session.cancel()
        XCTAssertTrue(
            handoff.commitReplacement {
                coordinator.commitSupplierPairingLease($0)
            }
        )

        XCTAssertEqual(
            events,
            ["pairing-disconnect", "replacement-start"]
        )
        XCTAssertEqual(replacementSource.connects.count, 1)
        XCTAssertEqual(registry.activeDeviceId, replacement.id)
    }

    @MainActor
    func testStalePairingLeaseCannotReleaseNewerLease() async throws {
        let (_, registry) = try await makeRegistry()
        let device = supplierDevice(id: "supplier-generation")
        registry.add(device)
        let source = FakeLiveSource(id: device.id)
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [device.id: source]
        )
        coordinator.start()
        registry.setActive(device.id)

        let first = try XCTUnwrap(
            coordinator.acquireSupplierPairingLease()
        )
        XCTAssertTrue(coordinator.cancelSupplierPairingLease(first))
        let second = try XCTUnwrap(
            coordinator.acquireSupplierPairingLease()
        )

        XCTAssertFalse(coordinator.commitSupplierPairingLease(first))
        XCTAssertEqual(source.connects.count, 2)
        XCTAssertTrue(coordinator.cancelSupplierPairingLease(second))
        XCTAssertEqual(source.connects.count, 3)
    }

    @MainActor
    func testBatteryFailureDisconnectsBeforeFailedFallbackAndRetries()
        async throws
    {
        let (_, registry) = try await makeRegistry()
        XCTAssertTrue(registry.archive("my-whoop"))
        let device = supplierDevice(id: "supplier-battery")
        registry.add(device)

        let adapter = FakePairingAdapter()
        var disconnectCountAtReconcile: [Int] = []
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            onTerminalBatteryFailure: {
                disconnectCountAtReconcile.append(
                    adapter.disconnectCount
                )
                return registry.reconcileUnavailableSupplier(device.id)
            },
            reconnectDelaysNanoseconds: [0, 0],
            reconnectDiscoveryTimeoutNanoseconds: 1_000_000_000
        )
        let coordinator = makeCoordinator(
            registry: registry,
            sources: [device.id: source]
        )
        coordinator.start()
        registry.setActive(device.id)
        await Task.yield()

        adapter.emit(
            .failed(stage: .battery, failure: .invalidBattery)
        )
        adapter.emit(
            .failed(stage: .battery, failure: .invalidBattery)
        )
        await Task.yield()

        XCTAssertEqual(disconnectCountAtReconcile, [1])
        XCTAssertEqual(registry.activeDeviceId, device.id)
        XCTAssertGreaterThanOrEqual(adapter.discoveries.count, 2)

        adapter.emit(.state(.connected))
        adapter.emit(
            .failed(stage: .battery, failure: .invalidBattery)
        )
        XCTAssertEqual(disconnectCountAtReconcile, [1, 2])
        source.stop()
    }

    @MainActor
    func testArchiveVerificationFailurePreservesDayOwnershipExactly() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = DeviceRegistryStore(
            dbQueue: store.registryWriter
        )
        try persistence.setDayOwner(
            day: "2026-09-22",
            deviceId: "my-whoop",
            locked: true
        )
        try persistence.setDayOwner(
            day: "2026-09-23",
            deviceId: "my-whoop",
            locked: false
        )
        let expectedOwners = [
            "2026-09-22": try XCTUnwrap(
                persistence.dayOwner("2026-09-22")
            ),
            "2026-09-23": try XCTUnwrap(
                persistence.dayOwner("2026-09-23")
            ),
        ]

        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER ignore_device_archive
                BEFORE UPDATE OF status ON pairedDevice
                WHEN OLD.id = 'my-whoop' AND NEW.status = 'archived'
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """)
        }

        let registry = DeviceRegistry(store: persistence)
        registry.reload()

        XCTAssertFalse(registry.archive("my-whoop"))
        XCTAssertEqual(registry.activeDeviceId, "my-whoop")
        XCTAssertEqual(
            try persistence.all().first { $0.id == "my-whoop" }?.status,
            .active
        )
        XCTAssertEqual(
            try persistence.dayOwner("2026-09-22"),
            expectedOwners["2026-09-22"]
        )
        XCTAssertEqual(
            try persistence.dayOwner("2026-09-23"),
            expectedOwners["2026-09-23"]
        )
    }

    @MainActor
    func testAddReturnsFalseWhenDatabaseIgnoresRegistration() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = DeviceRegistryStore(
            dbQueue: store.registryWriter
        )
        let registry = DeviceRegistry(store: persistence)
        registry.reload()
        let device = supplierDevice(
            id: "ignored-registration",
            status: .paired
        )

        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER ignore_device_registration
                BEFORE INSERT ON pairedDevice
                WHEN NEW.id = 'ignored-registration'
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """)
        }

        XCTAssertFalse(registry.add(device))
        XCTAssertFalse(
            registry.devices.contains { $0.id == device.id }
        )
        XCTAssertFalse(
            try persistence.all().contains { $0.id == device.id }
        )
    }

    @MainActor
    func testArchiveOwnershipDeletionFailureRollsBackStatusAndOwners() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = DeviceRegistryStore(
            dbQueue: store.registryWriter
        )
        try persistence.setDayOwner(
            day: "2026-09-24",
            deviceId: "my-whoop",
            locked: true
        )
        let expectedOwner = try XCTUnwrap(
            persistence.dayOwner("2026-09-24")
        )

        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER ignore_day_owner_delete
                BEFORE DELETE ON dayOwnership
                WHEN OLD.deviceId = 'my-whoop'
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """)
        }

        let registry = DeviceRegistry(store: persistence)
        registry.reload()

        XCTAssertFalse(registry.archive("my-whoop"))
        XCTAssertEqual(
            try persistence.all().first { $0.id == "my-whoop" }?.status,
            .active
        )
        XCTAssertEqual(
            try persistence.dayOwner("2026-09-24"),
            expectedOwner
        )
    }

    @MainActor
    func testRearchivingRemovesStaleDayOwnership() async throws {
        let store = try await WhoopStore.inMemory()
        let persistence = DeviceRegistryStore(
            dbQueue: store.registryWriter
        )
        try persistence.archive("my-whoop")
        try persistence.setDayOwner(
            day: "2026-09-24",
            deviceId: "my-whoop",
            locked: true
        )

        XCTAssertNotNil(try persistence.dayOwner("2026-09-24"))
        XCTAssertTrue(try persistence.archiveVerified("my-whoop"))
        XCTAssertNil(try persistence.dayOwner("2026-09-24"))
        XCTAssertEqual(
            try persistence.all().first { $0.id == "my-whoop" }?.status,
            .archived
        )
    }

    @MainActor
    func testSupplierCredentialRegistrationReadFailsClosed() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(
            store: DeviceRegistryStore(dbQueue: store.registryWriter)
        )
        registry.reload()

        try await store.registryWriter.write { db in
            try db.drop(table: "pairedDevice")
        }

        XCTAssertNil(registry.registeredSupplierCredentialDeviceIDs())
    }

    @MainActor
    func testArchivedSupplierDoesNotOwnCredentialRegistration() async throws {
        let (_, registry) = try await makeRegistry()
        let device = supplierDevice(
            id: "supplier-archived-cleanup",
            status: .paired
        )
        registry.add(device)
        XCTAssertTrue(registry.archive(device.id))

        XCTAssertEqual(
            registry.registeredSupplierCredentialDeviceIDs(),
            Set<String>()
        )
    }

    @MainActor
    func testArchivedSupplierRequiresPairingAndRejectsStaleDirectActivation()
        async throws
    {
        let (_, registry) = try await makeRegistry()
        let stalePairedValue = supplierDevice(
            id: "supplier-readd",
            status: .paired
        )
        registry.add(stalePairedValue)
        XCTAssertTrue(registry.archive(stalePairedValue.id))

        let archived = try XCTUnwrap(
            registry.devices.first { $0.id == stalePairedValue.id }
        )
        XCTAssertEqual(
            AppModel.activationRoute(for: archived),
            .supplierPairing
        )
        XCTAssertFalse(
            AppModel.activateDeviceDirectlyIfAllowed(
                stalePairedValue,
                in: registry
            ),
            "A stale pre-removal value must not reactivate a supplier whose credential was cleared."
        )
        XCTAssertNotEqual(registry.activeDeviceId, stalePairedValue.id)
        XCTAssertEqual(
            registry.devices.first { $0.id == stalePairedValue.id }?.status,
            .archived
        )
    }

    @MainActor
    func testPairedSupplierWithCredentialOwnershipRemainsDirectlyActivatable()
        async throws
    {
        let (_, registry) = try await makeRegistry()
        let device = supplierDevice(
            id: "supplier-paired",
            status: .paired
        )
        registry.add(device)

        XCTAssertEqual(AppModel.activationRoute(for: device), .direct)
        XCTAssertTrue(
            AppModel.activateDeviceDirectlyIfAllowed(
                device,
                in: registry
            )
        )
        XCTAssertEqual(registry.activeDeviceId, device.id)
    }

    @MainActor
    func testArchivedWhoopAndOuraRemainDirectlyActivatable() async throws {
        let (_, registry) = try await makeRegistry()
        let devices = [
            PairedDevice(
                id: "whoop-readd",
                brand: "WHOOP",
                model: "5.0 MG",
                peripheralId: UUID().uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr],
                status: .paired,
                addedAt: 1,
                lastSeenAt: 1
            ),
            PairedDevice(
                id: "oura-readd",
                brand: "Oura",
                model: "Oura Ring 4",
                peripheralId: UUID().uuidString,
                sourceKind: .oura,
                capabilities: [.hr, .sleep],
                status: .paired,
                addedAt: 1,
                lastSeenAt: 1
            ),
        ]

        for device in devices {
            XCTAssertTrue(registry.add(device))
            XCTAssertTrue(registry.archive(device.id))

            let archived = try XCTUnwrap(
                registry.devices.first { $0.id == device.id }
            )
            XCTAssertEqual(AppModel.activationRoute(for: archived), .direct)
            XCTAssertTrue(
                AppModel.activateDeviceDirectlyIfAllowed(
                    archived,
                    in: registry
                )
            )
            XCTAssertEqual(registry.activeDeviceId, device.id)
            XCTAssertEqual(
                registry.devices.first { $0.id == device.id }?.status,
                .active
            )
            XCTAssertTrue(registry.archive(device.id))
        }
    }

    @MainActor
    private func makeRegistry() async throws -> (WhoopStore, DeviceRegistry) {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistry(
            store: DeviceRegistryStore(dbQueue: store.registryWriter)
        )
        registry.reload()
        return (store, registry)
    }

    @MainActor
    private func makeCoordinator(
        registry: DeviceRegistry,
        sources: [String: any LiveHRSource],
        startWhoop: @escaping () -> Void = {},
        stopWhoop: @escaping () -> Void = {}
    ) -> SourceCoordinator {
        SourceCoordinator(
            registry: registry,
            live: LiveState(),
            storeHandle: { nil },
            startWhoop: startWhoop,
            stopWhoop: stopWhoop,
            setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID:
                Empty<String?, Never>().eraseToAnyPublisher(),
            noopBandSourceFactory: { sources[$0] }
        )
    }

    private func supplierDevice(
        id: String = "supplier-active",
        status: DeviceStatus = .active
    ) -> PairedDevice {
        PairedDevice(
            id: id,
            brand: "Veepoo-compatible",
            model: "Compatible supplier band",
            peripheralId: UUID().uuidString,
            sourceKind: .veepoo,
            capabilities: [.hr],
            status: status,
            addedAt: 1,
            lastSeenAt: 1
        )
    }
}
