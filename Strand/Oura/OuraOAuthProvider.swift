// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import AuthenticationServices

/// Oura's documented client-side-only OAuth provider. It uses a public client id and receives a bearer
/// token through ASWebAuthenticationSession; no confidential secret is compiled into the app. Oura does
/// not issue refresh tokens for this flow, so expiry or a 401 requires an explicit reauthorization.
final class OuraOAuthProvider: NSObject, AuthProvider, ASWebAuthenticationPresentationContextProviding {
    private let credentials: OuraCredentials
    private var anchor: ASPresentationAnchor?

    init(credentials: OuraCredentials) {
        self.credentials = credentials
    }

    var isConnected: Bool { OuraTokenStore.isConnected }
    func signOut() { OuraTokenStore.clear() }

    func validAccessToken() async throws -> String {
        guard let tokens = OuraTokenStore.load() else { throw OuraError.notConnected }
        if !tokens.isExpired { return tokens.accessToken }
        OuraTokenStore.clear()
        throw OuraError.reauthorizationRequired
    }

    /// Unconditionally refresh, regardless of the stored token's expiry state.
    func refreshedAccessToken() async throws -> String {
        OuraTokenStore.clear()
        throw OuraError.reauthorizationRequired
    }

    @MainActor
    func authorize(presentationAnchor: ASPresentationAnchor) async throws {
        self.anchor = presentationAnchor
        let state = UUID().uuidString
        let url = OuraOAuth.authorizeURL(credentials: credentials, state: state)
        let scheme = URL(string: credentials.redirectURI)?.scheme

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: OuraError.authFailed(err?.localizedDescription ?? "cancelled")) }
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            if !webSession.start() { cont.resume(throwing: OuraError.authFailed("couldn't start web session")) }
        }

        let tokens = try OuraOAuth.parseCallback(callback, expectedState: state, now: Date())
        guard OuraTokenStore.save(tokens) else { throw OuraError.tokenExchangeFailed("keychain write failed") }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
#endif // OURA_CLOUD_IMPORT
