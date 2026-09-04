package com.noop.managed

/**
 * Replays one idempotent managed-storage operation after refreshing both Firebase credentials.
 *
 * The operation owns its durable checkpoints. Only authentication failures are retried, and the
 * refreshed attempt is never looped.
 */
internal object ManagedAuthenticationRetry {
    suspend fun <T> run(
        authorization: suspend (forceRefresh: Boolean) -> ManagedAuthorization,
        operation: suspend (authorization: ManagedAuthorization) -> T,
    ): T = try {
        operation(authorization(false))
    } catch (_: ManagedStorageException.Authentication) {
        operation(authorization(true))
    }
}
