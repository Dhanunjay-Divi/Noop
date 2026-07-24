import XCTest
@testable import NoopRemoteSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RemoteSyncClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRejectsPublicCleartextServer() {
        XCTAssertThrowsError(
            try RemoteSyncConfiguration(
                baseURL: XCTUnwrap(URL(string: "http://example.com")),
                apiKey: "secret"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncError, .insecureURL)
        }
    }

    func testAcceptsPrivateLANCleartextServer() throws {
        let config = try RemoteSyncConfiguration(
            baseURL: XCTUnwrap(URL(string: "http://192.168.1.25:8770")),
            apiKey: "secret"
        )
        XCTAssertEqual(config.baseURL.host, "192.168.1.25")
        let linkLocal = try RemoteSyncConfiguration(
            baseURL: XCTUnwrap(URL(string: "http://169.254.23.4:8770")),
            apiKey: "secret"
        )
        XCTAssertEqual(linkLocal.baseURL.host, "169.254.23.4")
        XCTAssertTrue(RemoteSyncConfiguration.isPrivateHost("169.254.23.4"))
        XCTAssertFalse(RemoteSyncConfiguration.isPrivateHost("169.253.23.4"))
        XCTAssertFalse(RemoteSyncConfiguration.isPrivateHost("169.255.23.4"))
    }

    func testPublicHostnameCannotCollapseIntoPrivateIPv4() {
        for host in [
            "10.0.0.1.evil.example",
            "evil.10.0.0.1",
            "10.a.0.1",
            "192.168.1",
            "192.168.1.1.",
        ] {
            XCTAssertFalse(RemoteSyncConfiguration.isPrivateHost(host), host)
        }
    }

    func testHostnamePrefixCannotMasqueradeAsPrivateIPv6() {
        for host in ["fcevil.com", "fd-not-an-ip.example", "fe80:attacker.example"] {
            XCTAssertFalse(RemoteSyncConfiguration.isPrivateHost(host))
        }
        XCTAssertTrue(RemoteSyncConfiguration.isPrivateHost("fd00::25"))
        XCTAssertTrue(RemoteSyncConfiguration.isPrivateHost("fe80::1"))
    }

    func testRejectsCredentialsQueryAndFragmentInEndpoint() throws {
        for value in [
            "https://user:pass@example.com",
            "https://example.com?redirect=https://attacker.example",
            "https://example.com#secret",
        ] {
            XCTAssertThrowsError(
                try RemoteSyncConfiguration(
                    baseURL: XCTUnwrap(URL(string: value)),
                    apiKey: "secret"
                )
            ) { error in
                XCTAssertEqual(error as? RemoteSyncError, .invalidURLComponents)
            }
        }
    }

    func testRedirectPolicyAllowsOnlySameOrigin() throws {
        let base = try XCTUnwrap(URL(string: "https://noop.example:8443/base"))
        XCTAssertTrue(RemoteSyncConfiguration.isSameOrigin(
            base,
            try XCTUnwrap(URL(string: "https://noop.example:8443/v1/sync"))
        ))
        XCTAssertFalse(RemoteSyncConfiguration.isSameOrigin(
            base,
            try XCTUnwrap(URL(string: "https://attacker.example/v1/sync"))
        ))
        XCTAssertFalse(RemoteSyncConfiguration.isSameOrigin(
            base,
            try XCTUnwrap(URL(string: "http://noop.example:8443/v1/sync"))
        ))
        XCTAssertFalse(RemoteSyncConfiguration.isSameOrigin(
            base,
            try XCTUnwrap(URL(string: "https://noop.example/v1/sync"))
        ))
    }

    func testUploadUsesBearerAuthSnakeCaseAndIdempotencyKey() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: sessionConfig)
        let config = try RemoteSyncConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://noop.example")),
            apiKey: "top-secret"
        )
        let client = RemoteSyncClient(configuration: config, session: session)
        let batchId = UUID(uuidString: "72C97818-2BBF-4D2A-A4F8-8866CF889191")!
        let envelope = RemoteSyncEnvelope(
            batchId: batchId,
            source: RemoteSyncSource(deviceId: "strap-1", sentAt: "2026-07-24T12:00:00Z"),
            streams: RemoteStreams(hr: [RemoteSample(recordedAt: 1_700_000_000, value: 72)])
        )

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/sync")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Idempotency-Key"),
                batchId.uuidString.lowercased()
            )
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["schema_version"] as? Int, 1)
            let source = try XCTUnwrap(object["source"] as? [String: Any])
            XCTAssertEqual(source["device_id"] as? String, "strap-1")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {"batch_id":"72c97818-2bbf-4d2a-a4f8-8866cf889191","status":"accepted","counts":{"hr":1},"duplicate":false}
                """.utf8)
            )
        }

        let response = try await client.upload(envelope)
        XCTAssertEqual(response.batchId, batchId)
        XCTAssertEqual(response.counts["hr"], 1)
        XCTAssertFalse(response.duplicate)
    }

    func testServerErrorNeverIncludesAuthorizationValue() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: sessionConfig)
        let config = try RemoteSyncConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://noop.example")),
            apiKey: "do-not-leak"
        )
        let client = RemoteSyncClient(configuration: config, session: session)
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"detail":"reflected do-not-leak from request"}"#.utf8)
            )
        }

        do {
            _ = try await client.upload(
                RemoteSyncEnvelope(source: RemoteSyncSource(deviceId: "strap-1"))
            )
            XCTFail("Expected a server error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("do-not-leak"))
            XCTAssertTrue(error.localizedDescription.contains("authentication failed"))
        }
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
