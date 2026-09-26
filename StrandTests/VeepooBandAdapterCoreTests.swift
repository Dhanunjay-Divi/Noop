import Combine
import Security
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
        var onDisconnect: (() -> Void)?

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
        func disconnect() {
            disconnectCount += 1
            onDisconnect?()
        }
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
        var saveMutatesBeforeFailure = false
        var clearSucceeds = true
        var values: [String: String] = [:]
        var loadOverride: VeepooCredentialLoadResult?
        private(set) var saveCount = 0
        private(set) var clearCount = 0

        func load(deviceID: String) -> VeepooCredentialLoadResult {
            if let loadOverride { return loadOverride }
            return values[deviceID].map(VeepooCredentialLoadResult.available)
                ?? .missing
        }

        func save(_ password: String, deviceID: String) -> Bool {
            saveCount += 1
            if saveMutatesBeforeFailure {
                values[deviceID] = password
                return false
            }
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
    private final class FakeCredentialCleanup:
        VeepooCredentialCleanupAccess
    {
        var pending = Set<String>()
        var readsAvailable = true
        var readCount = 0
        var markSucceeds = true
        var clearSucceeds = true

        func markPending(deviceID: String) -> Bool {
            guard markSucceeds else { return false }
            pending.insert(deviceID)
            return true
        }

        func pendingDeviceIDs() -> Set<String>? {
            readCount += 1
            return readsAvailable ? pending : nil
        }

        @discardableResult
        func clearPending(deviceID: String) -> Bool {
            guard clearSucceeds else { return false }
            pending.remove(deviceID)
            return true
        }
    }

    @MainActor
    private final class FakeCredentialCleanupKeychain {
        var accounts = Set<String>()
        var forcedRows: [[String: Any]]?

        func makeStore() -> VeepooCredentialCleanupStore {
            VeepooCredentialCleanupStore(
                copyMatching: { [weak self] _, result in
                    guard let self else { return errSecNotAvailable }
                    let rows = self.forcedRows
                        ?? self.accounts.sorted().map {
                            [kSecAttrAccount as String: $0]
                        }
                    guard !rows.isEmpty else { return errSecItemNotFound }
                    result?.pointee = rows as CFArray
                    return errSecSuccess
                },
                addItem: { [weak self] item, _ in
                    guard let self,
                          let account = (item as NSDictionary)[
                              kSecAttrAccount
                          ] as? String
                    else {
                        return errSecParam
                    }
                    if self.accounts.contains(account) {
                        return errSecDuplicateItem
                    }
                    self.accounts.insert(account)
                    return errSecSuccess
                },
                deleteItem: { [weak self] query in
                    guard let self,
                          let account = (query as NSDictionary)[
                              kSecAttrAccount
                          ] as? String
                    else {
                        return errSecParam
                    }
                    return self.accounts.remove(account) == nil
                        ? errSecItemNotFound
                        : errSecSuccess
                }
            )
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
    func testTransientKeychainReadFailureDoesNotDeleteCredential() {
        var deleteCount = 0
        let store = VeepooCredentialStore(
            copyMatching: { _, _ in errSecInteractionNotAllowed },
            deleteItem: { _ in
                deleteCount += 1
                return errSecSuccess
            }
        )

        XCTAssertEqual(store.load(deviceID: "supplier"), .unavailable)
        XCTAssertEqual(deleteCount, 0)
    }

    @MainActor
    func testMalformedKeychainCredentialIsClassifiedAndDeleted() {
        var deleteCount = 0
        let store = VeepooCredentialStore(
            copyMatching: { _, result in
                result?.pointee = Data("12x4".utf8) as CFData
                return errSecSuccess
            },
            deleteItem: { _ in
                deleteCount += 1
                return errSecSuccess
            }
        )

        XCTAssertEqual(store.load(deviceID: "supplier"), .malformed)
        XCTAssertEqual(deleteCount, 1)
    }

    @MainActor
    func testMalformedKeychainCredentialDeletionFailureIsUnavailable() {
        var deleteCount = 0
        let store = VeepooCredentialStore(
            copyMatching: { _, result in
                result?.pointee = Data("12x4".utf8) as CFData
                return errSecSuccess
            },
            deleteItem: { _ in
                deleteCount += 1
                return errSecInteractionNotAllowed
            }
        )

        XCTAssertEqual(store.load(deviceID: "supplier"), .unavailable)
        XCTAssertEqual(deleteCount, 1)
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
    func testSourcePublishesPercentFormBatteryWithoutRescaling() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )

        adapter.emit(
            .battery(
                .init(
                    percent: 82,
                    level: nil,
                    charging: nil,
                    low: false
                )
            )
        )

        XCTAssertEqual(live.batteryPct, 82)
        XCTAssertEqual(adapter.liveStartCount, 1)
        source.stop()
    }

    @MainActor
    func testSourceMapsLevelFormBatteryUsingQuarterScalePolicy() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )

        adapter.emit(
            .battery(
                .init(
                    percent: nil,
                    level: 3,
                    charging: nil,
                    low: nil
                )
            )
        )

        XCTAssertEqual(live.batteryPct, 75)
        XCTAssertEqual(adapter.liveStartCount, 1)
        source.stop()
    }

    @MainActor
    func testSourcePublishesChargingBeforeBatteryCallbackAndClearsOnStop() {
        let live = LiveState()
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {}
        )
        var chargingAtBatteryCallback: Bool?
        live.onBatteryUpdate = { _ in
            chargingAtBatteryCallback = live.charging
        }

        adapter.emit(
            .battery(
                .init(
                    percent: 12,
                    level: nil,
                    charging: true,
                    low: true
                )
            )
        )

        XCTAssertEqual(live.charging, true)
        XCTAssertEqual(chargingAtBatteryCallback, true)

        source.stop()

        XCTAssertNil(live.charging)
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
    func testSourceRestartsLiveAfterNotWornAndBusyResponses() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            liveRestartDelaysNanoseconds: [0, 0],
            liveRestartTailDelayNanoseconds: 0
        )

        adapter.emit(.failed(stage: .live, failure: .notWorn))
        for _ in 0..<100 where adapter.liveStartCount < 1 {
            await Task.yield()
        }
        XCTAssertEqual(adapter.liveStartCount, 1)

        adapter.emit(.failed(stage: .live, failure: .busy))
        for _ in 0..<100 where adapter.liveStartCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(adapter.liveStartCount, 2)
        source.stop()
    }

    @MainActor
    func testSourceContinuesWithLowFrequencyTailAfterRestartBurst() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            liveRestartDelaysNanoseconds: [0],
            liveRestartTailDelayNanoseconds: 0
        )

        adapter.emit(.failed(stage: .live, failure: .notWorn))
        for _ in 0..<100 where adapter.liveStartCount < 1 {
            await Task.yield()
        }
        adapter.emit(.failed(stage: .live, failure: .notWorn))
        for _ in 0..<100 where adapter.liveStartCount < 2 {
            await Task.yield()
        }

        XCTAssertEqual(adapter.liveStartCount, 2)
        source.stop()
    }

    @MainActor
    func testStoppingSourceCancelsPendingLiveRestart() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            liveRestartDelaysNanoseconds: [20_000_000],
            liveRestartTailDelayNanoseconds: 20_000_000
        )

        adapter.emit(.failed(stage: .live, failure: .notWorn))
        source.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(adapter.liveStartCount, 0)
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
        credentials.loadOverride = .unavailable
        XCTAssertTrue(
            VeepooBandSourceFactory.hasUsableRegistration(
                for: device,
                credentials: credentials,
                adapterAvailable: true
            )
        )
        credentials.loadOverride = nil
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
    func testInitialActivationDiscoveryContinuesWithLowFrequencyReconnectTail()
        async
    {
        let adapter = FakeAdapter()
        var source: VeepooBandSource!
        adapter.onDiscovery = {
            if adapter.discoveries.count == 5 {
                source.stop()
            }
        }
        source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            reconnectDelaysNanoseconds: [0, 0, 0],
            reconnectDiscoveryTimeoutNanoseconds: 0,
            reconnectTailDelayNanoseconds: 0
        )
        source.connect(UUID())

        for _ in 0..<200 where adapter.discoveries.count < 5 {
            await Task.yield()
        }

        XCTAssertEqual(adapter.discoveries.count, 5)
        XCTAssertEqual(adapter.stopDiscoveryCount, 4)
        adapter.onDiscovery = nil
        source.stop()
    }

    @MainActor
    func testStoppingSourceCancelsPendingLowFrequencyReconnectTail() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            reconnectDelaysNanoseconds: [],
            reconnectDiscoveryTimeoutNanoseconds: 0,
            reconnectTailDelayNanoseconds: 20_000_000
        )
        source.connect(UUID())

        for _ in 0..<100 where adapter.stopDiscoveryCount < 1 {
            await Task.yield()
        }
        XCTAssertEqual(adapter.discoveries.count, 1)
        XCTAssertEqual(adapter.stopDiscoveryCount, 1)

        source.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(adapter.discoveries.count, 1)
        XCTAssertEqual(adapter.stopDiscoveryCount, 1)
    }

    @MainActor
    func testTerminalBatteryFailureClearsStateAndReconcilesOnce() {
        let live = LiveState()
        live.setBattery(80)
        live.setDisplayOnlyHeartRate(72, receivedAt: Date())
        live.connected = true
        let adapter = FakeAdapter()
        var reconciliationCount = 0
        var disconnectCountAtReconciliation = 0
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            onTerminalBatteryFailure: {
                reconciliationCount += 1
                disconnectCountAtReconciliation = adapter.disconnectCount
                return true
            }
        )

        adapter.emit(.failed(stage: .battery, failure: .invalidBattery))
        adapter.emit(.failed(stage: .battery, failure: .invalidBattery))

        XCTAssertNil(live.batteryPct)
        XCTAssertNil(live.displayOnlyHeartRate)
        XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
        XCTAssertFalse(live.connected)
        XCTAssertEqual(reconciliationCount, 1)
        XCTAssertEqual(disconnectCountAtReconciliation, 1)
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
    func testBatteryVerificationAllowsRegistrationWithoutLiveHeartRate()
        throws
    {
        let credentials = FakeCredentials()
        let (session, client) = try readyPairingSession(
            credentials: credentials,
            emitHeartRate: false
        )
        var registeredDevice: PairedDevice?

        let committed = session.commitPairedDevice(nickname: nil) { device in
            registeredDevice = device
            return true
        }

        XCTAssertTrue(committed)
        XCTAssertNotNil(registeredDevice)
        XCTAssertNil(session.heartRate)
        XCTAssertEqual(client.liveStarts.count, 1)
    }

    @MainActor
    func testTransientLiveFailureAfterBatteryPreservesReadyRegistration()
        throws
    {
        for failure in [
            VeepooBandAdapterFailure.notWorn,
            VeepooBandAdapterFailure.busy,
        ] {
            let credentials = FakeCredentials()
            let (session, adapter) = try readyDirectPairingSession(
                credentials: credentials
            )

            adapter.emit(.failed(stage: .live, failure: failure))

            XCTAssertEqual(session.phase, .ready)
            XCTAssertTrue(
                session.commitPairedDevice(nickname: nil) { _ in true }
            )
        }
    }

    @MainActor
    func testNonTransientLiveFailureAfterBatteryRemainsTerminal() throws {
        let credentials = FakeCredentials()
        let (session, adapter) = try readyDirectPairingSession(
            credentials: credentials
        )

        adapter.emit(.failed(stage: .live, failure: .internalFailure))

        XCTAssertEqual(session.phase, .failed(.internalFailure))
        XCTAssertFalse(
            session.commitPairedDevice(nickname: nil) { _ in true }
        )
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
    func testFailedRegistrationRetainsCleanupHandleUntilCredentialDeletionSucceeds()
        throws
    {
        let credentials = FakeCredentials()
        credentials.clearSucceeds = false
        let cleanup = FakeCredentialCleanup()
        let (session, _) = try readyPairingSession(
            credentials: credentials,
            credentialCleanup: cleanup
        )
        var generatedDeviceID: String?

        let committed = session.commitPairedDevice(nickname: nil) { device in
            generatedDeviceID = device.id
            return false
        }

        let deviceID = try XCTUnwrap(generatedDeviceID)
        XCTAssertFalse(committed)
        XCTAssertEqual(cleanup.pending, Set([deviceID]))
        XCTAssertEqual(credentials.values[deviceID], "2468")

        credentials.clearSucceeds = true
        VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: [],
            credentials: credentials,
            cleanup: cleanup
        )

        XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertNil(credentials.values[deviceID])
    }

    @MainActor
    func testPendingCleanupPreservesCredentialForRegisteredSupplier() throws {
        let credentials = FakeCredentials()
        let cleanup = FakeCredentialCleanup()
        cleanup.clearSucceeds = false
        let (session, _) = try readyPairingSession(
            credentials: credentials,
            credentialCleanup: cleanup
        )
        var generatedDeviceID: String?

        let committed = session.commitPairedDevice(nickname: nil) { device in
            generatedDeviceID = device.id
            return true
        }

        let deviceID = try XCTUnwrap(generatedDeviceID)
        XCTAssertTrue(committed)
        XCTAssertEqual(cleanup.pending, Set([deviceID]))
        XCTAssertEqual(credentials.values[deviceID], "2468")

        cleanup.clearSucceeds = true
        VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: [deviceID],
            credentials: credentials,
            cleanup: cleanup
        )

        XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(credentials.values[deviceID], "2468")
    }

    @MainActor
    func testCredentialCleanupLedgerSurvivesStoreRecreation() throws {
        let keychain = FakeCredentialCleanupKeychain()
        let first = keychain.makeStore()
        XCTAssertTrue(first.markPending(deviceID: "veepoo-generated"))

        let restored = keychain.makeStore()
        XCTAssertEqual(
            restored.pendingDeviceIDs(),
            Set(["veepoo-generated"])
        )
        XCTAssertTrue(restored.clearPending(deviceID: "veepoo-generated"))
        XCTAssertEqual(first.pendingDeviceIDs(), Set<String>())
    }

    @MainActor
    func testCredentialCleanupLedgerRejectsMalformedAndOversizedRows() {
        let keychain = FakeCredentialCleanupKeychain()
        let store = keychain.makeStore()

        keychain.forcedRows = [["unexpected": "row"]]
        XCTAssertNil(store.pendingDeviceIDs())

        keychain.forcedRows = (0...64).map {
            [kSecAttrAccount as String: "supplier-\($0)"]
        }
        XCTAssertNil(store.pendingDeviceIDs())
    }

    @MainActor
    func testPendingCleanupFailsClosedWithoutAuthoritativeRegistry() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.pending.insert("supplier")

        VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: nil,
            credentials: credentials,
            cleanup: cleanup
        )

        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertEqual(cleanup.pending, Set(["supplier"]))
    }

    @MainActor
    func testPendingCleanupRetriesAfterProtectedDataBecomesAvailable() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.pending.insert("supplier")
        cleanup.readsAvailable = false
        let protectedData = PassthroughSubject<Void, Never>()
        let reconciler = VeepooPendingCredentialCleanupReconciler(
            registeredDeviceIDs: { [] },
            credentials: credentials,
            cleanup: cleanup,
            protectedDataAvailablePublisher:
                protectedData.eraseToAnyPublisher(),
            retryDelaysNanoseconds: []
        )

        reconciler.start()

        XCTAssertEqual(cleanup.readCount, 1)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(cleanup.pending, Set(["supplier"]))

        cleanup.readsAvailable = true
        protectedData.send()

        XCTAssertEqual(cleanup.readCount, 2)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.pending.isEmpty)

        protectedData.send()
        XCTAssertEqual(cleanup.readCount, 2)
        XCTAssertEqual(credentials.clearCount, 1)
    }

    @MainActor
    func testPendingCleanupProtectedDataRetryIsOneShotWhenStorageStaysUnavailable() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.pending.insert("supplier")
        cleanup.readsAvailable = false
        let protectedData = PassthroughSubject<Void, Never>()
        let reconciler = VeepooPendingCredentialCleanupReconciler(
            registeredDeviceIDs: { [] },
            credentials: credentials,
            cleanup: cleanup,
            protectedDataAvailablePublisher:
                protectedData.eraseToAnyPublisher(),
            retryDelaysNanoseconds: []
        )

        reconciler.start()
        protectedData.send()
        protectedData.send()

        XCTAssertEqual(cleanup.readCount, 2)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(cleanup.pending, Set(["supplier"]))
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
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertTrue(session.registrationFailed)
        XCTAssertGreaterThan(client.disconnectCount, 0)
    }

    @MainActor
    func testMutatingSecureStorageFailureRetainsCleanupHandleWhenDeletionFails()
        throws
    {
        let credentials = FakeCredentials()
        credentials.saveMutatesBeforeFailure = true
        credentials.clearSucceeds = false
        let cleanup = FakeCredentialCleanup()
        let (session, _) = try readyPairingSession(
            credentials: credentials,
            credentialCleanup: cleanup
        )
        var registryCalls = 0

        let committed = session.commitPairedDevice(nickname: nil) { _ in
            registryCalls += 1
            return true
        }

        XCTAssertFalse(committed)
        XCTAssertEqual(registryCalls, 0)
        XCTAssertEqual(credentials.saveCount, 1)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertEqual(credentials.values.count, 1)
        XCTAssertEqual(cleanup.pending.count, 1)
    }

    @MainActor
    func testSupplierRemovalRequiresDurableCleanupMarkerBeforeArchive() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.markSucceeds = false
        var archiveCalls = 0

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup
        ) {
            archiveCalls += 1
            return true
        }

        XCTAssertFalse(removed)
        XCTAssertEqual(archiveCalls, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
    }

    @MainActor
    func testSupplierRemovalArchiveFailurePreservesCredentialAndClearsMarker() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            archive: { false }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertTrue(cleanup.pending.isEmpty)
    }

    @MainActor
    func testSupplierRemovalArchiveFailureRetainsMarkerWhenMarkerClearFails() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.clearSucceeds = false

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            archive: { false }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertEqual(cleanup.pending, Set(["supplier"]))

        cleanup.clearSucceeds = true
        VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: ["supplier"],
            credentials: credentials,
            cleanup: cleanup
        )

        XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(credentials.values["supplier"], "2468")
    }

    @MainActor
    func testSupplierRemovalLeavesNoCredentialAfterVerifiedArchive() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            archive: { true }
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.pending.isEmpty)
    }

    @MainActor
    func testSupplierRemovalDefersCredentialDeletionAfterVerifiedArchive() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        credentials.clearSucceeds = false
        let cleanup = FakeCredentialCleanup()

        let removed = VeepooSupplierRemoval.remove(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            archive: { true }
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertEqual(cleanup.pending, Set(["supplier"]))

        credentials.clearSucceeds = true
        VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: [],
            credentials: credentials,
            cleanup: cleanup
        )

        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.pending.isEmpty)
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
    private func readyDirectPairingSession(
        credentials: FakeCredentials
    ) throws -> (VeepooBandPairingSession, FakeAdapter) {
        let adapter = FakeAdapter()
        let session = VeepooBandPairingSession(
            adapter: adapter,
            credentials: credentials,
            credentialCleanup: FakeCredentialCleanup()
        )
        session.start()
        let candidate = VeepooBandCandidate(
            handle: 7,
            peripheralID: UUID(),
            printedIdentifier: "AA:BB:12:34"
        )
        adapter.emit(.candidate(candidate))
        session.select(candidate)
        session.confirmPrintedIdentifier("AABB1234")
        adapter.emit(.state(.connected))
        session.submitPassword("2468")
        adapter.emit(.authenticated)
        adapter.emit(
            .battery(
                .init(
                    percent: 80,
                    level: nil,
                    charging: false,
                    low: false
                )
            )
        )
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(adapter.liveStartCount, 1)
        return (session, adapter)
    }

    @MainActor
    private func readyPairingSession(
        credentials: FakeCredentials,
        credentialCleanup: FakeCredentialCleanup? = nil,
        emitHeartRate: Bool = true
    ) throws -> (VeepooBandPairingSession, FakeClient) {
        let client = FakeClient()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: RecordingDiagnostics()
        )
        let session = VeepooBandPairingSession(
            adapter: core,
            credentials: credentials,
            credentialCleanup:
                credentialCleanup ?? FakeCredentialCleanup()
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
        if emitHeartRate {
            client.emit(.live(generation: generation, .started))
            client.emit(
                .live(
                    generation: generation,
                    .sample(
                        bpm: 72,
                        receivedAt:
                            Date(timeIntervalSince1970: 1_800_000_000)
                    )
                )
            )
        }
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
