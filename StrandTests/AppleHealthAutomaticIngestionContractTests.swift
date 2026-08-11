import XCTest
@testable import Strand

/// macOS cannot link HealthKit, so these contract assertions protect the iOS-only bridge wiring while
/// the shared importer/policy tests exercise the actual data transformations as executable Swift.
final class AppleHealthAutomaticIngestionContractTests: XCTestCase {
    func testLiveBridgeConsumesAndObservesBothAbsoluteTemperatureTypes() throws {
        let source = try text("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".bodyTemperature").count - 1, 3)
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".appleSleepingWristTemperature").count - 1, 3)
        XCTAssertTrue(source.contains("a.bodyTemperatureC = v"))
        XCTAssertTrue(source.contains("a.wristTemperatureC = v"))
        XCTAssertTrue(source.contains("bodyTemperatureC: a.bodyTemperatureC"))
        XCTAssertTrue(source.contains("wristTemperatureC: a.wristTemperatureC"))
        XCTAssertFalse(source.contains("skinTempDevC: a.bodyTemperatureC"))
    }

    func testNewestHealthKitWeightUsesProvenanceAwareProfileBoundary() throws {
        let source = try text("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertTrue(source.contains("private func newestBodyMassReading()"))
        XCTAssertTrue(source.contains("measuredAt: sample.endDate"))
        XCTAssertTrue(source.contains("sample.sourceRevision.source"))
        XCTAssertTrue(source.contains("profile.acceptExternalWeight"))
        XCTAssertTrue(source.contains("source: \"apple-health:\\(origin)\""))
    }

    func testAuthorizationAndBackgroundDeliveryClaimsStayExplicitAndQualified() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let view = try text("Strand/Screens/AppleHealthView.swift")
        let app = try text("StrandiOS/App/StrandiOSApp.swift")
        let entitlements = try text("StrandiOS/Resources/NOOP.entitlements")

        XCTAssertTrue(view.contains("Review Health access"))
        let resumeStart = try XCTUnwrap(bridge.range(of: "func refreshAuthIfPreviouslyGranted()"))
        let liveStart = try XCTUnwrap(
            bridge.range(of: "// MARK: - Live delivery", range: resumeStart.upperBound..<bridge.endIndex)
        )
        let resumeBody = String(bridge[resumeStart.lowerBound..<liveStart.lowerBound])
        XCTAssertFalse(resumeBody.contains("requestAuthorization("),
                       "Launch/resume must never open the Health permission sheet.")
        XCTAssertTrue(app.contains("await health.foregroundCatchUp()"))
        XCTAssertTrue(view.contains("Apple may deliver Health updates in the background on its schedule"))
        XCTAssertTrue(view.contains("does not include Apple's background-delivery entitlement"))
        XCTAssertFalse(view.contains("Apple Health (Live)"),
                       "System-scheduled HealthKit delivery must not be described as realtime.")
        XCTAssertTrue(entitlements.contains("com.apple.developer.healthkit.background-delivery"))
    }

    func testMenstrualFlowIsBehindDedicatedCycleConsentAndNeverGeneralHealthConsent() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let optIn = try text("Strand/Screens/SkinTempCardsView.swift")

        let generalReadStart = try XCTUnwrap(bridge.range(of: "private var readTypes"))
        let generalReadEnd = try XCTUnwrap(
            bridge.range(of: "private var writeTypes", range: generalReadStart.upperBound..<bridge.endIndex)
        )
        let generalReadBody = String(bridge[generalReadStart.lowerBound..<generalReadEnd.lowerBound])
        XCTAssertFalse(generalReadBody.contains(".menstrualFlow"),
                       "General Apple Health connect must not silently request reproductive-health data.")

        XCTAssertTrue(bridge.contains("func requestCycleDataAccessAndImport() async"))
        XCTAssertTrue(bridge.contains("toShare: Set<HKSampleType>()"),
                      "The cycle request is read-only and must not add reproductive write access.")
        XCTAssertTrue(bridge.contains("read: Set<HKObjectType>([type])"))
        XCTAssertTrue(bridge.contains("cycleImportExplicitlyRequested"))
        XCTAssertTrue(bridge.contains("func disableCycleDataImport() async"))
        XCTAssertTrue(bridge.contains("deleteAllAppleHealthPeriodStarts"))
        XCTAssertTrue(optIn.contains("can ask to read cycle-start dates from Apple Health"),
                      "The in-app rationale must precede the dedicated system prompt.")
        XCTAssertTrue(optIn.contains("never flow intensity, symptoms, fertility or contraception data"))
    }

    private func text(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
