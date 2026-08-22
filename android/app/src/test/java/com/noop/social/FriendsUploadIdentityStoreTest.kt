package com.noop.social

import android.content.SharedPreferences
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class FriendsUploadIdentityStoreTest {
    @Test
    fun ambiguousRetryReusesIdentityUntilMatchingAcknowledgement() {
        val prefs = FakeSharedPreferences()
        val first = FriendsUploadIdentityStore.resolve(
            prefs,
            "fingerprint-a",
            Instant.parse("2026-08-22T12:00:00Z"),
        )
        val retry = FriendsUploadIdentityStore.resolve(
            prefs,
            "fingerprint-a",
            Instant.parse("2026-08-22T13:00:00Z"),
        )
        assertEquals(first, retry)

        val replacement = FriendsUploadIdentityStore.resolve(
            prefs,
            "fingerprint-b",
            Instant.parse("2026-08-22T14:00:00Z"),
        )
        assertNotEquals(first.batchId, replacement.batchId)

        // A late completion for the older body must not clear the newer in-flight identity.
        FriendsUploadIdentityStore.acknowledge(prefs, "fingerprint-a")
        assertEquals(
            replacement,
            FriendsUploadIdentityStore.resolve(
                prefs,
                "fingerprint-b",
                Instant.parse("2026-08-22T15:00:00Z"),
            ),
        )

        FriendsUploadIdentityStore.acknowledge(prefs, "fingerprint-b")
        val afterAck = FriendsUploadIdentityStore.resolve(
            prefs,
            "fingerprint-b",
            Instant.parse("2026-08-22T16:00:00Z"),
        )
        assertNotEquals(replacement.batchId, afterAck.batchId)
    }

    private class FakeSharedPreferences : SharedPreferences {
        private val values = linkedMapOf<String, Any?>()

        override fun getAll(): MutableMap<String, *> = LinkedHashMap(values)
        override fun getString(key: String, defValue: String?): String? =
            values[key] as? String ?: defValue
        override fun getStringSet(
            key: String,
            defValues: MutableSet<String>?,
        ): MutableSet<String>? {
            @Suppress("UNCHECKED_CAST")
            return values[key] as? MutableSet<String> ?: defValues
        }
        override fun getInt(key: String, defValue: Int): Int =
            values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long =
            values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float =
            values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean =
            values[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = key in values
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit

        private inner class Editor : SharedPreferences.Editor {
            private val pending = linkedMapOf<String, Any?>()
            private val removals = linkedSetOf<String>()
            private var clear = false

            override fun putString(key: String, value: String?) =
                apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) =
                apply { pending[key] = values }
            override fun putInt(key: String, value: Int) =
                apply { pending[key] = value }
            override fun putLong(key: String, value: Long) =
                apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) =
                apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) =
                apply { pending[key] = value }
            override fun remove(key: String) =
                apply { removals += key }
            override fun clear() =
                apply { clear = true }
            override fun commit(): Boolean {
                flush()
                return true
            }
            override fun apply() = flush()

            private fun flush() {
                if (clear) values.clear()
                removals.forEach(values::remove)
                values.putAll(pending)
            }
        }
    }
}
