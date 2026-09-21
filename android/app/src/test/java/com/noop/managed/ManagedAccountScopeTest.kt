package com.noop.managed

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedAccountScopeTest {
    @Test
    fun v2SeparatesProjectTenantAndUid() {
        val base = ManagedAccountScope.identity("noop-india", null, "shared-user")
        assertNotEquals(
            base,
            ManagedAccountScope.identity("noop-us", null, "shared-user"),
        )
        assertNotEquals(
            base,
            ManagedAccountScope.identity("noop-india", "premium", "shared-user"),
        )
        assertNotEquals(
            base,
            ManagedAccountScope.identity("noop-india", null, "another-user"),
        )
    }

    @Test
    fun existingV1EnrollmentKeepsItsDataNamespace() {
        val uid = "legacy-user"
        val legacy = ManagedAccountScope.legacy(uid)
        val binding = ManagedAccountScope.resolve(
            projectId = "noop-india",
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = legacy,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )

        assertEquals(legacy, binding.dataScopeHash)
        assertEquals(1, binding.dataScopeVersion)
        assertTrue(binding.requiresPersistence)

        val repeated = ManagedAccountScope.resolve(
            projectId = "noop-india",
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = legacy,
            persistedIdentityScopeHash = binding.identityScopeHash,
            persistedDataScopeVersion = binding.dataScopeVersion,
        )
        assertEquals(legacy, repeated.dataScopeHash)
        assertFalse(repeated.requiresPersistence)
    }

    @Test
    fun retainedV1ScopeRecoversAfterDisconnectAndReEnrollment() {
        val uid = "legacy-user"
        val legacy = ManagedAccountScope.legacy(uid)
        val recovered = ManagedAccountScope.resolve(
            projectId = "noop-india",
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = legacy,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )

        assertEquals(legacy, recovered.dataScopeHash)
        assertEquals(1, recovered.dataScopeVersion)
        assertTrue(recovered.requiresPersistence)
    }

    @Test
    fun newEnrollmentUsesV2Candidate() {
        val binding = ManagedAccountScope.resolve(
            projectId = "noop-india",
            tenantId = null,
            uid = "new-user",
            enrolledDataScopeHash = null,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )

        assertEquals(binding.identityScopeHash, binding.dataScopeHash)
        assertEquals(2, binding.dataScopeVersion)
        assertTrue(binding.requiresPersistence)
    }

    @Test
    fun foreignAndPartialBindingsFailClosed() {
        val v2 = ManagedAccountScope.identity("noop-india", null, "user")
        assertThrows(ManagedAccountScopeException.IdentityMismatch::class.java) {
            ManagedAccountScope.resolve(
                projectId = "noop-us",
                tenantId = null,
                uid = "user",
                enrolledDataScopeHash = v2,
                persistedIdentityScopeHash = v2,
                persistedDataScopeVersion = 2,
            )
        }
        assertThrows(ManagedAccountScopeException.InvalidPersistedBinding::class.java) {
            ManagedAccountScope.resolve(
                projectId = "noop-india",
                tenantId = null,
                uid = "user",
                enrolledDataScopeHash = v2,
                persistedIdentityScopeHash = null,
                persistedDataScopeVersion = 2,
            )
        }
    }
}
