public enum ManagedAuthenticationRetry {
    /// Replays one idempotent managed-storage operation after refreshing both Firebase credentials.
    ///
    /// The caller owns the operation's durable checkpoints. This helper deliberately retries only
    /// authentication failures and only once; policy, quota, integrity, and transport failures retain
    /// their original behavior.
    public static func run<Result>(
        authorization: (_ forceRefresh: Bool) async throws -> ManagedAuthorization,
        operation: (_ authorization: ManagedAuthorization) async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation(authorization(false))
        } catch ManagedStorageError.authentication {
            return try await operation(authorization(true))
        }
    }
}
