package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinuousHrvOvernightDefaultTest {
    @Test fun onlyLegacyUnchosenInstallIsPinned() {
        assertTrue(NoopPrefs.shouldPinLegacyOvernightDefault(false, true))
        assertFalse(NoopPrefs.shouldPinLegacyOvernightDefault(false, false))
        assertFalse(NoopPrefs.shouldPinLegacyOvernightDefault(true, true))
        assertFalse(NoopPrefs.shouldPinLegacyOvernightDefault(true, false))
    }
}
