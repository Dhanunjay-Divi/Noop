import Combine
import XCTest
@testable import Strand
import WhoopStore

final class VeepooBandAdapterCoreTests: XCTestCase {
    private static let approvedIdentity = VeepooBandProductIdentity(
        modelCode: "4321",
        hardwareRevision: "HW-1",
        firmwareRevision: "FW-2"
    )

    private static let approvedPolicy: VeepooBandCompatibilityPolicy = {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "approvedBands": [
                {
                  "platform": "apple",
                  "modelCode": "4321",
                  "hardwareRevision": "HW-1",
                  "firmwareRevision": "FW-2",
                  "protocolVersion": "noop-band-v1",
                  "wrapperRevision": "veepoo-apple-display-v1"
                }
              ]
            }
            """.utf8
        )
        return try! VeepooBandCompatibilityPolicy(
            validatingManifestData: data
        )
    }()

    @MainActor
    private final class FakeClient: VeepooBandSDKClient {
        var eventHandler: ((VeepooBandSDKEvent) -> Void)?
        private(set) var discoveries: [(UInt64, UUID?)] = []
        private(set) var stopDiscoveryCount = 0
        private(set) var connections: [(UInt64, UInt64, Bool)] = []
        private(set) var disconnectCount = 0
        private(set) var passwords: [(UInt64, String)] = []
        private(set) var batteryReads: [UInt64] = []
        private(set) var liveStarts: [UInt64] = []
        private(set) var liveStopCount = 0

        func startDiscovery(generation: UInt64, targetPeripheralID: UUID?) {
            discoveries.append((generation, targetPeripheralID))
        }

        func stopDiscovery() { stopDiscoveryCount += 1 }

        func connect(
            generation: UInt64,
            candidateHandle: UInt64,
            requiresUserConfirmation: Bool
        ) {
            connections.append(
                (generation, candidateHandle, requiresUserConfirmation)
            )
        }

        func disconnect() { disconnectCount += 1 }

        func verifyPassword(generation: UInt64, password: String) {
            passwords.append((generation, password))
        }

        func readBattery(generation: UInt64) {
            batteryReads.append(generation)
        }

        func startLiveHeartRate(generation: UInt64) {
            liveStarts.append(generation)
        }

        func stopLiveHeartRate() { liveStopCount += 1 }

        func emit(_ event: VeepooBandSDKEvent) {
            eventHandler?(event)
        }
    }

    @MainActor
    private final class RecordingDiagnostics:
        VeepooBandDiagnosticsRecording
    {
        private(set) var events: [VeepooBandDiagnostic] = []
        func record(_ event: VeepooBandDiagnostic) { events.append(event) }
    }

    @MainActor
    private final class FakeAdapter: VeepooBandAdapterControlling {
        var eventHandler: ((VeepooBandAdapterEvent) -> Void)?
        var state: VeepooBandAdapterState = .idle
        private(set) var liveStartCount = 0
        private(set) var disconnectCount = 0
        private(set) var discoveries: [UUID?] = []
        private(set) var stopDiscoveryCount = 0
        private(set) var connections: [(UInt64, String)] = []
        private(set) var reconnects: [UInt64] = []
        var onDiscovery: (() -> Void)?
        var onStopDiscovery: (() -> Void)?

        func startDiscovery(targetPeripheralID: UUID?) {
            discoveries.append(targetPeripheralID)
            onDiscovery?()
        }
        func stopDiscovery() {
            stopDiscoveryCount += 1
            onStopDiscovery?()
        }
        func connect(
            candidateHandle: UInt64,
            confirmedPrintedIdentifier: String
        ) {
            connections.append(
                (candidateHandle, confirmedPrintedIdentifier)
            )
        }
        func reconnect(candidateHandle: UInt64) {
            reconnects.append(candidateHandle)
        }
        func disconnect() { disconnectCount += 1 }
        func verifyPassword(_ password: String) {}
        func startLiveHeartRate() { liveStartCount += 1 }
        func stopLiveHeartRate() {}

        func emit(_ event: VeepooBandAdapterEvent) {
            eventHandler?(event)
        }
    }

    @MainActor
    private final class FakeCredentials: VeepooCredentialAccess {
        var saveSucceeds = true
        var clearSucceeds = true
        var values: [String: String] = [:]
        private(set) var saveCount = 0
        private(set) var clearCount = 0

        func load(deviceID: String) -> String? {
            values[deviceID]
        }

        func save(_ password: String, deviceID: String) -> Bool {
            saveCount += 1
            guard saveSucceeds else { return false }
            values[deviceID] = password
            return true
        }

        @discardableResult
        func clear(deviceID: String) -> Bool {
            clearCount += 1
            guard clearSucceeds else { return false }
            values.removeValue(forKey: deviceID)
            return true
        }
    }

    @MainActor
    func testFactoryIsDefaultOffWithoutApprovedDeviceBuildFlag() {
        XCTAssertFalse(VeepooBandAdapterFactory.productionEnabled)
        XCTAssertNil(
            VeepooBandAdapterFactory.makeForApprovedLocalDeviceBuild()
        )
    }

    @MainActor
    func testCandidateMustBeExplicitlySelectedAndPrintedIdentifierMustMatch() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        let generation = beginDiscovery(core, client: client)
        let peripheralID = UUID()

        client.emit(
            .candidate(
                generation: generation,
                handle: 42,
                peripheralID: peripheralID,
                printedIdentifier: "AA:BB:12:34"
            )
        )
        XCTAssertTrue(client.connections.isEmpty)

        core.connect(
            candidateHandle: 42,
            confirmedPrintedIdentifier: "AA-BB-9999"
        )
        XCTAssertTrue(client.connections.isEmpty)
        XCTAssertEqual(core.state, .discovering)

        core.connect(
            candidateHandle: 42,
            confirmedPrintedIdentifier: "aabb1234"
        )
        XCTAssertEqual(client.connections.map(\.1), [42])
        XCTAssertEqual(client.connections.map(\.2), [true])
        XCTAssertEqual(core.state, .connecting)
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .identification,
                    outcome: .rejected,
                    failure: .identifierMismatch
                )
            )
        )
    }

    @MainActor
    func testPairingUsesPhysicalConfirmationWithoutPrintedIdentifierMapping() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        let generation = beginDiscovery(core, client: client)

        client.emit(
            .candidate(
                generation: generation,
                handle: 42,
                peripheralID: UUID(),
                printedIdentifier: nil
            )
        )
        core.connect(
            candidateHandle: 42,
            confirmedPrintedIdentifier: "SIDE1234"
        )

        XCTAssertEqual(client.connections.map(\.1), [42])
        XCTAssertEqual(client.connections.map(\.2), [true])
        XCTAssertEqual(core.state, .connecting)
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .identification,
                    outcome: .completed
                )
            )
        )
    }

    @MainActor
    func testPairingSessionImmediatelyStartsPhysicalConfirmationWhenMappingIsAbsent()
        throws
    {
        let adapter = FakeAdapter()
        let session = VeepooBandPairingSession(adapter: adapter)
        session.start()
        let candidate = VeepooBandCandidate(
            handle: 8,
            peripheralID: UUID(),
            printedIdentifier: nil
        )
        adapter.emit(.candidate(candidate))

        session.select(candidate)

        XCTAssertEqual(session.phase, .connecting)
        XCTAssertEqual(adapter.connections.map(\.0), [8])
        XCTAssertEqual(adapter.connections.map(\.1), [""])
    }

    @MainActor
    func testReconnectDisablesUserConfirmationPrompt() {
        let client = FakeClient()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: RecordingDiagnostics()
        )
        let generation = beginDiscovery(core, client: client)
        client.emit(
            .candidate(
                generation: generation,
                handle: 9,
                peripheralID: UUID(),
                printedIdentifier: "SIDE1234"
            )
        )

        core.reconnect(candidateHandle: 9)

        XCTAssertEqual(client.connections.map(\.1), [9])
        XCTAssertEqual(client.connections.map(\.2), [false])
    }

    @MainActor
    func testPasswordRequiresFourASCIIDigits() {
        XCTAssertTrue(VeepooBandAdapterCore.isValidPassword("0007"))
        XCTAssertFalse(VeepooBandAdapterCore.isValidPassword("123"))
        XCTAssertFalse(VeepooBandAdapterCore.isValidPassword("12x4"))
        XCTAssertFalse(VeepooBandAdapterCore.isValidPassword("１２３４"))
        XCTAssertFalse(VeepooBandAdapterCore.isValidPassword("١٢٣٤"))
    }

    @MainActor
    func testBatteryReadIsSerializedBeforeLiveHeartRateCanStart() {
        let client = FakeClient()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: RecordingDiagnostics()
        )
        let generation = connect(core, client: client)

        core.verifyPassword("2468")
        client.emit(
            .password(
                generation: generation,
                .verified(Self.approvedIdentity)
            )
        )

        XCTAssertEqual(core.state, .readingBattery)
        XCTAssertEqual(client.batteryReads, [generation])
        core.startLiveHeartRate()
        XCTAssertTrue(client.liveStarts.isEmpty)

        client.emit(
            .battery(
                generation: generation,
                .init(
                    isPercent: true,
                    chargeState: .charging,
                    isLow: false,
                    value: 82
                )
            )
        )
        XCTAssertEqual(core.state, .ready)
        core.startLiveHeartRate()
        XCTAssertEqual(client.liveStarts, [generation])
    }

    @MainActor
    func testUnknownProductTupleIsRejectedBeforeAuthenticationAndBattery() {
        let identities = [
            VeepooBandProductIdentity(
                modelCode: "9999",
                hardwareRevision: Self.approvedIdentity.hardwareRevision,
                firmwareRevision: Self.approvedIdentity.firmwareRevision
            ),
            VeepooBandProductIdentity(
                modelCode: Self.approvedIdentity.modelCode,
                hardwareRevision: "HW-9",
                firmwareRevision: Self.approvedIdentity.firmwareRevision
            ),
            VeepooBandProductIdentity(
                modelCode: Self.approvedIdentity.modelCode,
                hardwareRevision: Self.approvedIdentity.hardwareRevision,
                firmwareRevision: "FW-9"
            ),
        ]

        for identity in identities {
            let client = FakeClient()
            let diagnostics = RecordingDiagnostics()
            let core = VeepooBandAdapterCore(
                client: client,
                compatibilityPolicy: Self.approvedPolicy,
                diagnostics: diagnostics
            )
            var events: [VeepooBandAdapterEvent] = []
            core.eventHandler = { events.append($0) }
            let generation = connect(core, client: client)

            core.verifyPassword("2468")
            client.emit(
                .password(generation: generation, .verified(identity))
            )

            XCTAssertEqual(core.state, .failed(.unsupported))
            XCTAssertTrue(client.batteryReads.isEmpty)
            XCTAssertFalse(
                events.contains {
                    if case .authenticated = $0 { return true }
                    return false
                }
            )
            XCTAssertTrue(
                diagnostics.events.contains(
                    .init(
                        stage: .compatibility,
                        outcome: .failed,
                        failure: .unsupported
                    )
                )
            )
        }
    }

    @MainActor
    func testBlankProductIdentityIsRejectedBeforeAuthenticationAndBattery() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }
        let generation = connect(core, client: client)

        core.verifyPassword("2468")
        client.emit(
            .password(
                generation: generation,
                .verified(
                    .init(
                        modelCode: "",
                        hardwareRevision: "HW-1",
                        firmwareRevision: "FW-2"
                    )
                )
            )
        )

        XCTAssertEqual(core.state, .failed(.invalidIdentity))
        XCTAssertTrue(client.batteryReads.isEmpty)
        XCTAssertFalse(
            events.contains {
                if case .authenticated = $0 { return true }
                return false
            }
        )
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .compatibility,
                    outcome: .failed,
                    failure: .invalidIdentity
                )
            )
        )
    }

    @MainActor
    func testReconnectFirmwareDriftCannotPromoteBatteryOrLiveState() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }
        let firstGeneration = ready(core, client: client)
        XCTAssertEqual(client.batteryReads, [firstGeneration])

        core.disconnect()
        let reconnectGeneration = beginDiscovery(core, client: client)
        client.emit(
            .candidate(
                generation: reconnectGeneration,
                handle: 2,
                peripheralID: UUID(),
                printedIdentifier: nil
            )
        )
        core.reconnect(candidateHandle: 2)
        client.emit(
            .connection(generation: reconnectGeneration, .connected)
        )
        core.verifyPassword("2468")
        client.emit(
            .password(
                generation: reconnectGeneration,
                .verified(
                    .init(
                        modelCode: Self.approvedIdentity.modelCode,
                        hardwareRevision:
                            Self.approvedIdentity.hardwareRevision,
                        firmwareRevision: "FW-DRIFT"
                    )
                )
            )
        )

        XCTAssertEqual(core.state, .failed(.unsupported))
        XCTAssertEqual(client.batteryReads, [firstGeneration])
        XCTAssertEqual(
            events.filter {
                if case .authenticated = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertTrue(client.liveStarts.isEmpty)
    }

    @MainActor
    func testBatteryScaleIsNotInvented() {
        XCTAssertEqual(
            VeepooBandAdapterCore.normalizeBattery(
                .init(
                    isPercent: true,
                    chargeState: .charging,
                    isLow: false,
                    value: 82
                )
            ),
            .init(percent: 82, level: nil, charging: true, low: false)
        )
        XCTAssertEqual(
            VeepooBandAdapterCore.normalizeBattery(
                .init(
                    isPercent: false,
                    chargeState: .full,
                    isLow: false,
                    value: 3
                )
            ),
            .init(percent: nil, level: 3, charging: nil, low: nil)
        )
        XCTAssertNil(
            VeepooBandAdapterCore.normalizeBattery(
                .init(
                    isPercent: false,
                    chargeState: .normal,
                    isLow: false,
                    value: 5
                )
            )
        )
    }

    @MainActor
    func testLiveHeartRatePreservesPhoneReceiptTimeAndBoundsInvalidSamples() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }
        let generation = ready(core, client: client)
        let receivedAt = Date()

        core.startLiveHeartRate()
        client.emit(.live(generation: generation, .started))
        client.emit(
            .live(
                generation: generation,
                .sample(bpm: 0, receivedAt: receivedAt)
            )
        )
        client.emit(
            .live(
                generation: generation,
                .sample(bpm: 72, receivedAt: receivedAt)
            )
        )

        XCTAssertTrue(
            events.contains(
                .heartRate(.init(bpm: 72, receivedAt: receivedAt))
            )
        )
        XCTAssertEqual(
            diagnostics.events.filter {
                $0.stage == .live
                    && $0.outcome == .rejected
                    && $0.failure == .invalidSample
            }.count,
            1
        )
    }

    @MainActor
    func testSourcePublishesSupplierHeartRateOnlyToDisplayLane() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )
        let receivedAt = Date()
        var acceptedSamples = 0
        let cancellable = live.heartRateSamplePublisher.sink { _ in
            acceptedSamples += 1
        }

        adapter.emit(
            .battery(
                .init(
                    percent: 80,
                    level: nil,
                    charging: nil,
                    low: nil
                )
            )
        )
        adapter.emit(
            .heartRate(.init(bpm: 72, receivedAt: receivedAt))
        )

        XCTAssertEqual(adapter.liveStartCount, 1)
        XCTAssertEqual(live.displayOnlyHeartRate, 72)
        XCTAssertEqual(live.displayOnlyHeartRateReceivedAt, receivedAt)
        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.heartRateSample)
        XCTAssertEqual(live.heartRateSampleSequence, 0)
        XCTAssertEqual(acceptedSamples, 0)
        withExtendedLifetime(cancellable) {}
        source.stop()
        XCTAssertNil(live.displayOnlyHeartRate)
        XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
    }

    @MainActor
    func testSourceClearsDisplayHeartRateWhenLiveStreamStops() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )
        adapter.emit(.heartRate(.init(bpm: 72, receivedAt: Date())))
        XCTAssertEqual(live.displayOnlyHeartRate, 72)
        XCTAssertTrue(live.connected)

        adapter.emit(.liveStopped)

        XCTAssertNil(live.displayOnlyHeartRate)
        XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
        XCTAssertFalse(live.connected)
        source.stop()
    }

    @MainActor
    func testSourcePublishesNonStreamingStateWhenLiveStreamFails() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )
        adapter.emit(.heartRate(.init(bpm: 72, receivedAt: Date())))
        XCTAssertTrue(live.connected)

        adapter.emit(.failed(stage: .live, failure: .notWorn))

        XCTAssertNil(live.displayOnlyHeartRate)
        XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
        XCTAssertFalse(live.connected)
        source.stop()
    }

    @MainActor
    func testSupplierRegistrationUsabilityRequiresRuntimeAndCredential() {
        let credentials = FakeCredentials()
        let device = PairedDevice(
            id: "supplier-band",
            brand: "Supplier",
            model: "Test",
            peripheralId: UUID().uuidString,
            sourceKind: .veepoo,
            capabilities: [.hr],
            status: .active,
            addedAt: 1,
            lastSeenAt: 1
        )

        XCTAssertFalse(
            VeepooBandSourceFactory.hasUsableRegistration(
                for: device,
                credentials: credentials,
                adapterAvailable: true
            )
        )
        credentials.values[device.id] = "2468"
        XCTAssertTrue(
            VeepooBandSourceFactory.hasUsableRegistration(
                for: device,
                credentials: credentials,
                adapterAvailable: true
            )
        )
        XCTAssertFalse(
            VeepooBandSourceFactory.hasUsableRegistration(
                for: device,
                credentials: credentials,
                adapterAvailable: false
            )
        )
        credentials.values[device.id] = "12x4"
        XCTAssertFalse(
            VeepooBandSourceFactory.hasUsableRegistration(
                for: device,
                credentials: credentials,
                adapterAvailable: true
            )
        )
    }

    @MainActor
    func testSupplierDisplayHeartRateExpiresAfterThirtySecondPolicy() async {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            displayFreshnessInterval: 0.02
        )
        adapter.emit(.heartRate(.init(bpm: 72, receivedAt: Date())))
        XCTAssertEqual(live.displayOnlyHeartRate, 72)

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(live.displayOnlyHeartRate)
        XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
        source.stop()
    }

    @MainActor
    func testSupplierDisplayFreshnessRejectsFutureAndExpiredTimestamps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            VeepooBandSource.freshnessRemaining(
                receivedAt: now.addingTimeInterval(-30),
                now: now
            ),
            0
        )
        XCTAssertNil(
            VeepooBandSource.freshnessRemaining(
                receivedAt: now.addingTimeInterval(-30.001),
                now: now
            )
        )
        XCTAssertNil(
            VeepooBandSource.freshnessRemaining(
                receivedAt: now.addingTimeInterval(0.001),
                now: now
            )
        )
    }

    @MainActor
    func testReconnectDiscoveryTimesOutAndStopsAfterBoundedAttempts() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            reconnectDelaysNanoseconds: [0, 0, 0],
            reconnectDiscoveryTimeoutNanoseconds: 0
        )
        source.connect(UUID())
        adapter.emit(.disconnected)

        for _ in 0..<100 {
            if adapter.discoveries.count == 4,
               adapter.stopDiscoveryCount == 3
            {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(adapter.discoveries.count, 4)
        XCTAssertEqual(adapter.stopDiscoveryCount, 3)
        source.stop()
    }

    @MainActor
    func testCredentialRejectionDisconnectsBeforeReconciliation() {
        let adapter = FakeAdapter()
        var disconnectCountAtReconciliation = 0
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {
                disconnectCountAtReconciliation = adapter.disconnectCount
            }
        )

        adapter.emit(
            .failed(
                stage: .authentication,
                failure: .credentialRejected
            )
        )

        XCTAssertEqual(disconnectCountAtReconciliation, 1)
        source.stop()
    }

    @MainActor
    func testFailedRegistrationClearsSavedCredentialAndStaysFailed() throws {
        let credentials = FakeCredentials()
        let (session, client) = try readyPairingSession(
            credentials: credentials
        )
        var registryCalls = 0

        let committed = session.commitPairedDevice(nickname: "Supplier") { _ in
            registryCalls += 1
            return false
        }

        XCTAssertFalse(committed)
        XCTAssertEqual(registryCalls, 1)
        XCTAssertEqual(credentials.saveCount, 1)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertTrue(session.registrationFailed)
        XCTAssertEqual(session.phase, .failed(.internalFailure))
        XCTAssertGreaterThan(client.disconnectCount, 0)
    }

    @MainActor
    func testSecureStorageFailureNeverMutatesRegistry() throws {
        let credentials = FakeCredentials()
        credentials.saveSucceeds = false
        let (session, client) = try readyPairingSession(
            credentials: credentials
        )
        var registryCalls = 0

        let committed = session.commitPairedDevice(nickname: nil) { _ in
            registryCalls += 1
            return true
        }

        XCTAssertFalse(committed)
        XCTAssertEqual(registryCalls, 0)
        XCTAssertEqual(credentials.saveCount, 1)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertTrue(session.registrationFailed)
        XCTAssertGreaterThan(client.disconnectCount, 0)
    }

    @MainActor
    func testSupplierRemovalRequiresCredentialCleanupBeforeArchive() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        credentials.clearSucceeds = false
        var archiveCalls = 0

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials
        ) {
            archiveCalls += 1
            return true
        }

        XCTAssertFalse(removed)
        XCTAssertEqual(archiveCalls, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
    }

    @MainActor
    func testSupplierRemovalRestoresCredentialWhenArchiveFails() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            archive: { false }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertEqual(credentials.values["supplier"], "2468")
    }

    @MainActor
    func testSupplierRemovalLeavesNoCredentialAfterVerifiedArchive() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            archive: { true }
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertNil(credentials.values["supplier"])
    }

    @MainActor
    func testSuccessfulRegistrationDisconnectsPairingOwnerBeforePublication()
        throws
    {
        let credentials = FakeCredentials()
        let (session, client) = try readyPairingSession(
            credentials: credentials
        )
        var disconnectCountAtPublication = 0

        let committed = session.commitPairedDevice(nickname: nil) { _ in
            disconnectCountAtPublication = client.disconnectCount
            return true
        }

        XCTAssertTrue(committed)
        XCTAssertEqual(disconnectCountAtPublication, 1)
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(session.phase, .idle)
    }

    @MainActor
    func testDisconnectInvalidatesLateCallbacksAndReconnectCanStartFresh() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }
        let generation = ready(core, client: client)

        core.disconnect()
        core.startDiscovery(targetPeripheralID: UUID())
        client.emit(
            .live(
                generation: generation,
                .sample(
                    bpm: 72,
                    receivedAt: Date(timeIntervalSince1970: 1)
                )
            )
        )

        XCTAssertFalse(
            events.contains {
                if case .heartRate = $0 { return true }
                return false
            }
        )
        XCTAssertEqual(client.discoveries.count, 2)
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .live,
                    outcome: .stale,
                    failure: .staleCallback
                )
            )
        )
    }

    @MainActor
    private func readyPairingSession(
        credentials: FakeCredentials
    ) throws -> (VeepooBandPairingSession, FakeClient) {
        let client = FakeClient()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: RecordingDiagnostics()
        )
        let session = VeepooBandPairingSession(
            adapter: core,
            credentials: credentials
        )
        session.start()
        let generation = try XCTUnwrap(client.discoveries.last?.0)
        client.emit(
            .candidate(
                generation: generation,
                handle: 7,
                peripheralID: UUID(),
                printedIdentifier: "AA:BB:12:34"
            )
        )
        let candidate = try XCTUnwrap(session.candidates.first)
        session.select(candidate)
        session.confirmPrintedIdentifier("AABB1234")
        client.emit(.connection(generation: generation, .connected))
        session.submitPassword("2468")
        client.emit(
            .password(
                generation: generation,
                .verified(Self.approvedIdentity)
            )
        )
        client.emit(
            .battery(
                generation: generation,
                .init(
                    isPercent: true,
                    chargeState: .normal,
                    isLow: false,
                    value: 80
                )
            )
        )
        client.emit(.live(generation: generation, .started))
        client.emit(
            .live(
                generation: generation,
                .sample(
                    bpm: 72,
                    receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        XCTAssertEqual(session.phase, .ready)
        return (session, client)
    }

    @MainActor
    private func beginDiscovery(
        _ core: VeepooBandAdapterCore,
        client: FakeClient
    ) -> UInt64 {
        core.startDiscovery(targetPeripheralID: nil)
        return try! XCTUnwrap(client.discoveries.last?.0)
    }

    @MainActor
    private func connect(
        _ core: VeepooBandAdapterCore,
        client: FakeClient
    ) -> UInt64 {
        let generation = beginDiscovery(core, client: client)
        client.emit(
            .candidate(
                generation: generation,
                handle: 1,
                peripheralID: UUID(),
                printedIdentifier: "AA:BB:12:34"
            )
        )
        core.connect(
            candidateHandle: 1,
            confirmedPrintedIdentifier: "AABB1234"
        )
        client.emit(.connection(generation: generation, .connected))
        XCTAssertEqual(core.state, .connected)
        return generation
    }

    @MainActor
    private func ready(
        _ core: VeepooBandAdapterCore,
        client: FakeClient
    ) -> UInt64 {
        let generation = connect(core, client: client)
        core.verifyPassword("2468")
        client.emit(
            .password(
                generation: generation,
                .verified(Self.approvedIdentity)
            )
        )
        client.emit(
            .battery(
                generation: generation,
                .init(
                    isPercent: true,
                    chargeState: .normal,
                    isLow: false,
                    value: 80
                )
            )
        )
        XCTAssertEqual(core.state, .ready)
        return generation
    }
}
