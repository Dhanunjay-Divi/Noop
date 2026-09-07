import XCTest

final class ReviewSampleModeContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReviewSampleIsDeterministicAndHasNoOperationalDependencies() throws {
        let source = try text("StrandiOS/App/ReviewSampleMode.swift")

        XCTAssertTrue(source.contains("Fictional sample wellness data"))
        XCTAssertTrue(source.contains("No sensor or medical reading is being taken."))
        XCTAssertTrue(source.contains("noop.review.entry.explore"))
        XCTAssertTrue(source.contains("noop.review.disclosure.enter"))
        XCTAssertTrue(source.contains("noop.review.root"))
        XCTAssertTrue(source.contains("noop.review.exit"))

        let forbidden = [
            "AppModel",
            "Repository",
            "BLEManager",
            "HealthKitBridge",
            "ManagedCloudService",
            "FriendsService",
            "SafetyPagingService",
            "URLSession",
            "UserDefaults",
            "@AppStorage",
            "UNUserNotificationCenter",
            ".task {",
            "Task {",
        ]
        for token in forbidden {
            XCTAssertFalse(
                source.contains(token),
                "Review Sample must remain a pure in-memory presentation tree; found \(token)."
            )
        }
    }

    func testReleaseRootKeepsReviewSampleAheadOfTermsAndOperationalShell() throws {
        let source = try text("StrandiOS/App/StrandiOSApp.swift")
        let root = try slice(
            source,
            from: "private struct iOSRootView: View",
            to: "#if DEBUG\n/// DEBUG-only screenshot harness"
        )

        XCTAssertTrue(root.contains("@State private var reviewSamplePhase: ReviewSamplePhase = .entry"))
        XCTAssertTrue(root.contains("ReviewSampleEntryView("))
        XCTAssertTrue(root.contains("ReviewSampleDisclosureView("))
        XCTAssertTrue(root.contains("ReviewSampleRootView("))
        XCTAssertTrue(root.contains("!reviewSampleBlocksStandardLaunch"))
        XCTAssertTrue(root.contains("activateStandardLaunchIfNeeded()"))
        XCTAssertTrue(root.contains("guard !reviewSampleBlocksStandardLaunch else { return }"))

        let sampleEntry = try XCTUnwrap(root.range(of: "ReviewSampleEntryView(")?.lowerBound)
        let operationalMount = try XCTUnwrap(root.range(of: "RootTabView()")?.lowerBound)
        XCTAssertGreaterThan(sampleEntry, operationalMount)
        XCTAssertTrue(
            root.contains("if hasLaunchAccess && reviewSampleOffered"),
            "The reviewer entry must be visible after launch access without a hidden gesture."
        )
    }

    func testDebugReviewLaunchCannotStartOperationalModel() throws {
        let source = try text("StrandiOS/App/StrandiOSApp.swift")
        XCTAssertTrue(source.contains("let reviewSampleFixtureRequested = CommandLine.arguments.contains(\"--review-sample\")"))
        XCTAssertTrue(source.contains("&& !reviewSampleFixtureRequested"))
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }
}
