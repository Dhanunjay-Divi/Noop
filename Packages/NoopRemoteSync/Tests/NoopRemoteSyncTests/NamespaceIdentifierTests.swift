import XCTest
@testable import NoopRemoteSync

final class NamespaceIdentifierTests: XCTestCase {
    func testScopedIdentifiersSeparatePlatformInstallationAndRevision() {
        let base = RemoteNamespaceIdentifier.scoped(
            platform: "ios",
            installationId: "install-a",
            logicalSourceId: "my-whoop-noop",
            revisionToken: "revision-1"
        )
        let otherPlatform = RemoteNamespaceIdentifier.scoped(
            platform: "macos",
            installationId: "install-a",
            logicalSourceId: "my-whoop-noop",
            revisionToken: "revision-1"
        )
        let otherInstall = RemoteNamespaceIdentifier.scoped(
            platform: "ios",
            installationId: "install-b",
            logicalSourceId: "my-whoop-noop",
            revisionToken: "revision-1"
        )
        let otherRevision = RemoteNamespaceIdentifier.scoped(
            platform: "ios",
            installationId: "install-a",
            logicalSourceId: "my-whoop-noop",
            revisionToken: "revision-2"
        )

        XCTAssertEqual(Set([base, otherPlatform, otherInstall, otherRevision]).count, 4)
        XCTAssertTrue(base.hasPrefix("ios:install-a:"))
    }

    func testLongOrUnicodeLogicalIdentifierUsesBoundedAllowedFallback() {
        let identifier = RemoteNamespaceIdentifier.scoped(
            platform: "ios",
            installationId: String(repeating: "installation-", count: 20),
            logicalSourceId: String(repeating: "strap 🪿 / ", count: 80)
        )

        XCTAssertLessThanOrEqual(identifier.utf8.count, 128)
        XCTAssertNotNil(
            identifier.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
                options: .regularExpression
            )
        )
    }

    func testRevisionTokenIsDeterministicAndOrderSensitive() {
        XCTAssertEqual(
            RemoteNamespaceIdentifier.revisionToken(["charge-v1", "effort-v1", "rest-v1"]),
            RemoteNamespaceIdentifier.revisionToken(["charge-v1", "effort-v1", "rest-v1"])
        )
        XCTAssertNotEqual(
            RemoteNamespaceIdentifier.revisionToken(["charge-v1", "effort-v1", "rest-v1"]),
            RemoteNamespaceIdentifier.revisionToken(["charge-v2", "effort-v1", "rest-v1"])
        )
    }

    func testReplayWindowAndCursorRoundTripWithCompletionMarker() throws {
        let window = RemoteDerivedWindow(
            fromTs: 100,
            toTs: 200,
            fromDay: "1970-01-01",
            toDay: "1970-01-02"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteDerivedWindow.self,
                from: JSONEncoder().encode(window)
            ),
            window
        )

        let cursor = RemoteDerivedCursor(
            sleepStartTs: 101,
            workoutStartTs: 102,
            workoutSport: "Run",
            journalDay: "1970-01-01",
            journalQuestion: "Caffeine?",
            dailySent: true
        ).markingComplete
        let decoded = try JSONDecoder().decode(
            RemoteDerivedCursor.self,
            from: JSONEncoder().encode(cursor)
        )
        XCTAssertEqual(decoded, cursor)
        XCTAssertTrue(decoded.isComplete)

        // Development builds that wrote OFFSET fields restart safely instead of failing decode.
        let legacy = Data(
            #"{"sleepOffset":5000,"workoutOffset":10,"journalOffset":3,"dailySent":true}"#.utf8
        )
        let migrated = try JSONDecoder().decode(RemoteDerivedCursor.self, from: legacy)
        XCTAssertNil(migrated.sleepStartTs)
        XCTAssertTrue(migrated.dailySent)
        XCTAssertFalse(migrated.isComplete)
    }
}
