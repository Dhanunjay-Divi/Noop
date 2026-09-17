package com.noop.ui

import com.noop.feedback.FeedbackFailureCategory
import com.noop.feedback.FeedbackState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDiagnosticReportDeliveryPolicyTest {
    @Test
    fun actionsStayUnavailableUntilTheStagedReportHasAnIdentity() {
        assertFalse(
            FeedbackDeliveryActionPolicy.canRetry(
                localFeedbackId = null,
                state = FeedbackState.QUEUED,
                actionInProgress = false,
                failureCategory = FeedbackFailureCategory.NONE,
            ),
        )
        assertFalse(
            FeedbackDeliveryActionPolicy.canCancel(
                localFeedbackId = null,
                state = FeedbackState.QUEUED,
                actionInProgress = false,
            ),
        )

        val localId = "11111111-1111-4111-8111-111111111111"
        assertTrue(
            FeedbackDeliveryActionPolicy.canRetry(
                localFeedbackId = localId,
                state = FeedbackState.QUEUED,
                actionInProgress = false,
                failureCategory = FeedbackFailureCategory.NONE,
            ),
        )
        assertTrue(
            FeedbackDeliveryActionPolicy.canCancel(
                localFeedbackId = localId,
                state = FeedbackState.QUEUED,
                actionInProgress = false,
            ),
        )
    }

    @Test
    fun actionsRemainBoundedByProgressAndFailureState() {
        val localId = "11111111-1111-4111-8111-111111111111"

        assertFalse(
            FeedbackDeliveryActionPolicy.canRetry(
                localFeedbackId = localId,
                state = FeedbackState.FAILED,
                actionInProgress = true,
                failureCategory = FeedbackFailureCategory.NETWORK,
            ),
        )
        assertFalse(
            FeedbackDeliveryActionPolicy.canRetry(
                localFeedbackId = localId,
                state = FeedbackState.FAILED,
                actionInProgress = false,
                failureCategory = FeedbackFailureCategory.ARCHIVE_INVALID,
            ),
        )
        assertFalse(
            FeedbackDeliveryActionPolicy.canCancel(
                localFeedbackId = localId,
                state = FeedbackState.CANCEL_FAILED,
                actionInProgress = false,
            ),
        )
    }
}
