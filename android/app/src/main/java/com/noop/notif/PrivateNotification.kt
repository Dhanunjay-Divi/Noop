package com.noop.notif

import android.content.Context
import androidx.core.app.NotificationCompat
import com.noop.R

/**
 * Keeps sensitive notification content available after unlock while exposing only neutral copy on
 * a protected lock screen.
 */
internal fun NotificationCompat.Builder.protectPrivateContent(
    context: Context,
    channelId: String,
): NotificationCompat.Builder = apply {
    setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
    setPublicVersion(
        NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(context.getString(R.string.notification_public_update))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build(),
    )
}
