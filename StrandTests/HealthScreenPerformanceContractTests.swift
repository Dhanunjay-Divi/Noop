import Foundation
import XCTest
@testable import Strand

final class HealthScreenPerformanceContractTests: XCTestCase {
    private func sourceText() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Strand/Screens/HealthView.swift"),
            encoding: .utf8
        )
    }

    func testHealthSectionsKeepTheirProductionOrder() {
        XCTAssertEqual(
            HealthMonitorSection.allCases,
            [
                .syncStatus,
                .heartRate,
                .vitals,
                .timeline,
                .fitnessAge,
                .vitality,
                .recoveryContributors,
                .bodyComposition,
                .biomarkerTrends,
                .skinTemperature,
                .hubLinks,
            ]
        )
    }

    func testHealthSectionsRemainIndependentLazyRows() throws {
        let source = try sourceText()
        let rootStart = try XCTUnwrap(source.range(of: "struct HealthView: View"))
        let rowsStart = try XCTUnwrap(source.range(of: "// MARK: - Lazy health section rows"))
        let root = source[rootStart.lowerBound..<rowsStart.lowerBound]

        XCTAssertTrue(root.contains("lazy: true"))
        XCTAssertTrue(root.contains("ForEach(HealthMonitorSection.allCases)"))
        XCTAssertFalse(source.contains("HealthSectionsStack"))

        let rowStart = try XCTUnwrap(source.range(of: "private struct HealthMonitorSectionRow"))
        let firstRunStart = try XCTUnwrap(source.range(of: "private struct HealthFirstRunContent"))
        let row = source[rowStart.lowerBound..<firstRunStart.lowerBound]
        XCTAssertTrue(row.contains("switch section"))
        XCTAssertFalse(row.contains("VStack(alignment: .leading, spacing: NoopMetrics.sectionGap)"))

        let sync = try XCTUnwrap(row.range(of: "SyncStatusSection()"))
        let heartRate = try XCTUnwrap(row.range(of: "HeartRateSection()"))
        let hubLinks = try XCTUnwrap(row.range(of: "HealthHubLinksSection()"))
        XCTAssertLessThan(sync.lowerBound, heartRate.lowerBound)
        XCTAssertLessThan(heartRate.lowerBound, hubLinks.lowerBound)
    }

    func testLiveHeartRateClockExistsOnlyWhileOptedInAndNotScrolling() throws {
        let source = try sourceText()

        XCTAssertTrue(source.contains("@Environment(\\.noopInteractionInProgress)"))
        XCTAssertTrue(source.contains("if liveTrackingOptedIn && !interactionInProgress"))
        XCTAssertTrue(source.contains("LiveHRSamplingClock"))
        XCTAssertFalse(source.contains("private let sampleTimer"))
    }
}
