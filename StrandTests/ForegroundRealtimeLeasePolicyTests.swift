import XCTest
@testable import Strand

final class ForegroundRealtimeLeasePolicyTests: XCTestCase {
    func testDefaultStateWaitsForExplicitForegroundSignal() {
        var policy = ForegroundRealtimeLeasePolicy()
        XCTAssertEqual(policy.requestLease(), .none)
        XCTAssertFalse(policy.transportArmed)
        XCTAssertEqual(policy.setForeground(true), .arm)
    }

    func testOpeningSurfaceWithoutExplicitLeaseDoesNotArm() {
        let policy = ForegroundRealtimeLeasePolicy(isForeground: true)
        XCTAssertFalse(policy.shouldArm)
        XCTAssertFalse(policy.transportArmed)
    }

    func testFirstLeaseArmsAndNestedLeasesBalanceOnLastRelease() {
        var policy = ForegroundRealtimeLeasePolicy(isForeground: true)
        XCTAssertEqual(policy.requestLease(), .arm)
        XCTAssertEqual(policy.requestLease(), .none)
        XCTAssertEqual(policy.leaseCount, 2)
        XCTAssertEqual(policy.releaseLease(), .none)
        XCTAssertEqual(policy.releaseLease(), .disarm)
        XCTAssertEqual(policy.leaseCount, 0)
    }

    func testBackgroundDisarmsButRetainsIntentAndForegroundRearmsOnce() {
        var policy = ForegroundRealtimeLeasePolicy(isForeground: true)
        XCTAssertEqual(policy.requestLease(), .arm)
        XCTAssertEqual(policy.setForeground(false), .disarm)
        XCTAssertEqual(policy.leaseCount, 1, "Backgrounding must not consume the visible session's lease.")
        XCTAssertEqual(policy.setForeground(false), .none)
        XCTAssertEqual(policy.setForeground(true), .arm)
        XCTAssertEqual(policy.setForeground(true), .none)
        XCTAssertEqual(policy.releaseLease(), .disarm)
    }

    func testLeaseRequestedInBackgroundWaitsForForeground() {
        var policy = ForegroundRealtimeLeasePolicy(isForeground: false)
        XCTAssertEqual(policy.requestLease(), .none)
        XCTAssertFalse(policy.transportArmed)
        XCTAssertEqual(policy.setForeground(true), .arm)
    }

    func testExtraReleaseClampsWithoutSpuriousTransportEdge() {
        var policy = ForegroundRealtimeLeasePolicy(isForeground: true)
        XCTAssertEqual(policy.releaseLease(), .none)
        XCTAssertEqual(policy.leaseCount, 0)
        XCTAssertFalse(policy.transportArmed)
    }

    func testLiveUiRequiresStartAndExplainsBatteryAndIndependentCapture() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/LiveView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("@State private var liveTrackingOptedIn = false"))
        XCTAssertTrue(source.contains("Start Live Tracking"))
        XCTAssertTrue(source.contains("uses more Noop Band and phone battery"))
        XCTAssertTrue(source.contains("only while this Live screen and NOOP are in the foreground"))
        XCTAssertTrue(source.contains("Continuous HRV capture is a separate option in Settings"))
        XCTAssertTrue(source.contains(".onAppear { refreshConnectionSnapshot(); consumeActiveWorkoutRequest() }"),
                      "Opening Live must refresh status only, never acquire the realtime lease.")
    }

    func testHealthHeartRateRequiresExplicitBalancedLiveLease() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/HealthView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("@State private var liveTrackingOptedIn = false"))
        XCTAssertTrue(source.contains("HealthLiveTrackingLeaseLifetime("))
        XCTAssertTrue(source.contains("@Binding var liveTrackingOptedIn: Bool"))
        XCTAssertTrue(source.contains("liveTrackingLatestSample?.sequence ?? 0"),
                      "Start must wait for a newer sensor packet rather than displaying cached BPM.")
        XCTAssertTrue(source.contains(".onReceive(live.heartRateSamplePublisher)"),
                      "An unchanged BPM packet must still wake the local Live indicator.")
        XCTAssertTrue(source.contains("Start Live HR"))
        XCTAssertTrue(source.contains("Stop Live HR"))
        XCTAssertTrue(source.contains("model.startRealtimeHR()"))
        XCTAssertTrue(source.contains("model.stopRealtimeHR()"))
        XCTAssertTrue(source.contains(".onAppear { prepareLiveDisplayForMountedRow() }"))
        XCTAssertFalse(source.contains(".onDisappear { stopLiveTracking() }"),
                       "Lazy row recycling must not consume the screen-owned lease.")
        XCTAssertTrue(source.contains(".onDisappear {\n                guard liveTrackingOptedIn else { return }"))
        XCTAssertTrue(source.contains("if !hasLiveHR && !live.connected"),
                      "A connected first-time user must be able to reach Start Live HR before history exists.")
        XCTAssertFalse(source.contains(".onAppear { startLiveTracking() }"))
    }
}
