// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class OuraOAuthTests: XCTestCase {
    private let creds = OuraCredentials(clientId: "cid", redirectURI: "noop://oura/callback")

    func testAuthorizeURLHasRequiredParams() throws {
        let url = OuraOAuth.authorizeURL(credentials: creds, state: "xyz")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "cloud.ouraring.com")
        XCTAssertEqual(comps.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(q["response_type"], "token")
        XCTAssertEqual(q["client_id"], "cid")
        XCTAssertEqual(q["redirect_uri"], "noop://oura/callback")
        XCTAssertEqual(q["state"], "xyz")
        XCTAssertEqual(q["scope"], OuraOAuth.scopes.joined(separator: " "))
        XCTAssertTrue(OuraOAuth.scopes.contains("daily"))
        XCTAssertTrue(OuraOAuth.scopes.contains("heartrate"))
        XCTAssertTrue(OuraOAuth.scopes.contains("spo2"))
        XCTAssertFalse(OuraOAuth.scopes.contains("spo2Daily"))
    }

    func testCallbackFragmentValidatesStateAndComputesExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let url = try XCTUnwrap(URL(string:
            "noop://oura/callback#access_token=acc&token_type=bearer&expires_in=86400&state=xyz"))
        let tokens = try OuraOAuth.parseCallback(url, expectedState: "xyz", now: now)
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(86400))
    }

    func testCallbackQueryDefaultsExpiryWhenExpiresInAbsent() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let url = try XCTUnwrap(URL(string: "noop://oura/callback?access_token=acc&state=xyz"))
        let tokens = try OuraOAuth.parseCallback(url, expectedState: "xyz", now: now)
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2_592_000))
    }

    func testCallbackRejectsMissingTokenStateMismatchAndDuplicates() throws {
        XCTAssertThrowsError(try OuraOAuth.parseCallback(
            XCTUnwrap(URL(string: "noop://oura/callback?error=access_denied&state=xyz")),
            expectedState: "xyz", now: Date()))
        XCTAssertThrowsError(try OuraOAuth.parseCallback(
            XCTUnwrap(URL(string: "noop://oura/callback#access_token=acc&state=wrong")),
            expectedState: "xyz", now: Date()))
        XCTAssertThrowsError(try OuraOAuth.parseCallback(
            XCTUnwrap(URL(string: "noop://oura/callback?state=xyz#access_token=a&access_token=b")),
            expectedState: "xyz", now: Date()))
    }

    func testNoConfidentialSecretOrTokenExchangeExistsInPublicClientFlow() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Strand/Oura/OuraOAuth.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("client_secret"))
        XCTAssertFalse(source.contains("oauth/token"))
    }
}
#endif // OURA_CLOUD_IMPORT
