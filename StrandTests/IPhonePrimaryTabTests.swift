import XCTest
@testable import Strand

final class IPhonePrimaryTabTests: XCTestCase {
    func testPrimaryOrderKeepsFriendsVisibleAndMoreLast() {
        XCTAssertEqual(
            IPhonePrimaryTab.allCases,
            [.today, .trends, .friends, .sleep, .more]
        )
        XCTAssertEqual(IPhonePrimaryTab.friends.rawValue, 2)
        XCTAssertEqual(IPhonePrimaryTab.sleep.rawValue, 3)
        XCTAssertEqual(IPhonePrimaryTab.more.rawValue, 4)
    }

    func testFiveTabCompactRailRetainsMinimumTouchWidth() {
        XCTAssertEqual(IPhonePrimaryTab.allCases.count, 5)
        XCTAssertLessThanOrEqual(IPhonePrimaryTab.compactMinimumViewportWidth, 320)
        XCTAssertGreaterThanOrEqual(
            IPhonePrimaryTab.compactItemWidth(in: 320),
            IPhonePrimaryTab.minimumTouchDimension
        )
    }

    func testInvitationNamesThePrimaryFriendsEntryPoint() {
        XCTAssertTrue(FriendsNavigationCopy.invitationInstruction.contains("Friends tab"))
        XCTAssertFalse(FriendsNavigationCopy.invitationInstruction.contains("More → Friends"))
    }

    @MainActor
    func testFriendsSummaryDefaultsAreBoundedAndOptInForVitals() {
        let visibility = FriendsService.Visibility()
        XCTAssertTrue(visibility.charge)
        XCTAssertTrue(visibility.effort)
        XCTAssertTrue(visibility.rest)
        XCTAssertFalse(visibility.sleepDuration)
        XCTAssertFalse(visibility.hrv)
        XCTAssertFalse(visibility.rhr)
    }
}
