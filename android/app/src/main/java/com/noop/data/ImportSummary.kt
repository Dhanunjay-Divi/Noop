package com.noop.data

/**
 * Result of importing an external data source (WHOOP export, Apple Health export, or
 * Health Connect) into the local Room store. Returned by every importer so the UI can
 * show one consistent "imported N days / M workouts" toast.
 */
data class ImportSummary(
    /** Human label of the source: "WHOOP", "Apple Health", "Health Connect". */
    val source: String,
    /** Rows actually upserted, keyed by table name (e.g. "dailyMetric" -> 1200). */
    val counts: Map<String, Int>,
    /** Earliest day touched, "YYYY-MM-DD" (null if nothing imported). */
    val firstDay: String? = null,
    /** Latest day touched, "YYYY-MM-DD". */
    val lastDay: String? = null,
    /** One-line human summary for a Toast / status line. */
    val message: String,
    /** Distinguishes a valid zero-row import from a read/save failure. */
    val succeeded: Boolean = true,
    /** Health Connect record types actually attempted (ungranted types are not attempted). */
    val recordTypesAttempted: Int = 0,
    /** Attempted Health Connect record types whose complete paginated read succeeded. */
    val recordTypesSucceeded: Int = 0,
    /** Attempted Health Connect record types whose read failed. Partial rows are never counted here. */
    val recordTypesFailed: Int = 0,
) {
    val totalRows: Int get() = counts.values.sum()

    companion object {
        /** A failed import carrying a reason. */
        fun failure(
            source: String,
            reason: String,
            recordTypesAttempted: Int = 0,
            recordTypesSucceeded: Int = 0,
            recordTypesFailed: Int = 0,
        ) = ImportSummary(
            source = source,
            counts = emptyMap(),
            message = reason,
            succeeded = false,
            recordTypesAttempted = recordTypesAttempted,
            recordTypesSucceeded = recordTypesSucceeded,
            recordTypesFailed = recordTypesFailed,
        )
    }
}

/** A coroutine completing normally is not enough: importers return explicit failure summaries. */
internal fun importCompletedSuccessfully(result: Result<ImportSummary>): Boolean =
    result.getOrNull()?.succeeded == true
