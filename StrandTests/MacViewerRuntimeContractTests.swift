import XCTest
@testable import Strand

final class MacViewerRuntimeContractTests: XCTestCase {
    func testCurrentMacRolePreservesLocalHistoryWithoutCollection() {
        XCTAssertEqual(AppRuntimeRole.currentPlatform, .managedViewer)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.allowsLocalCollection)
        XCTAssertFalse(AppRuntimeRole.currentPlatform.requiresCollectorOnboarding)
        XCTAssertTrue(AppRuntimeRole.currentPlatform.allowsLocalAnalysisAndGuidance)
        XCTAssertTrue(AppRuntimeRole.currentPlatform.hasManagedViewerTransport)
        XCTAssertTrue(AppRuntimeRole.currentPlatform.canPresentOperationalShell)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalCollection)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.requiresCollectorOnboarding)
        XCTAssertTrue(AppRuntimeRole.phoneCollector.allowsLocalAnalysisAndGuidance)
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
        XCTAssertTrue(viewer.contains("await repo.refresh()"))
        XCTAssertTrue(
            try text("Strand/App/RootView.swift").contains(
                "MacManagedViewerService.shared.bootstrap(repo: repo)"
            )
        )
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
