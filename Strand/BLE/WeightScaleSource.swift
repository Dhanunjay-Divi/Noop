import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol

/// Isolated collector for the Bluetooth SIG Weight Scale Service (0x181D). It has its own central
/// manager and never touches the WHOOP connection. Only standards-compliant 0x2A9D indications are
/// decoded; vendor-private services are intentionally neither scanned nor guessed.
@MainActor
final class WeightScaleSource: NSObject, ObservableObject {
    struct DiscoveredScale: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    struct Capture: Identifiable, Equatable {
        let id = UUID()
        let peripheralID: UUID
        let deviceName: String
        let measurement: WeightScaleMeasurement
        let receivedAt: Date
    }

    @Published private(set) var discovered: [DiscoveredScale] = []
    @Published private(set) var phase: WeightScaleLifecycle.Phase = .idle
    @Published private(set) var statusText = "Not paired"
    @Published private(set) var latestCapture: Capture?
    @Published private(set) var features: WeightScaleFeatures?
    @Published private(set) var pairedPeripheralID: UUID?
    @Published private(set) var pairedName: String?
    @Published private(set) var profileUserID: UInt8?

    private static let service = CBUUID(string: "181D")
    private static let measurement = CBUUID(string: "2A9D")
    private static let feature = CBUUID(string: "2A9E")
    private static let restoreIdentifier = "com.noop.bluetooth.weight-scale"
    private static let pairedIDKey = "noop.weightScale.peripheralID"
    private static let pairedNameKey = "noop.weightScale.name"
    private static let profileUserIDKey = "noop.weightScale.profileUserID"
    private static let profileUserPeripheralKey = "noop.weightScale.profileUserPeripheralID"

    private let defaults: UserDefaults
    private var lifecycle = WeightScaleLifecycle()
    /// Constructed lazily on iOS so merely creating AppModel on a fresh install cannot trigger the
    /// system Bluetooth permission sheet before NOOP has shown its own rationale. A remembered scale is
    /// evidence of a prior explicit pairing gesture, so that path may activate restoration at launch.
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var advertisedNames: [UUID: String] = [:]
    private var pendingConnectID: UUID?
    private var scanTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userStopped = false
    private var wantsResume = false
    private var scanRequested = false

    init(
        defaults: UserDefaults = .standard,
        resumeRememberedRuntimeAtLaunch: Bool = true
    ) {
        self.defaults = defaults
        let restoredPeripheralID = defaults.string(forKey: Self.pairedIDKey).flatMap(UUID.init(uuidString:))
        pairedPeripheralID = restoredPeripheralID
        pairedName = defaults.string(forKey: Self.pairedNameKey)
        if let paired = restoredPeripheralID,
           defaults.string(forKey: Self.profileUserPeripheralKey) == paired.uuidString,
           let raw = defaults.object(forKey: Self.profileUserIDKey) as? Int,
           (0...254).contains(raw) {
            profileUserID = UInt8(raw)
        }
        super.init()
        #if os(iOS)
        if resumeRememberedRuntimeAtLaunch, restoredPeripheralID != nil {
            activateCentralIfNeeded()
        }
        #else
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
    }

    var isScanning: Bool { phase == .scanning }
    var hasPairedScale: Bool { pairedPeripheralID != nil }

    /// Explicit foreground discovery. The scan is service-filtered and bounded to 15 seconds.
    func scan() {
        activateCentralIfNeeded()
        userStopped = false
        wantsResume = false
        scanRequested = true
        pendingConnectID = nil
        discovered.removeAll()
        seen.removeAll()
        advertisedNames.removeAll()
        transition(.userRequestedScan)
        statusText = "Looking for standard Bluetooth scales…"
        startScanIfReady()
    }

    func stopScan() {
        scanRequested = false
        cancelScanTimeout()
        if central?.state == .poweredOn { central.stopScan() }
        guard phase == .scanning else { return }
        transition(.userStopped)
        statusText = hasPairedScale ? "Paired · not listening" : "Scan stopped"
    }

    /// Pair/listen to a scale the user explicitly selected from this scan.
    func connect(_ id: UUID) {
        activateCentralIfNeeded()
        userStopped = false
        wantsResume = false
        scanRequested = false
        cancelScanTimeout()
        stopRadioScanOnly()
        pendingConnectID = id
        transition(.candidateChosen)
        statusText = "Connecting…"
        guard central.state == .poweredOn else { return }
        guard let candidate = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            scanRequested = true
            transition(.userRequestedScan)
            statusText = "Scale moved out of range. Looking again…"
            startScanIfReady()
            return
        }
        connect(candidate)
    }

    /// Resume only a scale the user previously paired. Called at app startup; never starts an open scan.
    func resumePairedScale() {
        guard pairedPeripheralID != nil else { return }
        activateCentralIfNeeded()
        userStopped = false
        wantsResume = true
        transition(.rememberedScaleResume)
        statusText = "Waiting for \(pairedName ?? "paired scale")…"
        connectRememberedIfReady()
    }

    func stopListening() {
        userStopped = true
        wantsResume = false
        scanRequested = false
        pendingConnectID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelScanTimeout()
        stopRadioScanOnly()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        transition(.userStopped)
        statusText = hasPairedScale ? "Paired · listening paused" : "Not paired"
    }

    func forgetPairedScale() {
        stopListening()
        defaults.removeObject(forKey: Self.pairedIDKey)
        defaults.removeObject(forKey: Self.pairedNameKey)
        defaults.removeObject(forKey: Self.profileUserIDKey)
        defaults.removeObject(forKey: Self.profileUserPeripheralKey)
        pairedPeripheralID = nil
        pairedName = nil
        profileUserID = nil
        latestCapture = nil
        features = nil
        statusText = "Not paired"
    }

    /// Select which standards-level user slot is allowed to update this phone's profile. Every decoded
    /// measurement is still stored; non-matching/unknown slots simply cannot overwrite profile weight.
    func chooseProfileUserID(_ userID: UInt8) {
        guard userID != 0xFF, let pairedPeripheralID else { return }
        profileUserID = userID
        defaults.set(Int(userID), forKey: Self.profileUserIDKey)
        defaults.set(pairedPeripheralID.uuidString, forKey: Self.profileUserPeripheralKey)
        // Re-emit the current event so choosing the slot can immediately apply that already-persisted
        // reading through AppModel's idempotent ingest path.
        if let old = latestCapture {
            latestCapture = Capture(peripheralID: old.peripheralID, deviceName: old.deviceName,
                                    measurement: old.measurement, receivedAt: old.receivedAt)
        }
    }

    /// A measurement with no user field is single-user and safe. A concrete slot requires the user's
    /// explicit selection; 0xFF is "unknown user" and is never allowed to drive the profile.
    func mayUpdateProfile(for measurement: WeightScaleMeasurement) -> Bool {
        WeightScaleProfileUserPolicy.allows(measurementUserID: measurement.userID,
                                            selectedUserID: profileUserID)
    }

    private func transition(_ event: WeightScaleLifecycle.Event) {
        phase = lifecycle.handle(event)
    }

    /// The only iOS central construction point. Calls come from an explicit scan/connect action or from
    /// resuming an exact peripheral identifier the user paired previously; a fresh unpaired launch never
    /// reaches here. macOS retains its existing eager construction in `init`.
    private func activateCentralIfNeeded() {
        guard central == nil else { return }
        #if os(iOS)
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
        #else
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
    }

    private func finishTimedScan() {
        guard phase == .scanning else { return }
        scanRequested = false
        cancelScanTimeout()
        stopRadioScanOnly()
        transition(.userStopped)
        statusText = discovered.isEmpty
            ? "No standard 0x181D scale found"
            : "Choose a scale to pair"
    }

    private func stopRadioScanOnly() {
        if central?.state == .poweredOn { central.stopScan() }
    }

    private func cancelScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
    }

    private func scheduleScanTimeout() {
        cancelScanTimeout()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishTimedScan()
        }
    }

    private func startScanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        scheduleScanTimeout()
    }

    private func connectRememberedIfReady() {
        guard let central, central.state == .poweredOn, let id = pairedPeripheralID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            // iOS normally retains the identifier. If it no longer does, do not scan forever in the
            // background; ask for an explicit re-scan so a different scale can never be adopted silently.
            transition(.transportDisconnected(hasRememberedScale: true))
            statusText = "Paired scale needs a new scan"
        }
    }

    private func connect(_ candidate: CBPeripheral) {
        scanRequested = false
        cancelScanTimeout()
        stopRadioScanOnly()
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingConnectID = candidate.identifier
        peripheral = candidate
        seen[candidate.identifier] = candidate
        candidate.delegate = self
        if candidate.state == .connected {
            pendingConnectID = nil
            transition(.transportConnected)
            statusText = "Checking standard weight service…"
            candidate.discoverServices([Self.service])
        } else {
            central.connect(candidate, options: nil)
        }
    }

    private func remember(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let newName = advertisedNames[id] ?? peripheral.name ?? "Bluetooth scale"
        if pairedPeripheralID != id {
            // A user slot belongs to one physical server; never carry it across a scale switch.
            profileUserID = nil
            defaults.removeObject(forKey: Self.profileUserIDKey)
            defaults.removeObject(forKey: Self.profileUserPeripheralKey)
        }
        pairedPeripheralID = id
        pairedName = newName
        defaults.set(id.uuidString, forKey: Self.pairedIDKey)
        defaults.set(newName, forKey: Self.pairedNameKey)
        wantsResume = true
    }

    private func scheduleReconnect() {
        guard !userStopped, pairedPeripheralID != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transition(.rememberedScaleResume)
            self?.connectRememberedIfReady()
        }
    }

    private func rejectProtocol(_ reason: String, peripheral: CBPeripheral) {
        transition(.protocolRejected)
        statusText = reason
        userStopped = true
        central.cancelPeripheralConnection(peripheral)
    }
}

extension WeightScaleSource: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            stopRadioScanOnly()
            transition(.bluetoothBecameUnavailable)
            switch central.state {
            case .unauthorized: statusText = "Bluetooth permission is off"
            case .unsupported: statusText = "Bluetooth LE is unavailable"
            case .poweredOff: statusText = "Bluetooth is off"
            default: statusText = "Bluetooth is getting ready…"
            }
            return
        }
        if scanRequested {
            transition(.userRequestedScan)
            startScanIfReady()
        } else if wantsResume || (pendingConnectID != nil) {
            if let id = pendingConnectID,
               let candidate = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(candidate)
            } else {
                connectRememberedIfReady()
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        seen[id] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Bluetooth scale"
        advertisedNames[id] = name
        let item = DiscoveredScale(id: id, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == id }) {
            discovered[index] = item
        } else {
            discovered.append(item)
        }
        discovered.sort { $0.rssi > $1.rssi }

        if pendingConnectID == id {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingConnectID = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        transition(.transportConnected)
        statusText = "Checking standard weight service…"
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        transition(.transportDisconnected(hasRememberedScale: pairedPeripheralID != nil))
        statusText = error.map { "Couldn't connect: \($0.localizedDescription)" }
            ?? "Scale unavailable. Step on it to wake it."
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        guard !userStopped else { return }
        transition(.transportDisconnected(hasRememberedScale: pairedPeripheralID != nil))
        statusText = "Waiting for \(pairedName ?? "paired scale")…"
        scheduleReconnect()
    }

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let pairedID = pairedPeripheralID,
              let match = restored.first(where: { $0.identifier == pairedID }) else { return }
        userStopped = false
        wantsResume = true
        peripheral = match
        seen[match.identifier] = match
        match.delegate = self
        if match.state == .connected {
            transition(.transportConnected)
            match.discoverServices([Self.service])
        } else {
            transition(.rememberedScaleResume)
        }
    }
    #endif
}

extension WeightScaleSource: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            rejectProtocol("Service check failed: \(error.localizedDescription)", peripheral: peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            rejectProtocol("Unsupported: no standard Weight Scale Service (0x181D)", peripheral: peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.measurement, Self.feature], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            rejectProtocol("Characteristic check failed: \(error.localizedDescription)", peripheral: peripheral)
            return
        }
        guard let chars = service.characteristics,
              let measurement = chars.first(where: { $0.uuid == Self.measurement }),
              measurement.properties.contains(.indicate) else {
            rejectProtocol("Unsupported: 0x2A9D standard indications are missing", peripheral: peripheral)
            return
        }
        if let feature = chars.first(where: { $0.uuid == Self.feature }) {
            peripheral.readValue(for: feature)
        }
        statusText = "Enabling weight measurements…"
        peripheral.setNotifyValue(true, for: measurement) // CoreBluetooth enables indication for indicate-only GATT
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.measurement else { return }
        guard error == nil, characteristic.isNotifying else {
            rejectProtocol("Couldn't enable standard weight indications", peripheral: peripheral)
            return
        }
        remember(peripheral)
        transition(.measurementCharacteristicValidated)
        statusText = "Listening · step on \(pairedName ?? "the scale")"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == Self.feature {
            features = WeightScaleFeatures.decode([UInt8](data))
            return
        }
        guard characteristic.uuid == Self.measurement else { return }
        do {
            let decoded = try WeightScaleMeasurementDecoder.decode([UInt8](data))
            let received = Date()
            let name = advertisedNames[peripheral.identifier] ?? pairedName ?? peripheral.name ?? "Bluetooth scale"
            latestCapture = Capture(peripheralID: peripheral.identifier,
                                    deviceName: name,
                                    measurement: decoded,
                                    receivedAt: received)
            statusText = String(format: "Received %.1f kg", decoded.weightKg)
        } catch WeightScaleDecodeError.measurementUnsuccessful {
            statusText = "Scale reported an unsuccessful measurement"
        } catch {
            statusText = "Ignored a malformed 0x2A9D measurement"
        }
    }
}
