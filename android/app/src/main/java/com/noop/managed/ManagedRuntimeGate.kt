package com.noop.managed

import android.content.Context
import com.noop.ui.NoopPrefs
import com.noop.ui.Terms

/**
 * Keeps every managed-network entry point behind the same current-Terms receipt as app startup.
 *
 * Reading this preference is local-only and intentionally happens before Firebase, WorkManager,
 * Room, or the managed service can initialize.
 */
internal object ManagedRuntimeGate {
    fun isAuthorized(context: Context): Boolean =
        acceptsCurrentTerms(
            NoopPrefs.of(context.applicationContext)
                .getString(NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, null),
        )

    internal fun acceptsCurrentTerms(acceptedVersion: String?): Boolean =
        acceptedVersion == Terms.CURRENT_VERSION
}
