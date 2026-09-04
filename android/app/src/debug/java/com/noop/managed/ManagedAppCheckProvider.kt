package com.noop.managed

import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory

internal object ManagedAppCheckProvider {
    fun install(app: FirebaseApp) {
        FirebaseAppCheck.getInstance(app).installAppCheckProviderFactory(
            DebugAppCheckProviderFactory.getInstance(),
        )
        FirebaseAppCheck.getInstance(app).setTokenAutoRefreshEnabled(true)
    }
}
