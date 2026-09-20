import XCTest
@testable import Strand

final class MacViewerRuntimeContractTests: XCTestCase {
    func testCurrentMacRoleIsViewerOnly() {
        XCTAssertEqual(AppRuntimeRole.currentPlatform, .managedViewer)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.allowsLocalCollection)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.allowsLocalAnalysisAndGuidance)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.hasManagedViewerTransport)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.canPresentOperationalShell)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalCollection)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalAnalysisAndGuidance)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.canPresentOperationalShell)
    }

    func testMacCompositionRootDoesNotActivateCollection() throws {
        let appModel = try text("Strand/App/AppModel.swift")
        let app = try text("Strand/App/StrandApp.swift")
        let manager = try text("Strand/BLE/BLEManager.swift")
        let scale = try text("Strand/BLE/WeightScaleSource.swift")

        XCTAssertTrue(appModel.contains("runtimeRole: AppRuntimeRole = .currentPlatform"))
        XCTAssertTrue(appModel.contains("allowsBluetoothRuntime: runtimeRole.allowsLocalCollection"))
        XCTAssertTrue(
            appModel.contains(
                "if allowsLocalCollection {\n"
                    + "            weightScaleSource.$latestCapture"
            )
        )
        XCTAssertTrue(
            appModel.contains(
                "if allowsLocalCollection {\n"
                    + "            // Physical-input + wear hooks"
            )
        )
        XCTAssertTrue(
            appModel.contains(
                "if allowsLocalCollection {\n"
                    + "            // A newly-published detected session"
            )
        )
        XCTAssertTrue(appModel.contains("if allowsLocalCollection {"))
        XCTAssertTrue(appModel.contains("if self.allowsLocalCollection {\n                await self.wireSourceCoordinator()"))
        XCTAssertTrue(app.contains("if model.allowsLocalCollection {"))
        XCTAssertTrue(app.contains("model.ble.requestSync(.foreground)"))
        XCTAssertTrue(appModel.contains("runtimeRole.allowsLocalAnalysisAndGuidance"))
        XCTAssertTrue(
            appModel.contains(
                "guard runtimeRole.canPresentOperationalShell else"
            )
        )
        XCTAssertTrue(
            appModel.contains(
                #"fields: ["outcome": "unavailable"]"#
            )
        )
        XCTAssertTrue(appModel.contains("Task(priority: .utility) { [weak self] in"))
        XCTAssertFalse(
            try text("Strand/App/RootView.swift")
                .contains("MacLiveHeartRateToolbarSurface()")
        )
        XCTAssertFalse(app.contains("MenuBarExtra"))

        XCTAssertTrue(manager.contains("guard allowsBluetoothRuntime else { return }"))
        XCTAssertTrue(manager.contains("\"outcome\": \"viewer_rejected\""))
        XCTAssertTrue(scale.contains("guard allowsBluetoothRuntime else {\n            statusText = \"Available on the collector phone\""))
        XCTAssertTrue(try text("Strand/App/RootView.swift").contains("var requiresCollectorRole: Bool"))
        XCTAssertTrue(
            try text("Strand/App/RootView.swift").contains(
                "if model.runtimeRole.canPresentOperationalShell"
            )
        )
        XCTAssertTrue(
            try text("Strand/App/RootView.swift").contains(
                "if model.runtimeRole.canPresentOperationalShell {\n"
                    + "            operationalShell\n"
                    + "        } else {\n"
                    + "            MacCollectorPhoneOnlyView()"
            )
        )
    }

    func testMacEntitlementDoesNotGrantBluetoothCollectorAccess() throws {
        let project = try text("project.yml")
        let entitlements = try text("Strand/Resources/Strand.entitlements")
        let strandTarget = try slice(project, from: "  Strand:\n", to: "  StrandTests:\n")
        XCTAssertFalse(
            strandTarget.contains("com.apple.security.device.bluetooth: true"),
            "The managed-viewer target must not carry the Bluetooth device entitlement."
        )
        XCTAssertFalse(
            entitlements.contains("com.apple.security.device.bluetooth"),
            "The checked-in entitlement source must not grant Bluetooth to the viewer."
        )
    }

    func testTodayDoesNotOfferBandControlledLiveSessionToManagedViewer() {
        XCTAssertFalse(
            LiquidTodayView.showsCollectorLiveSessionEntry(
                liveSessionsBeta: true,
                runtimeRole: .managedViewer
            )
        )
        XCTAssertTrue(
            LiquidTodayView.showsCollectorLiveSessionEntry(
                liveSessionsBeta: true,
                runtimeRole: .phoneCollector
            )
        )
        XCTAssertFalse(
            LiquidTodayView.showsCollectorLiveSessionEntry(
                liveSessionsBeta: false,
                runtimeRole: .phoneCollector
            )
        )
    }

    private func text(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }
}
