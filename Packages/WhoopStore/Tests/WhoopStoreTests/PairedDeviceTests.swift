import XCTest
@testable import WhoopStore

final class PairedDeviceSourceKindTests: XCTestCase {
    func testLiveAppleWatchSourceKindExists() {
        XCTAssertEqual(SourceKind(rawValue: "liveAppleWatch"), .liveAppleWatch)
        XCTAssertTrue(SourceKind.allCases.contains(.liveAppleWatch))
    }

    func testTransportAssignedBandNameStaysOutOfProductUI() {
        let device = PairedDevice(
            id: "whoop-demo",
            brand: "WHOOP",
            model: "5.0 MG",
            nickname: "WHOOP 5AG0146459",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .active,
            addedAt: 0,
            lastSeenAt: 0
        )

        XCTAssertEqual(device.displayName, "Noop Band")
    }

    func testUserAssignedBandNameStillWins() {
        let device = PairedDevice(
            id: "whoop-demo",
            brand: "WHOOP",
            model: "5.0 MG",
            nickname: "Morning Band",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .active,
            addedAt: 0,
            lastSeenAt: 0
        )

        XCTAssertEqual(device.displayName, "Morning Band")
    }
}
