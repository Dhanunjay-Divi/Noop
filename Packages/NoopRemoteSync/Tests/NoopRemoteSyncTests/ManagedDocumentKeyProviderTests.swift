import XCTest
@testable import NoopRemoteSync

final class ManagedDocumentKeyProviderTests: XCTestCase {
    private let account = String(repeating: "c", count: 64)

    func testRecoveryEnrollmentGatesUseAndRotationKeepsDocumentKeyID() async throws {
        let storage = InMemoryManagedDocumentKeyVaultStorage()
        let vault = ManagedDocumentKeyVault(storage: storage)
        do {
            _ = try await vault.activeDocumentKey(accountScopeHash: account)
            XCTFail("Expected default-off recovery gate")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentKeyProviderError,
                .recoveryNotEnrolled
            )
        }

        let documentKeyID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let initialMasterKey = Data(repeating: 1, count: 32)
        let initialReceipt = try receipt(
            masterKey: initialMasterKey,
            keyID: UUID(),
            wrappingRevision: 1,
            wrappedKey: Data(repeating: 9, count: 72)
        )
        try await vault.completeRecoveryEnrollment(
            accountScopeHash: account,
            masterKey: initialMasterKey,
            serverReceipt: initialReceipt
        )
        let created = try await vault.createDocumentKey(
            accountScopeHash: account,
            keyID: documentKeyID
        )
        let before = try await vault.wrappedDocumentKeys(
            accountScopeHash: account
        )
        let repeatedBefore = try await vault.wrappedDocumentKeys(
            accountScopeHash: account
        )
        XCTAssertEqual(before, repeatedBefore)
        let rotatedMasterKey = Data(repeating: 2, count: 32)
        let rotatedReceipt = try receipt(
            masterKey: rotatedMasterKey,
            keyID: UUID(),
            wrappingRevision: 2,
            wrappedKey: Data(repeating: 8, count: 72)
        )
        let plan = try await vault.prepareAccountMasterKeyRotation(
            accountScopeHash: account,
            newMasterKey: rotatedMasterKey,
            serverReceipt: rotatedReceipt
        )

        XCTAssertEqual(before.map(\.keyID), [documentKeyID])
        XCTAssertEqual(plan.wrappedDocumentKeys.map(\.keyID), [documentKeyID])
        XCTAssertEqual(
            plan.wrappedDocumentKeys[0].wrappingRevision,
            before[0].wrappingRevision + 1
        )
        let pending = try await vault.pendingAccountMasterKeyRotation(
            accountScopeHash: account
        )
        XCTAssertEqual(pending, plan)
        try await vault.commitAccountMasterKeyRotation(
            accountScopeHash: account,
            planID: plan.planID,
            acknowledgedDocumentKeys: plan.wrappedDocumentKeys
        )
        let committedPending = try await vault.pendingAccountMasterKeyRotation(
            accountScopeHash: account
        )
        XCTAssertNil(committedPending)
        let persisted = try await vault.documentKey(
            accountScopeHash: account,
            keyID: documentKeyID
        )
        XCTAssertEqual(persisted, created)
        let committedWrapped = try await vault.wrappedDocumentKeys(
            accountScopeHash: account
        )
        XCTAssertEqual(committedWrapped, plan.wrappedDocumentKeys)
    }

    func testRevokedKeyCannotDecryptOrBeRecovered() async throws {
        let vault = ManagedDocumentKeyVault(
            storage: InMemoryManagedDocumentKeyVaultStorage()
        )
        let master = Data(repeating: 3, count: 32)
        let keyID = UUID()
        let receipt = try receipt(
            masterKey: master,
            keyID: UUID(),
            wrappingRevision: 1,
            wrappedKey: Data(repeating: 7, count: 72),
            recoveryMethod: "device_transfer"
        )
        try await vault.completeRecoveryEnrollment(
            accountScopeHash: account,
            masterKey: master,
            serverReceipt: receipt
        )
        _ = try await vault.createDocumentKey(
            accountScopeHash: account,
            keyID: keyID
        )
        let wrappedKeys = try await vault.wrappedDocumentKeys(
            accountScopeHash: account
        )
        let wrapped = try XCTUnwrap(wrappedKeys.first)
        try await vault.revokeDocumentKey(
            accountScopeHash: account,
            keyID: keyID
        )

        do {
            _ = try await vault.documentKey(
                accountScopeHash: account,
                keyID: keyID
            )
            XCTFail("Expected revoked key rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentKeyProviderError,
                .keyRevoked
            )
        }
        do {
            try await vault.recoverDocumentKey(
                accountScopeHash: account,
                wrapped: wrapped,
                masterKey: master,
                makeActive: true
            )
            XCTFail("Expected revoked recovery rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentKeyProviderError,
                .keyRevoked
            )
        }
    }

    func testRecoveryReceiptRejectsAnUnrelatedLocalMasterKey() async throws {
        let vault = ManagedDocumentKeyVault(
            storage: InMemoryManagedDocumentKeyVaultStorage()
        )
        let receipt = try receipt(
            masterKey: Data(repeating: 4, count: 32),
            keyID: UUID(),
            wrappingRevision: 1,
            wrappedKey: Data(repeating: 6, count: 72)
        )

        do {
            try await vault.completeRecoveryEnrollment(
                accountScopeHash: account,
                masterKey: Data(repeating: 5, count: 32),
                serverReceipt: receipt
            )
            XCTFail("Expected master-key confirmation rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentKeyProviderError,
                .invalidKey
            )
        }
    }

    private func receipt(
        masterKey: Data,
        keyID: UUID,
        wrappingRevision: Int,
        wrappedKey: Data,
        recoveryMethod: String = "recovery_key"
    ) throws -> ManagedAccountMasterKeyReceipt {
        let wrappedKeySHA256 = ManagedDocumentEnvelopeDigest.sha256(wrappedKey)
        return try ManagedAccountMasterKeyReceipt(
            keyID: keyID,
            wrappingRevision: wrappingRevision,
            wrappedKey: wrappedKey,
            masterKeyConfirmationHMACSHA256:
                ManagedAccountMasterKeyBinding.confirmationHMACSHA256(
                    masterKey: masterKey,
                    accountScopeHash: account,
                    keyID: keyID,
                    wrappingRevision: wrappingRevision,
                    wrappedKeySHA256: wrappedKeySHA256,
                    recoveryMethod: recoveryMethod
                ),
            recoveryMethod: recoveryMethod
        )
    }
}

private final class InMemoryManagedDocumentKeyVaultStorage:
    ManagedDocumentKeyVaultStorage,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(accountScopeHash: String) -> Data? {
        lock.withLock { values[accountScopeHash] }
    }

    func save(_ data: Data, accountScopeHash: String) {
        lock.withLock { values[accountScopeHash] = data }
    }

    func remove(accountScopeHash: String) {
        lock.withLock { _ = values.removeValue(forKey: accountScopeHash) }
    }
}
