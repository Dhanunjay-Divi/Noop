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

    func readSteps() {
        core.readSteps()
    }

    func readSleep() {
        core.readSleep()
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
    /// Bounded re-arm for a battery read the supplier stack drops when it is
    /// issued while authentication is still settling.
    private static let batteryAttemptLimit = 6
    private static let batteryRetryInterval: TimeInterval = 2
    private var batteryRetry: Timer?
    private var batteryAttempts = 0

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
        batteryRetry?.invalidate()
        batteryAttempts = 0
        requestBattery(generation: generation)
        batteryRetry = Timer.scheduledTimer(
            withTimeInterval: Self.batteryRetryInterval,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.batteryAttempts < Self.batteryAttemptLimit else {
                    timer.invalidate()
                    self.batteryRetry = nil
                    return
                }
                self.requestBattery(generation: generation)
            }
        }
    }

    private var loggedCapabilities = false

    /// One-shot record of what THIS unit reports it can do. Booleans only - no
    /// health values - so the app can gate optional signals on the device's own
    /// feature report instead of assuming the SDK's full surface is present.
    private func logDeviceCapabilitiesOnce() {
        guard !loggedCapabilities, let model = manager.peripheralModel else {
            return
        }
        loggedCapabilities = true
        NSLog(
            "NOOP-CAP hrv=%d hrvAllDay=%d bp=%d met=%d emotion=%d glance=%d motion=%d",
            model.isSupportHRVTest ? 1 : 0,
            model.hrvSupportAllDay ? 1 : 0,
            model.isSupportBPTest ? 1 : 0,
            model.isSupportMetTest ? 1 : 0,
            model.isSupportEmotionTest ? 1 : 0,
            model.supportHealthGlanceTest ? 1 : 0,
            model.isSupportMotionState ? 1 : 0
        )
        // The typed feature flags the app previously never read. A zero here is the
        // device saying it has no such sensor, which is why an optional signal must
        // be gated on these rather than on the SDK merely exposing a selector.
        NSLog(
            "NOOP-CAP2 oxygen=%ld oxygenAuto=%ld bloodOxygen=%lu hrvType=%ld resRate=%ld fiveProtocol=%ld",
            model.oxygenType,
            model.oxygenAutoDetectType,
            model.bloodOxygenType,
            model.hrvType,
            model.resRateType,
            model.fiveProtocolType
        )
    }

    /// Issues one battery read. The supplier stack delivers two password
    /// callbacks, and a battery command issued from the first — 1ms in, while
    /// authentication is still settling — is accepted and then silently
    /// dropped. `readBattery` therefore re-arms this a bounded number of times
    /// so the reading still lands instead of stranding the adapter in
    /// `.readingBattery`, which is what kept live HR from ever starting.
    private func requestBattery(generation: UInt64) {
        guard let peripheral = manager.peripheralManage else {
            // Only the first attempt may fail the connection; a later retry
            // losing the peripheral is reported by the connection path itself.
            if batteryAttempts == 0 {
                emit(.connection(generation: generation, .failed))
            }
            batteryRetry?.invalidate()
            batteryRetry = nil
            return
        }
        logDeviceCapabilitiesOnce()
        batteryAttempts += 1
        NSLog("NOOP-LIVE battery attempt=%d", batteryAttempts)
        peripheral.veepooSDKReadDeviceBatteryAndChargeInfo {
            [weak self] isPercent, chargeState, isLow, value in
            let event = VeepooBandSDKBatteryEvent(
                isPercent: isPercent,
                chargeState: Self.map(chargeState),
                isLow: isLow,
                value: Int(value)
            )
            NSLog("NOOP-LIVE battery delivered")
            Task { @MainActor [weak self] in
                self?.batteryRetry?.invalidate()
                self?.batteryRetry = nil
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
            // Outcome-only diagnostics: the sample case deliberately logs
            // nothing, because a bpm is a health value.
            switch state {
            case .start:
                event = .started
                NSLog("NOOP-LIVE started")
            case .testing:
                event = .sample(bpm: Int(value), receivedAt: receivedAt)
            case .notWear:
                event = .notWorn
                NSLog("NOOP-LIVE notWorn")
            case .deviceBusy:
                event = .busy
                NSLog("NOOP-LIVE busy")
            case .over:
                event = .stopped
                NSLog("NOOP-LIVE stopped")
            @unknown default:
                event = .stopped
                NSLog("NOOP-LIVE unknown")
            }
            Task { @MainActor [weak self] in
                self?.emit(.live(generation: generation, event))
            }
        }
    }

    /// Reads the band's day-cumulative step total for today.
    ///
    /// This goes through `VPDataBaseOperation`, NOT the
    /// `veepooSDK_readStepDataWithDayNumber:` instance method: on this SDK the
    /// instance method is a bare `ret` stub on `VPPeripheralBaseManage`, so the
    /// completion block is never retained and never fires. The class method does
    /// issue the supplier's own step command to the band for a same-day query and
    /// calls back exactly once, on the main queue, about half a second later.
    func readSteps(generation: UInt64) {
        // The band's address may change across verification, so it is read from the
        // live peripheral model rather than the scan-time candidate.
        guard let model = manager.peripheralModel,
              let address = model.deviceAddress,
              !address.isEmpty
        else { return }
        VPDataBaseOperation.veepooSDKGetStepData(
            withDate: Self.supplierDayFormatter.string(from: Date()),
            andTableID: address,
            // The stature already configured on the band. It scales only the
            // vendor's distance/calorie conversion, never the step count, and is
            // read-only here: correcting it would be a BLE write to the device.
            changeUserStature: model.deviceStature
        ) { [weak self] stepDict in
            guard let raw = stepDict else { return }
            // The documented keys are capitalised, but the SDK's own fallback path
            // keys on lowercase, so both spellings are accepted.
            guard let steps = Self.intValue(raw["Step"] ?? raw["step"]) else {
                return
            }
            NSLog("NOOP-LIVE steps read ok")
            Task { @MainActor [weak self] in
                self?.emit(
                    .steps(
                        generation: generation,
                        VeepooBandSDKStepsEvent(
                            steps: steps,
                            distanceKm: Self.doubleValue(
                                raw["Dis"] ?? raw["dis"]
                            ),
                            kcal: Self.doubleValue(raw["Cal"] ?? raw["cal"])
                        )
                    )
                )
            }
        }
    }

    /// The supplier hands these back as either NSNumber or NSString depending on
    /// firmware, so both are accepted and anything else is dropped rather than
    /// coerced into a wrong number.
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? Double(s).map(Int.init) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Asks the band for its own scored sleep for last night.
    ///
    /// Two steps, because the instance-level `veepooSDK_readSleepDataWithDayNumber:`
    /// is a `ret` stub on the concrete manager exactly like the step one: first sync
    /// the device's stored days (that selector IS implemented on `VPPeripheralManage`),
    /// then read back only the sleep rows. NOOP reads sleep fields and nothing else -
    /// the sync also populates vendor tables this app deliberately never touches.
    func readSleep(generation: UInt64) {
        guard let peripheral = manager.peripheralManage,
              let model = manager.peripheralModel,
              let address = model.deviceAddress,
              !address.isEmpty
        else { return }
        NSLog("NOOP-SLEEP sync requested")
        peripheral.veepooSdkStartReadDeviceAllData {
            [weak self] state, totalDay, currentDay, progress in
            NSLog(
                "NOOP-SLEEP sync state=%ld days=%lu cur=%lu pct=%lu",
                state.rawValue, totalDay, currentDay, progress
            )
            // Only read once the device has finished handing over its days.
            guard state == .complete else { return }
            Task { @MainActor [weak self] in
                self?.emitSleep(generation: generation, address: address)
                // Sequenced, never concurrent: the supplier forbids overlapping
                // history reads, and this is the one place the previous one is known
                // to have finished.
                self?.probeHrv(generation: generation)
            }
        }
    }

    /// Read-only probe: does this unit actually hand over banked R-R intervals?
    ///
    /// The SDK gates this read on the device's protocol type and reports a gated bail
    /// as Complete-with-zero-days — a success-shaped callback carrying nothing — so
    /// the only honest way to know is to call it and count what comes back. Counts
    /// only; an R-R interval is a health value and is never logged.
    func probeHrv(generation: UInt64) {
        guard let peripheral = manager.peripheralManage,
              let model = manager.peripheralModel,
              let address = model.deviceAddress, !address.isEmpty
        else { return }
        NSLog("NOOP-HRV sync requested")
        peripheral.veepooSdkStartReadDeviceHrvData {
            [weak self] state, totalDay, currentDay, progress in
            NSLog(
                "NOOP-HRV sync state=%ld days=%lu cur=%lu pct=%lu",
                state.rawValue, totalDay, currentDay, progress
            )
            guard state == .complete else { return }
            Task { @MainActor [weak self] in
                self?.countHrvRows(address: address, syncedDays: totalDay)
            }
        }
    }

    /// Counts what actually landed in the supplier's HRV table. Row and beat COUNTS
    /// only - never a value, never an interval.
    private func countHrvRows(address: String, syncedDays: UInt) {
        var totalRows = 0
        var rowsWithBeats = 0
        var beats = 0
        var plausibleRaw = 0
        var plausibleScaled = 0
        var zeroBeats = 0
        var nonZeroBeats = 0
        var maxRaw: Double = 0
        for back in 0..<2 {
            let day = Self.supplierDayFormatter.string(
                from: Date().addingTimeInterval(TimeInterval(-86_400 * back))
            )
            let rows = (VPDataBaseOperation.veepooSDKGetDeviceHrvData(
                withDate: day,
                andTableID: address
            ) as? [[AnyHashable: Any]]) ?? []
            totalRows += rows.count
            for row in rows {
                // Documented as a per-minute array of every R-R interval.
                if let hearts = row["hearts"] as? [Any], !hearts.isEmpty {
                    rowsWithBeats += 1
                    beats += hearts.count
                    // Which interpretation puts the beats inside a physiological R-R
                    // window? COUNTS only - an interval is a health value and is
                    // never logged. 300...2000 ms is the same window HRVAnalyzer uses.
                    for beat in hearts {
                        let raw: Double?
                        if let n = beat as? NSNumber { raw = n.doubleValue }
                        else if let t = beat as? String { raw = Double(t) }
                        else { raw = nil }
                        guard let raw else { continue }
                        if (300...2000).contains(raw) { plausibleRaw += 1 }
                        if (300...2000).contains(raw * 10) { plausibleScaled += 1 }
                        // Distinguishes "the band never measured" from "we are
                        // decoding it wrong". Zero is not a physiological value, so
                        // counting zeros logs no health data.
                        if raw == 0 { zeroBeats += 1 } else { nonZeroBeats += 1 }
                        maxRaw = max(maxRaw, raw)
                    }
                }
            }
        }
        NSLog(
            "NOOP-HRV table syncedDays=%lu rows=%d rowsWithBeats=%d beats=%d",
            syncedDays, totalRows, rowsWithBeats, beats
        )
        NSLog(
            "NOOP-HRV plausible raw=%d x10=%d ofBeats=%d",
            plausibleRaw, plausibleScaled, beats
        )
        NSLog(
            "NOOP-HRV zeros=%d nonZero=%d maxRaw=%d parsedAny=%d",
            zeroBeats, nonZeroBeats, Int(maxRaw),
            (zeroBeats + nonZeroBeats)
        )
    }

    /// Reads back the most recent scored night and maps it onto NOOP's own shape.
    ///
    /// Both today and yesterday are queried: the band files a night under a single
    /// date key, and which one depends on when the session started, so a night that
    /// began before midnight is not under today's key.
    private func emitSleep(generation: UInt64, address: String) {
        let today = Date()
        let yesterday = today.addingTimeInterval(-86_400)
        var rows: [[AnyHashable: Any]] = []
        for date in [today, yesterday] {
            let key = Self.supplierDayFormatter.string(from: date)
            let dayRows = (VPDataBaseOperation.veepooSDKGetSleepData(
                withDate: key,
                andTableID: address
            ) as? [[AnyHashable: Any]]) ?? []
            // Counts only - a sleep duration is a health value.
            NSLog("NOOP-SLEEP rows day=%@ n=%d", key, dayRows.count)
            rows.append(contentsOf: dayRows)
        }
        guard !rows.isEmpty else { return }

        // The band reports each sleep period separately; take the longest as the
        // night rather than summing unrelated naps into one block.
        var best: (total: Double, row: [AnyHashable: Any])?
        for row in rows {
            let hours = Self.doubleValue(row["SLE_HOUR"]) ?? 0
            let minutes = Self.doubleValue(row["SLE_MINUTE"]) ?? 0
            let total = hours * 60 + minutes
            guard total > 0 else { continue }
            if best == nil || total > best!.total { best = (total, row) }
        }
        guard let best else {
            NSLog("NOOP-SLEEP no row with a positive duration")
            return
        }
        guard let start = Self.sleepTimestamp(best.row["SLEEP_TIME"]),
              let end = Self.sleepTimestamp(best.row["WAKE_TIME"]),
              end > start
        else {
            NSLog("NOOP-SLEEP unparseable session bounds")
            return
        }

        NSLog("NOOP-SLEEP read ok staged=%d",
              Self.sleepEfficiency(best.row["SLE_LINE"]) != nil ? 1 : 0)
        emit(
            .sleep(
                generation: generation,
                VeepooBandSDKSleepEvent(
                    startTs: start,
                    endTs: end,
                    totalMin: best.total,
                    deepMin: Self.doubleValue(best.row["DEEP_HOUR"]).map { $0 * 60 },
                    lightMin: Self.doubleValue(best.row["LIGHT_HOUR"]).map { $0 * 60 },
                    awakenings: Self.intValue(best.row["WakeUpTime"]),
                    efficiency: Self.sleepEfficiency(best.row["SLE_LINE"])
                )
            )
        )
    }

    /// Measured sleep efficiency from the band's own staging curve: one character
    /// per 5-minute epoch, 0=light, 1=deep, 2=awake. Efficiency is asleep epochs
    /// over total epochs, a real ratio in [0,1].
    ///
    /// Deliberately NOT asleep-time over in-bed-span: the band derives both from
    /// the same figures, so that ratio is a constant 1.0 and would present a
    /// duration as a sleep-quality score. Absent or unparseable curve -> nil.
    private static func sleepEfficiency(_ any: Any?) -> Double? {
        guard let line = any as? String else { return nil }
        var total = 0
        var asleep = 0
        for ch in line {
            switch ch {
            case "0", "1":
                total += 1
                asleep += 1
            case "2":
                total += 1
            default:
                continue
            }
        }
        guard total > 0 else { return nil }
        return Double(asleep) / Double(total)
    }

    /// The supplier stamps these as "yyyy/MM/dd HH:mm" in device-local time.
    private static func sleepTimestamp(_ any: Any?) -> Int? {
        guard let text = any as? String, !text.isEmpty else { return nil }
        return sleepTimeFormatter.date(from: text)
            .map { Int($0.timeIntervalSince1970) }
    }

    private static let sleepTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    private static let supplierDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
                            modelCode: {
                                return model.map { String($0.deviceNumber) } ?? ""
                            }(),
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
