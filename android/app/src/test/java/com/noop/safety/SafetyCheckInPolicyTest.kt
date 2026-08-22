package com.noop.safety

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetyShareMessageTest {
    private val captured = 1_787_395_200L // 2026-08-22T10:40:00Z

    @Test fun needHelpMessageWithValidLocation() {
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.NEED_HELP_NOW,
            displayName = "  Alex\nRiver  ",
            note = "Blue jacket.\nNear the south entrance.",
            location = SafetyLocation(
                latitude = 40.7128,
                longitude = -74.0060,
                horizontalAccuracyMeters = 8.6,
                capturedAtUnix = captured,
            ),
            preparedAtUnix = captured + 60L,
        )

        assertTrue(message, message.startsWith("Alex River: I need help now. Please call me."))
        assertTrue(
            message,
            message.contains("https://www.google.com/maps/search/?api=1&query=40.712800,-74.006000"),
        )
        assertTrue(message, message.contains("accuracy about 9 m"))
        assertTrue(message, message.contains("Note: Blue jacket. Near the south entrance."))
        assertTrue(
            message,
            message.endsWith(
                "NOOP did not send this automatically and does not monitor or contact emergency services.",
            ),
        )
    }

    @Test fun platformSuppliedCopyIsUsedWithoutWeakeningMessageSafety() {
        val copy = SafetyShareCopy(
            needHelpNowOpening = "AYUDA AHORA.",
            feelUnsafeOpening = "NO ESTOY SEGURA.",
            missedCheckInOpening = "FALTÉ A LA CITA.",
            immediateDangerInstruction = "PELIGRO INMEDIATO.",
            locationLabel = "UBICACIÓN",
            locationCapturedFormat = "CAPTURADA %1\$s.",
            locationCapturedAccuracyFormat = "CAPTURADA %1\$s, PRECISIÓN %2\$d M.",
            noteLabel = "NOTA",
            preparedAtFormat = "PREPARADA %1\$s.",
            deliveryBoundary = "BORRADOR MANUAL; SIN ENVÍO AUTOMÁTICO.",
        )
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.NEED_HELP_NOW,
            displayName = "  Ana\nSol  ",
            note = "puerta\u0000\nazul",
            location = SafetyLocation(
                latitude = 40.7128,
                longitude = -74.0060,
                horizontalAccuracyMeters = 8.6,
                capturedAtUnix = captured,
            ),
            preparedAtUnix = captured + 60L,
            copy = copy,
        )

        assertTrue(message, message.startsWith("Ana Sol: AYUDA AHORA.\nPELIGRO INMEDIATO."))
        assertTrue(message, message.contains("UBICACIÓN: https://www.google.com/maps/"))
        assertTrue(
            message,
            message.contains("CAPTURADA ${SafetyShareMessage.utcTimestamp(captured)}, PRECISIÓN 9 M."),
        )
        assertTrue(message, message.contains("NOTA: puerta azul"))
        assertTrue(
            message,
            message.contains("PREPARADA ${SafetyShareMessage.utcTimestamp(captured + 60L)}."),
        )
        assertTrue(message, message.endsWith("BORRADOR MANUAL; SIN ENVÍO AUTOMÁTICO."))
        assertFalse(message, message.contains("I need help now"))
        assertFalse(message, message.contains("\u0000"))
    }

    @Test fun invalidLocationIsOmitted() {
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.FEEL_UNSAFE,
            location = SafetyLocation(95.0, 0.0, capturedAtUnix = captured),
            preparedAtUnix = captured,
        )
        assertFalse(message, message.contains("Location:"))
        assertFalse(message, message.contains("maps"))
    }

    @Test fun nonFiniteLocationIsOmitted() {
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.MISSED_CHECK_IN,
            location = SafetyLocation(Double.NaN, 0.0, capturedAtUnix = captured),
            preparedAtUnix = captured,
        )
        assertFalse(message, message.contains("Location:"))
    }

    @Test fun staleAndFarFutureLocationsAreOmitted() {
        val stale = SafetyLocation(
            latitude = 40.7128,
            longitude = -74.0060,
            capturedAtUnix = captured - SafetyLocation.MAXIMUM_AGE_SECONDS - 1L,
        )
        val future = SafetyLocation(
            latitude = 40.7128,
            longitude = -74.0060,
            capturedAtUnix = captured + SafetyLocation.MAXIMUM_FUTURE_CLOCK_SKEW_SECONDS + 1L,
        )

        assertFalse(stale.isUsable(captured))
        assertFalse(future.isUsable(captured))
        assertFalse(
            SafetyShareMessage.build(
                intent = SafetyShareIntent.FEEL_UNSAFE,
                location = stale,
                preparedAtUnix = captured,
            ).contains("Location:"),
        )
        assertFalse(
            SafetyShareMessage.build(
                intent = SafetyShareIntent.FEEL_UNSAFE,
                location = future,
                preparedAtUnix = captured,
            ).contains("Location:"),
        )
    }

    @Test fun locationFreshnessBoundsAreInclusive() {
        assertTrue(
            SafetyLocation(
                40.7128,
                -74.0060,
                capturedAtUnix = captured - SafetyLocation.MAXIMUM_AGE_SECONDS,
            ).isUsable(captured),
        )
        assertTrue(
            SafetyLocation(
                40.7128,
                -74.0060,
                capturedAtUnix = captured + SafetyLocation.MAXIMUM_FUTURE_CLOCK_SKEW_SECONDS,
            ).isUsable(captured),
        )
        assertFalse(SafetyLocation(40.7128, -74.0060, capturedAtUnix = captured).isUsable(0L))
    }

    @Test fun blankNameAndNoteAreOmitted() {
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.MISSED_CHECK_IN,
            displayName = " \n\t ",
            note = " ",
            preparedAtUnix = captured,
        )
        assertTrue(message, message.startsWith("I missed a planned check-in."))
        assertFalse(message, message.contains("Note:"))
    }

    @Test fun userTextIsCappedAndControlFree() {
        val longName = "a".repeat(SafetyShareMessage.MAX_NAME_CHARACTERS + 20)
        val longNote = "b".repeat(SafetyShareMessage.MAX_NOTE_CHARACTERS + 20)
        val message = SafetyShareMessage.build(
            intent = SafetyShareIntent.NEED_HELP_NOW,
            displayName = longName,
            note = "one\u0000\n$longNote",
            preparedAtUnix = captured,
        )
        assertFalse(message, message.contains("\u0000"))
        assertTrue(
            message,
            message.contains("a".repeat(SafetyShareMessage.MAX_NAME_CHARACTERS) + ":"),
        )
        assertFalse(
            message,
            message.contains("b".repeat(SafetyShareMessage.MAX_NOTE_CHARACTERS + 1)),
        )
    }
}

class SafetyCheckInPolicyTest {
    @Test fun durationClampsToSafeRange() {
        assertEquals(5 * 60L, SafetyCheckInPolicy.clampedDurationSeconds(10L))
        assertEquals(30 * 60L, SafetyCheckInPolicy.clampedDurationSeconds(30 * 60L))
        assertEquals(24 * 60 * 60L, SafetyCheckInPolicy.clampedDurationSeconds(7 * 24 * 60 * 60L))
    }

    @Test fun dueTimestamp() {
        assertEquals(2_800L, SafetyCheckInPolicy.dueAtUnix(1_000L, 30 * 60L))
        assertNull(SafetyCheckInPolicy.dueAtUnix(0L, 30 * 60L))
        assertNull(SafetyCheckInPolicy.dueAtUnix(Long.MAX_VALUE - 10L, 30 * 60L))
    }

    @Test fun stateTransitions() {
        assertEquals(SafetyCheckInState.Inactive, SafetyCheckInPolicy.state(null, 1_000L))
        assertEquals(SafetyCheckInState.Active(2_000L), SafetyCheckInPolicy.state(3_000L, 1_000L))
        assertEquals(SafetyCheckInState.DueSoon(500L), SafetyCheckInPolicy.state(1_500L, 1_000L))
        assertEquals(SafetyCheckInState.Overdue(100L), SafetyCheckInPolicy.state(900L, 1_000L))
        assertEquals(SafetyCheckInState.Overdue(0L), SafetyCheckInPolicy.state(1_000L, 1_000L))
    }

    @Test fun labelsStateNoAutomaticSend() {
        assertEquals(
            "Check-in due in 1h 30m.",
            SafetyCheckInPolicy.statusLabel(SafetyCheckInState.Active(5_400L)),
        )
        assertEquals(
            "Check-in due soon: 5m remaining.",
            SafetyCheckInPolicy.statusLabel(SafetyCheckInState.DueSoon(300L)),
        )
        val overdue = SafetyCheckInPolicy.statusLabel(SafetyCheckInState.Overdue(90L))
        assertEquals("Check-in overdue by 1m. No message was sent automatically.", overdue)
        assertTrue(overdue.contains("No message was sent automatically."))
    }

    @Test fun notificationContainsNoHealthValueOrEmergencyPromise() {
        assertEquals("Personal check-in", SafetyCheckInPolicy.NOTIFICATION_TITLE)
        assertEquals(
            "Your timer ended. Check in with someone you trust if you still need to.",
            SafetyCheckInPolicy.NOTIFICATION_BODY,
        )
        val text = "${SafetyCheckInPolicy.NOTIFICATION_TITLE} ${SafetyCheckInPolicy.NOTIFICATION_BODY}".lowercase()
        assertFalse(text.contains("heart"))
        assertFalse(text.contains("recovery"))
        assertFalse(text.contains("emergency services notified"))
    }
}
