import CryptoKit
import Foundation

public enum BandContractLimits {
    public static let opaqueHandleLength = 128
    public static let sourceIdentityLength = 128
    public static let revisionLength = 64
    public static let cursorLength = 256
    public static let acknowledgementTokenLength = 256
    public static let samplesPerBatch = 4_096
    public static let batchesPerHistoryChunk = 256
    public static let samplesPerHistoryChunk = 16_384
    public static let historyCheckpointIdentities = 65_536
    public static let maximumSampleSequence = UInt64(Int64.max)
    public static let minimumDeviceTimeMilliseconds: Int64 = 0
}

private extension String {
    func hasValidUTF8Length(
        maximum: Int,
        allowEmpty: Bool = false
    ) -> Bool {
        guard maximum >= 0 else {
            return false
        }
        var count = 0
        for _ in utf8 {
            if count == maximum {
                return false
            }
            count += 1
        }
        return allowEmpty || count > 0
    }

    func hashUTF8(into hasher: inout Hasher) {
        hasher.combine(utf8.count)
        for byte in utf8 {
            hasher.combine(byte)
        }
    }
}

extension String {
    func hasIdenticalUTF8(to other: String) -> Bool {
        utf8.elementsEqual(other.utf8)
    }
}

func optionalStringsHaveIdenticalUTF8(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    switch (lhs, rhs) {
    case let (.some(lhs), .some(rhs)):
        return lhs.hasIdenticalUTF8(to: rhs)
    case (.none, .none):
        return true
    default:
        return false
    }
}

public enum BandCapability: String, Codable, CaseIterable, Sendable {
    case battery
    case charging
    case wearState = "wear_state"
    case steps
    case distance
    case calories
    case heartRate = "heart_rate"
    case rrIntervals = "rr_intervals"
    case sleep
    case spo2
    case respiration
    case temperature
    case stress
    case workoutHistory = "workout_history"
    case rawPPG = "raw_ppg"
    case accelerometer
    case gyroscope
    case haptics
    case alarms
    case weather
    case firmwareUpdate = "firmware_update"
}

public enum BandSessionState: String, Codable, Sendable {
    case idle
    case scanning
    case candidateSelected
    case connecting
    case authenticating
    case negotiatingCapabilities
    case ready
    case liveCollecting
    case historyCollecting
    case executingCommand
    case updatingFirmware
    case recovering
    case disconnecting
    case closed
    case incompatible
    case rejected
    case securityFailure
    case firmwareFailure
}

public enum BandConnectionPhase: String, Codable, Sendable {
    case connection
    case authentication
}

public enum BandDisconnectReason: String, Codable, Sendable {
    case userPaused
    case collectorHandoff
    case transportReplaced
}

public enum BandFailureCategory: String, Codable, Error, Sendable {
    case unavailable
    case permission
    case noResult
    case timeout
    case rejected
    case incompatible
    case authentication
    case securityFailure
    case staleCallback
    case disconnected
    case storage
    case historyStalled
    case lowBattery
    case updateNotEligible
    case updateInterrupted
    case updateVerification
    case busy
    case invalidState
    case invalidInput
    case unsupported
    case closed
    case internalFailure
}

public enum BandOperationClass: String, Codable, CaseIterable, Sendable {
    case history
    case battery
    case wearState
    case haptic
    case alarm
    case sampling
    case firmware
}

public enum BandFirmwareFailureDisposition: String, Codable, Sendable {
    case recoverable
    case terminal
}

public enum BandProvenanceLane: String, Codable, Sendable {
    case live
    case history
}

public enum BandStreamKind: String, Codable, CaseIterable, Sendable {
    case heartRate
    case rrInterval
    case steps
    case spo2
    case respiration
    case temperature
    case acceleration
}

func requiredCapability(
    for stream: BandStreamKind
) -> BandCapability {
    switch stream {
    case .heartRate:
        return .heartRate
    case .rrInterval:
        return .rrIntervals
    case .steps:
        return .steps
    case .spo2:
        return .spo2
    case .respiration:
        return .respiration
    case .temperature:
        return .temperature
    case .acceleration:
        return .accelerometer
    }
}

public enum BandUnit: String, Codable, Sendable {
    case beatsPerMinute
    case milliseconds
    case count
    case percent
    case breathsPerMinute
    case celsius
    case gravity
}

func requiredUnit(
    for stream: BandStreamKind
) -> BandUnit {
    switch stream {
    case .heartRate:
        return .beatsPerMinute
    case .rrInterval:
        return .milliseconds
    case .steps:
        return .count
    case .spo2:
        return .percent
    case .respiration:
        return .breathsPerMinute
    case .temperature:
        return .celsius
    case .acceleration:
        return .gravity
    }
}

public enum BandSampleQuality: String, Codable, Sendable {
    case accepted
    case degraded
    case rejected
}

public enum BandCadenceKind: String, Codable, Sendable {
    case periodic
    case eventDriven
    case aggregateWindow
}

public enum BandQualitySemantics: String, Codable, Sendable {
    case acceptedOrDegraded
}

public enum BandTimestampSemantics: String, Codable, Sendable {
    case deviceMilliseconds
}

public struct BandStreamSemantics:
    Equatable,
    Hashable,
    Codable,
    Sendable
{
    public let lane: BandProvenanceLane
    public let stream: BandStreamKind
    public let unit: BandUnit
    public let cadence: BandCadenceKind
    public let nominalIntervalMilliseconds: Int?
    public let quality: BandQualitySemantics
    public let timestamp: BandTimestampSemantics
    public let parserRevision: String
    public let calibrationRevision: String

    public init(
        lane: BandProvenanceLane,
        stream: BandStreamKind,
        unit: BandUnit,
        cadence: BandCadenceKind,
        nominalIntervalMilliseconds: Int?,
        quality: BandQualitySemantics,
        timestamp: BandTimestampSemantics,
        parserRevision: String,
        calibrationRevision: String
    ) {
        self.lane = lane
        self.stream = stream
        self.unit = unit
        self.cadence = cadence
        self.nominalIntervalMilliseconds = nominalIntervalMilliseconds
        self.quality = quality
        self.timestamp = timestamp
        self.parserRevision = parserRevision
        self.calibrationRevision = calibrationRevision
    }

    public static func == (
        lhs: BandStreamSemantics,
        rhs: BandStreamSemantics
    ) -> Bool {
        lhs.lane == rhs.lane
            && lhs.stream == rhs.stream
            && lhs.unit == rhs.unit
            && lhs.cadence == rhs.cadence
            && lhs.nominalIntervalMilliseconds
                == rhs.nominalIntervalMilliseconds
            && lhs.quality == rhs.quality
            && lhs.timestamp == rhs.timestamp
            && lhs.parserRevision.hasIdenticalUTF8(
                to: rhs.parserRevision
            )
            && lhs.calibrationRevision.hasIdenticalUTF8(
                to: rhs.calibrationRevision
            )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lane)
        hasher.combine(stream)
        hasher.combine(unit)
        hasher.combine(cadence)
        hasher.combine(nominalIntervalMilliseconds)
        hasher.combine(quality)
        hasher.combine(timestamp)
        parserRevision.hashUTF8(into: &hasher)
        calibrationRevision.hashUTF8(into: &hasher)
    }

    public func validate() throws {
        let cadenceIsValid: Bool
        switch cadence {
        case .eventDriven:
            cadenceIsValid = nominalIntervalMilliseconds == nil
        case .periodic, .aggregateWindow:
            cadenceIsValid = nominalIntervalMilliseconds.map {
                (1 ... 86_400_000).contains($0)
            } ?? false
        }
        guard unit == requiredUnit(for: stream),
              cadenceIsValid,
              parserRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              calibrationRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              )
        else {
            throw BandFailureCategory.incompatible
        }
    }
}

public struct BandPairingCandidate:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let handle: String
    public let compatible: Bool
    public let identifyEligible: Bool

    public init(handle: String, compatible: Bool, identifyEligible: Bool) {
        self.handle = handle
        self.compatible = compatible
        self.identifyEligible = identifyEligible
    }

    public func validate() throws {
        guard handle.hasValidUTF8Length(
            maximum: BandContractLimits.opaqueHandleLength
        )
        else {
            throw BandFailureCategory.invalidInput
        }
    }

    public var description: String {
        "BandPairingCandidate("
            + "compatible: \(compatible), "
            + "identifyEligible: \(identifyEligible)"
            + ")"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "compatible": compatible,
                "identifyEligible": identifyEligible,
            ],
            displayStyle: .struct
        )
    }
}

public struct BandScanToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let sessionNonce: UUID
    public let generation: UInt64

    init(sessionNonce: UUID, generation: UInt64) {
        self.sessionNonce = sessionNonce
        self.generation = generation
    }

    public var description: String { "BandScanToken" }
    public var debugDescription: String { "BandScanToken" }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["redacted": "BandScanToken"],
            displayStyle: .struct
        )
    }
}

public struct BandConnectionToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let sessionNonce: UUID
    let generation: UInt64
    let sequence: UInt64
    let candidateHandle: String

    init(
        sessionNonce: UUID,
        generation: UInt64,
        sequence: UInt64,
        candidateHandle: String
    ) {
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.sequence = sequence
        self.candidateHandle = candidateHandle
    }

    public var description: String { "BandConnectionToken" }
    public var debugDescription: String { "BandConnectionToken" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandConnectionToken")
    }
}

public struct BandReconnectToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let sessionNonce: UUID
    public let generation: UInt64
    let sequence: UInt64

    init(
        sessionNonce: UUID,
        generation: UInt64,
        sequence: UInt64
    ) {
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.sequence = sequence
    }

    public var description: String { "BandReconnectToken" }
    public var debugDescription: String { "BandReconnectToken" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandReconnectToken")
    }
}

public struct BandLiveToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let sessionNonce: UUID
    let generation: UInt64
    let sequence: UInt64

    init(
        sessionNonce: UUID,
        generation: UInt64,
        sequence: UInt64
    ) {
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.sequence = sequence
    }

    public var description: String { "BandLiveToken" }
    public var debugDescription: String { "BandLiveToken" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandLiveToken")
    }
}

public struct BandIdentity:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let sourceIdentity: String
    public let hardwareRevision: String
    public let firmwareVersion: String
    public let protocolVersion: String
    public let wrapperRevision: String

    public init(
        sourceIdentity: String,
        hardwareRevision: String,
        firmwareVersion: String,
        protocolVersion: String,
        wrapperRevision: String
    ) {
        self.sourceIdentity = sourceIdentity
        self.hardwareRevision = hardwareRevision
        self.firmwareVersion = firmwareVersion
        self.protocolVersion = protocolVersion
        self.wrapperRevision = wrapperRevision
    }

    public static func == (
        lhs: BandIdentity,
        rhs: BandIdentity
    ) -> Bool {
        lhs.sourceIdentity.hasIdenticalUTF8(to: rhs.sourceIdentity)
            && lhs.hardwareRevision.hasIdenticalUTF8(
                to: rhs.hardwareRevision
            )
            && lhs.firmwareVersion.hasIdenticalUTF8(
                to: rhs.firmwareVersion
            )
            && lhs.protocolVersion.hasIdenticalUTF8(
                to: rhs.protocolVersion
            )
            && lhs.wrapperRevision.hasIdenticalUTF8(
                to: rhs.wrapperRevision
            )
    }

    public func validate() throws {
        guard sourceIdentity.hasValidUTF8Length(
                  maximum: BandContractLimits.sourceIdentityLength
              ),
              hardwareRevision.hasValidUTF8Length(maximum: 32),
              firmwareVersion.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              protocolVersion.hasValidUTF8Length(maximum: 32),
              wrapperRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              )
        else {
            throw BandFailureCategory.invalidInput
        }
    }

    public var description: String { "BandIdentity" }
    public var debugDescription: String { "BandIdentity" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandIdentity")
    }
}

public struct BandCapabilityReport: Equatable, Codable, Sendable {
    static let maximumStreamSemantics =
        BandStreamKind.allCases.count * 2

    public static let supportedSchemaVersion = 3
    public static let supportedProtocolVersion = "noop-band-v1"

    public let schemaVersion: Int
    public let reportRevision: String
    public let protocolVersion: String
    public let hardwareRevision: String
    public let firmwareVersion: String
    public let historyDays: Int
    public let capabilities: Set<BandCapability>
    public let liveStreams: Set<BandStreamKind>
    public let historyStreams: Set<BandStreamKind>
    public let operationsAllowedDuringLive: Set<BandOperationClass>
    public let streamSemantics: [BandStreamSemantics]

    public init(
        schemaVersion: Int,
        reportRevision: String,
        protocolVersion: String,
        hardwareRevision: String,
        firmwareVersion: String,
        historyDays: Int,
        capabilities: Set<BandCapability>,
        liveStreams: Set<BandStreamKind>,
        historyStreams: Set<BandStreamKind>,
        operationsAllowedDuringLive: Set<BandOperationClass>,
        streamSemantics: [BandStreamSemantics]
    ) {
        self.schemaVersion = schemaVersion
        self.reportRevision = reportRevision
        self.protocolVersion = protocolVersion
        self.hardwareRevision = hardwareRevision
        self.firmwareVersion = firmwareVersion
        self.historyDays = historyDays
        self.capabilities = capabilities
        self.liveStreams = liveStreams
        self.historyStreams = historyStreams
        self.operationsAllowedDuringLive = operationsAllowedDuringLive
        self.streamSemantics = streamSemantics
    }

    public static func == (
        lhs: BandCapabilityReport,
        rhs: BandCapabilityReport
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.reportRevision.hasIdenticalUTF8(
                to: rhs.reportRevision
            )
            && lhs.protocolVersion.hasIdenticalUTF8(
                to: rhs.protocolVersion
            )
            && lhs.hardwareRevision.hasIdenticalUTF8(
                to: rhs.hardwareRevision
            )
            && lhs.firmwareVersion.hasIdenticalUTF8(
                to: rhs.firmwareVersion
            )
            && lhs.historyDays == rhs.historyDays
            && lhs.capabilities == rhs.capabilities
            && lhs.liveStreams == rhs.liveStreams
            && lhs.historyStreams == rhs.historyStreams
            && lhs.operationsAllowedDuringLive
                == rhs.operationsAllowedDuringLive
            && Self.semanticFrequencies(lhs.streamSemantics)
                == Self.semanticFrequencies(rhs.streamSemantics)
    }

    private static func semanticFrequencies(
        _ semantics: [BandStreamSemantics]
    ) -> [BandStreamSemantics: Int] {
        semantics.reduce(into: [:]) { frequencies, semantic in
            frequencies[semantic, default: 0] += 1
        }
    }

    init(
        schemaVersion: Int,
        protocolVersion: String,
        hardwareRevision: String,
        firmwareVersion: String,
        historyDays: Int,
        capabilities: Set<BandCapability>,
        liveStreams: Set<BandStreamKind>,
        historyStreams: Set<BandStreamKind>
    ) {
        self.init(
            schemaVersion: schemaVersion,
            reportRevision: "virtual-report-v1",
            protocolVersion: protocolVersion,
            hardwareRevision: hardwareRevision,
            firmwareVersion: firmwareVersion,
            historyDays: historyDays,
            capabilities: capabilities,
            liveStreams: liveStreams,
            historyStreams: historyStreams,
            operationsAllowedDuringLive: Set(
                BandOperationClass.allCases.filter { $0 != .firmware }
            ),
            streamSemantics: Self.virtualStreamSemantics(
                liveStreams: liveStreams,
                historyStreams: historyStreams
            )
        )
    }

    public func validate() throws {
        guard streamSemantics.count <= Self.maximumStreamSemantics else {
            throw BandFailureCategory.incompatible
        }
        let expectedSemantics = Set(
            liveStreams.map {
                BandStreamSemanticKey(lane: .live, stream: $0)
            } + historyStreams.map {
                BandStreamSemanticKey(lane: .history, stream: $0)
            }
        )
        let actualSemantics = Set(
            streamSemantics.map {
                BandStreamSemanticKey(lane: $0.lane, stream: $0.stream)
            }
        )
        guard schemaVersion == Self.supportedSchemaVersion,
              reportRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              protocolVersion == Self.supportedProtocolVersion,
              hardwareRevision.hasValidUTF8Length(maximum: 32),
              firmwareVersion.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              (0 ... 255).contains(historyDays),
              !capabilities.isEmpty,
              historyStreams.isEmpty || historyDays > 0,
              !operationsAllowedDuringLive.contains(.firmware),
              streamSemantics.count == actualSemantics.count,
              actualSemantics == expectedSemantics,
              liveStreams.union(historyStreams).allSatisfy({
                  capabilities.contains(requiredCapability(for: $0))
              }),
              streamSemantics.allSatisfy({
                  (try? $0.validate()) != nil
              })
        else {
            throw BandFailureCategory.incompatible
        }
    }

    private static func virtualStreamSemantics(
        liveStreams: Set<BandStreamKind>,
        historyStreams: Set<BandStreamKind>
    ) -> [BandStreamSemantics] {
        func semantics(
            lane: BandProvenanceLane,
            stream: BandStreamKind
        ) -> BandStreamSemantics {
            let cadence: BandCadenceKind
            let nominalIntervalMilliseconds: Int?
            switch stream {
            case .rrInterval:
                cadence = .eventDriven
                nominalIntervalMilliseconds = nil
            case .steps:
                cadence = .aggregateWindow
                nominalIntervalMilliseconds = 60_000
            case .acceleration:
                cadence = .periodic
                nominalIntervalMilliseconds = 40
            default:
                cadence = .periodic
                nominalIntervalMilliseconds = stream == .heartRate
                    ? 1_000
                    : 60_000
            }
            return BandStreamSemantics(
                lane: lane,
                stream: stream,
                unit: requiredUnit(for: stream),
                cadence: cadence,
                nominalIntervalMilliseconds: nominalIntervalMilliseconds,
                quality: .acceptedOrDegraded,
                timestamp: .deviceMilliseconds,
                parserRevision: "parser-v1",
                calibrationRevision: "calibration-v1"
            )
        }
        return liveStreams.map {
            semantics(lane: .live, stream: $0)
        } + historyStreams.map {
            semantics(lane: .history, stream: $0)
        }
    }
}

private struct BandStreamSemanticKey: Hashable {
    let lane: BandProvenanceLane
    let stream: BandStreamKind
}

public struct BandSampleIdentity:
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let stream: BandStreamKind
    public let sequence: UInt64
    public let deviceTimeMilliseconds: Int64

    public init(
        stream: BandStreamKind,
        sequence: UInt64,
        deviceTimeMilliseconds: Int64
    ) {
        self.stream = stream
        self.sequence = sequence
        self.deviceTimeMilliseconds = deviceTimeMilliseconds
    }

    public var description: String { "BandSampleIdentity" }
    public var debugDescription: String { "BandSampleIdentity" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandSampleIdentity")
    }
}

public struct BandSample:
    Equatable,
    Codable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let identity: BandSampleIdentity
    public let value: Double
    public let unit: BandUnit
    public let quality: BandSampleQuality

    public init(
        identity: BandSampleIdentity,
        value: Double,
        unit: BandUnit,
        quality: BandSampleQuality
    ) {
        self.identity = identity
        self.value = value
        self.unit = unit
        self.quality = quality
    }

    public static func == (lhs: BandSample, rhs: BandSample) -> Bool {
        lhs.identity == rhs.identity
            && lhs.value == rhs.value
            && lhs.unit == rhs.unit
            && lhs.quality == rhs.quality
    }

    public func validate() throws {
        guard identity.sequence <= BandContractLimits.maximumSampleSequence,
              identity.deviceTimeMilliseconds
                >= BandContractLimits.minimumDeviceTimeMilliseconds,
              value.isFinite,
              quality != .rejected
        else {
            throw BandFailureCategory.invalidInput
        }

        switch (identity.stream, unit) {
        case (.heartRate, .beatsPerMinute):
            guard (20 ... 260).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        case (.rrInterval, .milliseconds):
            guard (200 ... 3_000).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        case (.steps, .count):
            guard (0 ... 1_000_000).contains(value),
                  value.rounded(.towardZero) == value
            else {
                throw BandFailureCategory.invalidInput
            }
        case (.spo2, .percent):
            guard (50 ... 100).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        case (.respiration, .breathsPerMinute):
            guard (2 ... 80).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        case (.temperature, .celsius):
            guard (-20 ... 60).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        case (.acceleration, .gravity):
            guard (-32 ... 32).contains(value) else {
                throw BandFailureCategory.invalidInput
            }
        default:
            throw BandFailureCategory.invalidInput
        }
    }

    func hasEquivalentPayload(to other: BandSample) -> Bool {
        identity == other.identity
            && value == other.value
            && unit == other.unit
            && quality == other.quality
    }

    public var description: String { "BandSample" }
    public var debugDescription: String { "BandSample" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandSample")
    }
}

public struct BandSampleFingerprint:
    Hashable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let identity: BandSampleIdentity
    public let payloadFingerprint: String

    public init(
        identity: BandSampleIdentity,
        payloadFingerprint: String
    ) {
        self.identity = identity
        self.payloadFingerprint = payloadFingerprint
    }

    public init(sample: BandSample) {
        identity = sample.identity
        payloadFingerprint = samplePayloadFingerprint(sample)
    }

    public func validate() throws {
        guard identity.sequence <= BandContractLimits.maximumSampleSequence,
              identity.deviceTimeMilliseconds
                >= BandContractLimits.minimumDeviceTimeMilliseconds,
              payloadFingerprint.utf8.count == 64,
              payloadFingerprint.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else {
            throw BandFailureCategory.invalidInput
        }
    }

    func matches(_ sample: BandSample) -> Bool {
        identity == sample.identity
            && payloadFingerprint == samplePayloadFingerprint(sample)
    }

    public var description: String { "BandSampleFingerprint" }
    public var debugDescription: String { "BandSampleFingerprint" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandSampleFingerprint")
    }
}

private func samplePayloadFingerprint(_ sample: BandSample) -> String {
    let normalizedBits = sample.value == 0 ? UInt64(0) : sample.value.bitPattern
    let bits = String(normalizedBits, radix: 16)
    let paddedBits = String(repeating: "0", count: 16 - bits.count) + bits
    let canonical = [
        "v2",
        paddedBits,
        sample.unit.rawValue,
        sample.quality.rawValue,
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let hex = Array("0123456789abcdef".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(64)
    for byte in digest {
        encoded.append(hex[Int(byte >> 4)])
        encoded.append(hex[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
}

public struct BandSampleBatch:
    Equatable,
    Codable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let sourceIdentity: String
    public let lane: BandProvenanceLane
    public let parserRevision: String
    public let calibrationRevision: String
    public let samples: [BandSample]

    public init(
        sourceIdentity: String,
        lane: BandProvenanceLane,
        parserRevision: String,
        calibrationRevision: String,
        samples: [BandSample]
    ) {
        self.sourceIdentity = sourceIdentity
        self.lane = lane
        self.parserRevision = parserRevision
        self.calibrationRevision = calibrationRevision
        self.samples = samples
    }

    public static func == (
        lhs: BandSampleBatch,
        rhs: BandSampleBatch
    ) -> Bool {
        lhs.sourceIdentity.hasIdenticalUTF8(to: rhs.sourceIdentity)
            && lhs.lane == rhs.lane
            && lhs.parserRevision.hasIdenticalUTF8(
                to: rhs.parserRevision
            )
            && lhs.calibrationRevision.hasIdenticalUTF8(
                to: rhs.calibrationRevision
            )
            && lhs.samples == rhs.samples
    }

    public func validate(expectedLane: BandProvenanceLane) throws {
        guard lane == expectedLane,
              sourceIdentity.hasValidUTF8Length(
                  maximum: BandContractLimits.sourceIdentityLength
              ),
              parserRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              calibrationRevision.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              !samples.isEmpty,
              samples.count <= BandContractLimits.samplesPerBatch
        else {
            throw BandFailureCategory.invalidInput
        }
        try samples.forEach { try $0.validate() }
    }

    public var description: String { "BandSampleBatch" }
    public var debugDescription: String { "BandSampleBatch" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandSampleBatch")
    }
}

public struct BandHistoryRange:
    Equatable,
    Codable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let startDeviceTimeMilliseconds: Int64
    public let endDeviceTimeMilliseconds: Int64

    public init(
        startDeviceTimeMilliseconds: Int64,
        endDeviceTimeMilliseconds: Int64
    ) {
        self.startDeviceTimeMilliseconds = startDeviceTimeMilliseconds
        self.endDeviceTimeMilliseconds = endDeviceTimeMilliseconds
    }

    public func validate() throws {
        guard startDeviceTimeMilliseconds
                >= BandContractLimits.minimumDeviceTimeMilliseconds,
              endDeviceTimeMilliseconds >= startDeviceTimeMilliseconds
        else {
            throw BandFailureCategory.invalidInput
        }
    }

    public var description: String { "BandHistoryRange" }
    public var debugDescription: String { "BandHistoryRange" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandHistoryRange")
    }
}

public struct BandHistoryChunk:
    Equatable,
    Codable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let chunkIdentity: String
    public let previousCursor: String?
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
    public let retainedRange: BandHistoryRange?
    public let firstLostRange: BandHistoryRange?
    public let acknowledgementToken: String
    public let batches: [BandSampleBatch]

    public init(
        chunkIdentity: String,
        previousCursor: String?,
        nextCursor: String?,
        complete: Bool,
        overflowed: Bool,
        retainedRange: BandHistoryRange?,
        firstLostRange: BandHistoryRange?,
        acknowledgementToken: String,
        batches: [BandSampleBatch]
    ) {
        self.chunkIdentity = chunkIdentity
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
        self.complete = complete
        self.overflowed = overflowed
        self.retainedRange = retainedRange
        self.firstLostRange = firstLostRange
        self.acknowledgementToken = acknowledgementToken
        self.batches = batches
    }

    public static func == (
        lhs: BandHistoryChunk,
        rhs: BandHistoryChunk
    ) -> Bool {
        lhs.chunkIdentity.hasIdenticalUTF8(to: rhs.chunkIdentity)
            && optionalStringsHaveIdenticalUTF8(
                lhs.previousCursor,
                rhs.previousCursor
            )
            && optionalStringsHaveIdenticalUTF8(
                lhs.nextCursor,
                rhs.nextCursor
            )
            && lhs.complete == rhs.complete
            && lhs.overflowed == rhs.overflowed
            && lhs.retainedRange == rhs.retainedRange
            && lhs.firstLostRange == rhs.firstLostRange
            && lhs.acknowledgementToken.hasIdenticalUTF8(
                to: rhs.acknowledgementToken
            )
            && lhs.batches == rhs.batches
    }

    public func validate() throws {
        guard chunkIdentity.hasValidUTF8Length(
                  maximum: BandContractLimits.opaqueHandleLength
              ),
              previousCursor.map({
                  $0.hasValidUTF8Length(
                      maximum: BandContractLimits.cursorLength
                  )
              }) ?? true,
              nextCursor.map({
                  $0.hasValidUTF8Length(
                      maximum: BandContractLimits.cursorLength
                  )
              }) ?? true,
              acknowledgementToken.hasValidUTF8Length(
                  maximum: BandContractLimits.acknowledgementTokenLength
              ),
              !overflowed || (
                  retainedRange != nil
                    && firstLostRange != nil
              ),
              overflowed || firstLostRange == nil,
              batches.count <= BandContractLimits.batchesPerHistoryChunk,
              batches.reduce(0, { $0 + $1.samples.count })
                <= BandContractLimits.samplesPerHistoryChunk
        else {
            throw BandFailureCategory.invalidInput
        }
        try retainedRange?.validate()
        try firstLostRange?.validate()
        try batches.forEach { try $0.validate(expectedLane: .history) }
        if let retainedRange {
            guard batches.allSatisfy({ batch in
                batch.samples.allSatisfy { sample in
                    retainedRange.startDeviceTimeMilliseconds
                        ... retainedRange.endDeviceTimeMilliseconds
                        ~= sample.identity.deviceTimeMilliseconds
                }
            }) else {
                throw BandFailureCategory.invalidInput
            }
        }
        if overflowed {
            guard let retainedRange,
                  let firstLostRange,
                  firstLostRange.endDeviceTimeMilliseconds
                    < retainedRange.startDeviceTimeMilliseconds
            else {
                throw BandFailureCategory.invalidInput
            }
        }
    }

    public var description: String { "BandHistoryChunk" }
    public var debugDescription: String { "BandHistoryChunk" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandHistoryChunk")
    }
}

public struct BandHistoryCheckpoint:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let sourceIdentity: String
    public let acknowledgedCursor: String?
    public let lastHistoryComplete: Bool?
    public let durableSampleIdentities: Set<BandSampleIdentity>
    public let durableSampleFingerprints: Set<BandSampleFingerprint>

    public init(
        sourceIdentity: String,
        acknowledgedCursor: String?,
        lastHistoryComplete: Bool?,
        durableSampleIdentities: Set<BandSampleIdentity>,
        durableSampleFingerprints: Set<BandSampleFingerprint> = []
    ) {
        self.sourceIdentity = sourceIdentity
        self.acknowledgedCursor = acknowledgedCursor
        self.lastHistoryComplete = lastHistoryComplete
        self.durableSampleIdentities = durableSampleIdentities
        self.durableSampleFingerprints = durableSampleFingerprints
    }

    public static func == (
        lhs: BandHistoryCheckpoint,
        rhs: BandHistoryCheckpoint
    ) -> Bool {
        lhs.sourceIdentity.hasIdenticalUTF8(to: rhs.sourceIdentity)
            && optionalStringsHaveIdenticalUTF8(
                lhs.acknowledgedCursor,
                rhs.acknowledgedCursor
            )
            && lhs.lastHistoryComplete == rhs.lastHistoryComplete
            && lhs.durableSampleIdentities
                == rhs.durableSampleIdentities
            && lhs.durableSampleFingerprints
                == rhs.durableSampleFingerprints
    }

    public func validate() throws {
        let fingerprintIdentities = durableSampleFingerprints.map(\.identity)
        guard sourceIdentity.hasValidUTF8Length(
                  maximum: BandContractLimits.sourceIdentityLength
              ),
              acknowledgedCursor.map({
                  $0.hasValidUTF8Length(
                      maximum: BandContractLimits.cursorLength
                  )
              }) ?? true,
              durableSampleIdentities.count
                <= BandContractLimits.historyCheckpointIdentities,
              durableSampleIdentities.allSatisfy({
                  $0.sequence <= BandContractLimits.maximumSampleSequence
                    && $0.deviceTimeMilliseconds
                        >= BandContractLimits.minimumDeviceTimeMilliseconds
              }),
              durableSampleFingerprints.count
                <= BandContractLimits.historyCheckpointIdentities,
              Set(fingerprintIdentities).count
                == durableSampleFingerprints.count,
              durableSampleFingerprints.isEmpty
                || Set(fingerprintIdentities) == durableSampleIdentities
        else {
            throw BandFailureCategory.invalidInput
        }
        try durableSampleFingerprints.forEach { try $0.validate() }
    }

    public var description: String { "BandHistoryCheckpoint" }
    public var debugDescription: String { "BandHistoryCheckpoint" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandHistoryCheckpoint")
    }
}

public struct BandOperationToken:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let sessionNonce: UUID
    let generation: UInt64
    let sequence: UInt64
    let operationClass: BandOperationClass

    init(
        sessionNonce: UUID,
        generation: UInt64,
        sequence: UInt64,
        operationClass: BandOperationClass
    ) {
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.sequence = sequence
        self.operationClass = operationClass
    }

    public var description: String { "BandOperationToken" }
    public var debugDescription: String { "BandOperationToken" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandOperationToken")
    }
}

public struct LiveAcceptance:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let acceptedSamples: [BandSample]
    public let duplicateSamples: Int
    public let capabilityReportRevision: String
    public let parserRevision: String
    public let calibrationRevision: String
    let sessionNonce: UUID
    let generation: UInt64
    let receiptSequence: UInt64

    init(
        acceptedSamples: [BandSample],
        duplicateSamples: Int,
        capabilityReportRevision: String,
        parserRevision: String,
        calibrationRevision: String,
        sessionNonce: UUID,
        generation: UInt64,
        receiptSequence: UInt64
    ) {
        self.acceptedSamples = acceptedSamples
        self.duplicateSamples = duplicateSamples
        self.capabilityReportRevision = capabilityReportRevision
        self.parserRevision = parserRevision
        self.calibrationRevision = calibrationRevision
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.receiptSequence = receiptSequence
    }

    public var description: String { "LiveAcceptance" }
    public var debugDescription: String { "LiveAcceptance" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "LiveAcceptance")
    }
}

public struct AcceptedHistorySample:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let sourceIdentity: String
    public let lane: BandProvenanceLane
    public let parserRevision: String
    public let calibrationRevision: String
    public let capabilityReportRevision: String
    public let sample: BandSample

    init(
        batch: BandSampleBatch,
        capabilityReportRevision: String,
        sample: BandSample
    ) {
        sourceIdentity = batch.sourceIdentity
        lane = batch.lane
        parserRevision = batch.parserRevision
        calibrationRevision = batch.calibrationRevision
        self.capabilityReportRevision = capabilityReportRevision
        self.sample = sample
    }

    public var description: String { "AcceptedHistorySample" }
    public var debugDescription: String { "AcceptedHistorySample" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "AcceptedHistorySample")
    }
}

public struct DurableLiveReceipt:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let committedSamples: Int
    public let committed: Bool
    let sessionNonce: UUID
    let generation: UInt64
    let receiptSequence: UInt64

    public init(
        acceptance: LiveAcceptance,
        committedSamples: Int,
        committed: Bool
    ) {
        self.committedSamples = committedSamples
        self.committed = committed
        sessionNonce = acceptance.sessionNonce
        generation = acceptance.generation
        receiptSequence = acceptance.receiptSequence
    }

    public var description: String { "DurableLiveReceipt" }
    public var debugDescription: String { "DurableLiveReceipt" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "DurableLiveReceipt")
    }
}

public struct HistoryAcceptance:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let chunkIdentity: String
    public let acknowledgementToken: String
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
    public let retainedRange: BandHistoryRange?
    public let firstLostRange: BandHistoryRange?
    public let acceptedSamples: [AcceptedHistorySample]
    public let duplicateSamples: Int
    let sessionNonce: UUID
    let receiptSequence: UInt64

    init(
        chunkIdentity: String,
        acknowledgementToken: String,
        nextCursor: String?,
        complete: Bool,
        overflowed: Bool,
        retainedRange: BandHistoryRange?,
        firstLostRange: BandHistoryRange?,
        acceptedSamples: [AcceptedHistorySample],
        duplicateSamples: Int,
        sessionNonce: UUID,
        receiptSequence: UInt64
    ) {
        self.chunkIdentity = chunkIdentity
        self.acknowledgementToken = acknowledgementToken
        self.nextCursor = nextCursor
        self.complete = complete
        self.overflowed = overflowed
        self.retainedRange = retainedRange
        self.firstLostRange = firstLostRange
        self.acceptedSamples = Array(acceptedSamples)
        self.duplicateSamples = duplicateSamples
        self.sessionNonce = sessionNonce
        self.receiptSequence = receiptSequence
    }

    public var description: String { "HistoryAcceptance" }
    public var debugDescription: String { "HistoryAcceptance" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "HistoryAcceptance")
    }
}

public struct DurableHistoryReceipt:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let chunkIdentity: String
    public let acknowledgementToken: String
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
    public let retainedRange: BandHistoryRange?
    public let firstLostRange: BandHistoryRange?
    public let historyStateCommitted: Bool
    public let committedSamples: Int
    public let committed: Bool
    let sessionNonce: UUID
    let receiptSequence: UInt64

    public init(
        acceptance: HistoryAcceptance,
        historyStateCommitted: Bool,
        committedSamples: Int,
        committed: Bool
    ) {
        chunkIdentity = acceptance.chunkIdentity
        acknowledgementToken = acceptance.acknowledgementToken
        nextCursor = acceptance.nextCursor
        complete = acceptance.complete
        overflowed = acceptance.overflowed
        retainedRange = acceptance.retainedRange
        firstLostRange = acceptance.firstLostRange
        self.historyStateCommitted = historyStateCommitted
        self.committedSamples = committedSamples
        self.committed = committed
        sessionNonce = acceptance.sessionNonce
        receiptSequence = acceptance.receiptSequence
    }

    public var description: String { "DurableHistoryReceipt" }
    public var debugDescription: String { "DurableHistoryReceipt" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "DurableHistoryReceipt")
    }
}

private func redactedMirror<T>(of value: T, name: String) -> Mirror {
    Mirror(
        value,
        children: ["redacted": name],
        displayStyle: .struct
    )
}

public struct BandSessionSnapshot:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    public let state: BandSessionState
    public let generation: UInt64
    public let activeOperation: BandOperationClass?
    public let liveActive: Bool
    public let acknowledgedHistoryCursor: String?
    public let durableSampleCount: Int

    public init(
        state: BandSessionState,
        generation: UInt64,
        activeOperation: BandOperationClass?,
        liveActive: Bool,
        acknowledgedHistoryCursor: String?,
        durableSampleCount: Int
    ) {
        self.state = state
        self.generation = generation
        self.activeOperation = activeOperation
        self.liveActive = liveActive
        self.acknowledgedHistoryCursor = acknowledgedHistoryCursor
        self.durableSampleCount = durableSampleCount
    }

    public static func == (
        lhs: BandSessionSnapshot,
        rhs: BandSessionSnapshot
    ) -> Bool {
        lhs.state == rhs.state
            && lhs.generation == rhs.generation
            && lhs.activeOperation == rhs.activeOperation
            && lhs.liveActive == rhs.liveActive
            && optionalStringsHaveIdenticalUTF8(
                lhs.acknowledgedHistoryCursor,
                rhs.acknowledgedHistoryCursor
            )
            && lhs.durableSampleCount == rhs.durableSampleCount
    }

    public var description: String { "BandSessionSnapshot" }
    public var debugDescription: String { "BandSessionSnapshot" }
    public var customMirror: Mirror {
        redactedMirror(of: self, name: "BandSessionSnapshot")
    }
}
