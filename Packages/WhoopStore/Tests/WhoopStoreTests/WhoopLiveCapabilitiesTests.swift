import XCTest
@testable import WhoopStore

final class WhoopLiveCapabilitiesTests: XCTestCase {
    func testLiveCapabilitiesWithholdUnvalidatedStepsForEveryGeneration() {
        XCTAssertEqual(WhoopLiveCapabilities.metrics(forModel: "4.0"),
                       [.hr, .hrv, .skinTemp, .sleep, .strainLoad])
        XCTAssertEqual(WhoopLiveCapabilities.metrics(forModel: "5.0 MG"),
                       [.hr, .hrv, .skinTemp, .sleep, .strainLoad])
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP MG").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP 5.0").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP 5.0 / MG").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "WHOOP 4.0").contains(.steps))
        XCTAssertFalse(WhoopLiveCapabilities.metrics(forModel: "5.0 MG").contains(.spo2))
    }

    func testEncodingAndRuntimeSanitizerWithholdUnvalidatedMetrics() {
        XCTAssertEqual(WhoopLiveCapabilities.encoded(forModel: "4.0"),
                       "hr,hrv,skinTemp,sleep,strainLoad")
        XCTAssertEqual(WhoopLiveCapabilities.encoded(forModel: "5.0 MG"),
                       "hr,hrv,skinTemp,sleep,strainLoad")
        XCTAssertEqual(
            WhoopLiveCapabilities.stripUnvalidatedLiveTokens(
                fromEncoded: "hr,hrv,spo2,skinTemp,sleep,steps,strainLoad"),
            "hr,hrv,skinTemp,sleep,strainLoad"
        )
        XCTAssertEqual(
            WhoopLiveCapabilities.withoutUnvalidatedLiveMetrics(
                [.hr, .spo2, .steps, .strainLoad]
            ),
            [.hr, .strainLoad]
        )
    }
}
