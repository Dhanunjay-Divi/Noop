package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HydrationReminderPolicyTest {

    @Test fun clampsMinutesAndIntervalsToSafeBounds() {
        assertEquals(0, HydrationReminderPolicy.clampMinuteOfDay(-5))
        assertEquals(1439, HydrationReminderPolicy.clampMinuteOfDay(2_000))
        assertEquals(60, HydrationReminderPolicy.clampIntervalMinutes(5))
        assertEquals(240, HydrationReminderPolicy.clampIntervalMinutes(999))
    }

    @Test fun adaptiveTimingUsesOnlyAvailableEffortAndConfirmedIntake() {
        val plan = HydrationReminderPolicy.adaptivePlan(
            baseIntervalMinutes = 120,
            startMinutes = 8 * 60,
            endMinutes = 21 * 60,
            context = HydrationAdaptiveContext(
                effort = 80.0,
                consumedMl = 300.0,
                goalMl = 2_500,
                minuteOfDay = 14 * 60 + 30,
            ),
        )
        assertEquals(75, plan.intervalMinutes)
        assertEquals(
            listOf(
                HydrationAdaptiveReason.HIGHER_EFFORT,
                HydrationAdaptiveReason.BEHIND_GOAL,
            ),
            plan.reasons,
        )
    }

    @Test fun adaptiveTimingCanEaseWhenConfirmedIntakeIsAhead() {
        val plan = HydrationReminderPolicy.adaptivePlan(
            baseIntervalMinutes = 120,
            startMinutes = 8 * 60,
            endMinutes = 21 * 60,
            context = HydrationAdaptiveContext(
                effort = null,
                consumedMl = 2_000.0,
                goalMl = 2_500,
                minuteOfDay = 12 * 60,
            ),
        )
        assertEquals(135, plan.intervalMinutes)
        assertEquals(listOf(HydrationAdaptiveReason.AHEAD_OF_GOAL), plan.reasons)
    }

    @Test fun adaptiveTimingFallsBackToBaseWhenEvidenceIsMissingOrInvalid() {
        listOf(
            HydrationAdaptiveContext(null, null, null, 12 * 60),
            HydrationAdaptiveContext(Double.NaN, Double.NaN, 0, 12 * 60),
        ).forEach { context ->
            assertEquals(
                HydrationAdaptivePlan(120, emptyList()),
                HydrationReminderPolicy.adaptivePlan(120, 8 * 60, 21 * 60, context),
            )
        }
    }

    @Test fun daytimeSlotsAreStartInclusiveAndEndExclusive() {
        assertEquals(
            listOf(8 * 60, 10 * 60, 12 * 60, 14 * 60, 16 * 60, 18 * 60, 20 * 60),
            HydrationReminderPolicy.slotMinutes(8 * 60, 21 * 60, 120),
        )
    }

    @Test fun overnightAndAllDayWindowsAreSupported() {
        assertEquals(
            listOf(0, 120, 20 * 60, 22 * 60),
            HydrationReminderPolicy.slotMinutes(20 * 60, 4 * 60, 120),
        )
        assertEquals(12, HydrationReminderPolicy.slotMinutes(0, 0, 120).size)
    }

    @Test fun dueSlotUsesGraceAndHandlesPreviousDayAcrossMidnight() {
        val due = HydrationReminderPolicy.latestDueSlot(
            epochDay = 100,
            minuteOfDay = 10,
            startMinutes = 23 * 60 + 55,
            endMinutes = 1 * 60,
            intervalMinutes = 60,
            graceMinutes = 20,
        )
        assertEquals(HydrationReminderSlot(99, 23 * 60 + 55), due)
        assertNull(
            HydrationReminderPolicy.latestDueSlot(
                epochDay = 100,
                minuteOfDay = 30,
                startMinutes = 23 * 60 + 55,
                endMinutes = 1 * 60,
                intervalMinutes = 60,
                graceMinutes = 20,
            ),
        )
    }

    @Test fun nextSlotIsStrictlyFutureAndRollsToTomorrow() {
        assertEquals(
            HydrationReminderSlot(10, 10 * 60),
            HydrationReminderPolicy.nextSlot(10, 9 * 60, 8 * 60, 21 * 60, 120),
        )
        assertEquals(
            HydrationReminderSlot(11, 8 * 60),
            HydrationReminderPolicy.nextSlot(10, 21 * 60, 8 * 60, 21 * 60, 120),
        )
    }

    @Test fun notificationAndStrapLanesDeduplicateIndependently() {
        assertTrue(HydrationReminderPolicy.shouldNotify(true, "10:480", null))
        assertFalse(HydrationReminderPolicy.shouldNotify(true, "10:480", "10:480"))
        assertFalse(HydrationReminderPolicy.shouldNotify(false, "10:480", null))
        assertFalse(
            "An adaptive slot realignment must not double-notify inside one hour",
            HydrationReminderPolicy.shouldNotify(true, "10:510", "10:480"),
        )
        assertTrue(HydrationReminderPolicy.shouldNotify(true, "10:540", "10:480"))

        val allowed = HydrationReminderPolicy.shouldBuzzStrap(
            enabled = true,
            strapBuzzEnabled = true,
            wristAlertsMasterOn = true,
            connected = true,
            bonded = true,
            encryptedBond = true,
            worn = true,
            freshLiveSample = true,
            inQuietHours = false,
            currentSlotKey = "10:480",
            lastBuzzedSlotKey = null,
        )
        assertTrue(allowed)
        assertFalse(
            HydrationReminderPolicy.shouldBuzzStrap(
                true, true, true, true, true, true, true, true, false,
                "10:480", "10:480",
            ),
        )
    }

    @Test fun bandFirstEscalatesOnlyWhenTheTapWindowWasMissed() {
        assertTrue(
            HydrationReminderPolicy.shouldEscalateAfterTapWindow(
                enabled = true,
                bandFirst = true,
                currentSlotKey = "10:480",
                lastConfirmedSlotKey = null,
                lastNotifiedSlotKey = null,
            ),
        )
        assertFalse(
            HydrationReminderPolicy.shouldEscalateAfterTapWindow(
                true, true, "10:480", "10:480", null,
            ),
        )
        assertFalse(
            HydrationReminderPolicy.shouldEscalateAfterTapWindow(
                true, true, "10:480", null, "10:480",
            ),
        )
        assertFalse(
            HydrationReminderPolicy.shouldEscalateAfterTapWindow(
                true, false, "10:480", null, null,
            ),
        )
    }

    @Test fun strapBuzzFailsClosedWithoutAnyTrustGate() {
        val baseline = listOf(true, true, true, true, true, true, true, true, false)
        for (missing in 0..7) {
            val gates = baseline.toMutableList().also { it[missing] = false }
            assertFalse(
                HydrationReminderPolicy.shouldBuzzStrap(
                    enabled = gates[0], strapBuzzEnabled = gates[1], wristAlertsMasterOn = gates[2],
                    connected = gates[3], bonded = gates[4], encryptedBond = gates[5], worn = gates[6],
                    freshLiveSample = gates[7], inQuietHours = gates[8], currentSlotKey = "10:480",
                    lastBuzzedSlotKey = null,
                ),
            )
        }
        assertFalse(
            HydrationReminderPolicy.shouldBuzzStrap(
                true, true, true, true, true, true, true, true, true, "10:480", null,
            ),
        )
    }

    @Test fun lockScreenCopyIsGenericAndContainsNoHealthValues() {
        val (title, body) = HydrationReminderPolicy.notificationCopy()
        val copy = "$title $body"
        assertEquals("Hydration check-in", title)
        listOf("250", "500", "ml", "%", "score", "heart", "HRV").forEach {
            assertFalse(copy.contains(it, ignoreCase = true))
        }
    }
}
