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
        (allowEmpty || !isEmpty) && utf8.count <= maximum
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
}

public enum BandConnectionPhase: String, Codable, Sendable {
    case connection
    case authentication
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

public enum BandOperationClass: String, Codable, Sendable {
    case history
    case battery
    case wearState
    case haptic
    case alarm
    case sampling
    case firmware
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

public enum BandUnit: String, Codable, Sendable {
    case beatsPerMinute
    case milliseconds
    case count
    case percent
    case breathsPerMinute
    case celsius
    case gravity
}

public enum BandSampleQuality: String, Codable, Sendable {
    case accepted
    case degraded
    case rejected
}

public struct BandPairingCandidate: Equatable, Sendable {
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
}

public struct BandIdentity: Equatable, Sendable {
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
}

public struct BandCapabilityReport: Equatable, Codable, Sendable {
    public static let supportedSchemaVersion = 1
    public static let supportedProtocolVersion = "noop-band-v1"

    public let schemaVersion: Int
    public let protocolVersion: String
    public let hardwareRevision: String
    public let firmwareVersion: String
    public let historyDays: Int
    public let capabilities: Set<BandCapability>

    public init(
        schemaVersion: Int,
        protocolVersion: String,
        hardwareRevision: String,
        firmwareVersion: String,
        historyDays: Int,
        capabilities: Set<BandCapability>
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.hardwareRevision = hardwareRevision
        self.firmwareVersion = firmwareVersion
        self.historyDays = historyDays
        self.capabilities = capabilities
    }

    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion,
              protocolVersion == Self.supportedProtocolVersion,
              hardwareRevision.hasValidUTF8Length(maximum: 32),
              firmwareVersion.hasValidUTF8Length(
                  maximum: BandContractLimits.revisionLength
              ),
              (0 ... 255).contains(historyDays),
              !capabilities.isEmpty
        else {
            throw BandFailureCategory.incompatible
        }
    }
}

public struct BandSampleIdentity: Hashable, Codable, Sendable {
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
}

public struct BandSample: Equatable, Codable, Sendable {
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
}

public struct BandSampleBatch: Equatable, Codable, Sendable {
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
}

public struct BandHistoryChunk: Equatable, Codable, Sendable {
    public let chunkIdentity: String
    public let previousCursor: String?
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
    public let acknowledgementToken: String
    public let batches: [BandSampleBatch]

    public init(
        chunkIdentity: String,
        previousCursor: String?,
        nextCursor: String?,
        complete: Bool,
        overflowed: Bool,
        acknowledgementToken: String,
        batches: [BandSampleBatch]
    ) {
        self.chunkIdentity = chunkIdentity
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
        self.complete = complete
        self.overflowed = overflowed
        self.acknowledgementToken = acknowledgementToken
        self.batches = batches
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
              batches.count <= BandContractLimits.batchesPerHistoryChunk,
              batches.reduce(0, { $0 + $1.samples.count })
                <= BandContractLimits.samplesPerHistoryChunk
        else {
            throw BandFailureCategory.invalidInput
        }
        try batches.forEach { try $0.validate(expectedLane: .history) }
    }
}

public struct BandHistoryCheckpoint: Equatable, Sendable {
    public let sourceIdentity: String
    public let acknowledgedCursor: String?
    public let lastHistoryComplete: Bool?
    public let durableSampleIdentities: Set<BandSampleIdentity>

    public init(
        sourceIdentity: String,
        acknowledgedCursor: String?,
        lastHistoryComplete: Bool?,
        durableSampleIdentities: Set<BandSampleIdentity>
    ) {
        self.sourceIdentity = sourceIdentity
        self.acknowledgedCursor = acknowledgedCursor
        self.lastHistoryComplete = lastHistoryComplete
        self.durableSampleIdentities = durableSampleIdentities
    }

    public func validate() throws {
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
              })
        else {
            throw BandFailureCategory.invalidInput
        }
    }
}

public struct BandOperationToken: Equatable, Sendable {
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
}

public struct LiveAcceptance: Equatable, Sendable {
    public let acceptedSamples: [BandSample]
    public let duplicateSamples: Int
    let sessionNonce: UUID
    let generation: UInt64
    let receiptSequence: UInt64

    init(
        acceptedSamples: [BandSample],
        duplicateSamples: Int,
        sessionNonce: UUID,
        generation: UInt64,
        receiptSequence: UInt64
    ) {
        self.acceptedSamples = acceptedSamples
        self.duplicateSamples = duplicateSamples
        self.sessionNonce = sessionNonce
        self.generation = generation
        self.receiptSequence = receiptSequence
    }
}

public struct DurableLiveReceipt: Equatable, Sendable {
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
}

public struct HistoryAcceptance: Equatable, Sendable {
    public let chunkIdentity: String
    public let acknowledgementToken: String
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
    public let acceptedSamples: Int
    public let duplicateSamples: Int
    let sessionNonce: UUID
    let receiptSequence: UInt64

    init(
        chunkIdentity: String,
        acknowledgementToken: String,
        nextCursor: String?,
        complete: Bool,
        overflowed: Bool,
        acceptedSamples: Int,
        duplicateSamples: Int,
        sessionNonce: UUID,
        receiptSequence: UInt64
    ) {
        self.chunkIdentity = chunkIdentity
        self.acknowledgementToken = acknowledgementToken
        self.nextCursor = nextCursor
        self.complete = complete
        self.overflowed = overflowed
        self.acceptedSamples = acceptedSamples
        self.duplicateSamples = duplicateSamples
        self.sessionNonce = sessionNonce
        self.receiptSequence = receiptSequence
    }
}

public struct DurableHistoryReceipt: Equatable, Sendable {
    public let chunkIdentity: String
    public let acknowledgementToken: String
    public let nextCursor: String?
    public let complete: Bool
    public let overflowed: Bool
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
        self.historyStateCommitted = historyStateCommitted
        self.committedSamples = committedSamples
        self.committed = committed
        sessionNonce = acceptance.sessionNonce
        receiptSequence = acceptance.receiptSequence
    }
}

public struct BandSessionSnapshot: Equatable, Sendable {
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
}
