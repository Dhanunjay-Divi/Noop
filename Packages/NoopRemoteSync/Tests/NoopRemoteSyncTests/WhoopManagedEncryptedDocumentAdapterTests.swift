import GRDB
import XCTest
@testable import NoopRemoteSync
@testable import WhoopStore

final class WhoopManagedEncryptedDocumentAdapterTests: XCTestCase {
    private let account = String(repeating: "d", count: 64)

    func testEncryptedDocumentStagesDecryptsAndUsesValidatedApplyPath() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.activateManagedDocumentProfile(
            accountScopeHash: account,
            updatedAtMs: 1
        )
        let vault = ManagedDocumentKeyVault(
            storage: AdapterMemoryKeyStorage()
        )
        let masterKey = Data(repeating: 4, count: 32)
        let masterKeyID = UUID()
        let wrappedMasterKey = Data(repeating: 6, count: 72)
        let receipt = try ManagedAccountMasterKeyReceipt(
            keyID: masterKeyID,
            wrappingRevision: 1,
            wrappedKey: wrappedMasterKey,
            masterKeyConfirmationHMACSHA256:
                ManagedAccountMasterKeyBinding.confirmationHMACSHA256(
                    masterKey: masterKey,
                    accountScopeHash: account,
                    keyID: masterKeyID,
                    wrappingRevision: 1,
                    wrappedKeySHA256:
                        ManagedDocumentEnvelopeDigest.sha256(wrappedMasterKey),
                    recoveryMethod: "device_transfer"
                ),
            recoveryMethod: "device_transfer"
        )
        try await vault.completeRecoveryEnrollment(
            accountScopeHash: account,
            masterKey: masterKey,
            serverReceipt: receipt
        )
        let key = try await vault.createDocumentKey(
            accountScopeHash: account,
            keyID: UUID()
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "managed-adapter-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ManagedDocumentCiphertextInbox(root: root)
        let payload: [String: ManagedDocumentJSONValue] = [
            "schema_version": .integer(1),
            "table": .string("journal"),
            "key": .object([
                "deviceId": .string("strap"),
                "day": .string("2026-09-19"),
                "question": .string("private_note"),
            ]),
            "record": .object([
                "deviceId": .string("strap"),
                "day": .string("2026-09-19"),
                "question": .string("private_note"),
                "answeredYes": .boolean(true),
                "notes": .string("encrypted"),
                "numericValue": .null,
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(payload)
        let keyJSON = try encoder.encode(
            [
                "day": ManagedDocumentJSONValue.string("2026-09-19"),
                "deviceId": .string("strap"),
                "question": .string("private_note"),
            ]
        )
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: ManagedDocumentKind.journal.rawValue,
            tableName: "journal",
            keyJSON: keyJSON
        )
        let metadata = try ManagedDocumentEnvelopeMetadata(
            accountScopeHash: account,
            documentKind: .journal,
            documentID: documentID,
            revision: 1
        )
        let envelope = try ManagedDocumentEnvelope.seal(
            plaintext,
            key: key.keyData,
            metadata: metadata
        )
        let document = ManagedDocument(
            documentKind: .journal,
            documentID: documentID,
            revision: 1,
            originInstallationID: "ios-test",
            contentMode: "client_encrypted",
            clientKeyID: key.keyID,
            contentSHA256: ManagedDocumentEnvelopeDigest.sha256(envelope),
            payloadJSON: nil,
            payloadCiphertextBase64: envelope.base64EncodedString(),
            updatedAt: "2026-09-19T12:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
        let change = document.changeMetadata
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: account,
            documentKeys: vault,
            ciphertextInbox: inbox
        )

        try await inbox.stageIncoming(
            accountScopeHash: account,
            document: document
        )
        let stagedCount = try await inbox.pendingIncomingCount()
        XCTAssertEqual(stagedCount, 1)
        try await adapter.apply(document: document, change: change)
        let appliedCount = try await inbox.pendingIncomingCount()
        XCTAssertEqual(appliedCount, 0)
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT answeredYes, notes FROM journal
                    WHERE deviceId = 'strap'
                      AND day = '2026-09-19'
                      AND question = 'private_note'
                    """
            )
        }
        XCTAssertEqual(row?["answeredYes"] as Bool?, true)
        XCTAssertEqual(row?["notes"] as String?, "encrypted")
    }
}

private final class AdapterMemoryKeyStorage:
    ManagedDocumentKeyVaultStorage,
    @unchecked Sendable
{
    private var data: Data?
    func load(accountScopeHash _: String) -> Data? { data }
    func save(_ data: Data, accountScopeHash _: String) { self.data = data }
    func remove(accountScopeHash _: String) { data = nil }
}
