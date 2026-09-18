import Foundation
import NoopRemoteSync

#if os(iOS)
@MainActor
enum ManagedCloudRetryScheduler {
    typealias PendingRetry = ManagedCloudRetryStateStore.PendingRetry

    static func pendingRetry(
        for scope: ManagedCloudRetryScope,
        defaults: UserDefaults = .standard
    ) -> PendingRetry? {
        ManagedCloudRetryStateStore.pendingRetry(
            for: scope,
            defaults: defaults
        )
    }

    static func shouldAttempt(
        _ scope: ManagedCloudRetryScope,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let pending = pendingRetry(
            for: scope,
            defaults: defaults
        ) else {
            return true
        }
        guard pending.notBefore <= now else {
            BackgroundSyncScheduler.requestWake(
                noLaterThan: pending.notBefore,
                now: now
            )
            return false
        }
        return true
    }

    @discardableResult
    static func recordFailure(
        scope: ManagedCloudRetryScope,
        retryAfter: TimeInterval?,
        failureKind: String,
        now: Date = Date(),
        jitterUnit: Double = Double.random(in: 0...1),
        defaults: UserDefaults = .standard
    ) -> ManagedStorageRetryPlan {
        let prior = ManagedCloudRetryStateStore.failureCount(
            for: scope,
            defaults: defaults
        )
        let nextCount = min(
            max(0, prior) + 1,
            ManagedStorageRetryPolicy.maximumFailureCount
        )
        let plan = ManagedStorageRetryPolicy.plan(
            afterFailure: nextCount,
            retryAfter: retryAfter,
            jitterUnit: jitterUnit
        )
        let notBefore = now.addingTimeInterval(plan.delay)
        ManagedCloudRetryStateStore.store(
            scope: scope,
            failureCount: plan.failureCount,
            notBefore: notBefore,
            defaults: defaults
        )
        BackgroundSyncScheduler.requestWake(
            noLaterThan: notBefore,
            now: now
        )
        AppDiagnosticsRecorder.shared.record(
            "managed_sync.retry_scheduled",
            fields: [
                "attempt": String(plan.failureCount),
                "delay_bucket": plan.delayBucket,
                "delay_source": plan.retryAfterApplied ? "server" : "policy",
                "failure_kind": failureKind,
                "scope": scope.rawValue,
            ]
        )
        return plan
    }

    static func clear(
        _ scope: ManagedCloudRetryScope,
        defaults: UserDefaults = .standard
    ) {
        ManagedCloudRetryStateStore.clear(
            scope,
            defaults: defaults
        )
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        ManagedCloudRetryStateStore.clearAll(defaults: defaults)
    }
}
#endif
