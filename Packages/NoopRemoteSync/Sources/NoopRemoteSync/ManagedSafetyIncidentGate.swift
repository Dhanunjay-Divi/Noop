import Foundation

@MainActor
public final class ManagedSafetyIncidentGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    public init() {}

    public func acquire() async throws {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }

        guard !Task.isCancelled else {
            release()
            throw CancellationError()
        }
    }

    public func release() {
        guard isHeld else { return }
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    var waitingCount: Int {
        waiters.count
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
