import Foundation

/// Pure scheduling state for post-backfill analysis.
///
/// The first durable commit is handled quickly. Later commits use a quiet-edge delay, capped by a
/// maximum interval so a continuously arriving history stream cannot postpone dashboard metrics forever.
/// Only one revision may be in flight; commits that arrive during analysis remain pending.
struct PersistedHistoryRefreshSchedule {
    struct Claim: Equatable {
        let revision: UInt64
    }

    let initialDelay: TimeInterval
    let quietDelay: TimeInterval
    let maximumContinuousDelay: TimeInterval

    private(set) var latestRevision: UInt64 = 0
    private(set) var completedRevision: UInt64 = 0
    private(set) var inFlightRevision: UInt64?
    private(set) var firstPendingAt: TimeInterval?
    private(set) var lastCommitAt: TimeInterval?
    private(set) var lastCompletedAt: TimeInterval?

    init(
        initialDelay: TimeInterval = 0.75,
        quietDelay: TimeInterval = 2,
        maximumContinuousDelay: TimeInterval = 30
    ) {
        precondition(initialDelay >= 0)
        precondition(quietDelay >= 0)
        precondition(maximumContinuousDelay > 0)
        self.initialDelay = initialDelay
        self.quietDelay = quietDelay
        self.maximumContinuousDelay = maximumContinuousDelay
    }

    @discardableResult
    mutating func noteCommit(revision: UInt64, at now: TimeInterval) -> TimeInterval? {
        guard revision > latestRevision else { return nextDeadline }
        let alreadyRepresented = max(completedRevision, inFlightRevision ?? 0)
        latestRevision = revision
        lastCommitAt = now
        if revision > alreadyRepresented, firstPendingAt == nil {
            firstPendingAt = now
        }
        return nextDeadline
    }

    var nextDeadline: TimeInterval? {
        guard inFlightRevision == nil, latestRevision > completedRevision,
              let firstPendingAt, let lastCommitAt else { return nil }
        guard let lastCompletedAt else {
            return firstPendingAt + initialDelay
        }
        return min(
            lastCommitAt + quietDelay,
            lastCompletedAt + maximumContinuousDelay
        )
    }

    mutating func claimIfDue(at now: TimeInterval) -> Claim? {
        guard let deadline = nextDeadline, now >= deadline else { return nil }
        let claim = Claim(revision: latestRevision)
        inFlightRevision = claim.revision
        firstPendingAt = nil
        return claim
    }

    @discardableResult
    mutating func complete(_ claim: Claim, at now: TimeInterval) -> TimeInterval? {
        precondition(inFlightRevision == claim.revision)
        completedRevision = max(completedRevision, claim.revision)
        inFlightRevision = nil
        lastCompletedAt = now
        if latestRevision > completedRevision, firstPendingAt == nil {
            firstPendingAt = lastCommitAt ?? now
        }
        return nextDeadline
    }
}

/// Main-actor owner for the pure schedule. Timer replacement is safe because every replacement remains
/// capped by `maximumContinuousDelay`; the operation itself is serialized by the schedule's in-flight claim.
@MainActor
final class PersistedHistoryRefreshWorker {
    typealias Operation = @MainActor () async -> Void

    private var schedule: PersistedHistoryRefreshSchedule
    private let operation: Operation
    private var wakeTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(
        schedule: PersistedHistoryRefreshSchedule = PersistedHistoryRefreshSchedule(),
        operation: @escaping Operation
    ) {
        self.schedule = schedule
        self.operation = operation
    }

    deinit {
        wakeTask?.cancel()
        operationTask?.cancel()
    }

    func noteCommit(revision: UInt64) {
        arm(deadline: schedule.noteCommit(revision: revision, at: now))
    }

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func arm(deadline: TimeInterval?) {
        wakeTask?.cancel()
        wakeTask = nil
        guard let deadline else { return }
        let delay = max(0, deadline - now)
        let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
        wakeTask = Task { @MainActor [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.wake()
        }
    }

    private func wake() {
        wakeTask = nil
        guard let claim = schedule.claimIfDue(at: now) else {
            arm(deadline: schedule.nextDeadline)
            return
        }
        let operation = self.operation
        operationTask = Task { @MainActor [weak self] in
            await operation()
            guard !Task.isCancelled else { return }
            self?.didComplete(claim)
        }
    }

    private func didComplete(_ claim: PersistedHistoryRefreshSchedule.Claim) {
        operationTask = nil
        arm(deadline: schedule.complete(claim, at: now))
    }
}
