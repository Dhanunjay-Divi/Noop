// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import AuthenticationServices

/// The auth seam. Today's concrete provider is `OuraOAuthProvider` (Oura client-side-only OAuth);
/// a future backend-mediated provider can replace it without touching the API client or the sync layer.
protocol AuthProvider {
    /// True when tokens are stored (connected), regardless of expiry.
    var isConnected: Bool { get }
    /// Return a currently-valid access token. A client-side token that expired requires reauthorization.
    func validAccessToken() async throws -> String
    /// Handle a token rejected server-side. Providers with no safe refresh grant clear it and require
    /// reauthorization; test or future backend providers may return a refreshed token.
    func refreshedAccessToken() async throws -> String
    /// Run the interactive authorization (opens Oura's consent page) and store the resulting tokens.
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws
    /// Forget the stored tokens (disconnect).
    func signOut()
}
#endif // OURA_CLOUD_IMPORT
