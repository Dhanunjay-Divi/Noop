package com.noop.ui

import android.app.Activity
import android.os.Bundle

/**
 * Private entry point for notification actions.
 *
 * PendingIntents target this non-exported activity so caller-controlled intents
 * cannot forge wellness presentations through the exported app/deep-link host.
 */
class NotificationRouteActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NotificationRouteBridge.recordFromTrustedIntent(
            applicationContext,
            intent,
        )
        startActivity(appLaunchIntent(this))
        finish()
    }
}
