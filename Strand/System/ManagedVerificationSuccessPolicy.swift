import Foundation

enum ManagedVerificationSuccessPolicy {
    static let durationNanoseconds: UInt64 = 3_000_000_000

    @MainActor
    static func dismissalTask(
        durationNanoseconds: UInt64 = durationNanoseconds,
        onDismiss: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
