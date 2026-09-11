package com.noop.notif

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.data.WhoopRepository
import com.noop.ui.AutoWorkoutAutomationPolicy
import com.noop.ui.AutoWorkoutBackgroundPolicy
import com.noop.ui.AutoWorkoutCandidateScan
import com.noop.ui.AutoWorkoutMode
import com.noop.ui.AutoWorkoutPrefs
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NoopPrefs
import com.noop.ui.NotificationRouteBridge
import com.noop.ui.buildDetectedAutoWorkoutRow
import kotlin.coroutines.cancellation.CancellationException

/** Pure decision/copy seam for the background candidate notification. */
internal object AutoWorkoutCandidateNotificationPolicy {
    data class Copy(val title: String, val body: String)

    enum class Kind(val tokenPrefix: String) { CANDIDATE("candidate"), AUTO_SAVED("autoSaved") }

    fun privacySafeCopy(kind: Kind): Copy = when (kind) {
        Kind.CANDIDATE -> Copy(
            title = "Possible workout found",
            body = "Open NOOP to review the activity and choose whether to save it.",
        )
        Kind.AUTO_SAVED -> Copy(
            title = "Workout saved automatically",
            body = "Open NOOP to keep it or mark it as not a workout.",
        )
    }

    fun token(startSec: Long, endSec: Long): String = AutoWorkoutPrefs.token(startSec, endSec)

    fun deliveryToken(kind: Kind, candidateToken: String): String =
        "${kind.tokenPrefix}:$candidateToken"

    fun shouldPost(
        autoDetectEnabled: Boolean,
        suggestionNotificationsEnabled: Boolean,
        notificationsAlreadyAuthorized: Boolean,
        kind: Kind,
        candidateToken: String,
        lastNotifiedToken: String?,
    ): Boolean {
        if (!autoDetectEnabled ||
            !suggestionNotificationsEnabled ||
            !notificationsAlreadyAuthorized
        ) return false
        if (deliveryToken(kind, candidateToken) == lastNotifiedToken) return false
        // Before modes existed, Ask notifications stored only `start:<ts>`. Honor that old token so an
        // upgrade does not re-alert an already reviewed suggestion.
        if (kind == Kind.CANDIDATE && candidateToken == lastNotifiedToken) return false
        return true
    }

    /** A failed OS post must not consume the span; leaving [previous] intact makes the next scan retry. */
    fun tokenAfterAttempt(previous: String?, candidateToken: String, postedSuccessfully: Boolean): String? =
        if (postedSuccessfully) candidateToken else previous
}

/**
 * Runs the same scan as Today after reanalysis. Ask posts a suggestion. The dormant legacy Auto-save
 * branch can persist only when a future calibrated-confidence policy permits it; current preferences
 * resolve it to Ask. It never requests notification permission, and a failed unattended write falls
 * back to an explicit suggestion.
 */
object AutoWorkoutCandidateNotifier {
    private const val CHANNEL_ID = "noop_auto_workout_candidates"
    private const val PREFS_FILE = "noop_auto_workout_notifications"
    private const val KEY_LAST_NOTIFIED_TOKEN = "autoWorkout.lastNotifiedToken"
    private val postLock = Any()

    suspend fun afterReanalysis(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        traceSink: ((String) -> Unit)? = null,
    ) {
        val appContext = context.applicationContext
        val mode = NoopPrefs.autoWorkoutMode(appContext)
        if (mode == AutoWorkoutMode.OFF) return

        val days = try {
            repository.daysMerged(activeDeviceId)
        } catch (t: Throwable) {
            if (t is CancellationException) throw t
            return
        }
        val candidate = try {
            AutoWorkoutCandidateScan.latest(
                repository = repository,
                activeDeviceId = activeDeviceId,
                days = days,
                dismissedTokens = AutoWorkoutPrefs.dismissed(appContext),
                traceSink = traceSink,
                forceRefresh = true,
            )
        } catch (t: Throwable) {
            if (t is CancellationException) throw t
            return // best effort: detection/DB/notification work must never break sync or scoring
        } ?: return

        if (!AutoWorkoutBackgroundPolicy.shouldProcess(
                candidate = candidate,
                nowSec = System.currentTimeMillis() / 1_000L,
            )
        ) return

        if (mode == AutoWorkoutMode.AUTO_SAVE && AutoWorkoutAutomationPolicy.shouldAutoSave(candidate)) {
            val computedId = repository.computedDeviceId(activeDeviceId)
            val row = buildDetectedAutoWorkoutRow(computedId, candidate)
            val saved = row != null && runCatching { repository.saveManualWorkout(row) }.isSuccess
            if (saved && row != null) {
                AutoWorkoutPrefs.recordCandidateDecision(
                    appContext,
                    candidate,
                    AutoWorkoutPrefs.DecisionAction.AUTO_SAVED,
                    AutoWorkoutPrefs.DecisionActor.AUTOMATION,
                    row.sport,
                )
                AutoWorkoutPrefs.recordReview(
                    appContext,
                    AutoWorkoutPrefs.Review(
                        candidate.startSec, candidate.endSec, row.sport, row.deviceId, row.source,
                        candidate.avgBpm, candidate.peakBpm,
                    ),
                )
                runCatching {
                    postIfAuthorized(
                        appContext, candidate.startSec, candidate.endSec,
                        AutoWorkoutCandidateNotificationPolicy.Kind.AUTO_SAVED,
                    )
                }
                return
            }
        }

        // Notification plumbing is strictly best-effort; an OEM manager/prefs failure cannot turn a
        // successful scoring pass into a sync failure.
        runCatching {
            postIfAuthorized(
                appContext, candidate.startSec, candidate.endSec,
                AutoWorkoutCandidateNotificationPolicy.Kind.CANDIDATE,
            )
        }
    }

    /** Called by the visible Today path after it wins a harmless duplicate-save race with reanalysis. */
    fun postAutoSavedIfAuthorized(context: Context, startSec: Long, endSec: Long) {
        runCatching {
            postIfAuthorized(
                context.applicationContext, startSec, endSec,
                AutoWorkoutCandidateNotificationPolicy.Kind.AUTO_SAVED,
            )
        }
    }

    @SuppressLint("MissingPermission") // explicit permission/settings gate + fail-safe catch below
    private fun postIfAuthorized(
        context: Context,
        startSec: Long,
        endSec: Long,
        kind: AutoWorkoutCandidateNotificationPolicy.Kind,
    ) {
        synchronized(postLock) {
            val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            val previous = prefs.getString(KEY_LAST_NOTIFIED_TOKEN, null)
            val candidateToken = AutoWorkoutCandidateNotificationPolicy.token(startSec, endSec)
            val deliveryToken = AutoWorkoutCandidateNotificationPolicy.deliveryToken(kind, candidateToken)
            val authorized = runCatching { notificationsAlreadyAuthorized(context) }.getOrDefault(false)
            val autoDetectEnabled = NoopPrefs.autoDetectWorkouts(context)
            val suggestionNotificationsEnabled =
                NoopPrefs.autoWorkoutSuggestionNotifications(context)
            if (!authorized && autoDetectEnabled && suggestionNotificationsEnabled) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.AUTO_WORKOUT,
                    NotificationLifecycleCategory.RECOMMENDATION,
                )
            }
            if (!AutoWorkoutCandidateNotificationPolicy.shouldPost(
                    autoDetectEnabled = autoDetectEnabled,
                    suggestionNotificationsEnabled = suggestionNotificationsEnabled,
                    notificationsAlreadyAuthorized = authorized,
                    kind = kind,
                    candidateToken = candidateToken,
                    lastNotifiedToken = previous,
                )
            ) return

            val posted = runCatching {
                if (!ensureUsableChannel(context)) {
                    NotificationLifecycleLedger.suppressed(
                        context,
                        NotificationLifecycleId.AUTO_WORKOUT,
                        NotificationLifecycleCategory.RECOMMENDATION,
                    )
                    return@runCatching false
                }
                val copy = AutoWorkoutCandidateNotificationPolicy.privacySafeCopy(kind)
                val openToday = NotificationPlatformIdentity.activityPendingIntent(
                    context,
                    NotificationPlatformIdentity.ActivityIntent.AUTO_WORKOUT,
                    NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.TODAY),
                )
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(copy.title)
                    .setContentText(copy.body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(copy.body))
                    .setContentIntent(openToday)
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                    .build()
                NotificationLifecycleLedger.posted(
                    context,
                    NotificationLifecycleId.AUTO_WORKOUT,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    NotificationManagerCompat.from(context).notify(
                        NotificationPlatformIdentity.NotificationId.AUTO_WORKOUT,
                        notification,
                    )
                }
            }.getOrElse {
                NotificationLifecycleLedger.unknown(
                    context,
                    NotificationLifecycleId.AUTO_WORKOUT,
                    NotificationLifecycleCategory.RECOMMENDATION,
                )
                false
            }

            val next = AutoWorkoutCandidateNotificationPolicy.tokenAfterAttempt(
                previous, deliveryToken, posted,
            )
            if (next != previous) prefs.edit().putString(KEY_LAST_NOTIFIED_TOKEN, next).apply()
        }
    }

    /** Remove a suggestion the user handled in-app. Keep its stable last-token so it cannot re-alert. */
    fun cancelHandled(context: Context) {
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.AUTO_WORKOUT,
            NotificationLifecycleCategory.RECOMMENDATION,
        ) {
            NotificationManagerCompat.from(context.applicationContext).cancel(
                NotificationPlatformIdentity.NotificationId.AUTO_WORKOUT,
            )
        }
    }

    /** True only for permission/settings already granted by some user-initiated notification feature. */
    private fun notificationsAlreadyAuthorized(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /** Create the channel only after authorization is known; a user-blocked existing channel stays off. */
    private fun ensureUsableChannel(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return existing.importance != NotificationManager.IMPORTANCE_NONE
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Automatic workouts",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Private prompts to save or review workouts NOOP detects on this phone."
            },
        )
        return manager.getNotificationChannel(CHANNEL_ID)
            ?.let { it.importance != NotificationManager.IMPORTANCE_NONE }
            ?: false
    }
}
