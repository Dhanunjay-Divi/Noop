import XCTest
import WhoopProtocol
@testable import Strand

final class Whoop5ClientHelloAckTests: XCTestCase {
    func testNoOutstandingHelloDoesNotEstablishBond() {
        XCTAssertFalse(Whoop5ClientHelloAck.shouldEstablishBond(
            family: .whoop5,
            alreadyBonded: false,
            helloPending: false,
            callbackMatchesCommandCharacteristic: true
        ))
    }

    func testUnrelatedWriteDoesNotEstablishBond() {
        XCTAssertFalse(Whoop5ClientHelloAck.shouldEstablishBond(
            family: .whoop5,
            alreadyBonded: false,
            helloPending: true,
            callbackMatchesCommandCharacteristic: false
        ))
    }

    func testOutstandingHelloOnItsCharacteristicEstablishesBond() {
        XCTAssertTrue(Whoop5ClientHelloAck.shouldEstablishBond(
            family: .whoop5,
            alreadyBonded: false,
            helloPending: true,
            callbackMatchesCommandCharacteristic: true
        ))
    }

    func testAlreadyBondedOrLegacyFamilyDoesNotReestablishBond() {
        XCTAssertFalse(Whoop5ClientHelloAck.shouldEstablishBond(
            family: .whoop5,
            alreadyBonded: true,
            helloPending: true,
            callbackMatchesCommandCharacteristic: true
        ))
        XCTAssertFalse(Whoop5ClientHelloAck.shouldEstablishBond(
            family: .whoop4,
            alreadyBonded: false,
            helloPending: true,
            callbackMatchesCommandCharacteristic: true
        ))
    }
}
