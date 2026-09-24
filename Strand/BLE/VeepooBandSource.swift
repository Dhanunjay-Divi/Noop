import Combine
import Foundation
import Security
import WhoopStore

@MainActor
protocol VeepooCredentialAccess: AnyObject {
    func load(deviceID: String) -> String?
    func save(_ password: String, deviceID: String) -> Bool
    @discardableResult
    func clear(deviceID: String) -> Bool
}

@MainActor
final class VeepooCredentialStore: VeepooCredentialAccess {
    static let shared = VeepooCredentialStore()
    private let service = "com.noop.supplier-band.transport-password"

    func load(deviceID: String) -> String? {
        guard !deviceID.isEmpty else { return nil }
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              VeepooBandAdapterCore.isValidPassword(value)
        else {
            clear(deviceID: deviceID)
            return nil
        }
        return value
    }

    func save(_ password: String, deviceID: String) -> Bool {
        guard !deviceID.isEmpty,
              VeepooBandAdapterCore.isValidPassword(password),
              let data = password.data(using: .utf8)
        else {
            return false
        }
        let query = baseQuery(deviceID: deviceID)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear(deviceID: String) -> Bool {
        guard !deviceID.isEmpty else { return false }
        let status = SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
    }
}

enum VeepooSupplierLifecycleStage: String {
    case registration
    case secureCleanup = "secure_cleanup"
    case reconciliation
}

enum VeepooSupplierLifecycleOutcome: String {
    case began
    case completed
    case failed
}

enum VeepooSupplierLifecycleTrigger: String {
    case sourceUnavailable = "source_unavailable"
    case authenticationRejected = "authentication_rejected"
}

enum VeepooSupplierLifecycleFailure: String {
    case securePersistence = "secure_persistence"
    case registryPersistence = "registry_persistence"
    case cleanupFailed = "cleanup_failed"
    case fallbackUnavailable = "fallback_unavailable"
}

@MainActor
enum VeepooSupplierLifecycleDiagnostics {
    static func record(
        stage: VeepooSupplierLifecycleStage,
        outcome: VeepooSupplierLifecycleOutcome,
        trigger: VeepooSupplierLifecycleTrigger? = nil,
        failure: VeepooSupplierLifecycleFailure? = nil
    ) {
        var fields = [
            "stage": stage.rawValue,
            "outcome": outcome.rawValue,
        ]
        if let trigger {
            fields["trigger"] = trigger.rawValue
        }
        if let failure {
            fields["failure_kind"] = failure.rawValue
        }
        AppDiagnosticsRecorder.shared.record(
            "band.supplier_lifecycle",
            fields: fields
        )
    }
}

/// Registered-source bridge. Supplier live HR updates only `LiveState`; it is
/// intentionally never mapped to `Streams` or inserted into durable history.
@MainActor
final class VeepooBandSource: LiveHRSource {
    private let live: LiveState
    private let adapter: any VeepooBandAdapterControlling
    private let password: String
    private let onCredentialRejected: () -> Void
    private var targetPeripheralID: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var credentialRejected = false
    private var stopped = false

    init(
        live: LiveState,
        adapter: any VeepooBandAdapterControlling,
        password: String,
        onCredentialRejected: @escaping () -> Void
    ) {
        self.live = live
        self.adapter = adapter
        self.password = password
        self.onCredentialRejected = onCredentialRejected
        adapter.eventHandler = { [weak self] event in self?.handle(event) }
    }

    func scan() {
        guard !stopped, let targetPeripheralID else { return }
        adapter.startDiscovery(targetPeripheralID: targetPeripheralID)
    }

    func connect(_ id: UUID) {
        guard !stopped else { return }
        targetPeripheralID = id
        reconnectAttempt = 0
        credentialRejected = false
        adapter.startDiscovery(targetPeripheralID: id)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        adapter.disconnect()
        live.connected = false
        live.batteryPct = nil
        live.clearBiometrics()
    }

    private func handle(_ event: VeepooBandAdapterEvent) {
        guard !stopped else { return }
        switch event {
        case .candidate(let candidate):
            guard candidate.peripheralID == targetPeripheralID else { return }
            adapter.reconnect(candidateHandle: candidate.handle)
        case .state(.connected):
            adapter.verifyPassword(password)
        case .battery(let reading):
            if let percent = reading.percent {
                live.setBattery(Double(percent))
            }
            adapter.startLiveHeartRate()
        case .heartRate(let reading):
            reconnectAttempt = 0
            live.setDisplayOnlyHeartRate(
                reading.bpm,
                receivedAt: reading.receivedAt
            )
            live.connected = true
        case .disconnected:
            live.connected = false
            live.batteryPct = nil
            live.clearBiometrics()
            if !credentialRejected { scheduleReconnect() }
        case .failed(let stage, let failure):
            if stage == .authentication && failure == .credentialRejected {
                credentialRejected = true
                adapter.disconnect()
                onCredentialRejected()
                return
            }
            if stage == .connection || stage == .disconnect {
                scheduleReconnect()
            }
        case .state, .authenticated, .liveStarted, .liveStopped:
            break
        }
    }

    private func scheduleReconnect() {
        guard !stopped,
              reconnectTask == nil,
              let targetPeripheralID,
              reconnectAttempt < 3
        else {
            return
        }
        reconnectAttempt += 1
        let delay = UInt64([2, 5, 15][reconnectAttempt - 1])
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.reconnectTask = nil
            self.adapter.startDiscovery(targetPeripheralID: targetPeripheralID)
        }
    }
}

@MainActor
enum VeepooBandSourceFactory {
    static func productionFactory(
        registry: DeviceRegistry,
        live: LiveState,
        credentials: any VeepooCredentialAccess = VeepooCredentialStore.shared
    ) -> ((String) -> (any LiveHRSource)?)? {
        guard VeepooBandAdapterFactory.productionEnabled else { return nil }
        return { deviceID in
            guard let row = registry.devices.first(where: { $0.id == deviceID }),
                  row.sourceKind == .veepoo,
                  row.peripheralId.flatMap(UUID.init(uuidString:)) != nil,
                  let password = credentials.load(deviceID: deviceID),
                  let adapter =
                    VeepooBandAdapterFactory.makeForApprovedLocalDeviceBuild()
            else {
                return nil
            }
            return VeepooBandSource(
                live: live,
                adapter: adapter,
                password: password,
                onCredentialRejected: {
                    let cleared = credentials.clear(deviceID: deviceID)
                    VeepooSupplierLifecycleDiagnostics.record(
                        stage: .secureCleanup,
                        outcome: cleared ? .completed : .failed,
                        trigger: .authenticationRejected,
                        failure: cleared ? nil : .cleanupFailed
                    )
                    let reconciled = registry.reconcileUnavailableSupplier(
                        deviceID
                    )
                    VeepooSupplierLifecycleDiagnostics.record(
                        stage: .reconciliation,
                        outcome: reconciled ? .completed : .failed,
                        trigger: .authenticationRejected,
                        failure: reconciled ? nil : .fallbackUnavailable
                    )
                }
            )
        }
    }
}

@MainActor
final class VeepooBandPairingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case confirmPrintedIdentifier
        case connecting
        case password
        case checkingBattery
        case checkingLiveHeartRate
        case ready
        case failed(VeepooBandAdapterFailure)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [VeepooBandCandidate] = []
    @Published private(set) var selectedCandidate: VeepooBandCandidate?
    @Published private(set) var battery: VeepooBandBatteryReading?
    @Published private(set) var heartRate: VeepooBandHeartRateReading?
    @Published private(set) var lastFailure: VeepooBandAdapterFailure?
    @Published private(set) var registrationFailed = false

    private let adapter: any VeepooBandAdapterControlling
    private let credentials: any VeepooCredentialAccess
    private let deviceID = "veepoo-\(UUID().uuidString.lowercased())"
    private var acceptedPassword = ""

    init(
        adapter: any VeepooBandAdapterControlling,
        credentials: any VeepooCredentialAccess = VeepooCredentialStore.shared
    ) {
        self.adapter = adapter
        self.credentials = credentials
        adapter.eventHandler = { [weak self] event in self?.handle(event) }
    }

    static func makeForApprovedLocalDeviceBuild() -> VeepooBandPairingSession? {
        guard let adapter =
            VeepooBandAdapterFactory.makeForApprovedLocalDeviceBuild()
        else {
            return nil
        }
        return VeepooBandPairingSession(adapter: adapter)
    }

    func start() {
        candidates = []
        selectedCandidate = nil
        battery = nil
        heartRate = nil
        lastFailure = nil
        registrationFailed = false
        acceptedPassword = ""
        phase = .scanning
        adapter.startDiscovery(targetPeripheralID: nil)
    }

    func select(_ candidate: VeepooBandCandidate) {
        guard candidates.contains(candidate) else { return }
        selectedCandidate = candidate
        lastFailure = nil
        phase = .confirmPrintedIdentifier
    }

    func confirmPrintedIdentifier(_ value: String) {
        guard let selectedCandidate else { return }
        lastFailure = nil
        adapter.connect(
            candidateHandle: selectedCandidate.handle,
            confirmedPrintedIdentifier: value
        )
    }

    func submitPassword(_ value: String) {
        guard phase == .password,
              VeepooBandAdapterCore.isValidPassword(value)
        else {
            phase = .failed(.invalidCredential)
            return
        }
        acceptedPassword = value
        lastFailure = nil
        adapter.verifyPassword(value)
    }

    func commitPairedDevice(
        nickname: String?,
        register: (PairedDevice) -> Bool
    ) -> Bool {
        guard phase == .ready,
              let selectedCandidate,
              battery != nil,
              heartRate != nil
        else {
            return false
        }

        let now = Int(Date().timeIntervalSince1970)
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(
            id: deviceID,
            brand: "Veepoo-compatible",
            model: "Compatible supplier band",
            nickname: trimmed?.isEmpty == false ? trimmed : nil,
            peripheralId: selectedCandidate.peripheralID.uuidString,
            sourceKind: .veepoo,
            capabilities: [.hr],
            status: .paired,
            addedAt: now,
            lastSeenAt: now
        )

        registrationFailed = false
        VeepooSupplierLifecycleDiagnostics.record(
            stage: .registration,
            outcome: .began
        )
        guard credentials.save(acceptedPassword, deviceID: deviceID) else {
            failRegistration(.securePersistence)
            return false
        }
        guard register(device) else {
            let cleared = credentials.clear(deviceID: deviceID)
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: cleared ? .completed : .failed,
                failure: cleared ? nil : .cleanupFailed
            )
            failRegistration(.registryPersistence)
            return false
        }

        acceptedPassword = ""
        VeepooSupplierLifecycleDiagnostics.record(
            stage: .registration,
            outcome: .completed
        )
        return true
    }

    func cancel() {
        acceptedPassword = ""
        adapter.disconnect()
        phase = .idle
    }

    private func failRegistration(
        _ failure: VeepooSupplierLifecycleFailure
    ) {
        acceptedPassword = ""
        adapter.disconnect()
        registrationFailed = true
        lastFailure = .internalFailure
        phase = .failed(.internalFailure)
        VeepooSupplierLifecycleDiagnostics.record(
            stage: .registration,
            outcome: .failed,
            failure: failure
        )
    }

    private func handle(_ event: VeepooBandAdapterEvent) {
        switch event {
        case .candidate(let candidate):
            guard !candidates.contains(candidate) else { return }
            candidates.append(candidate)
        case .state(.connecting):
            phase = .connecting
        case .state(.connected):
            phase = .password
        case .authenticated:
            phase = .checkingBattery
        case .battery(let reading):
            battery = reading
            phase = .checkingLiveHeartRate
            adapter.startLiveHeartRate()
        case .heartRate(let reading):
            heartRate = reading
            phase = .ready
        case .failed(_, let failure):
            lastFailure = failure
            if failure == .identifierMismatch {
                phase = .confirmPrintedIdentifier
            } else if failure == .credentialRejected
                        || failure == .invalidCredential {
                acceptedPassword = ""
                phase = .password
            } else {
                phase = .failed(failure)
            }
        case .disconnected:
            lastFailure = .disconnected
            if phase != .idle { phase = .failed(.disconnected) }
        case .state, .liveStarted, .liveStopped:
            break
        }
    }
}
