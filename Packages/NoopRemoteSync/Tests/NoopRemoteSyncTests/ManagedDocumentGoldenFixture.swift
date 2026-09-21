import Foundation

struct ManagedDocumentGoldenFixture: Decodable {
    struct Document: Decodable {
        let accountScopeHash: String
        let documentKind: String
        let documentID: String
        let revision: Int64
        let keyID: String
        let keyHex: String
        let nonceHex: String
        let aadHex: String
        let plaintextBase64: String
        let envelopeBase64: String
        let envelopeSHA256: String

        private enum CodingKeys: String, CodingKey {
            case accountScopeHash = "account_scope_hash"
            case documentKind = "document_kind"
            case documentID = "document_id"
            case revision
            case keyID = "key_id"
            case keyHex = "key_hex"
            case nonceHex = "nonce_hex"
            case aadHex = "aad_hex"
            case plaintextBase64 = "plaintext_base64"
            case envelopeBase64 = "envelope_base64"
            case envelopeSHA256 = "envelope_sha256"
        }
    }

    struct KeyWrap: Decodable {
        let accountScopeHash: String
        let documentKeyID: String
        let wrappingKeyID: String
        let wrappingRevision: Int
        let documentKeyHex: String
        let wrappingKeyHex: String
        let nonceHex: String
        let aadHex: String
        let wrappedKeyBase64: String
        let wrappedKeySHA256: String

        private enum CodingKeys: String, CodingKey {
            case accountScopeHash = "account_scope_hash"
            case documentKeyID = "document_key_id"
            case wrappingKeyID = "wrapping_key_id"
            case wrappingRevision = "wrapping_revision"
            case documentKeyHex = "document_key_hex"
            case wrappingKeyHex = "wrapping_key_hex"
            case nonceHex = "nonce_hex"
            case aadHex = "aad_hex"
            case wrappedKeyBase64 = "wrapped_key_base64"
            case wrappedKeySHA256 = "wrapped_key_sha256"
        }
    }

    let version: Int
    let document: Document
    let keyWrap: KeyWrap

    private enum CodingKeys: String, CodingKey {
        case version
        case document
        case keyWrap = "key_wrap"
    }

    static func load(filePath: StaticString = #filePath) throws -> Self {
        var root = URL(fileURLWithPath: "\(filePath)")
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let url = root.appendingPathComponent(
            "Fixtures/managed-document-sync/v1/golden-vectors.json"
        )
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

extension Data {
    init?(managedHex: String) {
        guard managedHex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(managedHex.count / 2)
        var index = managedHex.startIndex
        while index < managedHex.endIndex {
            let end = managedHex.index(index, offsetBy: 2)
            guard let byte = UInt8(managedHex[index..<end], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = end
        }
        self = Data(bytes)
    }

    var managedHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
