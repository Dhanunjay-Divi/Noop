import Foundation
import StrandAnalytics

/// Upgrade boundary for formula changes that do not alter raw-input fingerprints.
///
/// A revision string, rather than a one-shot boolean, makes every future Charge revision fail open
/// into a full-history rescore. Completion is persisted only after the analysis pass succeeds.
enum ChargeFormulaUpgradeGate {
    static let completedRevisionKey = "noop.analysis.completedChargeFormulaRevision"
    static let historyDays = 4_000
    static var currentRevision: String { NoopScoreAlgorithmRevision.charge }

    static func needsRescore(completedRevision: String?) -> Bool {
        completedRevision != currentRevision
    }

    static func revisionToPersist(passCompleted: Bool, wasRequired: Bool) -> String? {
        passCompleted && wasRequired ? currentRevision : nil
    }
}

/// Upgrade boundary for Rest formula changes that do not alter raw-input fingerprints.
///
/// Completion is persisted only after every resolvable historical day and required pass boundary
/// succeeds, so old and new Sleep Scores never share one current-revision publication label.
enum RestFormulaUpgradeGate {
    static let completedRevisionKey = "noop.analysis.completedRestFormulaRevision"
    static let nextAnchorKey = "noop.analysis.restFormulaNextAnchor"
    static let anchorRevisionKey = "noop.analysis.restFormulaAnchorRevision"
    static let historyDays = 4_000
    static var currentRevision: String { NoopScoreAlgorithmRevision.rest }
    static var traversalRevision: String {
        "\(ChargeFormulaUpgradeGate.currentRevision)|\(currentRevision)"
    }

    enum Progress: Equatable {
        case retry
        case advance(nextAnchor: Int)
        case complete(revision: String)
    }

    static func needsRescore(completedRevision: String?) -> Bool {
        completedRevision != currentRevision
    }

    static func traversalAnchor(
        migrationRequired: Bool,
        anchorRevision: String?,
        storedAnchor: Int?
    ) -> Int? {
        guard migrationRequired,
              anchorRevision == traversalRevision
                || anchorRevision == currentRevision,
              let storedAnchor,
              storedAnchor >= 0 else {
            return nil
        }
        return storedAnchor
    }

    static func progress(
        receipt: IntelligenceEngine.ScoreRunReceipt?,
        wasRequired: Bool,
        traversalWasSelected: Bool
    ) -> Progress {
        guard wasRequired,
              traversalWasSelected,
              let receipt,
              receipt.allRequiredBoundariesCompleted else {
            return .retry
        }
        if receipt.resolvableHistorySatisfied,
           receipt.nextResolvableHistoryAnchor == nil {
            return .complete(revision: currentRevision)
        }
        if let nextAnchor = receipt.nextResolvableHistoryAnchor,
           nextAnchor >= 0 {
            return .advance(nextAnchor: nextAnchor)
        }
        return .retry
    }
}

/// Fail-closed publication policy for locally computed derived metrics during formula migration.
///
/// Raw, imported, journal, and official-reference namespaces remain publishable. Only the
/// `noop_computed` derived namespace waits until both current migration markers are durable.
enum FormulaPublicationGate {
    static let computedSourceKind = "noop_computed"
    static let managedDerivedDataClass = "derived_summaries"
    static let deferredDiagnosticFields = [
        "computed_derived": "deferred",
        "reason": "formula_migration",
    ]

    static func computedDerivedReady(defaults: UserDefaults = .standard) -> Bool {
        computedDerivedReady(
            completedChargeRevision: defaults.string(
                forKey: ChargeFormulaUpgradeGate.completedRevisionKey
            ),
            completedRestRevision: defaults.string(
                forKey: RestFormulaUpgradeGate.completedRevisionKey
            )
        )
    }

    static func computedDerivedReady(
        completedChargeRevision: String?,
        completedRestRevision: String?
    ) -> Bool {
        completedChargeRevision == ChargeFormulaUpgradeGate.currentRevision
            && completedRestRevision == RestFormulaUpgradeGate.currentRevision
    }

    static func shouldPublishDerived(
        sourceKind: String,
        computedDerivedReady: Bool
    ) -> Bool {
        sourceKind != computedSourceKind || computedDerivedReady
    }

    static func shouldPublishSocialSummaries(
        computedDerivedReady: Bool
    ) -> Bool {
        computedDerivedReady
    }

    static func publishSocialSummariesIfReady<T>(
        computedDerivedReady: Bool,
        publish: () async throws -> T
    ) async rethrows -> T? {
        guard shouldPublishSocialSummaries(
            computedDerivedReady: computedDerivedReady
        ) else {
            return nil
        }
        return try await publish()
    }

    static func managedDataClasses(
        sourceKind: String,
        available: [String],
        computedDerivedReady: Bool
    ) -> [String] {
        guard !shouldPublishDerived(
            sourceKind: sourceKind,
            computedDerivedReady: computedDerivedReady
        ) else {
            return available
        }
        return available.filter { $0 != managedDerivedDataClass }
    }
}
