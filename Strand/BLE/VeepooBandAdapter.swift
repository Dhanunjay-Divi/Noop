import Foundation

enum VeepooBandAdapterFactory {
#if os(iOS) && NOOP_SUPPLIER_VEEPOO && canImport(VeepooBleSDK)
    static let productionEnabled = true

    @MainActor
    static func makeForApprovedLocalDeviceBuild()
        -> (any VeepooBandAdapterControlling)?
    {
        VeepooBandAdapter()
    }
#else
    static let productionEnabled = false

    @MainActor
    static func makeForApprovedLocalDeviceBuild()
        -> (any VeepooBandAdapterControlling)?
    {
        nil
    }
#endif
}

#if os(iOS) && NOOP_SUPPLIER_VEEPOO && canImport(VeepooBleSDK)
@preconcurrency import VeepooBleSDK

@MainActor
private final class VeepooBandAdapter: VeepooBandAdapterControlling {
    var eventHandler: ((VeepooBandAdapterEvent) -> Void)? {
        get { core.eventHandler }
        set { core.eventHandler = newValue }
    }

    var state: VeepooBandAdapterState { core.state }
    private let core: VeepooBandAdapterCore

    init() {
        core = VeepooBandAdapterCore(
            client: VeepooBleSDKClient(),
            compatibilityPolicy: .loadFromMainBundle(
                allowsUnlistedQualification: Self.qualificationMode
            )
        )
    }

#if NOOP_SUPPLIER_QUALIFICATION
    private static let qualificationMode = true
#else
    private static let qualificationMode = false
#endif

    func startDiscovery(targetPeripheralID: UUID?) {
        core.startDiscovery(targetPeripheralID: targetPeripheralID)
    }

    func stopDiscovery() {
        core.stopDiscovery()
    }

    func connect(
        candidateHandle: UInt64,
        confirmedPrintedIdentifier: String
    ) {
        core.connect(
            candidateHandle: candidateHandle,
            confirmedPrintedIdentifier: confirmedPrintedIdentifier
        )
    }

    func reconnect(candidateHandle: UInt64) {
        core.reconnect(candidateHandle: candidateHandle)
    }

    func disconnect() {
        core.disconnect()
    }

    func verifyPassword(_ password: String) {
        core.verifyPassword(password)
    }

    func startLiveHeartRate() {
        core.startLiveHeartRate()
    }

    func stopLiveHeartRate() {
        core.stopLiveHeartRate()
    }
}

/// The only file that imports the restricted supplier framework.
@MainActor
private final class VeepooBleSDKClient: VeepooBandSDKClient {
    var eventHandler: ((VeepooBandSDKEvent) -> Void)?

    private let manager: VPBleCentralManage
    private var candidates: [UInt64: VPPeripheralModel] = [:]
    private var handleByPeripheralID: [UUID: UInt64] = [:]
    private var nextCandidateHandle: UInt64 = 0

    init(manager: VPBleCentralManage = .sharedBleManager()) {
        self.manager = manager
        manager.isLogEnable = false
        manager.automaticConnection = false
        manager.deviceConfirmTimeout = 12
    }

    func startDiscovery(
        generation: UInt64,
        targetPeripheralID: UUID?
    ) {
        candidates.removeAll(keepingCapacity: true)
        handleByPeripheralID.removeAll(keepingCapacity: true)
        installConnectionObserver(generation: generation)
        manager.veepooSDKStartScanDeviceAndReceiveScanningDevice {
            [weak self] model in
            guard let model else { return }
            Task { @MainActor [weak self] in
                self?.accept(
                    model,
                    generation: generation,
                    targetPeripheralID: targetPeripheralID
                )
            }
        }
    }

    func stopDiscovery() {
        manager.veepooSDKStopScanDevice()
    }

    func connect(
        generation: UInt64,
        candidateHandle: UInt64,
        requiresUserConfirmation: Bool
    ) {
        guard let model = candidates[candidateHandle] else {
            emit(.connection(generation: generation, .failed))
            return
        }
        manager.deviceShowConfirm = requiresUserConfirmation
        installConnectionObserver(generation: generation)
        manager.veepooSDKConnectDevice(model) { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handle(state, generation: generation)
            }
        }
    }

    func disconnect() {
        manager.vpBleConnectStateChangeBlock = nil
        manager.veepooSDKStopScanDevice()
        manager.peripheralManage?.veepooSDKTestHeartStart(
            false,
            testResult: nil
        )
        manager.veepooSDKDisconnectDevice()
        candidates.removeAll()
        handleByPeripheralID.removeAll()
    }

    func verifyPassword(generation: UInt64, password: String) {
        manager.veepooSDKSynchronousPassword(
            with: .VerifyPasswordType,
            password: password
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handle(result, generation: generation)
            }
        }
    }

    func readBattery(generation: UInt64) {
        guard let peripheral = manager.peripheralManage else {
            emit(.connection(generation: generation, .failed))
            return
        }
        peripheral.veepooSDKReadDeviceBatteryAndChargeInfo {
            [weak self] isPercent, chargeState, isLow, value in
            let event = VeepooBandSDKBatteryEvent(
                isPercent: isPercent,
                chargeState: Self.map(chargeState),
                isLow: isLow,
                value: Int(value)
            )
            Task { @MainActor [weak self] in
                self?.emit(.battery(generation: generation, event))
            }
        }
    }

    func startLiveHeartRate(generation: UInt64) {
        guard let peripheral = manager.peripheralManage else {
            emit(.connection(generation: generation, .failed))
            return
        }
        peripheral.veepooSDKTestHeartStart(true) {
            [weak self] state, value in
            let receivedAt = Date()
            let event: VeepooBandSDKLiveEvent
            switch state {
            case .start:
                event = .started
            case .testing:
                event = .sample(bpm: Int(value), receivedAt: receivedAt)
            case .notWear:
                event = .notWorn
            case .deviceBusy:
                event = .busy
            case .over:
                event = .stopped
            @unknown default:
                event = .stopped
            }
            Task { @MainActor [weak self] in
                self?.emit(.live(generation: generation, event))
            }
        }
    }

    func stopLiveHeartRate() {
        manager.peripheralManage?.veepooSDKTestHeartStart(
            false,
            testResult: nil
        )
    }

    private func accept(
        _ model: VPPeripheralModel,
        generation: UInt64,
        targetPeripheralID: UUID?
    ) {
        guard let peripheral = model.peripheral else { return }
        let peripheralID = peripheral.identifier
        guard targetPeripheralID == nil || targetPeripheralID == peripheralID
        else {
            return
        }
        if let existing = handleByPeripheralID[peripheralID] {
            candidates[existing] = model
            return
        }
        nextCandidateHandle &+= 1
        let handle = nextCandidateHandle
        candidates[handle] = model
        handleByPeripheralID[peripheralID] = handle
        emit(
            .candidate(
                generation: generation,
                handle: handle,
                peripheralID: peripheralID,
                // `deviceAddress` is a Bluetooth address, not a proven mapping
                // to the identifier printed on the band. The test integration
                // therefore relies on the SDK's physical confirmation prompt
                // instead of presenting this address as a printed identifier.
                printedIdentifier: nil
            )
        )
    }

    private func installConnectionObserver(generation: UInt64) {
        manager.vpBleConnectStateChangeBlock = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handle(state, generation: generation)
            }
        }
    }

    private func handle(
        _ state: DeviceConnectState,
        generation: UInt64
    ) {
        switch state {
        case .BlePoweredOff:
            emit(.connection(generation: generation, .radioUnavailable))
        case .BleConnecting:
            emit(.connection(generation: generation, .connecting))
        case .BleConnectSuccess:
            emit(.connection(generation: generation, .connected))
        case .BleConnectFailed:
            emit(.connection(generation: generation, .failed))
        case .BleVerifyPasswordSuccess:
            break
        case .BleVerifyPasswordFailure:
            emit(.password(generation: generation, .rejected))
        case .BleConnectTimeout:
            emit(.connection(generation: generation, .timeout))
        case .BleConfirmTimeout:
            emit(.connection(generation: generation, .confirmationTimeout))
        @unknown default:
            emit(.connection(generation: generation, .failed))
        }
    }

    private func handle(
        _ state: VPDeviceConnectState,
        generation: UInt64
    ) {
        switch state {
        case .connectStateDisConnect:
            emit(.connection(generation: generation, .disconnected))
        case .connectStateConnecting:
            emit(.connection(generation: generation, .connecting))
        case .connectStateConnect:
            emit(.connection(generation: generation, .connected))
        case .connectStateVerifyPasswordSuccess:
            break
        case .connectStateVerifyPasswordFailure:
            emit(.password(generation: generation, .rejected))
        case .connectStateTimeout:
            emit(.connection(generation: generation, .timeout))
        case .confirmStateTimeout:
            emit(.connection(generation: generation, .confirmationTimeout))
        case .discoverNewUpdateFirm:
            break
        @unknown default:
            emit(.connection(generation: generation, .failed))
        }
    }

    private func handle(
        _ result: PasswordSynchronTpye,
        generation: UInt64
    ) {
        switch result {
        case .validationSuccess, .validationAllSuccess:
            let model = manager.peripheralModel
            emit(
                .password(
                    generation: generation,
                    .verified(
                        .init(
                            modelCode: model.map {
                                String($0.deviceNumber)
                            } ?? "",
                            hardwareRevision:
                                model?.deviceTestVersion ?? "",
                            firmwareRevision: model?.deviceVersion ?? ""
                        )
                    )
                )
            )
        case .validationFailed:
            emit(.password(generation: generation, .rejected))
        default:
            emit(.password(generation: generation, .failed))
        }
    }

    private static func map(
        _ state: VPDeviceChargeState
    ) -> VeepooBandSDKChargeState {
        switch state {
        case .normal: return .normal
        case .charging: return .charging
        case .full: return .full
        case .lowPressure: return .unknown
        @unknown default: return .unknown
        }
    }

    private func emit(_ event: VeepooBandSDKEvent) {
        eventHandler?(event)
    }
}
#endif
