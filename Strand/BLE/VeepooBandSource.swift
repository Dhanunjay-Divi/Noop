import Combine
import Foundation
import Security
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
protocol VeepooCredentialAccess: AnyObject {
    func load(deviceID: String) -> VeepooCredentialLoadResult
    func save(_ password: String, deviceID: String) -> Bool
    @discardableResult
    func clear(deviceID: String) -> Bool
}

@MainActor
protocol VeepooCredentialCleanupAccess: AnyObject {
    func markPending(deviceID: String) -> Bool
    func pendingDeviceIDs() -> Set<String>?
    @discardableResult
    func clearPending(deviceID: String) -> Bool
}

@MainActor
final class VeepooCredentialCleanupStore: VeepooCredentialCleanupAccess {
    static let shared = VeepooCredentialCleanupStore()

    private let service = "com.noop.supplier-band.pending-credential-cleanup"
    private let maximumPendingIDs = 64
    private let maximumDeviceIDLength = 256
    private let copyMatching:
        (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let addItem:
        (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let deleteItem: (CFDictionary) -> OSStatus

    init(
        copyMatching: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = SecItemCopyMatching,
        addItem: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = SecItemAdd,
        deleteItem: @escaping (CFDictionary) -> OSStatus = SecItemDelete
    ) {
        self.copyMatching = copyMatching
        self.addItem = addItem
        self.deleteItem = deleteItem
    }

    func markPending(deviceID: String) -> Bool {
        guard valid(deviceID),
              let pending = pendingDeviceIDs()
        else {
            return false
        }
        if pending.contains(deviceID) { return true }
        guard pending.count < maximumPendingIDs else { return false }
        var item = baseQuery(deviceID: deviceID)
        item[kSecValueData as String] = Data("v1".utf8)
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = addItem(item as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    func pendingDeviceIDs() -> Set<String>? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return nil }

        let attributes: [[String: Any]]
        if let rows = result as? [[String: Any]] {
            attributes = rows
        } else if let row = result as? [String: Any] {
            attributes = [row]
        } else {
            return nil
        }
        guard attributes.count <= maximumPendingIDs else { return nil }
        let deviceIDs = attributes.compactMap {
            $0[kSecAttrAccount as String] as? String
        }
        guard deviceIDs.count == attributes.count,
              deviceIDs.allSatisfy(valid)
        else {
            return nil
        }
        return Set(deviceIDs)
    }

    @discardableResult
    func clearPending(deviceID: String) -> Bool {
        guard valid(deviceID) else { return false }
        let status = deleteItem(baseQuery(deviceID: deviceID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func valid(_ deviceID: String) -> Bool {
        !deviceID.isEmpty
            && deviceID.count <= maximumDeviceIDLength
            && deviceID.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private func baseQuery(deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
    }
}

enum VeepooCredentialLoadResult: Equatable {
    case available(String)
    case missing
    case malformed
    case unavailable
}

@MainActor
final class VeepooCredentialStore: VeepooCredentialAccess {
    static let shared = VeepooCredentialStore()
    private let service = "com.noop.supplier-band.transport-password"
    private let copyMatching:
        (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let deleteItem: (CFDictionary) -> OSStatus

    init(
        copyMatching: @escaping (
            CFDictionary,
            UnsafeMutablePointer<CFTypeRef?>?
        ) -> OSStatus = SecItemCopyMatching,
        deleteItem: @escaping (CFDictionary) -> OSStatus = SecItemDelete
    ) {
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
    }

    func load(deviceID: String) -> VeepooCredentialLoadResult {
        guard !deviceID.isEmpty else { return .missing }
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              VeepooBandAdapterCore.isValidPassword(value) else {
            return clear(deviceID: deviceID) ? .malformed : .unavailable
        }
        return .available(value)
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
        let status = deleteItem(baseQuery(deviceID: deviceID) as CFDictionary)
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
    case removal
    case secureCleanup = "secure_cleanup"
    case secureRead = "secure_read"
    case managerLease = "manager_lease"
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
    case terminalBatteryFailure = "terminal_battery_failure"
    case protectedDataAvailable = "protected_data_available"
}

enum VeepooSupplierLifecycleFailure: String {
    case securePersistence = "secure_persistence"
    case secureReadUnavailable = "secure_read_unavailable"
    case registryPersistence = "registry_persistence"
    case cleanupFailed = "cleanup_failed"
    case credentialRestore = "credential_restore"
    case fallbackUnavailable = "fallback_unavailable"
    case staleLease = "stale_lease"
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

@MainActor
enum VeepooSupplierRemoval {
    static func remove(
        deviceID: String,
        credentials: any VeepooCredentialAccess,
        archive: () -> Bool
    ) -> Bool {
        VeepooSupplierLifecycleDiagnostics.record(
            stage: .removal,
            outcome: .began
        )
        let priorCredential: String?
        switch credentials.load(deviceID: deviceID) {
        case .available(let credential):
            priorCredential = credential
        case .missing, .malformed:
            priorCredential = nil
        case .unavailable:
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .removal,
                outcome: .failed,
                failure: .secureReadUnavailable
            )
            return false
        }
        guard credentials.clear(deviceID: deviceID) else {
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .removal,
                outcome: .failed,
                failure: .cleanupFailed
            )
            return false
        }
        guard archive() else {
            let restored = priorCredential.map {
                credentials.save($0, deviceID: deviceID)
            } ?? true
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .removal,
                outcome: .failed,
                failure: restored ? .registryPersistence : .credentialRestore
            )
            return false
        }
        VeepooSupplierLifecycleDiagnostics.record(
            stage: .removal,
            outcome: .completed
        )
        return true
    }
}

@MainActor
enum VeepooPendingCredentialCleanup {
    static func reconcile(
        registeredDeviceIDs: Set<String>?,
        credentials: any VeepooCredentialAccess,
        cleanup: any VeepooCredentialCleanupAccess
    ) {
        guard let registeredDeviceIDs else {
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: .failed,
                failure: .cleanupFailed
            )
            return
        }
        guard let pending = cleanup.pendingDeviceIDs() else {
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: .failed,
                failure: .cleanupFailed
            )
            return
        }
        for deviceID in pending.sorted() {
            let completed: Bool
            if registeredDeviceIDs.contains(deviceID) {
                completed = cleanup.clearPending(deviceID: deviceID)
            } else {
                completed = credentials.clear(deviceID: deviceID)
                    && cleanup.clearPending(deviceID: deviceID)
            }
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: completed ? .completed : .failed,
                failure: completed ? nil : .cleanupFailed
            )
        }
    }
}

/// Registered-source bridge. Supplier live HR updates only `LiveState`; it is
/// intentionally never mapped to `Streams` or inserted into durable history.
@MainActor
final class VeepooBandSource: LiveHRSource {
    nonisolated static let displayFreshnessInterval: TimeInterval = 30

    private let live: LiveState
    private let adapter: any VeepooBandAdapterControlling
    private var password: String?
    private let credentialLoader: (() -> VeepooCredentialLoadResult)?
    private let protectedDataAvailablePublisher: AnyPublisher<Void, Never>
    private let credentialRetryDelaysNanoseconds: [UInt64]
    private let onCredentialRejected: () -> Void
    private let onCredentialPermanentlyUnavailable: () -> Void
    private let onTerminalBatteryFailure: () -> Bool
    private let displayFreshnessInterval: TimeInterval
    private let reconnectDelaysNanoseconds: [UInt64]
    private let reconnectDiscoveryTimeoutNanoseconds: UInt64
    private let now: () -> Date
    private var targetPeripheralID: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var credentialRetryTask: Task<Void, Never>?
    private var protectedDataCancellable: AnyCancellable?
    private var displayFreshnessTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var credentialRetryAttempt = 0
    private var credentialRejected = false
    private var credentialWaitRecorded = false
    private var permanentCredentialFailureHandled = false
    private var terminalBatteryFailureHandled = false
    private var stopped = false
    /// Optional sink for the band's own day-cumulative activity totals.
    private let persistSteps: ((VeepooBandStepsReading) -> Void)?
    /// Optional sink for the night the band scored itself.
    private let persistSleep: ((VeepooBandSleepReading) -> Void)?
    /// One-shot per session: the sleep read triggers a full device-history sync,
    /// which is slow and shares the radio with the live-HR stream.
    private var sleepReadTask: Task<Void, Never>?
    /// Delay before that sync, so live HR is established first.
    private static let sleepReadDelayNanoseconds: UInt64 = 20_000_000_000
    /// Repeating read of the band's step counter. The band owns the count and keeps
    /// accumulating it on-device, so the app only chooses when to read.
    private var stepPollTask: Task<Void, Never>?
    /// Step poll cadence. The counter is a whole-day total, so a slow poll is enough
    /// and keeps radio traffic off the live-HR stream.
    private static let stepPollIntervalNanoseconds: UInt64 = 60_000_000_000

    /// Pending restart of live HR after a transient wear/busy stop.
    private var liveRearmTask: Task<Void, Never>?
    /// Cadence for that restart. Long enough that a band still settling on the
    /// wrist is not hammered, short enough that putting it back on resumes
    /// streaming without waiting for a full BLE reconnect.
    private static let liveRearmDelayNanoseconds: UInt64 = 15_000_000_000
    /// Optional persistence sink. When supplied, accepted supplier live HR is
    /// written to durable storage alongside the display-only readout, so the band
    /// accumulates history like the WHOOP transport does.
    private let persist: ((Int, Date) -> Void)?

    init(
        live: LiveState,
        adapter: any VeepooBandAdapterControlling,
        password: String,
        onCredentialRejected: @escaping () -> Void,
        onTerminalBatteryFailure: @escaping () -> Bool = { true },
        displayFreshnessInterval: TimeInterval = displayFreshnessInterval,
        reconnectDelaysNanoseconds: [UInt64] = [
            2_000_000_000,
            5_000_000_000,
            15_000_000_000,
        ],
        reconnectDiscoveryTimeoutNanoseconds: UInt64 = 12_000_000_000,
        persist: ((Int, Date) -> Void)? = nil,
        persistSteps: ((VeepooBandStepsReading) -> Void)? = nil,
        persistSleep: ((VeepooBandSleepReading) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.persist = persist
        self.persistSteps = persistSteps
        self.persistSleep = persistSleep
        self.live = live
        self.adapter = adapter
        self.password = password
        self.credentialLoader = nil
        self.protectedDataAvailablePublisher =
            Empty<Void, Never>().eraseToAnyPublisher()
        self.credentialRetryDelaysNanoseconds = []
        self.onCredentialRejected = onCredentialRejected
        self.onCredentialPermanentlyUnavailable = {}
        self.onTerminalBatteryFailure = onTerminalBatteryFailure
        self.displayFreshnessInterval = displayFreshnessInterval
        self.reconnectDelaysNanoseconds = reconnectDelaysNanoseconds
        self.reconnectDiscoveryTimeoutNanoseconds =
            reconnectDiscoveryTimeoutNanoseconds
        self.now = now
        adapter.eventHandler = { [weak self] event in self?.handle(event) }
    }

    init(
        live: LiveState,
        adapter: any VeepooBandAdapterControlling,
        credentialLoader: @escaping () -> VeepooCredentialLoadResult,
        protectedDataAvailablePublisher: AnyPublisher<Void, Never>? = nil,
        credentialRetryDelaysNanoseconds: [UInt64] = [
            1_000_000_000,
            5_000_000_000,
            15_000_000_000,
        ],
        onCredentialRejected: @escaping () -> Void,
        onCredentialPermanentlyUnavailable: @escaping () -> Void,
        onTerminalBatteryFailure: @escaping () -> Bool = { true },
        displayFreshnessInterval: TimeInterval = displayFreshnessInterval,
        reconnectDelaysNanoseconds: [UInt64] = [
            2_000_000_000,
            5_000_000_000,
            15_000_000_000,
        ],
        reconnectDiscoveryTimeoutNanoseconds: UInt64 = 12_000_000_000,
        persist: ((Int, Date) -> Void)? = nil,
        persistSteps: ((VeepooBandStepsReading) -> Void)? = nil,
        persistSleep: ((VeepooBandSleepReading) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.persist = persist
        self.persistSteps = persistSteps
        self.persistSleep = persistSleep
        self.live = live
        self.adapter = adapter
        self.password = nil
        self.credentialLoader = credentialLoader
        self.protectedDataAvailablePublisher =
            protectedDataAvailablePublisher
                ?? VeepooBandSource.systemProtectedDataAvailablePublisher()
        self.credentialRetryDelaysNanoseconds =
            credentialRetryDelaysNanoseconds
        self.onCredentialRejected = onCredentialRejected
        self.onCredentialPermanentlyUnavailable =
            onCredentialPermanentlyUnavailable
        self.onTerminalBatteryFailure = onTerminalBatteryFailure
        self.displayFreshnessInterval = displayFreshnessInterval
        self.reconnectDelaysNanoseconds = reconnectDelaysNanoseconds
        self.reconnectDiscoveryTimeoutNanoseconds =
            reconnectDiscoveryTimeoutNanoseconds
        self.now = now
        adapter.eventHandler = { [weak self] event in self?.handle(event) }
    }

    func scan() {
        guard !stopped, let targetPeripheralID else { return }
        startTransportWhenCredentialAvailable(
            targetPeripheralID: targetPeripheralID
        )
    }

    func connect(_ id: UUID) {
        guard !stopped else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        targetPeripheralID = id
        reconnectAttempt = 0
        credentialRetryAttempt = 0
        credentialRejected = false
        permanentCredentialFailureHandled = false
        terminalBatteryFailureHandled = false
        startTransportWhenCredentialAvailable(targetPeripheralID: id)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        credentialRetryTask?.cancel()
        credentialRetryTask = nil
        protectedDataCancellable?.cancel()
        protectedDataCancellable = nil
        displayFreshnessTask?.cancel()
        displayFreshnessTask = nil
        liveRearmTask?.cancel()
        liveRearmTask = nil
        stepPollTask?.cancel()
        stepPollTask = nil
        sleepReadTask?.cancel()
        sleepReadTask = nil
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
            reconnectTask?.cancel()
            reconnectTask = nil
            adapter.reconnect(candidateHandle: candidate.handle)
        case .state(.connected):
            terminalBatteryFailureHandled = false
            guard let password else {
                adapter.disconnect()
                retryCredentialAfterTransientFailure(
                    resetBudget: false,
                    trigger: nil
                )
                return
            }
            adapter.verifyPassword(password)
        case .sleep(let reading):
            persistSleep?(reading)
        case .steps(let reading):
            // Liveness is enforced upstream: the adapter core only accepts a step
            // event while it is in .ready/.startingLive/.streaming, so a late
            // callback from a dropped session is already rejected there. Do NOT
            // gate on live.connected here - that flag only turns true once the
            // first HR SAMPLE is accepted, which is strictly after the first step
            // read, so it would silently discard the opening reading.
            persistSteps?(reading)
        case .battery(let reading):
            NSLog("NOOP-LIVE source battery -> requesting live HR")
            // `.battery` is the point the adapter reaches `.ready`, which is the
            // earliest state that accepts a step read.
            startStepPolling()
            scheduleSleepRead()
            if let percent = reading.percent {
                live.setBattery(Double(percent))
            }
            adapter.startLiveHeartRate()
        case .heartRate(let reading):
            guard Self.freshnessRemaining(
                receivedAt: reading.receivedAt,
                now: now(),
                freshnessInterval: displayFreshnessInterval
            ) != nil else {
                clearDisplayHeartRate()
                return
            }
            reconnectAttempt = 0
            live.setDisplayOnlyHeartRate(
                reading.bpm,
                receivedAt: reading.receivedAt
            )
            persist?(reading.bpm, reading.receivedAt)
            live.connected = true
            scheduleDisplayExpiry(for: reading.receivedAt)
        case .disconnected:
            displayFreshnessTask?.cancel()
            displayFreshnessTask = nil
            live.connected = false
            live.batteryPct = nil
            live.clearBiometrics()
            if !credentialRejected && !terminalBatteryFailureHandled {
                scheduleReconnect()
            }
        case .failed(let stage, let failure):
            if stage == .authentication && failure == .credentialRejected {
                guard !credentialRejected else { return }
                credentialRejected = true
                adapter.disconnect()
                onCredentialRejected()
                return
            }
            if stage == .battery {
                guard !terminalBatteryFailureHandled else { return }
                terminalBatteryFailureHandled = true
                reconnectTask?.cancel()
                reconnectTask = nil
                live.batteryPct = nil
                publishNonStreamingDisplayState()
                adapter.disconnect()
                if !onTerminalBatteryFailure() {
                    scheduleReconnect()
                }
                return
            }
            if stage == .live {
                publishNonStreamingDisplayState()
                // A band that has not yet found a pulse - or that briefly loses skin
                // contact - reports `notWorn`/`busy`, which ends the supplier's live
                // session and leaves the adapter in `.ready`. Nothing else re-arms it,
                // so every later sample is rejected as stale and the session stays dead
                // for the rest of the connection even once the band IS worn. Restart it
                // on a bounded cadence while the transport is still up.
                if failure == .notWorn || failure == .busy {
                    scheduleLiveRearm()
                }
            }
            if stage == .connection || stage == .disconnect {
                reconnectTask?.cancel()
                reconnectTask = nil
                scheduleReconnect()
            }
        case .liveStopped:
            publishNonStreamingDisplayState()
        case .state, .authenticated, .liveStarted:
            break
        }
    }

    private func startTransportWhenCredentialAvailable(
        targetPeripheralID: UUID
    ) {
        guard !stopped else { return }
        if password != nil {
            startBoundedDiscovery(
                targetPeripheralID: targetPeripheralID,
                delayNanoseconds: 0
            )
            return
        }
        retryCredentialAfterTransientFailure(
            resetBudget: false,
            trigger: nil
        )
    }

    private func retryCredentialAfterTransientFailure(
        resetBudget: Bool,
        trigger: VeepooSupplierLifecycleTrigger?
    ) {
        guard !stopped,
              !permanentCredentialFailureHandled,
              let credentialLoader
        else {
            return
        }
        if resetBudget {
            credentialRetryAttempt = 0
        }

        switch credentialLoader() {
        case .available(let credential):
            guard VeepooBandAdapterCore.isValidPassword(credential) else {
                handlePermanentlyUnavailableCredential()
                return
            }
            password = credential
            credentialRetryTask?.cancel()
            credentialRetryTask = nil
            protectedDataCancellable?.cancel()
            protectedDataCancellable = nil
            credentialRetryAttempt = 0
            if credentialWaitRecorded {
                VeepooSupplierLifecycleDiagnostics.record(
                    stage: .secureRead,
                    outcome: .completed,
                    trigger: trigger
                )
                credentialWaitRecorded = false
            }
            guard let targetPeripheralID else { return }
            startBoundedDiscovery(
                targetPeripheralID: targetPeripheralID,
                delayNanoseconds: 0
            )
        case .missing, .malformed:
            handlePermanentlyUnavailableCredential()
        case .unavailable:
            if !credentialWaitRecorded {
                credentialWaitRecorded = true
                VeepooSupplierLifecycleDiagnostics.record(
                    stage: .secureRead,
                    outcome: .failed,
                    failure: .secureReadUnavailable
                )
            }
            installProtectedDataRetryIfNeeded()
            scheduleCredentialRetry()
        }
    }

    private func installProtectedDataRetryIfNeeded() {
        guard protectedDataCancellable == nil else { return }
        protectedDataCancellable = protectedDataAvailablePublisher
            .sink { [weak self] in
                guard let self else { return }
                self.credentialRetryTask?.cancel()
                self.credentialRetryTask = nil
                self.retryCredentialAfterTransientFailure(
                    resetBudget: true,
                    trigger: .protectedDataAvailable
                )
            }
    }

    private func scheduleCredentialRetry() {
        guard !stopped,
              credentialRetryTask == nil,
              credentialRetryAttempt <
                credentialRetryDelaysNanoseconds.count
        else {
            return
        }
        let delay =
            credentialRetryDelaysNanoseconds[credentialRetryAttempt]
        credentialRetryAttempt += 1
        credentialRetryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.credentialRetryTask = nil
            self.retryCredentialAfterTransientFailure(
                resetBudget: false,
                trigger: nil
            )
        }
    }

    private func handlePermanentlyUnavailableCredential() {
        guard !permanentCredentialFailureHandled else { return }
        permanentCredentialFailureHandled = true
        credentialRetryTask?.cancel()
        credentialRetryTask = nil
        protectedDataCancellable?.cancel()
        protectedDataCancellable = nil
        adapter.disconnect()
        onCredentialPermanentlyUnavailable()
    }

    /// Restarts live HR after a transient wear/busy stop. `finishLive` leaves the
    /// adapter in `.ready`, which is exactly the state `startLiveHeartRate()`
    /// requires, so this simply re-issues the request once the band has had time to
    /// settle. Superseded by the next failure and cancelled by `stop()`.
    /// Polls the band's day-cumulative step total while the transport is up. Reads
    /// only; the band owns the counter and nothing is written to the device.
    /// Reads the band's own scored sleep once per session, after live HR has had
    /// time to settle. Read-only; nothing is written to the device.
    private func scheduleSleepRead() {
        guard !stopped, sleepReadTask == nil else { return }
        sleepReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.sleepReadDelayNanoseconds
            )
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.adapter.readSleep()
        }
    }

    private func startStepPolling() {
        guard !stopped, stepPollTask == nil else { return }
        stepPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                self.adapter.readSteps()
                try? await Task.sleep(
                    nanoseconds: Self.stepPollIntervalNanoseconds
                )
            }
        }
    }

    private func scheduleLiveRearm() {
        guard !stopped else { return }
        liveRearmTask?.cancel()
        liveRearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.liveRearmDelayNanoseconds
            )
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.liveRearmTask = nil
            self.adapter.startLiveHeartRate()
        }
    }

    private func scheduleReconnect() {
        guard !stopped,
              reconnectTask == nil,
              let targetPeripheralID,
              reconnectAttempt < reconnectDelaysNanoseconds.count
        else {
            return
        }
        reconnectAttempt += 1
        let delay = reconnectDelaysNanoseconds[reconnectAttempt - 1]
        startBoundedDiscovery(
            targetPeripheralID: targetPeripheralID,
            delayNanoseconds: delay
        )
    }

    private func startBoundedDiscovery(
        targetPeripheralID: UUID,
        delayNanoseconds: UInt64
    ) {
        guard !stopped, reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.adapter.startDiscovery(targetPeripheralID: targetPeripheralID)
            try? await Task.sleep(
                nanoseconds: self.reconnectDiscoveryTimeoutNanoseconds
            )
            guard !Task.isCancelled, !self.stopped else { return }
            self.adapter.stopDiscovery()
            self.reconnectTask = nil
            self.scheduleReconnect()
        }
    }

    static func freshnessRemaining(
        receivedAt: Date,
        now: Date,
        freshnessInterval: TimeInterval = displayFreshnessInterval
    ) -> TimeInterval? {
        let age = now.timeIntervalSince(receivedAt)
        guard age >= 0, age <= freshnessInterval else { return nil }
        return freshnessInterval - age
    }

    private func scheduleDisplayExpiry(for receivedAt: Date) {
        displayFreshnessTask?.cancel()
        guard let remaining = Self.freshnessRemaining(
            receivedAt: receivedAt,
            now: now(),
            freshnessInterval: displayFreshnessInterval
        ) else {
            clearDisplayHeartRate()
            return
        }
        let sleepNanoseconds = UInt64(
            max(0, remaining) * 1_000_000_000
        )
        displayFreshnessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            guard self.live.displayOnlyHeartRateReceivedAt == receivedAt else {
                return
            }
            self.displayFreshnessTask = nil
            self.live.clearDisplayOnlyHeartRate()
        }
    }

    private func clearDisplayHeartRate() {
        displayFreshnessTask?.cancel()
        displayFreshnessTask = nil
        live.clearDisplayOnlyHeartRate()
    }

    private func publishNonStreamingDisplayState() {
        clearDisplayHeartRate()
        live.connected = false
    }

    private static func systemProtectedDataAvailablePublisher()
        -> AnyPublisher<Void, Never>
    {
        #if canImport(UIKit)
        return NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification
        )
        .map { _ in () }
        .eraseToAnyPublisher()
        #else
        return Empty<Void, Never>().eraseToAnyPublisher()
        #endif
    }
}

@MainActor
enum VeepooBandSourceFactory {
    static func hasUsableRegistration(
        for device: PairedDevice,
        credentials: any VeepooCredentialAccess,
        adapterAvailable: Bool = VeepooBandAdapterFactory.productionEnabled
    ) -> Bool {
        guard let availability = credentialAvailability(
            for: device,
            credentials: credentials,
            adapterAvailable: adapterAvailable
        ) else {
            return false
        }
        switch availability {
        case .available(let password):
            return VeepooBandAdapterCore.isValidPassword(password)
        case .unavailable:
            return true
        case .missing, .malformed:
            return false
        }
    }

    static func productionFactory(
        registry: DeviceRegistry,
        live: LiveState,
        credentials: (any VeepooCredentialAccess)? = nil,
        /// Optional durable sink for accepted supplier live HR, keyed by device id.
        /// nil keeps the historic display-only behaviour.
        persistFactory: ((String) -> ((Int, Date) -> Void))? = nil,
        /// Optional durable sink for the band's own day-cumulative activity totals,
        /// keyed by device id. nil collects nothing, as before.
        persistStepsFactory: (
            (String) -> ((VeepooBandStepsReading) -> Void)
        )? = nil,
        /// Optional durable sink for the night the band scored itself.
        persistSleepFactory: (
            (String) -> ((VeepooBandSleepReading) -> Void)
        )? = nil
    ) -> ((String) -> (any LiveHRSource)?)? {
        guard VeepooBandAdapterFactory.productionEnabled else { return nil }
        let credentials = credentials ?? VeepooCredentialStore.shared
        return { deviceID in
            guard let row = registry.devices.first(where: { $0.id == deviceID }),
                  isStructurallyUsable(row, adapterAvailable: true),
                  let adapter =
                    VeepooBandAdapterFactory.makeForApprovedLocalDeviceBuild()
            else {
                return nil
            }

            let reconcilePermanentCredentialFailure = {
                let reconciled = registry.reconcileUnavailableSupplier(
                    deviceID
                )
                VeepooSupplierLifecycleDiagnostics.record(
                    stage: .reconciliation,
                    outcome: reconciled ? .completed : .failed,
                    trigger: .sourceUnavailable,
                    failure: reconciled ? nil : .fallbackUnavailable
                )
            }
            let reconcileAuthenticationRejection = {
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
            let reconcileBatteryFailure = {
                let reconciled = registry.reconcileUnavailableSupplier(
                    deviceID
                )
                VeepooSupplierLifecycleDiagnostics.record(
                    stage: .reconciliation,
                    outcome: reconciled ? .completed : .failed,
                    trigger: .terminalBatteryFailure,
                    failure: reconciled ? nil : .fallbackUnavailable
                )
                return reconciled
            }

            switch credentials.load(deviceID: deviceID) {
            case .available(let password)
                where VeepooBandAdapterCore.isValidPassword(password):
                return VeepooBandSource(
                    live: live,
                    adapter: adapter,
                    password: password,
                    onCredentialRejected:
                        reconcileAuthenticationRejection,
                    onTerminalBatteryFailure: reconcileBatteryFailure,
                    persist: persistFactory?(deviceID),
                    persistSteps: persistStepsFactory?(deviceID),
                    persistSleep: persistSleepFactory?(deviceID)
                )
            case .unavailable:
                return VeepooBandSource(
                    live: live,
                    adapter: adapter,
                    credentialLoader: {
                        credentials.load(deviceID: deviceID)
                    },
                    onCredentialRejected:
                        reconcileAuthenticationRejection,
                    onCredentialPermanentlyUnavailable:
                        reconcilePermanentCredentialFailure,
                    onTerminalBatteryFailure: reconcileBatteryFailure,
                    persist: persistFactory?(deviceID),
                    persistSteps: persistStepsFactory?(deviceID),
                    persistSleep: persistSleepFactory?(deviceID)
                )
            case .available, .missing, .malformed:
                return nil
            }
        }
    }

    private static func credentialAvailability(
        for device: PairedDevice,
        credentials: any VeepooCredentialAccess,
        adapterAvailable: Bool
    ) -> VeepooCredentialLoadResult? {
        guard isStructurallyUsable(
            device,
            adapterAvailable: adapterAvailable
        ) else {
            return nil
        }
        return credentials.load(deviceID: device.id)
    }

    private static func isStructurallyUsable(
        _ device: PairedDevice,
        adapterAvailable: Bool
    ) -> Bool {
        adapterAvailable
            && device.sourceKind == .veepoo
            && device.peripheralId.flatMap(UUID.init(uuidString:)) != nil
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
    private let credentialCleanup: any VeepooCredentialCleanupAccess
    /// Device-id prefix for supplier-band rows. Named once so provenance copy
    /// elsewhere cannot drift from the id format.
    static let deviceIDPrefix = "veepoo-"
    private let deviceID =
        "\(VeepooBandPairingSession.deviceIDPrefix)\(UUID().uuidString.lowercased())"
    private var acceptedPassword = ""
    private var ignoringExpectedDisconnect = false

    init(
        adapter: any VeepooBandAdapterControlling,
        credentials: (any VeepooCredentialAccess)? = nil,
        credentialCleanup: (any VeepooCredentialCleanupAccess)? = nil
    ) {
        self.adapter = adapter
        self.credentials = credentials ?? VeepooCredentialStore.shared
        self.credentialCleanup =
            credentialCleanup ?? VeepooCredentialCleanupStore.shared
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
        if candidate.printedIdentifier == nil {
            phase = .connecting
            adapter.connect(
                candidateHandle: candidate.handle,
                confirmedPrintedIdentifier: ""
            )
        } else {
            phase = .confirmPrintedIdentifier
        }
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
        guard credentialCleanup.markPending(deviceID: deviceID) else {
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: .failed,
                failure: .cleanupFailed
            )
            failRegistration(.cleanupFailed)
            return false
        }
        guard credentials.save(acceptedPassword, deviceID: deviceID) else {
            let credentialCleared = credentials.clear(deviceID: deviceID)
            let cleanupCleared = credentialCleared
                && credentialCleanup.clearPending(deviceID: deviceID)
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: credentialCleared && cleanupCleared
                    ? .completed
                    : .failed,
                failure: credentialCleared && cleanupCleared
                    ? nil
                    : .cleanupFailed
            )
            failRegistration(.securePersistence)
            return false
        }
        // The supplier SDK uses a process-wide manager. Release the pairing
        // owner before publishing the new active row so SourceCoordinator can
        // start the production owner without the pairing session subsequently
        // clearing its observer or disconnecting its link.
        ignoringExpectedDisconnect = true
        adapter.disconnect()
        ignoringExpectedDisconnect = false
        guard register(device) else {
            let credentialCleared = credentials.clear(deviceID: deviceID)
            let cleanupCleared = credentialCleared
                && credentialCleanup.clearPending(deviceID: deviceID)
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: credentialCleared && cleanupCleared
                    ? .completed
                    : .failed,
                failure: credentialCleared && cleanupCleared
                    ? nil
                    : .cleanupFailed
            )
            failRegistration(.registryPersistence)
            return false
        }

        if !credentialCleanup.clearPending(deviceID: deviceID) {
            VeepooSupplierLifecycleDiagnostics.record(
                stage: .secureCleanup,
                outcome: .failed,
                failure: .cleanupFailed
            )
        }
        acceptedPassword = ""
        phase = .idle
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
            if ignoringExpectedDisconnect { return }
            lastFailure = .disconnected
            if phase != .idle { phase = .failed(.disconnected) }
        case .state, .liveStarted, .liveStopped, .steps, .sleep:
            break
        }
    }
}
