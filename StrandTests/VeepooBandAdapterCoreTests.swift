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
        private(set) var readStepsRequests: [(UInt64, UInt64)] = []
        private(set) var readSleepRequests: [(UInt64, UInt64)] = []

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

        func readSteps(generation: UInt64, requestID: UInt64) {
            readStepsRequests.append((generation, requestID))
        }

        func readSleep(generation: UInt64, requestID: UInt64) {
            readSleepRequests.append((generation, requestID))
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
        private(set) var readStepRequestIDs: [UInt64] = []
        private(set) var readSleepRequestIDs: [UInt64] = []
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
        var readStepsCount: Int { readStepRequestIDs.count }
        var readSleepCount: Int { readSleepRequestIDs.count }

        func readSteps(requestID: UInt64) {
            readStepRequestIDs.append(requestID)
        }

        func readSleep(requestID: UInt64) {
            readSleepRequestIDs.append(requestID)
        }

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
        var rejectedPending = Set<String>()
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

        func markRejectedPending(deviceID: String) -> Bool {
            guard markSucceeds else { return false }
            rejectedPending.insert(deviceID)
            return true
        }

        func rejectedPendingDeviceIDs() -> Set<String>? {
            readCount += 1
            return readsAvailable ? rejectedPending : nil
        }

        @discardableResult
        func clearRejectedPending(deviceID: String) -> Bool {
            guard clearSucceeds else { return false }
            rejectedPending.remove(deviceID)
            return true
        }
    }

    @MainActor
    private final class FakeCredentialCleanupFallback:
        VeepooCredentialCleanupFallbackAccess
    {
        var pending = Set<String>()
        var available = true

        func mark(deviceID: String) -> Bool {
            guard available else { return false }
            pending.insert(deviceID)
            return true
        }

        func pendingDeviceIDs() -> Set<String>? {
            available ? pending : nil
        }

        @discardableResult
        func clear(deviceID: String) -> Bool {
            guard available else { return false }
            pending.remove(deviceID)
            return true
        }
    }

    @MainActor
    private final class FakeCredentialCleanupKeychain {
        var accountsByService = [String: Set<String>]()
        var forcedRows: [[String: Any]]?
        var copyStatusOverride: OSStatus?
        let fallback = FakeCredentialCleanupFallback()

        func makeStore() -> VeepooCredentialCleanupStore {
            VeepooCredentialCleanupStore(
                copyMatching: { [weak self] query, result in
                    guard let self,
                          let service = (query as NSDictionary)[
                              kSecAttrService
                          ] as? String
                    else {
                        return errSecNotAvailable
                    }
                    if let copyStatusOverride = self.copyStatusOverride {
                        return copyStatusOverride
                    }
                    let rows = self.forcedRows
                        ?? self.accountsByService[
                            service,
                            default: []
                        ].sorted().map {
                            [kSecAttrAccount as String: $0]
                        }
                    guard !rows.isEmpty else { return errSecItemNotFound }
                    result?.pointee = rows as CFArray
                    return errSecSuccess
                },
                addItem: { [weak self] item, _ in
                    guard let self,
                          let service = (item as NSDictionary)[
                              kSecAttrService
                          ] as? String,
                          let account = (item as NSDictionary)[
                              kSecAttrAccount
                          ] as? String
                    else {
                        return errSecParam
                    }
                    if self.accountsByService[
                        service,
                        default: []
                    ].contains(account) {
                        return errSecDuplicateItem
                    }
                    self.accountsByService[
                        service,
                        default: []
                    ].insert(account)
                    return errSecSuccess
                },
                deleteItem: { [weak self] query in
                    guard let self,
                          let service = (query as NSDictionary)[
                              kSecAttrService
                          ] as? String,
                          let account = (query as NSDictionary)[
                              kSecAttrAccount
                          ] as? String
                    else {
                        return errSecParam
                    }
                    return self.accountsByService[
                        service,
                        default: []
                    ].remove(account) == nil
                        ? errSecItemNotFound
                        : errSecSuccess
                },
                rejectionFallback: fallback
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
    func testReadyTransportReadsMeasuredStepsAndBandScoredSleep() {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }

        core.readSteps(requestID: 1)
        core.readSleep(requestID: 2)
        XCTAssertTrue(client.readStepsRequests.isEmpty)
        XCTAssertTrue(client.readSleepRequests.isEmpty)

        let generation = ready(core, client: client)
        let stepRequestID: UInt64 = 10
        let sleepRequestID: UInt64 = 11
        core.readSteps(requestID: stepRequestID)
        XCTAssertEqual(
            client.readStepsRequests.map { [$0.0, $0.1] },
            [[generation, stepRequestID]]
        )

        let steps = VeepooBandStepsReading(
            steps: 0,
            distanceKm: 0,
            kcal: 0
        )
        let sleep = VeepooBandSleepReading(
            startTs: 1_000,
            endTs: 26_200,
            totalMin: 420,
            deepMin: 80,
            lightMin: 260,
            awakenings: 2,
            efficiency: 0.91
        )
        client.emit(
            .steps(
                generation: generation,
                requestID: stepRequestID,
                reading: .init(steps: 0, distanceKm: 0, kcal: 0)
            )
        )
        core.readSleep(requestID: sleepRequestID)
        XCTAssertEqual(
            client.readSleepRequests.map { [$0.0, $0.1] },
            [[generation, sleepRequestID]]
        )
        client.emit(
            .sleep(
                generation: generation,
                requestID: sleepRequestID,
                reading: .init(
                    startTs: sleep.startTs,
                    endTs: sleep.endTs,
                    totalMin: sleep.totalMin,
                    deepMin: sleep.deepMin,
                    lightMin: sleep.lightMin,
                    awakenings: sleep.awakenings,
                    efficiency: sleep.efficiency
                )
            )
        )

        XCTAssertEqual(core.state, .ready)
        XCTAssertTrue(
            events.contains(
                .steps(requestID: stepRequestID, reading: steps)
            )
        )
        XCTAssertTrue(
            events.contains(
                .sleep(requestID: sleepRequestID, reading: sleep)
            )
        )
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(stage: .steps, outcome: .completed)
            )
        )
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(stage: .sleep, outcome: .completed)
            )
        )
    }

    @MainActor
    func testOptionalMetricFailureDoesNotTearDownHealthyTransport() {
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

        core.readSteps(requestID: 21)
        client.emit(
            .stepsFailed(
                generation: generation,
                requestID: 21,
                failure: .noResult
            )
        )
        core.readSleep(requestID: 22)
        client.emit(
            .sleepFailed(
                generation: generation,
                requestID: 22,
                failure: .timeout
            )
        )

        XCTAssertEqual(core.state, .ready)
        XCTAssertEqual(client.disconnectCount, 0)
        XCTAssertTrue(
            events.contains(
                .metricReadFailed(
                    requestID: 21,
                    stage: .steps,
                    failure: .noResult
                )
            )
        )
        XCTAssertTrue(
            events.contains(
                .metricReadFailed(
                    requestID: 22,
                    stage: .sleep,
                    failure: .timeout
                )
            )
        )
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .steps,
                    outcome: .failed,
                    failure: .noResult
                )
            )
        )
    }

    @MainActor
    func testInvalidBandSleepValuesAreRejectedWithoutDisconnecting() {
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
        core.readSleep(requestID: 31)

        client.emit(
            .sleep(
                generation: generation,
                requestID: 31,
                reading: .init(
                    startTs: 1_000,
                    endTs: 26_200,
                    totalMin: 420,
                    deepMin: -1,
                    lightMin: 260,
                    awakenings: 2,
                    efficiency: 1.2
                )
            )
        )

        XCTAssertEqual(core.state, .ready)
        XCTAssertEqual(client.disconnectCount, 0)
        XCTAssertFalse(
            events.contains {
                if case .sleep = $0 { return true }
                return false
            }
        )
        XCTAssertTrue(
            events.contains(
                .metricReadFailed(
                    requestID: 31,
                    stage: .sleep,
                    failure: .invalidSample
                )
            )
        )
    }

    @MainActor
    func testMetricReadRejectsLateCallbackWhileNextRequestIsActive() {
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

        core.readSteps(requestID: 41)
        client.emit(
            .stepsFailed(
                generation: generation,
                requestID: 41,
                failure: .noResult
            )
        )
        core.readSteps(requestID: 42)
        client.emit(
            .steps(
                generation: generation,
                requestID: 41,
                reading: .init(steps: 111, distanceKm: nil, kcal: nil)
            )
        )
        client.emit(
            .steps(
                generation: generation,
                requestID: 42,
                reading: .init(steps: 222, distanceKm: nil, kcal: nil)
            )
        )

        let acceptedRequestIDs = events.compactMap { event -> UInt64? in
            guard case .steps(let requestID, _) = event else { return nil }
            return requestID
        }
        XCTAssertEqual(acceptedRequestIDs, [42])
        XCTAssertTrue(
            diagnostics.events.contains(
                .init(
                    stage: .steps,
                    outcome: .stale,
                    failure: .staleCallback
                )
            )
        )
    }

    @MainActor
    func testMetricReadTimeoutReleasesLaneAndRejectsLateCallback() async {
        let client = FakeClient()
        let diagnostics = RecordingDiagnostics()
        let core = VeepooBandAdapterCore(
            client: client,
            compatibilityPolicy: Self.approvedPolicy,
            diagnostics: diagnostics,
            stepReadTimeoutNanoseconds: 1_000_000
        )
        var events: [VeepooBandAdapterEvent] = []
        core.eventHandler = { events.append($0) }
        let generation = ready(core, client: client)

        core.readSteps(requestID: 51)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(
            events.contains(
                .metricReadFailed(
                    requestID: 51,
                    stage: .steps,
                    failure: .timeout
                )
            )
        )

        client.emit(
            .steps(
                generation: generation,
                requestID: 51,
                reading: .init(steps: 111, distanceKm: nil, kcal: nil)
            )
        )
        core.readSteps(requestID: 52)
        client.emit(
            .steps(
                generation: generation,
                requestID: 52,
                reading: .init(steps: 222, distanceKm: nil, kcal: nil)
            )
        )

        let acceptedRequestIDs = events.compactMap { event -> UInt64? in
            guard case .steps(let requestID, _) = event else { return nil }
            return requestID
        }
        XCTAssertEqual(acceptedRequestIDs, [52])
        XCTAssertEqual(core.state, .ready)
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
    func testSourceBatchesHeartRateAndFlushesRemainderOnStop() {
        let live = LiveState()
        let adapter = FakeAdapter()
        var batches: [[VeepooBandHeartRateReading]] = []
        let clock = Date(timeIntervalSince1970: 2_000)
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persist: { batches.append($0) },
            heartRatePersistBatchSize: 2,
            heartRatePersistInterval: 30,
            now: { clock }
        )

        adapter.emit(
            .heartRate(
                .init(
                    bpm: 70,
                    receivedAt: Date(timeIntervalSince1970: 1_990.1)
                )
            )
        )
        adapter.emit(
            .heartRate(
                .init(
                    bpm: 71,
                    receivedAt: Date(timeIntervalSince1970: 1_990.8)
                )
            )
        )
        XCTAssertTrue(batches.isEmpty)

        adapter.emit(
            .heartRate(
                .init(
                    bpm: 72,
                    receivedAt: Date(timeIntervalSince1970: 1_991.1)
                )
            )
        )
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.bpm), [71, 72])

        adapter.emit(
            .heartRate(
                .init(
                    bpm: 73,
                    receivedAt: Date(timeIntervalSince1970: 1_992.1)
                )
            )
        )
        source.stop()

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].map(\.bpm), [73])
    }

    @MainActor
    func testSourceFlushesPartialHeartRateBatchAfterBoundedInterval() async {
        let live = LiveState()
        let adapter = FakeAdapter()
        var batches: [[VeepooBandHeartRateReading]] = []
        let clock = Date()
        let source = VeepooBandSource(
            live: live,
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persist: { batches.append($0) },
            heartRatePersistBatchSize: 30,
            heartRatePersistInterval: 0.02,
            now: { clock }
        )

        adapter.emit(
            .heartRate(.init(bpm: 72, receivedAt: clock))
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.bpm), [72])
        source.stop()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(batches.count, 1)
    }

    @MainActor
    func testSourceSerializesOptionalMetricReadsAndCancelsOnStop() async {
        let adapter = FakeAdapter()
        var persistedSteps: [VeepooBandStepsReading] = []
        var persistedSleep: [VeepooBandSleepReading] = []
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persistSteps: { persistedSteps.append($0) },
            persistSleep: { persistedSleep.append($0) },
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 1_000_000
        )

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
        for _ in 0..<100 where adapter.readStepsCount < 1 {
            await Task.yield()
        }
        XCTAssertEqual(adapter.readStepsCount, 1)
        let firstStepRequestID = try! XCTUnwrap(
            adapter.readStepRequestIDs.first
        )

        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(adapter.readStepsCount, 1)
        XCTAssertEqual(
            adapter.readSleepCount,
            0,
            "Sleep must wait for the outstanding step command"
        )

        adapter.emit(
            .metricReadFailed(
                requestID: firstStepRequestID,
                stage: .steps,
                failure: .noResult
            )
        )
        XCTAssertEqual(
            adapter.readSleepCount,
            1,
            "An optional step failure must release the command lane"
        )
        let sleepRequestID = try! XCTUnwrap(
            adapter.readSleepRequestIDs.first
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(
            adapter.readStepsCount,
            1,
            "Step polling must wait for the outstanding sleep command"
        )

        let sleep = VeepooBandSleepReading(
            startTs: 1_000,
            endTs: 26_200,
            totalMin: 420,
            deepMin: 80,
            lightMin: 260,
            awakenings: 2,
            efficiency: 0.91
        )
        adapter.emit(
            .sleep(requestID: sleepRequestID, reading: sleep)
        )
        for _ in 0..<100 where adapter.readStepsCount < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(adapter.readStepsCount, 2)
        let secondStepRequestID = adapter.readStepRequestIDs[1]

        let step = VeepooBandStepsReading(
            steps: 4_321,
            distanceKm: 3.2,
            kcal: 240
        )
        adapter.emit(
            .steps(requestID: secondStepRequestID, reading: step)
        )
        XCTAssertEqual(persistedSteps, [step])
        XCTAssertEqual(persistedSleep, [sleep])

        source.stop()
        let readsAtStop = adapter.readStepsCount
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(adapter.readStepsCount, readsAtStop)
        XCTAssertEqual(adapter.readSleepCount, 1)
    }

    @MainActor
    func testSourceQueuesSleepAfterSuccessfulStepResult() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persistSteps: { _ in },
            persistSleep: { _ in },
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 1_000_000
        )

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
        for _ in 0..<100 where adapter.readStepsCount < 1 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(adapter.readSleepCount, 0)
        let stepRequestID = try! XCTUnwrap(
            adapter.readStepRequestIDs.first
        )

        adapter.emit(
            .steps(
                requestID: stepRequestID,
                reading: .init(steps: 20, distanceKm: nil, kcal: nil)
            )
        )

        XCTAssertEqual(adapter.readSleepCount, 1)
        source.stop()
    }

    @MainActor
    func testSourceRejectsUnsolicitedMetricResultsAndClearsQueueOnDisconnect()
        async
    {
        let adapter = FakeAdapter()
        var stepResults = 0
        var sleepResults = 0
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persistSteps: { _ in stepResults += 1 },
            persistSleep: { _ in sleepResults += 1 },
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 1_000_000
        )
        let step = VeepooBandStepsReading(
            steps: 20,
            distanceKm: nil,
            kcal: nil
        )
        let sleep = VeepooBandSleepReading(
            startTs: 1_000,
            endTs: 26_200,
            totalMin: 420,
            deepMin: nil,
            lightMin: nil,
            awakenings: nil,
            efficiency: nil
        )

        adapter.emit(.steps(requestID: 900, reading: step))
        adapter.emit(.sleep(requestID: 901, reading: sleep))
        XCTAssertEqual(stepResults, 0)
        XCTAssertEqual(sleepResults, 0)

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
        for _ in 0..<100 where adapter.readStepsCount < 1 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(adapter.readSleepCount, 0)
        let outstandingStepRequestID = try! XCTUnwrap(
            adapter.readStepRequestIDs.first
        )

        adapter.emit(.disconnected)
        adapter.emit(
            .steps(requestID: outstandingStepRequestID, reading: step)
        )
        adapter.emit(.sleep(requestID: 902, reading: sleep))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(adapter.readSleepCount, 0)
        XCTAssertEqual(stepResults, 0)
        XCTAssertEqual(sleepResults, 0)
        source.stop()
    }

    @MainActor
    func testSourceTimeoutDisconnectsAndRejectsLateMetricCallback() async {
        let adapter = FakeAdapter()
        var persistedSteps: [VeepooBandStepsReading] = []
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persistSteps: { persistedSteps.append($0) },
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 0
        )
        adapter.onDisconnect = {
            adapter.emit(.disconnected)
        }

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
        for _ in 0..<100 where adapter.readStepsCount < 1 {
            await Task.yield()
        }
        let firstRequestID = try! XCTUnwrap(
            adapter.readStepRequestIDs.first
        )

        adapter.emit(
            .metricReadFailed(
                requestID: firstRequestID,
                stage: .steps,
                failure: .timeout
            )
        )
        XCTAssertEqual(adapter.disconnectCount, 1)
        adapter.emit(
            .steps(
                requestID: firstRequestID,
                reading: .init(steps: 111, distanceKm: nil, kcal: nil)
            )
        )
        XCTAssertTrue(persistedSteps.isEmpty)

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
        for _ in 0..<100 where adapter.readStepsCount < 2 {
            await Task.yield()
        }
        let secondRequestID = adapter.readStepRequestIDs[1]
        XCTAssertNotEqual(secondRequestID, firstRequestID)
        let accepted = VeepooBandStepsReading(
            steps: 222,
            distanceKm: nil,
            kcal: nil
        )
        adapter.emit(
            .steps(requestID: secondRequestID, reading: accepted)
        )
        XCTAssertEqual(persistedSteps, [accepted])
        source.stop()
    }

    @MainActor
    func testSourceClearsQueuedMetricReadsOnStop() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            persistSteps: { _ in },
            persistSleep: { _ in },
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 1_000_000
        )

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
        for _ in 0..<100 where adapter.readStepsCount < 1 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(adapter.readSleepCount, 0)
        let stepRequestID = try! XCTUnwrap(
            adapter.readStepRequestIDs.first
        )

        source.stop()
        adapter.emit(
            .steps(
                requestID: stepRequestID,
                reading: .init(steps: 20, distanceKm: nil, kcal: nil)
            )
        )
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(adapter.readSleepCount, 0)
    }

    @MainActor
    func testSourceSkipsOptionalReadsWhenNoDurableSinkExists() async {
        let adapter = FakeAdapter()
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            password: "2468",
            onCredentialRejected: {},
            stepPollIntervalNanoseconds: 1_000_000,
            sleepReadDelayNanoseconds: 0
        )

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
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(adapter.readStepsCount, 0)
        XCTAssertEqual(adapter.readSleepCount, 0)
        source.stop()
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
    func testAuthenticatedTransportStaysConnectedWhenLiveHeartRateIsUnavailable() {
        for failure in [
            VeepooBandAdapterFailure.notWorn,
            VeepooBandAdapterFailure.busy,
        ] {
            let live = LiveState()
            let adapter = FakeAdapter()
            let source = VeepooBandSource(
                live: live,
                adapter: adapter,
                password: "2468",
                onCredentialRejected: {},
                liveRestartDelaysNanoseconds: [1_000_000_000]
            )
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
            XCTAssertTrue(live.connected)
            adapter.emit(.heartRate(.init(bpm: 72, receivedAt: Date())))

            adapter.emit(.failed(stage: .live, failure: failure))

            XCTAssertNil(live.displayOnlyHeartRate)
            XCTAssertNil(live.displayOnlyHeartRateReceivedAt)
            XCTAssertTrue(live.connected)
            XCTAssertEqual(live.batteryPct, 80)
            source.stop()
        }
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
    func testCredentialReadContinuesWithLowFrequencyTailAfterRetryBurst()
        async
    {
        let adapter = FakeAdapter()
        let target = UUID()
        var loadCount = 0
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            credentialLoader: {
                loadCount += 1
                return loadCount < 5 ? .unavailable : .available("2468")
            },
            credentialRetryDelaysNanoseconds: [0, 0, 0],
            credentialRetryTailDelayNanoseconds: 0,
            onCredentialRejected: {},
            onCredentialPermanentlyUnavailable: {}
        )

        source.connect(target)
        for _ in 0..<200 where adapter.discoveries.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(loadCount, 5)
        XCTAssertEqual(adapter.discoveries, [target])
        source.stop()
    }

    @MainActor
    func testStoppingSourceCancelsPendingCredentialReadTail() async {
        let adapter = FakeAdapter()
        var loadCount = 0
        let source = VeepooBandSource(
            live: LiveState(),
            adapter: adapter,
            credentialLoader: {
                loadCount += 1
                return .unavailable
            },
            credentialRetryDelaysNanoseconds: [],
            credentialRetryTailDelayNanoseconds: 20_000_000,
            onCredentialRejected: {},
            onCredentialPermanentlyUnavailable: {}
        )

        source.connect(UUID())
        XCTAssertEqual(loadCount, 1)
        source.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(adapter.discoveries.isEmpty)
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
    func testRejectedCredentialCleanupLedgerSurvivesStoreRecreation() {
        let keychain = FakeCredentialCleanupKeychain()
        let first = keychain.makeStore()
        XCTAssertTrue(
            first.markRejectedPending(deviceID: "veepoo-rejected")
        )

        let restored = keychain.makeStore()
        XCTAssertEqual(
            restored.rejectedPendingDeviceIDs(),
            Set(["veepoo-rejected"])
        )
        XCTAssertTrue(
            restored.clearRejectedPending(deviceID: "veepoo-rejected")
        )
        XCTAssertEqual(
            first.rejectedPendingDeviceIDs(),
            Set<String>()
        )
    }

    @MainActor
    func testRejectedCleanupFallbackLedgerSurvivesStoreRecreation() throws {
        let suite = "noop.rejected-cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = VeepooCredentialCleanupFallbackStore(defaults: defaults)

        XCTAssertTrue(first.mark(deviceID: "veepoo-fallback"))

        let restored = VeepooCredentialCleanupFallbackStore(
            defaults: defaults
        )
        XCTAssertEqual(
            restored.pendingDeviceIDs(),
            Set(["veepoo-fallback"])
        )
        XCTAssertTrue(restored.clear(deviceID: "veepoo-fallback"))
        XCTAssertEqual(first.pendingDeviceIDs(), Set<String>())
    }

    @MainActor
    func testRejectedCleanupUsesFallbackWhenKeychainIsUnavailable() {
        let fallback = FakeCredentialCleanupFallback()
        var keychainAvailable = false
        let store = VeepooCredentialCleanupStore(
            copyMatching: { _, _ in
                keychainAvailable
                    ? errSecItemNotFound
                    : errSecInteractionNotAllowed
            },
            addItem: { _, _ in errSecInteractionNotAllowed },
            deleteItem: { _ in errSecInteractionNotAllowed },
            rejectionFallback: fallback
        )

        XCTAssertTrue(store.markRejectedPending(deviceID: "supplier"))
        XCTAssertEqual(fallback.pending, Set(["supplier"]))
        XCTAssertNil(store.rejectedPendingDeviceIDs())
        keychainAvailable = true
        XCTAssertEqual(
            store.rejectedPendingDeviceIDs(),
            Set(["supplier"])
        )
    }

    @MainActor
    func testRejectedCleanupDoesNotFinishFromPartialFallbackInventory() {
        let keychain = FakeCredentialCleanupKeychain()
        let store = keychain.makeStore()
        let credentials = FakeCredentials()
        credentials.values["keychain-only"] = "2468"
        credentials.values["fallback-only"] = "1357"

        XCTAssertTrue(
            store.markRejectedPending(deviceID: "keychain-only")
        )
        keychain.fallback.pending.insert("fallback-only")
        keychain.copyStatusOverride = errSecInteractionNotAllowed

        XCTAssertNil(store.rejectedPendingDeviceIDs())
        XCTAssertFalse(
            VeepooPendingCredentialCleanup.reconcile(
                registeredDeviceIDs: ["keychain-only", "fallback-only"],
                credentials: credentials,
                cleanup: store,
                trigger: .scheduledRetry
            )
        )
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["keychain-only"], "2468")
        XCTAssertEqual(credentials.values["fallback-only"], "1357")
        XCTAssertEqual(
            keychain.fallback.pending,
            Set(["fallback-only"])
        )

        keychain.copyStatusOverride = nil
        XCTAssertTrue(
            VeepooPendingCredentialCleanup.reconcile(
                registeredDeviceIDs: ["keychain-only", "fallback-only"],
                credentials: credentials,
                cleanup: store,
                trigger: .protectedDataAvailable
            )
        )
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertTrue(keychain.fallback.pending.isEmpty)
        XCTAssertEqual(store.rejectedPendingDeviceIDs(), Set<String>())
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
    func testAuthenticationRejectionRequiresDurableMarkerBeforeDeletion() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.markSucceeds = false
        var retryDeviceIDs = [String]()
        var persistedRejections = Set<String>()

        let completed = VeepooRejectedCredentialCleanup.begin(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            persistFailClosedRejection: {
                persistedRejections.insert("supplier")
                return true
            },
            retry: { retryDeviceIDs.append($0) }
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertTrue(cleanup.rejectedPending.isEmpty)
        XCTAssertEqual(persistedRejections, Set(["supplier"]))
        XCTAssertEqual(retryDeviceIDs, ["supplier"])
    }

    @MainActor
    func testAuthenticationRejectionRetainsMarkerWhenDeletionFails() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        credentials.clearSucceeds = false
        let cleanup = FakeCredentialCleanup()
        var retryDeviceIDs = [String]()
        var persistedRejections = Set<String>()

        let completed = VeepooRejectedCredentialCleanup.begin(
            deviceID: "supplier",
            credentials: credentials,
            cleanup: cleanup,
            persistFailClosedRejection: {
                persistedRejections.insert("supplier")
                return true
            },
            retry: { retryDeviceIDs.append($0) }
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertEqual(cleanup.rejectedPending, Set(["supplier"]))
        XCTAssertTrue(persistedRejections.isEmpty)
        XCTAssertEqual(retryDeviceIDs, ["supplier"])
    }

    @MainActor
    func testArchivedRejectionCleanupSurvivesReconcilerRecreation() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.markSucceeds = false
        var archivedDeviceIDs = Set<String>()

        XCTAssertFalse(
            VeepooRejectedCredentialCleanup.begin(
                deviceID: "supplier",
                credentials: credentials,
                cleanup: cleanup,
                persistFailClosedRejection: {
                    archivedDeviceIDs.insert("supplier")
                    return true
                },
                retry: { _ in }
            )
        )
        XCTAssertEqual(credentials.values["supplier"], "2468")

        let restarted = VeepooPendingCredentialCleanupReconciler(
            registeredDeviceIDs: { [] },
            archivedDeviceIDs: { archivedDeviceIDs },
            credentials: credentials,
            cleanup: cleanup,
            protectedDataAvailablePublisher:
                Empty<Void, Never>().eraseToAnyPublisher(),
            retryDelaysNanoseconds: []
        )
        restarted.start()

        XCTAssertNil(credentials.values["supplier"])
        XCTAssertEqual(credentials.clearCount, 1)
    }

    @MainActor
    func testRejectedCleanupDeletesCredentialForRegisteredSupplier() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        cleanup.rejectedPending.insert("supplier")

        let completed = VeepooPendingCredentialCleanup.reconcile(
            registeredDeviceIDs: ["supplier"],
            credentials: credentials,
            cleanup: cleanup,
            trigger: .authenticationRejected
        )

        XCTAssertTrue(completed)
        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.rejectedPending.isEmpty)
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
    func testReconcilerPersistsQueuedRejectionAfterProtectedDataRecovery() {
        let credentials = FakeCredentials()
        credentials.values["supplier"] = "2468"
        let cleanup = FakeCredentialCleanup()
        let protectedData = PassthroughSubject<Void, Never>()
        let reconciler = VeepooPendingCredentialCleanupReconciler(
            registeredDeviceIDs: { ["supplier"] },
            credentials: credentials,
            cleanup: cleanup,
            protectedDataAvailablePublisher:
                protectedData.eraseToAnyPublisher(),
            retryDelaysNanoseconds: []
        )
        reconciler.start()
        cleanup.markSucceeds = false

        reconciler.enqueueAuthenticationRejection(deviceID: "supplier")

        XCTAssertEqual(credentials.clearCount, 0)
        XCTAssertEqual(credentials.values["supplier"], "2468")
        XCTAssertTrue(cleanup.rejectedPending.isEmpty)

        cleanup.markSucceeds = true
        protectedData.send()

        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.rejectedPending.isEmpty)
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

        XCTAssertEqual(cleanup.readCount, 3)
        XCTAssertEqual(credentials.clearCount, 1)
        XCTAssertNil(credentials.values["supplier"])
        XCTAssertTrue(cleanup.pending.isEmpty)

        protectedData.send()
        XCTAssertEqual(cleanup.readCount, 3)
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
