import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RemoteSyncConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, timeout: TimeInterval = 60) throws {
        guard baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw RemoteSyncError.invalidURLComponents
        }
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isPrivateHost(baseURL.host)) else {
            throw RemoteSyncError.insecureURL
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteSyncError.missingAPIKey
        }
        guard timeout > 0 else { throw RemoteSyncError.invalidTimeout }
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
    }

    /// Cleartext HTTP is allowed only for loopback/private-LAN development. Public servers must use TLS.
    public static func isPrivateHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let octets = withUnsafeBytes(of: &ipv4) { Array($0) }
            return octets[0] == 10 ||
                octets[0] == 127 ||
                (octets[0] == 169 && octets[1] == 254) ||
                (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 172 && (16...31).contains(octets[1]))
        }

        // A prefix check alone would classify a hostname such as `fcevil.com` as private.
        // Require a syntactically valid IPv6 literal, then inspect its actual bytes.
        let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let uniqueLocal = bytes[0] == 0xfc || bytes[0] == 0xfd
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        return loopback || uniqueLocal || linkLocal
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
            return (scheme, host, port)
        }
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left == right
    }
}

public enum RemoteSyncError: Error, Equatable, LocalizedError {
    case insecureURL
    case invalidURLComponents
    case missingAPIKey
    case invalidTimeout
    case invalidResponse
    case server(status: Int, message: String)
    case encoding(String)
    case decoding(String)
    case batchMismatch
    case unexpectedAcknowledgementStatus(String)
    case invalidDerivedWindow

    public var errorDescription: String? {
        switch self {
        case .insecureURL:
            return "Use HTTPS, or HTTP only for localhost/private-LAN servers."
        case .invalidURLComponents:
            return "The server URL cannot contain credentials, a query, or a fragment."
        case .missingAPIKey:
            return "The server API key is required."
        case .invalidTimeout:
            return "The request timeout must be greater than zero."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .server(let status, let message):
            return "Server error \(status): \(message)"
        case .encoding(let message):
            return "Could not encode the sync batch: \(message)"
        case .decoding(let message):
            return "Could not read the server response: \(message)"
        case .batchMismatch:
            return "The server acknowledged a different sync batch."
        case .unexpectedAcknowledgementStatus(let status):
            return "The server did not accept the sync batch (status: \(status))."
        case .invalidDerivedWindow:
            return "The saved derived-history replay window is invalid."
        }
    }
}

public protocol RemoteSyncUploading: Sendable {
    func upload(_ envelope: RemoteSyncEnvelope) async throws -> RemoteSyncResponse
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) { self.origin = origin }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              RemoteSyncConfiguration.isSameOrigin(origin, target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public actor RemoteSyncClient: RemoteSyncUploading {
    private let configuration: RemoteSyncConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: RemoteSyncConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            // Test/embedding seam. Production callers omit this and receive the hardened session below.
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.urlCredentialStorage = nil
            self.session = URLSession(
                configuration: sessionConfiguration,
                delegate: SameOriginRedirectDelegate(origin: configuration.baseURL),
                delegateQueue: nil
            )
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func health() async throws -> RemoteHealthResponse {
        let request = request(path: "healthz", method: "GET", authenticated: false)
        let data = try await perform(request)
        do {
            return try decoder.decode(RemoteHealthResponse.self, from: data)
        } catch {
            throw RemoteSyncError.decoding(error.localizedDescription)
        }
    }

    /// Authenticated readiness probe used by the settings screen. Unlike `/healthz`, this proves
    /// both that the server is reachable and that the pasted API key is accepted.
    public func authenticatedStatus() async throws -> RemoteHealthResponse {
        let request = request(path: "v1/status", method: "GET", authenticated: true)
        let data = try await perform(request)
        do {
            return try decoder.decode(RemoteHealthResponse.self, from: data)
        } catch {
            throw RemoteSyncError.decoding(error.localizedDescription)
        }
    }

    public func upload(_ envelope: RemoteSyncEnvelope) async throws -> RemoteSyncResponse {
        let request = try makeUploadRequest(envelope)
        let data = try await perform(request)
        return try decode(RemoteSyncResponse.self, from: data)
    }

    // MARK: - Private social sharing

    /// Create the first social profile with the configured self-hosted-server administrator token.
    ///
    /// Callers may explicitly supply a different authorization for administrative tooling, but the
    /// normal app path uses the `.admin` default and stores the returned member token separately.
    public func bootstrapFriendProfile(
        _ profile: RemoteFriendProfileCreate,
        authorization: RemoteSocialAuthorization = .admin
    ) async throws -> RemoteFriendBootstrapResponse {
        let request = try socialJSONRequest(
            path: "v1/social/bootstrap",
            method: "POST",
            authorization: authorization,
            body: profile
        )
        return try decode(
            RemoteFriendBootstrapResponse.self,
            from: try await perform(request)
        )
    }

    public func friendProfile(
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendProfileResponse {
        let request = try socialRequest(
            path: "v1/social/me",
            method: "GET",
            authorization: authorization
        )
        return try decode(
            RemoteFriendProfileResponse.self,
            from: try await perform(request)
        )
    }

    /// Permanently delete the authenticated member's social profile and associated social data.
    ///
    /// The explicit confirmation header is intentionally fixed to the server's destructive-action
    /// contract. The server invalidates the member credential as part of the successful deletion.
    public func deleteFriendProfile(
        authorization: RemoteSocialAuthorization
    ) async throws {
        var request = try socialRequest(
            path: "v1/social/me",
            method: "DELETE",
            authorization: authorization
        )
        request.setValue(
            "DELETE MY SOCIAL PROFILE",
            forHTTPHeaderField: "X-Noop-Confirm"
        )
        _ = try await perform(request)
    }

    public func createFriendInvite(
        _ invite: RemoteFriendInviteCreate = RemoteFriendInviteCreate(),
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendInviteResponse {
        let request = try socialJSONRequest(
            path: "v1/social/invites",
            method: "POST",
            authorization: authorization,
            body: invite
        )
        return try decode(
            RemoteFriendInviteResponse.self,
            from: try await perform(request)
        )
    }

    public func revokeFriendInvite(
        _ inviteId: UUID,
        authorization: RemoteSocialAuthorization
    ) async throws {
        let request = try socialRequest(
            path: "v1/social/invites/\(inviteId.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
        _ = try await perform(request)
    }

    /// Join a circle when this installation has no social profile yet.
    ///
    /// The one-time invite code is the capability, so this route intentionally sends no bearer
    /// credential. Callers must persist and reuse the request's client-generated enrollment ID and
    /// member token before retrying; the response intentionally never echoes the plaintext token.
    public func joinFriendInvite(
        _ join: RemoteFriendInviteJoin
    ) async throws -> RemoteFriendInviteJoinResponse {
        var request = request(
            path: "v1/social/invites/join",
            method: "POST",
            authenticated: false
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(join)
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
        return try decode(
            RemoteFriendInviteJoinResponse.self,
            from: try await perform(request)
        )
    }

    public func redeemFriendInvite(
        code: String,
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendRequestResponse {
        let request = try socialJSONRequest(
            path: "v1/social/invites/redeem",
            method: "POST",
            authorization: authorization,
            body: RemoteFriendInviteRedeem(code: code)
        )
        return try decode(
            RemoteFriendRequestResponse.self,
            from: try await perform(request)
        )
    }

    public func friendRequests(
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendRequestsResponse {
        let request = try socialRequest(
            path: "v1/social/requests",
            method: "GET",
            authorization: authorization
        )
        return try decode(
            RemoteFriendRequestsResponse.self,
            from: try await perform(request)
        )
    }

    public func decideFriendRequest(
        _ requestId: UUID,
        decision: RemoteFriendDecision,
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendRequestResponse {
        let request = try socialJSONRequest(
            path: "v1/social/requests/\(requestId.uuidString.lowercased())",
            method: "POST",
            authorization: authorization,
            body: RemoteFriendRequestDecision(decision: decision)
        )
        return try decode(
            RemoteFriendRequestResponse.self,
            from: try await perform(request)
        )
    }

    public func friends(
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendsResponse {
        let request = try socialRequest(
            path: "v1/social/friends",
            method: "GET",
            authorization: authorization
        )
        return try decode(RemoteFriendsResponse.self, from: try await perform(request))
    }

    public func updateFriendPrivacy(
        _ friendId: UUID,
        changes: RemoteFriendVisibilityPatch,
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendPrivacyResponse {
        let request = try socialJSONRequest(
            path: "v1/social/friends/\(friendId.uuidString.lowercased())/privacy",
            method: "PATCH",
            authorization: authorization,
            body: changes
        )
        return try decode(
            RemoteFriendPrivacyResponse.self,
            from: try await perform(request)
        )
    }

    public func removeFriend(
        _ friendId: UUID,
        authorization: RemoteSocialAuthorization
    ) async throws {
        let request = try socialRequest(
            path: "v1/social/friends/\(friendId.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
        _ = try await perform(request)
    }

    public func blockFriend(
        _ profileId: UUID,
        authorization: RemoteSocialAuthorization
    ) async throws {
        let request = try socialRequest(
            path: "v1/social/blocks/\(profileId.uuidString.lowercased())",
            method: "POST",
            authorization: authorization
        )
        _ = try await perform(request)
    }

    public func unblockFriend(
        _ profileId: UUID,
        authorization: RemoteSocialAuthorization
    ) async throws {
        let request = try socialRequest(
            path: "v1/social/blocks/\(profileId.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
        _ = try await perform(request)
    }

    public func friendFeed(
        startDay: String? = nil,
        endDay: String? = nil,
        authorization: RemoteSocialAuthorization
    ) async throws -> RemoteFriendFeedResponse {
        var query: [URLQueryItem] = []
        if let startDay { query.append(URLQueryItem(name: "start", value: startDay)) }
        if let endDay { query.append(URLQueryItem(name: "end", value: endDay)) }
        let request = try socialRequest(
            path: "v1/social/feed",
            method: "GET",
            authorization: authorization,
            queryItems: query
        )
        return try decode(
            RemoteFriendFeedResponse.self,
            from: try await perform(request)
        )
    }

    // MARK: - Emergency contacts and manual paging

    public func bootstrapSafetyProfile(
        _ profile: RemoteSafetyProfileBootstrap
    ) async throws -> RemoteSafetyBootstrapResponse {
        let request = try safetyJSONRequest(
            path: "v1/safety/bootstrap",
            method: "POST",
            authorization: .admin,
            body: profile
        )
        return try decode(
            RemoteSafetyBootstrapResponse.self,
            from: try await perform(request)
        )
    }

    public func safetyContacts(
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyContactsResponse {
        let request = try safetyRequest(
            path: "v1/safety/contacts",
            method: "GET",
            authorization: authorization
        )
        return try decode(
            RemoteSafetyContactsResponse.self,
            from: try await perform(request)
        )
    }

    public func addSafetyContact(
        _ contact: RemoteSafetyContactCreate,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyContactResponse {
        let request = try safetyJSONRequest(
            path: "v1/safety/contacts",
            method: "POST",
            authorization: authorization,
            body: contact
        )
        return try decode(
            RemoteSafetyContactResponse.self,
            from: try await perform(request)
        )
    }

    public func resendSafetyContactInvitation(
        _ contactId: UUID,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyContactResponse {
        let request = try safetyJSONRequest(
            path: "v1/safety/contacts/\(contactId.uuidString.lowercased())/resend",
            method: "POST",
            authorization: authorization,
            body: EmptyRemoteBody()
        )
        return try decode(
            RemoteSafetyContactResponse.self,
            from: try await perform(request)
        )
    }

    public func removeSafetyContact(
        _ contactId: UUID,
        authorization: RemoteSafetyAuthorization
    ) async throws {
        let request = try safetyRequest(
            path: "v1/safety/contacts/\(contactId.uuidString.lowercased())",
            method: "DELETE",
            authorization: authorization
        )
        _ = try await perform(request)
    }

    public func sendManualSafetyPage(
        idempotencyKey: UUID,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyDispatch {
        var request = try safetyJSONRequest(
            path: "v1/safety/incidents",
            method: "POST",
            authorization: authorization,
            body: RemoteSafetyPageCreate()
        )
        request.setValue(
            idempotencyKey.uuidString.lowercased(),
            forHTTPHeaderField: "Idempotency-Key"
        )
        return try decode(
            RemoteSafetyDispatch.self,
            from: try await perform(request)
        )
    }

    public func safetyIncidents(
        limit: Int = 20,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyIncidentList {
        let request = try safetyRequest(
            path: "v1/safety/incidents",
            method: "GET",
            authorization: authorization,
            queryItems: [
                URLQueryItem(
                    name: "limit",
                    value: String(min(max(limit, 1), 100))
                ),
            ]
        )
        return try decode(
            RemoteSafetyIncidentList.self,
            from: try await perform(request)
        )
    }

    public func safetyIncident(
        _ dispatchId: UUID,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyDispatch {
        let request = try safetyRequest(
            path: "v1/safety/incidents/\(dispatchId.uuidString.lowercased())",
            method: "GET",
            authorization: authorization
        )
        return try decode(
            RemoteSafetyDispatch.self,
            from: try await perform(request)
        )
    }

    public func updateSafetyIncidentLocation(
        _ dispatchId: UUID,
        update: RemoteSafetyLocationUpdate,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyLocationResponse {
        let request = try safetyJSONRequest(
            path: (
                "v1/safety/incidents/"
                + "\(dispatchId.uuidString.lowercased())/location"
            ),
            method: "PUT",
            authorization: authorization,
            body: update
        )
        return try decode(
            RemoteSafetyLocationResponse.self,
            from: try await perform(request)
        )
    }

    public func resolveSafetyIncident(
        _ dispatchId: UUID,
        note: String? = nil,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyDispatch {
        try await transitionSafetyIncident(
            dispatchId,
            action: "resolve",
            note: note,
            authorization: authorization
        )
    }

    public func cancelSafetyIncident(
        _ dispatchId: UUID,
        note: String? = nil,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyDispatch {
        try await transitionSafetyIncident(
            dispatchId,
            action: "cancel",
            note: note,
            authorization: authorization
        )
    }

    /// Kept internal so tests can inspect the exact request before URLSession
    /// canonicalizes its body into an implementation-specific stream.
    func makeUploadRequest(_ envelope: RemoteSyncEnvelope) throws -> URLRequest {
        var request = request(path: "v1/sync", method: "POST", authenticated: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(envelope.batchId.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        do {
            request.httpBody = try encoder.encode(envelope)
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
        return request
    }

    private func request(
        path: String,
        method: String,
        authenticated: Bool,
        bearerToken: String? = nil,
        queryItems: [URLQueryItem] = []
    ) -> URLRequest {
        var url = configuration.baseURL.appendingPathComponent(path)
        if !queryItems.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Noop/remote-sync-v1", forHTTPHeaderField: "User-Agent")
        if authenticated {
            request.setValue(
                "Bearer \(bearerToken ?? configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func socialRequest(
        path: String,
        method: String,
        authorization: RemoteSocialAuthorization,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        request(
            path: path,
            method: method,
            authenticated: true,
            bearerToken: try bearerToken(for: authorization),
            queryItems: queryItems
        )
    }

    private func socialJSONRequest<Body: Encodable>(
        path: String,
        method: String,
        authorization: RemoteSocialAuthorization,
        body: Body
    ) throws -> URLRequest {
        var request = try socialRequest(
            path: path,
            method: method,
            authorization: authorization
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
        return request
    }

    private func safetyRequest(
        path: String,
        method: String,
        authorization: RemoteSafetyAuthorization,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let bearer: String
        switch authorization {
        case .admin:
            bearer = configuration.apiKey
        case .safety(let token):
            bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bearer.isEmpty else { throw RemoteSyncError.missingAPIKey }
        }
        return request(
            path: path,
            method: method,
            authenticated: true,
            bearerToken: bearer,
            queryItems: queryItems
        )
    }

    private func safetyJSONRequest<Body: Encodable>(
        path: String,
        method: String,
        authorization: RemoteSafetyAuthorization,
        body: Body
    ) throws -> URLRequest {
        var request = try safetyRequest(
            path: path,
            method: method,
            authorization: authorization
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
        return request
    }

    private func transitionSafetyIncident(
        _ dispatchId: UUID,
        action: String,
        note: String?,
        authorization: RemoteSafetyAuthorization
    ) async throws -> RemoteSafetyDispatch {
        let request = try safetyJSONRequest(
            path: "v1/safety/incidents/\(dispatchId.uuidString.lowercased())/\(action)",
            method: "POST",
            authorization: authorization,
            body: RemoteSafetyIncidentTransition(note: note)
        )
        return try decode(
            RemoteSafetyDispatch.self,
            from: try await perform(request)
        )
    }

    private func bearerToken(for authorization: RemoteSocialAuthorization) throws -> String {
        switch authorization {
        case .admin:
            return configuration.apiKey
        case .member(let token):
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw RemoteSyncError.missingAPIKey }
            return trimmed
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RemoteSyncError.decoding(error.localizedDescription)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            if http.statusCode == 401 || http.statusCode == 403 {
                message = "authentication failed"
            } else {
                var safe = Self.safeServerMessage(data)
                // Redact both credential classes. Social requests can carry a member token instead
                // of the configured administrator key; redacting only the latter would let a
                // reflected member credential escape through a 4xx/5xx detail string.
                let requestBearer = request.value(forHTTPHeaderField: "Authorization")
                    .flatMap(Self.bearerValue)
                let secrets = [configuration.apiKey, requestBearer].compactMap { $0 }
                    + Self.secretBodyValues(in: request)
                for secret in Set(secrets)
                where !secret.isEmpty {
                    safe = safe.replacingOccurrences(of: secret, with: "[REDACTED]")
                }
                message = safe
            }
            throw RemoteSyncError.server(status: http.statusCode, message: message)
        }
        return data
    }

    private static func bearerValue(_ header: String) -> String? {
        let prefix = "Bearer "
        guard header.count > prefix.count,
              header.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }
        return String(header.dropFirst(prefix.count))
    }

    private static func secretBodyValues(in request: URLRequest) -> [String] {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return []
        }
        // Join enrollment sends its client-generated member credential in the body. Treat it with
        // the same reflection protection as bearer credentials even though the server never
        // intentionally returns it.
        return ["member_token", "safety_token"].compactMap { object[$0] as? String }
    }

    private static func safeServerMessage(_ data: Data) -> String {
        guard !data.isEmpty else { return "request failed" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String {
            return String(detail.prefix(300))
        }
        return String(String(decoding: data.prefix(300), as: UTF8.self))
    }
}

private struct EmptyRemoteBody: Encodable {}
