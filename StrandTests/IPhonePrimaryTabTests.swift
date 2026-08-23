import XCTest
@testable import Strand

final class IPhonePrimaryTabTests: XCTestCase {
    func testPrimaryOrderKeepsWorkoutsVisibleAndMoreLast() {
        XCTAssertEqual(
            IPhonePrimaryTab.allCases,
            [.today, .trends, .activity, .sleep, .more]
        )
        XCTAssertEqual(IPhonePrimaryTab.activity.rawValue, 2)
        XCTAssertEqual(IPhonePrimaryTab.sleep.rawValue, 3)
        XCTAssertEqual(IPhonePrimaryTab.more.rawValue, 4)
    }

    func testCompactNavigationDisclosureRetainsMinimumTouchSize() {
        XCTAssertEqual(IPhonePrimaryTab.allCases.count, 5)
        XCTAssertGreaterThanOrEqual(
            IPhonePrimaryTab.compactControlDimension,
            IPhonePrimaryTab.minimumTouchDimension
        )
    }

    func testInvitationNamesTheFriendsEntryPointInMore() {
        XCTAssertTrue(FriendsNavigationCopy.invitationInstruction.contains("More → Friends"))
        XCTAssertFalse(FriendsNavigationCopy.invitationInstruction.contains("Friends tab"))
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
