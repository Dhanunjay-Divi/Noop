import Foundation
import WhoopStore

#if os(iOS)
import MetricKit
import UIKit
#endif

/// Allocation-free frame-gap accumulator used by the production scroll monitor.
///
/// It stores summaries rather than individual frames so diagnostics cannot become a source of scrolling
/// pressure. A 50 ms gap is visible jank on both 60 Hz and ProMotion displays; 150 ms is a severe hitch.
struct ScrollHitchAccumulator {
    enum Classification: Equatable {
        case regular
        case hitch
        case severe
    }

    static let hitchThresholdMs: Double = 50
    static let severeThresholdMs: Double = 150
    static let maximumAcceptedDurationMs: Double = 5_000

    private(set) var frameCount = 0
    private(set) var hitchCount = 0
    private(set) var severeHitchCount = 0
    private(set) var totalDurationMs: Double = 0
    private(set) var worstDurationMs: Double = 0

    var meanDurationMs: Double {
        frameCount > 0 ? totalDurationMs / Double(frameCount) : 0
    }

    @discardableResult
    mutating func record(durationMs: Double) -> Classification? {
        guard durationMs > 0, durationMs <= Self.maximumAcceptedDurationMs else { return nil }
        frameCount += 1
        totalDurationMs += durationMs
        worstDurationMs = max(worstDurationMs, durationMs)

        if durationMs >= Self.severeThresholdMs {
            hitchCount += 1
            severeHitchCount += 1
            return .severe
        }
        if durationMs >= Self.hitchThresholdMs {
            hitchCount += 1
            return .hitch
        }
        return .regular
    }
}

/// Lightweight, always-on diagnostics for app freezes and slow launches.
///
/// The recorder deliberately stores operational facts only: lifecycle edges, fixed screen names,
/// operation durations, process memory, database file size, and main-thread responsiveness. It never
/// writes health rows, account identifiers, credentials, free-form user text, or network payloads.
///
/// Storage is bounded and local to Caches:
/// - the current and previous app sessions are each capped to `sessionCapBytes`;
/// - MetricKit's delayed Apple-authored crash/hang payloads are capped to `metricKitCapBytes`;
/// - every export still passes through TestBundleAssembler's whole-bundle redaction step.
final class AppDiagnosticsRecorder: NSObject {
    struct OperationToken: Sendable {
        fileprivate let id: String
        fileprivate let name: String
        fileprivate let startedAtUptime: TimeInterval
    }

    private struct DiagnosticEntryCandidate: Sendable {
        let name: String
        let url: URL
    }

    static let shared = AppDiagnosticsRecorder()

    static let currentSessionEntryName = "app-session-current.jsonl"
    static let previousSessionEntryName = "app-session-previous.jsonl"
    static let metricKitEntryName = "apple-performance-diagnostics.jsonl"

    static let sessionCapBytes = 512 * 1024
    static let metricKitCapBytes = 2 * 1024 * 1024
    private static let trimSlackBytes = 64 * 1024
    private static let metricPayloadIDsKey = "appDiagnostics.metricPayloadIDs.v1"
    static let mainThreadStallThresholdSeconds: TimeInterval = 1
    private static let watchdogIntervalMilliseconds = 500
    private static let sensitiveFieldFragments = [
        "account_id",
        "account_scope",
        "address",
        "authorization",
        "biometric",
        "body",
        "challenge_id",
        "claim_id",
        "contact_id",
        "cookie",
        "credential",
        "delivery_id",
        "device_id",
        "dispatch_id",
        "email",
        "endpoint",
        "enrollment_id",
        "health_value",
        "incident_id",
        "installation_id",
        "invite",
        "journal",
        "latitude",
        "location",
        "longitude",
        "member_id",
        "message",
        "note",
        "object_key",
        "otp",
        "password",
        "path",
        "payload",
        "phone",
        "poke_id",
        "profile_id",
        "query",
        "request_id",
        "serial",
        "session_id",
        "secret",
        "signed_url",
        "source_id",
        "text",
        "token",
        "url",
        "user_id",
        "uuid",
    ]

    private let directory: URL
    private let ioQueue = DispatchQueue(label: "com.noop.app-diagnostics.io", qos: .utility)
    private let ioQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private var operationCounter: UInt64 = 0
    private var started = false

    #if os(iOS)
    private let watchdogQueue = DispatchQueue(
        label: "com.noop.app-diagnostics.watchdog",
        qos: .utility
    )
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogActive = false
    private var pingSequence: UInt64 = 0
    private var pendingPing: (id: UInt64, startedAt: TimeInterval)?
    private var stallWasLogged = false
    private var lastHeartbeatAt: TimeInterval = 0
    private var systemObserversInstalled = false
    #endif

    private override init() {
        directory = Self.defaultDirectory()
        super.init()
        ioQueue.setSpecific(key: ioQueueKey, value: 1)
    }

    /// Internal initializer for deterministic filesystem tests. It never subscribes to MetricKit unless
    /// `start(subscribeToSystem:)` is explicitly called with the default `true` on iOS.
    init(directory: URL) {
        self.directory = directory
        super.init()
        ioQueue.setSpecific(key: ioQueueKey, value: 1)
    }

    deinit {
        #if os(iOS)
        if systemObserversInstalled {
            NotificationCenter.default.removeObserver(self)
            MXMetricManager.shared.remove(self)
        }
        watchdogTimer?.cancel()
        #endif
    }

    /// Start one process session. This is synchronous only for the tiny rotate/create operation so a
    /// marker is on disk before AppModel/database startup can hang. Later appends happen off the main
    /// thread. Calling it twice in one process is a no-op.
    func start(subscribeToSystem: Bool = true) {
        let didStart = withIOQueue { () -> Bool in
            guard !started else { return false }
            started = true
            prepareDirectoryAndRotateSession()
            appendEvent(
                "process.launch",
                fields: [
                    "app_version": Self.appVersion,
                    "app_build": Self.appBuild,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                ],
                includeResourceSnapshot: true,
                at: Date(),
                uptime: ProcessInfo.processInfo.systemUptime
            )
            return true
        }
        guard didStart else { return }

        #if os(iOS)
        guard subscribeToSystem else { return }
        installSystemObservers()
        startWatchdog()

        let manager = MXMetricManager.shared
        manager.add(self)
        // MetricKit delivery is delayed and best-effort. Persist already-available payloads immediately,
        // then the subscriber callbacks below collect future deliveries. Stable payload ids deduplicate
        // the same 24-hour report when it appears through both paths. Reading and serializing these
        // potentially large payloads stays off the launch thread; diagnostics must never make launch
        // responsiveness worse.
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            for payload in manager.pastDiagnosticPayloads.suffix(4) {
                self.persistOnIOQueue(payload)
            }
            for payload in manager.pastPayloads.suffix(2) {
                self.persistOnIOQueue(payload)
            }
        }
        #endif
    }

    /// Append a fixed operational breadcrumb. Callers should use stable event/field names and never pass
    /// user-entered content. Values are length-bounded as a second guard against accidental large writes.
    func record(_ event: String,
                fields: [String: String] = [:],
                includeResourceSnapshot: Bool = false) {
        let safeEvent = Self.sanitizedToken(event)
        let safeFields = Self.sanitizedFields(fields)
        let at = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.appendEvent(
                safeEvent,
                fields: safeFields,
                includeResourceSnapshot: includeResourceSnapshot,
                at: at,
                uptime: uptime
            )
        }
    }

    /// Pair begin/end breadcrumbs around an operation that may contend with the UI. A process killed or
    /// frozen before `endOperation` leaves the unmatched begin marker, which is itself useful evidence.
    func beginOperation(_ name: String,
                        fields: [String: String] = [:]) -> OperationToken {
        stateLock.lock()
        operationCounter &+= 1
        let id = "op_\(operationCounter)"
        stateLock.unlock()

        let token = OperationToken(
            id: id,
            name: Self.sanitizedToken(name),
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        var eventFields = fields
        eventFields["operation"] = token.name
        eventFields["operation_id"] = token.id
        record("operation.begin", fields: eventFields)
        return token
    }

    func endOperation(_ token: OperationToken,
                      outcome: String = "completed",
                      fields: [String: String] = [:],
                      includeResourceSnapshot: Bool = false) {
        var eventFields = fields
        eventFields["operation"] = token.name
        eventFields["operation_id"] = token.id
        eventFields["outcome"] = Self.sanitizedToken(outcome)
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - token.startedAtUptime)
        eventFields["duration_ms"] = String(Int((elapsed * 1_000).rounded()))
        record(
            "operation.end",
            fields: eventFields,
            includeResourceSnapshot: includeResourceSnapshot
        )
    }

    #if os(iOS)
    /// Scene activity gates both the watchdog and minute heartbeat. The timer remains allocated for the
    /// process lifetime but performs no pings or snapshots while the app is not active.
    func setApplicationActive(_ active: Bool) {
        watchdogQueue.async { [weak self] in
            guard let self else { return }
            self.watchdogActive = active
            self.pendingPing = nil
            self.stallWasLogged = false
            if active {
                self.lastHeartbeatAt = 0
                self.record("scene.active", includeResourceSnapshot: true)
            } else {
                self.record("scene.not_active")
            }
        }
    }
    #else
    func setApplicationActive(_ active: Bool) {
        record(active ? "scene.active" : "scene.not_active")
    }
    #endif

    /// Snapshot the already-bounded local files for TestBundleAssembler. No health database is copied.
    /// The IO queue barrier guarantees every breadcrumb enqueued before report assembly is visible.
    func diagnosticEntries() -> [FileExport.BundleEntry] {
        let candidates = diagnosticEntryCandidates
        return withIOQueue { Self.readDiagnosticEntries(candidates) }
    }

    /// Async report-builder entrypoint. The serial queue remains the ordering barrier, but callers on the
    /// main actor suspend instead of synchronously waiting on utility-priority file IO.
    func diagnosticEntriesAsync() async -> [FileExport.BundleEntry] {
        let candidates = diagnosticEntryCandidates
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: Self.readDiagnosticEntries(candidates))
            }
        }
    }

    private var diagnosticEntryCandidates: [DiagnosticEntryCandidate] {
        [
            DiagnosticEntryCandidate(
                name: Self.currentSessionEntryName,
                url: currentSessionURL
            ),
            DiagnosticEntryCandidate(
                name: Self.previousSessionEntryName,
                url: previousSessionURL
            ),
            DiagnosticEntryCandidate(
                name: Self.metricKitEntryName,
                url: metricKitURL
            ),
        ]
    }

    private static func readDiagnosticEntries(
        _ candidates: [DiagnosticEntryCandidate]
    ) -> [FileExport.BundleEntry] {
        candidates.compactMap { candidate in
            guard let data = try? Data(contentsOf: candidate.url), !data.isEmpty else {
                return nil
            }
            return FileExport.BundleEntry(name: candidate.name, data: data)
        }
    }

    // MARK: - Bounded JSONL storage

    private var currentSessionURL: URL {
        directory.appendingPathComponent("current-session.jsonl")
    }

    private var previousSessionURL: URL {
        directory.appendingPathComponent("previous-session.jsonl")
    }

    private var metricKitURL: URL {
        directory.appendingPathComponent("metrickit.jsonl")
    }

    private func prepareDirectoryAndRotateSession() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: previousSessionURL.path) {
            try? fm.removeItem(at: previousSessionURL)
        }
        if fm.fileExists(atPath: currentSessionURL.path) {
            try? fm.moveItem(at: currentSessionURL, to: previousSessionURL)
        }
        fm.createFile(atPath: currentSessionURL.path, contents: nil)
        applyFileProtection(to: currentSessionURL)
        applyFileProtection(to: previousSessionURL)
        applyFileProtection(to: metricKitURL)
    }

    private func appendEvent(_ event: String,
                             fields: [String: String],
                             includeResourceSnapshot: Bool,
                             at: Date,
                             uptime: TimeInterval) {
        var object: [String: Any] = [
            "schema": 1,
            "at": Self.timestamp(at),
            "uptime_ms": Int((uptime * 1_000).rounded()),
            "event": event,
        ]
        if !fields.isEmpty { object["fields"] = fields }
        if includeResourceSnapshot { object["resources"] = resourceSnapshot() }
        appendJSONObject(object, to: currentSessionURL, capBytes: Self.sessionCapBytes)
    }

    private func appendJSONObject(_ object: [String: Any], to url: URL, capBytes: Int) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        data.append(0x0A)

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            applyFileProtection(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            return
        }

        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > capBytes + Self.trimSlackBytes,
              let existing = try? Data(contentsOf: url) else { return }
        let bounded = Self.boundedJSONLTail(existing, maxBytes: capBytes)
        try? bounded.write(to: url, options: .atomic)
        applyFileProtection(to: url)
    }

    /// Keep the newest complete JSONL records under `maxBytes`, with an explicit first-line marker.
    /// Public to the module so the retention contract can be pinned without a running iOS process.
    static func boundedJSONLTail(_ data: Data, maxBytes: Int) -> Data {
        guard maxBytes > 0, data.count > maxBytes else {
            return maxBytes > 0 ? data : Data()
        }
        let marker = Data(
            "{\"schema\":1,\"event\":\"log.trimmed\",\"fields\":{\"reason\":\"older records removed\"}}\n".utf8
        )
        guard maxBytes > marker.count else { return Data(marker.prefix(maxBytes)) }

        let suffix = data.suffix(maxBytes - marker.count)
        guard let newline = suffix.firstIndex(of: 0x0A) else { return marker }
        let tailStart = suffix.index(after: newline)
        var result = marker
        result.append(contentsOf: suffix[tailStart...])
        return Data(result.prefix(maxBytes))
    }

    private func resourceSnapshot() -> [String: Any] {
        var values: [String: Any] = [:]
        if let memory = Self.residentFootprintMB() {
            values["memory_mb"] = Int(memory.rounded())
        }
        if let dbBytes = Self.databaseFootprintBytes() {
            values["database_bytes"] = dbBytes
        }
        if let available = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            values["disk_available_bytes"] = available
        }
        values["thermal_state"] = Self.thermalStateName(ProcessInfo.processInfo.thermalState)
        values["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        values["physical_memory_bytes"] = ProcessInfo.processInfo.physicalMemory
        return values
    }

    private static func databaseFootprintBytes() -> Int? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        let fm = FileManager.default
        var total = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            if let size = (try? fm.attributesOfItem(atPath: path + suffix)[.size]) as? Int {
                total += size
                found = true
            }
        }
        return found ? total : nil
    }

    private static func residentFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1_024 * 1_024)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func applyFileProtection(to url: URL) {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func withIOQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) == 1 { return work() }
        return ioQueue.sync(execute: work)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NOOP/AppDiagnostics", isDirectory: true)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
    }

    private static func sanitizedToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.prefix(96).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        let token = String(scalars)
        return token.isEmpty ? "unknown" : token
    }

    private static func sanitizedFields(_ fields: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var redacted = 0
        for (key, value) in fields.prefix(24) {
            let safeKey = sanitizedToken(key)
            let lowered = safeKey.lowercased()
            guard !sensitiveFieldFragments.contains(where: lowered.contains) else {
                redacted += 1
                continue
            }
            result[safeKey] = sanitizedFieldValue(value)
        }
        if redacted > 0 { result["redacted_fields"] = String(redacted) }
        return result
    }

    private static func sanitizedFieldValue(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-/:{}+")
        )
        let scalars = value.unicodeScalars.prefix(512).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        return String(scalars)
    }

    static func freshnessBucket(ageSeconds: TimeInterval?) -> String {
        guard let ageSeconds, ageSeconds.isFinite else { return "missing" }
        if ageSeconds < -60 { return "future_clock" }
        let age = max(0, ageSeconds)
        if age < 120 { return "under_2m" }
        if age < 15 * 60 { return "2m_to_15m" }
        if age < 2 * 60 * 60 { return "15m_to_2h" }
        return "over_2h"
    }

    static func failureKind(_ error: Error) -> String {
        sanitizedToken(String(reflecting: type(of: error)))
    }

    // MARK: - Main-thread watchdog and system signals

    #if os(iOS)
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.watchdogIntervalMilliseconds),
            repeating: .milliseconds(Self.watchdogIntervalMilliseconds),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdogTimer = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard watchdogActive else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if lastHeartbeatAt == 0 || now - lastHeartbeatAt >= 60 {
            lastHeartbeatAt = now
            record("process.heartbeat", includeResourceSnapshot: true)
        }

        if let pendingPing {
            let delay = now - pendingPing.startedAt
            if delay >= Self.mainThreadStallThresholdSeconds, !stallWasLogged {
                stallWasLogged = true
                record(
                    "main_thread.stall_detected",
                    fields: ["blocked_ms": String(Int((delay * 1_000).rounded()))],
                    includeResourceSnapshot: true
                )
            }
            return
        }

        pingSequence &+= 1
        let id = pingSequence
        pendingPing = (id, now)
        DispatchQueue.main.async { [weak self] in
            self?.acknowledgeMainThreadPing(id)
        }
    }

    private func acknowledgeMainThreadPing(_ id: UInt64) {
        let recoveredAt = ProcessInfo.processInfo.systemUptime
        watchdogQueue.async { [weak self] in
            guard let self, let pending = self.pendingPing, pending.id == id else { return }
            let delay = max(0, recoveredAt - pending.startedAt)
            if self.stallWasLogged {
                self.record(
                    "main_thread.stall_recovered",
                    fields: ["blocked_ms": String(Int((delay * 1_000).rounded()))],
                    includeResourceSnapshot: true
                )
            }
            self.pendingPing = nil
            self.stallWasLogged = false
        }
    }

    private func installSystemObservers() {
        guard !systemObserversInstalled else { return }
        systemObserversInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(receivedMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(protectedDataBecameUnavailable),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(protectedDataBecameAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func receivedMemoryWarning() {
        record("system.memory_warning", includeResourceSnapshot: true)
    }

    @objc private func thermalStateChanged() {
        record(
            "system.thermal_state_changed",
            fields: [
                "thermal_state": Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            ],
            includeResourceSnapshot: true
        )
    }

    @objc private func protectedDataBecameUnavailable() {
        record("system.protected_data_unavailable")
    }

    @objc private func protectedDataBecameAvailable() {
        record("system.protected_data_available")
    }

    @objc private func applicationWillTerminate() {
        record("process.will_terminate", includeResourceSnapshot: true)
        // Best-effort drain of the small append already queued above.
        withIOQueue {}
    }
    #endif
}

#if os(iOS)
extension AppDiagnosticsRecorder: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            for payload in payloads { self.persistOnIOQueue(payload) }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            for payload in payloads { self.persistOnIOQueue(payload) }
        }
    }

    private func persistOnIOQueue(_ payload: MXMetricPayload) {
        persistMetricKitPayloadOnIOQueue(
            payload.jsonRepresentation(),
            kind: "metric",
            identity: "metric:\(payload.timeStampBegin.timeIntervalSince1970):\(payload.timeStampEnd.timeIntervalSince1970)"
        )
    }

    private func persistOnIOQueue(_ payload: MXDiagnosticPayload) {
        persistMetricKitPayloadOnIOQueue(
            payload.jsonRepresentation(),
            kind: "diagnostic",
            identity: "diagnostic:\(payload.timeStampBegin.timeIntervalSince1970):\(payload.timeStampEnd.timeIntervalSince1970)"
        )
    }

    /// Called only on `ioQueue`; keeping JSON conversion and disk writes here prevents MetricKit delivery
    /// from competing with SwiftUI or app initialization.
    private func persistMetricKitPayloadOnIOQueue(_ data: Data,
                                                  kind: String,
                                                  identity: String) {
        let defaults = UserDefaults.standard
        var seen = defaults.stringArray(forKey: Self.metricPayloadIDsKey) ?? []
        guard !seen.contains(identity) else { return }

        guard let payload = try? JSONSerialization.jsonObject(with: data) else { return }
        let object: [String: Any] = [
            "schema": 1,
            "at": Self.timestamp(Date()),
            "event": "metrickit.\(kind)",
            "payload": payload,
        ]
        appendJSONObject(
            object,
            to: metricKitURL,
            capBytes: Self.metricKitCapBytes
        )
        seen.append(identity)
        defaults.set(Array(seen.suffix(64)), forKey: Self.metricPayloadIDsKey)
    }
}
#endif

#if os(iOS)
/// Samples display delivery only while a real primary-page scroll is moving.
///
/// Unlike Test Centre's opt-in performance capture, this production monitor writes no per-frame records
/// and owns no perpetual display link. It emits one bounded summary when a scroll settles, plus a throttled
/// resource snapshot after a severe hitch. This makes ordinary scroll lag diagnosable without adding idle
/// battery work or enough logging to cause the problem being measured.
@MainActor
final class AppScrollHitchMonitor {
    static let shared = AppScrollHitchMonitor()

    private static let smoothSummaryIntervalSeconds: TimeInterval = 60
    private static let severeEventIntervalSeconds: TimeInterval = 2

    private var displayLink: CADisplayLink?
    private var context = "unknown"
    private var startedAtUptime: TimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var lastSmoothSummaryUptime: TimeInterval = 0
    private var lastSevereEventUptime: TimeInterval = 0
    private var accumulator = ScrollHitchAccumulator()

    private init() {}

    var isRunning: Bool { displayLink != nil }

    func begin(context newContext: String) {
        if isRunning {
            guard context != newContext else { return }
            end(reason: "context_changed")
        }

        context = newContext
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        lastFrameTimestamp = 0
        accumulator = ScrollHitchAccumulator()

        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func end(reason: String = "idle") {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil

        let summary = accumulator
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let durationMs = max(0, (finishedAt - startedAtUptime) * 1_000)
        lastFrameTimestamp = 0
        accumulator = ScrollHitchAccumulator()

        guard summary.frameCount > 0 else { return }
        let smoothSummaryDue =
            finishedAt - lastSmoothSummaryUptime >= Self.smoothSummaryIntervalSeconds
        guard summary.hitchCount > 0 || smoothSummaryDue else { return }
        if summary.hitchCount == 0 { lastSmoothSummaryUptime = finishedAt }

        AppDiagnosticsRecorder.shared.record(
            "ui.scroll.summary",
            fields: [
                "screen": context,
                "reason": reason,
                "duration_ms": String(Int(durationMs.rounded())),
                "frames": String(summary.frameCount),
                "mean_frame_ms": String(Int(summary.meanDurationMs.rounded())),
                "hitches_50ms": String(summary.hitchCount),
                "severe_hitches_150ms": String(summary.severeHitchCount),
                "worst_frame_ms": String(Int(summary.worstDurationMs.rounded())),
            ],
            includeResourceSnapshot: summary.severeHitchCount > 0
        )
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        defer { lastFrameTimestamp = timestamp }
        guard lastFrameTimestamp > 0 else { return }

        let durationMs = (timestamp - lastFrameTimestamp) * 1_000
        guard accumulator.record(durationMs: durationMs) == .severe else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSevereEventUptime >= Self.severeEventIntervalSeconds else { return }
        lastSevereEventUptime = now
        AppDiagnosticsRecorder.shared.record(
            "ui.scroll.severe_hitch",
            fields: [
                "screen": context,
                "frame_ms": String(Int(durationMs.rounded())),
            ],
            includeResourceSnapshot: true
        )
    }
}
#endif
