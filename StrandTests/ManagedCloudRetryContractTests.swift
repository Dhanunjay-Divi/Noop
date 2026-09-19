import Foundation
@testable import Strand
import XCTest

final class ManagedCloudRetryContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "ManagedCloudRetryContractTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testScopedRetryStateClearsWithoutTouchingOtherScopesOrDefaults()
        throws
    {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let coreDeadline = Date(timeIntervalSince1970: 2_000_000_000)
        let safetyDeadline = Date(timeIntervalSince1970: 2_000_000_900)

        ManagedCloudRetryStateStore.store(
            scope: .core,
            failureCount: 2,
            notBefore: coreDeadline,
            defaults: defaults
        )
        ManagedCloudRetryStateStore.store(
            scope: .safety,
            failureCount: 4,
            notBefore: safetyDeadline,
            defaults: defaults
        )
        defaults.set("preserved", forKey: "unrelated")

        ManagedCloudRetryStateStore.clear(.core, defaults: defaults)

        XCTAssertNil(
            ManagedCloudRetryStateStore.pendingRetry(
                for: .core,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedCloudRetryStateStore.pendingRetry(
                for: .safety,
                defaults: defaults
            ),
            .init(failureCount: 4, notBefore: safetyDeadline)
        )
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserved")
    }

    func testLegacySharedDeadlineMigratesConservativelyOnce() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(3, forKey: "managedCloud.retry.failureCount.v1")
        defaults.set(
            deadline.timeIntervalSince1970,
            forKey: "managedCloud.retry.notBefore.v1"
        )

        for scope in ManagedCloudRetryScope.allCases {
            XCTAssertEqual(
                ManagedCloudRetryStateStore.pendingRetry(
                    for: scope,
                    defaults: defaults
                ),
                .init(failureCount: 3, notBefore: deadline)
            )
        }
        XCTAssertNil(
            defaults.object(forKey: "managedCloud.retry.failureCount.v1")
        )
        XCTAssertNil(
            defaults.object(forKey: "managedCloud.retry.notBefore.v1")
        )
    }

    func testCompletedAccountLifecyclesClearEveryRetryScope() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        XCTAssertGreaterThanOrEqual(
            apple.components(
                separatedBy: "ManagedCloudRetryScheduler.clearAll()"
            ).count - 1,
            3
        )
        XCTAssertTrue(
            apple.contains(
                "stopManagedSafetyLocationSharing(reason: \"signed_out\")\n"
                    + "            ManagedCloudRetryScheduler.clearAll()"
            )
        )
    }

    func testManualCoreSyncDoesNotClearAutomaticRetryState() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let start = try XCTUnwrap(
            apple.range(of: "func syncNow(repo: Repository) async")
        )
        let end = try XCTUnwrap(
            apple.range(
                of: "func exportCompleteCloudHistory",
                range: start.upperBound..<apple.endIndex
            )
        )
        let body = String(apple[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("ManagedCloudRetryScheduler.clear"))
    }

    func testAppleCatchUpRetriesAndClearsEachScopeIndependently() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let retry = try source("StrandiOS/System/ManagedCloudRetry.swift")

        for scope in ["core", "social", "safety"] {
            XCTAssertTrue(
                apple.contains(
                    "ManagedCloudRetryScheduler.pendingRetry(for: .\(scope))"
                )
            )
            XCTAssertTrue(
                apple.contains(
                    "ManagedCloudRetryScheduler.clear(.\(scope))"
                )
            )
            XCTAssertTrue(apple.contains("scope: .\(scope)"))
        }
        XCTAssertEqual(
            apple.components(
                separatedBy:
                    "if Self.isAutomaticCatchUpCancellation(error) { return false }"
            ).count - 1,
            3
        )
        XCTAssertFalse(apple.contains("strictestRetryableFailure"))
        XCTAssertTrue(retry.contains("\"scope\": scope.rawValue"))
        XCTAssertTrue(retry.contains("retryAfter: retryAfter"))
    }

    func testAppleBusyCatchUpRemainsIncompleteWithoutRetryingUnenrolledState()
        throws
    {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        XCTAssertTrue(
            apple.contains("guard phase == .enrolled else { return true }")
        )
        XCTAssertTrue(
            apple.contains(
                "guard !disconnecting,\n"
                    + "              !isBusy,\n"
                    + "              !running,\n"
                    + "              !socialRunning,\n"
                    + "              !safetyRunning\n"
                    + "        else { return false }"
            )
        )
    }

    func testAndroidFallbackReleasesDeadlineBeforeWorkerRetryAndAuthClearsState()
        throws
    {
        let source = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudScheduler.kt"
        )
        XCTAssertTrue(source.contains("scope = failure.scope"))
        XCTAssertTrue(source.contains("return aggregateOutcome"))
        XCTAssertTrue(source.contains("scopedRetryEnqueueTransition("))
        XCTAssertTrue(source.contains("retryStore.clear(failure.scope)"))
        XCTAssertTrue(source.contains("RetryEnqueueOutcome.WORKER_RETRY"))
        XCTAssertTrue(
            source.contains(
                "if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {\n"
                    + "            ManagedCloudRetryStore(applicationContext).clearAll()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "if (!service.shouldSchedule()) {\n"
                    + "            ManagedCloudRetryStore(applicationContext).clearAll()"
            )
        )
        XCTAssertTrue(source.contains("\"enqueue_outcome\""))
    }
}
