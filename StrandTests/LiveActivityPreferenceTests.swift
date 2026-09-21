import Foundation
import XCTest
@testable import Strand

final class LiveActivityPreferenceTests: XCTestCase {
    private func makeDefaults() -> (String, UserDefaults) {
        let suite = "LiveActivityPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    func testFreshInstallRequiresExplicitOptIn() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UnitPrefs.liveActivityEnabled(defaults: defaults))
        XCTAssertFalse(UnitPrefs.liveActivityShowsCharge(defaults: defaults))
        XCTAssertFalse(UnitPrefs.liveActivityShowsEffort(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: UnitPrefs.liveActivityPrivacyMigrationKey))
    }

    func testEstablishedInstallStillRequiresExplicitOptIn() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "noop.onboarded")

        UnitPrefs.migrateLiveActivityPrivacyIfNeeded(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: UnitPrefs.liveActivityKey))
        XCTAssertFalse(defaults.bool(forKey: UnitPrefs.liveActivityChargeKey))
        XCTAssertFalse(defaults.bool(forKey: UnitPrefs.liveActivityEffortKey))
    }

    func testMigrationNeverOverwritesStoredUserChoices() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "noop.onboarded")
        defaults.set(false, forKey: UnitPrefs.liveActivityKey)
        defaults.set(false, forKey: UnitPrefs.liveActivityChargeKey)
        defaults.set(true, forKey: UnitPrefs.liveActivityEffortKey)

        UnitPrefs.migrateLiveActivityPrivacyIfNeeded(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: UnitPrefs.liveActivityKey))
        XCTAssertFalse(defaults.bool(forKey: UnitPrefs.liveActivityChargeKey))
        XCTAssertTrue(defaults.bool(forKey: UnitPrefs.liveActivityEffortKey))

        defaults.set(true, forKey: UnitPrefs.liveActivityKey)
        UnitPrefs.migrateLiveActivityPrivacyIfNeeded(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: UnitPrefs.liveActivityKey),
                      "An idempotent migration must not restore an earlier preference.")
    }

    func testForegroundAndMacPresentationStartPrivateAndIndependent() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(
            LiveHeartRatePresentationPreferences.inAppBannerEnabled(defaults: defaults)
        )
        XCTAssertFalse(
            LiveHeartRatePresentationPreferences.macToolbarEnabled(defaults: defaults)
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: LiveHeartRatePresentationPreferences.privacyMigrationKey
            )
        )

        defaults.set(
            true,
            forKey: LiveHeartRatePresentationPreferences.inAppBannerKey
        )
        XCTAssertTrue(
            LiveHeartRatePresentationPreferences.inAppBannerEnabled(defaults: defaults)
        )
        XCTAssertFalse(
            LiveHeartRatePresentationPreferences.macToolbarEnabled(defaults: defaults)
        )
    }

    func testPresentationMigrationPreservesExistingChoices() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            true,
            forKey: LiveHeartRatePresentationPreferences.macToolbarKey
        )

        LiveHeartRatePresentationPreferences.migratePrivacyIfNeeded(
            defaults: defaults
        )

        XCTAssertTrue(
            defaults.bool(
                forKey: LiveHeartRatePresentationPreferences.macToolbarKey
            )
        )
        XCTAssertFalse(
            defaults.bool(
                forKey: LiveHeartRatePresentationPreferences.inAppBannerKey
            )
        )
    }

    func testPresentationDistinguishesWaitingFromStaleReconnection() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: nil,
                observedAt: nil,
                now: now
            ),
            .waiting
        )
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: 61,
                observedAt: now.addingTimeInterval(-10 * 60),
                now: now
            ),
            .reconnecting
        )
        XCTAssertEqual(
            LiveHeartRatePresentationState.resolve(
                enabled: true,
                connected: true,
                bpm: 61,
                observedAt: now.addingTimeInterval(-10),
                now: now
            ),
            .live(61)
        )
    }
}
