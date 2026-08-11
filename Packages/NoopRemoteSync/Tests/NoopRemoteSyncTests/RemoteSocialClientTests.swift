import XCTest
@testable import NoopRemoteSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RemoteSocialClientTests: XCTestCase {
    private let profileId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let friendId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let inviteId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let requestId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let enrollmentId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    override func tearDown() {
        SocialURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testBootstrapUsesAdminBearerEncodesSnakeCaseAndDecodesCredential() async throws {
        let client = try makeClient()
        SocialURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/bootstrap")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer admin-secret"
            )
            let body = try Self.jsonBody(request)
            XCTAssertEqual(body["display_name"] as? String, "Avery")
            XCTAssertEqual(body["installation_id"] as? String, "install-1")
            XCTAssertEqual(
                body["daily_device_id"] as? String,
                "ios:install-1:my-whoop-noop"
            )
            return Self.response(
                request,
                status: 201,
                json: """
                {
                  "profile": {
                    "profile_id": "\(self.profileId.uuidString)",
                    "enrollment_id": "\(self.enrollmentId.uuidString)",
                    "display_name": "Avery",
                    "installation_id": "install-1",
                    "daily_device_id": "ios:install-1:my-whoop-noop",
                    "created_at": "2026-07-25T10:00:00Z",
                    "updated_at": "2026-07-25T10:00:00Z",
                    "disabled_at": null
                  },
                  "member_token": "noop_member_first",
                  "token_notice": "Store this token securely."
                }
                """
            )
        }

        let response = try await client.bootstrapFriendProfile(
            RemoteFriendProfileCreate(
                displayName: "Avery",
                installationId: "install-1",
                dailyDeviceId: "ios:install-1:my-whoop-noop"
            )
        )

        XCTAssertEqual(response.profile.profileId, profileId)
        XCTAssertEqual(response.profile.enrollmentId, enrollmentId)
        XCTAssertEqual(response.memberToken, "noop_member_first")
    }

    func testInviteCreateRedeemAndRevokeUseMemberBearerAndExactRoutes() async throws {
        let client = try makeClient()
        var call = 0
        SocialURLProtocolStub.handler = { request in
            defer { call += 1 }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer noop_member_alice"
            )
            switch call {
            case 0:
                XCTAssertEqual(request.url?.path, "/v1/social/invites")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(try Self.jsonBody(request)["expires_in_hours"] as? Int, 48)
                return Self.response(
                    request,
                    status: 201,
                    json: """
                    {
                      "invite": {
                        "invite_id": "\(self.inviteId.uuidString)",
                        "inviter_id": "\(self.profileId.uuidString)",
                        "created_at": "2026-07-25T10:00:00Z",
                        "expires_at": "2026-07-27T10:00:00Z",
                        "redeemed_at": null,
                        "redeemed_by": null,
                        "revoked_at": null
                      },
                      "code": "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX",
                      "code_notice": "One time."
                    }
                    """
                )
            case 1:
                XCTAssertEqual(request.url?.path, "/v1/social/invites/redeem")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    try Self.jsonBody(request)["code"] as? String,
                    "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX"
                )
                return Self.response(
                    request,
                    status: 201,
                    json: """
                    {
                      "request": {
                        "request_id": "\(self.requestId.uuidString)",
                        "invite_id": "\(self.inviteId.uuidString)",
                        "inviter_id": "\(self.profileId.uuidString)",
                        "requester_id": "\(self.friendId.uuidString)",
                        "status": "pending",
                        "created_at": "2026-07-25T10:02:00Z",
                        "decided_at": null,
                        "recipient": {
                          "profile_id": "\(self.profileId.uuidString)",
                          "display_name": "Avery"
                        }
                      }
                    }
                    """
                )
            default:
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/social/invites/\(self.inviteId.uuidString.lowercased())"
                )
                XCTAssertEqual(request.httpMethod, "DELETE")
                return Self.response(request, status: 204)
            }
        }

        let authorization = RemoteSocialAuthorization.member(token: "noop_member_alice")
        let invite = try await client.createFriendInvite(
            RemoteFriendInviteCreate(expiresInHours: 48),
            authorization: authorization
        )
        XCTAssertEqual(invite.invite.inviteId, inviteId)
        let request = try await client.redeemFriendInvite(
            code: invite.code,
            authorization: authorization
        )
        XCTAssertEqual(request.request.recipient?.displayName, "Avery")
        try await client.revokeFriendInvite(inviteId, authorization: authorization)
        XCTAssertEqual(call, 3)
    }

    func testFirstTimeInviteJoinSendsRetryCredentialsWithoutBearerAndDecodesReceipt() async throws {
        let client = try makeClient()
        let memberToken = "noop_member_abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
        SocialURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/invites/join")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.jsonBody(request)
            XCTAssertEqual(body["code"] as? String, "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX")
            XCTAssertEqual(body["display_name"] as? String, "Morgan")
            XCTAssertEqual(body["installation_id"] as? String, "install-2")
            XCTAssertEqual(
                body["daily_device_id"] as? String,
                "ios:install-2:my-whoop-noop"
            )
            XCTAssertEqual(
                body["enrollment_id"] as? String,
                self.enrollmentId.uuidString
            )
            XCTAssertEqual(body["member_token"] as? String, memberToken)
            return Self.response(
                request,
                status: 201,
                json: """
                {
                  "profile": {
                    "profile_id": "\(self.friendId.uuidString)",
                    "enrollment_id": "\(self.enrollmentId.uuidString)",
                    "display_name": "Morgan",
                    "installation_id": "install-2",
                    "daily_device_id": "ios:install-2:my-whoop-noop",
                    "created_at": "2026-07-25T10:02:00Z",
                    "updated_at": "2026-07-25T10:02:00Z",
                    "disabled_at": null
                  },
                  "request": {
                    "request_id": "\(self.requestId.uuidString)",
                    "status": "pending",
                    "created_at": "2026-07-25T10:02:00Z",
                    "decided_at": null,
                    "recipient": {"display_name": "Avery"}
                  },
                  "idempotent_replay": false,
                  "token_notice": "The server never returns the submitted member token."
                }
                """
            )
        }

        let response = try await client.joinFriendInvite(
            RemoteFriendInviteJoin(
                code: "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX",
                displayName: "Morgan",
                installationId: "install-2",
                dailyDeviceId: "ios:install-2:my-whoop-noop",
                enrollmentId: enrollmentId,
                memberToken: memberToken
            )
        )
        XCTAssertEqual(response.profile.profileId, friendId)
        XCTAssertEqual(response.profile.enrollmentId, enrollmentId)
        XCTAssertFalse(response.idempotentReplay)
        XCTAssertEqual(response.request.status, .pending)
        XCTAssertEqual(response.request.recipient.displayName, "Avery")
    }

    func testRetrySafeInviteJoinDecodesIdempotentReplayWithoutEchoedToken() async throws {
        let client = try makeClient()
        let memberToken = "noop_member_abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
        SocialURLProtocolStub.handler = { request in
            let body = try Self.jsonBody(request)
            XCTAssertEqual(body["member_token"] as? String, memberToken)
            XCTAssertEqual(body["enrollment_id"] as? String, self.enrollmentId.uuidString)
            return Self.response(
                request,
                status: 201,
                json: """
                {
                  "profile": {
                    "profile_id": "\(self.friendId.uuidString)",
                    "enrollment_id": "\(self.enrollmentId.uuidString)",
                    "display_name": "Morgan",
                    "installation_id": "install-2",
                    "daily_device_id": "ios:install-2:my-whoop-noop",
                    "created_at": "2026-07-25T10:02:00Z",
                    "updated_at": "2026-07-25T10:02:00Z",
                    "disabled_at": null
                  },
                  "request": {
                    "request_id": "\(self.requestId.uuidString)",
                    "status": "pending",
                    "created_at": "2026-07-25T10:02:00Z",
                    "decided_at": null,
                    "recipient": {"display_name": "Avery"}
                  },
                  "idempotent_replay": true,
                  "token_notice": "The server never returns the submitted member token."
                }
                """
            )
        }

        let response = try await client.joinFriendInvite(
            RemoteFriendInviteJoin(
                code: "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX",
                displayName: "Morgan",
                installationId: "install-2",
                dailyDeviceId: "ios:install-2:my-whoop-noop",
                enrollmentId: enrollmentId,
                memberToken: memberToken
            )
        )

        XCTAssertTrue(response.idempotentReplay)
        XCTAssertEqual(response.profile.enrollmentId, enrollmentId)
    }

    func testDeleteFriendProfileUsesMemberBearerExactConfirmationAndAcceptsNoContent() async throws {
        let client = try makeClient()
        SocialURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/social/me")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer noop_member_owner"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Confirm"),
                "DELETE MY SOCIAL PROFILE"
            )
            XCTAssertNil(request.httpBody)
            return Self.response(request, status: 204)
        }

        try await client.deleteFriendProfile(
            authorization: .member(token: "noop_member_owner")
        )
    }

    func testRequestsListAndDecisionDecodeTheirDistinctShapes() async throws {
        let client = try makeClient()
        var call = 0
        SocialURLProtocolStub.handler = { request in
            defer { call += 1 }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer noop_member_owner"
            )
            if call == 0 {
                XCTAssertEqual(request.url?.path, "/v1/social/requests")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(
                    request,
                    json: """
                    {
                      "requests": [{
                        "request_id": "\(self.requestId.uuidString)",
                        "invite_id": "\(self.inviteId.uuidString)",
                        "inviter_id": "\(self.profileId.uuidString)",
                        "requester_id": "\(self.friendId.uuidString)",
                        "status": "pending",
                        "created_at": "2026-07-25T10:02:00Z",
                        "decided_at": null,
                        "direction": "incoming",
                        "profile": {
                          "profile_id": "\(self.friendId.uuidString)",
                          "display_name": "Morgan"
                        }
                      }]
                    }
                    """
                )
            }
            XCTAssertEqual(
                request.url?.path,
                "/v1/social/requests/\(self.requestId.uuidString.lowercased())"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try Self.jsonBody(request)["decision"] as? String, "accept")
            return Self.response(
                request,
                json: """
                {
                  "request": {
                    "request_id": "\(self.requestId.uuidString)",
                    "invite_id": "\(self.inviteId.uuidString)",
                    "inviter_id": "\(self.profileId.uuidString)",
                    "requester_id": "\(self.friendId.uuidString)",
                    "status": "accepted",
                    "created_at": "2026-07-25T10:02:00Z",
                    "decided_at": "2026-07-25T10:03:00Z"
                  }
                }
                """
            )
        }

        let authorization = RemoteSocialAuthorization.member(token: "noop_member_owner")
        let listed = try await client.friendRequests(authorization: authorization)
        XCTAssertEqual(listed.requests.first?.direction, .incoming)
        XCTAssertEqual(listed.requests.first?.profile?.displayName, "Morgan")
        let decided = try await client.decideFriendRequest(
            requestId,
            decision: .accept,
            authorization: authorization
        )
        XCTAssertEqual(decided.request.status, .accepted)
        XCTAssertNil(decided.request.direction)
    }

    func testFriendsPrivacyPatchAndRemovalUseServerEnforcedVisibilityContract() async throws {
        let client = try makeClient()
        var call = 0
        SocialURLProtocolStub.handler = { request in
            defer { call += 1 }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer noop_member_owner"
            )
            switch call {
            case 0:
                XCTAssertEqual(request.url?.path, "/v1/social/friends")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(
                    request,
                    json: """
                    {
                      "friends": [{
                        "profile_id": "\(self.friendId.uuidString)",
                        "display_name": "Morgan",
                        "friends_since": "2026-07-25T10:03:00Z",
                        "sharing": {
                          "charge": true, "effort": true, "rest": true,
                          "sleep_duration": false, "hrv": false, "rhr": false
                        },
                        "shared_with_me": {
                          "charge": true, "effort": false, "rest": true,
                          "sleep_duration": true, "hrv": false, "rhr": false
                        }
                      }]
                    }
                    """
                )
            case 1:
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/social/friends/\(self.friendId.uuidString.lowercased())/privacy"
                )
                XCTAssertEqual(request.httpMethod, "PATCH")
                let body = try Self.jsonBody(request)
                XCTAssertEqual(body.count, 2)
                XCTAssertEqual(body["hrv"] as? Bool, true)
                XCTAssertEqual(body["sleep_duration"] as? Bool, false)
                XCTAssertNil(body["charge"])
                return Self.response(
                    request,
                    json: """
                    {
                      "friend_id": "\(self.friendId.uuidString)",
                      "sharing": {
                        "charge": true, "effort": true, "rest": true,
                        "sleep_duration": false, "hrv": true, "rhr": false
                      },
                      "privacy": "Applied by the server."
                    }
                    """
                )
            default:
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/social/friends/\(self.friendId.uuidString.lowercased())"
                )
                XCTAssertEqual(request.httpMethod, "DELETE")
                return Self.response(request, status: 204)
            }
        }

        let authorization = RemoteSocialAuthorization.member(token: "noop_member_owner")
        let listed = try await client.friends(authorization: authorization)
        XCTAssertEqual(listed.friends.first?.sharedWithMe.sleepDuration, true)
        let updated = try await client.updateFriendPrivacy(
            friendId,
            changes: RemoteFriendVisibilityPatch(sleepDuration: false, hrv: true),
            authorization: authorization
        )
        XCTAssertTrue(updated.sharing.hrv)
        try await client.removeFriend(friendId, authorization: authorization)
        XCTAssertEqual(call, 3)
    }

    func testBlocksAndFeedUseExactMethodsQueryAndSparseSummaryDecoding() async throws {
        let client = try makeClient()
        var call = 0
        SocialURLProtocolStub.handler = { request in
            defer { call += 1 }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer noop_member_owner"
            )
            if call < 2 {
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/social/blocks/\(self.friendId.uuidString.lowercased())"
                )
                XCTAssertEqual(request.httpMethod, call == 0 ? "POST" : "DELETE")
                return Self.response(request, status: 204)
            }

            XCTAssertEqual(request.url?.path, "/v1/social/feed")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = try XCTUnwrap(
                URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems
            )
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }),
                ["start": "2026-07-20", "end": "2026-07-25"]
            )
            return Self.response(
                request,
                json: """
                {
                  "start": "2026-07-20",
                  "end": "2026-07-25",
                  "days": [{
                    "profile_id": "\(self.friendId.uuidString)",
                    "display_name": "Morgan",
                    "day": "2026-07-24",
                    "summary": {"charge": 78, "effort": 42, "rest": 84}
                  }],
                  "units": {
                    "charge": "score_0_to_100",
                    "effort": "score_0_to_100",
                    "rest": "score_0_to_100",
                    "sleep_duration": "minutes",
                    "hrv": "milliseconds",
                    "rhr": "beats_per_minute"
                  },
                  "privacy": "Only enabled fields."
                }
                """
            )
        }

        let authorization = RemoteSocialAuthorization.member(token: "noop_member_owner")
        try await client.blockFriend(friendId, authorization: authorization)
        try await client.unblockFriend(friendId, authorization: authorization)
        let feed = try await client.friendFeed(
            startDay: "2026-07-20",
            endDay: "2026-07-25",
            authorization: authorization
        )
        XCTAssertEqual(feed.days.first?.summary.rest, 84)
        XCTAssertNil(feed.days.first?.summary.hrv)
        XCTAssertEqual(feed.units.rest, "score_0_to_100")
    }

    func testMemberCredentialIsRedactedFromNonAuthServerErrors() async throws {
        let client = try makeClient()
        let memberToken = "noop_member_do-not-leak"
        SocialURLProtocolStub.handler = { request in
            Self.response(
                request,
                status: 409,
                json: #"{"detail":"reflected noop_member_do-not-leak from request"}"#
            )
        }

        do {
            _ = try await client.friendProfile(
                authorization: .member(token: memberToken)
            )
            XCTFail("Expected a server error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(memberToken))
            XCTAssertTrue(error.localizedDescription.contains("[REDACTED]"))
        }
    }

    func testJoinBodyCredentialIsRedactedFromServerErrors() async throws {
        let client = try makeClient()
        let memberToken = "noop_member_abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
        SocialURLProtocolStub.handler = { request in
            Self.response(
                request,
                status: 409,
                json: #"{"detail":"reflected noop_member_abcdefghijklmnopqrstuvwxyzABCDEFGH123456789 from request"}"#
            )
        }

        do {
            _ = try await client.joinFriendInvite(
                RemoteFriendInviteJoin(
                    code: "NOOP-ABCDEF-GHIJKL-MNOPQR-STUVWX",
                    displayName: "Morgan",
                    installationId: "install-2",
                    dailyDeviceId: "ios:install-2:my-whoop-noop",
                    enrollmentId: enrollmentId,
                    memberToken: memberToken
                )
            )
            XCTFail("Expected a server error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(memberToken))
            XCTAssertTrue(error.localizedDescription.contains("[REDACTED]"))
        }
    }

    func testBlankMemberCredentialIsRejectedBeforeNetwork() async throws {
        let client = try makeClient()
        SocialURLProtocolStub.handler = { request in
            XCTFail("Blank member token should not make a request")
            return Self.response(request)
        }

        do {
            _ = try await client.friends(authorization: .member(token: " \n "))
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? RemoteSyncError, .missingAPIKey)
        }
    }

    private func makeClient() throws -> RemoteSyncClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SocialURLProtocolStub.self]
        return RemoteSyncClient(
            configuration: try RemoteSyncConfiguration(
                baseURL: XCTUnwrap(URL(string: "https://noop.example")),
                apiKey: "admin-secret"
            ),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var output = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                output.append(buffer, count: count)
            }
            data = output
        } else {
            throw URLError(.cannotDecodeRawData)
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        json: String = ""
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: json.isEmpty ? nil : ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }
}

private final class SocialURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
