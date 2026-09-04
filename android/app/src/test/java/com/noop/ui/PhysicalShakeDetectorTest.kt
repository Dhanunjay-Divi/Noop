package com.noop.ui

import android.hardware.SensorManager
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhysicalShakeDetectorTest {
    @Test fun requiresStrongImpulseAndDebouncesRepeatedSamples() {
        val detector = PhysicalShakeDetector()
        assertFalse(
            detector.sample(
                0f,
                0f,
                SensorManager.GRAVITY_EARTH,
                nowMs = 1_000L,
            ),
        )
        assertTrue(
            detector.sample(
                SensorManager.GRAVITY_EARTH * 3f,
                0f,
                0f,
                nowMs = 2_000L,
            ),
        )
        assertFalse(
            detector.sample(
                SensorManager.GRAVITY_EARTH * 3f,
                0f,
                0f,
                nowMs = 2_500L,
            ),
        )
        assertTrue(
            detector.sample(
                SensorManager.GRAVITY_EARTH * 3f,
                0f,
                0f,
                nowMs = 4_100L,
            ),
        )
    }
}
