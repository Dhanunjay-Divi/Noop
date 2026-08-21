import Foundation

/// Pure, ActivityKit-free selection used when more than one NOOP Live Activity survives a relaunch.
/// ActivityKit does not document the order of `Activity.activities`, so callers provide the best
/// available recency stamp (NOOP's advancing `staleDate`) and this helper picks deterministically.
struct LiveActivitySelection: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let id: String
        let freshnessDate: Date?
    }

    let canonicalID: String?
    let duplicateIDs: [String]

    static func select(_ candidates: [Candidate]) -> LiveActivitySelection {
        guard let canonical = candidates.max(by: isOlder) else {
            return LiveActivitySelection(canonicalID: nil, duplicateIDs: [])
        }
        return LiveActivitySelection(
            canonicalID: canonical.id,
            duplicateIDs: candidates.lazy.filter { $0.id != canonical.id }.map(\.id)
        )
    }

    private static func isOlder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsDate = lhs.freshnessDate ?? .distantPast
        let rhsDate = rhs.freshnessDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        // A stable tie-break makes the choice independent of ActivityKit's undocumented array order.
        return lhs.id < rhs.id
    }
}
