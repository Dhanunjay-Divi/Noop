package com.noop.notif

import com.noop.ui.NoopNotificationRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoWorkoutCandidateNotificationPolicyTest {
    private val token = AutoWorkoutCandidateNotificationPolicy.token(100L, 200L)
    private val kind = AutoWorkoutCandidateNotificationPolicy.Kind.CANDIDATE
    private val deliveryToken = AutoWorkoutCandidateNotificationPolicy.deliveryToken(kind, token)

    @Test
    fun token_isStableAcrossEndpointGrowthAndSpecificToStart() {
        assertEquals("start:100", token)
        assertEquals(token, AutoWorkoutCandidateNotificationPolicy.token(100L, 200L))
        assertEquals(token, AutoWorkoutCandidateNotificationPolicy.token(100L, 201L))
        assertFalse(token == AutoWorkoutCandidateNotificationPolicy.token(101L, 200L))
    }

    @Test
    fun post_requiresOptInExistingAuthorizationAndANewSpan() {
        assertTrue(AutoWorkoutCandidateNotificationPolicy.shouldPost(true, true, kind, token, null))
        assertFalse(AutoWorkoutCandidateNotificationPolicy.shouldPost(false, true, kind, token, null))
        assertFalse(AutoWorkoutCandidateNotificationPolicy.shouldPost(true, false, kind, token, null))
        assertFalse(AutoWorkoutCandidateNotificationPolicy.shouldPost(true, true, kind, token, deliveryToken))
        assertFalse(
            "legacy candidate tokens remain deduped after migration",
            AutoWorkoutCandidateNotificationPolicy.shouldPost(true, true, kind, token, token),
        )
    }

    @Test
    fun failedPost_doesNotConsumeSpanSoNextScanCanRetry() {
        val afterFailure = AutoWorkoutCandidateNotificationPolicy.tokenAfterAttempt(
            previous = null,
            candidateToken = token,
            postedSuccessfully = false,
        )
        assertNull(afterFailure)
        assertTrue(AutoWorkoutCandidateNotificationPolicy.shouldPost(true, true, kind, token, afterFailure))

        val afterSuccess = AutoWorkoutCandidateNotificationPolicy.tokenAfterAttempt(
            previous = afterFailure,
            candidateToken = deliveryToken,
            postedSuccessfully = true,
        )
        assertEquals(deliveryToken, afterSuccess)
        assertFalse(AutoWorkoutCandidateNotificationPolicy.shouldPost(true, true, kind, token, afterSuccess))
    }

    @Test
    fun copyIsPrivacySafeAndTapRouteIsTodayOnly() {
        for (copyKind in AutoWorkoutCandidateNotificationPolicy.Kind.entries) {
            val copy = AutoWorkoutCandidateNotificationPolicy.privacySafeCopy(copyKind)
            val combined = "${copy.title} ${copy.body}".lowercase()
            assertFalse(Regex("""\b\d+\b""").containsMatchIn(combined))
            assertFalse(combined.contains("bpm"))
            assertFalse(combined.contains("heart rate"))
        }
        assertEquals(NoopNotificationRoute.TODAY, NoopNotificationRoute.fromRaw("today"))
        assertEquals(NoopNotificationRoute.WORKOUTS, NoopNotificationRoute.fromRaw("workouts"))
        assertNull(NoopNotificationRoute.fromRaw("https://example.com"))
    }
}
