package com.noop.ui

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BiofeedbackPrefsTest {

    @Test
    fun currentCapability_honorsExplicitOptInsAtEngineBoundary() {
        val config = BiofeedbackPrefs.stressConfig(
            storedCheckInEnabled = true,
            storedAutoNudge = true,
            storedPhoneNudge = true,
            capability = BiofeedbackPrefs.automaticStressNudgeCapability,
        )

        assertTrue(BiofeedbackPrefs.automaticStressNudgesAvailable)
        assertTrue(config.enabled)
        assertTrue(config.autoNudge)
        val canonical = BiofeedbackPrefs.canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = true,
            storedAutoNudge = true,
            storedPhoneNudge = true,
            capability = BiofeedbackPrefs.automaticStressNudgeCapability,
        )
        assertTrue(canonical.phoneNudge)
    }

    @Test
    fun availableCapability_requiresHierarchicalOptIns() {
        val available = BiofeedbackPrefs.AutomaticStressNudgeCapability
            .AVAILABLE_WITH_TIMESTAMP_MATCHED_WRIST_MOTION

        val fullyOptedIn = BiofeedbackPrefs.stressConfig(true, true, available)
        assertTrue(fullyOptedIn.enabled)
        assertTrue(fullyOptedIn.autoNudge)

        val masterOff = BiofeedbackPrefs.stressConfig(false, true, available)
        assertFalse(masterOff.enabled)
        assertFalse(masterOff.autoNudge)

        val autoOff = BiofeedbackPrefs.stressConfig(true, false, available)
        assertTrue(autoOff.enabled)
        assertFalse(autoOff.autoNudge)

        val canonicalMasterOff = BiofeedbackPrefs.canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = false,
            storedAutoNudge = true,
            storedPhoneNudge = true,
            capability = available,
        )
        assertFalse(canonicalMasterOff.checkInEnabled)
        assertFalse(canonicalMasterOff.autoNudge)
        assertFalse(canonicalMasterOff.phoneNudge)

        val automaticOff = BiofeedbackPrefs.canonicalAutomaticStressNudgePreferences(
            storedCheckInEnabled = true,
            storedAutoNudge = false,
            storedPhoneNudge = true,
            capability = available,
        )
        assertTrue(automaticOff.checkInEnabled)
        assertFalse(automaticOff.autoNudge)
        assertFalse(automaticOff.phoneNudge)
    }

    @Test
    fun unavailableCapabilityMigration_disarmsAllAutomaticFlagsAndPreservesManualBreathePrefs() {
        val prefs = FakeSharedPreferences().apply {
            map["biofeedback.stressCheckIn"] = true
            map["biofeedback.stressAutoNudge"] = true
            map["biofeedback.stressPhoneNudge"] = true
            map["biofeedback.resonanceBpm"] = 5.5f
            map["biofeedback.resonanceLockedAt"] = 1_700_000_000_000L
            map["biofeedback.stressUseResonancePace"] = true
        }

        val migrated = BiofeedbackPrefs.migrateAutomaticStressNudgePreferences(
            prefs,
            BiofeedbackPrefs.AutomaticStressNudgeCapability
                .UNAVAILABLE_NEEDS_TIMESTAMP_MATCHED_WRIST_MOTION,
        )

        assertFalse(migrated.checkInEnabled)
        assertFalse(migrated.autoNudge)
        assertFalse(migrated.phoneNudge)
        assertFalse(prefs.getBoolean("biofeedback.stressCheckIn", true))
        assertFalse(prefs.getBoolean("biofeedback.stressAutoNudge", true))
        assertFalse(prefs.getBoolean("biofeedback.stressPhoneNudge", true))
        assertEquals(5.5f, prefs.getFloat("biofeedback.resonanceBpm", 0f), 0f)
        assertEquals(1_700_000_000_000L, prefs.getLong("biofeedback.resonanceLockedAt", 0L))
        assertTrue(prefs.getBoolean("biofeedback.stressUseResonancePace", false))
    }

    private class FakeSharedPreferences : SharedPreferences {
        val map = HashMap<String, Any?>()

        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getString(key: String, defValue: String?): String? = map[key] as? String ?: defValue
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit
        override fun edit(): SharedPreferences.Editor = FakeEditor(this)

        private class FakeEditor(private val prefs: FakeSharedPreferences) : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { removals.add(key) }
            override fun clear() = apply { prefs.map.clear() }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() = flush()
            private fun flush() {
                removals.forEach(prefs.map::remove)
                prefs.map.putAll(pending)
            }
        }
    }
}
