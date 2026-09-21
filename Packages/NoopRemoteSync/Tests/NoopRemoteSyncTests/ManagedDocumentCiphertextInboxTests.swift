import XCTest
@testable import NoopRemoteSync

final class ManagedDocumentCiphertextInboxTests: XCTestCase {
    private let firstAccount = String(repeating: "a", count: 64)
    private let secondAccount = String(repeating: "b", count: 64)

    func testIncomingAndOutgoingCiphertextSurviveRestart() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ManagedDocumentGoldenFixture.load().document
        let document = try makeIncomingDocument(fixture: fixture)
        let first = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: fixture.accountScopeHash
        )
        try await first.stageIncoming(
            accountScopeHash: fixture.accountScopeHash,
            document: document
        )
        let firstIncomingCount = try await first.pendingIncomingCount()
        XCTAssertEqual(firstIncomingCount, 1)

        let restarted = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: fixture.accountScopeHash
        )
        let restartedIncomingCount = try await restarted.pendingIncomingCount()
        XCTAssertEqual(restartedIncomingCount, 1)
        let key = try ManagedDocumentKey(
            keyID: UUID(uuidString: fixture.keyID)!,
            keyData: Data(managedHex: fixture.keyHex)!
        )
        let plaintext = Data(base64Encoded: fixture.plaintextBase64)!
        let firstOutgoing = try await restarted.outgoingEnvelope(
            accountScopeHash: fixture.accountScopeHash,
            localIdentifier: "local-row",
            generation: 2,
            documentKind: .journal,
            documentID: document.documentID,
            revision: document.revision,
            key: key,
            plaintext: plaintext
        )
        let secondOutgoing = try await ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: fixture.accountScopeHash
        ).outgoingEnvelope(
            accountScopeHash: fixture.accountScopeHash,
            localIdentifier: "local-row",
            generation: 2,
            documentKind: .journal,
            documentID: document.documentID,
            revision: document.revision,
            key: key,
            plaintext: plaintext
        )
        XCTAssertEqual(firstOutgoing, secondOutgoing)
        let restartedOutgoingCount = try await restarted.pendingOutgoingCount()
        XCTAssertEqual(restartedOutgoingCount, 1)
        do {
            _ = try await restarted.outgoingEnvelope(
                accountScopeHash: fixture.accountScopeHash,
                localIdentifier: "local-row",
                generation: 2,
                documentKind: .journal,
                documentID: document.documentID,
                revision: document.revision,
                key: key,
                plaintext: plaintext + Data([0])
            )
            XCTFail("Expected stale outbound ciphertext rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentCiphertextInboxError,
                .invalidRecord
            )
        }

        try await restarted.removeIncoming(
            accountScopeHash: fixture.accountScopeHash,
            document: document
        )
        try await restarted.removeOutgoing(
            accountScopeHash: fixture.accountScopeHash,
            localIdentifier: "local-row",
            generation: 2,
            revision: document.revision
        )
        let finalIncomingCount = try await restarted.pendingIncomingCount()
        let finalOutgoingCount = try await restarted.pendingOutgoingCount()
        XCTAssertEqual(finalIncomingCount, 0)
        XCTAssertEqual(finalOutgoingCount, 0)
    }

    func testOutgoingCiphertextSurvivesAgeSweepUntilAcknowledged()
        async throws
    {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ManagedDocumentCiphertextInboxPolicy(
            maximumRecordCount: 4,
            maximumTotalBytes: 1_024 * 1_024,
            maximumAgeMilliseconds: 10
        )
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 3, count: 32)
        )
        let documentID = UUID()
        let first = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount,
            policy: policy,
            clock: { 1 }
        )
        let ciphertext = try await first.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "age-protected",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("pending upload".utf8)
        )

        let restarted = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount,
            policy: policy,
            clock: { 11 }
        )
        let pendingCount = try await restarted.pendingOutgoingCount()
        let replayed = try await restarted.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "age-protected",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("pending upload".utf8)
        )
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(replayed, ciphertext)
    }

    func testOutgoingCiphertextSurvivesWallClockRollback()
        async throws
    {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 4, count: 32)
        )
        let documentID = UUID()
        let first = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount,
            clock: { 10_000 }
        )
        let ciphertext = try await first.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "clock-protected",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("pending after clock correction".utf8)
        )

        let restarted = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount,
            clock: { 1_000 }
        )
        let pendingCount = try await restarted.pendingOutgoingCount()
        let replayed = try await restarted.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "clock-protected",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("pending after clock correction".utf8)
        )
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(replayed, ciphertext)
    }

    func testReconcileRemovesOnlyAcknowledgedOutgoingOrphans()
        async throws
    {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 8, count: 32)
        )
        let inbox = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount
        )
        _ = try await inbox.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: String(repeating: "1", count: 64),
            generation: 1,
            documentKind: .journal,
            documentID: UUID(),
            revision: 1,
            key: key,
            plaintext: Data("retain".utf8)
        )
        _ = try await inbox.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: String(repeating: "2", count: 64),
            generation: 2,
            documentKind: .journal,
            documentID: UUID(),
            revision: 3,
            key: key,
            plaintext: Data("remove".utf8)
        )

        let removed = try await inbox.reconcileOutgoing(
            accountScopeHash: firstAccount,
            retaining: [
                ManagedDocumentCiphertextInboxOutgoingReference(
                    localIdentifier: String(repeating: "1", count: 64),
                    generation: 1,
                    revision: 1
                ),
            ]
        )

        let remaining = try await inbox.pendingOutgoingCount()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remaining, 1)
    }

    func testNewOutgoingWriteFailsWhenOnlyUnacknowledgedCiphertextRemains()
        async throws
    {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ManagedDocumentCiphertextInboxPolicy(
            maximumRecordCount: 1,
            maximumTotalBytes: 1_024 * 1_024,
            maximumAgeMilliseconds: 60_000
        )
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 5, count: 32)
        )
        let inbox = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount,
            policy: policy,
            clock: { 1 }
        )
        let firstDocumentID = UUID()
        let firstCiphertext = try await inbox.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "first",
            generation: 1,
            documentKind: .journal,
            documentID: firstDocumentID,
            revision: 1,
            key: key,
            plaintext: Data("first pending upload".utf8)
        )

        do {
            _ = try await inbox.outgoingEnvelope(
                accountScopeHash: firstAccount,
                localIdentifier: "second",
                generation: 1,
                documentKind: .journal,
                documentID: UUID(),
                revision: 1,
                key: key,
                plaintext: Data("second pending upload".utf8)
            )
            XCTFail("Expected quota rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentCiphertextInboxError,
                .quotaExceeded
            )
        }

        let pendingCount = try await inbox.pendingOutgoingCount()
        let replayed = try await inbox.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "first",
            generation: 1,
            documentKind: .journal,
            documentID: firstDocumentID,
            revision: 1,
            key: key,
            plaintext: Data("first pending upload".utf8)
        )
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(replayed, firstCiphertext)
    }

    func testAccountsUseDistinctOpaqueDirectoriesAndCannotCrossBind() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 7, count: 32)
        )
        let documentID = UUID()
        let first = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount
        )
        let second = ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: secondAccount
        )

        _ = try await first.outgoingEnvelope(
            accountScopeHash: firstAccount,
            localIdentifier: "same-row",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("first".utf8)
        )
        _ = try await second.outgoingEnvelope(
            accountScopeHash: secondAccount,
            localIdentifier: "same-row",
            generation: 1,
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            key: key,
            plaintext: Data("second".utf8)
        )

        let firstCount = try await first.pendingOutgoingCount()
        let secondCount = try await second.pendingOutgoingCount()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
        let accountDirectories = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("accounts", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(accountDirectories.count, 2)
        for directory in accountDirectories {
            XCTAssertFalse(directory.lastPathComponent.contains(firstAccount))
            XCTAssertFalse(directory.lastPathComponent.contains(secondAccount))
            XCTAssertEqual(directory.lastPathComponent.count, 64)
        }

        do {
            _ = try await first.outgoingEnvelope(
                accountScopeHash: secondAccount,
                localIdentifier: "cross-account",
                generation: 1,
                documentKind: .journal,
                documentID: documentID,
                revision: 1,
                key: key,
                plaintext: Data("blocked".utf8)
            )
            XCTFail("Expected account rebind rejection")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentCiphertextInboxError,
                .invalidRecord
            )
        }
    }

    func testPurgingOneAccountPreservesAnotherAccountsCiphertext() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 9, count: 32)
        )
        for account in [firstAccount, secondAccount] {
            _ = try await ManagedDocumentCiphertextInbox(
                root: root,
                accountScopeHash: account
            ).outgoingEnvelope(
                accountScopeHash: account,
                localIdentifier: "row",
                generation: 1,
                documentKind: .journal,
                documentID: UUID(),
                revision: 1,
                key: key,
                plaintext: Data(account.prefix(1).utf8)
            )
        }

        XCTAssertEqual(
            try ManagedDocumentCiphertextInbox.purgeAccount(
                root: root,
                accountScopeHash: firstAccount
            ),
            .removed
        )
        let firstRemaining = try await ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: firstAccount
        ).pendingOutgoingCount()
        let secondRemaining = try await ManagedDocumentCiphertextInbox(
            root: root,
            accountScopeHash: secondAccount
        ).pendingOutgoingCount()
        XCTAssertEqual(firstRemaining, 0)
        XCTAssertEqual(secondRemaining, 1)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "managed-document-inbox-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeIncomingDocument(
        fixture: ManagedDocumentGoldenFixture.Document
    ) throws -> ManagedDocument {
        ManagedDocument(
            documentKind: .journal,
            documentID: UUID(uuidString: fixture.documentID)!,
            revision: fixture.revision,
            originInstallationID: "ios-test",
            contentMode: "client_encrypted",
            clientKeyID: UUID(uuidString: fixture.keyID)!,
            contentSHA256: fixture.envelopeSHA256,
            payloadJSON: nil,
            payloadCiphertextBase64: fixture.envelopeBase64,
            updatedAt: "2026-09-19T12:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
    }
}
