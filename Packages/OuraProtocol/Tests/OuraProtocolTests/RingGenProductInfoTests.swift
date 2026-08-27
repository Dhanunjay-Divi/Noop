import XCTest
@testable import OuraProtocol

final class RingGenProductInfoTests: XCTestCase {
    func testRecogniseRequiresAnExplicitGenerationToken() {
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Ring Gen3"), .gen3)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Ring 4"), .gen4)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "OURA RING GEN5"), .gen5)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Horizon"), .gen3)
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "Oura 2H3B2405003655"))
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "WHOOP 5.0"))
        XCTAssertNil(OuraRingGen.recognise(advertisedName: nil))
    }

    func testHardwareIdMapsKnownGenerationsOnly() {
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_03"), .gen3)
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_04"), .gen4)
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_05"), .gen5)
        XCTAssertNil(OuraRingGen.from(hardwareId: "2H3B2405003655"))
        XCTAssertNil(OuraRingGen.from(hardwareId: "BLB_09"))
        XCTAssertNil(OuraRingGen.from(hardwareId: "BLB_"))
    }

    func testProductInfoStringSkipsStatusAndStopsAtNull() {
        let hardware: [UInt8] = [0x00, 0x42, 0x4C, 0x42, 0x5F, 0x30, 0x33, 0x00, 0x00]
        let serial: [UInt8] = [0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35,
                               0x30, 0x30, 0x33, 0x36, 0x35, 0x35, 0x00]
        XCTAssertEqual(OuraDecoders.productInfoString(hardware), "BLB_03")
        XCTAssertEqual(OuraDecoders.productInfoString(serial), "2H3B2405003655")
        XCTAssertEqual(
            OuraDecoders.productInfoString(hardware).flatMap(OuraRingGen.from(hardwareId:)),
            .gen3
        )
        XCTAssertNil(OuraDecoders.productInfoString(serial).flatMap(OuraRingGen.from(hardwareId:)))
        XCTAssertNil(OuraDecoders.productInfoString([0x01, 0x42, 0x4C, 0x42, 0x5F, 0x30, 0x35]))
        XCTAssertNil(OuraDecoders.productInfoString([]))
        XCTAssertNil(OuraDecoders.productInfoString([0x00, 0x00]))
    }
}
