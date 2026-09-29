import Foundation
import NoopRemoteSync
import WhoopStore

/// Keeps Apple preference side effects behind the durable managed-document
/// apply while delegating every other document kind to the shared adapter.
actor ManagedCloudDocumentAdapter:
    ManagedDocumentOutbox,
    WhoopManagedDocumentRestoring
{
    private let delegate: WhoopManagedDocumentAdapter
    private let store: WhoopStore
    private let accountScopeHash: String
    private let documentKeys: (any ManagedDocumentKeyProviding)?
    private let ciphertextInbox: ManagedDocumentCiphertextInbox?
    private let operationValidator: @Sendable () async throws -> Void
    private let preferenceCommitter: @Sendable (Data) async throws -> Void

    init(
        store: WhoopStore,
        accountScopeHash: String,
        documentKeys: (any ManagedDocumentKeyProviding)? = nil,
        ciphertextInbox: ManagedDocumentCiphertextInbox? = nil,
        operationValidator: @escaping @Sendable () async throws -> Void = {},
        preferenceCommitter:
            @escaping @Sendable (Data) async throws -> Void
    ) throws {
        delegate = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash,
            documentKeys: documentKeys,
            ciphertextInbox: ciphertextInbox
        )
        self.store = store
        self.accountScopeHash = accountScopeHash
        self.documentKeys = documentKeys
        self.ciphertextInbox = ciphertextInbox
        self.operationValidator = operationValidator
        self.preferenceCommitter = preferenceCommitter
    }

    func pendingDocuments(
        limit: Int
    ) async throws -> [ManagedPendingDocument] {
        try await operationValidator()
        let pending = try await delegate.pendingDocuments(limit: limit)
        try await operationValidator()
        return pending
    }

    func acknowledge(
        _ pending: ManagedPendingDocument,
        remote: ManagedDocument
    ) async throws {
        try await operationValidator()
        try await delegate.acknowledge(pending, remote: remote)
        try await operationValidator()
    }

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        try await operationValidator()
        guard document.documentKind == .preferences else {
            try await delegate.apply(document: document, change: change)
            try await operationValidator()
            return
        }

        let preference = try await verifiedPreference(
            document: document,
            change: change
        )
        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: accountScopeHash,
                documentKind: document.documentKind.rawValue,
                documentID: document.documentID.uuidString.lowercased(),
                revision: document.revision,
                contentSHA256: document.contentSHA256,
                payloadJSON: preference.payload,
                deleted: false,
                appliedAtMs: Self.nowMilliseconds()
            )
        } catch ManagedDocumentStoreError.unacknowledgedLocalGeneration {
            throw ManagedStorageError.documentConflict(
                documentKind: document.documentKind,
                remoteRevision: document.revision
            )
        } catch {
            throw ManagedStorageError.invalidResponse
        }

        // The committer validates the account fence and applies UserDefaults
        // in one MainActor turn, so an account transition cannot interleave.
        try await preferenceCommitter(preference.payload)
        if let ciphertextInbox {
            do {
                try await ciphertextInbox.removeIncoming(
                    accountScopeHash: accountScopeHash,
                    document: document
                )
            } catch {
                throw ManagedStorageError.invalidResponse
            }
        }
        try await operationValidator()
    }

    private func verifiedPreference(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws -> (payload: Data, values: [String: Any]) {
        try Self.validatePreferenceMetadata(document, change: change)
        guard let documentKeys,
              let keyID = document.clientKeyID,
              let encoded = document.payloadCiphertextBase64,
              let ciphertext = Data(base64Encoded: encoded),
              ciphertext.base64EncodedString() == encoded,
              (17...ManagedDocumentEnvelope.maximumEnvelopeBytes)
                .contains(ciphertext.count),
              ManagedDigest.sha256(ciphertext) == document.contentSHA256 else {
            throw ManagedStorageError.invalidConfiguration
        }

        let key: ManagedDocumentKey
        do {
            key = try await documentKeys.documentKey(
                accountScopeHash: accountScopeHash,
                keyID: keyID
            )
        } catch ManagedDocumentKeyProviderError.recoveryNotEnrolled {
            throw ManagedStorageError.invalidConfiguration
        } catch ManagedDocumentKeyProviderError.keyNotFound {
            throw ManagedStorageError.invalidConfiguration
        } catch ManagedDocumentKeyProviderError.keyRevoked {
            throw ManagedStorageError.invalidResponse
        } catch {
            throw ManagedStorageError.invalidResponse
        }
        guard key.keyID == keyID else {
            throw ManagedStorageError.invalidResponse
        }

        let plaintext: Data
        do {
            plaintext = try ManagedDocumentEnvelope.open(
                ciphertext,
                key: key.keyData,
                metadata: ManagedDocumentEnvelopeMetadata(
                    accountScopeHash: accountScopeHash,
                    documentKind: document.documentKind,
                    documentID: document.documentID,
                    revision: document.revision
                )
            )
        } catch {
            throw ManagedStorageError.invalidResponse
        }

        do {
            let payload = try JSONDecoder().decode(
                [String: ManagedDocumentJSONValue].self,
                from: plaintext
            )
            guard try Self.canonicalData(payload) == plaintext,
                  try Self.preferenceDocumentID() == document.documentID else {
                throw ManagedStorageError.invalidResponse
            }
            let values = BackupSettings.decode(plaintext)
            guard !values.isEmpty,
                  let normalized = BackupSettings.encode(values),
                  try Self.equalJSON(normalized, plaintext) else {
                throw ManagedStorageError.invalidResponse
            }
            return (normalized, values)
        } catch let error as ManagedStorageError {
            throw error
        } catch {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func validatePreferenceMetadata(
        _ document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) throws {
        guard document.revision > 0,
              document.contentSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              ManagedTimestamp.milliseconds(
                  iso8601: document.updatedAt
              ) != nil,
              document.deletedAt == nil,
              document.contentMode
                == ManagedDocumentContentMode.clientEncrypted.rawValue,
              document.payloadJSON == nil,
              document.clientKeyID != nil,
              document.payloadCiphertextBase64 != nil,
              change.resourceKind == "document",
              change.resourceID == document.documentID,
              change.operation == "upsert",
              change.contentSHA256 == document.contentSHA256,
              let metadata = change.document,
              metadata.documentKind == .preferences,
              metadata.documentID == document.documentID,
              metadata.revision == document.revision,
              metadata.contentMode == document.contentMode,
              metadata.clientKeyID == document.clientKeyID,
              metadata.updatedAt == document.updatedAt,
              metadata.deletedAt == nil else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func preferenceDocumentID() throws -> UUID {
        ManagedDocumentStableIdentifier.uuid(
            documentKind: ManagedDocumentKind.preferences.rawValue,
            tableName: "preferences",
            keyJSON: try canonicalData([
                "scope": .string("global"),
            ])
        )
    }

    private static func canonicalData(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func equalJSON(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs)
        let right = try JSONSerialization.jsonObject(with: rhs)
        return (left as? NSObject)?.isEqual(right) == true
    }

    private static func nowMilliseconds() -> Int64 {
        max(
            0,
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        )
    }
}
