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
        XCTAssertNil(SafetyPagingService.normalizedE164("+١٤١٥٥٥٥٠١٢٣"))
        XCTAssertNil(SafetyPagingService.normalizedE164("+１２３４５６７８９"))
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

    func testLegacyPendingPageKeepsItsOriginalManualEightHourBody() {
        let key = UUID()
        let pending = SafetyPendingPageRequest.legacyManual(
            idempotencyKey: key
        )

        XCTAssertEqual(pending.idempotencyKey, key)
        XCTAssertEqual(pending.page.trigger, .manualSOS)
        XCTAssertEqual(pending.page.shareDurationHours, .eight)
        XCTAssertNil(pending.page.evidence)
    }

    func testTerminalIdempotentReplayRequiresOneFreshPageRequest() {
        XCTAssertTrue(
            SafetyPagingService.shouldReplaceTerminalPageReplay(
                status: .resolved,
                idempotentReplay: true
            )
        )
        XCTAssertFalse(
            SafetyPagingService.shouldReplaceTerminalPageReplay(
                status: .open,
                idempotentReplay: true
            )
        )
        XCTAssertFalse(
            SafetyPagingService.shouldReplaceTerminalPageReplay(
                status: .resolved,
                idempotentReplay: false
            )
        )
    }

    func testSafetyContactReceiptRejectsInvalidServerCounts() {
        XCTAssertEqual(
            SafetyIncidentContactPresentation.receipt(reached: 2, targeted: 3),
            .init(reached: 2, targeted: 3)
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.receipt(reached: -1, targeted: 3)
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.receipt(reached: 4, targeted: 3)
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.receipt(reached: 0, targeted: 0)
        )
    }

    func testSafetyContactReceiptParsesServerReachTimestampWithoutFabricatingOne() {
        XCTAssertNotNil(
            SafetyIncidentContactPresentation.lastReachedDate(
                "2026-08-24T14:03:12.123456Z"
            )
        )
        XCTAssertNotNil(
            SafetyIncidentContactPresentation.lastReachedDate(
                "2026-08-24T14:03:12Z"
            )
        )
        XCTAssertNil(SafetyIncidentContactPresentation.lastReachedDate(nil))
        XCTAssertNil(
            SafetyIncidentContactPresentation.lastReachedDate("not-a-timestamp")
        )
    }

    func testFailedIncidentStaysCriticalTerminalEvenWithoutNewSummary() {
        XCTAssertTrue(
            SafetyIncidentContactPresentation.shouldShowAllContactsFailed(
                status: .failed,
                summaryReportsAllFailed: nil
            )
        )
        XCTAssertFalse(
            SafetyIncidentContactPresentation.allowsResolveOrCancel(.failed)
        )
        switch SafetyIncidentContactPresentation.tone(for: .failed) {
        case .critical:
            break
        default:
            XCTFail("A terminal all-contact failure must retain critical presentation.")
        }
        XCTAssertTrue(
            SafetyIncidentContactPresentation.shouldShowAllContactsFailed(
                status: .open,
                summaryReportsAllFailed: true
            )
        )
        XCTAssertFalse(
            SafetyIncidentContactPresentation.shouldShowAllContactsFailed(
                status: .partialFailure,
                summaryReportsAllFailed: false
            )
        )
    }

    func testPagingEnabledIsBackwardCompatibleButExplicitFalseFailsClosed() {
        XCTAssertTrue(
            SafetyPagingService.deliveryAvailable(
                providerConfigured: true,
                pagingEnabled: nil
            ),
            "Legacy servers without paging_enabled remain compatible."
        )
        XCTAssertTrue(
            SafetyPagingService.deliveryAvailable(
                providerConfigured: true,
                pagingEnabled: true
            )
        )
        XCTAssertFalse(
            SafetyPagingService.deliveryAvailable(
                providerConfigured: true,
                pagingEnabled: false
            )
        )
        XCTAssertFalse(
            SafetyPagingService.deliveryAvailable(
                providerConfigured: false,
                pagingEnabled: true
            )
        )
    }

    func testReadinessMessageClearsWhenPagingBecomesDisabled() {
        XCTAssertEqual(
            SafetyPagingService.readinessStatusMessage(
                acceptedCount: 2,
                providerConfigured: true,
                pagingEnabled: true
            ),
            "Safety paging is ready."
        )
        XCTAssertEqual(
            SafetyPagingService.readinessStatusMessage(
                acceptedCount: 2,
                providerConfigured: true,
                pagingEnabled: false
            ),
            ""
        )
        XCTAssertEqual(
            SafetyPagingService.readinessStatusMessage(
                acceptedCount: 2,
                providerConfigured: false,
                pagingEnabled: true
            ),
            ""
        )
    }

    func testSafetyIncidentRestorePolicyIsBoundedAndTerminalAware() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            try XCTUnwrap(
                SafetySOSRuntime.boundedSessionExpiry(
                    requested: nil,
                    now: now
                )
            ).timeIntervalSince(now),
            SafetySOSRuntime.fallbackSessionSeconds,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                SafetySOSRuntime.boundedSessionExpiry(
                    requested: now.addingTimeInterval(24 * 60 * 60),
                    now: now
                )
            ).timeIntervalSince(now),
            SafetySOSRuntime.maximumSessionSeconds,
            accuracy: 0.001
        )
        XCTAssertEqual(SafetySOSRuntime.fallbackSessionSeconds, 8 * 60 * 60)
        XCTAssertEqual(SafetySOSRuntime.maximumSessionSeconds, 12 * 60 * 60)
        XCTAssertEqual(
            SafetySOSRuntime.resumedLocationSequence(
                server: 41,
                persisted: NSNumber(value: 56),
                sameDispatch: true
            ),
            56
        )
        XCTAssertEqual(
            SafetySOSRuntime.resumedLocationSequence(
                server: 41,
                persisted: NSNumber(value: 56),
                sameDispatch: false
            ),
            41
        )
        XCTAssertNil(
            SafetySOSRuntime.boundedSessionExpiry(
                requested: now,
                now: now
            )
        )

        XCTAssertTrue(SafetySOSRuntime.isActive(.open))
        XCTAssertTrue(SafetySOSRuntime.isActive(.pending))
        XCTAssertTrue(SafetySOSRuntime.isActive(.acknowledged))
        XCTAssertFalse(SafetySOSRuntime.isActive(.failed))
        XCTAssertFalse(SafetySOSRuntime.isActive(.resolved))
        XCTAssertFalse(SafetySOSRuntime.isActive(.expired))
    }

    func testTerminalNotificationMarkerAdvancesOnlyAfterSuccessfulPost() {
        let previous = SafetySOSRuntime.StatusNotificationMarker(
            dispatchId: "old",
            status: "acknowledged"
        )
        let candidate = SafetySOSRuntime.StatusNotificationMarker(
            dispatchId: "new",
            status: "failed"
        )

        XCTAssertEqual(
            SafetySOSRuntime.markerAfterNotificationAttempt(
                previous: previous,
                candidate: candidate,
                postedSuccessfully: false
            ),
            previous
        )
        XCTAssertEqual(
            SafetySOSRuntime.markerAfterNotificationAttempt(
                previous: previous,
                candidate: candidate,
                postedSuccessfully: true
            ),
            candidate
        )
    }

    func testExpiredIncidentRetainsMonitorUntilTerminalNotificationPosts() {
        XCTAssertTrue(
            SafetySOSRuntime.shouldRetainMonitorState(
                status: .failed,
                locallyExpired: true,
                notificationReconciled: false
            )
        )
        XCTAssertFalse(
            SafetySOSRuntime.shouldRetainMonitorState(
                status: .failed,
                locallyExpired: true,
                notificationReconciled: true
            )
        )
        XCTAssertFalse(
            SafetySOSRuntime.shouldRetainMonitorState(
                status: .open,
                locallyExpired: true,
                notificationReconciled: true
            )
        )
        XCTAssertTrue(
            SafetySOSRuntime.shouldRetainMonitorState(
                status: .open,
                locallyExpired: false,
                notificationReconciled: true
            )
        )
    }

    func testDirectCallActionAcceptsOnlyStrictE164Numbers() {
        XCTAssertEqual(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "+14155550123"
            )?.absoluteString,
            "tel:+14155550123"
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "4155550123"
            )
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "+0123456789"
            )
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "+1415 555 0123"
            )
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "+١٤١٥٥٥٥٠١٢٣"
            )
        )
        XCTAssertNil(
            SafetyIncidentContactPresentation.telephoneURL(
                phoneE164: "+１２３４５６７８９"
            )
        )
    }

    func testSafetyResultCopyUsesHonestEvidenceAndBackgroundReconciliation() throws {
        let runtime = try source("Strand/System/SafetySOSRuntime.swift")
        let app = try source("StrandiOS/App/StrandiOSApp.swift")
        let screen = try source("Strand/Screens/SafetyCenterView.swift")
        let service = try source("Strand/Data/SafetyPagingService.swift")
        let strings = try source("Strand/Resources/Localizable.xcstrings")

        XCTAssertFalse(runtime.contains("SOS page sent"))
        XCTAssertTrue(runtime.contains("safety.page.detail.submitted"))
        XCTAssertTrue(runtime.contains("refreshActiveIncidentStatusIfNeeded"))
        XCTAssertTrue(runtime.contains("postStatusNotificationOnce"))
        XCTAssertTrue(runtime.contains("requestNotificationAuthorizationIfNeeded"))
        XCTAssertTrue(screen.contains(
            "await SafetySOSRuntime.requestNotificationAuthorizationIfNeeded()"
        ))
        XCTAssertTrue(screen.contains("safety.page.contact_responses"))
        XCTAssertTrue(app.contains(
            "SafetySOSRuntime.shared.refreshActiveIncidentStatusIfNeeded()"
        ))
        XCTAssertTrue(strings.contains(
            #"value":"Delivery or response confirmed for %1$lld of %2$lld contacts"#
        ))
        XCTAssertTrue(strings.contains("Delivery or response confirmed"))
        XCTAssertTrue(strings.contains(
            #""safety.sos.notifications.off""#
        ))
        XCTAssertTrue(strings.contains(#"value":"Paging started""#))
        XCTAssertTrue(strings.contains("Delivery confirmation is pending."))
        XCTAssertTrue(strings.contains(
            #""safety.page.contact_responses""#
        ))
        XCTAssertTrue(service.contains(
            #"statusMessage = String(localized: "safety.page.detail.submitted")"#
        ))
    }

    func testRelaunchReconcilesBeforeResumingLocation() throws {
        let runtime = try source("Strand/System/SafetySOSRuntime.swift")
        let start = try XCTUnwrap(
            runtime.range(of: "func restoreLocationSharingIfNeeded() async")
        )
        let end = try XCTUnwrap(
            runtime.range(
                of: "func refreshActiveIncidentStatusIfNeeded() async",
                range: start.upperBound..<runtime.endIndex
            )
        )
        let restore = String(runtime[start.lowerBound..<end.lowerBound])
        let lookup = try XCTUnwrap(restore.range(of: "service.incident(dispatchId)"))
        let reconcile = try XCTUnwrap(restore.range(of: "reconcileStatus(dispatch)"))
        let resume = try XCTUnwrap(
            restore.range(of: "startLocationSharing(for: dispatch")
        )

        XCTAssertLessThan(lookup.lowerBound, reconcile.lowerBound)
        XCTAssertLessThan(reconcile.lowerBound, resume.lowerBound)
        XCTAssertTrue(restore.contains("privacy-bounded deadline"))
        XCTAssertTrue(restore.contains("[401, 404, 409, 410]"))

        let refreshStart = try XCTUnwrap(
            runtime.range(of: "func refreshActiveIncidentStatusIfNeeded() async")
        )
        let refreshEnd = try XCTUnwrap(
            runtime.range(
                of: "private func startStatusMonitoring",
                range: refreshStart.upperBound..<runtime.endIndex
            )
        )
        let refresh = String(
            runtime[refreshStart.lowerBound..<refreshEnd.lowerBound]
        )
        let fetch = try XCTUnwrap(
            refresh.range(of: "SafetyPagingService().incident(dispatchId)")
        )
        XCTAssertFalse(
            refresh[..<fetch.lowerBound].contains("stopLocationSharing"),
            "Expired state must not be discarded before server reconciliation."
        )
    }

    func testAutomaticFallBoundaryRemainsVisibleAndRuntimeInert() throws {
        let center = try source("Strand/Screens/SafetyCenterView.swift")
        let appModel = try source("Strand/App/AppModel.swift")
        let androidService = try source(
            "android/app/src/main/java/com/noop/ble/WhoopConnectionService.kt"
        )
        let androidViewModel = try source(
            "android/app/src/main/java/com/noop/ui/AppViewModel.kt"
        )

        XCTAssertTrue(center.contains("safety.fall.status"))
        XCTAssertTrue(center.contains("safety.fall.requirements"))
        XCTAssertFalse(appModel.contains("FallResponseStateMachine("))
        XCTAssertFalse(androidService.contains("FallResponseStateMachine("))
        XCTAssertFalse(androidViewModel.contains("FallResponseStateMachine("))
    }

    func testSafetySetupIsPartOfOnboardingBeforeAppearance() throws {
        let onboarding = try source("Strand/Onboarding/OnboardingWizard.swift")
        XCTAssertTrue(onboarding.contains(
            "notifications, safetyContacts, appearance, dailyRhythm, done"
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
        XCTAssertTrue(launcher.contains(#".accessibilityIdentifier("noop.quick-actions.updates")"#))
        XCTAssertTrue(shell.contains(
            "Opens Updates, workout, strength, meal, journal, hydration, HRV, breathing, intervals, and Live HR actions"
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
