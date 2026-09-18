import Foundation
import NoopRemoteSync

enum ManagedCloudRetryScope: String, CaseIterable {
    case core
    case social
    case safety
}

struct ManagedCloudRetryStateStore {
    struct PendingRetry: Equatable {
        let failureCount: Int
        let notBefore: Date
    }

    private enum Key {
        static let legacyFailureCount =
            "managedCloud.retry.failureCount.v1"
        static let legacyNotBefore =
            "managedCloud.retry.notBefore.v1"
        static let scopeMigrationComplete =
            "managedCloud.retry.scopeMigrationComplete.v2"

        static func failureCount(_ scope: ManagedCloudRetryScope) -> String {
            "managedCloud.retry.\(scope.rawValue).failureCount.v2"
        }

        static func notBefore(_ scope: ManagedCloudRetryScope) -> String {
            "managedCloud.retry.\(scope.rawValue).notBefore.v2"
        }
    }

    static func failureCount(
        for scope: ManagedCloudRetryScope,
        defaults: UserDefaults = .standard
    ) -> Int {
        migrateLegacyStateIfNeeded(defaults: defaults)
        return max(
            0,
            defaults.integer(forKey: Key.failureCount(scope))
        )
    }

    static func pendingRetry(
        for scope: ManagedCloudRetryScope,
        defaults: UserDefaults = .standard
    ) -> PendingRetry? {
        migrateLegacyStateIfNeeded(defaults: defaults)
        let failureCount = max(
            0,
            defaults.integer(forKey: Key.failureCount(scope))
        )
        let notBefore = defaults.double(forKey: Key.notBefore(scope))
        guard failureCount > 0, notBefore > 0 else { return nil }
        return PendingRetry(
            failureCount: min(
                failureCount,
                ManagedStorageRetryPolicy.maximumFailureCount
            ),
            notBefore: Date(timeIntervalSince1970: notBefore)
        )
    }

    static func store(
        scope: ManagedCloudRetryScope,
        failureCount: Int,
        notBefore: Date,
        defaults: UserDefaults = .standard
    ) {
        migrateLegacyStateIfNeeded(defaults: defaults)
        defaults.set(
            min(
                max(0, failureCount),
                ManagedStorageRetryPolicy.maximumFailureCount
            ),
            forKey: Key.failureCount(scope)
        )
        defaults.set(
            notBefore.timeIntervalSince1970,
            forKey: Key.notBefore(scope)
        )
    }

    static func clear(
        _ scope: ManagedCloudRetryScope,
        defaults: UserDefaults = .standard
    ) {
        migrateLegacyStateIfNeeded(defaults: defaults)
        defaults.removeObject(forKey: Key.failureCount(scope))
        defaults.removeObject(forKey: Key.notBefore(scope))
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        for scope in ManagedCloudRetryScope.allCases {
            defaults.removeObject(forKey: Key.failureCount(scope))
            defaults.removeObject(forKey: Key.notBefore(scope))
        }
        defaults.removeObject(forKey: Key.legacyFailureCount)
        defaults.removeObject(forKey: Key.legacyNotBefore)
        defaults.set(true, forKey: Key.scopeMigrationComplete)
    }

    private static func migrateLegacyStateIfNeeded(
        defaults: UserDefaults
    ) {
        guard !defaults.bool(forKey: Key.scopeMigrationComplete) else {
            return
        }
        let failureCount = min(
            max(0, defaults.integer(forKey: Key.legacyFailureCount)),
            ManagedStorageRetryPolicy.maximumFailureCount
        )
        let notBefore = defaults.double(forKey: Key.legacyNotBefore)
        if failureCount > 0, notBefore > 0 {
            // The previous ledger did not identify its failed endpoint.
            // Preserve the deadline for every scope once; each scope clears
            // independently after its next eligible attempt.
            for scope in ManagedCloudRetryScope.allCases {
                defaults.set(
                    failureCount,
                    forKey: Key.failureCount(scope)
                )
                defaults.set(
                    notBefore,
                    forKey: Key.notBefore(scope)
                )
            }
        }
        defaults.removeObject(forKey: Key.legacyFailureCount)
        defaults.removeObject(forKey: Key.legacyNotBefore)
        defaults.set(true, forKey: Key.scopeMigrationComplete)
    }
}
