package com.noop.ui

import com.noop.update.UpdateCheck

data class ReleaseWelcomeInstallState(
    val pending: Boolean,
    val completed: Boolean,
) {
    fun completingWelcome(): ReleaseWelcomeInstallState =
        ReleaseWelcomeInstallState(pending = false, completed = true)

    companion object {
        fun prepared(
            onboarded: Boolean,
            storedPending: Boolean,
            storedCompleted: Boolean,
        ): ReleaseWelcomeInstallState = when {
            storedCompleted ->
                ReleaseWelcomeInstallState(pending = false, completed = true)
            storedPending ->
                ReleaseWelcomeInstallState(pending = true, completed = false)
            !onboarded ->
                ReleaseWelcomeInstallState(pending = true, completed = false)
            onboarded ->
                ReleaseWelcomeInstallState(pending = false, completed = true)
            else ->
                ReleaseWelcomeInstallState(pending = false, completed = false)
        }

        fun isReleaseDue(currentVersion: String, lastSeenVersion: String): Boolean =
            UpdateCheck.isNewer(currentVersion, lastSeenVersion)
    }
}
