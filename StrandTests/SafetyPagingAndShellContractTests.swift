import XCTest
import NoopRemoteSync
@testable import Strand

@MainActor
final class SafetyPagingAndShellContractTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testE164NormalizationAcceptsInternationalInputAndRejectsUnsafeValues() {
        XCTAssertEqual(
            SafetyPagingService.normalizedE164("+1 (415) 555-0123"),
            "+14155550123"
        )
        XCTAssertEqual(
            SafetyPagingService.normalizedE164("0044 20 7946 0958"),
            "+442079460958"
        )
        XCTAssertNil(SafetyPagingService.normalizedE164("4155550123"))
        XCTAssertNil(SafetyPagingService.normalizedE164("+0123456789"))
        XCTAssertNil(SafetyPagingService.normalizedE164("+1234567"))
        XCTAssertNil(SafetyPagingService.normalizedE164("+1234567890123456"))
    }

    func testContactReminderRemainsRequiredUntilTwoAcceptances() {
        XCTAssertFalse(
            SafetyContactReminders.needsReminder(
                reminderRequired: false,
                acceptedCount: 0
            )
        )
        XCTAssertTrue(
            SafetyContactReminders.needsReminder(
                reminderRequired: true,
                acceptedCount: 0
            )
        )
        XCTAssertTrue(
            SafetyContactReminders.needsReminder(
                reminderRequired: true,
                acceptedCount: 1
            )
        )
        XCTAssertFalse(
            SafetyContactReminders.needsReminder(
                reminderRequired: true,
                acceptedCount: 2
            )
        )
        XCTAssertFalse(
            SafetyContactReminders.needsReminder(
                reminderRequired: true,
                acceptedCount: 5
            )
        )
    }

    func testSafetyPageIdempotencyKeySurvivesAmbiguousOutcomes() {
        XCTAssertTrue(
            SafetyPagingService.shouldRetainPageIdempotencyKey(serverStatus: nil)
        )
        XCTAssertTrue(
            SafetyPagingService.shouldRetainPageIdempotencyKey(serverStatus: 500)
        )
        XCTAssertTrue(
            SafetyPagingService.shouldRetainPageIdempotencyKey(serverStatus: 503)
        )
        XCTAssertFalse(
            SafetyPagingService.shouldRetainPageIdempotencyKey(serverStatus: 401)
        )
        XCTAssertFalse(
            SafetyPagingService.shouldRetainPageIdempotencyKey(serverStatus: 412)
        )
    }

    func testSafetySetupIsPartOfOnboardingBeforeAppearance() throws {
        let onboarding = try source("Strand/Onboarding/OnboardingWizard.swift")
        XCTAssertTrue(onboarding.contains(
            "notifications, safetyContacts, appearance, done"
        ))
        XCTAssertTrue(onboarding.contains(
            "case .safetyContacts: SafetyContactsStep()"
        ))
        XCTAssertTrue(onboarding.contains(
            "SafetyContactsSetupView(service: service)"
        ))
    }

    func testFloatingQuickActionLauncherKeepsNineActionsAndVisualQAEntryPoint() throws {
        let shell = try source("StrandiOS/App/RootTabView.swift")
        XCTAssertTrue(shell.contains(
            "case menu, workout, strength, nutrition, journal, hydration, hrv, breathe, intervals, live"
        ))
        XCTAssertTrue(shell.contains("FloatingQuickAddButton(compact: tabBarCompact)"))
        XCTAssertTrue(shell.contains("--demo-quick-actions"))

        let launcher = try XCTUnwrap(
            shell.range(
                of: "private struct QuickActionSheet"
            ).map { String(shell[$0.lowerBound...]) }
        )
        for title in [
            "Workout", "Strength", "Meal", "Journal", "Hydration",
            "HRV", "Breathe", "Intervals", "Live HR",
        ] {
            XCTAssertTrue(launcher.contains("tile(\"\(title)\""), title)
        }
        XCTAssertTrue(shell.contains(
            "Opens workout, strength, meal, journal, hydration, HRV, breathing, intervals, and Live HR actions"
        ))
    }
}
