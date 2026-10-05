import XCTest
@testable import Strand

@MainActor
final class BandPresentationScanTests: XCTestCase {
    func testDisconnectedPairedBandResumesAfterPresentationCancellation() {
        XCTAssertTrue(
            BLEManager.shouldResumeConnectionAfterPresentScan(
                intentionalDisconnect: false,
                connected: false,
                bonded: true,
                hasReconnectTarget: true,
                pendingConnect: false,
                normalScanActive: true
            )
        )
    }

    func testInFlightReconnectScanResumesWithoutAConnectedPeripheral() {
        XCTAssertTrue(
            BLEManager.shouldResumeConnectionAfterPresentScan(
                intentionalDisconnect: false,
                connected: false,
                bonded: false,
                hasReconnectTarget: false,
                pendingConnect: false,
                normalScanActive: true
            )
        )
    }

    func testFreshInstallCancellationDoesNotInventAConnection() {
        XCTAssertFalse(
            BLEManager.shouldResumeConnectionAfterPresentScan(
                intentionalDisconnect: false,
                connected: false,
                bonded: false,
                hasReconnectTarget: false,
                pendingConnect: false,
                normalScanActive: false
            )
        )
    }

    func testPendingConnectionRequestResumesAfterPresentationCancellation() {
        XCTAssertTrue(
            BLEManager.shouldResumeConnectionAfterPresentScan(
                intentionalDisconnect: false,
                connected: false,
                bonded: false,
                hasReconnectTarget: false,
                pendingConnect: true,
                normalScanActive: false
            )
        )
    }

    func testIntentionalDisconnectRemainsAuthoritative() {
        XCTAssertFalse(
            BLEManager.shouldResumeConnectionAfterPresentScan(
                intentionalDisconnect: true,
                connected: true,
                bonded: true,
                hasReconnectTarget: true,
                pendingConnect: true,
                normalScanActive: true
            )
        )
    }

    func testAbandonedPresentationRestoresDurableIntentAndBondSnapshot() {
        let suiteName = "BandPresentationScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = BLEManager.PresentScanResumeContext(
            model: .whoop4,
            persistedModelRaw: WhoopModel.whoop4.rawValue,
            bluetoothIntent: true,
            bluetoothReleased: false,
            monitoringExpected: true,
            shouldReconnect: true,
            bonded: true,
            encryptedBond: true
        )

        BLEManager.persistPresentScanResumeContext(context, defaults: defaults)
        defaults.set(WhoopModel.whoop5mg.rawValue, forKey: "selectedWhoopModel")
        defaults.set(false, forKey: "noop.bluetooth.userPrimed")
        defaults.set(true, forKey: "noop.bluetooth.explicitlyReleased")
        defaults.set(
            false,
            forKey: BluetoothAvailabilityNotifications.monitoringExpectedKey
        )

        let restored = BLEManager.consumeAbandonedPresentScanResumeContext(
            defaults: defaults
        )

        XCTAssertEqual(restored, context)
        XCTAssertEqual(
            defaults.string(forKey: "selectedWhoopModel"),
            WhoopModel.whoop4.rawValue
        )
        XCTAssertTrue(defaults.bool(forKey: "noop.bluetooth.userPrimed"))
        XCTAssertFalse(defaults.bool(forKey: "noop.bluetooth.explicitlyReleased"))
        XCTAssertTrue(
            defaults.bool(
                forKey: BluetoothAvailabilityNotifications.monitoringExpectedKey
            )
        )
        XCTAssertNil(defaults.data(forKey: BLEManager.presentScanResumeContextKey))
        XCTAssertTrue(restored?.bonded == true)
        XCTAssertTrue(restored?.encryptedBond == true)
    }

    func testCorruptAbandonedPresentationIsClearedWithoutChangingPreferences() {
        let suiteName = "BandPresentationScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data("not-json".utf8),
            forKey: BLEManager.presentScanResumeContextKey
        )
        defaults.set(WhoopModel.whoop5mg.rawValue, forKey: "selectedWhoopModel")

        XCTAssertNil(
            BLEManager.consumeAbandonedPresentScanResumeContext(
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: "selectedWhoopModel"),
            WhoopModel.whoop5mg.rawValue
        )
        XCTAssertNil(defaults.data(forKey: BLEManager.presentScanResumeContextKey))
    }
}
