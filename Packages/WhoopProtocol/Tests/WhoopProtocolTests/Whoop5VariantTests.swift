import XCTest
@testable import WhoopProtocol

final class Whoop5VariantTests: XCTestCase {

    func testSerialPrefixIdentifiesMG() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AM12345678"), .mg)
        XCTAssertTrue(Whoop5Variant.from(serial: "5AM12345678").isMG)
        // Real WHOOP Life/MG validation fixture (identifier deliberately truncated to its
        // capability-bearing prefix; no personal device serial belongs in source control).
        XCTAssertEqual(Whoop5Variant.from(serial: "MGB00000000"), .mg)
    }

    func testSerialPrefixIdentifiesFiveZero() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678"), .fiveZero)
        XCTAssertFalse(Whoop5Variant.from(serial: "5AG12345678").isMG)
    }

    func testHardwareRevisionIsDeviceAttestedFiveZero() {
        // The observed 5.0 hardware id, with no serial available at all.
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WG50_r52"), .fiveZero)
    }

    func testHardwareRevisionIsDeviceAttestedMG() {
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WS50_r03"), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: " ws50_R00 "), .mg)
    }

    func testAdvertisedNamePrefixTolerated() {
        // Callers may pass the advertised name instead of the DIS serial.
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP 5AM12345678"), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: " whoop mgb00000000 "), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: " whoop   mgb00000000 ", hardwareRevision: " ws50_r03 "), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: "  whoop 5ag12345678  "), .fiveZero)
    }

    func testContradictionYieldsUnknownRatherThanAGuess() {
        // Both board families are attested; disagreement still means the evidence or our model is
        // incomplete, so refuse to pick a winner (#716: a mis-stamped model is worse than none).
        XCTAssertEqual(Whoop5Variant.from(serial: "5AM12345678", hardwareRevision: "WG50_r52"), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "MGB00000000", hardwareRevision: "WG50_r52"), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678", hardwareRevision: "WS50_r03"), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WS50_WG50_r03"), .unknown)
    }

    func testAgreeingSignalsResolve() {
        XCTAssertEqual(Whoop5Variant.from(serial: "5AG12345678", hardwareRevision: "WG50_r52"), .fiveZero)
        XCTAssertEqual(Whoop5Variant.from(serial: "MGB00000000", hardwareRevision: "WS50_r03"), .mg)
        XCTAssertEqual(Whoop5Variant.from(serial: "5AM12345678", hardwareRevision: "WS50_r03"), .mg)
    }

    func testUnattestedInputsAreUnknownNeverInferred() {
        XCTAssertEqual(Whoop5Variant.from(serial: nil), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: ""), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP"), .unknown)
        // A stray digit in the name must NOT imply a generation (#772 — the bug that read a
        // serial's "5" as Gen5 on a Gen3 ring; same failure mode, different product).
        XCTAssertEqual(Whoop5Variant.from(serial: "WHOOP 4.0"), .unknown)
        XCTAssertEqual(Whoop5Variant.from(serial: "5XX99999999"), .unknown)
        // A made-up token must not be confused with the attested WS50 MG board prefix.
        XCTAssertEqual(Whoop5Variant.from(serial: nil, hardwareRevision: "WGMG_r01"), .unknown)
    }

    func testLabels() {
        XCTAssertEqual(Whoop5Variant.mg.label, "MG")
        XCTAssertEqual(Whoop5Variant.fiveZero.label, "5.0")
        XCTAssertEqual(Whoop5Variant.unknown.label, "—")
        XCTAssertEqual(Whoop5Variant.mg.registryModelLabel, "WHOOP MG")
        XCTAssertEqual(Whoop5Variant.fiveZero.registryModelLabel, "WHOOP 5.0")
        XCTAssertNil(Whoop5Variant.unknown.registryModelLabel)
    }
}
