import Foundation

struct VeepooBandCandidate: Equatable, Sendable, Identifiable {
    let handle: UInt64
    let peripheralID: UUID
    let printedIdentifier: String?

    var id: UInt64 { handle }
}

struct VeepooBandBatteryReading: Equatable, Sendable {
    let percent: Int?
    let level: Int?
    let charging: Bool?
    let low: Bool?
}

struct VeepooBandHeartRateReading: Equatable, Sendable {
    let bpm: Int
    /// Phone receipt time captured in the supplier callback. This is display
    /// freshness only and must not become a durable health timestamp.
    let receivedAt: Date
}

enum VeepooBandAdapterFailure: String, Error, Equatable, Sendable {
    case adapterUnavailable
    case radioUnavailable
    case invalidState
    case noResult
    case identifierMismatch
    case connectionFailed
    case disconnected
    case timeout
    case confirmationTimeout
    case invalidCredential
    case credentialRejected
    case invalidBattery
    case invalidSample
    case notWorn
    case busy
    case unsupported
    case staleCallback
    case internalFailure
}

enum VeepooBandAdapterStage: String, Equatable, Hashable, Sendable {
    case discovery
    case identification
    case connection
    case authentication
    case battery
    case live
    case disconnect
}

enum VeepooBandAdapterState: Equatable, Sendable {
    case idle
    case discovering
    case connecting
    case connected
    case authenticating
    case readingBattery
    case ready
    case startingLive
    case streaming
    case failed(VeepooBandAdapterFailure)
}

enum VeepooBandAdapterEvent: Equatable, Sendable {
    case state(VeepooBandAdapterState)
    case candidate(VeepooBandCandidate)
    case authenticated
    case battery(VeepooBandBatteryReading)
    case liveStarted
    case heartRate(VeepooBandHeartRateReading)
    case liveStopped
    case disconnected
    case failed(stage: VeepooBandAdapterStage, failure: VeepooBandAdapterFailure)
}

@MainActor
protocol VeepooBandAdapterControlling: AnyObject {
    var eventHandler: ((VeepooBandAdapterEvent) -> Void)? { get set }
    var state: VeepooBandAdapterState { get }

    func startDiscovery(targetPeripheralID: UUID?)
    func stopDiscovery()
    func connect(candidateHandle: UInt64, confirmedPrintedIdentifier: String)
    func reconnect(candidateHandle: UInt64)
    func disconnect()
    func verifyPassword(_ password: String)
    func startLiveHeartRate()
    func stopLiveHeartRate()
}

enum VeepooBandSDKConnectionEvent: Equatable, Sendable {
    case radioUnavailable
    case connecting
    case connected
    case disconnected
    case failed
    case timeout
    case confirmationTimeout
}

enum VeepooBandSDKPasswordEvent: Equatable, Sendable {
    case verified
    case rejected
    case failed
}

enum VeepooBandSDKChargeState: Equatable, Sendable {
    case normal
    case charging
    case full
    case unknown
}

struct VeepooBandSDKBatteryEvent: Equatable, Sendable {
    let isPercent: Bool
    let chargeState: VeepooBandSDKChargeState
    let isLow: Bool
    let value: Int
}

enum VeepooBandSDKLiveEvent: Equatable, Sendable {
    case started
    case sample(bpm: Int, receivedAt: Date)
    case notWorn
    case busy
    case stopped
}

enum VeepooBandSDKEvent: Equatable, Sendable {
    case candidate(
        generation: UInt64,
        handle: UInt64,
        peripheralID: UUID,
        printedIdentifier: String?
    )
    case connection(generation: UInt64, VeepooBandSDKConnectionEvent)
    case password(generation: UInt64, VeepooBandSDKPasswordEvent)
    case battery(generation: UInt64, VeepooBandSDKBatteryEvent)
    case live(generation: UInt64, VeepooBandSDKLiveEvent)

    var generation: UInt64 {
        switch self {
        case .candidate(let generation, _, _, _),
             .connection(let generation, _),
             .password(let generation, _),
             .battery(let generation, _),
             .live(let generation, _):
            return generation
        }
    }
}

@MainActor
protocol VeepooBandSDKClient: AnyObject {
    var eventHandler: ((VeepooBandSDKEvent) -> Void)? { get set }

    func startDiscovery(generation: UInt64, targetPeripheralID: UUID?)
    func stopDiscovery()
    func connect(
        generation: UInt64,
        candidateHandle: UInt64,
        requiresUserConfirmation: Bool
    )
    func disconnect()
    func verifyPassword(generation: UInt64, password: String)
    func readBattery(generation: UInt64)
    func startLiveHeartRate(generation: UInt64)
    func stopLiveHeartRate()
}

enum VeepooBandDiagnosticOutcome: String, Equatable, Sendable {
    case began
    case completed
    case cancelled
    case rejected
    case failed
    case stale
}

struct VeepooBandDiagnostic: Equatable, Sendable {
    let stage: VeepooBandAdapterStage
    let outcome: VeepooBandDiagnosticOutcome
    let failure: VeepooBandAdapterFailure?
    let countBucket: String?

    init(
        stage: VeepooBandAdapterStage,
        outcome: VeepooBandDiagnosticOutcome,
        failure: VeepooBandAdapterFailure? = nil,
        count: Int? = nil
    ) {
        self.stage = stage
        self.outcome = outcome
        self.failure = failure
        countBucket = count.map {
            switch $0 {
            case ...0: return "0"
            case 1: return "1"
            case 2...9: return "2_9"
            default: return "10_plus"
            }
        }
    }
}

@MainActor
protocol VeepooBandDiagnosticsRecording: AnyObject {
    func record(_ event: VeepooBandDiagnostic)
}

@MainActor
final class VeepooBandAppDiagnostics: VeepooBandDiagnosticsRecording {
    static let shared = VeepooBandAppDiagnostics()

    func record(_ event: VeepooBandDiagnostic) {
        var fields = [
            "stage": event.stage.rawValue,
            "outcome": event.outcome.rawValue,
        ]
        if let failure = event.failure {
            fields["failure_kind"] = failure.rawValue
        }
        if let countBucket = event.countBucket {
            fields["count_bucket"] = countBucket
        }
        AppDiagnosticsRecorder.shared.record(
            "band.supplier_adapter",
            fields: fields
        )
    }
}

/// App-owned state machine around the quarantined supplier client.
@MainActor
final class VeepooBandAdapterCore: VeepooBandAdapterControlling {
    var eventHandler: ((VeepooBandAdapterEvent) -> Void)?
    private(set) var state: VeepooBandAdapterState = .idle

    private let client: any VeepooBandSDKClient
    private let diagnostics: any VeepooBandDiagnosticsRecording
    private var generation: UInt64 = 0
    private var candidates: [UInt64: VeepooBandCandidate] = [:]
    private var acceptedHeartRateCount = 0
    private var staleStages = Set<VeepooBandAdapterStage>()
    private var reportedInvalidHeartRate = false

    init(
        client: any VeepooBandSDKClient,
        diagnostics: (any VeepooBandDiagnosticsRecording)? = nil
    ) {
        self.client = client
        self.diagnostics = diagnostics ?? VeepooBandAppDiagnostics.shared
        client.eventHandler = { [weak self] event in self?.handle(event) }
    }

    func startDiscovery(targetPeripheralID: UUID?) {
        cancelCurrentSession(recordCancellation: state != .idle)
        generation &+= 1
        candidates.removeAll(keepingCapacity: true)
        acceptedHeartRateCount = 0
        reportedInvalidHeartRate = false
        staleStages.removeAll(keepingCapacity: true)
        transition(to: .discovering)
        diagnostics.record(.init(stage: .discovery, outcome: .began))
        client.startDiscovery(
            generation: generation,
            targetPeripheralID: targetPeripheralID
        )
    }

    func stopDiscovery() {
        guard state == .discovering else { return }
        client.stopDiscovery()
        diagnostics.record(
            .init(
                stage: .discovery,
                outcome: .cancelled,
                count: candidates.count
            )
        )
        generation &+= 1
        candidates.removeAll()
        transition(to: .idle)
    }

    func connect(
        candidateHandle: UInt64,
        confirmedPrintedIdentifier: String
    ) {
        guard let candidate = selectableCandidate(candidateHandle) else { return }
        if let printedIdentifier = candidate.printedIdentifier {
            guard Self.printedIdentifiersMatch(
                confirmedPrintedIdentifier,
                printedIdentifier
            ) else {
                reject(.identifierMismatch, stage: .identification)
                return
            }
        }
        diagnostics.record(.init(stage: .identification, outcome: .completed))
        beginConnection(candidateHandle, requiresUserConfirmation: true)
    }

    /// Reconnect is allowed only for a previously persisted peripheral. The
    /// original pairing already performed explicit candidate and printed-ID
    /// confirmation.
    func reconnect(candidateHandle: UInt64) {
        guard selectableCandidate(candidateHandle) != nil else { return }
        beginConnection(candidateHandle, requiresUserConfirmation: false)
    }

    func disconnect() {
        guard state != .idle else { return }
        let priorStage = currentStage
        let count = acceptedHeartRateCount
        client.stopLiveHeartRate()
        client.stopDiscovery()
        client.disconnect()
        generation &+= 1
        candidates.removeAll()
        acceptedHeartRateCount = 0
        transition(to: .idle)
        eventHandler?(.disconnected)
        diagnostics.record(
            .init(
                stage: priorStage,
                outcome: .cancelled,
                count: priorStage == .live ? count : nil
            )
        )
        diagnostics.record(.init(stage: .disconnect, outcome: .completed))
    }

    func verifyPassword(_ password: String) {
        guard state == .connected else {
            reject(.invalidState, stage: .authentication)
            return
        }
        guard Self.isValidPassword(password) else {
            reject(.invalidCredential, stage: .authentication)
            return
        }
        transition(to: .authenticating)
        diagnostics.record(.init(stage: .authentication, outcome: .began))
        client.verifyPassword(generation: generation, password: password)
    }

    func startLiveHeartRate() {
        guard state == .ready else {
            reject(.invalidState, stage: .live)
            return
        }
        acceptedHeartRateCount = 0
        reportedInvalidHeartRate = false
        transition(to: .startingLive)
        diagnostics.record(.init(stage: .live, outcome: .began))
        client.startLiveHeartRate(generation: generation)
    }

    func stopLiveHeartRate() {
        guard state == .startingLive || state == .streaming else { return }
        client.stopLiveHeartRate()
        transition(to: .ready)
        eventHandler?(.liveStopped)
        diagnostics.record(
            .init(
                stage: .live,
                outcome: .completed,
                count: acceptedHeartRateCount
            )
        )
        acceptedHeartRateCount = 0
    }

    static func isValidPassword(_ value: String) -> Bool {
        value.unicodeScalars.count == 4
            && value.unicodeScalars.allSatisfy {
                (48...57).contains(Int($0.value))
            }
    }

    static func printedIdentifiersMatch(_ entered: String, _ discovered: String) -> Bool {
        let left = normalizedPrintedIdentifier(entered)
        let right = normalizedPrintedIdentifier(discovered)
        return left.count >= 4 && left == right
    }

    private static func normalizedPrintedIdentifier(_ value: String) -> String {
        var result = ""
        for scalar in value.uppercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            result.append(Character(String(scalar)))
        }
        return result
    }

    static func normalizeBattery(
        _ event: VeepooBandSDKBatteryEvent
    ) -> VeepooBandBatteryReading? {
        let charging: Bool?
        switch event.chargeState {
        case .normal: charging = false
        case .charging: charging = true
        case .full, .unknown: charging = nil
        }
        if event.isPercent {
            guard (0...100).contains(event.value) else { return nil }
            return .init(
                percent: event.value,
                level: nil,
                charging: charging,
                low: event.isLow
            )
        }
        guard (0...4).contains(event.value) else { return nil }
        return .init(
            percent: nil,
            level: event.value,
            charging: charging,
            low: nil
        )
    }

    private func selectableCandidate(_ handle: UInt64) -> VeepooBandCandidate? {
        guard state == .discovering, let candidate = candidates[handle] else {
            reject(.noResult, stage: .connection)
            return nil
        }
        return candidate
    }

    private func beginConnection(
        _ handle: UInt64,
        requiresUserConfirmation: Bool
    ) {
        client.stopDiscovery()
        diagnostics.record(
            .init(
                stage: .discovery,
                outcome: .completed,
                count: candidates.count
            )
        )
        transition(to: .connecting)
        diagnostics.record(.init(stage: .connection, outcome: .began))
        client.connect(
            generation: generation,
            candidateHandle: handle,
            requiresUserConfirmation: requiresUserConfirmation
        )
    }

    private func handle(_ event: VeepooBandSDKEvent) {
        guard event.generation == generation else {
            recordStale(stage(for: event))
            return
        }
        switch event {
        case .candidate(_, let handle, let peripheralID, let printedIdentifier):
            guard state == .discovering else {
                recordStale(.discovery)
                return
            }
            guard candidates[handle] == nil else { return }
            let candidate = VeepooBandCandidate(
                handle: handle,
                peripheralID: peripheralID,
                printedIdentifier: printedIdentifier
            )
            candidates[handle] = candidate
            eventHandler?(.candidate(candidate))
        case .connection(_, let value):
            handle(value)
        case .password(_, let value):
            handle(value)
        case .battery(_, let value):
            guard state == .readingBattery else {
                recordStale(.battery)
                return
            }
            guard let reading = Self.normalizeBattery(value) else {
                fail(.invalidBattery, stage: .battery)
                return
            }
            transition(to: .ready)
            eventHandler?(.battery(reading))
            diagnostics.record(.init(stage: .battery, outcome: .completed))
        case .live(_, let value):
            handle(value)
        }
    }

    private func handle(_ event: VeepooBandSDKConnectionEvent) {
        switch event {
        case .connecting:
            guard state == .connecting else { recordStale(.connection); return }
        case .connected:
            guard state == .connecting else { recordStale(.connection); return }
            transition(to: .connected)
            diagnostics.record(.init(stage: .connection, outcome: .completed))
        case .disconnected:
            unexpectedDisconnect()
        case .radioUnavailable:
            fail(.radioUnavailable, stage: .connection)
        case .failed:
            fail(.connectionFailed, stage: .connection)
        case .timeout:
            fail(.timeout, stage: .connection)
        case .confirmationTimeout:
            fail(.confirmationTimeout, stage: .connection)
        }
    }

    private func handle(_ event: VeepooBandSDKPasswordEvent) {
        guard state == .authenticating else {
            recordStale(.authentication)
            return
        }
        switch event {
        case .verified:
            eventHandler?(.authenticated)
            diagnostics.record(.init(stage: .authentication, outcome: .completed))
            transition(to: .readingBattery)
            diagnostics.record(.init(stage: .battery, outcome: .began))
            client.readBattery(generation: generation)
        case .rejected:
            transition(to: .connected)
            reject(.credentialRejected, stage: .authentication)
        case .failed:
            fail(.internalFailure, stage: .authentication)
        }
    }

    private func handle(_ event: VeepooBandSDKLiveEvent) {
        switch event {
        case .started:
            guard state == .startingLive else { recordStale(.live); return }
            eventHandler?(.liveStarted)
        case .sample(let bpm, let receivedAt):
            guard state == .startingLive || state == .streaming else {
                recordStale(.live)
                return
            }
            guard (30...220).contains(bpm) else {
                if !reportedInvalidHeartRate {
                    reportedInvalidHeartRate = true
                    reject(.invalidSample, stage: .live)
                }
                return
            }
            if state == .startingLive {
                transition(to: .streaming)
            }
            acceptedHeartRateCount &+= 1
            eventHandler?(.heartRate(.init(bpm: bpm, receivedAt: receivedAt)))
        case .notWorn:
            finishLive(failure: .notWorn)
        case .busy:
            finishLive(failure: .busy)
        case .stopped:
            guard state == .startingLive || state == .streaming else {
                recordStale(.live)
                return
            }
            stopLiveHeartRate()
        }
    }

    private func finishLive(failure: VeepooBandAdapterFailure) {
        guard state == .startingLive || state == .streaming else {
            recordStale(.live)
            return
        }
        client.stopLiveHeartRate()
        transition(to: .ready)
        eventHandler?(.failed(stage: .live, failure: failure))
        diagnostics.record(
            .init(
                stage: .live,
                outcome: .rejected,
                failure: failure,
                count: acceptedHeartRateCount
            )
        )
        acceptedHeartRateCount = 0
    }

    private func unexpectedDisconnect() {
        guard state != .idle else { return }
        client.stopLiveHeartRate()
        client.stopDiscovery()
        generation &+= 1
        candidates.removeAll()
        acceptedHeartRateCount = 0
        transition(to: .idle)
        eventHandler?(.disconnected)
        diagnostics.record(
            .init(
                stage: .disconnect,
                outcome: .failed,
                failure: .disconnected
            )
        )
    }

    private func fail(
        _ failure: VeepooBandAdapterFailure,
        stage: VeepooBandAdapterStage
    ) {
        client.stopLiveHeartRate()
        client.stopDiscovery()
        client.disconnect()
        transition(to: .failed(failure))
        eventHandler?(.failed(stage: stage, failure: failure))
        diagnostics.record(
            .init(stage: stage, outcome: .failed, failure: failure)
        )
    }

    private func reject(
        _ failure: VeepooBandAdapterFailure,
        stage: VeepooBandAdapterStage
    ) {
        eventHandler?(.failed(stage: stage, failure: failure))
        diagnostics.record(
            .init(stage: stage, outcome: .rejected, failure: failure)
        )
    }

    private func cancelCurrentSession(recordCancellation: Bool) {
        guard state != .idle else { return }
        let priorStage = currentStage
        client.stopLiveHeartRate()
        client.stopDiscovery()
        client.disconnect()
        if recordCancellation {
            diagnostics.record(
                .init(stage: priorStage, outcome: .cancelled)
            )
        }
    }

    private func transition(to next: VeepooBandAdapterState) {
        state = next
        eventHandler?(.state(next))
    }

    private func recordStale(_ stage: VeepooBandAdapterStage) {
        guard staleStages.insert(stage).inserted else { return }
        diagnostics.record(
            .init(
                stage: stage,
                outcome: .stale,
                failure: .staleCallback
            )
        )
    }

    private func stage(for event: VeepooBandSDKEvent) -> VeepooBandAdapterStage {
        switch event {
        case .candidate: return .discovery
        case .connection: return .connection
        case .password: return .authentication
        case .battery: return .battery
        case .live: return .live
        }
    }

    private var currentStage: VeepooBandAdapterStage {
        switch state {
        case .idle: return .disconnect
        case .discovering: return .discovery
        case .connecting, .connected: return .connection
        case .authenticating: return .authentication
        case .readingBattery: return .battery
        case .ready, .startingLive, .streaming: return .live
        case .failed: return .disconnect
        }
    }
}
