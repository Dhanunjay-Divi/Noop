import Foundation
import StrandAnalytics
import WhoopStore

enum SmartAlarmRuntimeState: Equatable {
    case off
    case fixed(Date)
    case waitingForSleep
    case durationScheduled(fireDate: Date, asleepMinutes: Int, targetMinutes: Int)
    case durationReached(asleepMinutes: Int, targetMinutes: Int)
}

/// Pure policy for the detected-sleep alarm. It accepts only stage-rich, recent sessions produced by
/// NOOP's on-device detector; imported summary dictionaries cannot masquerade as a live sleep stream.
enum SleepDurationAlarmPolicy {
    static let minimumTargetMinutes = 4 * 60
    static let maximumTargetMinutes = 12 * 60
    static let minimumObservedSleepMinutes = 30
    static let maximumSessionAge: TimeInterval = 18 * 60 * 60
    static let maximumObservationLag: TimeInterval = 90 * 60
    static let maximumImmediateFireLag: TimeInterval = 30 * 60
    static let fragmentJoinGap: TimeInterval = 90 * 60

    struct Observation: Equatable {
        let sessionStart: Int
        let observedThrough: Int
        let asleepSeconds: Int

        var asleepMinutes: Int { asleepSeconds / 60 }
    }

    enum Decision: Equatable {
        case waiting
        case schedule(fireDate: Date, observation: Observation, targetMinutes: Int)
        case fire(observation: Observation, targetMinutes: Int)
        case alreadyFired(observation: Observation, targetMinutes: Int)
    }

    static func normalizedTargetMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minimumTargetMinutes), maximumTargetMinutes)
    }

    /// Decode one locally computed session. Imported and manual rows carry no gravity-coverage verdict,
    /// while a sparse local window is not reliable enough to drive an unattended wake alarm.
    /// Overlapping or malformed stage arrays are rejected instead of double-counting sleep.
    static func observation(from session: CachedSleepSession) -> Observation? {
        guard session.gravitySparse == false,
              let json = session.stagesJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([StageSegment].self, from: data),
              !segments.isEmpty else { return nil }

        let ordered = segments.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var previousEnd = Int.min
        var asleepSeconds = 0
        var observedThrough = Int.min

        for segment in ordered {
            guard segment.end > segment.start,
                  segment.start >= session.effectiveStartTs - 60,
                  segment.end <= session.endTs + 60,
                  segment.start >= previousEnd else { return nil }
            previousEnd = segment.end
            observedThrough = max(observedThrough, segment.end)
            switch segment.stage.lowercased() {
            case "light", "deep", "rem":
                asleepSeconds += segment.end - segment.start
            case "wake", "awake":
                break
            default:
                return nil
            }
        }

        guard observedThrough > session.effectiveStartTs, asleepSeconds > 0 else { return nil }
        return Observation(
            sessionStart: session.effectiveStartTs,
            observedThrough: observedThrough,
            asleepSeconds: asleepSeconds
        )
    }

    static func decision(
        sessions: [CachedSleepSession],
        targetMinutes rawTargetMinutes: Int,
        weekdays: Set<Int>,
        lastFiredSessionStart: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Decision {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let observations = joinedObservations(
            sessions.compactMap(observation(from:))
                .filter {
                    $0.sessionStart <= nowSeconds
                        && nowSeconds - $0.sessionStart <= Int(maximumSessionAge)
                        && $0.observedThrough <= nowSeconds + 5 * 60
                        && nowSeconds - $0.observedThrough <= Int(maximumObservationLag)
                }
        )
        guard let observation = observations.max(by: {
            $0.observedThrough < $1.observedThrough
        }), observation.asleepMinutes >= minimumObservedSleepMinutes else {
            return .waiting
        }

        let targetMinutes = normalizedTargetMinutes(rawTargetMinutes)
        let targetSeconds = targetMinutes * 60
        if observation.asleepSeconds >= targetSeconds {
            guard weekdayEnabled(for: now, weekdays: weekdays, calendar: calendar),
                  nowSeconds - observation.observedThrough <= Int(maximumImmediateFireLag) else {
                return .waiting
            }
            if lastFiredSessionStart == observation.sessionStart {
                return .alreadyFired(observation: observation, targetMinutes: targetMinutes)
            }
            return .fire(observation: observation, targetMinutes: targetMinutes)
        }

        let remainingSeconds = targetSeconds - observation.asleepSeconds
        let projectedSeconds = max(
            observation.observedThrough + remainingSeconds,
            nowSeconds + 60
        )
        let fireDate = Date(timeIntervalSince1970: TimeInterval(projectedSeconds))
        guard weekdayEnabled(for: fireDate, weekdays: weekdays, calendar: calendar) else {
            return .waiting
        }
        return .schedule(
            fireDate: fireDate,
            observation: observation,
            targetMinutes: targetMinutes
        )
    }

    private static func weekdayEnabled(
        for date: Date,
        weekdays: Set<Int>,
        calendar: Calendar
    ) -> Bool {
        let valid = weekdays.filter { (1...7).contains($0) }
        if weekdays.isEmpty { return true }
        guard !valid.isEmpty else { return false }
        return valid.contains(calendar.component(.weekday, from: date))
    }

    private static func joinedObservations(_ observations: [Observation]) -> [Observation] {
        let ordered = observations.sorted {
            $0.sessionStart == $1.sessionStart
                ? $0.observedThrough < $1.observedThrough
                : $0.sessionStart < $1.sessionStart
        }
        var result: [Observation] = []
        for observation in ordered {
            guard let previous = result.last,
                  observation.sessionStart >= previous.observedThrough,
                  observation.sessionStart - previous.observedThrough <= Int(fragmentJoinGap)
            else {
                result.append(observation)
                continue
            }
            result[result.count - 1] = Observation(
                sessionStart: previous.sessionStart,
                observedThrough: max(previous.observedThrough, observation.observedThrough),
                asleepSeconds: previous.asleepSeconds + observation.asleepSeconds
            )
        }
        return result
    }
}
