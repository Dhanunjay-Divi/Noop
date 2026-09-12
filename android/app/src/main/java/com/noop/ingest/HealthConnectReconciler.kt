package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.ChangesTokenRequest
import com.noop.data.HealthConnectSyncStateRow
import com.noop.data.ImportSummary
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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

internal interface HealthConnectBmiProjectionStateStore {
    suspend fun loadFingerprint(): String?
    suspend fun reconcileLocalProjection(heightCm: Double): Int
    suspend fun commitProjectionAndFingerprint(
        heightCm: Double,
        fingerprint: String,
        updatedAtMs: Long,
    ): Int
}

/**
 * Durable dependency token for Health Connect's derived BMI projection.
 *
 * Health Connect supplies weight but no BMI record, so the projection is valid only for the exact
 * confirmed profile height used to derive it. ProfileStore persists height as Float; fingerprinting
 * those exact bits avoids locale/format drift while still distinguishing confirmation, correction,
 * and removal. The value stays local in the existing sync-state table.
 */
internal object HealthConnectBmiProjectionFingerprint {
    const val STATE_RECORD_TYPE = "noop.internal.health-connect.bmi-height-fingerprint.v1"
    const val UNCONFIRMED = "v1:unconfirmed"

    val weightRecordType: String =
        HealthConnectImporter.recordTypeKey(WeightRecord::class)

    fun forHeight(heightCm: Double): String {
        if (!heightCm.isFinite() || heightCm <= 0.0) return UNCONFIRMED
        val bits = heightCm.toFloat().toRawBits().toUInt().toString(16).padStart(8, '0')
        return "v1:confirmed:$bits"
    }
}

/**
 * Couples the provider Weight cursor to the local profile input used for BMI derivation.
 *
 * A mismatch first rebuilds local derived BMI from already stored Health Connect weight rows. With no
 * Weight permission, that replacement and the fingerprint commit are atomic. With Weight permission, the
 * old fingerprint remains durable until the forced complete-history provider bootstrap succeeds, then a
 * final local projection and fingerprint commit are atomic. Failure or cancellation therefore retries.
 */
internal class HealthConnectBmiProjectionCoordinator(
    private val stateStore: HealthConnectBmiProjectionStateStore,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    suspend fun reconcile(
        recordTypes: Set<String>,
        heightCm: Double,
        runReconcile: suspend (forceBootstrapRecordTypes: Set<String>) -> HealthConnectReconcileResult,
    ): HealthConnectReconcileResult {
        val weightRecordType = HealthConnectBmiProjectionFingerprint.weightRecordType
        val desiredFingerprint = HealthConnectBmiProjectionFingerprint.forHeight(heightCm)
        val appliedFingerprint = try {
            stateStore.loadFingerprint()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return HealthConnectReconcileResult.RetryableFailure(
                "Health Connect BMI projection state could not be read",
            )
        }
        val forceBootstrap = appliedFingerprint != desiredFingerprint
        val forceWeightBootstrap = forceBootstrap && weightRecordType in recordTypes
        if (forceWeightBootstrap) {
            try {
                stateStore.reconcileLocalProjection(heightCm)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return HealthConnectReconcileResult.RetryableFailure(
                    "Health Connect BMI projection state could not be applied",
                )
            }

            val result = runReconcile(setOf(weightRecordType))
            if (result !is HealthConnectReconcileResult.Success) return result
            try {
                stateStore.commitProjectionAndFingerprint(
                    heightCm = heightCm,
                    fingerprint = desiredFingerprint,
                    updatedAtMs = nowMs(),
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return HealthConnectReconcileResult.RetryableFailure(
                    "Health Connect BMI projection state could not be committed",
                )
            }
            return result
        }

        if (forceBootstrap) {
            try {
                stateStore.commitProjectionAndFingerprint(
                    heightCm = heightCm,
                    fingerprint = desiredFingerprint,
                    updatedAtMs = nowMs(),
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return HealthConnectReconcileResult.RetryableFailure(
                    "Health Connect BMI projection state could not be applied",
                )
            }
        }

        return runReconcile(emptySet())
    }
}

/**
 * Process-wide gate for foreground and WorkManager reconciliation. The current profile height is read only
 * after the caller owns the lock, so a queued run cannot replay a stale height captured before a newer run.
 */
internal class HealthConnectReconciliationGate {
    private val mutex = Mutex()

    suspend fun <T> run(
        currentHeightCm: () -> Double,
        block: suspend (heightCm: Double) -> T,
    ): T = mutex.withLock {
        currentCoroutineContext().ensureActive()
        block(currentHeightCm())
    }
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
    suspend fun reconcile(
        recordTypes: Set<String>,
        forceBootstrapRecordTypes: Set<String> = emptySet(),
    ): HealthConnectReconcileResult {
        if (recordTypes.isEmpty()) {
            return HealthConnectReconcileResult.Success(false, 0, 0, 0)
        }
        return try {
            val stored = tokenStore.load(recordTypes)
            val forcedBootstrap = forceBootstrapRecordTypes.intersect(recordTypes)
            val next = LinkedHashMap<String, String>()
            var requiresRebuild = false
            var requiresFullHistory = false
            val affectedRecordTypes = linkedSetOf<String>()
            var bootstrapped = 0
            var upsertions = 0
            var deletions = 0

            for (recordType in recordTypes.sorted()) {
                // A derived-projection dependency changed. Treat only that record type as missing for
                // this run; do not delete its durable cursor unless the complete rebuild succeeds.
                val initial = stored[recordType].takeUnless { recordType in forcedBootstrap }
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
        } catch (cancelled: CancellationException) {
            throw cancelled
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

private class RoomHealthConnectBmiProjectionStateStore(
    private val repository: WhoopRepository,
) : HealthConnectBmiProjectionStateStore {
    override suspend fun loadFingerprint(): String? =
        repository.healthConnectSyncStates(
            listOf(HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE),
        ).firstOrNull()?.changesToken

    override suspend fun reconcileLocalProjection(heightCm: Double): Int =
        reconcileProjection(heightCm = heightCm, fingerprint = null)

    override suspend fun commitProjectionAndFingerprint(
        heightCm: Double,
        fingerprint: String,
        updatedAtMs: Long,
    ): Int = reconcileProjection(
        heightCm = heightCm,
        fingerprint = HealthConnectSyncStateRow(
            HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE,
            fingerprint,
            updatedAtMs,
        ),
    )

    private suspend fun reconcileProjection(
        heightCm: Double,
        fingerprint: HealthConnectSyncStateRow?,
    ): Int = repository.reconcileHealthConnectDerivedBmi(fingerprint) { weight ->
        HealthConnectImporter.derivedBmi(weight.value, heightCm)?.let { bmi ->
            MetricSeriesRow(
                deviceId = WhoopRepository.HEALTH_CONNECT_SOURCE,
                day = weight.day,
                key = "bmi",
                value = bmi,
            )
        }
    }
}

internal object HealthConnectReconciler {
    private val reconciliationGate = HealthConnectReconciliationGate()

    /**
     * Reconcile only the local BMI dependency projection. This does not access the provider and is
     * therefore safe when Health Connect or Weight permission is unavailable. It shares the same gate
     * as foreground and worker imports so profile changes cannot race a provider rebuild.
     */
    suspend fun reconcileLocalBmiProjection(
        repository: WhoopRepository,
        currentHeightCm: () -> Double,
    ): HealthConnectReconcileResult = reconciliationGate.run(currentHeightCm) { heightCm ->
        HealthConnectBmiProjectionCoordinator(
            stateStore = RoomHealthConnectBmiProjectionStateStore(repository),
        ).reconcile(
            recordTypes = emptySet(),
            heightCm = heightCm,
        ) {
            HealthConnectReconcileResult.Success(
                rebuilt = false,
                bootstrappedTypes = 0,
                upsertions = 0,
                deletions = 0,
            )
        }
    }

    /**
     * Manual/onboarding Health Connect import. Every UI entry point uses this gate so the profile height
     * is read after serialization and a queued stale value cannot overwrite a newer BMI projection.
     */
    suspend fun importNow(
        context: Context,
        repository: WhoopRepository,
        currentHeightCm: () -> Double,
    ): ImportSummary = reconciliationGate.run(currentHeightCm) importGate@ { heightCm ->
        val grantedPermissions = try {
            HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return@importGate ImportSummary.failure(
                HealthConnectImporter.SOURCE,
                "Could not read Health Connect permissions",
            )
        }
        val keys = HealthConnectImporter.grantedRecordTypes(grantedPermissions)
            .mapTo(linkedSetOf(), HealthConnectImporter::recordTypeKey)
        var summary: ImportSummary? = null
        val result = HealthConnectBmiProjectionCoordinator(
            stateStore = RoomHealthConnectBmiProjectionStateStore(repository),
        ).reconcile(
            recordTypes = keys,
            heightCm = heightCm,
        ) {
            val imported = HealthConnectImporter.import(
                context = context,
                repo = repository,
                heightCm = heightCm,
            )
            summary = imported
            if (imported.succeeded) {
                HealthConnectReconcileResult.Success(
                    rebuilt = true,
                    bootstrappedTypes = 0,
                    upsertions = 0,
                    deletions = 0,
                )
            } else {
                HealthConnectReconcileResult.RetryableFailure(imported.message)
            }
        }
        when (result) {
            is HealthConnectReconcileResult.Success ->
                summary ?: ImportSummary.failure(
                    HealthConnectImporter.SOURCE,
                    "Health Connect import did not run",
                )
            is HealthConnectReconcileResult.RetryableFailure ->
                summary?.takeUnless { it.succeeded }
                    ?: ImportSummary.failure(HealthConnectImporter.SOURCE, result.reason)
        }
    }

    suspend fun reconcile(
        context: Context,
        repository: WhoopRepository,
        grantedPermissions: Set<String>,
        currentHeightCm: () -> Double,
    ): HealthConnectReconcileResult = reconciliationGate.run(currentHeightCm) { heightCm ->
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
        HealthConnectBmiProjectionCoordinator(
            stateStore = RoomHealthConnectBmiProjectionStateStore(repository),
        ).reconcile(
            recordTypes = keys,
            heightCm = heightCm,
        ) { forceBootstrapRecordTypes ->
            engine.reconcile(
                recordTypes = keys,
                forceBootstrapRecordTypes = forceBootstrapRecordTypes,
            )
        }
    }
}
