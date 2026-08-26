import Foundation

/// Wire-format version for the self-hosted Noop sync API.
public let noopRemoteSyncSchemaVersion = 1

public struct RemoteDeviceInfo: Codable, Equatable, Sendable {
    public let displayName: String?
    public let model: String?
    public let firmwareVersion: String?
    public let hardwareRevision: String?

    public init(
        displayName: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        hardwareRevision: String? = nil
    ) {
        self.displayName = displayName
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.hardwareRevision = hardwareRevision
    }
}

public struct RemoteSyncSource: Codable, Equatable, Sendable {
    public let deviceId: String
    public let sentAt: String
    public let appVersion: String?
    public let platform: String?
    public let device: RemoteDeviceInfo?
    public let metadata: [String: String]?

    public init(
        deviceId: String,
        sentAt: String = ISO8601DateFormatter().string(from: Date()),
        appVersion: String? = nil,
        platform: String? = nil,
        device: RemoteDeviceInfo? = nil,
        metadata: [String: String]? = nil
    ) {
        self.deviceId = deviceId
        self.sentAt = sentAt
        self.appVersion = appVersion
        self.platform = platform
        self.device = device
        self.metadata = metadata
    }
}

/// One scalar sample in a canonical stream. Units are defined by the API:
/// bpm, milliseconds, percent, degrees Celsius, breaths/minute, or steps.
public struct RemoteSample: Codable, Equatable, Sendable {
    public let recordedAt: Int
    public let value: Double
    public let quality: Double?
    public let metadata: [String: String]?

    public init(
        recordedAt: Int,
        value: Double,
        quality: Double? = nil,
        metadata: [String: String]? = nil
    ) {
        self.recordedAt = recordedAt
        self.value = value
        self.quality = quality
        self.metadata = metadata
    }
}

public struct RemoteEvent: Codable, Equatable, Sendable {
    public let eventId: String
    public let recordedAt: Int
    public let kind: String
    public let value: Double?
    public let metadata: [String: String]?

    public init(
        eventId: String,
        recordedAt: Int,
        kind: String,
        value: Double? = nil,
        metadata: [String: String]? = nil
    ) {
        self.eventId = eventId
        self.recordedAt = recordedAt
        self.kind = kind
        self.value = value
        self.metadata = metadata
    }
}

public struct RemoteStreams: Codable, Equatable, Sendable {
    public var hr: [RemoteSample]
    public var rr: [RemoteSample]
    public var battery: [RemoteSample]
    public var spo2: [RemoteSample]
    public var skinTemp: [RemoteSample]
    public var respiration: [RemoteSample]
    public var steps: [RemoteSample]
    public var events: [RemoteEvent]

    public init(
        hr: [RemoteSample] = [],
        rr: [RemoteSample] = [],
        battery: [RemoteSample] = [],
        spo2: [RemoteSample] = [],
        skinTemp: [RemoteSample] = [],
        respiration: [RemoteSample] = [],
        steps: [RemoteSample] = [],
        events: [RemoteEvent] = []
    ) {
        self.hr = hr
        self.rr = rr
        self.battery = battery
        self.spo2 = spo2
        self.skinTemp = skinTemp
        self.respiration = respiration
        self.steps = steps
        self.events = events
    }

    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && battery.isEmpty && spo2.isEmpty &&
            skinTemp.isEmpty && respiration.isEmpty && steps.isEmpty && events.isEmpty
    }
}

public struct RemoteSleepSession: Codable, Equatable, Sendable {
    public let sessionId: String
    public let startTs: Int
    public let endTs: Int
    public let efficiency: Double?
    public let restingHr: Int?
    public let avgHrv: Double?
    /// Canonical stage totals in whole seconds. Supported keys are `awake`, `light`, `deep`, and `rem`.
    ///
    /// The local cache has historically stored several JSON shapes and, for imported summaries,
    /// stage durations in minutes. The sync boundary normalises those representations so every client
    /// and server agrees on one unit and never has to infer whether a number means minutes or seconds.
    public let stages: [String: Int]?
    /// Per-session evidence required to decide whether locally classified detailed stages may publish.
    /// Raw stages remain backup data; consumers must enforce the evidence policy before presenting them.
    public let metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case startTs
        case endTs
        case efficiency
        case restingHr
        case avgHrv
        case stages
        case metadata
    }

    public init(
        sessionId: String,
        startTs: Int,
        endTs: Int,
        efficiency: Double? = nil,
        restingHr: Int? = nil,
        avgHrv: Double? = nil,
        stages: [String: Int]? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sessionId = sessionId
        self.startTs = startTs
        self.endTs = endTs
        self.efficiency = efficiency
        self.restingHr = restingHr
        self.avgHrv = avgHrv
        self.stages = stages
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        startTs = try container.decode(Int.self, forKey: .startTs)
        endTs = try container.decode(Int.self, forKey: .endTs)
        efficiency = try container.decodeIfPresent(Double.self, forKey: .efficiency)
        restingHr = try container.decodeIfPresent(Int.self, forKey: .restingHr)
        avgHrv = try container.decodeIfPresent(Double.self, forKey: .avgHrv)
        stages = try container.decodeIfPresent([String: Int].self, forKey: .stages)
        metadata = try container.decodeIfPresent(
            [String: String].self,
            forKey: .metadata
        ) ?? [:]
    }
}

public struct RemoteWorkout: Codable, Equatable, Sendable {
    public let workoutId: String
    public let startTs: Int
    public let endTs: Int
    public let sport: String
    public let source: String?
    public let metrics: [String: Double]?

    public init(
        workoutId: String,
        startTs: Int,
        endTs: Int,
        sport: String,
        source: String? = nil,
        metrics: [String: Double]? = nil
    ) {
        self.workoutId = workoutId
        self.startTs = startTs
        self.endTs = endTs
        self.sport = sport
        self.source = source
        self.metrics = metrics
    }
}

public struct RemoteJournalEntry: Codable, Equatable, Sendable {
    public let day: String
    public let question: String
    public let answeredYes: Bool
    public let notes: String?
    public let numericValue: Double?

    public init(
        day: String,
        question: String,
        answeredYes: Bool,
        notes: String? = nil,
        numericValue: Double? = nil
    ) {
        self.day = day
        self.question = question
        self.answeredYes = answeredYes
        self.notes = notes
        self.numericValue = numericValue
    }
}

public struct RemoteSyncEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let batchId: UUID
    public let source: RemoteSyncSource
    public let streams: RemoteStreams
    public let dailyMetrics: [String: [String: Double]]
    public let sleepSessions: [RemoteSleepSession]
    public let workouts: [RemoteWorkout]
    public let journal: [RemoteJournalEntry]

    public init(
        schemaVersion: Int = noopRemoteSyncSchemaVersion,
        batchId: UUID = UUID(),
        source: RemoteSyncSource,
        streams: RemoteStreams = RemoteStreams(),
        dailyMetrics: [String: [String: Double]] = [:],
        sleepSessions: [RemoteSleepSession] = [],
        workouts: [RemoteWorkout] = [],
        journal: [RemoteJournalEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.batchId = batchId
        self.source = source
        self.streams = streams
        self.dailyMetrics = dailyMetrics
        self.sleepSessions = sleepSessions
        self.workouts = workouts
        self.journal = journal
    }

    public var isEmpty: Bool {
        streams.isEmpty && dailyMetrics.isEmpty && sleepSessions.isEmpty &&
            workouts.isEmpty && journal.isEmpty
    }
}

public struct RemoteSyncResponse: Codable, Equatable, Sendable {
    public let batchId: UUID
    public let status: String
    public let counts: [String: Int]
    public let duplicate: Bool

    public init(batchId: UUID, status: String, counts: [String: Int], duplicate: Bool) {
        self.batchId = batchId
        self.status = status
        self.counts = counts
        self.duplicate = duplicate
    }
}

public struct RemoteHealthResponse: Codable, Equatable, Sendable {
    public let status: String

    public init(status: String) { self.status = status }
}
