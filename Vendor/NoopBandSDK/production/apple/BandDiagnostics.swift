import Foundation

public enum BandDiagnosticKind: String, Codable, Sendable {
    case discovery
    case connection
    case capability
    case command
    case live
    case history
    case reconnect
    case firmware
    case pressure
}

public enum BandDiagnosticOutcome: String, Codable, Sendable {
    case began
    case completed
    case cancelled
    case rejected
    case timedOut
    case stale
    case interrupted
    case failed
}

public enum BandCountBucket: String, Codable, Sendable {
    case zero
    case one
    case twoToTen
    case elevenToHundred
    case overHundred

    public init(count: Int) {
        switch count {
        case ...0:
            self = .zero
        case 1:
            self = .one
        case 2 ... 10:
            self = .twoToTen
        case 11 ... 100:
            self = .elevenToHundred
        default:
            self = .overHundred
        }
    }
}

public enum BandDurationBucket: String, Codable, Sendable {
    case underSecond
    case oneToFiveSeconds
    case sixToThirtySeconds
    case thirtyOneToThreeHundredSeconds
    case overThreeHundredSeconds

    public init(milliseconds: Int) {
        switch milliseconds {
        case ..<1_000:
            self = .underSecond
        case 1_000 ... 5_000:
            self = .oneToFiveSeconds
        case 5_001 ... 30_000:
            self = .sixToThirtySeconds
        case 30_001 ... 300_000:
            self = .thirtyOneToThreeHundredSeconds
        default:
            self = .overThreeHundredSeconds
        }
    }
}

public struct BandDiagnosticEvent: Equatable, Codable, Sendable {
    public let kind: BandDiagnosticKind
    public let outcome: BandDiagnosticOutcome
    public let countBucket: BandCountBucket?
    public let durationBucket: BandDurationBucket?

    public init(
        kind: BandDiagnosticKind,
        outcome: BandDiagnosticOutcome,
        countBucket: BandCountBucket? = nil,
        durationBucket: BandDurationBucket? = nil
    ) {
        self.kind = kind
        self.outcome = outcome
        self.countBucket = countBucket
        self.durationBucket = durationBucket
    }
}

public actor BandDiagnosticsRecorder {
    private let capacity: Int
    private var events: [BandDiagnosticEvent] = []

    public init(capacity: Int = 128) {
        self.capacity = max(1, min(capacity, 512))
    }

    public func record(_ event: BandDiagnosticEvent) {
        if events.count == capacity {
            events.removeFirst()
        }
        events.append(event)
    }

    public func snapshot() -> [BandDiagnosticEvent] {
        events
    }
}
