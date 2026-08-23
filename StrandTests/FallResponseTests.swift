import XCTest
@testable import Strand

final class FallResponseTests: XCTestCase {
    private let eventId = UUID(uuidString: "77ED2BB6-19F5-4CA0-8540-B2398E4A1A11")!

    private func candidate(
        detectedAt: Int = 1_000,
        receivedAt: Int = 1_001,
        sampleRate: Int = 100,
        windowMs: Int = 1_500,
        isWorn: Bool = true,
        wearAgeMs: Int = 200,
        version: Int = 1
    ) -> FallResponseCandidate {
        FallResponseCandidate(
            eventId: eventId,
            detectorContractVersion: version,
            detectedAtUnix: detectedAt,
            receivedAtUnix: receivedAt,
            motionSampleRateHz: sampleRate,
            motionWindowMilliseconds: windowMs,
            isWorn: isWorn,
            wornEvidenceAgeMilliseconds: wearAgeMs
        )
    }

    func testQualifiedCandidateWaitsForConfirmedHapticBeforeCountdown() {
        var machine = FallResponseStateMachine()
        let transition = machine.receive(candidate(), nowUnix: 1_002)

        XCTAssertEqual(transition.gate, .eligible)
        XCTAssertEqual(
            machine.phase,
            .awaitingHaptic(eventId: eventId, deadlineUnix: 1_007)
        )
        XCTAssertEqual(
            transition.actions,
            [
                .requestStrongBandHaptic(eventId: eventId),
                .presentResponsePrompt(eventId: eventId),
                .scheduleDeadline(eventId: eventId, unix: 1_007),
            ]
        )

        let actions = machine.confirmHaptic(eventId: eventId, nowUnix: 1_004)
        XCTAssertEqual(
            machine.phase,
            .awaitingResponse(eventId: eventId, deadlineUnix: 1_049)
        )
        XCTAssertEqual(
            actions,
            [
                .startResponseCountdown(eventId: eventId, deadlineUnix: 1_049),
                .scheduleDeadline(eventId: eventId, unix: 1_049),
            ]
        )
    }

    func testNoResponseAfterConfirmedHapticPagesExactlyOnce() {
        var machine = FallResponseStateMachine()
        _ = machine.receive(candidate(), nowUnix: 1_002)
        _ = machine.confirmHaptic(eventId: eventId, nowUnix: 1_004)

        XCTAssertEqual(machine.tick(nowUnix: 1_048), [])
        XCTAssertEqual(
            machine.tick(nowUnix: 1_049),
            [
                .stopBandHaptic(eventId: eventId),
                .dismissResponsePrompt(eventId: eventId),
                .pageAcceptedContacts(eventId: eventId),
            ]
        )
        XCTAssertEqual(machine.tick(nowUnix: 1_060), [])
        XCTAssertEqual(machine.phase, .paging(eventId: eventId))
    }

    func testUnconfirmedHapticFailsClosedWithoutAutomaticPage() {
        var machine = FallResponseStateMachine()
        _ = machine.receive(candidate(), nowUnix: 1_002)

        XCTAssertEqual(
            machine.tick(nowUnix: 1_007),
            [
                .dismissResponsePrompt(eventId: eventId),
                .showHapticFailure(eventId: eventId),
            ]
        )
        XCTAssertEqual(
            machine.phase,
            .resolved(eventId: eventId, outcome: .hapticUnconfirmed)
        )
    }

    func testUserCanCancelOrRequestHelpFromEitherWaitingPhase() {
        var okay = FallResponseStateMachine()
        _ = okay.receive(candidate(), nowUnix: 1_002)
        XCTAssertEqual(
            okay.acknowledgeOkay(eventId: eventId, nowUnix: 1_003),
            [
                .stopBandHaptic(eventId: eventId),
                .dismissResponsePrompt(eventId: eventId),
            ]
        )
        XCTAssertEqual(okay.phase, .resolved(eventId: eventId, outcome: .userOkay))

        var help = FallResponseStateMachine()
        _ = help.receive(candidate(), nowUnix: 1_002)
        XCTAssertEqual(
            help.requestHelp(eventId: eventId).last,
            .pageAcceptedContacts(eventId: eventId)
        )
        XCTAssertEqual(help.phase, .paging(eventId: eventId))
    }

    func testLateOrMismatchedHapticCannotStartCountdown() {
        let otherId = UUID()

        var mismatched = FallResponseStateMachine()
        _ = mismatched.receive(candidate(), nowUnix: 1_002)
        XCTAssertEqual(
            mismatched.confirmHaptic(eventId: otherId, nowUnix: 1_003),
            []
        )
        XCTAssertEqual(
            mismatched.phase,
            .awaitingHaptic(eventId: eventId, deadlineUnix: 1_007)
        )

        var late = FallResponseStateMachine()
        _ = late.receive(candidate(), nowUnix: 1_002)
        XCTAssertEqual(
            late.confirmHaptic(eventId: eventId, nowUnix: 1_007),
            []
        )
        XCTAssertEqual(
            late.tick(nowUnix: 1_007),
            [
                .dismissResponsePrompt(eventId: eventId),
                .showHapticFailure(eventId: eventId),
            ]
        )
    }

    func testResponseDeadlineCannotBeExtendedByDelayedSchedulerTick() {
        var machine = FallResponseStateMachine()
        _ = machine.receive(candidate(), nowUnix: 1_002)
        _ = machine.confirmHaptic(eventId: eventId, nowUnix: 1_004)

        XCTAssertEqual(
            machine.acknowledgeOkay(eventId: eventId, nowUnix: 1_049),
            []
        )
        XCTAssertEqual(
            machine.tick(nowUnix: 1_049).last,
            .pageAcceptedContacts(eventId: eventId)
        )
    }

    func testExplicitHelpStillPagesAtDeadline() {
        var machine = FallResponseStateMachine()
        _ = machine.receive(candidate(), nowUnix: 1_002)
        _ = machine.confirmHaptic(eventId: eventId, nowUnix: 1_004)

        XCTAssertEqual(
            machine.requestHelp(eventId: eventId).last,
            .pageAcceptedContacts(eventId: eventId)
        )
        XCTAssertEqual(machine.tick(nowUnix: 1_049), [])
    }

    func testPageCompletionIsIdempotentAndResetRequiresTerminalState() {
        var machine = FallResponseStateMachine()
        machine.reset()
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.receive(candidate(), nowUnix: 1_002)
        _ = machine.requestHelp(eventId: eventId)
        XCTAssertEqual(
            machine.completePage(eventId: eventId, succeeded: false),
            [.showPageFailure(eventId: eventId)]
        )
        XCTAssertEqual(
            machine.phase,
            .resolved(eventId: eventId, outcome: .pageFailed)
        )
        XCTAssertEqual(machine.completePage(eventId: eventId, succeeded: true), [])

        machine.reset()
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStaleLowRateOffWristAndUnknownContractCandidatesAreRejected() {
        XCTAssertEqual(
            FallResponsePolicy.gate(
                candidate(detectedAt: 989, receivedAt: 990),
                nowUnix: 1_002
            ),
            .stale
        )
        XCTAssertEqual(
            FallResponsePolicy.gate(candidate(sampleRate: 25), nowUnix: 1_002),
            .insufficientMotion
        )
        XCTAssertEqual(
            FallResponsePolicy.gate(candidate(isWorn: false), nowUnix: 1_002),
            .notWorn
        )
        XCTAssertEqual(
            FallResponsePolicy.gate(candidate(wearAgeMs: 2_001), nowUnix: 1_002),
            .staleWearEvidence
        )
        XCTAssertEqual(
            FallResponsePolicy.gate(candidate(version: 2), nowUnix: 1_002),
            .unsupportedContract
        )
    }

    func testDuplicateOrConcurrentCandidateCannotRestartCountdown() {
        var machine = FallResponseStateMachine()
        _ = machine.receive(candidate(), nowUnix: 1_002)
        let duplicate = machine.receive(candidate(), nowUnix: 1_003)
        XCTAssertNil(duplicate.gate)
        XCTAssertTrue(duplicate.actions.isEmpty)
        XCTAssertEqual(
            machine.phase,
            .awaitingHaptic(eventId: eventId, deadlineUnix: 1_007)
        )
    }
}
