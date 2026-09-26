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

    func testRealSetupIsPrimaryAndReviewSampleIsSecondary() throws {
        let source = try text("StrandiOS/App/ReviewSampleMode.swift")
        let entry = try slice(
            source,
            from: "struct ReviewSampleEntryView: View",
            to: "struct ReviewSampleDisclosureView: View"
        )

        let setup = try XCTUnwrap(entry.range(of: "\"Continue setup\"")?.lowerBound)
        let sample = try XCTUnwrap(entry.range(of: "\"Explore Review Sample\"")?.lowerBound)
        XCTAssertLessThan(setup, sample)
        XCTAssertTrue(entry.contains(
            "\"Continue setup\",\n                            systemImage: \"arrow.right\",\n                            kind: .primary"
        ))
        XCTAssertTrue(entry.contains(
            "\"Explore Review Sample\",\n                            systemImage: \"eye.fill\",\n                            kind: .secondary"
        ))
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
        XCTAssertTrue(root.contains("!demoBypass && forceReviewSample"))
        XCTAssertFalse(
            root.contains(
                "forceReviewSample || acceptedTerms != Terms.currentVersion"
            ),
            "Ordinary first launch must not be intercepted by the App Review sample chooser."
        )
        XCTAssertTrue(root.contains("activateStandardLaunchIfNeeded()"))
        XCTAssertTrue(root.contains("guard !reviewSampleBlocksStandardLaunch else { return }"))
        let forceReviewSample = try slice(
            root,
            from: "private var forceReviewSample: Bool",
            to: "private var hasLaunchAccess: Bool"
        )
        XCTAssertTrue(
            forceReviewSample.contains(
                "CommandLine.arguments.contains(\"--review-sample\")"
            )
        )
        XCTAssertFalse(
            forceReviewSample.contains("#if DEBUG"),
            "The explicit App Review launch argument must remain usable in the Release binary."
        )

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

    func testFreshInstallDoesNotMountOperationalTabShellBehindOnboarding() throws {
        let source = try text("StrandiOS/App/StrandiOSApp.swift")
        let root = try slice(
            source,
            from: "private var shell: some View",
            to: "/// DEBUG: launched with --demo-seed"
        )
        let tabMount = try slice(
            root,
            from: "if hasLaunchAccess",
            to: "RootTabView()"
        )

        XCTAssertTrue(
            tabMount.contains("&& (onboarded || demoBypass)"),
            "The operational tab shell must not exist until first-run setup completes."
        )
        XCTAssertTrue(root.contains("&& !onboarded"))
        XCTAssertTrue(root.contains("OnboardingWizard(onFinished:"))
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
