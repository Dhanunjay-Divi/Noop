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
        var request = request(path: "v1/sync", method: "POST", authenticated: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(envelope.batchId.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        do {
            request.httpBody = try encoder.encode(envelope)
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
        let data = try await perform(request)
        do {
            return try decoder.decode(RemoteSyncResponse.self, from: data)
        } catch {
            throw RemoteSyncError.decoding(error.localizedDescription)
        }
    }

    private func request(path: String, method: String, authenticated: Bool) -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Noop/remote-sync-v1", forHTTPHeaderField: "User-Agent")
        if authenticated {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
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
                message = Self.safeServerMessage(data).replacingOccurrences(
                    of: configuration.apiKey,
                    with: "[REDACTED]"
                )
            }
            throw RemoteSyncError.server(status: http.statusCode, message: message)
        }
        return data
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
