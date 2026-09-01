import Foundation

/// Evidence-gated daily guidance shared by the Apple and Android apps.
///
/// This engine ranks observations; it does not schedule notifications or infer causes. In particular,
/// a late night is described as a routine shift, never as alcohol, a party, illness, or poor judgment.
/// Missing or stale data fails closed.
public enum AdaptiveDayGuidance {
    public static let minimumRoutineNights = 5
    public static let strongRoutineNights = 7
    public static let routineLookbackDays = 21
    public static let latestSleepMaximumAgeSeconds = 30 * 60 * 60
    public static let shortSleepThresholdMinutes = 60
    public static let lateRoutineThresholdMinutes = 90
    public static let routineDurationDropMinutes = 45
    public static let travelThresholdSeconds = 2 * 60 * 60
    public static let travelMaximumAgeSeconds = 36 * 60 * 60

    public enum Kind: String, Equatable, Sendable, Codable {
        case travelAdjustment
        case routineRecovery
        case sleepRecovery
    }

    public enum Confidence: String, Equatable, Sendable, Codable {
        case building
        case strong
    }

    public struct SleepDay: Equatable, Sendable {
        public let day: String
        public let totalSleepMinutes: Double?

        public init(day: String, totalSleepMinutes: Double?) {
            self.day = day
            self.totalSleepMinutes = totalSleepMinutes
        }
    }

    public struct SleepWindow: Equatable, Sendable {
        public let startSec: Int
        public let endSec: Int

        public init(startSec: Int, endSec: Int) {
            self.startSec = startSec
            self.endSec = endSec
        }
    }

    /// A persisted timezone transition. Keeping the observation after the offset snapshot advances lets
    /// delivery retry after quiet hours or a temporarily unavailable notification permission.
    public struct TimeZoneChange: Equatable, Sendable {
        public let previousOffsetSec: Int
        public let currentOffsetSec: Int
        public let observedAtSec: Int

        public init(previousOffsetSec: Int, currentOffsetSec: Int, observedAtSec: Int) {
            self.previousOffsetSec = previousOffsetSec
            self.currentOffsetSec = currentOffsetSec
            self.observedAtSec = observedAtSec
        }
    }

    public struct Input: Equatable, Sendable {
        public let today: String
        public let nowSec: Int
        public let currentTimeZoneOffsetSec: Int
        public let sleepTargetMinutes: Int
        public let sleepDays: [SleepDay]
        public let sleepWindows: [SleepWindow]
        public let timeZoneChange: TimeZoneChange?

        public init(
            today: String,
            nowSec: Int,
            currentTimeZoneOffsetSec: Int,
            sleepTargetMinutes: Int,
            sleepDays: [SleepDay],
            sleepWindows: [SleepWindow],
            timeZoneChange: TimeZoneChange?
        ) {
            self.today = today
            self.nowSec = nowSec
            self.currentTimeZoneOffsetSec = currentTimeZoneOffsetSec
            self.sleepTargetMinutes = sleepTargetMinutes
            self.sleepDays = sleepDays
            self.sleepWindows = sleepWindows
            self.timeZoneChange = timeZoneChange
        }
    }

    public struct Recommendation: Equatable, Sendable {
        public let kind: Kind
        public let observedAtSec: Int
        public let maximumAgeSeconds: Int
        public let confidence: Confidence
        public let fingerprint: String
        /// Stable, value-free reason tokens for diagnostics and tests.
        public let evidence: [String]

        public init(
            kind: Kind,
            observedAtSec: Int,
            maximumAgeSeconds: Int,
            confidence: Confidence,
            fingerprint: String,
            evidence: [String]
        ) {
            self.kind = kind
            self.observedAtSec = observedAtSec
            self.maximumAgeSeconds = maximumAgeSeconds
            self.confidence = confidence
            self.fingerprint = fingerprint
            self.evidence = evidence
        }
    }

    /// Returns the single highest-priority current recommendation: travel, then a measured routine shift,
    /// then short-sleep guidance. Delivery-level cooldowns remain the app shell's responsibility.
    public static func recommendation(_ input: Input) -> Recommendation? {
        if let travel = travelRecommendation(input) { return travel }

        let windows = eligibleWindows(input)
        if let routine = routineRecommendation(input, windows: windows) { return routine }
        return sleepRecommendation(input, windows: windows)
    }

    private static func travelRecommendation(_ input: Input) -> Recommendation? {
        guard let change = input.timeZoneChange else { return nil }
        let age = input.nowSec - change.observedAtSec
        let delta = normalizedTravelDeltaSeconds(
            previousOffsetSec: change.previousOffsetSec,
            currentOffsetSec: change.currentOffsetSec
        )
        guard age >= -5 * 60,
              age <= travelMaximumAgeSeconds,
              abs(change.previousOffsetSec) <= 14 * 60 * 60,
              abs(change.currentOffsetSec) <= 14 * 60 * 60,
              abs(delta) >= travelThresholdSeconds else { return nil }
        return Recommendation(
            kind: .travelAdjustment,
            observedAtSec: change.observedAtSec,
            maximumAgeSeconds: travelMaximumAgeSeconds,
            confidence: .strong,
            fingerprint: "travel:\(change.previousOffsetSec):\(change.currentOffsetSec):\(change.observedAtSec / 3600)",
            evidence: [delta > 0 ? "timezone-east" : "timezone-west", "offset-change"]
        )
    }

    /// Return the shortest wall-clock shift between two UTC offsets. Raw offset subtraction reports a
    /// 22-hour change for a two-hour International Date Line crossing; circadian guidance should use
    /// the equivalent two-hour shift instead. Exactly 24 hours means the local clock did not move.
    public static func normalizedTravelDeltaSeconds(
        previousOffsetSec: Int,
        currentOffsetSec: Int
    ) -> Int {
        let day = 24 * 60 * 60
        let halfDay = day / 2
        let raw = currentOffsetSec - previousOffsetSec
        return ((raw + halfDay) % day + day) % day - halfDay
    }

    private static func eligibleWindows(_ input: Input) -> [SleepWindow] {
        let oldest = input.nowSec - routineLookbackDays * 24 * 60 * 60
        var seen = Set<String>()
        let eligible = input.sleepWindows
            .filter { window in
                let duration = window.endSec - window.startSec
                guard window.startSec >= oldest,
                      window.endSec <= input.nowSec,
                      duration >= 3 * 60 * 60,
                      duration <= 14 * 60 * 60,
                      isOvernightOnset(window.startSec, offsetSec: input.currentTimeZoneOffsetSec)
                else { return false }
                return seen.insert("\(window.startSec):\(window.endSec)").inserted
            }
            .sorted { $0.endSec < $1.endSec }

        // A fragmented or duplicated night must not count as several routine observations. Keep the
        // longest eligible block on each noon-to-noon local sleep day, with latest end as the tie-break.
        var primaryByNight: [Int: SleepWindow] = [:]
        for window in eligible {
            let key = sleepNightKey(window.startSec, offsetSec: input.currentTimeZoneOffsetSec)
            guard let current = primaryByNight[key] else {
                primaryByNight[key] = window
                continue
            }
            let duration = window.endSec - window.startSec
            let currentDuration = current.endSec - current.startSec
            if duration > currentDuration
                || (duration == currentDuration && window.endSec > current.endSec) {
                primaryByNight[key] = window
            }
        }
        return primaryByNight.values.sorted { $0.endSec < $1.endSec }
    }

    private static func routineRecommendation(
        _ input: Input,
        windows: [SleepWindow]
    ) -> Recommendation? {
        guard let latest = windows.last,
              input.nowSec - latest.endSec <= latestSleepMaximumAgeSeconds else { return nil }
        let history = Array(windows.dropLast().suffix(14))
        guard history.count >= minimumRoutineNights else { return nil }

        let baselineOnset = median(history.map {
            bedtimeCoordinate($0.startSec, offsetSec: input.currentTimeZoneOffsetSec)
        })
        let latestOnset = bedtimeCoordinate(
            latest.startSec,
            offsetSec: input.currentTimeZoneOffsetSec
        )
        let delay = latestOnset - baselineOnset
        let baselineDuration = median(history.map { Double($0.endSec - $0.startSec) / 60.0 })
        let latestDuration = Double(latest.endSec - latest.startSec) / 60.0
        let target = Double(min(max(input.sleepTargetMinutes, 5 * 60), 11 * 60))
        let shortened = latestDuration <= baselineDuration - Double(routineDurationDropMinutes)
            || latestDuration <= target - Double(shortSleepThresholdMinutes)
        guard delay >= Double(lateRoutineThresholdMinutes), shortened else { return nil }

        return Recommendation(
            kind: .routineRecovery,
            observedAtSec: latest.endSec,
            maximumAgeSeconds: 18 * 60 * 60,
            confidence: history.count >= strongRoutineNights ? .strong : .building,
            fingerprint: "routine:\(latest.startSec / 900):\(latest.endSec / 900)",
            evidence: ["personal-sleep-timing", "later-onset", "shorter-sleep"]
        )
    }

    private static func sleepRecommendation(
        _ input: Input,
        windows: [SleepWindow]
    ) -> Recommendation? {
        let target = Double(min(max(input.sleepTargetMinutes, 5 * 60), 11 * 60))
        if let current = input.sleepDays.last(where: { $0.day == input.today }),
           let minutes = current.totalSleepMinutes,
           minutes.isFinite,
           (120...900).contains(minutes),
           target - minutes >= Double(shortSleepThresholdMinutes) {
            let observedAt = windows.last.map(\.endSec).flatMap { endSec -> Int? in
                let age = input.nowSec - endSec
                return (-5 * 60...latestSleepMaximumAgeSeconds).contains(age)
                    ? endSec
                    : nil
            } ?? input.nowSec
            return Recommendation(
                kind: .sleepRecovery,
                observedAtSec: observedAt,
                maximumAgeSeconds: 18 * 60 * 60,
                confidence: .strong,
                fingerprint: "sleep:\(input.today):\(Int(minutes.rounded()))",
                evidence: ["current-sleep", "below-explicit-target"]
            )
        }

        // A sleep block is a weaker fallback because time in bed is not the same as asleep time.
        guard let latest = windows.last,
              input.nowSec - latest.endSec <= latestSleepMaximumAgeSeconds else { return nil }
        let duration = Double(latest.endSec - latest.startSec) / 60.0
        guard target - duration >= Double(shortSleepThresholdMinutes) else { return nil }
        return Recommendation(
            kind: .sleepRecovery,
            observedAtSec: latest.endSec,
            maximumAgeSeconds: 18 * 60 * 60,
            confidence: .building,
            fingerprint: "sleep-window:\(latest.startSec / 900):\(latest.endSec / 900)",
            evidence: ["recent-sleep-window", "below-explicit-target"]
        )
    }

    private static func isOvernightOnset(_ epochSec: Int, offsetSec: Int) -> Bool {
        let minute = localMinute(epochSec, offsetSec: offsetSec)
        return minute >= 18 * 60 || minute < 6 * 60
    }

    private static func sleepNightKey(_ epochSec: Int, offsetSec: Int) -> Int {
        Int(floor(Double(epochSec + offsetSec - 12 * 60 * 60) / Double(24 * 60 * 60)))
    }

    /// Maps evening through early-morning bedtimes onto one monotonic 18:00...30:00 axis.
    private static func bedtimeCoordinate(_ epochSec: Int, offsetSec: Int) -> Double {
        let minute = localMinute(epochSec, offsetSec: offsetSec)
        return Double(minute < 12 * 60 ? minute + 24 * 60 : minute)
    }

    private static func localMinute(_ epochSec: Int, offsetSec: Int) -> Int {
        let day = 24 * 60 * 60
        let local = ((epochSec + offsetSec) % day + day) % day
        return local / 60
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
