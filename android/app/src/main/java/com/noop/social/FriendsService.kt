package com.noop.social

import android.content.Context
import com.noop.BuildConfig
import com.noop.data.WhoopRepository
import com.noop.sync.RemoteEnvelope
import com.noop.sync.RemoteEnvelopeDraft
import com.noop.sync.RemoteNoopAlgorithmRevision
import com.noop.sync.RemoteSourceDraft
import com.noop.sync.RemoteSyncClient
import com.noop.sync.RemoteSyncConfiguration
import com.noop.sync.RemoteSyncException
import com.noop.sync.RemoteSyncJson
import com.noop.sync.RemoteSyncPrefs
import com.noop.sync.RemoteSyncService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.URI
import java.time.LocalDate

data class FriendsRefreshResult(
    val snapshot: FriendsSnapshot,
    val summaryUploaded: Boolean,
    val summaryRetryable: Boolean = false,
)

internal object FriendsAutomaticRefreshPolicy {
    const val INTERVAL_MS = 15L * 60L * 1_000L

    fun isDue(lastSuccessMs: Long, nowMs: Long): Boolean =
        lastSuccessMs <= 0L || nowMs - lastSuccessMs >= INTERVAL_MS
}

internal object FriendsRetryPolicy {
    fun isRetryableSummaryFailure(error: Throwable): Boolean = when (error) {
        is RemoteSyncException.Network -> true
        is RemoteSyncException.Server -> error.statusCode == 429 || error.statusCode >= 500
        else -> false
    }
}

/** Pure construction policy for the 31-day summary replacement window. */
internal object FriendsSummaryProjection {
    fun replacement(
        start: LocalDate,
        end: LocalDate,
    ): LinkedHashMap<String, MutableMap<String, Double>> {
        require(!start.isAfter(end)) { "Friends replacement start must not follow end." }
        return generateSequence(start) { current ->
            current.plusDays(1).takeIf { !it.isAfter(end) }
        }.associateTo(linkedMapOf()) { it.toString() to linkedMapOf() }
    }

    fun add(
        payload: MutableMap<String, MutableMap<String, Double>>,
        day: String,
        key: String,
        value: Double?,
        range: ClosedFloatingPointRange<Double>,
    ) {
        val values = payload[day] ?: return
        if (key in values || value == null || !value.isFinite() || value !in range) return
        values[key] = value
    }
}

object FriendsService {
    private val mutex = Mutex()

    fun setupState(context: Context): FriendsSetupState =
        FriendsPreferences.setupState(context)

    fun profileName(context: Context): String =
        FriendsPreferences.memberContext(context)?.displayName
            ?: FriendsPreferences.pendingEnrollment(context)?.displayName.orEmpty()

    fun serverAddress(context: Context): String? =
        FriendsPreferences.memberContext(context)?.endpoint
            ?: FriendsPreferences.pendingEnrollment(context)?.endpoint
            ?: RemoteSyncPrefs.endpoint().takeIf(String::isNotBlank)

    suspend fun bootstrap(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        displayName: String,
    ): FriendsRefreshResult = mutex.withLock {
        val name = validatedDisplayName(displayName)
        val endpoint = RemoteSyncPrefs.endpoint().takeIf(String::isNotBlank)
            ?: throw FriendsException.InvalidInput(
                "Set up and test Backup & Sync before creating a private profile.",
            )
        val adminToken = RemoteSyncPrefs.apiKey()
            ?: throw FriendsException.InvalidInput(
                "The self-hosted server administrator key is missing.",
            )
        val dailyDeviceId = RemoteSyncService.socialDailyDeviceId(activeDeviceId)
        val response = FriendsClient(endpoint, adminToken).bootstrap(
            displayName = name,
            installationId = RemoteSyncPrefs.installationId(),
            dailyDeviceId = dailyDeviceId,
        )
        FriendsPreferences.persistProfile(
            context = context,
            profile = response.profile,
            endpoint = endpoint,
            memberToken = response.memberToken,
        )
        FriendsSyncScheduler.reconcile(context)
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun join(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        serverAddress: String,
        code: String,
        displayName: String,
    ): FriendsRefreshResult = mutex.withLock {
        val endpoint = com.noop.sync.RemoteEndpointPolicy.normalize(serverAddress)
        val normalizedCode = normalizeInviteCode(code)
        val existing = FriendsPreferences.memberContext(context)
        if (existing != null) {
            if (!sameOrigin(existing.endpoint, endpoint)) {
                throw FriendsException.InvalidInput(
                    "This profile belongs to ${existing.endpoint}. A different server cannot replace it.",
                )
            }
            FriendsClient(existing.endpoint, existing.token).redeem(normalizedCode)
        } else {
            val name = validatedDisplayName(displayName)
            val dailyDeviceId = RemoteSyncService.socialDailyDeviceId(activeDeviceId)
            val pending = FriendsPreferences.preparePendingEnrollment(
                context = context,
                endpoint = endpoint,
                displayName = name,
                dailyDeviceId = dailyDeviceId,
            )
            val response = FriendsClient(endpoint).join(
                code = normalizedCode,
                displayName = pending.displayName,
                installationId = RemoteSyncPrefs.installationId(),
                dailyDeviceId = pending.dailyDeviceId,
                enrollmentId = pending.enrollmentId,
                memberToken = pending.token,
            )
            FriendsPreferences.persistProfile(
                context = context,
                profile = response.profile,
                endpoint = endpoint,
                memberToken = pending.token,
            )
            FriendsSyncScheduler.reconcile(context)
        }
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun refresh(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
    ): FriendsRefreshResult = mutex.withLock {
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun automaticRefreshIfDue(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        nowMs: Long = System.currentTimeMillis(),
    ): FriendsRefreshResult? = mutex.withLock {
        if (FriendsPreferences.memberContext(context) == null) return@withLock null
        if (!FriendsAutomaticRefreshPolicy.isDue(
                FriendsPreferences.lastAutomaticMs(context),
                nowMs,
            )
        ) {
            return@withLock null
        }
        // Record the throttle only after success. Retriable network/provider failures must remain due
        // so WorkManager's backoff can actually execute the retry instead of returning early.
        refreshLocked(context, repository, activeDeviceId).also { result ->
            if (!result.summaryRetryable) {
                FriendsPreferences.setLastAutomaticMs(context, nowMs)
            }
        }
    }

    suspend fun createInvite(context: Context): FriendInvite = mutex.withLock {
        val member = requireMember(context)
        FriendsClient(member.endpoint, member.token).createInvite()
    }

    suspend fun decide(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        requestId: String,
        accept: Boolean,
    ): FriendsRefreshResult = mutex.withLock {
        val member = requireMember(context)
        FriendsClient(member.endpoint, member.token).decide(requestId, accept)
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun updatePrivacy(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        friendId: String,
        visibility: FriendVisibility,
    ): FriendsRefreshResult = mutex.withLock {
        val member = requireMember(context)
        FriendsClient(member.endpoint, member.token).updatePrivacy(friendId, visibility)
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun removeFriend(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        friendId: String,
    ): FriendsRefreshResult = mutex.withLock {
        val member = requireMember(context)
        FriendsClient(member.endpoint, member.token).removeFriend(friendId)
        refreshLocked(context, repository, activeDeviceId)
    }

    suspend fun leaveAndDelete(context: Context) = mutex.withLock {
        val member = requireMember(context)
        FriendsClient(member.endpoint, member.token).deleteProfile()
        FriendsPreferences.clearProfile(context)
        FriendsSyncScheduler.reconcile(context)
    }

    suspend fun discardPendingJoin(context: Context) = mutex.withLock {
        if (FriendsPreferences.memberContext(context) != null) {
            throw FriendsException.InvalidInput(
                "The Friends profile is already active.",
            )
        }
        val pending = FriendsPreferences.pendingEnrollment(context)
            ?: throw FriendsException.InvalidInput(
                "There is no pending Friends invitation to discard.",
            )
        FriendsClient(pending.endpoint, pending.token)
            .deletePendingEnrollment(pending.enrollmentId)
        FriendsPreferences.clearPendingEnrollment(context)
        FriendsSyncScheduler.reconcile(context)
    }

    internal fun normalizeInviteCode(raw: String): String {
        val normalized = raw.uppercase().filter(Char::isLetterOrDigit)
        if (normalized.length !in 12..32 || !normalized.all(Char::isLetterOrDigit)) {
            throw FriendsException.InvalidInput("Enter a valid one-time invite code.")
        }
        return normalized
    }

    internal fun sharedFieldUnion(friends: List<FriendContact>): FriendVisibility =
        FriendVisibility(
            charge = friends.any { it.sharing.charge },
            effort = friends.any { it.sharing.effort },
            rest = friends.any { it.sharing.rest },
            sleepDuration = friends.any { it.sharing.sleepDuration },
            hrv = friends.any { it.sharing.hrv },
            rhr = friends.any { it.sharing.rhr },
        )

    private suspend fun refreshLocked(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
    ): FriendsRefreshResult {
        val member = requireMember(context)
        val client = FriendsClient(member.endpoint, member.token)
        val (friends, requests) = coroutineScope {
            val friendsRequest = async { client.friends() }
            val requestsRequest = async { client.requests() }
            friendsRequest.await() to requestsRequest.await()
        }
        var summaryRetryable = false
        val summaryUploaded = try {
            uploadSummary(
                context = context,
                repository = repository,
                activeDeviceId = activeDeviceId,
                member = member,
                allowed = sharedFieldUnion(friends),
            )
            true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            summaryRetryable = FriendsRetryPolicy.isRetryableSummaryFailure(error)
            false
        }
        val today = LocalDate.now()
        val latest = client.feed(
            start = today.minusDays(14).toString(),
            end = today.toString(),
        )
        return FriendsRefreshResult(
            snapshot = FriendsSnapshot(
                friends = friends
                    .map { it.copy(latest = latest[it.profileId]) }
                    .sortedBy { it.displayName.lowercase(java.util.Locale.ROOT) },
                requests = requests.sortedByDescending(FriendRequest::createdAt),
            ),
            summaryUploaded = summaryUploaded,
            summaryRetryable = summaryRetryable,
        )
    }

    private suspend fun uploadSummary(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        member: FriendMemberContext,
        allowed: FriendVisibility,
    ) {
        val end = LocalDate.now()
        val start = end.minusDays(30)
        val payload = FriendsSummaryProjection.replacement(start, end)

        val computedSources = repository.computedSourceIds(activeDeviceId)
        for (source in computedSources) {
            repository.dailyMetrics(source, start.toString(), end.toString()).forEach { row ->
                if (allowed.charge) {
                    FriendsSummaryProjection.add(
                        payload,
                        row.day,
                        "recovery",
                        row.recovery,
                        0.0..100.0,
                    )
                }
                if (allowed.effort) {
                    FriendsSummaryProjection.add(
                        payload,
                        row.day,
                        "effort",
                        row.strain,
                        0.0..100.0,
                    )
                }
                if (allowed.sleepDuration) {
                    FriendsSummaryProjection.add(
                        payload,
                        row.day,
                        "total_sleep_min",
                        row.totalSleepMin,
                        0.0..1_440.0,
                    )
                }
                if (allowed.hrv) {
                    FriendsSummaryProjection.add(
                        payload,
                        row.day,
                        "avg_hrv",
                        row.avgHrv,
                        0.0..500.0,
                    )
                }
                if (allowed.rhr) {
                    FriendsSummaryProjection.add(
                        payload,
                        row.day,
                        "resting_hr",
                        row.restingHr?.toDouble(),
                        20.0..250.0,
                    )
                }
            }
            if (allowed.rest) {
                repository.metricSeries(
                    source,
                    "sleep_performance",
                    start.toString(),
                    end.toString(),
                ).forEach { point ->
                    FriendsSummaryProjection.add(
                        payload,
                        point.day,
                        "sleep_performance",
                        point.value,
                        0.0..100.0,
                    )
                }
            }
        }

        val draft = RemoteEnvelopeDraft(
            source = RemoteSourceDraft(
                deviceId = member.dailyDeviceId,
                appVersion = BuildConfig.VERSION_NAME,
                metadata = mapOf(
                    "installation_id" to RemoteSyncPrefs.installationId(),
                    "logical_source_id" to "$activeDeviceId-noop-friends",
                    "namespace" to "noop_computed",
                    "paired_device_id" to activeDeviceId,
                    "privacy" to "explicit_opt_in",
                    "score_provenance" to "noop_transparent_algorithm",
                    "algorithm_revision" to "${RemoteNoopAlgorithmRevision.METADATA}+friends-v1",
                ),
            ),
            dailyMetrics = payload,
        )
        val fingerprint = RemoteSyncJson.fingerprint(draft)
        val identity = FriendsPreferences.uploadIdentity(context, fingerprint)
        RemoteSyncClient(
            RemoteSyncConfiguration(member.endpoint, member.token, timeoutSeconds = 30),
        ).upload(
            RemoteEnvelope(
                batchId = identity.batchId,
                sentAt = identity.sentAt,
                draft = draft,
            ),
        )
        FriendsPreferences.acknowledgeUpload(context, fingerprint)
    }

    private fun requireMember(context: Context): FriendMemberContext =
        FriendsPreferences.memberContext(context)
            ?: throw FriendsException.InvalidInput("Create or join a private Friends profile first.")

    private fun validatedDisplayName(raw: String): String {
        val value = raw.trim().replace(Regex("""\s+"""), " ")
        if (value.length !in 1..64) {
            throw FriendsException.InvalidInput(
                "Choose a display name between 1 and 64 characters.",
            )
        }
        return value
    }

    private fun sameOrigin(left: String, right: String): Boolean {
        fun origin(value: String): Triple<String, String, Int>? {
            val uri = runCatching { URI(value) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            val host = uri.host?.lowercase() ?: return null
            val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
            return Triple(scheme, host, port)
        }
        return origin(left) == origin(right)
    }
}
