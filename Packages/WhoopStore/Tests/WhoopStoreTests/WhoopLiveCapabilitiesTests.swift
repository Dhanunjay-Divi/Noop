import XCTest
@testable import WhoopStore

final class WhoopLiveCapabilitiesTests: XCTestCase {
    func testCapabilitiesAreHonestPerGeneration() {
        XCTAssertEqual(WhoopLiveCapabilities.metrics(forModel: "4.0"),
                       [.hr, .hrv, .skinTemp, .sleep, .strainLoad])
        XCTAssertEqual(WhoopLiveCapabilities.metrics(forModel: "5.0 MG"),
                       [.hr, .hrv, .skinTemp, .sleep, .strainLoad, .steps])
        XCTAssertTrue(WhoopLiveCapabilities.metrics(forModel: "WHOOP MG").contains(.steps))
        XCTAssertTrue(WhoopLiveCapabilities.metrics(forModel: "WHOOP 5.0").contains(.steps))
        XCTAssertTrue(WhoopLiveCapabilities.metrics(forModel: "WHOOP 5.0 / MG").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP 4.0").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "5.0 MG").contains(.spo2))
    }

    func testEncodingAndLegacySpo2StripAreStable() {
        XCTAssertEqual(WhoopLiveCapabilities.encoded(forModel: "4.0"),
                       "hr,hrv,skinTemp,sleep,strainLoad")
        XCTAssertEqual(WhoopLiveCapabilities.encoded(forModel: "5.0 MG"),
                       "hr,hrv,skinTemp,sleep,steps,strainLoad")
        XCTAssertEqual(
            WhoopLiveCapabilities.stripSpo2Token(
                fromEncoded: "hr,hrv,spo2,skinTemp,sleep,strainLoad"),
            "hr,hrv,skinTemp,sleep,strainLoad"
        )
    }
}
