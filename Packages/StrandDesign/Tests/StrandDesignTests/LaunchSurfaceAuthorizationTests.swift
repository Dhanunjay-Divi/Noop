import Foundation
import XCTest
@testable import StrandDesign

final class LaunchSurfaceAuthorizationTests: XCTestCase {
    /// Mirrors build 229's Watch wire shape. Decoding the build-230 scrub through this type proves that
    /// a staggered older Watch ignores the new keys but still replaces every cached display value.
    private struct LegacyWatchScoreSnapshot: Decodable {
        let charge: Double?
        let chargeCalibrating: Bool
        let effort: Double?
        let effortCalibrating: Bool
        let rest: Double?
        let restCalibrating: Bool
        let hr: Int?
        let sleepSummary: String
        let asOf: Date
        let scoreDay: String?
    }

    private let gatedInfo: [String: Any] = [
        LaunchSurfaceAuthorization.requiredInfoKey: "YES",
        LaunchSurfaceAuthorization.versionInfoKey: "release-1",
    ]

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "LaunchSurfaceAuthorizationTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testRequiredGateDefaultsDeniedUntilExactVersionIsPublished() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: gatedInfo,
            defaults: defaults
        ))

        XCTAssertTrue(LaunchSurfaceAuthorization.publishAuthorized(
            gateVersion: "release-1",
            infoDictionary: gatedInfo,
            defaults: defaults
        ))
        XCTAssertTrue(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: gatedInfo,
            defaults: defaults
        ))
    }

    func testRotationMalformedPolicyAndClearFailClosed() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(LaunchSurfaceAuthorization.publishAuthorized(
            gateVersion: "release-1",
            infoDictionary: gatedInfo,
            defaults: defaults
        ))
        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: [
                LaunchSurfaceAuthorization.requiredInfoKey: true,
                LaunchSurfaceAuthorization.versionInfoKey: "release-2",
            ],
            defaults: defaults
        ))
        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: [
                LaunchSurfaceAuthorization.requiredInfoKey: "YES",
                LaunchSurfaceAuthorization.versionInfoKey: "$(UNRESOLVED)",
            ],
            defaults: defaults
        ))
        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: [LaunchSurfaceAuthorization.requiredInfoKey: "perhaps"],
            defaults: defaults
        ))
        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: [
                LaunchSurfaceAuthorization.requiredInfoKey: NSNumber(value: 2),
                LaunchSurfaceAuthorization.versionInfoKey: "release-1",
            ],
            defaults: defaults
        ))

        LaunchSurfaceAuthorization.clear(infoDictionary: gatedInfo, defaults: defaults)
        XCTAssertFalse(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: gatedInfo,
            defaults: defaults
        ))
    }

    func testUngatedPolicyDoesNotRequireReceipt() {
        XCTAssertTrue(LaunchSurfaceAuthorization.isAuthorized(
            infoDictionary: [LaunchSurfaceAuthorization.requiredInfoKey: "NO"],
            defaults: nil
        ))
        XCTAssertEqual(
            LaunchSurfaceAuthorization.requirement(infoDictionary: [:]),
            .notRequired
        )
    }

    func testLegacyWatchPayloadDecodesButCannotOpenGatedSurface() throws {
        let json = #"{"charge":72,"chargeCalibrating":false,"effort":41,"effortCalibrating":false,"rest":84,"restCalibrating":false,"hr":58,"sleepSummary":"7h 12m","asOf":0}"#
        let snapshot = try JSONDecoder().decode(WatchScoreSnapshot.self, from: Data(json.utf8))

        XCTAssertTrue(snapshot.launchGateRequired)
        XCTAssertNil(snapshot.launchGateVersion)
        XCTAssertFalse(snapshot.launchGateAuthorized)
        XCTAssertFalse(snapshot.isLaunchSurfaceAuthorized(infoDictionary: gatedInfo))
    }

    func testWatchSnapshotRequiresExactEmbeddedAuthorization() {
        let authorized = WatchScoreSnapshot(
            charge: 72,
            chargeCalibrating: false,
            effort: 41,
            effortCalibrating: false,
            rest: 84,
            restCalibrating: false,
            hr: 58,
            sleepSummary: "7h 12m",
            asOf: Date(),
            launchGateRequired: true,
            launchGateVersion: "release-1",
            launchGateAuthorized: true
        )

        XCTAssertTrue(authorized.isLaunchSurfaceAuthorized(infoDictionary: gatedInfo))
        XCTAssertFalse(authorized.isLaunchSurfaceAuthorized(infoDictionary: [
            LaunchSurfaceAuthorization.requiredInfoKey: true,
            LaunchSurfaceAuthorization.versionInfoKey: "release-2",
        ]))
    }

    func testLockedScrubClearsBuild229WatchValuesAndDeniesCurrentWatch() throws {
        let scrub = WatchScoreSnapshot.launchLocked(authorization: LaunchSurfaceAuthorization(
            required: true,
            gateVersion: "release-1",
            authorized: true
        ))
        let data = try JSONEncoder().encode(scrub)

        // The immediately preceding Watch build ignores build 230's extra keys, but all fields it can
        // render are explicitly overwritten with neutral stale state.
        let legacy = try JSONDecoder().decode(LegacyWatchScoreSnapshot.self, from: data)
        XCTAssertNil(legacy.charge)
        XCTAssertFalse(legacy.chargeCalibrating)
        XCTAssertNil(legacy.effort)
        XCTAssertFalse(legacy.effortCalibrating)
        XCTAssertNil(legacy.rest)
        XCTAssertFalse(legacy.restCalibrating)
        XCTAssertNil(legacy.hr)
        XCTAssertEqual(legacy.sleepSummary, "")
        XCTAssertEqual(legacy.asOf, Date(timeIntervalSince1970: 0))
        XCTAssertNil(legacy.scoreDay)

        // A gate-aware Watch sees the same payload as an explicit denial for the exact release version.
        let current = try JSONDecoder().decode(WatchScoreSnapshot.self, from: data)
        XCTAssertTrue(current.launchGateRequired)
        XCTAssertEqual(current.launchGateVersion, "release-1")
        XCTAssertFalse(current.launchGateAuthorized)
        XCTAssertFalse(current.isLaunchSurfaceAuthorized(infoDictionary: gatedInfo))
    }

    func testLockedStrengthScrubIsLegacyDecodableAndEmpty() throws {
        let data = try JSONEncoder().encode(WatchStrengthPlan.launchLocked)
        let decoded = try JSONDecoder().decode(WatchStrengthPlan.self, from: data)

        XCTAssertTrue(decoded.routines.isEmpty)
        XCTAssertNil(decoded.activeSessionName)
        XCTAssertEqual(decoded.activeCompletedSets, 0)
        XCTAssertEqual(decoded.activeTargetSets, 0)
        XCTAssertEqual(decoded.updatedAt, Date(timeIntervalSince1970: 0))
    }
}
