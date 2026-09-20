import CryptoKit
import Foundation

public enum ManagedDocumentEnvelopeError: Error, Equatable {
    case invalidMetadata
    case invalidKey
    case invalidEnvelope
    case payloadTooLarge
    case authenticationFailed
}

public struct ManagedDocumentEnvelopeMetadata: Equatable, Sendable {
    public let accountScopeHash: String
    public let documentKind: ManagedDocumentKind
    public let documentID: UUID
    public let revision: Int64

    public init(
        accountScopeHash: String,
        documentKind: ManagedDocumentKind,
        documentID: UUID,
        revision: Int64
    ) throws {
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil,
        revision > 0 else {
            throw ManagedDocumentEnvelopeError.invalidMetadata
        }
        self.accountScopeHash = accountScopeHash
        self.documentKind = documentKind
        self.documentID = documentID
        self.revision = revision
    }

    public var authenticatedData: Data {
        Data(
            (
                "noop-managed-document-aad-v1\0"
                    + accountScopeHash + "\0"
                    + documentKind.rawValue + "\0"
                    + documentID.uuidString.lowercased() + "\0"
                    + String(revision)
            ).utf8
        )
    }
}

public enum ManagedDocumentEnvelope {
    public static let maximumEnvelopeBytes = 1_048_576
    public static let maximumPlaintextBytes = maximumEnvelopeBytes - 40

    private static let magic = Data([
        0x4e, 0x4f, 0x4f, 0x50, 0x44, 0x4f, 0x43, 0x00,
    ])

    public static func seal(
        _ plaintext: Data,
        key: Data,
        metadata: ManagedDocumentEnvelopeMetadata
    ) throws -> Data {
        try seal(plaintext, key: key, metadata: metadata, nonce: nil)
    }

    static func seal(
        _ plaintext: Data,
        key: Data,
        metadata: ManagedDocumentEnvelopeMetadata,
        nonce: Data?
    ) throws -> Data {
        guard key.count == 32 else {
            throw ManagedDocumentEnvelopeError.invalidKey
        }
        guard plaintext.count <= maximumPlaintextBytes else {
            throw ManagedDocumentEnvelopeError.payloadTooLarge
        }
        let aesNonce: AES.GCM.Nonce
        do {
            aesNonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        } catch {
            throw ManagedDocumentEnvelopeError.invalidEnvelope
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: aesNonce,
                authenticating: metadata.authenticatedData
            )
        } catch {
            throw ManagedDocumentEnvelopeError.invalidEnvelope
        }
        var envelope = magic
        envelope.append(1)
        envelope.append(12)
        envelope.append(contentsOf: [0, 0])
        envelope.append(contentsOf: aesNonce)
        envelope.append(box.ciphertext)
        envelope.append(box.tag)
        guard envelope.count <= maximumEnvelopeBytes else {
            throw ManagedDocumentEnvelopeError.payloadTooLarge
        }
        return envelope
    }

    public static func open(
        _ envelope: Data,
        key: Data,
        metadata: ManagedDocumentEnvelopeMetadata
    ) throws -> Data {
        guard key.count == 32 else {
            throw ManagedDocumentEnvelopeError.invalidKey
        }
        guard envelope.count >= 40,
              envelope.count <= maximumEnvelopeBytes,
              envelope.prefix(magic.count) == magic,
              envelope[8] == 1,
              envelope[9] == 12,
              envelope[10] == 0,
              envelope[11] == 0 else {
            throw ManagedDocumentEnvelopeError.invalidEnvelope
        }
        let nonce = envelope.subdata(in: 12..<24)
        let ciphertext = envelope.subdata(in: 24..<(envelope.count - 16))
        let tag = envelope.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: metadata.authenticatedData
            )
        } catch {
            throw ManagedDocumentEnvelopeError.authenticationFailed
        }
    }
}

public struct ManagedWrappedDocumentKey: Codable, Equatable, Sendable {
    public let version: Int
    public let keyID: UUID
    public let wrappingKeyID: UUID
    public let wrappingRevision: Int
    public let algorithm: String
    public let wrappedKeyBase64: String
    public let wrappedKeySHA256: String

    public init(
        keyID: UUID,
        wrappingKeyID: UUID,
        wrappingRevision: Int,
        wrappedKey: Data
    ) throws {
        guard wrappingRevision > 0,
              wrappedKey.count == 72 else {
            throw ManagedDocumentEnvelopeError.invalidMetadata
        }
        self.version = 1
        self.keyID = keyID
        self.wrappingKeyID = wrappingKeyID
        self.wrappingRevision = wrappingRevision
        self.algorithm = "A256GCM"
        self.wrappedKeyBase64 = wrappedKey.base64EncodedString()
        self.wrappedKeySHA256 = ManagedDocumentEnvelopeDigest.sha256(wrappedKey)
    }

    public var wrappedKey: Data? {
        guard version == 1,
              algorithm == "A256GCM",
              wrappingRevision > 0,
              wrappedKeySHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              let data = Data(base64Encoded: wrappedKeyBase64),
              data.count == 72,
              data.base64EncodedString() == wrappedKeyBase64,
              ManagedDocumentEnvelopeDigest.sha256(data) == wrappedKeySHA256
        else {
            return nil
        }
        return data
    }
}

public enum ManagedAccountMasterKeyBinding {
    private static let context =
        "noop-managed-account-master-key-confirmation-v1"
    private static let recoveryMethods = Set([
        "recovery_key",
        "device_transfer",
        "platform_escrow",
    ])

    public static func confirmationHMACSHA256(
        masterKey: Data,
        accountScopeHash: String,
        keyID: UUID,
        wrappingRevision: Int,
        wrappedKeySHA256: String,
        recoveryMethod: String
    ) throws -> String {
        guard masterKey.count == 32 else {
            throw ManagedDocumentEnvelopeError.invalidKey
        }
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil,
        wrappingRevision > 0,
        wrappedKeySHA256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil,
        recoveryMethods.contains(recoveryMethod) else {
            throw ManagedDocumentEnvelopeError.invalidMetadata
        }
        let message = [
            context,
            accountScopeHash,
            keyID.uuidString.lowercased(),
            String(wrappingRevision),
            wrappedKeySHA256,
            recoveryMethod,
        ].joined(separator: "\0")
        let confirmation = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: masterKey)
        )
        return confirmation.map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(
        masterKey: Data,
        accountScopeHash: String,
        receipt: ManagedAccountMasterKeyReceipt
    ) -> Bool {
        guard let expected = try? confirmationHMACSHA256(
            masterKey: masterKey,
            accountScopeHash: accountScopeHash,
            keyID: receipt.keyID,
            wrappingRevision: receipt.wrappingRevision,
            wrappedKeySHA256: receipt.wrappedKeySHA256,
            recoveryMethod: receipt.recoveryMethod
        ) else {
            return false
        }
        let lhs = Array(expected.utf8)
        let rhs = Array(receipt.masterKeyConfirmationHMACSHA256.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

public struct ManagedAccountMasterKeyReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let keyID: UUID
    public let wrappingRevision: Int
    public let algorithm: String
    public let wrappedKeyBase64: String
    public let wrappedKeySHA256: String
    public let masterKeyConfirmationHMACSHA256: String
    public let recoveryMethod: String
    public let status: String

    public init(
        keyID: UUID,
        wrappingRevision: Int,
        wrappedKey: Data,
        masterKeyConfirmationHMACSHA256: String,
        recoveryMethod: String,
        status: String = "active"
    ) throws {
        guard wrappingRevision > 0,
              (40...16_384).contains(wrappedKey.count),
              masterKeyConfirmationHMACSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              ["recovery_key", "device_transfer", "platform_escrow"]
                .contains(recoveryMethod),
              status == "active" else {
            throw ManagedDocumentEnvelopeError.invalidMetadata
        }
        self.version = 1
        self.keyID = keyID
        self.wrappingRevision = wrappingRevision
        self.algorithm = "A256GCM"
        self.wrappedKeyBase64 = wrappedKey.base64EncodedString()
        self.wrappedKeySHA256 = ManagedDocumentEnvelopeDigest.sha256(
            wrappedKey
        )
        self.masterKeyConfirmationHMACSHA256 =
            masterKeyConfirmationHMACSHA256
        self.recoveryMethod = recoveryMethod
        self.status = status
    }

    public var wrappedKey: Data? {
        guard version == 1,
              algorithm == "A256GCM",
              wrappingRevision > 0,
              ["recovery_key", "device_transfer", "platform_escrow"]
                .contains(recoveryMethod),
              status == "active",
              wrappedKeySHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              masterKeyConfirmationHMACSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              let data = Data(base64Encoded: wrappedKeyBase64),
              data.base64EncodedString() == wrappedKeyBase64,
              (40...16_384).contains(data.count),
              ManagedDocumentEnvelopeDigest.sha256(data)
                == wrappedKeySHA256 else {
            return nil
        }
        return data
    }
}

public struct ManagedDocumentKeyRotationPlan: Equatable, Sendable {
    public let planID: UUID
    public let accountMasterReceipt: ManagedAccountMasterKeyReceipt
    public let wrappedDocumentKeys: [ManagedWrappedDocumentKey]

    init(
        planID: UUID,
        accountMasterReceipt: ManagedAccountMasterKeyReceipt,
        wrappedDocumentKeys: [ManagedWrappedDocumentKey]
    ) {
        self.planID = planID
        self.accountMasterReceipt = accountMasterReceipt
        self.wrappedDocumentKeys = wrappedDocumentKeys
    }
}

enum ManagedDocumentKeyWrapEnvelope {
    private static let magic = Data([
        0x4e, 0x4f, 0x4f, 0x50, 0x4b, 0x45, 0x59, 0x00,
    ])

    static func seal(
        documentKey: Data,
        accountScopeHash: String,
        keyID: UUID,
        wrappingKeyID: UUID,
        wrappingRevision: Int,
        wrappingKey: Data,
        nonce: Data? = nil
    ) throws -> Data {
        guard documentKey.count == 32, wrappingKey.count == 32 else {
            throw ManagedDocumentEnvelopeError.invalidKey
        }
        let aad = authenticatedData(
            accountScopeHash: accountScopeHash,
            keyID: keyID,
            wrappingKeyID: wrappingKeyID,
            wrappingRevision: wrappingRevision
        )
        let aesNonce: AES.GCM.Nonce
        do {
            aesNonce = try nonce.map(AES.GCM.Nonce.init(data:)) ?? AES.GCM.Nonce()
        } catch {
            throw ManagedDocumentEnvelopeError.invalidEnvelope
        }
        let box = try AES.GCM.seal(
            documentKey,
            using: SymmetricKey(data: wrappingKey),
            nonce: aesNonce,
            authenticating: aad
        )
        var envelope = magic
        envelope.append(1)
        envelope.append(12)
        envelope.append(contentsOf: [0, 0])
        envelope.append(contentsOf: aesNonce)
        envelope.append(box.ciphertext)
        envelope.append(box.tag)
        return envelope
    }

    static func open(
        _ envelope: Data,
        accountScopeHash: String,
        keyID: UUID,
        wrappingKeyID: UUID,
        wrappingRevision: Int,
        wrappingKey: Data
    ) throws -> Data {
        guard wrappingKey.count == 32,
              envelope.count == 72,
              envelope.prefix(magic.count) == magic,
              envelope[8] == 1,
              envelope[9] == 12,
              envelope[10] == 0,
              envelope[11] == 0 else {
            throw ManagedDocumentEnvelopeError.invalidEnvelope
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.subdata(in: 12..<24)),
                ciphertext: envelope.subdata(in: 24..<56),
                tag: envelope.suffix(16)
            )
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: wrappingKey),
                authenticating: authenticatedData(
                    accountScopeHash: accountScopeHash,
                    keyID: keyID,
                    wrappingKeyID: wrappingKeyID,
                    wrappingRevision: wrappingRevision
                )
            )
        } catch {
            throw ManagedDocumentEnvelopeError.authenticationFailed
        }
    }

    private static func authenticatedData(
        accountScopeHash: String,
        keyID: UUID,
        wrappingKeyID: UUID,
        wrappingRevision: Int
    ) -> Data {
        Data(
            (
                "noop-managed-document-key-wrap-v1\0"
                    + accountScopeHash + "\0"
                    + keyID.uuidString.lowercased() + "\0"
                    + wrappingKeyID.uuidString.lowercased() + "\0"
                    + String(wrappingRevision)
            ).utf8
        )
    }
}

enum ManagedDocumentEnvelopeDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
