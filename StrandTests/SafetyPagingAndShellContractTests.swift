import XCTest
import NoopRemoteSync
@testable import Strand

@MainActor
final class SafetyPagingAndShellContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
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

    func testManagedSafetyLocationRetryIsBounded() {
        XCTAssertEqual(
            ManagedSafetyLocationRetryPolicy.delayNanoseconds(
                afterFailedAttempt: 1
            ),
            2_000_000_000
        )
        XCTAssertEqual(
            ManagedSafetyLocationRetryPolicy.delayNanoseconds(
                afterFailedAttempt: 2
            ),
            5_000_000_000
        )
        XCTAssertNil(
            ManagedSafetyLocationRetryPolicy.delayNanoseconds(
                afterFailedAttempt: 3
            )
        )
    }

    func testManagedSafetyLocationSessionRestoreIsBoundedAndValidated() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let incidentID = UUID()
        let restored = ManagedSafetyLocationSessionPolicy.restoredSession(
            incidentID: incidentID.uuidString,
            expiresAtUnix: now.addingTimeInterval(24 * 60 * 60)
                .timeIntervalSince1970,
            now: now
        )

        XCTAssertEqual(restored?.incidentID, incidentID)
        XCTAssertEqual(
            restored?.expiresAt,
            now.addingTimeInterval(
                ManagedSafetyLocationSessionPolicy.maximumSessionDuration
            )
        )
        XCTAssertNil(
            ManagedSafetyLocationSessionPolicy.restoredSession(
                incidentID: "not-an-identifier",
                expiresAtUnix: now.addingTimeInterval(60).timeIntervalSince1970,
                now: now
            )
        )
        XCTAssertNil(
            ManagedSafetyLocationSessionPolicy.restoredSession(
                incidentID: incidentID.uuidString,
                expiresAtUnix: now.timeIntervalSince1970,
                now: now
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

    func testManagedSafetyKeepsOnlyLatestLocationUntilPageEnds() throws {
        let service = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        let view = try source(
            "StrandiOS/System/ManagedSafetyView.swift"
        )
        let runtime = try source(
            "Strand/System/SafetySOSRuntime.swift"
        )
        let application = try source(
            "StrandiOS/App/StrandiOSApp.swift"
        )
        let project = try source("project.yml")

        XCTAssertTrue(service.contains(
            "private let managedSafetyLocationStreamer"
        ))
        XCTAssertTrue(service.contains(
            "reconcileManagedSafetyLocationSharing()"
        ))
        XCTAssertTrue(service.contains(
            #"source: "stream""#
        ))
        XCTAssertTrue(service.contains(
            "stopManagedSafetyLocationSharing(reason: \"disconnect\")"
        ))
        XCTAssertTrue(service.contains(
            "stopManagedSafetyLocationSharing(reason: \"presentation_cleared\")"
        ))
        XCTAssertTrue(service.contains(
            "managedSafetyLocationExpiryTask"
        ))
        XCTAssertTrue(service.contains(
            "restoreManagedSafetyLocationSharingIfNeeded()"
        ))
        XCTAssertTrue(service.contains(
            "persistManagedSafetyLocationSession("
        ))
        XCTAssertTrue(service.contains(
            "managedCloud.safety.locationIncidentID.v1"
        ))
        XCTAssertTrue(service.contains(
            "managedCloud.safety.locationExpiresAt.v1"
        ))
        XCTAssertTrue(view.contains(
            "locationProvider.requestBackgroundAuthorization()"
        ))
        XCTAssertTrue(view.contains(
            "managed.safety.location.background.body"
        ))
        XCTAssertTrue(runtime.contains(
            "enum SubmissionDisposition"
        ))
        XCTAssertTrue(runtime.contains(
            "manager.startMonitoringSignificantLocationChanges()"
        ))
        XCTAssertTrue(runtime.contains(
            "manager.stopMonitoringSignificantLocationChanges()"
        ))
        XCTAssertTrue(application.contains(
            "launchOptions?[.location]"
        ))
        XCTAssertTrue(application.contains(
            "ManagedCloudService.shared.bootstrap()"
        ))
        XCTAssertTrue(project.contains("- location"))
        XCTAssertFalse(service.contains(
            #""latitude": String"#
        ))
        XCTAssertFalse(service.contains(
            #""longitude": String"#
        ))
    }

    func testManagedSafetyColdPushRestoresPersistedEnrollmentBeforeGuard() throws {
        let service = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        let start = try XCTUnwrap(
            service.range(
                of: "func handleManagedSafetyPush(incidentID: UUID?) async -> Bool"
            )
        )
        let end = try XCTUnwrap(
            service.range(
                of: "// MARK: - Managed Friends",
                range: start.upperBound..<service.endIndex
            )
        )
        let handler = String(service[start.lowerBound..<end.lowerBound])
        let reconcile = try XCTUnwrap(
            handler.range(of: "reconcilePersistedManagedState()")
        )
        let phaseGuard = try XCTUnwrap(
            handler.range(of: "guard phase == .enrolled")
        )

        XCTAssertTrue(handler.contains(
            "if !firebaseConfigured || phase == .signedOut"
        ))
        XCTAssertLessThan(reconcile.lowerBound, phaseGuard.lowerBound)
    }

    func testManagedSafetyRetiresPushWhenNotificationsAreNotAuthorized() throws {
        let service = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )

        XCTAssertTrue(service.contains(
            """
            guard allowed else {
                            await retireManagedPushInstallationForNotificationSettings()
                            return false
                        }
            """
        ))
        XCTAssertGreaterThanOrEqual(
            service.components(
                separatedBy: "guard authorized else {"
            ).count,
            3
        )
        let registrationStart = try XCTUnwrap(
            service.range(
                of: "func registerManagedPushToken(_ token: String) async"
            )
        )
        let registrationEnd = try XCTUnwrap(
            service.range(
                of: "@discardableResult\n    func enableManagedSafetyNotifications()",
                range: registrationStart.upperBound..<service.endIndex
            )
        )
        let registration = String(
            service[
                registrationStart.lowerBound..<registrationEnd.lowerBound
            ]
        )
        XCTAssertTrue(registration.contains(
            "UNUserNotificationCenter.current()"
        ))
        XCTAssertTrue(registration.contains(
            "await retireManagedPushInstallationForNotificationSettings()"
        ))
        XCTAssertTrue(registration.contains("targetKind: .token"))
        XCTAssertFalse(registration.contains("targetKind: .fid"))
        XCTAssertTrue(service.contains(
            "Messaging.messaging().isAutoInitEnabled = false"
        ))
        XCTAssertTrue(service.contains(
            "try await client().revokePushInstallation("
        ))
    }

    func testManagedSafetyNotificationResponseCanRouteRetainedHistory() throws {
        let presenter = try source(
            "Strand/System/NotificationPresenter.swift"
        )
        let application = try source(
            "StrandiOS/App/StrandiOSApp.swift"
        )

        XCTAssertTrue(presenter.contains(
            "ManagedSafetyPushPayload.incidentIDForUserResponse("
        ))
        XCTAssertTrue(application.contains(
            "ManagedSafetyPushPayload.incidentID("
        ))
        XCTAssertFalse(application.contains(
            "ManagedSafetyPushPayload.incidentIDForUserResponse("
        ))
    }

    func testManagedSafetyHistoryLocalizesEveryWireStatus() throws {
        let view = try source(
            "StrandiOS/System/ManagedSafetyView.swift"
        )

        XCTAssertTrue(view.contains("private func incidentStatusLabel("))
        XCTAssertTrue(view.contains("private func participantStatusLabel("))
        XCTAssertTrue(view.contains(
            "managed.safety.status.label.unavailable"
        ))
        XCTAssertTrue(view.contains(
            "managed.safety.participant.status.unavailable"
        ))
        XCTAssertFalse(view.contains(
            "incident.status.replacingOccurrences(of: \"_\""
        ))
        XCTAssertFalse(view.contains(
            "participant.status.replacingOccurrences(of: \"_\""
        ))
    }

    func testDeletingSocialProfileClearsManagedSafetyOnBothPhones() throws {
        let apple = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        let appleStart = try XCTUnwrap(
            apple.range(of: "func deleteSocialProfile() async")
        )
        let appleEnd = try XCTUnwrap(
            apple.range(
                of: "func sendSocialPoke(",
                range: appleStart.upperBound..<apple.endIndex
            )
        )
        let appleDelete = String(
            apple[appleStart.lowerBound..<appleEnd.lowerBound]
        )
        XCTAssertTrue(appleDelete.contains("clearSocialState()"))
        XCTAssertTrue(appleDelete.contains("clearSafetyState()"))

        let android = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt"
        )
        let androidStart = try XCTUnwrap(
            android.range(of: "suspend fun deleteSocialProfile()")
        )
        let androidEnd = try XCTUnwrap(
            android.range(
                of: "suspend fun sendSocialPoke(",
                range: androidStart.upperBound..<android.endIndex
            )
        )
        let androidDelete = String(
            android[androidStart.lowerBound..<androidEnd.lowerBound]
        )
        XCTAssertTrue(androidDelete.contains(
            "preferences.clearSocialState()"
        ))
        XCTAssertTrue(androidDelete.contains(
            "preferences.clearSafetyState()"
        ))
        XCTAssertTrue(androidDelete.contains("clearSafetyPresentation()"))
    }

    func testManagedDisconnectFailsClosedUntilPushIsInvalidated() throws {
        let apple = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        let android = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt"
        )

        XCTAssertTrue(apple.contains(
            "ManagedPushRevocationPolicy.canFinalizeDisconnect("
        ))
        XCTAssertTrue(apple.contains(
            "scheduleManagedSafetyBootstrap()"
        ))
        XCTAssertTrue(android.contains(
            "ManagedPushRevocationPolicy.canFinalizeDisconnect("
        ))
        XCTAssertTrue(android.contains(
            "scheduleManagedSafetyBootstrap()"
        ))

        let appleDisconnectStart = try XCTUnwrap(
            apple.range(of: "func disconnect() async")
        )
        let appleDisconnectEnd = try XCTUnwrap(
            apple.range(
                of: "private func unregisterManagedMessagingInstallation()",
                range: appleDisconnectStart.upperBound..<apple.endIndex
            )
        )
        let appleDisconnect = String(
            apple[
                appleDisconnectStart.lowerBound..<appleDisconnectEnd.lowerBound
            ]
        )
        let appleWait = try XCTUnwrap(
            appleDisconnect.range(of: "await waitForManagedPushRegistrations()")
        )
        let appleRevoke = try XCTUnwrap(
            appleDisconnect.range(of: "client().revokePushInstallation(")
        )
        XCTAssertLessThan(appleWait.lowerBound, appleRevoke.lowerBound)
        XCTAssertTrue(apple.contains(
            "guard beginManagedPushRegistration() else { return }"
        ))
        XCTAssertTrue(apple.contains(
            "defer { endManagedPushRegistration() }"
        ))

        let androidDisconnectStart = try XCTUnwrap(
            android.range(of: "suspend fun disconnect()")
        )
        let androidDisconnectEnd = try XCTUnwrap(
            android.range(
                of: "suspend fun sendDeletionCode(",
                range: androidDisconnectStart.upperBound..<android.endIndex
            )
        )
        let androidDisconnect = String(
            android[
                androidDisconnectStart.lowerBound..<androidDisconnectEnd.lowerBound
            ]
        )
        XCTAssertTrue(android.contains(
            "managedPushRegistrationMutex.withLock"
        ))
        XCTAssertTrue(androidDisconnect.contains(
            "managedPushRegistrationMutex.withLock"
        ))
        let disconnecting = try XCTUnwrap(
            androidDisconnect.range(of: "managedDisconnecting = true")
        )
        let serialization = try XCTUnwrap(
            androidDisconnect.range(of: "managedPushRegistrationMutex.withLock")
        )
        XCTAssertLessThan(disconnecting.lowerBound, serialization.lowerBound)
    }

    func testManagedInviteRedemptionExplainsWhoMustAccept() throws {
        let apple = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        let catalog = try source(
            "Tools/SafetyLocalization/safety_strings.json"
        )
        let corrected =
            "Safety request added from the invitation. Accept it in Contact requests to finish setup."
        let reversed =
            "Safety request sent from the invitation. The other person must accept it."

        XCTAssertTrue(apple.contains(corrected))
        XCTAssertTrue(catalog.contains(corrected))
        XCTAssertFalse(apple.contains(reversed))
        XCTAssertFalse(catalog.contains(reversed))
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
        let notifications = try XCTUnwrap(
            onboarding.range(of: "notifications, safetyContacts,")
        )
        let appearance = try XCTUnwrap(
            onboarding.range(of: "appearance, dailyRhythm, plan, done")
        )
        XCTAssertLessThan(notifications.lowerBound, appearance.lowerBound)
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
                let marker = "/\(sourceRoot)/"
                guard let markerRange = file.path.range(of: marker, options: .backwards) else {
                    XCTFail("Could not derive repository-relative path for \(file.path)")
                    continue
                }
                let relative = sourceRoot + "/" + file.path[markerRange.upperBound...]
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
