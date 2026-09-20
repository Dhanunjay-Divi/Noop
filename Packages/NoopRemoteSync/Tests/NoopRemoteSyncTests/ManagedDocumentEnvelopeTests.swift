import CryptoKit
import XCTest
@testable import NoopRemoteSync

final class ManagedDocumentEnvelopeTests: XCTestCase {
    func testGoldenVectorMatchesAppleImplementation() throws {
        let fixture = try ManagedDocumentGoldenFixture.load()
        let vector = fixture.document
        let metadata = try ManagedDocumentEnvelopeMetadata(
            accountScopeHash: vector.accountScopeHash,
            documentKind: try XCTUnwrap(
                ManagedDocumentKind(rawValue: vector.documentKind)
            ),
            documentID: try XCTUnwrap(UUID(uuidString: vector.documentID)),
            revision: vector.revision
        )
        XCTAssertEqual(metadata.authenticatedData.managedHex, vector.aadHex)
        let envelope = try ManagedDocumentEnvelope.seal(
            try XCTUnwrap(Data(base64Encoded: vector.plaintextBase64)),
            key: try XCTUnwrap(Data(managedHex: vector.keyHex)),
            metadata: metadata,
            nonce: try XCTUnwrap(Data(managedHex: vector.nonceHex))
        )
        XCTAssertEqual(envelope.base64EncodedString(), vector.envelopeBase64)
        XCTAssertEqual(
            ManagedDocumentEnvelopeDigest.sha256(envelope),
            vector.envelopeSHA256
        )
        XCTAssertEqual(
            try ManagedDocumentEnvelope.open(
                envelope,
                key: try XCTUnwrap(Data(managedHex: vector.keyHex)),
                metadata: metadata
            ).base64EncodedString(),
            vector.plaintextBase64
        )
    }

    func testTamperCrossAccountAndRevisionReplayAreRejected() throws {
        let fixture = try ManagedDocumentGoldenFixture.load().document
        let envelope = try XCTUnwrap(Data(base64Encoded: fixture.envelopeBase64))
        let key = try XCTUnwrap(Data(managedHex: fixture.keyHex))
        let documentID = try XCTUnwrap(UUID(uuidString: fixture.documentID))
        let kind = try XCTUnwrap(
            ManagedDocumentKind(rawValue: fixture.documentKind)
        )
        var tampered = envelope
        tampered[tampered.index(before: tampered.endIndex)] ^= 1

        for (candidate, expected) in [
            (
                tampered,
                try ManagedDocumentEnvelopeMetadata(
                    accountScopeHash: fixture.accountScopeHash,
                    documentKind: kind,
                    documentID: documentID,
                    revision: fixture.revision
                )
            ),
            (
                envelope,
                try ManagedDocumentEnvelopeMetadata(
                    accountScopeHash: String(repeating: "b", count: 64),
                    documentKind: kind,
                    documentID: documentID,
                    revision: fixture.revision
                )
            ),
            (
                envelope,
                try ManagedDocumentEnvelopeMetadata(
                    accountScopeHash: fixture.accountScopeHash,
                    documentKind: kind,
                    documentID: documentID,
                    revision: fixture.revision + 1
                )
            ),
        ] {
            XCTAssertThrowsError(
                try ManagedDocumentEnvelope.open(
                    candidate,
                    key: key,
                    metadata: expected
                )
            ) {
                XCTAssertEqual(
                    $0 as? ManagedDocumentEnvelopeError,
                    .authenticationFailed
                )
            }
        }
    }

    func testKeyWrappingGoldenVector() throws {
        let vector = try ManagedDocumentGoldenFixture.load().keyWrap
        let wrapped = try ManagedDocumentKeyWrapEnvelope.seal(
            documentKey: try XCTUnwrap(
                Data(managedHex: vector.documentKeyHex)
            ),
            accountScopeHash: vector.accountScopeHash,
            keyID: try XCTUnwrap(UUID(uuidString: vector.documentKeyID)),
            wrappingKeyID: try XCTUnwrap(
                UUID(uuidString: vector.wrappingKeyID)
            ),
            wrappingRevision: vector.wrappingRevision,
            wrappingKey: try XCTUnwrap(
                Data(managedHex: vector.wrappingKeyHex)
            ),
            nonce: try XCTUnwrap(Data(managedHex: vector.nonceHex))
        )
        XCTAssertEqual(wrapped.base64EncodedString(), vector.wrappedKeyBase64)
        XCTAssertEqual(
            ManagedDocumentEnvelopeDigest.sha256(wrapped),
            vector.wrappedKeySHA256
        )
    }

    func testWrappedDocumentKeyRejectsNonCanonicalEnvelopeSize() {
        XCTAssertThrowsError(
            try ManagedWrappedDocumentKey(
                keyID: UUID(),
                wrappingKeyID: UUID(),
                wrappingRevision: 1,
                wrappedKey: Data(repeating: 1, count: 40)
            )
        )
    }
}
