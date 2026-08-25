import XCTest
@testable import Strand
import WhoopStore

/// Pins the Devices card's state-pill priority (#221): "Connected · not paired" must beat "Active · Live"
/// but yield to a reboot's "Reconnecting…". Mirrors the Kotlin `DevicePillStateTest` exactly — a silent
/// reorder on either platform would otherwise only be caught by eyeballing a screenshot.
final class DevicePillStateTests: XCTestCase {

    func testBondRefused_beatsActiveLive_butYieldsToReconnecting() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: true, isLiveConnected: true).label,
            "Connected · not paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: true,
                                     bondRefused: true, isLiveConnected: true).label,
            "Reconnecting…")
    }

    func testNormalConnect_isUnaffected() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: true).label,
            "Active · Live")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Active")
    }

    func testNonActiveAndArchived() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: true, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Removed")
    }

    func testUnknownBandModelUsesProductName() {
        let device = PairedDevice(id: "my-whoop", brand: "WHOOP", model: "WHOOP",
                                  nickname: nil, peripheralId: nil, sourceKind: .liveBLE,
                                  capabilities: [.hr, .hrv], status: .active,
                                  addedAt: 0, lastSeenAt: 0)
        XCTAssertEqual(DeviceCapabilityProfile.make(for: device).displayModel, "Noop Band")
    }

    func testBandCustomerNameAndVisibleDiagnosticsHideVendorBrand() {
        XCTAssertEqual(WhoopModel.whoop4.displayName, "Noop Band")
        XCTAssertEqual(WhoopModel.whoop5mg.displayName, "Noop Band")
        XCTAssertEqual(WhoopModel.whoop4.transportName, "legacy band")
        XCTAssertEqual(WhoopModel.whoop5mg.transportName, "newer band")
    }

    func testDevicesDefaultHierarchyKeepsDiagnosticsBehindDisclosure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/DevicesView.swift"))
        XCTAssertTrue(source.contains("private var emptyDevicesHero"))
        XCTAssertTrue(source.contains("Text(\"Add your first device\")"))
        XCTAssertTrue(source.contains("DisclosureGroup(isExpanded: $showTechnicalDetails)"))
        XCTAssertTrue(source.contains("Text(\"Technical details\")"))
        XCTAssertFalse(source.contains("Button(action: action) { cardContent }"),
                       "A disclosure cannot be nested in the whole-card activation button.")
    }
}
