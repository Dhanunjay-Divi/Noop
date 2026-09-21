package com.noop.managed

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ManagedAccountScopePersistenceInstrumentedTest {
    private lateinit var context: Context

    @Before
    fun resetPreferences() {
        context = ApplicationProvider.getApplicationContext()
        context.deleteSharedPreferences(PREFERENCES_FILE)
    }

    @After
    fun cleanPreferences() {
        context.deleteSharedPreferences(PREFERENCES_FILE)
    }

    @Test
    fun legacyScopeSurvivesDisconnectAndIsReusedForReEnrollment() {
        val uid = "legacy-user"
        val legacyScope = ManagedAccountScope.legacy(uid)
        val identityScope = ManagedAccountScope.identity(PROJECT_ID, null, uid)
        val preferences = ManagedCloudPreferences(context)
        val enrolled = ManagedAccountScope.resolve(
            projectId = PROJECT_ID,
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = legacyScope,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )
        preferences.completeEnrollment(enrolled, POLICY_VERSION)

        preferences.clearEnrollment(preserveLegacyScope = true)

        assertNull(preferences.enrolledScopeHash)
        assertNull(preferences.enrolledIdentityScopeHash)
        assertNull(preferences.enrolledDataScopeVersion)
        val retainedScope = preferences.retainedLegacyDataScopeHash(identityScope)
        assertEquals(legacyScope, retainedScope)

        val recovered = ManagedAccountScope.resolve(
            projectId = PROJECT_ID,
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = retainedScope,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )
        assertEquals(legacyScope, recovered.dataScopeHash)
        assertEquals(1, recovered.dataScopeVersion)

        preferences.completeEnrollment(recovered, POLICY_VERSION)
        assertEquals(legacyScope, preferences.enrolledScopeHash)
        assertNull(preferences.retainedLegacyDataScopeHash(identityScope))
    }

    @Test
    fun confirmedErasureClearDoesNotRetainLegacyScope() {
        val uid = "legacy-user"
        val legacyScope = ManagedAccountScope.legacy(uid)
        val identityScope = ManagedAccountScope.identity(PROJECT_ID, null, uid)
        val preferences = ManagedCloudPreferences(context)
        val enrolled = ManagedAccountScope.resolve(
            projectId = PROJECT_ID,
            tenantId = null,
            uid = uid,
            enrolledDataScopeHash = legacyScope,
            persistedIdentityScopeHash = null,
            persistedDataScopeVersion = null,
        )
        preferences.completeEnrollment(enrolled, POLICY_VERSION)

        preferences.clearEnrollment()

        assertNull(preferences.enrolledScopeHash)
        assertNull(preferences.retainedLegacyDataScopeHash(identityScope))
    }

    private companion object {
        const val PREFERENCES_FILE = "noop_managed_cloud_secure_v1"
        const val PROJECT_ID = "noop-india"
        const val POLICY_VERSION = "managed-storage-v1"
    }
}
