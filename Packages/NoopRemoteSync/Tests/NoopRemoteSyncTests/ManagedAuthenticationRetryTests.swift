import XCTest
@testable import NoopRemoteSync

final class ManagedAuthenticationRetryTests: XCTestCase {
    func testSuccessUsesCachedAuthorizationWithoutRefresh() async throws {
        let recorder = AuthenticationRetryRecorder()

        let result = try await ManagedAuthenticationRetry.run(
            authorization: { forceRefresh in
                await recorder.recordAuthorization(forceRefresh)
                return try Self.authorization(forceRefresh ? "fresh" : "cached")
            },
            operation: { authorization in
                await recorder.recordOperation(authorization.identityToken)
                return authorization.identityToken
            }
        )

        XCTAssertEqual(result, "cached")
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.authorizationRequests, [false])
        XCTAssertEqual(snapshot.operationTokens, ["cached"])
    }

    func testAuthenticationFailureRefreshesAndReplaysExactlyOnce() async throws {
        let recorder = AuthenticationRetryRecorder()

        let result = try await ManagedAuthenticationRetry.run(
            authorization: { forceRefresh in
                await recorder.recordAuthorization(forceRefresh)
                return try Self.authorization(forceRefresh ? "fresh" : "cached")
            },
            operation: { authorization in
                await recorder.recordOperation(authorization.identityToken)
                if authorization.identityToken == "cached" {
                    throw ManagedStorageError.authentication
                }
                return "completed"
            }
        )

        XCTAssertEqual(result, "completed")
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.authorizationRequests, [false, true])
        XCTAssertEqual(snapshot.operationTokens, ["cached", "fresh"])
    }

    func testSecondAuthenticationFailurePropagatesWithoutLooping() async throws {
        let recorder = AuthenticationRetryRecorder()

        do {
            _ = try await ManagedAuthenticationRetry.run(
                authorization: { forceRefresh in
                    await recorder.recordAuthorization(forceRefresh)
                    return try Self.authorization(forceRefresh ? "fresh" : "cached")
                },
                operation: { authorization in
                    await recorder.recordOperation(authorization.identityToken)
                    throw ManagedStorageError.authentication
                }
            ) as String
            XCTFail("A second authentication failure must propagate.")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .authentication)
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.authorizationRequests, [false, true])
        XCTAssertEqual(snapshot.operationTokens, ["cached", "fresh"])
    }

    func testNonAuthenticationFailureDoesNotRefreshOrReplay() async throws {
        let recorder = AuthenticationRetryRecorder()

        do {
            _ = try await ManagedAuthenticationRetry.run(
                authorization: { forceRefresh in
                    await recorder.recordAuthorization(forceRefresh)
                    return try Self.authorization(forceRefresh ? "fresh" : "cached")
                },
                operation: { authorization in
                    await recorder.recordOperation(authorization.identityToken)
                    throw ManagedStorageError.quotaExceeded
                }
            ) as String
            XCTFail("Quota failure must propagate.")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .quotaExceeded)
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.authorizationRequests, [false])
        XCTAssertEqual(snapshot.operationTokens, ["cached"])
    }

    private static func authorization(_ token: String) throws -> ManagedAuthorization {
        try ManagedAuthorization(
            identityToken: token,
            appCheckToken: "app-check-\(token)",
            installationID: "installation-1",
            installationToken: "noopm_" + String(repeating: "a", count: 43)
        )
    }
}

private actor AuthenticationRetryRecorder {
    private(set) var authorizationRequests: [Bool] = []
    private(set) var operationTokens: [String] = []

    func recordAuthorization(_ forceRefresh: Bool) {
        authorizationRequests.append(forceRefresh)
    }

    func recordOperation(_ token: String) {
        operationTokens.append(token)
    }

    func snapshot() -> (authorizationRequests: [Bool], operationTokens: [String]) {
        (authorizationRequests, operationTokens)
    }
}
