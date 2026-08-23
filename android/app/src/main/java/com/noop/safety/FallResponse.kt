package com.noop.safety

/**
 * Host-side contract for a future validated Noop Band fall detector.
 *
 * Delayed history, heart rate, and wellness scores can never create a candidate. Paging starts only
 * after a versioned live-motion event, a confirmed warning haptic, and an unanswered response window.
 */
data class FallResponseCandidate(
    val eventId: String,
    val detectorContractVersion: Int,
    val detectedAtUnix: Long,
    val receivedAtUnix: Long,
    val motionSampleRateHz: Int,
    val motionWindowMilliseconds: Int,
    val isWorn: Boolean,
    val wornEvidenceAgeMilliseconds: Int,
)

enum class FallCandidateGate {
    ELIGIBLE,
    UNSUPPORTED_CONTRACT,
    STALE,
    FUTURE_DATED,
    INSUFFICIENT_MOTION,
    NOT_WORN,
    STALE_WEAR_EVIDENCE,
}

object FallResponsePolicy {
    const val SUPPORTED_DETECTOR_CONTRACT_VERSION = 1
    const val MINIMUM_MOTION_SAMPLE_RATE_HZ = 50
    const val MINIMUM_MOTION_WINDOW_MILLISECONDS = 1_000
    const val MAXIMUM_WEAR_EVIDENCE_AGE_MILLISECONDS = 2_000
    const val MAXIMUM_TRANSPORT_AGE_SECONDS = 5L
    const val MAXIMUM_FUTURE_SKEW_SECONDS = 2L
    const val HAPTIC_CONFIRMATION_SECONDS = 5L
    const val RESPONSE_WINDOW_SECONDS = 45L

    fun gate(candidate: FallResponseCandidate, nowUnix: Long): FallCandidateGate {
        if (candidate.detectorContractVersion != SUPPORTED_DETECTOR_CONTRACT_VERSION) {
            return FallCandidateGate.UNSUPPORTED_CONTRACT
        }
        if (candidate.motionSampleRateHz < MINIMUM_MOTION_SAMPLE_RATE_HZ ||
            candidate.motionWindowMilliseconds < MINIMUM_MOTION_WINDOW_MILLISECONDS
        ) {
            return FallCandidateGate.INSUFFICIENT_MOTION
        }
        if (!candidate.isWorn) {
            return FallCandidateGate.NOT_WORN
        }
        if (candidate.wornEvidenceAgeMilliseconds !in
            0..MAXIMUM_WEAR_EVIDENCE_AGE_MILLISECONDS
        ) {
            return FallCandidateGate.STALE_WEAR_EVIDENCE
        }
        if (candidate.receivedAtUnix > nowUnix + MAXIMUM_FUTURE_SKEW_SECONDS ||
            candidate.detectedAtUnix >
            candidate.receivedAtUnix + MAXIMUM_FUTURE_SKEW_SECONDS
        ) {
            return FallCandidateGate.FUTURE_DATED
        }
        if (nowUnix - candidate.receivedAtUnix > MAXIMUM_TRANSPORT_AGE_SECONDS ||
            nowUnix - candidate.detectedAtUnix > MAXIMUM_TRANSPORT_AGE_SECONDS
        ) {
            return FallCandidateGate.STALE
        }
        return FallCandidateGate.ELIGIBLE
    }
}

class FallResponseStateMachine {
    enum class Outcome { USER_OKAY, PAGE_SENT, PAGE_FAILED, HAPTIC_UNCONFIRMED }

    sealed interface Phase {
        data object Idle : Phase
        data class AwaitingHaptic(val eventId: String, val deadlineUnix: Long) : Phase
        data class AwaitingResponse(val eventId: String, val deadlineUnix: Long) : Phase
        data class Paging(val eventId: String) : Phase
        data class Resolved(val eventId: String, val outcome: Outcome) : Phase
    }

    sealed interface Action {
        data class RequestStrongBandHaptic(val eventId: String) : Action
        data class PresentResponsePrompt(val eventId: String) : Action
        data class ScheduleDeadline(val eventId: String, val unix: Long) : Action
        data class StartResponseCountdown(
            val eventId: String,
            val deadlineUnix: Long,
        ) : Action
        data class StopBandHaptic(val eventId: String) : Action
        data class DismissResponsePrompt(val eventId: String) : Action
        data class PageAcceptedContacts(val eventId: String) : Action
        data class ShowHapticFailure(val eventId: String) : Action
        data class ShowPageFailure(val eventId: String) : Action
    }

    data class Transition(
        val gate: FallCandidateGate?,
        val actions: List<Action>,
    )

    var phase: Phase = Phase.Idle
        private set

    fun receive(candidate: FallResponseCandidate, nowUnix: Long): Transition {
        if (phase !is Phase.Idle) return Transition(null, emptyList())
        val gate = FallResponsePolicy.gate(candidate, nowUnix)
        if (gate != FallCandidateGate.ELIGIBLE) return Transition(gate, emptyList())
        val deadline = nowUnix + FallResponsePolicy.HAPTIC_CONFIRMATION_SECONDS
        phase = Phase.AwaitingHaptic(candidate.eventId, deadline)
        return Transition(
            gate,
            listOf(
                Action.RequestStrongBandHaptic(candidate.eventId),
                Action.PresentResponsePrompt(candidate.eventId),
                Action.ScheduleDeadline(candidate.eventId, deadline),
            ),
        )
    }

    fun confirmHaptic(eventId: String, nowUnix: Long): List<Action> {
        val current = phase as? Phase.AwaitingHaptic ?: return emptyList()
        if (current.eventId != eventId || nowUnix >= current.deadlineUnix) return emptyList()
        val deadline = nowUnix + FallResponsePolicy.RESPONSE_WINDOW_SECONDS
        phase = Phase.AwaitingResponse(eventId, deadline)
        return listOf(
            Action.StartResponseCountdown(eventId, deadline),
            Action.ScheduleDeadline(eventId, deadline),
        )
    }

    fun acknowledgeOkay(eventId: String, nowUnix: Long): List<Action> {
        if (activeEventId() != eventId) return emptyList()
        val canAcknowledge = when (val current = phase) {
            is Phase.AwaitingHaptic -> true
            is Phase.AwaitingResponse -> nowUnix < current.deadlineUnix
            else -> false
        }
        if (!canAcknowledge) return emptyList()
        phase = Phase.Resolved(eventId, Outcome.USER_OKAY)
        return listOf(
            Action.StopBandHaptic(eventId),
            Action.DismissResponsePrompt(eventId),
        )
    }

    fun requestHelp(eventId: String): List<Action> {
        if (activeEventId() != eventId || !isWaitingForResponse()) return emptyList()
        phase = Phase.Paging(eventId)
        return listOf(
            Action.StopBandHaptic(eventId),
            Action.DismissResponsePrompt(eventId),
            Action.PageAcceptedContacts(eventId),
        )
    }

    fun tick(nowUnix: Long): List<Action> {
        return when (val current = phase) {
            is Phase.AwaitingHaptic -> {
                if (nowUnix < current.deadlineUnix) return emptyList()
                phase = Phase.Resolved(current.eventId, Outcome.HAPTIC_UNCONFIRMED)
                listOf(
                    Action.DismissResponsePrompt(current.eventId),
                    Action.ShowHapticFailure(current.eventId),
                )
            }
            is Phase.AwaitingResponse -> {
                if (nowUnix < current.deadlineUnix) return emptyList()
                phase = Phase.Paging(current.eventId)
                listOf(
                    Action.StopBandHaptic(current.eventId),
                    Action.DismissResponsePrompt(current.eventId),
                    Action.PageAcceptedContacts(current.eventId),
                )
            }
            else -> emptyList()
        }
    }

    fun completePage(eventId: String, succeeded: Boolean): List<Action> {
        val current = phase as? Phase.Paging ?: return emptyList()
        if (current.eventId != eventId) return emptyList()
        phase = Phase.Resolved(
            eventId,
            if (succeeded) Outcome.PAGE_SENT else Outcome.PAGE_FAILED,
        )
        return if (succeeded) emptyList() else listOf(Action.ShowPageFailure(eventId))
    }

    fun reset() {
        if (phase is Phase.Resolved) phase = Phase.Idle
    }

    private fun activeEventId(): String? = when (val current = phase) {
        is Phase.AwaitingHaptic -> current.eventId
        is Phase.AwaitingResponse -> current.eventId
        is Phase.Paging -> current.eventId
        is Phase.Resolved -> current.eventId
        Phase.Idle -> null
    }

    private fun isWaitingForResponse(): Boolean =
        phase is Phase.AwaitingHaptic || phase is Phase.AwaitingResponse
}
