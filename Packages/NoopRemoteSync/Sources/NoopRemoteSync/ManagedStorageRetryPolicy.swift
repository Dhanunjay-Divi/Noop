import Foundation

public struct ManagedStorageRetryPlan: Equatable, Sendable {
    public let failureCount: Int
    public let delay: TimeInterval
    public let retryAfterApplied: Bool
    public let delayBucket: String

    public init(
        failureCount: Int,
        delay: TimeInterval,
        retryAfterApplied: Bool,
        delayBucket: String
    ) {
        self.failureCount = failureCount
        self.delay = delay
        self.retryAfterApplied = retryAfterApplied
        self.delayBucket = delayBucket
    }
}

public enum ManagedStorageRetryPolicy {
    public static let maximumFailureCount = 7
    public static let initialDelay: TimeInterval = 30
    public static let maximumBackoffDelay: TimeInterval = 30 * 60
    public static let maximumRetryAfter: TimeInterval = 6 * 60 * 60

    public static func plan(
        afterFailure failureCount: Int,
        retryAfter: TimeInterval?,
        jitterUnit: Double
    ) -> ManagedStorageRetryPlan {
        let boundedCount = min(max(1, failureCount), maximumFailureCount)
        let exponent = boundedCount - 1
        let exponential = min(
            maximumBackoffDelay,
            initialDelay * pow(2, Double(exponent))
        )
        let boundedJitter = min(max(jitterUnit, 0), 1)
        let jittered = min(
            maximumBackoffDelay,
            ceil(exponential * (0.75 + boundedJitter * 0.5))
        )
        let boundedRetryAfter = retryAfter.map {
            min(max(1, $0), maximumRetryAfter)
        }
        let delay = max(jittered, boundedRetryAfter ?? 0)
        return ManagedStorageRetryPlan(
            failureCount: boundedCount,
            delay: delay,
            retryAfterApplied: boundedRetryAfter.map { $0 > jittered } ?? false,
            delayBucket: delayBucket(for: delay)
        )
    }

    public static func retryAfter(
        from rawValue: String?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }

        if let seconds = Int64(value), seconds > 0 {
            return min(TimeInterval(seconds), maximumRetryAfter)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = ceil(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        return min(seconds, maximumRetryAfter)
    }

    public static func delayBucket(for delay: TimeInterval) -> String {
        switch delay {
        case ..<60:
            return "under_1m"
        case ..<(5.0 * 60.0):
            return "1_to_5m"
        case ..<(30.0 * 60.0):
            return "5_to_30m"
        case ..<(2.0 * 60.0 * 60.0):
            return "30m_to_2h"
        default:
            return "2h_to_6h"
        }
    }
}

public extension ManagedStorageError {
    var retryAfter: TimeInterval? {
        guard case .server(_, let retryAfter) = self else { return nil }
        return retryAfter
    }

    var isAutomaticRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .server(let status, _):
            return status == 408 || status == 429 || status >= 500
        default:
            return false
        }
    }
}
