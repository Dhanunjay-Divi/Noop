import Foundation
@testable import NoopRemoteSync
@testable import Strand
@testable import WhoopStore
import XCTest

@MainActor
final class ManagedCloudDocumentAdapterTests: XCTestCase {
    private let accountScopeHash = String(repeating: "a", count: 64)

    func testConflictDoesNotChangeDefaultsOrReplaceLocalPreference()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let localPayload = try XCTUnwrap(
            BackupSettings.encode(["units.system": "imperial"])
        )
        fixture.defaults.set("imperial", forKey: "units.system")
        try await fixture.store.stageManagedPreferences(
            localPayload,
            updatedAtMs: 1
        )

        do {
            try await fixture.adapter.apply(
                document: fixture.document,
                change: fixture.document.changeMetadata
            )
            XCTFail("Expected the unacknowledged local preference to win")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageError,
                .documentConflict(
                    documentKind: .preferences,
                    remoteRevision: fixture.document.revision
                )
            )
        }

        XCTAssertEqual(
            fixture.defaults.string(forKey: "units.system"),
            "imperial"
        )
        let pending = try await fixture.store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.payloadJSON, localPayload)
    }

    func testSuccessfulDurableApplyPrecedesLocalPreferenceUpdate()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("imperial", forKey: "units.system")

        try await fixture.adapter.apply(
            document: fixture.document,
            change: fixture.document.changeMetadata
        )

        XCTAssertEqual(
            fixture.defaults.string(forKey: "units.system"),
            "metric"
        )
        let identity = try await fixture.store.managedDocumentIdentity(
            accountScopeHash: accountScopeHash,
            documentKind: ManagedDocumentKind.preferences.rawValue,
            documentID: fixture.document.documentID.uuidString
        )
        XCTAssertEqual(identity?.tableName, "preferences")
        XCTAssertEqual(identity?.localKey, "global")
        let pending = try await fixture.store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertTrue(pending.isEmpty)

        try await fixture.store.stageManagedPreferences(
            fixture.preferencePayload,
            updatedAtMs: 2
        )
        let identicalSnapshot = try await fixture.store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertTrue(identicalSnapshot.isEmpty)
    }

    func testGenerationFenceAfterDurableApplyBlocksLocalSideEffects()
        async throws
    {
        let gate = ManagedPreferenceApplyGate(failOnCall: 2)
        let fixture = try await makeFixture(gate: gate)
        defer { fixture.cleanup() }
        fixture.defaults.set("imperial", forKey: "units.system")

        do {
            try await fixture.adapter.apply(
                document: fixture.document,
                change: fixture.document.changeMetadata
            )
            XCTFail("Expected the account generation fence to cancel")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let identity = try await fixture.store.managedDocumentIdentity(
            accountScopeHash: accountScopeHash,
            documentKind: ManagedDocumentKind.preferences.rawValue,
            documentID: fixture.document.documentID.uuidString
        )
        XCTAssertNotNil(identity)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "units.system"),
            "imperial"
        )
        let pending = try await fixture.store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertTrue(pending.isEmpty)
    }

    private func makeFixture(
        gate: ManagedPreferenceApplyGate? = nil
    ) async throws -> ManagedPreferenceFixture {
        let store = try await WhoopStore.inMemory()
        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountScopeHash,
            updatedAtMs: 1
        )
        let suiteName =
            "ManagedCloudDocumentAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = try ManagedDocumentKey(
            keyID: UUID(),
            keyData: Data(repeating: 7, count: 32)
        )
        let keys = FixedManagedDocumentKeys(key: key)
        let payload = try XCTUnwrap(
            BackupSettings.encode(["units.system": "metric"])
        )
        let keyJSON = try canonicalData([
            "scope": .string("global"),
        ])
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: ManagedDocumentKind.preferences.rawValue,
            tableName: "preferences",
            keyJSON: keyJSON
        )
        let envelope = try ManagedDocumentEnvelope.seal(
            payload,
            key: key.keyData,
            metadata: ManagedDocumentEnvelopeMetadata(
                accountScopeHash: accountScopeHash,
                documentKind: .preferences,
                documentID: documentID,
                revision: 1
            )
        )
        let document = ManagedDocument(
            documentKind: .preferences,
            documentID: documentID,
            revision: 1,
            originInstallationID: "ios-test",
            contentMode: ManagedDocumentContentMode.clientEncrypted.rawValue,
            clientKeyID: key.keyID,
            contentSHA256: ManagedDigest.sha256(envelope),
            payloadJSON: nil,
            payloadCiphertextBase64: envelope.base64EncodedString(),
            updatedAt: "2026-09-20T12:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
        let inboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "managed-preference-\(UUID().uuidString)"
            )
        let inbox = ManagedDocumentCiphertextInbox(root: inboxRoot)
        let operationValidator: @Sendable () async throws -> Void = {
            if let gate {
                try await MainActor.run {
                    try gate.validate()
                }
            }
        }
        let preferenceCommitter:
            @Sendable (Data) async throws -> Void = { payload in
                try await MainActor.run {
                    if let gate {
                        try gate.validate()
                    }
                    let values = BackupSettings.decode(payload)
                    guard !values.isEmpty else {
                        throw ManagedStorageError.invalidResponse
                    }
                    guard let targetDefaults = UserDefaults(
                        suiteName: suiteName
                    ) else {
                        throw ManagedStorageError.invalidResponse
                    }
                    BackupSettings.apply(values, to: targetDefaults)
                }
            }
        let adapter = try ManagedCloudDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash,
            documentKeys: keys,
            ciphertextInbox: inbox,
            operationValidator: operationValidator,
            preferenceCommitter: preferenceCommitter
        )
        return ManagedPreferenceFixture(
            store: store,
            adapter: adapter,
            document: document,
            preferencePayload: payload,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            inboxRoot: inboxRoot
        )
    }

    private func canonicalData(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

private struct ManagedPreferenceFixture {
    let store: WhoopStore
    let adapter: ManagedCloudDocumentAdapter
    let document: ManagedDocument
    let preferencePayload: Data
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let inboxRoot: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: inboxRoot)
    }
}

private actor FixedManagedDocumentKeys: ManagedDocumentKeyProviding {
    let key: ManagedDocumentKey

    init(key: ManagedDocumentKey) {
        self.key = key
    }

    func recoveryEnrollmentComplete(accountScopeHash _: String) -> Bool {
        true
    }

    func activeDocumentKey(
        accountScopeHash _: String
    ) -> ManagedDocumentKey {
        key
    }

    func documentKey(
        accountScopeHash _: String,
        keyID _: UUID
    ) -> ManagedDocumentKey {
        key
    }
}

@MainActor
private final class ManagedPreferenceApplyGate {
    private let failOnCall: Int
    private var calls = 0

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func validate() throws {
        calls += 1
        if calls == failOnCall {
            throw CancellationError()
        }
    }
}
