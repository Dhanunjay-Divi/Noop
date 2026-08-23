import XCTest
import NoopRemoteSync
@testable import Strand

@MainActor
final class SafetyPagingAndShellContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
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

    func testBandRhythmClassifierCannotEscapeProtocolDiagnostics() throws {
        let allowedDecoders: Set<String> = [
            "Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift",
            "android/app/src/main/java/com/noop/protocol/Whoop5Ecg.kt",
        ]
        let bannedTypedTokens = [
            "EcgArrhythmiaCheckResult",
            "EcgArrhythmiaCheckStatus",
            "heartKeyArrhythmiaCheckResult",
            "heartKeyArrhythmiaCheckStatus",
            "afibDetected",
            "AFIB_DETECTED",
            "normalSinusRhythm",
            "NORMAL_SINUS_RHYTHM",
        ]
        var violations: [String] = []
        var scannedFiles = 0
        for sourceRoot in ["Strand", "StrandiOS", "StrandWatch", "Packages", "android/app/src/main"] {
            let directory = repoRoot.appendingPathComponent(sourceRoot)
            guard let files = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let file as URL in files {
                guard file.pathExtension == "swift" || file.pathExtension == "kt" else { continue }
                let relative = file.path.replacingOccurrences(
                    of: repoRoot.path + "/",
                    with: ""
                )
                guard !relative.hasPrefix("Packages/") || relative.contains("/Sources/") else { continue }
                guard !allowedDecoders.contains(relative) else { continue }
                scannedFiles += 1

                var text = try String(contentsOf: file, encoding: .utf8)
                // BLE diagnostics may preserve the two raw bytes. Removing the full raw-field
                // identifiers before checking their typed prefixes keeps that exception explicit.
                text = text.replacingOccurrences(of: "heartKeyArrhythmiaCheckResultRaw", with: "")
                text = text.replacingOccurrences(of: "heartKeyArrhythmiaCheckStatusRaw", with: "")
                for token in bannedTypedTokens where text.contains(token) {
                    violations.append("\(relative): \(token)")
                }
                let lowercase = text.lowercased()
                if lowercase.contains("afib") || lowercase.contains("atrial fibrillation") {
                    violations.append("\(relative): clinical AFib wording")
                }
            }
        }

        XCTAssertGreaterThan(scannedFiles, 100, "Production-source audit did not run")
        XCTAssertTrue(
            violations.isEmpty,
            "Band classifier output must stay decode-only; escaped into:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }

    func testEcgSpotRecordingClosesItsStreamAndInvalidatesStaleTimers() throws {
        let ble = try source("Strand/BLE/BLEManager.swift")
        func section(from start: String, to end: String) throws -> String {
            let lower = try XCTUnwrap(ble.range(of: start)?.lowerBound)
            let upper = try XCTUnwrap(
                ble.range(of: end, range: lower..<ble.endIndex)?.lowerBound
            )
            return String(ble[lower..<upper])
        }

        let armed = try section(
            from: "private var ecgProbeArmed: Bool",
            to: "private var ecgStopOverride"
        )
        XCTAssertTrue(armed.contains("return Date() < deadline"))

        let stop = try section(
            from: "public func ecgStopCapture",
            to: "public func clearEcgProbe"
        )
        let invalidate = try XCTUnwrap(stop.range(of: "invalidateEcgProbeRun"))
        let gate = try XCTUnwrap(stop.range(of: "guard ecgGatesAllow"))
        XCTAssertLessThan(invalidate.lowerBound, gate.lowerBound)

        let dismiss = try section(
            from: "public func clearEcgProbe",
            to: "private func beginEcgProbeRun"
        )
        XCTAssertTrue(dismiss.contains("invalidateEcgProbeRun(clearPresentation: true)"))
        XCTAssertTrue(dismiss.contains("writeEcgStopCommands(recordsSteps: false)"))

        let verdict = try section(
            from: "private func scheduleEcgProbeVerdict",
            to: "private func noteEcgProbeFrame"
        )
        XCTAssertTrue(verdict.contains("self.ecgProbeDeadline = nil"))
        XCTAssertTrue(verdict.contains("self.writeEcgStopCommands(recordsSteps: false)"))
        XCTAssertTrue(verdict.contains("self.ecgMayBeRunning = false"))
    }
}
