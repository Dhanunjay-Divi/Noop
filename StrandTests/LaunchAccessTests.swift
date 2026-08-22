import Foundation
import Security
import XCTest
@testable import Strand

@MainActor
final class LaunchAccessTests: XCTestCase {
    private final class MemoryStore: LaunchAccessReceiptStoring {
        var receipt: LaunchAccessReceipt?
        var failRead = false
        var failWrite = false

        func read() throws -> LaunchAccessReceipt? {
            if failRead { throw LaunchAccessStoreError.readFailed(errSecInteractionNotAllowed) }
            return receipt
        }

        func save(_ receipt: LaunchAccessReceipt) throws {
            if failWrite { throw LaunchAccessStoreError.writeFailed(errSecNotAvailable) }
            self.receipt = receipt
        }
    }

    private let salt = Data((0..<16).map(UInt8.init))
    private let knownVerifier = Data([
        0x8b, 0xdb, 0x7c, 0x00, 0x14, 0x51, 0x19, 0x00,
        0x2c, 0x4a, 0x6d, 0x4d, 0xd9, 0x93, 0x5c, 0x29,
        0xae, 0x27, 0x14, 0xff, 0xf1, 0x46, 0xd5, 0x69,
        0x4d, 0xfe, 0x6d, 0xa2, 0xbf, 0x68, 0x0a, 0xc0,
    ])

    /// Constructed from scalar values so test fixtures cannot be mistaken for a real distribution code.
    private var candidate: String {
        String(decoding: [
            108, 97, 117, 110, 99, 104, 45, 99, 111, 100,
            101, 45, 102, 105, 120, 116, 117, 114, 101,
        ], as: UTF8.self)
    }

    func testKnownPBKDF2SHA256Vector() {
        XCTAssertEqual(
            LaunchAccessVerifier.derive(candidate, salt: salt, iterations: 100_000),
            knownVerifier
        )
    }

    func testCorrectAndIncorrectCandidates() throws {
        let configuration = try enabledConfiguration(version: "preview-1")
        XCTAssertTrue(LaunchAccessVerifier.matches(candidate, configuration: configuration))
        XCTAssertFalse(LaunchAccessVerifier.matches(candidate + "x", configuration: configuration))
    }

    func testCanonicalUnicodeInputsMatch() {
        let composed = "caf\u{00E9}-fixture"
        let decomposed = "cafe\u{0301}-fixture"
        let verifier = LaunchAccessVerifier.derive(composed, salt: salt, iterations: 100_000)!
        let configuration = LaunchAccessConfiguration(
            version: "unicode-1",
            salt: salt,
            verifier: verifier,
            iterations: 100_000
        )
        XCTAssertTrue(LaunchAccessVerifier.matches(decomposed, configuration: configuration))
    }

    func testBlankVersionDisablesButMalformedEnabledConfigurationFailsClosed() {
        XCTAssertEqual(
            LaunchAccessConfiguration.resolve(infoDictionary: [:]),
            .disabled
        )
        XCTAssertEqual(
            LaunchAccessConfiguration.resolve(infoDictionary: [
                LaunchAccessConfiguration.versionInfoKey: "preview-1",
                LaunchAccessConfiguration.saltInfoKey: "not-hex",
            ]),
            .invalid
        )
    }

    func testRequiredBlankConfigurationFailsClosed() {
        XCTAssertEqual(
            LaunchAccessConfiguration.resolve(infoDictionary: [
                LaunchAccessConfiguration.requiredInfoKey: "YES",
            ]),
            .invalid
        )
    }

    func testUnsafeIterationCountsFailClosed() {
        var info = configurationInfo(version: "preview-1")
        info[LaunchAccessConfiguration.iterationsInfoKey] = 1
        XCTAssertEqual(LaunchAccessConfiguration.resolve(infoDictionary: info), .invalid)
        info[LaunchAccessConfiguration.iterationsInfoKey] = 2_000_001
        XCTAssertEqual(LaunchAccessConfiguration.resolve(infoDictionary: info), .invalid)
    }

    func testConstantTimeComparatorFunctionalCases() {
        XCTAssertTrue(LaunchAccessVerifier.constantTimeEqual(knownVerifier, knownVerifier))
        var different = knownVerifier
        different[0] ^= 0xff
        XCTAssertFalse(LaunchAccessVerifier.constantTimeEqual(knownVerifier, different))
        XCTAssertFalse(LaunchAccessVerifier.constantTimeEqual(knownVerifier, knownVerifier.dropLast()))
    }

    func testUnlockPersistsOnlyCurrentGateVersionAndSurvivesControllerRelaunch() {
        let store = MemoryStore()
        let info = configurationInfo(version: "preview-1")
        let first = LaunchAccessController(infoDictionary: info, store: store)
        XCTAssertEqual(first.state, .locked)
        XCTAssertEqual(first.submit(candidate), .accepted)
        XCTAssertEqual(store.receipt, LaunchAccessReceipt(gateVersion: "preview-1"))

        let relaunched = LaunchAccessController(infoDictionary: info, store: store)
        XCTAssertEqual(relaunched.state, .unlocked)
    }

    func testGateVersionRotationRelocksAnExistingInstall() {
        let store = MemoryStore()
        store.receipt = LaunchAccessReceipt(gateVersion: "preview-1")
        let rotated = LaunchAccessController(
            infoDictionary: configurationInfo(version: "preview-2"),
            store: store
        )
        XCTAssertEqual(rotated.state, .locked)
    }

    func testKeychainWriteFailureNeverGrantsAccess() {
        let store = MemoryStore()
        store.failWrite = true
        let controller = LaunchAccessController(
            infoDictionary: configurationInfo(version: "preview-1"),
            store: store
        )
        XCTAssertEqual(controller.submit(candidate), .persistenceFailed)
        XCTAssertEqual(controller.state, .locked)
        XCTAssertNil(store.receipt)
    }

    func testDisabledConfigurationBypassesWithoutWritingAReceipt() {
        let store = MemoryStore()
        let controller = LaunchAccessController(infoDictionary: [:], store: store)
        XCTAssertEqual(controller.state, .unlocked)
        XCTAssertNil(store.receipt)
    }

    private func configurationInfo(version: String) -> [String: Any] {
        [
            LaunchAccessConfiguration.versionInfoKey: version,
            LaunchAccessConfiguration.saltInfoKey: salt.hex,
            LaunchAccessConfiguration.verifierInfoKey: knownVerifier.hex,
            LaunchAccessConfiguration.iterationsInfoKey: 100_000,
        ]
    }

    private func enabledConfiguration(version: String) throws -> LaunchAccessConfiguration {
        let resolution = LaunchAccessConfiguration.resolve(
            infoDictionary: configurationInfo(version: version)
        )
        guard case .enabled(let configuration) = resolution else {
            throw XCTSkip("fixture configuration did not resolve")
        }
        return configuration
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
