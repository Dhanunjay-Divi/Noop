package com.noop.managed

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class ManagedAuthenticationRetryTest {
    @Test
    fun successUsesCachedAuthorizationWithoutRefresh() = runTest {
        val authorizationRequests = mutableListOf<Boolean>()
        val operationTokens = mutableListOf<String>()

        val result = ManagedAuthenticationRetry.run(
            authorization = { forceRefresh ->
                authorizationRequests += forceRefresh
                authorization(if (forceRefresh) "fresh" else "cached")
            },
            operation = {
                operationTokens += it.identityToken
                it.identityToken
            },
        )

        assertEquals("cached", result)
        assertEquals(listOf(false), authorizationRequests)
        assertEquals(listOf("cached"), operationTokens)
    }

    @Test
    fun authenticationFailureRefreshesAndReplaysExactlyOnce() = runTest {
        val authorizationRequests = mutableListOf<Boolean>()
        val operationTokens = mutableListOf<String>()

        val result = ManagedAuthenticationRetry.run(
            authorization = { forceRefresh ->
                authorizationRequests += forceRefresh
                authorization(if (forceRefresh) "fresh" else "cached")
            },
            operation = {
                operationTokens += it.identityToken
                if (it.identityToken == "cached") {
                    throw ManagedStorageException.Authentication()
                }
                "completed"
            },
        )

        assertEquals("completed", result)
        assertEquals(listOf(false, true), authorizationRequests)
        assertEquals(listOf("cached", "fresh"), operationTokens)
    }

    @Test
    fun secondAuthenticationFailurePropagatesWithoutLooping() = runTest {
        val authorizationRequests = mutableListOf<Boolean>()
        val operationTokens = mutableListOf<String>()

        try {
            ManagedAuthenticationRetry.run(
                authorization = { forceRefresh ->
                    authorizationRequests += forceRefresh
                    authorization(if (forceRefresh) "fresh" else "cached")
                },
                operation = {
                    operationTokens += it.identityToken
                    throw ManagedStorageException.Authentication()
                },
            )
            fail("A second authentication failure must propagate.")
        } catch (_: ManagedStorageException.Authentication) {
            // Expected.
        }

        assertEquals(listOf(false, true), authorizationRequests)
        assertEquals(listOf("cached", "fresh"), operationTokens)
    }

    @Test
    fun nonAuthenticationFailureDoesNotRefreshOrReplay() = runTest {
        val authorizationRequests = mutableListOf<Boolean>()
        val operationTokens = mutableListOf<String>()

        try {
            ManagedAuthenticationRetry.run(
                authorization = { forceRefresh ->
                    authorizationRequests += forceRefresh
                    authorization(if (forceRefresh) "fresh" else "cached")
                },
                operation = {
                    operationTokens += it.identityToken
                    throw ManagedStorageException.QuotaExceeded()
                },
            )
            fail("Quota failure must propagate.")
        } catch (_: ManagedStorageException.QuotaExceeded) {
            // Expected.
        }

        assertEquals(listOf(false), authorizationRequests)
        assertEquals(listOf("cached"), operationTokens)
    }

    private fun authorization(token: String) = ManagedAuthorization(
        identityToken = token,
        appCheckToken = "app-check-$token",
        installationId = "installation-1",
        installationToken = "noopm_" + "a".repeat(43),
    )
}
