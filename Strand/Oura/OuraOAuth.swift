// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation

/// Pure pieces of Oura's documented client-side-only OAuth flow. It returns a short-lived bearer token
/// to the registered redirect and never embeds a confidential client secret in the distributable app.
enum OuraOAuth {
    static let authorizeEndpoint = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    // Explicit data-minimizing scope list. Do not omit `scope`: Oura treats a blank scope as "all
    // scopes configured on the app", which can silently grow when the developer portal adds new lanes.
    // Endpoints with newer portal-only scopes may be skipped by the coordinator until they get a
    // deliberate opt-in + scope addition.
    static let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2"]

    /// The consent URL to open in ASWebAuthenticationSession. `state` is a caller-generated nonce echoed
    /// back on redirect and verified, to defeat CSRF / stray callbacks.
    static func authorizeURL(credentials: OuraCredentials, state: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "token"),
            .init(name: "client_id", value: credentials.clientId),
            .init(name: "redirect_uri", value: credentials.redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Validate the state nonce and parse the OAuth callback. OAuth servers commonly return implicit
    /// tokens in the URL fragment; Oura examples have also used query parameters, so accept either but
    /// reject duplicate names rather than choosing an attacker-controlled ambiguity.
    static func parseCallback(_ callback: URL, expectedState: String, now: Date) throws -> OuraTokens {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw OuraError.authFailed("invalid callback")
        }
        var items = components.queryItems ?? []
        if let fragment = components.fragment,
           let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems {
            items.append(contentsOf: fragmentItems)
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil else {
                throw OuraError.authFailed("duplicate callback parameter")
            }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == expectedState else {
            throw OuraError.authFailed("state mismatch")
        }
        if let error = values["error"], !error.isEmpty {
            throw OuraError.authFailed(error)
        }
        guard let access = values["access_token"], !access.isEmpty else {
            throw OuraError.authFailed("no access token")
        }
        let seconds = values["expires_in"].flatMap(TimeInterval.init) ?? 2_592_000
        guard seconds > 0, seconds <= 31 * 86_400 else {
            throw OuraError.authFailed("invalid token lifetime")
        }
        return OuraTokens(
            accessToken: access,
            refreshToken: nil,
            expiresAt: now.addingTimeInterval(seconds)
        )
    }
}
#endif // OURA_CLOUD_IMPORT
