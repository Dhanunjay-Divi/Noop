import XCTest
@testable import NoopRemoteSync

final class ManagedStorageRetryPolicyTests: XCTestCase {
    func testBackoffIsJitteredExponentialAndBounded() {
        XCTAssertEqual(
            ManagedStorageRetryPolicy.plan(
                afterFailure: 1,
                retryAfter: nil,
                jitterUnit: 0
            ),
            ManagedStorageRetryPlan(
                failureCount: 1,
                delay: 23,
                retryAfterApplied: false,
                delayBucket: "under_1m"
            )
        )
        XCTAssertEqual(
            ManagedStorageRetryPolicy.plan(
                afterFailure: 2,
                retryAfter: nil,
                jitterUnit: 0.5
            ).delay,
            60
        )
        XCTAssertEqual(
            ManagedStorageRetryPolicy.plan(
                afterFailure: 99,
                retryAfter: nil,
                jitterUnit: 1
            ),
            ManagedStorageRetryPlan(
                failureCount: 7,
                delay: 1_800,
                retryAfterApplied: false,
                delayBucket: "30m_to_2h"
            )
        )
    }

    func testRetryAfterIsALowerBoundAndClamped() {
        XCTAssertEqual(
            ManagedStorageRetryPolicy.plan(
                afterFailure: 1,
                retryAfter: 300,
                jitterUnit: 0.5
            ),
            ManagedStorageRetryPlan(
                failureCount: 1,
                delay: 300,
                retryAfterApplied: true,
                delayBucket: "5_to_30m"
            )
        )
        XCTAssertEqual(
            ManagedStorageRetryPolicy.plan(
                afterFailure: 1,
                retryAfter: 999_999,
                jitterUnit: 0.5
            ).delay,
            ManagedStorageRetryPolicy.maximumRetryAfter
        )
    }

    func testRetryAfterAcceptsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            ManagedStorageRetryPolicy.retryAfter(from: "300", now: now),
            300
        )
        XCTAssertEqual(
            ManagedStorageRetryPolicy.retryAfter(
                from: "Thu, 01 Jan 1970 00:05:00 GMT",
                now: now
            ),
            300
        )
        XCTAssertNil(
            ManagedStorageRetryPolicy.retryAfter(from: "0", now: now)
        )
        XCTAssertNil(
            ManagedStorageRetryPolicy.retryAfter(from: "invalid", now: now)
        )
    }

    func testOnlyTransientManagedStorageFailuresAreAutomaticRetryable() {
        XCTAssertTrue(ManagedStorageError.transport.isAutomaticRetryable)
        XCTAssertTrue(
            ManagedStorageError.server(status: 408).isAutomaticRetryable
        )
        XCTAssertTrue(
            ManagedStorageError.server(status: 429).isAutomaticRetryable
        )
        XCTAssertTrue(
            ManagedStorageError.server(status: 503).isAutomaticRetryable
        )
        XCTAssertFalse(
            ManagedStorageError.server(status: 422).isAutomaticRetryable
        )
        XCTAssertFalse(ManagedStorageError.authentication.isAutomaticRetryable)
    }
}
