import Foundation

/// Host-side contract for a future validated Noop Band fall detector.
///
/// The phone never derives a fall from delayed history, heart rate, or wellness scores. A candidate
/// must arrive through a versioned live-motion firmware contract. Paging begins only after the band
/// confirms that the warning haptic fired and the response window expires without an acknowledgement.
struct FallResponseCandidate: Equatable, Sendable {
    let eventId: UUID
    let detectorContractVersion: Int
    let detectedAtUnix: Int
    let receivedAtUnix: Int
    let motionSampleRateHz: Int
    let motionWindowMilliseconds: Int
    let isWorn: Bool
    let wornEvidenceAgeMilliseconds: Int
}

enum FallCandidateGate: Equatable, Sendable {
    case eligible
    case unsupportedContract
    case stale
    case futureDated
    case insufficientMotion
    case notWorn
    case staleWearEvidence
}

enum FallResponsePolicy {
    static let supportedDetectorContractVersion = 1
    static let minimumMotionSampleRateHz = 50
    static let minimumMotionWindowMilliseconds = 1_000
    static let maximumWearEvidenceAgeMilliseconds = 2_000
    static let maximumTransportAgeSeconds = 5
    static let maximumFutureSkewSeconds = 2
    static let hapticConfirmationSeconds = 5
    static let responseWindowSeconds = 45

    static func gate(
        _ candidate: FallResponseCandidate,
        nowUnix: Int
    ) -> FallCandidateGate {
        guard candidate.detectorContractVersion == supportedDetectorContractVersion else {
            return .unsupportedContract
        }
        guard candidate.motionSampleRateHz >= minimumMotionSampleRateHz,
              candidate.motionWindowMilliseconds >= minimumMotionWindowMilliseconds
        else {
            return .insufficientMotion
        }
        guard candidate.isWorn else {
            return .notWorn
        }
        guard candidate.wornEvidenceAgeMilliseconds >= 0,
              candidate.wornEvidenceAgeMilliseconds <= maximumWearEvidenceAgeMilliseconds
        else {
            return .staleWearEvidence
        }
        guard candidate.receivedAtUnix <= nowUnix + maximumFutureSkewSeconds,
              candidate.detectedAtUnix <= candidate.receivedAtUnix + maximumFutureSkewSeconds
        else {
            return .futureDated
        }
        guard nowUnix - candidate.receivedAtUnix <= maximumTransportAgeSeconds,
              nowUnix - candidate.detectedAtUnix <= maximumTransportAgeSeconds
        else {
            return .stale
        }
        return .eligible
    }
}

struct FallResponseStateMachine {
    enum Outcome: Equatable, Sendable {
        case userOkay
        case pageSent
        case pageFailed
        case hapticUnconfirmed
    }

    enum Phase: Equatable, Sendable {
        case idle
        case awaitingHaptic(eventId: UUID, deadlineUnix: Int)
        case awaitingResponse(eventId: UUID, deadlineUnix: Int)
        case paging(eventId: UUID)
        case resolved(eventId: UUID, outcome: Outcome)
    }

    enum Action: Equatable, Sendable {
        case requestStrongBandHaptic(eventId: UUID)
        case presentResponsePrompt(eventId: UUID)
        case scheduleDeadline(eventId: UUID, unix: Int)
        case startResponseCountdown(eventId: UUID, deadlineUnix: Int)
        case stopBandHaptic(eventId: UUID)
        case dismissResponsePrompt(eventId: UUID)
        case pageAcceptedContacts(eventId: UUID)
        case showHapticFailure(eventId: UUID)
        case showPageFailure(eventId: UUID)
    }

    struct Transition: Equatable, Sendable {
        let gate: FallCandidateGate?
        let actions: [Action]
    }

    private(set) var phase: Phase = .idle

    mutating func receive(
        _ candidate: FallResponseCandidate,
        nowUnix: Int
    ) -> Transition {
        guard case .idle = phase else {
            return Transition(gate: nil, actions: [])
        }
        let gate = FallResponsePolicy.gate(candidate, nowUnix: nowUnix)
        guard gate == .eligible else {
            return Transition(gate: gate, actions: [])
        }
        let deadline = nowUnix + FallResponsePolicy.hapticConfirmationSeconds
        phase = .awaitingHaptic(eventId: candidate.eventId, deadlineUnix: deadline)
        return Transition(
            gate: .eligible,
            actions: [
                .requestStrongBandHaptic(eventId: candidate.eventId),
                .presentResponsePrompt(eventId: candidate.eventId),
                .scheduleDeadline(eventId: candidate.eventId, unix: deadline),
            ]
        )
    }

    mutating func confirmHaptic(eventId: UUID, nowUnix: Int) -> [Action] {
        guard case .awaitingHaptic(let activeId, let hapticDeadline) = phase,
              activeId == eventId,
              nowUnix < hapticDeadline
        else { return [] }
        let responseDeadline = nowUnix + FallResponsePolicy.responseWindowSeconds
        phase = .awaitingResponse(eventId: eventId, deadlineUnix: responseDeadline)
        return [
            .startResponseCountdown(eventId: eventId, deadlineUnix: responseDeadline),
            .scheduleDeadline(eventId: eventId, unix: responseDeadline),
        ]
    }

    mutating func acknowledgeOkay(eventId: UUID, nowUnix: Int) -> [Action] {
        guard activeEventId == eventId else { return [] }
        switch phase {
        case .awaitingHaptic:
            break
        case .awaitingResponse(_, let deadline) where nowUnix < deadline:
            break
        default:
            return []
        }
        phase = .resolved(eventId: eventId, outcome: .userOkay)
        return [
            .stopBandHaptic(eventId: eventId),
            .dismissResponsePrompt(eventId: eventId),
        ]
    }

    /// An explicit "Get help" action pages immediately, even if the haptic acknowledgement has not
    /// arrived. This is user intent, not an automatic inference.
    mutating func requestHelp(eventId: UUID) -> [Action] {
        guard activeEventId == eventId, isWaitingForResponse else { return [] }
        phase = .paging(eventId: eventId)
        return [
            .stopBandHaptic(eventId: eventId),
            .dismissResponsePrompt(eventId: eventId),
            .pageAcceptedContacts(eventId: eventId),
        ]
    }

    mutating func tick(nowUnix: Int) -> [Action] {
        switch phase {
        case .awaitingHaptic(let eventId, let deadline) where nowUnix >= deadline:
            phase = .resolved(eventId: eventId, outcome: .hapticUnconfirmed)
            return [
                .dismissResponsePrompt(eventId: eventId),
                .showHapticFailure(eventId: eventId),
            ]
        case .awaitingResponse(let eventId, let deadline) where nowUnix >= deadline:
            phase = .paging(eventId: eventId)
            return [
                .stopBandHaptic(eventId: eventId),
                .dismissResponsePrompt(eventId: eventId),
                .pageAcceptedContacts(eventId: eventId),
            ]
        default:
            return []
        }
    }

    mutating func completePage(eventId: UUID, succeeded: Bool) -> [Action] {
        guard case .paging(let activeId) = phase, activeId == eventId else { return [] }
        phase = .resolved(
            eventId: eventId,
            outcome: succeeded ? .pageSent : .pageFailed
        )
        return succeeded ? [] : [.showPageFailure(eventId: eventId)]
    }

    mutating func reset() {
        guard case .resolved = phase else { return }
        phase = .idle
    }

    private var activeEventId: UUID? {
        switch phase {
        case .awaitingHaptic(let eventId, _), .awaitingResponse(let eventId, _):
            return eventId
        case .paging(let eventId), .resolved(let eventId, _):
            return eventId
        case .idle:
            return nil
        }
    }

    private var isWaitingForResponse: Bool {
        switch phase {
        case .awaitingHaptic, .awaitingResponse:
            return true
        case .idle, .paging, .resolved:
            return false
        }
    }
}
