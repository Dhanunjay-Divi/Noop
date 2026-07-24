package com.noop.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteEndpointPolicyTest {
    @Test
    fun publicCleartextIsRejected() {
        val error = assertThrows(RemoteSyncConfigurationException::class.java) {
            RemoteEndpointPolicy.normalize("http://example.com")
        }
        assertTrue(error.message.orEmpty().contains("HTTPS"))
    }

    @Test
    fun privateLanAndLoopbackCleartextAreAccepted() {
        assertEquals("http://192.168.1.42:8000", RemoteEndpointPolicy.normalize("http://192.168.1.42:8000/"))
        assertEquals("http://10.0.2.2:8000", RemoteEndpointPolicy.normalize("http://10.0.2.2:8000"))
        assertEquals("http://169.254.10.20", RemoteEndpointPolicy.normalize("http://169.254.10.20"))
        assertEquals("http://localhost:8000", RemoteEndpointPolicy.normalize("http://localhost:8000"))
        assertEquals("http://noop.local", RemoteEndpointPolicy.normalize("http://noop.local"))
        assertEquals("http://[fc00::1]:8000", RemoteEndpointPolicy.normalize("http://[fc00::1]:8000"))
        assertEquals("http://[fe80::1]", RemoteEndpointPolicy.normalize("http://[fe80::1]"))
        assertEquals("http://[::1]", RemoteEndpointPolicy.normalize("http://[::1]"))
    }

    @Test
    fun numericPrefixesAndIpv6LookingHostnamesCannotBypassCleartextPolicy() {
        listOf(
            "http://10.0.0.1.evil.com",
            "http://010.0.0.1",
            "http://192.168.1.4.attacker.example",
            "http://fcevil.com",
            "http://fd-attacker.example",
            "http://fe80.example",
            "http://[2001:4860:4860::8888]",
        ).forEach { url ->
            assertThrows("Expected rejection for $url", RemoteSyncConfigurationException::class.java) {
                RemoteEndpointPolicy.normalize(url)
            }
        }
    }

    @Test
    fun missingSchemeDefaultsToHttpsAndKeepsBasePath() {
        assertEquals(
            "https://noop.example.com/api",
            RemoteEndpointPolicy.normalize("noop.example.com/api/"),
        )
    }

    @Test
    fun embeddedCredentialsAndQueryAreRejected() {
        assertThrows(RemoteSyncConfigurationException::class.java) {
            RemoteEndpointPolicy.normalize("https://user:secret@example.com")
        }
        assertThrows(RemoteSyncConfigurationException::class.java) {
            RemoteEndpointPolicy.normalize("https://example.com?token=secret")
        }
    }
}
