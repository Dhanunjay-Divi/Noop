import Foundation

public enum BandDiagnosticKind: String, Codable, Sendable {
    case discovery
    case connection
    case authentication
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
    case staged
    case completed
    case cancelled
    case rejected
    case timedOut
    case stale
    case interrupted
    case failed
    case terminal
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
    public let failureCategory: BandFailureCategory?
    public let countBucket: BandCountBucket?
    public let durationBucket: BandDurationBucket?

    public init(
        kind: BandDiagnosticKind,
        outcome: BandDiagnosticOutcome,
        failureCategory: BandFailureCategory? = nil,
        countBucket: BandCountBucket? = nil,
        durationBucket: BandDurationBucket? = nil
    ) {
        self.kind = kind
        self.outcome = outcome
        self.failureCategory = failureCategory
        self.countBucket = countBucket
        self.durationBucket = durationBucket
    }
}

public actor BandDiagnosticsRecorder {
    private let capacity: Int
    private var events: [BandDiagnosticEvent] = []
    private var suspendNextRecordForTesting = false
    private var suspendedRecordContinuation:
        CheckedContinuation<Void, Never>?

    public init(capacity: Int = 128) {
        self.capacity = max(1, min(capacity, 512))
    }

    public func record(_ event: BandDiagnosticEvent) async {
        append(event)
        await suspendRecordIfRequestedForTesting()
    }

    public func record(_ batch: [BandDiagnosticEvent]) {
        for event in batch {
            append(event)
        }
    }

    public func recordCoalescingConsecutive(
        _ event: BandDiagnosticEvent
    ) {
        if let last = events.last,
           last.kind == event.kind,
           last.outcome == event.outcome,
           last.failureCategory == nil,
           event.failureCategory == nil
        {
            events[events.count - 1] = event
            return
        }
        append(event)
    }

    private func append(_ event: BandDiagnosticEvent) {
        if events.count == capacity {
            events.removeFirst()
        }
        events.append(event)
    }

    public func snapshot() -> [BandDiagnosticEvent] {
        events
    }

    func requestNextRecordSuspensionForTesting() {
        suspendNextRecordForTesting = true
    }

    func waitForRecordSuspensionForTesting() async {
        while suspendedRecordContinuation == nil {
            await Task.yield()
        }
    }

    func resumeSuspendedRecordForTesting() {
        suspendedRecordContinuation?.resume()
        suspendedRecordContinuation = nil
    }

    private func suspendRecordIfRequestedForTesting() async {
        guard suspendNextRecordForTesting else {
            return
        }
        suspendNextRecordForTesting = false
        await withCheckedContinuation { continuation in
            suspendedRecordContinuation = continuation
        }
    }
}
