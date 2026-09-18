package com.noop.analytics

import android.content.SharedPreferences

/** Upgrade boundary for Charge formula changes that do not create a raw-input dirty marker. */
internal object ChargeFormulaUpgradeGate {
    const val COMPLETED_REVISION_KEY = "noop.analysis.completedChargeFormulaRevision"
    const val HISTORY_DAYS = 4_000
    const val CURRENT_REVISION = NoopScoreAlgorithmRevision.CHARGE

    fun needsRescore(completedRevision: String?): Boolean =
        completedRevision != CURRENT_REVISION
}

/**
 * Upgrade boundary for Rest formula changes that do not create a raw-input dirty marker.
 *
 * Completion is written only after every resolvable historical day and required pass boundary
 * succeeds.
 */
internal object RestFormulaUpgradeGate {
    const val COMPLETED_REVISION_KEY = "noop.analysis.completedRestFormulaRevision"
    const val NEXT_ANCHOR_KEY = "noop.analysis.restFormulaNextAnchor"
    const val ANCHOR_REVISION_KEY = "noop.analysis.restFormulaAnchorRevision"
    const val HISTORY_DAYS = 4_000
    const val CURRENT_REVISION = NoopScoreAlgorithmRevision.REST
    val TRAVERSAL_REVISION =
        "${ChargeFormulaUpgradeGate.CURRENT_REVISION}|$CURRENT_REVISION"

    sealed interface Progress {
        data object Retry : Progress
        data class Advance(val nextAnchor: Long) : Progress
        data class Complete(val revision: String) : Progress
    }

    fun needsRescore(completedRevision: String?): Boolean =
        completedRevision != CURRENT_REVISION

    fun traversalAnchor(
        migrationRequired: Boolean,
        anchorRevision: String?,
        storedAnchor: Long?,
    ): Long? =
        storedAnchor?.takeIf {
            migrationRequired &&
                (
                    anchorRevision == TRAVERSAL_REVISION ||
                        anchorRevision == CURRENT_REVISION
                    ) &&
                it >= 0L
        }

    fun progress(
        passCompleted: Boolean,
        resolvableHistorySatisfied: Boolean,
        nextResolvableHistoryAnchor: Long?,
        wasRequired: Boolean,
        traversalWasSelected: Boolean,
    ): Progress {
        if (!passCompleted || !wasRequired || !traversalWasSelected) {
            return Progress.Retry
        }
        if (resolvableHistorySatisfied && nextResolvableHistoryAnchor == null) {
            return Progress.Complete(CURRENT_REVISION)
        }
        return nextResolvableHistoryAnchor
            ?.takeIf { it >= 0L }
            ?.let(Progress::Advance)
            ?: Progress.Retry
    }
}

/**
 * Fail-closed publication policy for locally computed derived metrics during formula migration.
 *
 * Raw, imported, journal, and official-reference namespaces remain publishable. Only the
 * `noop_computed` derived namespace waits until both current completion markers are durable.
 */
internal object FormulaPublicationGate {
    const val COMPUTED_SOURCE_KIND = "noop_computed"
    const val MANAGED_DERIVED_DATA_CLASS = "derived_summaries"
    val DEFERRED_DIAGNOSTIC_FIELDS = mapOf(
        "computed_derived" to "deferred",
        "reason" to "formula_migration",
    )

    fun computedDerivedReady(preferences: SharedPreferences): Boolean =
        computedDerivedReady(
            completedChargeRevision = preferences.getString(
                ChargeFormulaUpgradeGate.COMPLETED_REVISION_KEY,
                null,
            ),
            completedRestRevision = preferences.getString(
                RestFormulaUpgradeGate.COMPLETED_REVISION_KEY,
                null,
            ),
        )

    fun computedDerivedReady(
        completedChargeRevision: String?,
        completedRestRevision: String?,
    ): Boolean =
        completedChargeRevision == ChargeFormulaUpgradeGate.CURRENT_REVISION &&
            completedRestRevision == RestFormulaUpgradeGate.CURRENT_REVISION

    fun shouldPublishDerived(
        sourceKind: String,
        computedDerivedReady: Boolean,
    ): Boolean =
        sourceKind != COMPUTED_SOURCE_KIND || computedDerivedReady

    fun managedDataClasses(
        sourceKind: String,
        available: List<String>,
        computedDerivedReady: Boolean,
    ): List<String> =
        if (shouldPublishDerived(sourceKind, computedDerivedReady)) {
            available
        } else {
            available.filterNot { it == MANAGED_DERIVED_DATA_CLASS }
        }
}
