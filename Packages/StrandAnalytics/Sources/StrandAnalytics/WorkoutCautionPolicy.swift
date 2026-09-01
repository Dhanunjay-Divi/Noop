import Foundation

/// Sustained-exertion guidance for a user-started workout.
///
/// HRmax is a personalized exertion reference, not a medical limit. The policy rejects impossible and
/// uncorroborated jump samples, smooths accepted readings, requires dwell, and rate-limits cues. Its
/// strongest output means "pause and assess how you feel", never "a medical event was detected".
public struct WorkoutCautionPolicy {
    public static let easeFractionOfMax = 0.90
    public static let pauseFractionOfMax = 0.97
    public static let easeResetFractionOfMax = 0.87
    public static let pauseResetFractionOfMax = 0.94
    public static let smoothingWindowSec = 12
    public static let staleAfterSec = 8
    public static let warmupSec = 60
    public static let easeDwellSec = 45
    public static let pauseDwellSec = 45
    public static let easeCooldownSec = 5 * 60
    public static let pauseCooldownSec = 10 * 60
    public static let minimumCueGapSec = 90
    public static let minPlausibleBpm = 25.0
    public static let maxPlausibleBpm = 240.0
    public static let maxJumpBpm = 45.0
    public static let jumpCorroborationSec = 5
    public static let jumpCorroborationBpm = 8.0

    public struct Config: Equatable, Sendable {
        public let hrMax: Double

        public init(hrMax: Double) {
            self.hrMax = hrMax
        }
    }

    public enum Status: String, Equatable, Sendable, Codable {
        case warmup
        case active
        case stale
    }

    public enum Level: String, Equatable, Sendable, Codable {
        case comfortable
        case high
        case veryHigh
    }

    public enum Cue: String, Equatable, Sendable, Codable {
        case easeOff
        case pauseAndAssess
        case recovered
    }

    public struct Output: Equatable, Sendable {
        public let status: Status
        public let level: Level
        public let smoothedBpm: Double?
        public let sampleArrived: Bool
        public let cue: Cue?

        public init(
            status: Status,
            level: Level,
            smoothedBpm: Double?,
            sampleArrived: Bool,
            cue: Cue?
        ) {
            self.status = status
            self.level = level
            self.smoothedBpm = smoothedBpm
            self.sampleArrived = sampleArrived
            self.cue = cue
        }
    }

    private struct Reading {
        let ts: Int
        let bpm: Int
    }

    private let config: Config
    private let startTs: Int
    private var buffer: [Reading] = []
    private var lastValidTs: Int?
    private var lastAcceptedBpm: Double?
    private var pendingJumpBpm: Double?
    private var pendingJumpAt: Int?
    private var easeSince: Int?
    private var pauseSince: Int?
    private var lastEaseAt: Int?
    private var lastPauseAt: Int?
    private var lastCueAt: Int?
    private var recoveryArmed = false

    public init(config: Config, startTs: Int) {
        self.config = config
        self.startTs = startTs
    }

    public mutating func update(now: Int, bpm: Int?) -> Output {
        if let lastValidTs, now - lastValidTs > Self.staleAfterSec {
            resetAfterGap()
        }

        var sampleArrived = false
        if let bpm, accept(bpm: bpm, now: now) {
            buffer.append(Reading(ts: now, bpm: bpm))
            lastValidTs = now
            lastAcceptedBpm = Double(bpm)
            sampleArrived = true
        }

        buffer.removeAll { $0.ts < now - Self.smoothingWindowSec }
        let stale = lastValidTs.map { now - $0 > Self.staleAfterSec } ?? true
        guard !stale, !buffer.isEmpty else {
            return Output(
                status: .stale,
                level: .comfortable,
                smoothedBpm: nil,
                sampleArrived: sampleArrived,
                cue: nil
            )
        }

        let smoothed = median(buffer.map { Double($0.bpm) })
        let pauseThreshold = config.hrMax * Self.pauseFractionOfMax
        let easeThreshold = config.hrMax * Self.easeFractionOfMax
        let level: Level = smoothed >= pauseThreshold
            ? .veryHigh
            : (smoothed >= easeThreshold ? .high : .comfortable)

        if smoothed >= pauseThreshold {
            if pauseSince == nil { pauseSince = now }
        } else if smoothed < config.hrMax * Self.pauseResetFractionOfMax {
            pauseSince = nil
        }
        if smoothed >= easeThreshold {
            if easeSince == nil { easeSince = now }
        } else if smoothed < config.hrMax * Self.easeResetFractionOfMax {
            easeSince = nil
        }

        let status: Status = now - startTs < Self.warmupSec ? .warmup : .active
        guard status == .active, sampleArrived else {
            return Output(
                status: status,
                level: level,
                smoothedBpm: smoothed,
                sampleArrived: sampleArrived,
                cue: nil
            )
        }

        var cue: Cue?
        let globalReady = lastCueAt.map { now - $0 >= Self.minimumCueGapSec } ?? true
        if recoveryArmed, smoothed < config.hrMax * Self.easeResetFractionOfMax {
            cue = .recovered
            recoveryArmed = false
        } else if globalReady,
                  let since = pauseSince,
                  now - since >= Self.pauseDwellSec,
                  lastPauseAt.map({ now - $0 >= Self.pauseCooldownSec }) ?? true {
            cue = .pauseAndAssess
            lastPauseAt = now
            lastCueAt = now
            pauseSince = now
            easeSince = now
            recoveryArmed = true
        } else if globalReady,
                  smoothed < pauseThreshold,
                  let since = easeSince,
                  now - since >= Self.easeDwellSec,
                  lastEaseAt.map({ now - $0 >= Self.easeCooldownSec }) ?? true {
            cue = .easeOff
            lastEaseAt = now
            lastCueAt = now
            easeSince = now
            recoveryArmed = true
        }

        return Output(
            status: status,
            level: level,
            smoothedBpm: smoothed,
            sampleArrived: sampleArrived,
            cue: cue
        )
    }

    private mutating func accept(bpm: Int, now: Int) -> Bool {
        let value = Double(bpm)
        guard config.hrMax.isFinite,
              (100...240).contains(config.hrMax),
              value >= Self.minPlausibleBpm,
              value <= Self.maxPlausibleBpm else {
            return false
        }

        guard let prior = lastAcceptedBpm,
              let priorAt = lastValidTs,
              now - priorAt <= Self.smoothingWindowSec,
              abs(value - prior) > Self.maxJumpBpm else {
            pendingJumpBpm = nil
            pendingJumpAt = nil
            return true
        }

        if let pending = pendingJumpBpm,
           let pendingAt = pendingJumpAt,
           now - pendingAt <= Self.jumpCorroborationSec,
           abs(value - pending) <= Self.jumpCorroborationBpm {
            pendingJumpBpm = nil
            pendingJumpAt = nil
            return true
        }
        pendingJumpBpm = value
        pendingJumpAt = now
        return false
    }

    private mutating func resetAfterGap() {
        buffer.removeAll(keepingCapacity: true)
        easeSince = nil
        pauseSince = nil
        pendingJumpBpm = nil
        pendingJumpAt = nil
        recoveryArmed = false
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
