package com.noop.safety

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FallResponseTest {
    private val eventId = "77ed2bb6-19f5-4ca0-8540-b2398e4a1a11"

    private fun candidate(
        detectedAt: Long = 1_000,
        receivedAt: Long = 1_001,
        sampleRate: Int = 100,
        windowMs: Int = 1_500,
        isWorn: Boolean = true,
        wearAgeMs: Int = 200,
        version: Int = 1,
    ) = FallResponseCandidate(
        eventId = eventId,
        detectorContractVersion = version,
        detectedAtUnix = detectedAt,
        receivedAtUnix = receivedAt,
        motionSampleRateHz = sampleRate,
        motionWindowMilliseconds = windowMs,
        isWorn = isWorn,
        wornEvidenceAgeMilliseconds = wearAgeMs,
    )

    @Test
    fun confirmedHapticStartsFortyFiveSecondResponseWindow() {
        val machine = FallResponseStateMachine()
        val transition = machine.receive(candidate(), 1_002)
        assertEquals(FallCandidateGate.ELIGIBLE, transition.gate)
        assertEquals(
            FallResponseStateMachine.Phase.AwaitingHaptic(eventId, 1_007),
            machine.phase,
        )

        val actions = machine.confirmHaptic(eventId, 1_004)
        assertEquals(
            FallResponseStateMachine.Phase.AwaitingResponse(eventId, 1_049),
            machine.phase,
        )
        assertEquals(
            listOf(
                FallResponseStateMachine.Action.StartResponseCountdown(eventId, 1_049),
                FallResponseStateMachine.Action.ScheduleDeadline(eventId, 1_049),
            ),
            actions,
        )
    }

    @Test
    fun noResponsePagesExactlyOnce() {
        val machine = FallResponseStateMachine()
        machine.receive(candidate(), 1_002)
        machine.confirmHaptic(eventId, 1_004)
        assertTrue(machine.tick(1_048).isEmpty())
        assertEquals(
            FallResponseStateMachine.Action.PageAcceptedContacts(eventId),
            machine.tick(1_049).last(),
        )
        assertTrue(machine.tick(1_060).isEmpty())
    }

    @Test
    fun unconfirmedHapticNeverAutomaticallyPages() {
        val machine = FallResponseStateMachine()
        machine.receive(candidate(), 1_002)
        val actions = machine.tick(1_007)
        assertEquals(
            listOf(
                FallResponseStateMachine.Action.DismissResponsePrompt(eventId),
                FallResponseStateMachine.Action.ShowHapticFailure(eventId),
            ),
            actions,
        )
        assertEquals(
            FallResponseStateMachine.Phase.Resolved(
                eventId,
                FallResponseStateMachine.Outcome.HAPTIC_UNCONFIRMED,
            ),
            machine.phase,
        )
    }

    @Test
    fun staleLowRateOffWristAndUnknownContractCandidatesAreRejected() {
        assertEquals(
            FallCandidateGate.STALE,
            FallResponsePolicy.gate(
                candidate(detectedAt = 989, receivedAt = 990),
                1_002,
            ),
        )
        assertEquals(
            FallCandidateGate.INSUFFICIENT_MOTION,
            FallResponsePolicy.gate(candidate(sampleRate = 25), 1_002),
        )
        assertEquals(
            FallCandidateGate.NOT_WORN,
            FallResponsePolicy.gate(candidate(isWorn = false), 1_002),
        )
        assertEquals(
            FallCandidateGate.STALE_WEAR_EVIDENCE,
            FallResponsePolicy.gate(candidate(wearAgeMs = 2_001), 1_002),
        )
        assertEquals(
            FallCandidateGate.UNSUPPORTED_CONTRACT,
            FallResponsePolicy.gate(candidate(version = 2), 1_002),
        )
    }

    @Test
    fun duplicateCandidateCannotRestartCountdown() {
        val machine = FallResponseStateMachine()
        machine.receive(candidate(), 1_002)
        val duplicate = machine.receive(candidate(), 1_003)
        assertNull(duplicate.gate)
        assertTrue(duplicate.actions.isEmpty())
        assertEquals(
            FallResponseStateMachine.Phase.AwaitingHaptic(eventId, 1_007),
            machine.phase,
        )
    }

    @Test
    fun lateOrMismatchedHapticCannotStartCountdown() {
        val mismatched = FallResponseStateMachine()
        mismatched.receive(candidate(), 1_002)
        assertTrue(mismatched.confirmHaptic("other-event", 1_003).isEmpty())
        assertEquals(
            FallResponseStateMachine.Phase.AwaitingHaptic(eventId, 1_007),
            mismatched.phase,
        )

        val late = FallResponseStateMachine()
        late.receive(candidate(), 1_002)
        assertTrue(late.confirmHaptic(eventId, 1_007).isEmpty())
        assertEquals(
            listOf(
                FallResponseStateMachine.Action.DismissResponsePrompt(eventId),
                FallResponseStateMachine.Action.ShowHapticFailure(eventId),
            ),
            late.tick(1_007),
        )
    }

    @Test
    fun responseDeadlineCannotBeExtendedByDelayedSchedulerTick() {
        val machine = FallResponseStateMachine()
        machine.receive(candidate(), 1_002)
        machine.confirmHaptic(eventId, 1_004)

        assertTrue(machine.acknowledgeOkay(eventId, 1_049).isEmpty())
        assertEquals(
            FallResponseStateMachine.Action.PageAcceptedContacts(eventId),
            machine.tick(1_049).last(),
        )
    }

    @Test
    fun explicitHelpStillPagesAtDeadline() {
        val machine = FallResponseStateMachine()
        machine.receive(candidate(), 1_002)
        machine.confirmHaptic(eventId, 1_004)
        assertEquals(
            FallResponseStateMachine.Action.PageAcceptedContacts(eventId),
            machine.requestHelp(eventId).last(),
        )
        assertTrue(machine.tick(1_049).isEmpty())
    }

    @Test
    fun pageCompletionIsIdempotentAndResetRequiresTerminalState() {
        val machine = FallResponseStateMachine()
        machine.reset()
        assertEquals(FallResponseStateMachine.Phase.Idle, machine.phase)

        machine.receive(candidate(), 1_002)
        machine.requestHelp(eventId)
        assertEquals(
            listOf(FallResponseStateMachine.Action.ShowPageFailure(eventId)),
            machine.completePage(eventId, succeeded = false),
        )
        assertEquals(
            FallResponseStateMachine.Phase.Resolved(
                eventId,
                FallResponseStateMachine.Outcome.PAGE_FAILED,
            ),
            machine.phase,
        )
        assertTrue(machine.completePage(eventId, succeeded = true).isEmpty())

        machine.reset()
        assertEquals(FallResponseStateMachine.Phase.Idle, machine.phase)
    }
}
