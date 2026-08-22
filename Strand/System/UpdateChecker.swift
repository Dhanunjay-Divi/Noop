import Foundation
import WhoopProtocol

/// Resolves the update lane before any network work starts. Apple-distributed builds must stay on
/// Apple's update path; only a directly installed/private build may consult project releases.
enum UpdateDeliveryPolicy {
    enum Destination: Equatable {
        case privateReleases
        case appStore
        case testFlight
    }

    static func destination(
        for channel: TrialNoticePolicy.DistributionChannel
    ) -> Destination {
        switch channel {
        case .privatePreview: return .privateReleases
        case .appStore: return .appStore
        case .testFlight: return .testFlight
        }
    }
}

/// User-initiated update check for directly installed/private builds. App Store and TestFlight
/// builds short-circuit to an Apple-managed state before constructing a private-release request.
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, notes: String)
        case managedByApple
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(
        string: "https://api.github.com/repos/Dhanunjay-Divi/Noop/releases/latest"
    )!

    func check(
        currentVersion: String,
        channel: TrialNoticePolicy.DistributionChannel = TrialNoticePolicy.distributionChannel()
    ) {
        guard state != .checking else { return }

        guard UpdateDeliveryPolicy.destination(for: channel) == .privateReleases else {
            state = .managedByApple
            return
        }

        state = .checking
        Task {
            do {
                var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let urlString = json["html_url"] as? String,
                      let url = URL(string: urlString) else {
                    state = .failed
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = Self.cleanNotes(json["body"] as? String ?? "")
                state = VersionCheck.isNewer(latest, than: currentVersion)
                    ? .available(version: latest, url: url, notes: notes)
                    : .upToDate(version: latest)
            } catch {
                state = .failed
            }
        }
    }

    /// Turn a GitHub release body into a short, readable "what's new" for an inline preview: drop the
    /// "Downloads"/footer boilerplate, strip the heaviest markdown markers, and cap the length.
    static func cleanNotes(_ body: String) -> String {
        var s = body.components(separatedBy: "Downloads").first ?? body
        for marker in ["**", "## ", "# "] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }
}
