import FirebaseAuth
import XCTest
@testable import Strand

final class MacViewerRuntimeContractTests: XCTestCase {
    func testCurrentMacRolePreservesLocalHistoryWithoutCollection() {
        XCTAssertEqual(AppRuntimeRole.currentPlatform, .managedViewer)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.allowsLocalCollection)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.requiresCollectorOnboarding)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.allowsLocalAnalysisAndGuidance)
        XCTAssertTrue(
            AppRuntimeRole.currentPlatform
                .enforcesManagedViewerReadOnlyRoutes
        )
        XCTAssertTrue(AppRuntimeRole.currentPlatform.hasManagedViewerTransport)
        XCTAssertTrue(AppRuntimeRole.currentPlatform.canPresentOperationalShell)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalCollection)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.requiresCollectorOnboarding)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalAnalysisAndGuidance)
        XCTAssertFalse(
            AppRuntimeRole.phoneCollector
                .enforcesManagedViewerReadOnlyRoutes
        )
        XCTAssertFalse(AppRuntimeRole.phoneCollector.hasManagedViewerTransport)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.canPresentOperationalShell)
    }

    func testFreshMacViewerNeverEntersCollectorOnboarding() {
        for onboarded in [false, true] {
            XCTAssertEqual(
                ContentView.entryDestination(
                    acceptedCurrentTerms: false,
                    onboarded: onboarded,
                    runtimeRole: .managedViewer,
                    bypassesEntryGates: false
                ),
                .terms
            )
            XCTAssertEqual(
                ContentView.entryDestination(
                    acceptedCurrentTerms: true,
                    onboarded: onboarded,
                    runtimeRole: .managedViewer,
                    bypassesEntryGates: false
                ),
                .operationalShell
            )
        }
    }

    func testPhoneCollectorEntryStillRequiresOnboardingAfterTerms() {
        XCTAssertEqual(
            ContentView.entryDestination(
                acceptedCurrentTerms: false,
                onboarded: false,
                runtimeRole: .phoneCollector,
                bypassesEntryGates: false
            ),
            .terms
        )
        XCTAssertEqual(
            ContentView.entryDestination(
                acceptedCurrentTerms: true,
                onboarded: false,
                runtimeRole: .phoneCollector,
                bypassesEntryGates: false
            ),
            .collectorOnboarding
        )
        XCTAssertEqual(
            ContentView.entryDestination(
                acceptedCurrentTerms: true,
                onboarded: true,
                runtimeRole: .phoneCollector,
                bypassesEntryGates: false
            ),
            .operationalShell
        )
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

    func testManagedViewerStartupSkipsLegacyBackupSyncAndGuidanceWorkers()
        throws
    {
        let root = try text("Strand/App/RootView.swift")
        let startup = try slice(
            root,
            from: "        .task {\n",
            to: "        .onChangeCompat(of: repo.refreshSeq) { _ in\n"
        )
        XCTAssertTrue(
            startup.contains(
                "guard model.runtimeRole.allowsLocalCollection,"
            )
        )
        XCTAssertTrue(
            startup.contains(
                "!repo.isManagedViewerStoreActive else { return }"
            )
        )
        XCTAssertTrue(startup.contains("FolderBackup.catchUpIfDue("))
        XCTAssertTrue(startup.contains("RemoteSyncService.catchUpIfDue("))

        let startupRange = try XCTUnwrap(root.range(of: startup))
        let refreshHookStart = try XCTUnwrap(
            root.range(
                of: "        .onChangeCompat(of: repo.refreshSeq) { _ in\n",
                range: startupRange.upperBound..<root.endIndex
            )
        ).lowerBound
        let refreshHookEnd = try XCTUnwrap(
            root.range(
                of: "        // Honour a cross-screen request",
                range: refreshHookStart..<root.endIndex
            )
        ).lowerBound
        let refreshHook = String(root[refreshHookStart..<refreshHookEnd])
        XCTAssertTrue(
            refreshHook.contains(
                "guard model.runtimeRole.allowsLocalCollection,"
            )
        )
        XCTAssertTrue(
            refreshHook.contains(
                "!repo.isManagedViewerStoreActive else { return }"
            )
        )
        XCTAssertTrue(
            refreshHook.contains("RemoteSyncService.catchUpIfDue(")
        )

        let onAppear = try slice(
            root,
            from: "        .onAppear {\n",
            to: "        .onReceive("
        )
        XCTAssertTrue(
            onAppear.contains(
                "if model.runtimeRole.allowsLocalAnalysisAndGuidance,"
            )
        )
        XCTAssertTrue(
            onAppear.contains(
                "!repo.isManagedViewerStoreActive {"
            )
        )
        XCTAssertTrue(
            onAppear.contains(
                "DailyReviewNotifications.restoreScheduleIfAuthorized()"
            )
        )
        XCTAssertTrue(
            onAppear.contains(
                "await repo.reconcileDailyReviewJournalReminders()"
            )
        )
    }

    func testManagedViewerRoutesAreReadOnlyAndMutationRoutesAreUnavailable()
        throws
    {
        let allowed = Set(
            NavItem.allCases.filter(\.isAvailableInManagedViewer)
        )
        XCTAssertEqual(
            allowed,
            Set([
                .today, .friends, .explore, .compare, .trends, .health,
                .stress, .fusedRecord,
            ])
        )
        XCTAssertTrue(
            [
                NavItem.intelligence, .insightsHub, .coach, .live, .breathe,
                .intervals, .insights, .sleep, .workouts, .nutrition,
                .labBook, .rhythm, .appleHealth, .xiaomi, .dataSources,
                .backupSync, .devices, .notifications, .automation,
                .smartAlarm, .safety, .settings, .testCentre,
            ].allSatisfy { !$0.isAvailableInManagedViewer }
        )

        let root = try text("Strand/App/RootView.swift")
        let selection = try slice(
            root,
            from: "    private func select(_ item: NavItem) {\n",
            to: "    /// The filter text that actually applies"
        )
        XCTAssertTrue(
            selection.contains(
                "model.runtimeRole.enforcesManagedViewerReadOnlyRoutes"
            )
        )
        XCTAssertFalse(selection.contains("repo.isManagedViewerStoreActive"))
        XCTAssertTrue(selection.contains("!item.isAvailableInManagedViewer"))
        XCTAssertTrue(selection.contains("selection = .today"))

        let visibility = try slice(
            root,
            from: "    private func visibleItems(in group: NavGroup)",
            to: "    /// One selectable destination row"
        )
        XCTAssertTrue(
            visibility.contains(
                "model.runtimeRole.enforcesManagedViewerReadOnlyRoutes"
            )
        )
        XCTAssertFalse(visibility.contains("repo.isManagedViewerStoreActive"))
        XCTAssertTrue(
            visibility.contains("roleItems.filter(\\.isAvailableInManagedViewer)")
        )

        let detail = try slice(
            root,
            from: "    @ViewBuilder private var detail: some View {\n",
            to: "    @ViewBuilder\n    private func destination("
        )
        XCTAssertTrue(detail.contains("!selected.isAvailableInManagedViewer"))
        XCTAssertTrue(detail.contains("MacCollectorPhoneOnlyView()"))
        XCTAssertFalse(
            detail.contains(".disabled("),
            "Read-only viewer routes must retain navigation and selection controls."
        )
        XCTAssertTrue(root.contains(".id(\n                        \"\\(repo.storeScopeRevision):\""))
        XCTAssertTrue(
            root.contains(
                ".onChangeCompat(of: repo.storeScopeRevision)"
            )
        )

        let compare = try text("Strand/Screens/CompareView.swift")
        XCTAssertTrue(
            root.contains(
                "CompareView(\n"
                    + "                allowsScoreRefresh:\n"
                    + "                    model.runtimeRole"
                    + ".allowsLocalAnalysisAndGuidance"
            )
        )
        let writeBoundary = try slice(
            compare,
            from: "    private func loadOfficialReference() async {\n",
            to: "    private var officialReferenceSection: some View {\n"
        )
        let readOnlyGuard = try XCTUnwrap(
            writeBoundary.range(of: "guard allowsScoreRefresh else")
        )
        let rescore = try XCTUnwrap(
            writeBoundary.range(of: "intelligence.analyzeRecent(")
        )
        let calibrationWrite = try XCTUnwrap(
            writeBoundary.range(
                of: "personalCalibrationStore.saveValidated("
            )
        )
        XCTAssertLessThan(readOnlyGuard.lowerBound, rescore.lowerBound)
        XCTAssertLessThan(
            readOnlyGuard.lowerBound,
            calibrationWrite.lowerBound
        )

        XCTAssertTrue(
            root.contains(
                "MetricExplorerView(\n"
                    + "                allowsLocalMutations:\n"
                    + "                    model.runtimeRole"
                    + ".allowsLocalAnalysisAndGuidance"
            )
        )
        XCTAssertTrue(
            root.contains(
                "HealthView(\n"
                    + "                allowsLocalMutations:\n"
                    + "                    model.runtimeRole"
                    + ".allowsLocalAnalysisAndGuidance"
            )
        )
        XCTAssertTrue(
            root.contains(
                "StressView(\n"
                    + "                allowsLocalMutations:\n"
                    + "                    model.runtimeRole"
                    + ".allowsLocalAnalysisAndGuidance"
            )
        )
        XCTAssertTrue(
            root.contains(
                "LiquidTodayView(\n"
                    + "                allowsLocalMutations:\n"
                    + "                    model.runtimeRole"
                    + ".allowsLocalAnalysisAndGuidance"
            )
        )

        let today = try text("Strand/Liquid/LiquidTodayView.swift")
        XCTAssertTrue(today.contains("init(allowsLocalMutations: Bool = true)"))
        XCTAssertTrue(
            today.contains(
                "guard allowsLocalMutations, selectedDayOffset == 0 else"
            )
        )
        XCTAssertTrue(
            today.contains(
                "if allowsLocalMutations, selectedDayOffset == 0 {\n"
                    + "                    Divider().overlay"
            )
        )
        XCTAssertTrue(
            today.contains(
                "MetricDetailView(\n"
                    + "                    metric: metric,\n"
                    + "                    allowsLocalMutations: allowsLocalMutations"
            )
        )

        let explore = try text("Strand/Screens/MetricExplorerView.swift")
        XCTAssertTrue(
            explore.components(
                separatedBy: "init(allowsLocalMutations: Bool = true)"
            ).count >= 2
        )
        XCTAssertTrue(
            explore.contains(
                "guard allowsLocalMutations, !refreshing else"
            )
        )

        let health = try text("Strand/Screens/HealthView.swift")
        XCTAssertTrue(health.contains("init(allowsLocalMutations: Bool = true)"))
        XCTAssertTrue(
            health.contains(
                "guard allowsLocalMutations, !refreshing else"
            )
        )
        XCTAssertTrue(
            health.contains(
                "onLogPeriod: allowsLocalMutations ?"
            )
        )
        XCTAssertTrue(
            health.contains(
                "onFix: allowsLocalMutations"
            )
        )
        XCTAssertTrue(
            health.contains(
                "HealthHubLinksSection(\n"
                    + "                allowsLocalRecords: "
                    + "allowsLocalMutations"
            )
        )
        let hubLinks = try slice(
            health,
            from: "private struct HealthHubLinksSection: View {\n",
            to: "    private func linkRow("
        )
        XCTAssertTrue(hubLinks.contains("if allowsLocalRecords"))
        XCTAssertTrue(hubLinks.contains("router.openLabBook()"))
        XCTAssertTrue(hubLinks.contains("router.openFusedRecord()"))

        let stress = try text("Strand/Screens/StressView.swift")
        XCTAssertTrue(
            stress.contains("init(allowsLocalMutations: Bool = true)")
        )
        XCTAssertTrue(
            stress.contains(
                "if allowsLocalMutations, day.sustainedHigh"
            )
        )
        XCTAssertTrue(
            stress.contains(
                "guard allowsLocalMutations else { return }\n"
                    + "                    showBreathe = true"
            )
        )
        XCTAssertTrue(
            today.contains("StressView(allowsLocalMutations: false)")
        )
    }

    func testManagedHistoryRefreshesZeroDeltaStoreAndRefencesPublication()
        throws
    {
        let viewer = try text(
            "Strand/System/MacManagedViewerService.swift"
        )
        let restore = try slice(
            viewer,
            from: "    private func restoreManagedHistory(\n",
            to: "    private func scheduleHistoryContinuation(\n"
        )
        XCTAssertFalse(
            restore.contains("if result.appliedChanges > 0"),
            "An already-populated account store must refresh after a zero-delta restore."
        )
        let refresh = try XCTUnwrap(
            restore.range(
                of: "            try await repo.refreshManagedViewer(\n"
            )
        )
        XCTAssertTrue(
            restore.contains(
                "validateBeforePublication: operationValidator"
            )
        )
        let postRefreshValidation = try XCTUnwrap(
            restore.range(
                of: "            try await operationValidator()\n",
                range: refresh.upperBound..<restore.endIndex
            )
        )
        let historyPublication = try XCTUnwrap(
            restore.range(of: "            historyLastUpdatedAt = Date()\n")
        )
        XCTAssertLessThan(
            refresh.lowerBound,
            postRefreshValidation.lowerBound
        )
        XCTAssertLessThan(
            postRefreshValidation.lowerBound,
            historyPublication.lowerBound
        )
    }

    func testStaleHistoryContinuationCannotPublishOrDeactivateNewerAccount()
        throws
    {
        let viewer = try text(
            "Strand/System/MacManagedViewerService.swift"
        )
        let run = try slice(
            viewer,
            from: "    private func runHistoryContinuation(\n",
            to: "    private func cancelHistoryContinuation()"
        )
        let generationFence =
            "guard historyContinuationGeneration == generation else"
        XCTAssertGreaterThanOrEqual(
            run.components(separatedBy: generationFence).count - 1,
            3,
            "Continuation start, success publication, and failure side effects "
                + "must each reject a stale generation."
        )
        XCTAssertTrue(
            run.contains("continuationGeneration: generation"),
            "The inner restore must carry the same continuation generation "
                + "through its repository publication validator."
        )

        let success = try slice(
            run,
            from: "            let summary = try await ",
            to: "        } catch is CancellationError"
        )
        let successFence = try XCTUnwrap(success.range(of: generationFence))
        let statusPublish = try XCTUnwrap(success.range(of: "            status = "))
        XCTAssertLessThan(
            successFence.lowerBound,
            statusPublish.lowerBound,
            "A stale continuation must not publish status into a newer account."
        )

        let failureStart = try XCTUnwrap(
            run.range(of: "        } catch {\n", options: .backwards)
        ).upperBound
        let failure = String(run[failureStart...])
        let failureFence = try XCTUnwrap(failure.range(of: generationFence))
        let hideHistory = try XCTUnwrap(
            failure.range(of: "await hideManagedHistory(repo: repo)")
        )
        let failurePublish = try XCTUnwrap(
            failure.range(of: "applyFailure(error)")
        )
        XCTAssertLessThan(
            failureFence.lowerBound,
            hideHistory.lowerBound,
            "A stale continuation must not deactivate the newer account store."
        )
        XCTAssertLessThan(
            failureFence.lowerBound,
            failurePublish.lowerBound,
            "A stale continuation must not publish failure into a newer account."
        )

        let cancel = try slice(
            viewer,
            from: "    private func cancelHistoryContinuation() {\n",
            to: "    private func loadManagedFriends("
        )
        let generationAdvance = try XCTUnwrap(
            cancel.range(of: "historyContinuationGeneration &+= 1")
        )
        let taskCancel = try XCTUnwrap(
            cancel.range(of: "historyContinuationTask?.cancel()")
        )
        XCTAssertLessThan(
            generationAdvance.lowerBound,
            taskCancel.lowerBound,
            "Cancellation must invalidate the generation before the task can "
                + "resume from suspension."
        )

        let hide = try slice(
            viewer,
            from: "    private func hideManagedHistory(repo: Repository) async {\n",
            to: "    static func shouldHideManagedHistory("
        )
        let busyBarrier = try XCTUnwrap(
            hide.range(of: "isBusy = true")
        )
        let clear = try XCTUnwrap(
            hide.range(of: "clearPresentation()")
        )
        let deactivation = try XCTUnwrap(
            hide.range(of: "await repo.deactivateManagedViewerStore()")
        )
        XCTAssertLessThan(
            busyBarrier.lowerBound,
            clear.lowerBound,
            "Terminal history handling must close service entry guards before "
                + "clearing continuation state."
        )
        XCTAssertLessThan(
            clear.lowerBound,
            deactivation.lowerBound,
            "Terminal history handling must invalidate continuation work before "
                + "the suspending store switch."
        )
        XCTAssertTrue(
            hide.contains("defer { isBusy = wasBusy }"),
            "The entry barrier must remain active across the suspending store "
                + "switch and restore its caller-owned busy state afterward."
        )
        XCTAssertEqual(
            viewer.components(
                separatedBy: "await hideManagedHistory(repo: repo)"
            ).count - 1,
            7,
            "Every terminal catch path must share the cancel-before-deactivate helper."
        )
        let reconcile = try slice(
            viewer,
            from: "    private func reconcile(\n",
            to: "    private func loadManagedViewer("
        )
        XCTAssertTrue(
            reconcile.contains(
                "            } catch ManagedStorageError.authentication,\n"
                    + "                    ManagedStorageError.forbidden {\n"
                    + "                await hideManagedHistory(repo: repo)\n"
            ),
            "The post-load authentication catch must invalidate continuation "
                + "work before deactivating the account store."
        )
    }

    @MainActor
    func testTerminalFirebaseAuthHidesHistoryButTransientFailuresDoNot() {
        let terminalCodes: [AuthErrorCode] = [
            .invalidUserToken,
            .userTokenExpired,
            .userDisabled,
            .userNotFound,
        ]
        for code in terminalCodes {
            let error = NSError(
                domain: AuthErrors.domain,
                code: code.rawValue
            )
            XCTAssertTrue(
                MacManagedViewerService
                    .terminalFirebaseAuthenticationLoss(error),
                "\(code) should require a fresh sign-in"
            )
            XCTAssertTrue(
                MacManagedViewerService.shouldHideManagedHistory(for: error),
                "\(code) must hide the prior account's cached history"
            )
        }

        for code in [AuthErrorCode.networkError, .tooManyRequests] {
            let error = NSError(
                domain: AuthErrors.domain,
                code: code.rawValue
            )
            XCTAssertFalse(
                MacManagedViewerService
                    .terminalFirebaseAuthenticationLoss(error),
                "\(code) is transient and must retain cached history"
            )
            XCTAssertFalse(
                MacManagedViewerService.shouldHideManagedHistory(for: error),
                "\(code) must not hide a valid account's cached history"
            )
        }

        let offline = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )
        XCTAssertFalse(
            MacManagedViewerService.shouldHideManagedHistory(for: offline)
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
        XCTAssertTrue(
            strandTarget.contains("product: FirebaseAuth")
        )
        XCTAssertTrue(
            strandTarget.contains("product: FirebaseAppCheck")
        )
        XCTAssertTrue(
            strandTarget.contains("product: FirebaseCore")
        )
        XCTAssertTrue(
            strandTarget.contains(
                "com.apple.developer.devicecheck.appattest-environment"
            )
        )
        XCTAssertTrue(
            strandTarget.contains("Debug: Config/NOOPMac.xcconfig")
        )
    }

    func testFriendsUsesOneManagedAccountRouteWithoutProviderChoice() throws {
        let friends = try text("Strand/Screens/FriendsView.swift")
        let ios = try text("StrandiOS/System/ManagedFriendsView.swift")
        let mac = try text("Strand/Screens/MacManagedFriendsView.swift")
        let android = try text(
            "android/app/src/main/java/com/noop/ui/ManagedFriendsScreen.kt"
        )
        let viewer = try text("Strand/System/MacManagedViewerService.swift")

        XCTAssertTrue(friends.contains("ManagedFriendsView()"))
        XCTAssertTrue(
            friends.contains(
                "MacManagedFriendsView(service: macManagedService)"
            )
        )
        XCTAssertFalse(friends.contains("FriendsSource"))
        XCTAssertFalse(friends.contains("selfHostedBody"))
        XCTAssertFalse(friends.contains("FriendsService"))
        XCTAssertFalse(friends.contains("Enter invite details"))
        XCTAssertFalse(ios.contains("FriendsSourcePicker"))
        XCTAssertFalse(ios.contains("selectedSource"))
        XCTAssertFalse(mac.contains("FriendsSourcePicker"))
        XCTAssertFalse(mac.contains("self-hosted"))
        XCTAssertFalse(android.contains("FRIENDS_SOURCE_"))
        XCTAssertFalse(android.contains("FriendsSourcePicker"))
        XCTAssertFalse(android.contains("SelfHostedFriendsScreen("))
        XCTAssertFalse(
            exists(
                "android/app/src/main/java/com/noop/ui/FriendsScreen.kt"
            )
        )
        XCTAssertTrue(viewer.contains("platform: .macOS"))
        XCTAssertTrue(viewer.contains("client().enrollAccount("))
        XCTAssertFalse(viewer.contains("client().enroll("))
        XCTAssertFalse(viewer.contains("managedClient.overview("))
        XCTAssertTrue(viewer.contains("socialProfile("))
        XCTAssertTrue(viewer.contains("socialFriends("))
        XCTAssertTrue(viewer.contains("socialRequests("))
        XCTAssertTrue(viewer.contains("socialFeed("))
        XCTAssertTrue(viewer.contains("restoreOnly("))
        XCTAssertTrue(viewer.contains("restoreDocuments: false"))
        XCTAssertTrue(viewer.contains("WhoopManagedSyncStateStore("))
        XCTAssertTrue(viewer.contains("WhoopManagedRestoreApplier(store: store)"))
        XCTAssertTrue(viewer.contains(#""managed_macos.history_restore""#))
        XCTAssertTrue(viewer.contains("try await repo.refreshManagedViewer("))
        XCTAssertTrue(
            try text("Strand/App/RootView.swift").contains(
                "MacManagedViewerService.shared.bootstrap(repo: repo)"
            )
        )
        let root = try text("Strand/App/RootView.swift")
        let startup = try slice(
            root,
            from: "        .task {\n",
            to: "        .onChangeCompat(of: repo.refreshSeq) { _ in\n"
        )
        let bootstrap = try XCTUnwrap(
            startup.range(
                of: "await MacManagedViewerService.shared.bootstrap(repo: repo)"
            )
        )
        let localWait = try XCTUnwrap(
            startup.range(of: "if !repo.loaded")
        )
        XCTAssertLessThan(
            bootstrap.lowerBound,
            localWait.lowerBound,
            "Managed account bootstrap must not wait on legacy local history."
        )

        let appModel = try text("Strand/App/AppModel.swift")
        let viewerStartup = try slice(
            appModel,
            from: "        } else {\n"
                + "            AppDiagnosticsRecorder.shared.record(\n"
                + "                \"runtime.collection_role\",",
            to: "        Task.detached { AppModel.purgeImportInbox();"
        )
        XCTAssertFalse(viewerStartup.contains("repo.refresh()"))
        XCTAssertFalse(viewerStartup.contains("wireDeviceRegistry()"))
        XCTAssertTrue(mac.contains("Text(\"Account history\")"))
        XCTAssertTrue(mac.contains("await service.refresh(repo: repo)"))
        XCTAssertFalse(viewer.contains(".sync("))

        let forbiddenMutations = [
            "createSocialProfile(",
            "updateSocialProfile(",
            "deleteSocialProfile(",
            "createSocialRequest(",
            "decideSocialRequest(",
            "updateSocialVisibility(",
            "createSocialPoke(",
            "putSocialSummary(",
            "registerManagedPush",
            "reserveChunk(",
            "completeChunk(",
            "createSafety",
        ]
        for fragment in forbiddenMutations {
            XCTAssertFalse(
                viewer.contains(fragment),
                "macOS viewer reintroduced managed mutation: \(fragment)"
            )
        }
    }

    func testMacSidebarFooterReflectsManagedViewerSyncState() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(
            MacSidebarSyncPresentation.resolve(
                phase: .unavailable,
                isBusy: false,
                status: "",
                historyLastUpdatedAt: nil,
                historyHasMore: false,
                now: now
            ),
            MacSidebarSyncPresentation(
                title: String(localized: "History sync"),
                detail: String(
                    localized: "appwide.mac.viewer.synced_detail"
                ),
                tone: .critical
            )
        )
        XCTAssertEqual(
            MacSidebarSyncPresentation.resolve(
                phase: .signedOut,
                isBusy: false,
                status: "",
                historyLastUpdatedAt: nil,
                historyHasMore: false,
                now: now
            ).title,
            String(localized: "Sign in to NOOP")
        )
        XCTAssertEqual(
            MacSidebarSyncPresentation.resolve(
                phase: .emailVerificationRequired,
                isBusy: false,
                status: "",
                historyLastUpdatedAt: nil,
                historyHasMore: false,
                now: now
            ).tone,
            .warning
        )
        XCTAssertEqual(
            MacSidebarSyncPresentation.resolve(
                phase: .enrollmentRequired,
                isBusy: false,
                status: "",
                historyLastUpdatedAt: nil,
                historyHasMore: false,
                now: now
            ).title,
            String(localized: "Connect this Mac")
        )
        XCTAssertEqual(
            MacSidebarSyncPresentation.resolve(
                phase: .signedOut,
                isBusy: true,
                status: "",
                historyLastUpdatedAt: nil,
                historyHasMore: false,
                now: now
            ).tone,
            .active
        )

        let fresh = MacSidebarSyncPresentation.resolve(
            phase: .ready,
            isBusy: false,
            status: String(localized: "History synced"),
            historyLastUpdatedAt: now.addingTimeInterval(-5 * 60),
            historyHasMore: false,
            now: now
        )
        XCTAssertEqual(fresh.title, String(localized: "History synced"))
        XCTAssertEqual(fresh.detail, String(localized: "5 min ago"))
        XCTAssertEqual(fresh.tone, .positive)

        let stale = MacSidebarSyncPresentation.resolve(
            phase: .ready,
            isBusy: false,
            status: String(localized: "History synced"),
            historyLastUpdatedAt: now.addingTimeInterval(
                -MacSidebarSyncPresentation.staleAfter
            ),
            historyHasMore: false,
            now: now
        )
        XCTAssertEqual(stale.title, String(localized: "Sync now"))
        XCTAssertEqual(stale.tone, .warning)
        XCTAssertTrue(stale.detail.contains(String(localized: "1 d ago")))

        for historyHasMore in [false, true] {
            let pending = MacSidebarSyncPresentation.resolve(
                phase: .ready,
                isBusy: false,
                status: historyHasMore
                    ? String(localized: "History sync")
                    : "",
                historyLastUpdatedAt: nil,
                historyHasMore: historyHasMore,
                now: now
            )
            XCTAssertEqual(pending.title, String(localized: "History sync"))
            XCTAssertEqual(pending.detail, String(localized: "Sync now"))
            XCTAssertEqual(pending.tone, .warning)
        }
    }

    func testMacSidebarFooterMapsFailuresToFixedSafeCopy() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let network = String(
            localized:
                "NOOP could not reach the managed service. Check the connection and retry."
        )
        let networkFailure = MacSidebarSyncPresentation.resolve(
            phase: .ready,
            isBusy: false,
            status: network,
            historyLastUpdatedAt: now.addingTimeInterval(-60),
            historyHasMore: false,
            now: now
        )
        XCTAssertEqual(networkFailure.title, String(localized: "Try again"))
        XCTAssertEqual(networkFailure.detail, network)
        XCTAssertEqual(networkFailure.tone, .critical)

        let arbitraryMarker = "private-provider-error-marker"
        let fallback = MacSidebarSyncPresentation.resolve(
            phase: .ready,
            isBusy: false,
            status: arbitraryMarker,
            historyLastUpdatedAt: now.addingTimeInterval(-60),
            historyHasMore: false,
            now: now
        )
        XCTAssertEqual(
            fallback.detail,
            String(localized: "NOOP could not update this Mac.")
        )
        XCTAssertFalse(fallback.detail.contains(arbitraryMarker))
        XCTAssertEqual(fallback.tone, .critical)
    }

    func testMacSidebarFooterHasExplicitAccessibleStatus() throws {
        let root = try text("Strand/App/RootView.swift")

        XCTAssertTrue(
            root.contains(
                "MacSidebarSyncStatus(\n"
                    + "                    service: "
                    + "MacManagedViewerService.shared"
            )
        )
        XCTAssertTrue(
            root.contains("@ObservedObject var service: MacManagedViewerService")
        )
        XCTAssertTrue(
            root.contains(".accessibilityElement(children: .ignore)")
        )
        XCTAssertTrue(
            root.contains(".accessibilityLabel(Text(presentation.title))")
        )
        XCTAssertTrue(
            root.contains(".accessibilityValue(Text(presentation.detail))")
        )
        XCTAssertFalse(
            root.contains("SidebarStatus(viewerOnly: true)")
        )
    }

    func testManagedFriendsCopyIsLocalizedAcrossSupportedAppleLocales() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: catalogURL)
            ) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let locales = [
            "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant",
        ]
        let keys = [
            "Friends is unavailable",
            "This build cannot connect to the NOOP account service.",
            "Sign in to NOOP",
            "Use the verified email and password from your NOOP account. Account creation and band setup stay on the phone.",
            "NOOP account email",
            "NOOP account password",
            "Finish email verification from the account message, then return here. This Mac cannot activate or claim a band.",
            "Connect this Mac",
            "Allow this Mac to read your retained account history and accepted Friends summaries. It cannot collect band data, upload health history, page contacts, poke friends, or change sharing.",
            "Account history",
            "NOOP could not open its local history on this Mac.",
            "NOOP could not update this Mac.",
            "Sign out of NOOP on this Mac",
            "Finish Friends on your phone",
            "Create your private Friends profile and choose sharing from the collector phone. This Mac will then show the accepted summaries.",
            "Waiting for your decision on the phone",
            "Use the phone to manage this request",
            "No accepted friends yet",
            "Find, invite, accept, and configure sharing from the phone. This Mac stays read-only.",
            "Recent shared days",
            "Sign out on this Mac",
            "Read-only",
            "Delete Friends?",
            "Delete Friends",
            "Friendships, invitations, shared summaries, badges, pending pokes, Safety contacts, Safety invitations, and Safety incident history will be deleted. Any active Safety page and location sharing will end. Cloud backup and on-device data are unchanged.",
            "Account deletion scheduled",
            "Create your Friends profile",
            "Communication permissions",
            "Each permission is directional and can be revoked at any time. Nothing is sent automatically.",
            "Allow messages",
            "Allow photos",
            "Allow audio calls",
            "Allow video calls",
            "Communication they allow",
            "I can message them",
            "I can send photos",
            "I can start audio calls",
            "I can start video calls",
            "7 shared days",
            "30 shared days",
            "Milestone",
            "Deletion can begin after %@.",
            "Deletion time unavailable.",
        ]

        for key in keys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing managed Friends key: \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)"
            )
            for locale in locales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale) localization for: \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "Missing \(locale) string unit for: \(key)"
                )
                XCTAssertEqual(
                    unit["state"] as? String,
                    "translated",
                    "\(locale): \(key)"
                )
            }
        }
    }

    func testDeletionEligibilityUsesLocalizedDateFormatting() throws {
        let cloud = try text("StrandiOS/System/ManagedCloudViews.swift")
        let friends = try text("StrandiOS/System/ManagedFriendsView.swift")

        XCTAssertTrue(
            cloud.contains(
                "managedDeletionEligibilityText(notBefore)"
            )
        )
        XCTAssertTrue(
            friends.contains(
                "managedDeletionEligibilityText(notBefore)"
            )
        )
        XCTAssertTrue(
            cloud.contains(
                "date.formatted(date: .abbreviated, time: .shortened)"
            )
        )
        XCTAssertFalse(
            cloud.contains(#"Text("Deletion can begin after \(notBefore).")"#)
        )
        XCTAssertFalse(
            friends.contains(#"Text("Deletion can begin after \(notBefore).")"#)
        )
    }

    func testBandControlledLiveSessionIsCollectorOnlyAcrossTodayAndSettings() {
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
        XCTAssertFalse(
            SettingsView.showsCollectorLiveSessionControl(
                runtimeRole: .managedViewer
            )
        )
        XCTAssertTrue(
            SettingsView.showsCollectorLiveSessionControl(
                runtimeRole: .phoneCollector
            )
        )
    }

    private func text(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func exists(_ relativePath: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent(relativePath).path
        )
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }
}
