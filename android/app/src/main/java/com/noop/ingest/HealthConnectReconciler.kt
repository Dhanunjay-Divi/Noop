package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.request.ChangesTokenRequest
import com.noop.data.HealthConnectSyncStateRow
import com.noop.data.WhoopRepository

/** Provider-neutral page so the token state machine has deterministic plain-JVM tests. */
internal data class HealthConnectChangePage(
    val nextToken: String,
    val hasMore: Boolean,
    val tokenExpired: Boolean,
    val upsertions: Int = 0,
    val deletions: Int = 0,
    val upsertionsOutsideAutomaticWindow: Boolean = false,
)

internal interface HealthConnectChangeFeed {
    suspend fun createToken(recordType: String): String
    suspend fun changes(token: String): HealthConnectChangePage
}

internal interface HealthConnectTokenStore {
    suspend fun load(recordTypes: Set<String>): Map<String, String>
    suspend fun save(tokens: Map<String, String>, updatedAtMs: Long)
}

/**
 * Scope required to make the local Health Connect projection match the provider before committing
 * the drained change tokens. Health Connect deletion events identify a record and its type, but do
 * not expose the deleted record's timestamp. Such a deletion therefore requires the importer's full
 * supported history window. A recent-only rebuild is safe only when every upserted record is known
 * to overlap that recent window.
 */
internal data class HealthConnectRebuildRequest(
    val affectedRecordTypes: Set<String>,
    val horizon: Horizon,
) {
    enum class Horizon {
        AUTOMATIC_WINDOW,
        FULL_SUPPORTED_HISTORY,
    }

    /** Null is the importer's explicit full supported-history mode. */
    val lookbackDays: Long?
        get() = when (horizon) {
            Horizon.AUTOMATIC_WINDOW -> HealthConnectImporter.AUTOMATIC_LOOKBACK_DAYS
            Horizon.FULL_SUPPORTED_HISTORY -> null
        }
}

internal sealed interface HealthConnectReconcileResult {
    data class Success(
        val rebuilt: Boolean,
        val bootstrappedTypes: Int,
        val upsertions: Int,
        val deletions: Int,
    ) : HealthConnectReconcileResult

    data class RetryableFailure(val reason: String) : HealthConnectReconcileResult
}

/**
 * Transaction boundary for Health Connect changes.
 *
 * Tokens are drained per record type (so a deletion's otherwise-untyped record id still has type
 * context), but never persisted until the local projection rebuild succeeds. A crash or retry thus
 * replays pages instead of losing a deletion. The provider's deletion id cannot be mapped exactly to
 * NOOP's aggregate rows. Recent upsertions trigger one bounded source-scoped rebuild; historical
 * upsertions, deletions, initial baselines, and expired cursors trigger a full supported-history
 * source-scoped rebuild because a bounded replacement cannot make those cases complete.
 */
internal class HealthConnectChangeEngine(
    private val feed: HealthConnectChangeFeed,
    private val tokenStore: HealthConnectTokenStore,
    private val rebuild: suspend (HealthConnectRebuildRequest) -> Boolean,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val maxPagesPerType: Int = 10_000,
) {
    suspend fun reconcile(recordTypes: Set<String>): HealthConnectReconcileResult {
        if (recordTypes.isEmpty()) {
            return HealthConnectReconcileResult.Success(false, 0, 0, 0)
        }
        return try {
            val stored = tokenStore.load(recordTypes)
            val next = LinkedHashMap<String, String>()
            var requiresRebuild = false
            var requiresFullHistory = false
            val affectedRecordTypes = linkedSetOf<String>()
            var bootstrapped = 0
            var upsertions = 0
            var deletions = 0

            for (recordType in recordTypes.sorted()) {
                val initial = stored[recordType]
                if (initial == null) {
                    val fresh = feed.createToken(recordType)
                    if (fresh.isBlank()) return HealthConnectReconcileResult.RetryableFailure(
                        "Health Connect returned an empty initial token for $recordType",
                    )
                    next[recordType] = fresh
                    requiresRebuild = true
                    requiresFullHistory = true
                    affectedRecordTypes += recordType
                    bootstrapped += 1
                    continue
                }

                var token: String = requireNotNull(initial)
                var pages = 0
                while (true) {
                    pages += 1
                    if (pages > maxPagesPerType) {
                        return HealthConnectReconcileResult.RetryableFailure(
                            "Health Connect change paging exceeded $maxPagesPerType pages for $recordType",
                        )
                    }
                    val page = feed.changes(token)
                    if (page.tokenExpired) {
                        // A fresh token is acquired BEFORE the rebuild. Changes racing the rebuild stay
                        // after this cursor and are replayed next run; the token is not saved yet.
                        val fresh = feed.createToken(recordType)
                        if (fresh.isBlank()) return HealthConnectReconcileResult.RetryableFailure(
                            "Health Connect returned an empty replacement token for $recordType",
                        )
                        next[recordType] = fresh
                        requiresRebuild = true
                        requiresFullHistory = true
                        affectedRecordTypes += recordType
                        break
                    }

                    upsertions += page.upsertions
                    deletions += page.deletions
                    if (page.upsertions > 0 || page.deletions > 0) {
                        requiresRebuild = true
                        affectedRecordTypes += recordType
                    }
                    // DeletionChange carries no original timestamp. It may refer to a row older than
                    // AUTOMATIC_LOOKBACK_DAYS, so advancing the token after a bounded rebuild would
                    // permanently strand that stale local row.
                    if (page.deletions > 0) requiresFullHistory = true
                    // UpsertionChange does include the record, so the Android adapter can retain the
                    // efficient fast path when (and only when) its timestamp overlaps that window.
                    if (page.upsertionsOutsideAutomaticWindow) requiresFullHistory = true

                    if (page.nextToken.isBlank() || (page.hasMore && page.nextToken == token)) {
                        return HealthConnectReconcileResult.RetryableFailure(
                            "Health Connect returned a non-advancing change token for $recordType",
                        )
                    }
                    token = page.nextToken
                    if (!page.hasMore) {
                        next[recordType] = token
                        break
                    }
                }
            }

            if (requiresRebuild) {
                val request = HealthConnectRebuildRequest(
                    affectedRecordTypes = affectedRecordTypes.toSet(),
                    horizon = if (requiresFullHistory) {
                        HealthConnectRebuildRequest.Horizon.FULL_SUPPORTED_HISTORY
                    } else {
                        HealthConnectRebuildRequest.Horizon.AUTOMATIC_WINDOW
                    },
                )
                if (!rebuild(request)) {
                    return HealthConnectReconcileResult.RetryableFailure(
                        "Health Connect projection rebuild did not complete",
                    )
                }
            }
            tokenStore.save(next, nowMs())
            HealthConnectReconcileResult.Success(
                rebuilt = requiresRebuild,
                bootstrappedTypes = bootstrapped,
                upsertions = upsertions,
                deletions = deletions,
            )
        } catch (t: Throwable) {
            HealthConnectReconcileResult.RetryableFailure(
                t.message ?: t.javaClass.simpleName,
            )
        }
    }
}

/** Any unknown Record shape fails toward the complete-history path. */
internal fun healthConnectUpsertionIsOutsideWindow(
    record: Record,
    automaticWindowStart: java.time.Instant,
): Boolean {
    // Health Connect interval reads overlap the filter, so the importer returns each interval whose
    // end is at/after the boundary. Instant records return their time. Unknown shapes yield null and
    // fail toward a complete rebuild.
    return HealthConnectImporter.recordLastInstant(record)
        ?.isBefore(automaticWindowStart)
        ?: true
}

/** Android adapter around the pinned Health Connect 1.1 alpha change API. */
private class AndroidHealthConnectChangeFeed(
    private val client: HealthConnectClient,
    private val selfPackage: String,
    private val automaticWindowStart: java.time.Instant =
        HealthConnectImporter.automaticLookbackStart(),
) : HealthConnectChangeFeed {
    override suspend fun createToken(recordType: String): String {
        val type = requireNotNull(HealthConnectImporter.recordTypeForKey(recordType)) {
            "Unknown Health Connect record type $recordType"
        }
        return client.getChangesToken(ChangesTokenRequest(setOf(type)))
    }

    override suspend fun changes(token: String): HealthConnectChangePage {
        val response = client.getChanges(token)
        var upsertions = 0
        var deletions = 0
        var upsertionsOutsideAutomaticWindow = false
        for (change in response.changes) {
            when (change) {
                is DeletionChange -> deletions += 1
                is UpsertionChange -> if (!HealthConnectImporter.isSelfWritten(
                        change.record.metadata.dataOrigin.packageName,
                        selfPackage,
                    )
                ) {
                    upsertions += 1
                    if (healthConnectUpsertionIsOutsideWindow(change.record, automaticWindowStart)) {
                        upsertionsOutsideAutomaticWindow = true
                    }
                }
            }
        }
        return HealthConnectChangePage(
            nextToken = response.nextChangesToken,
            hasMore = response.hasMore,
            tokenExpired = response.changesTokenExpired,
            upsertions = upsertions,
            deletions = deletions,
            upsertionsOutsideAutomaticWindow = upsertionsOutsideAutomaticWindow,
        )
    }
}

private class RoomHealthConnectTokenStore(
    private val repository: WhoopRepository,
) : HealthConnectTokenStore {
    override suspend fun load(recordTypes: Set<String>): Map<String, String> =
        repository.healthConnectSyncStates(recordTypes.toList())
            .associate { it.recordType to it.changesToken }

    override suspend fun save(tokens: Map<String, String>, updatedAtMs: Long) {
        repository.upsertHealthConnectSyncStates(tokens.map { (recordType, token) ->
            HealthConnectSyncStateRow(recordType, token, updatedAtMs)
        })
    }
}

internal object HealthConnectReconciler {
    suspend fun reconcile(
        context: Context,
        repository: WhoopRepository,
        grantedPermissions: Set<String>,
        heightCm: Double,
    ): HealthConnectReconcileResult {
        val recordTypes = HealthConnectImporter.grantedRecordTypes(grantedPermissions)
        val keys = recordTypes.mapTo(linkedSetOf(), HealthConnectImporter::recordTypeKey)
        val engine = HealthConnectChangeEngine(
            feed = AndroidHealthConnectChangeFeed(HealthConnectImporter.client(context), context.packageName),
            tokenStore = RoomHealthConnectTokenStore(repository),
            rebuild = { request ->
                HealthConnectImporter.import(
                    context = context,
                    repo = repository,
                    heightCm = heightCm,
                    // A null lookback selects the importer's documented 10-year supported history.
                    // Rebuild all currently granted HC-owned fields atomically: several projections
                    // (notably workout distance/energy/HR) depend on more than one record type.
                    lookbackDays = request.lookbackDays,
                    replaceOwnedProjection = true,
                ).succeeded
            },
        )
        return engine.reconcile(keys)
    }
}
