import Foundation
import Security

public enum ManagedDocumentKeyProviderError: Error, Equatable {
    case invalidAccount
    case invalidKey
    case recoveryNotEnrolled
    case keyNotFound
    case keyRevoked
    case storageUnavailable
}

public struct ManagedDocumentKey: Equatable, Sendable {
    public let keyID: UUID
    public let keyData: Data

    public init(keyID: UUID, keyData: Data) throws {
        guard keyData.count == 32 else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        self.keyID = keyID
        self.keyData = keyData
    }
}

public protocol ManagedDocumentKeyProviding: Sendable {
    func recoveryEnrollmentComplete(
        accountScopeHash: String
    ) async throws -> Bool

    func activeDocumentKey(
        accountScopeHash: String
    ) async throws -> ManagedDocumentKey

    func documentKey(
        accountScopeHash: String,
        keyID: UUID
    ) async throws -> ManagedDocumentKey
}

public protocol ManagedDocumentKeyVaultStorage: Sendable {
    func load(accountScopeHash: String) throws -> Data?
    func save(_ data: Data, accountScopeHash: String) throws
    func remove(accountScopeHash: String) throws
}

public actor ManagedDocumentKeyVault: ManagedDocumentKeyProviding {
    private struct State: Codable {
        var version = 3
        var recoveryEnrollment: ManagedAccountMasterKeyReceipt?
        var activeMasterKeyID: UUID?
        var masterKeyBase64: String?
        var masterWrappingRevision = 0
        var activeDocumentKeyID: UUID?
        var documentKeys: [String: String] = [:]
        var wrappedDocumentKeys: [String: ManagedWrappedDocumentKey] = [:]
        var revokedDocumentKeyIDs: Set<String> = []
        var pendingMasterRotation: PendingMasterRotation?
    }

    private struct PendingMasterRotation: Codable {
        let planID: UUID
        let accountMasterReceipt: ManagedAccountMasterKeyReceipt
        let masterKeyBase64: String
        let wrappedDocumentKeys: [String: ManagedWrappedDocumentKey]
    }

    private let storage: any ManagedDocumentKeyVaultStorage

    public init(storage: any ManagedDocumentKeyVaultStorage) {
        self.storage = storage
    }

    public func recoveryEnrollmentComplete(
        accountScopeHash: String
    ) throws -> Bool {
        try validateAccount(accountScopeHash)
        return try load(accountScopeHash).recoveryEnrollment != nil
    }

    public func completeRecoveryEnrollment(
        accountScopeHash: String,
        masterKey: Data,
        serverReceipt: ManagedAccountMasterKeyReceipt
    ) throws {
        try validateAccount(accountScopeHash)
        guard masterKey.count == 32,
              serverReceipt.wrappedKey != nil,
              ManagedAccountMasterKeyBinding.matches(
                  masterKey: masterKey,
                  accountScopeHash: accountScopeHash,
                  receipt: serverReceipt
              ),
              serverReceipt.status == "active" else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        var state = try load(accountScopeHash)
        guard state.recoveryEnrollment == nil,
              state.activeMasterKeyID == nil,
              state.documentKeys.isEmpty,
              state.pendingMasterRotation == nil else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        state.recoveryEnrollment = serverReceipt
        state.activeMasterKeyID = serverReceipt.keyID
        state.masterKeyBase64 = masterKey.base64EncodedString()
        state.masterWrappingRevision = serverReceipt.wrappingRevision
        try save(state, accountScopeHash)
    }

    @discardableResult
    public func createDocumentKey(
        accountScopeHash: String,
        keyID: UUID = UUID()
    ) throws -> ManagedDocumentKey {
        try validateAccount(accountScopeHash)
        var state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil,
              let masterKeyID = state.activeMasterKeyID,
              let masterKey = state.masterKeyBase64.flatMap({
                  Data(base64Encoded: $0)
              }),
              masterKey.count == 32,
              state.masterWrappingRevision > 0,
              state.pendingMasterRotation == nil else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        let id = keyID.uuidString.lowercased()
        guard state.documentKeys[id] == nil,
              state.wrappedDocumentKeys[id] == nil,
              !state.revokedDocumentKeyIDs.contains(id) else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        let data = try randomKey()
        let wrapped = try ManagedDocumentKeyWrapEnvelope.seal(
            documentKey: data,
            accountScopeHash: accountScopeHash,
            keyID: keyID,
            wrappingKeyID: masterKeyID,
            wrappingRevision: state.masterWrappingRevision,
            wrappingKey: masterKey
        )
        state.documentKeys[id] = data.base64EncodedString()
        state.wrappedDocumentKeys[id] = try ManagedWrappedDocumentKey(
            keyID: keyID,
            wrappingKeyID: masterKeyID,
            wrappingRevision: state.masterWrappingRevision,
            wrappedKey: wrapped
        )
        state.activeDocumentKeyID = keyID
        try save(state, accountScopeHash)
        return try ManagedDocumentKey(keyID: keyID, keyData: data)
    }

    public func activeDocumentKey(
        accountScopeHash: String
    ) throws -> ManagedDocumentKey {
        try validateAccount(accountScopeHash)
        let state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        guard let keyID = state.activeDocumentKeyID else {
            throw ManagedDocumentKeyProviderError.keyNotFound
        }
        return try key(state, keyID: keyID)
    }

    public func documentKey(
        accountScopeHash: String,
        keyID: UUID
    ) throws -> ManagedDocumentKey {
        try validateAccount(accountScopeHash)
        let state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        return try key(state, keyID: keyID)
    }

    public func wrappedDocumentKeys(
        accountScopeHash: String
    ) throws -> [ManagedWrappedDocumentKey] {
        try validateAccount(accountScopeHash)
        let state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil,
              state.activeMasterKeyID != nil,
              state.masterKeyBase64 != nil,
              state.masterWrappingRevision > 0,
              state.documentKeys.count == state.wrappedDocumentKeys.count else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        return try state.wrappedDocumentKeys.keys.sorted().map { value in
            guard !state.revokedDocumentKeyIDs.contains(value),
                  state.documentKeys[value] != nil,
                  let wrapped = state.wrappedDocumentKeys[value],
                  wrapped.wrappedKey != nil else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
            return wrapped
        }
    }

    public func prepareAccountMasterKeyRotation(
        accountScopeHash: String,
        newMasterKey: Data,
        serverReceipt: ManagedAccountMasterKeyReceipt,
        planID: UUID = UUID()
    ) throws -> ManagedDocumentKeyRotationPlan {
        try validateAccount(accountScopeHash)
        guard newMasterKey.count == 32,
              serverReceipt.wrappedKey != nil,
              ManagedAccountMasterKeyBinding.matches(
                  masterKey: newMasterKey,
                  accountScopeHash: accountScopeHash,
                  receipt: serverReceipt
              ),
              serverReceipt.status == "active" else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        var state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil,
              state.pendingMasterRotation == nil,
              serverReceipt.keyID != state.activeMasterKeyID,
              serverReceipt.wrappingRevision > state.masterWrappingRevision else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        var wrappedDocumentKeys: [String: ManagedWrappedDocumentKey] = [:]
        for value in state.documentKeys.keys.sorted() {
            guard let keyID = UUID(uuidString: value),
                  !state.revokedDocumentKeyIDs.contains(value),
                  let encoded = state.documentKeys[value],
                  let documentKey = Data(base64Encoded: encoded),
                  documentKey.count == 32 else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
            let wrapped = try ManagedDocumentKeyWrapEnvelope.seal(
                documentKey: documentKey,
                accountScopeHash: accountScopeHash,
                keyID: keyID,
                wrappingKeyID: serverReceipt.keyID,
                wrappingRevision: serverReceipt.wrappingRevision,
                wrappingKey: newMasterKey
            )
            wrappedDocumentKeys[value] = try ManagedWrappedDocumentKey(
                keyID: keyID,
                wrappingKeyID: serverReceipt.keyID,
                wrappingRevision: serverReceipt.wrappingRevision,
                wrappedKey: wrapped
            )
        }
        state.pendingMasterRotation = PendingMasterRotation(
            planID: planID,
            accountMasterReceipt: serverReceipt,
            masterKeyBase64: newMasterKey.base64EncodedString(),
            wrappedDocumentKeys: wrappedDocumentKeys
        )
        try save(state, accountScopeHash)
        return ManagedDocumentKeyRotationPlan(
            planID: planID,
            accountMasterReceipt: serverReceipt,
            wrappedDocumentKeys: wrappedDocumentKeys.values.sorted {
                $0.keyID.uuidString < $1.keyID.uuidString
            }
        )
    }

    public func pendingAccountMasterKeyRotation(
        accountScopeHash: String
    ) throws -> ManagedDocumentKeyRotationPlan? {
        try validateAccount(accountScopeHash)
        guard let pending = try load(accountScopeHash).pendingMasterRotation
        else {
            return nil
        }
        return ManagedDocumentKeyRotationPlan(
            planID: pending.planID,
            accountMasterReceipt: pending.accountMasterReceipt,
            wrappedDocumentKeys: pending.wrappedDocumentKeys.values.sorted {
                $0.keyID.uuidString < $1.keyID.uuidString
            }
        )
    }

    public func commitAccountMasterKeyRotation(
        accountScopeHash: String,
        planID: UUID,
        acknowledgedDocumentKeys: [ManagedWrappedDocumentKey]
    ) throws {
        try validateAccount(accountScopeHash)
        var state = try load(accountScopeHash)
        guard let pending = state.pendingMasterRotation,
              pending.planID == planID,
              let newMasterKey = Data(
                  base64Encoded: pending.masterKeyBase64
              ),
              newMasterKey.count == 32 else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        var acknowledged: [String: ManagedWrappedDocumentKey] = [:]
        for wrapped in acknowledgedDocumentKeys {
            let id = wrapped.keyID.uuidString.lowercased()
            guard acknowledged[id] == nil,
                  wrapped.wrappedKey != nil else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
            acknowledged[id] = wrapped
        }
        guard acknowledged == pending.wrappedDocumentKeys else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        state.recoveryEnrollment = pending.accountMasterReceipt
        state.activeMasterKeyID = pending.accountMasterReceipt.keyID
        state.masterKeyBase64 = pending.masterKeyBase64
        state.masterWrappingRevision =
            pending.accountMasterReceipt.wrappingRevision
        state.wrappedDocumentKeys = pending.wrappedDocumentKeys
        state.pendingMasterRotation = nil
        try save(state, accountScopeHash)
    }

    public func cancelAccountMasterKeyRotation(
        accountScopeHash: String,
        planID: UUID
    ) throws {
        try validateAccount(accountScopeHash)
        var state = try load(accountScopeHash)
        guard state.pendingMasterRotation?.planID == planID else {
            throw ManagedDocumentKeyProviderError.keyNotFound
        }
        state.pendingMasterRotation = nil
        try save(state, accountScopeHash)
    }

    public func recoverDocumentKey(
        accountScopeHash: String,
        wrapped: ManagedWrappedDocumentKey,
        masterKey: Data,
        makeActive: Bool
    ) throws {
        try validateAccount(accountScopeHash)
        guard let envelope = wrapped.wrappedKey else {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        let documentKey: Data
        do {
            documentKey = try ManagedDocumentKeyWrapEnvelope.open(
                envelope,
                accountScopeHash: accountScopeHash,
                keyID: wrapped.keyID,
                wrappingKeyID: wrapped.wrappingKeyID,
                wrappingRevision: wrapped.wrappingRevision,
                wrappingKey: masterKey
            )
        } catch {
            throw ManagedDocumentKeyProviderError.invalidKey
        }
        var state = try load(accountScopeHash)
        guard state.recoveryEnrollment != nil else {
            throw ManagedDocumentKeyProviderError.recoveryNotEnrolled
        }
        guard !state.revokedDocumentKeyIDs.contains(
            wrapped.keyID.uuidString.lowercased()
        ) else {
            throw ManagedDocumentKeyProviderError.keyRevoked
        }
        state.documentKeys[wrapped.keyID.uuidString.lowercased()] =
            documentKey.base64EncodedString()
        state.wrappedDocumentKeys[wrapped.keyID.uuidString.lowercased()] =
            wrapped
        if makeActive {
            state.activeDocumentKeyID = wrapped.keyID
        }
        try save(state, accountScopeHash)
    }

    public func revokeDocumentKey(
        accountScopeHash: String,
        keyID: UUID
    ) throws {
        try validateAccount(accountScopeHash)
        var state = try load(accountScopeHash)
        let id = keyID.uuidString.lowercased()
        guard state.documentKeys.removeValue(forKey: id) != nil
                || state.revokedDocumentKeyIDs.contains(id) else {
            throw ManagedDocumentKeyProviderError.keyNotFound
        }
        state.wrappedDocumentKeys.removeValue(forKey: id)
        state.revokedDocumentKeyIDs.insert(id)
        if state.activeDocumentKeyID == keyID {
            state.activeDocumentKeyID = nil
        }
        try save(state, accountScopeHash)
    }

    public func removeAccount(accountScopeHash: String) throws {
        try validateAccount(accountScopeHash)
        do {
            try storage.remove(accountScopeHash: accountScopeHash)
        } catch {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
    }

    private func key(_ state: State, keyID: UUID) throws -> ManagedDocumentKey {
        let id = keyID.uuidString.lowercased()
        guard !state.revokedDocumentKeyIDs.contains(id) else {
            throw ManagedDocumentKeyProviderError.keyRevoked
        }
        guard let encoded = state.documentKeys[id],
              let data = Data(base64Encoded: encoded),
              data.count == 32 else {
            throw ManagedDocumentKeyProviderError.keyNotFound
        }
        return try ManagedDocumentKey(keyID: keyID, keyData: data)
    }

    private func validateAccount(_ accountScopeHash: String) throws {
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedDocumentKeyProviderError.invalidAccount
        }
    }

    private func load(_ accountScopeHash: String) throws -> State {
        do {
            guard let data = try storage.load(accountScopeHash: accountScopeHash)
            else {
                return State()
            }
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 3 else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
            try validateBoundMasterState(
                state,
                accountScopeHash: accountScopeHash
            )
            return state
        } catch let error as ManagedDocumentKeyProviderError {
            throw error
        } catch {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
    }

    private func validateBoundMasterState(
        _ state: State,
        accountScopeHash: String
    ) throws {
        if let receipt = state.recoveryEnrollment {
            guard state.activeMasterKeyID == receipt.keyID,
                  state.masterWrappingRevision == receipt.wrappingRevision,
                  let encoded = state.masterKeyBase64,
                  let masterKey = Data(base64Encoded: encoded),
                  masterKey.count == 32,
                  ManagedAccountMasterKeyBinding.matches(
                      masterKey: masterKey,
                      accountScopeHash: accountScopeHash,
                      receipt: receipt
                  ) else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
        } else {
            guard state.activeMasterKeyID == nil,
                  state.masterKeyBase64 == nil,
                  state.masterWrappingRevision == 0 else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
        }
        if let pending = state.pendingMasterRotation {
            guard let pendingMasterKey = Data(
                base64Encoded: pending.masterKeyBase64
            ),
            pendingMasterKey.count == 32,
            ManagedAccountMasterKeyBinding.matches(
                masterKey: pendingMasterKey,
                accountScopeHash: accountScopeHash,
                receipt: pending.accountMasterReceipt
            ) else {
                throw ManagedDocumentKeyProviderError.invalidKey
            }
        }
    }

    private func save(_ state: State, _ accountScopeHash: String) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try storage.save(
                encoder.encode(state),
                accountScopeHash: accountScopeHash
            )
        } catch {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
    }

    private func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
        return Data(bytes)
    }
}

public final class KeychainManagedDocumentKeyVaultStorage:
    ManagedDocumentKeyVaultStorage,
    @unchecked Sendable
{
    private let service: String

    public init(service: String = "com.noop.managed-document-keys.v1") {
        self.service = service
    }

    public func load(accountScopeHash: String) throws -> Data? {
        var query = baseQuery(accountScopeHash)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
        return data
    }

    public func save(_ data: Data, accountScopeHash: String) throws {
        let query = baseQuery(accountScopeHash)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
    }

    public func remove(accountScopeHash: String) throws {
        let status = SecItemDelete(baseQuery(accountScopeHash) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ManagedDocumentKeyProviderError.storageUnavailable
        }
    }

    private func baseQuery(_ accountScopeHash: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountScopeHash,
        ]
    }
}
