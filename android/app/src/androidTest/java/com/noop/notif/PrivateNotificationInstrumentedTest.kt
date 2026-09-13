package com.noop.notif

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PrivateNotificationInstrumentedTest {
    @Test
    fun sensitiveNotificationBuildsANeutralActionFreePublicVersion() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val pendingIntent = PendingIntent.getActivity(
            context,
            1,
            Intent("com.noop.test.OPEN_PRIVATE_NOTIFICATION").setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val sensitiveAction = NotificationCompat.Action.Builder(
            R.drawable.ic_stat_heart,
            "Sensitive action",
            pendingIntent,
        )
            .addRemoteInput(
                RemoteInput.Builder("sensitive_reply")
                    .setLabel("Sensitive reply")
                    .build(),
            )
            .build()

        val privateNotification = NotificationCompat.Builder(context, "privacy-runtime-test")
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle("Sensitive title")
            .setContentText("Sensitive health detail")
            .setContentIntent(pendingIntent)
            .addAction(sensitiveAction)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText("Sensitive expanded health detail"),
            )
            .protectPrivateContent(context, "privacy-runtime-test")
            .build()

        assertEquals(NotificationCompat.VISIBILITY_PRIVATE, privateNotification.visibility)
        assertNotNull(privateNotification.publicVersion)
        val publicNotification = checkNotNull(privateNotification.publicVersion)
        assertEquals(NotificationCompat.VISIBILITY_PUBLIC, publicNotification.visibility)
        assertEquals(
            context.getString(R.string.app_name),
            publicNotification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
        )
        assertEquals(
            context.getString(R.string.notification_public_update),
            publicNotification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
        )
        assertNull(publicNotification.contentIntent)
        assertEquals(0, publicNotification.actions?.size ?: 0)
        assertTrue(
            publicNotification.actions
                .orEmpty()
                .flatMap { it.remoteInputs?.toList().orEmpty() }
                .isEmpty(),
        )
        assertNull(publicNotification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        assertNull(publicNotification.extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
        assertNull(publicNotification.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES))
        assertNull(publicNotification.extras.getString(Notification.EXTRA_TEMPLATE))
    }
}
