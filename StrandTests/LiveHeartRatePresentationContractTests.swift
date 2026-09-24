import Foundation
import XCTest
@testable import Strand
import WhoopStore

final class LiveHeartRatePresentationContractTests: XCTestCase {
    func testPhoneSurfaceRemainsConfigurableAndViewerHasNoFalseLiveSurface() throws {
        let root = repositoryRoot()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Strand/Screens/SettingsView.swift"),
            encoding: .utf8
        )
        let phone = try String(
            contentsOf: root.appendingPathComponent("StrandiOS/App/StrandiOSApp.swift"),
            encoding: .utf8
        )
        let mac = try String(
            contentsOf: root.appendingPathComponent("Strand/App/RootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            settings.contains(
                "LiveHeartRatePresentationPreferences.inAppBannerKey"
            )
        )
        XCTAssertFalse(
            settings.contains(
                "LiveHeartRatePresentationPreferences.macToolbarKey"
            )
        )
        XCTAssertTrue(phone.contains("InAppLiveHeartRateBanner(live: model.live)"))
        XCTAssertTrue(phone.contains("scenePhase == .active"))
        XCTAssertFalse(mac.contains("MacLiveHeartRateToolbarSurface()"))
        XCTAssertTrue(
            settings.contains(
                #"LocalizedStringKey("appwide.health.live_activity.compact_detail")"#
            )
        )
        XCTAssertTrue(
            settings.contains(
                #"LocalizedStringKey("appwide.health.live_activity.detail")"#
            )
        )
    }

    func testPresentationUsesFreshPacketTimeAndNeverLogsHeartRateValues() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Strand/System/LiveHeartRatePresentation.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("live.displayedHeartRate"))
        XCTAssertTrue(source.contains("live.displayedHeartRateReceivedAt"))
        XCTAssertTrue(source.contains("LiveHeartRateSurfacePolicy.isLive"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("case reconnecting"))
        XCTAssertFalse(source.contains(".fixedSize(horizontal: true"))
        XCTAssertTrue(source.contains("\"surface\": surface"))
        XCTAssertTrue(source.contains("\"state\": enabled ? \"enabled\" : \"disabled\""))
        XCTAssertFalse(source.contains("\"bpm\":"))
        XCTAssertFalse(source.contains("\"heart_rate\":"))
    }

    func testLiveActivityLifecycleIsBoundedAndPrivacySafe() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "StrandiOS/Widgets/LiveActivityController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("failedStartRetryDelay: TimeInterval = 30"))
        XCTAssertTrue(source.contains("desired.now >= startRetryNotBefore"))
        XCTAssertTrue(source.contains(#""live_hr.live_activity""#))
        XCTAssertTrue(source.contains(#"operation: "start""#))
        XCTAssertTrue(source.contains(#"operation: "update""#))
        XCTAssertTrue(source.contains(#"operation: "end""#))
        XCTAssertTrue(source.contains(#"failureKind: "platform""#))
        XCTAssertFalse(source.contains(#""bpm": bpm"#))
        XCTAssertFalse(source.contains(#""error": error"#))
    }

    func testSupplierDisplayHeartRatePrecedesAcceptedFallbackOnLiveSurface() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Strand/Screens/LiveView.swift"
            ),
            encoding: .utf8
        )
        let precedence = "live.displayOnlyHeartRate ?? model.bpm"

        XCTAssertEqual(
            source.components(separatedBy: precedence).count - 1,
            2,
            "Both the focal readout and signal rail must prefer fresh supplier display HR."
        )
        XCTAssertFalse(source.contains("model.bpm ?? live.displayOnlyHeartRate"))
    }

    func testSupplierSourceHidesWhoopControlSurface() throws {
        XCTAssertFalse(
            LiveView.shouldShowWhoopControls(activeSourceKind: .veepoo)
        )
        XCTAssertTrue(
            LiveView.shouldShowWhoopControls(activeSourceKind: .liveBLE)
        )
        XCTAssertTrue(
            LiveView.shouldShowWhoopControls(activeSourceKind: nil)
        )

        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Strand/Screens/LiveView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(
                "if showsWhoopControls {\n                        sessionConsole"
            )
        )
        XCTAssertTrue(source.contains("} else if supplierSourceActive {"))
        XCTAssertTrue(
            source.contains(
                "Supplier transport is owned by SourceCoordinator, not BLEManager."
            )
        )
    }

    private func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("project.yml").path
        ) {
            let parent = candidate.deletingLastPathComponent()
            precondition(parent.path != candidate.path, "Could not locate repository root")
            candidate = parent
        }
        return candidate
    }
}
