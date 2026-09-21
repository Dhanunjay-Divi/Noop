import Foundation
import XCTest

final class ManagedDocumentLifecycleContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func serviceSource() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(
                "StrandiOS/System/ManagedCloudService.swift"
            ),
            encoding: .utf8
        )
    }

    private func section(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(
                of: end,
                range: startRange.upperBound..<source.endIndex
            )
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testEncryptedRuntimeRequiresDurableRecoveryEnrollment() throws {
        let source = try serviceSource()
        let runtime = try section(
            source,
            from: "    private func managedDocumentRuntime(",
            to: "    nonisolated private static func managedNowMilliseconds"
        )

        let persisted = try XCTUnwrap(
            runtime.range(of: "persistedState = try storage.load")
        )
        let persistedGate = try XCTUnwrap(
            runtime.range(of: "guard let persistedState else")
        )
        let durableGate = try XCTUnwrap(
            runtime.range(
                of: "guard Self.hasDurableManagedDocumentRecoveryEnrollment"
            )
        )
        XCTAssertTrue(
            runtime.contains(
                "persistedState,\n"
                    + "            accountScopeHash: accountScopeHash"
            )
        )
        XCTAssertTrue(
            runtime.contains(
                "_ data: Data,\n"
                    + "        accountScopeHash: String"
            )
        )
        let vault = try XCTUnwrap(
            runtime.range(of: "let vault = ManagedDocumentKeyVault")
        )
        let recovery = try XCTUnwrap(
            runtime.range(
                of: "recoveryComplete = try await vault.recoveryEnrollmentComplete"
            )
        )
        let recoveryGate = try XCTUnwrap(
            runtime.range(of: "guard recoveryComplete else")
        )
        let inbox = try XCTUnwrap(
            runtime.range(of: "let inbox = ManagedDocumentCiphertextInbox")
        )
        let encryptedAdapter = try XCTUnwrap(
            runtime.range(of: "documentKeys: vault")
        )

        XCTAssertLessThan(persisted.lowerBound, persistedGate.lowerBound)
        XCTAssertLessThan(persistedGate.lowerBound, durableGate.lowerBound)
        XCTAssertLessThan(durableGate.lowerBound, vault.lowerBound)
        XCTAssertLessThan(vault.lowerBound, recovery.lowerBound)
        XCTAssertLessThan(recovery.lowerBound, recoveryGate.lowerBound)
        XCTAssertLessThan(recoveryGate.lowerBound, inbox.lowerBound)
        XCTAssertLessThan(inbox.lowerBound, encryptedAdapter.lowerBound)
        XCTAssertTrue(
            runtime.contains(
                "ManagedDocumentRuntimeMode.serverReadable.rawValue"
            )
        )
        XCTAssertTrue(
            runtime.contains(
                "ManagedDocumentRuntimeMode.clientEncrypted.rawValue"
            )
        )
        XCTAssertTrue(
            runtime.contains("async throws -> ManagedCloudDocumentAdapter")
        )
        XCTAssertFalse(
            runtime.contains("WhoopManagedDocumentAdapter(")
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "managedDocumentRuntime(").count - 1,
            3
        )
    }

    func testManagedSyncValidatorsUseImmutableActorCapture() throws {
        let source = try serviceSource()

        XCTAssertEqual(
            source.components(
                separatedBy: "[self] in"
            ).count - 1,
            2
        )
        XCTAssertEqual(
            source.components(
                separatedBy:
                    "@Sendable (Data) async throws -> Void = { [self] payload in"
            ).count - 1,
            2
        )
        XCTAssertFalse(
            source.contains(
                "[weak self] in\n"
                    + "                try await MainActor.run"
            )
        )
    }

    func testConfirmedAccountDeletionPurgesBeforeSignOutAndEnrollmentClear() throws {
        let source = try serviceSource()
        let completed = try section(
            source,
            from: "    private func completeLocalErasureState()",
            to: "    private func purgeManagedDocumentLocalState()"
        )

        let purge = try XCTUnwrap(
            completed.range(of: "guard purgeManagedDocumentLocalState()")
        )
        let signOut = try XCTUnwrap(
            completed.range(of: "Auth.auth().signOut()")
        )
        let clear = try XCTUnwrap(
            completed.range(of: "clearEnrollment()")
        )
        XCTAssertLessThan(purge.lowerBound, signOut.lowerBound)
        XCTAssertLessThan(signOut.lowerBound, clear.lowerBound)
        let purgeState = try section(
            source,
            from: "    private func purgeManagedDocumentLocalState()",
            to: "    private func restoreAfterCanceledErasure"
        )
        XCTAssertTrue(
            purgeState.contains(
                "let scopeHash =\n"
                    + "            defaults.string("
            )
        )
        XCTAssertTrue(
            purgeState.contains(
                "forKey: Key.enrolledScopeHash"
            )
        )
        XCTAssertFalse(purgeState.contains("accountScopeHash()"))
        let ciphertextPurge = try XCTUnwrap(
            purgeState.range(of: "ManagedDocumentCiphertextInbox")
        )
        let keyRemoval = try XCTUnwrap(
            purgeState.range(of: "try storage.remove(")
        )
        let mappingRemoval = try XCTUnwrap(
            purgeState.range(of: "accountScopeRecoveryStore.remove()")
        )
        XCTAssertLessThan(ciphertextPurge.lowerBound, keyRemoval.lowerBound)
        XCTAssertLessThan(keyRemoval.lowerBound, mappingRemoval.lowerBound)
        XCTAssertTrue(
            purgeState.contains(#""scope_mapping": scopeMapping"#)
        )
    }

    func testDeletionPurgesOnlyAfterExplicitCompletedStatus() throws {
        let source = try serviceSource()
        let refresh = try section(
            source,
            from: "    func refreshDeletionStatus() async",
            to: "    func cancelAccountDeletion() async"
        )

        XCTAssertFalse(source.contains("deletionDeadlineHasPassed"))
        XCTAssertFalse(source.contains("completeLocalDeletionHandoff"))
        XCTAssertFalse(refresh.contains("catch ManagedStorageError.notFound"))
        XCTAssertTrue(refresh.contains("client().erasureReceipt("))
        XCTAssertTrue(refresh.contains("erasureReceiptAuthorization()"))
        XCTAssertFalse(refresh.contains("authorization(forceRefresh: false)"))
        XCTAssertEqual(
            refresh.components(
                separatedBy: #"job.status == "completed""#
            ).count - 1,
            1
        )
        XCTAssertEqual(
            refresh.components(
                separatedBy: "completeLocalErasureState()"
            ).count - 1,
            1
        )
        XCTAssertTrue(refresh.contains("phase = .deletionScheduled"))
        XCTAssertTrue(refresh.contains(#""outcome": "pending_retry""#))
    }

    func testDisconnectPreservesRecoverableDocumentKeys() throws {
        let source = try serviceSource()
        let disconnect = try section(
            source,
            from: "    func disconnect() async",
            to: "    private func unregisterManagedMessagingInstallation()"
        )

        XCTAssertFalse(
            disconnect.contains("purgeManagedDocumentLocalState")
        )
        XCTAssertTrue(
            disconnect.contains(
                "updateManagedDocumentProfileBinding(\n"
                    + "                    accountScopeHash: nil"
            )
        )
        XCTAssertTrue(
            disconnect.contains("await cancelAndAwaitAccountOperations()")
        )
        XCTAssertTrue(disconnect.contains("Auth.auth().signOut()"))
        XCTAssertTrue(disconnect.contains("clearEnrollment()"))
        XCTAssertTrue(
            disconnect.contains(
                #"reason: "disconnect_requested""#
            )
        )
        XCTAssertFalse(
            disconnect.contains("stopManagedSafetyLocationSharing")
        )
        let boundary = try XCTUnwrap(
            disconnect.range(
                of: #"reason: "disconnect_requested""#
            )
        )
        let quiesce = try XCTUnwrap(
            disconnect.range(of: "await cancelAndAwaitAccountOperations()")
        )
        let signOut = try XCTUnwrap(disconnect.range(of: "Auth.auth().signOut()"))
        let clear = try XCTUnwrap(disconnect.range(of: "clearEnrollment()"))
        XCTAssertLessThan(boundary.lowerBound, quiesce.lowerBound)
        XCTAssertLessThan(quiesce.lowerBound, signOut.lowerBound)
        XCTAssertLessThan(signOut.lowerBound, clear.lowerBound)
        XCTAssertTrue(
            disconnect.contains(
                "updateManagedDocumentProfileBinding(\n"
                    + "                    accountScopeHash: scopeHash"
            )
        )
        let clearEnrollment = try section(
            source,
            from: "    private func clearEnrollment()",
            to: "    private func clearSocialPresentation()"
        )
        XCTAssertFalse(
            clearEnrollment.contains(
                "removeObject(forKey: Key.accountScopeRecoveryMapping)"
            )
        )
    }

    func testAuthChangesCancelAndFenceAccountRefreshes() throws {
        let source = try serviceSource()
        let boundary = try section(
            source,
            from: "    private func makeAccountOperationFence(",
            to: "    private func accountScopeHash()"
        )
        let safety = try section(
            source,
            from: "    private func refreshSafetyData(",
            to: "    private func reconcileManagedSafetyLocationSharing("
        )
        let social = try section(
            source,
            from: "    private func refreshSocialData(",
            to: "    private static func socialSummaryDays("
        )

        XCTAssertTrue(source.contains("addStateDidChangeListener"))
        XCTAssertTrue(boundary.contains("accountOperationGeneration &+= 1"))
        XCTAssertTrue(boundary.contains("accountTransitioning = true"))
        XCTAssertTrue(boundary.contains("managedSyncTask?.cancel()"))
        XCTAssertTrue(boundary.contains("managedHistoryImportTask?.cancel()"))
        XCTAssertTrue(boundary.contains("socialRefreshTask?.cancel()"))
        XCTAssertTrue(boundary.contains("safetyRefreshTask?.cancel()"))
        XCTAssertTrue(boundary.contains("cancelAndAwaitAccountOperations()"))
        XCTAssertTrue(boundary.contains("if let syncTask"))
        XCTAssertTrue(boundary.contains("try? await syncTask.value"))
        XCTAssertTrue(boundary.contains("if let profileBinding"))
        XCTAssertTrue(boundary.contains("await profileBinding.value"))
        XCTAssertTrue(
            boundary.contains(
                "private func handleAuthStateChange(_ user: User?) async"
            )
        )
        let handler = try section(
            source,
            from: "    private func handleAuthStateChange(_ user: User?) async",
            to: "    private func accountScopeHash()"
        )
        let awaitOldWork = try XCTUnwrap(
            handler.range(of: "await cancelAndAwaitAccountOperations()")
        )
        let finishBoundary = try XCTUnwrap(
            handler.range(
                of: "finishAccountBoundaryTransition(generation: generation)"
            )
        )
        let rebind = try XCTUnwrap(
            handler.range(of: "reconcileAuthenticatedState()")
        )
        XCTAssertLessThan(awaitOldWork.lowerBound, finishBoundary.lowerBound)
        XCTAssertLessThan(finishBoundary.lowerBound, rebind.lowerBound)
        XCTAssertTrue(
            safety.contains("try validateAccountOperationFence(fence)")
        )
        XCTAssertGreaterThanOrEqual(
            social.components(
                separatedBy: "try validateAccountOperationFence(fence)"
            ).count - 1,
            8
        )
    }

    func testManagedSyncCoalescingRepeatsDifferentModes() throws {
        let source = try serviceSource()
        let sync = try section(
            source,
            from: "    private enum SyncMode: Equatable",
            to: "    private func performSync("
        )

        XCTAssertTrue(source.contains("private var managedSyncMode: SyncMode?"))
        XCTAssertTrue(sync.contains("let existingMode = managedSyncMode"))
        XCTAssertTrue(sync.contains("guard existingMode != mode else"))
        XCTAssertTrue(sync.contains("return try await sync(repo: repo, mode: mode)"))
        XCTAssertTrue(sync.contains("managedSyncMode = mode"))
        XCTAssertTrue(sync.contains("managedSyncMode = nil"))
    }

    func testSocialRefreshRepeatsWhenPokeDeliveryWasCoalescedAway() throws {
        let source = try serviceSource()
        let social = try section(
            source,
            from: "    private func refreshSocialData(",
            to: "    private static func socialSummaryDays("
        )

        XCTAssertTrue(
            source.contains("private var socialRefreshDeliversPokes = false")
        )
        XCTAssertTrue(
            social.contains(
                "guard deliverPokes && !existingDeliversPokes"
            )
        )
        XCTAssertTrue(
            social.contains(
                "deliverPokes: true"
            )
        )
    }

    func testLifecycleDiagnosticsAreCategoricalAndPayloadFree() throws {
        let source = try serviceSource()
        let runtime = try section(
            source,
            from: "    private func managedDocumentRuntime(",
            to: "    nonisolated private static func managedNowMilliseconds"
        )
        let purge = try section(
            source,
            from: "    private func purgeManagedDocumentLocalState()",
            to: "    private func restoreAfterCanceledErasure"
        )
        let diagnostics = runtime + purge

        XCTAssertTrue(
            diagnostics.contains("\"managed_documents.runtime\"")
        )
        XCTAssertTrue(
            diagnostics.contains(
                "\"managed_documents.account_delete_purge\""
            )
        )
        for forbidden in [
            "localizedDescription",
            "errorDescription",
            "\"account_scope\"",
            "\"payload\"",
            "\"identifier\"",
        ] {
            XCTAssertFalse(diagnostics.contains(forbidden))
        }
    }

    func testManagedHistoryProgressIsLocalizedAcrossSupportedLocales()
        throws
    {
        let catalog = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Strand/Resources/Localizable.xcstrings"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalog) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let locales = [
            "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant",
        ]
        let keys = [
            "Finishing current phone backup before export…",
            "Creating a consistent cloud-history snapshot…",
            "Exporting cloud history: %1$lld of %2$lld objects, %3$@ of %4$@.",
            "Exporting personal records: %1$lld of %2$lld objects.",
            "Verifying %lld exported objects and finalizing the archive…",
            "Validating every object in the cloud-history archive…",
            "Importing cloud history: %1$lld of %2$lld objects, %3$@ of %4$@.",
            "Finalizing %lld imported objects…",
            "NOOP safely paused after a large backup catch-up. Keep the app open, sync again, then retry the complete cloud-history export.",
        ]

        for key in keys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing managed-history localization: \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any]
            )
            for locale in locales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale): \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any]
                )
                XCTAssertEqual(unit["state"] as? String, "translated")
                XCTAssertFalse(
                    (unit["value"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty ?? true,
                    "\(locale): \(key)"
                )
            }
        }
    }

    func testManagedAccountDeletionCopyIsLocalizedAcrossSupportedLocales()
        throws
    {
        let catalog = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Strand/Resources/Localizable.xcstrings"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalog) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let locales = [
            "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant",
        ]
        let keys = [
            "Delete NOOP account?",
            "Verification code",
            "Send verification code",
            "Cloud data and your NOOP account will be scheduled for deletion after a 24-hour cooling-off period. Data stored locally on this iPhone is not deleted.",
            "NOOP+ verification code",
            "Delete NOOP account…",
            "Account deletion verification code",
            "A verification code was sent.",
            "Request a new verification code.",
            "A fresh verification code was sent to %@.",
            "Send a fresh verification code before deleting your NOOP account.",
            "NOOP account deletion is scheduled after the 24-hour cooling-off period.",
            "NOOP account deletion status: %@.",
            "NOOP account deletion completed. Local NOOP data remains on this iPhone.",
            "NOOP account deletion is processing in the cloud. Local NOOP data remains on this iPhone.",
            "NOOP account deletion was canceled.",
            "Enter the verification code from the text message.",
        ]

        for key in keys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing managed-account deletion localization: \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any]
            )
            for locale in locales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale): \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any]
                )
                XCTAssertEqual(unit["state"] as? String, "translated")
                XCTAssertFalse(
                    (unit["value"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty ?? true,
                    "\(locale): \(key)"
                )
            }
        }
    }

    func testRetiredSelfHostedFriendsCatalogCopyIsAbsent() throws {
        let catalog = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Strand/Resources/Localizable.xcstrings"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalog) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let retiredKeys = [
            "Leave this circle and delete your server profile?",
            "Leave & delete server copy",
            "Host your private circle",
            "Friends lives on a Noop server you control. There is no Noop account or public profile.",
            "Set up your server",
            "An invitation includes a server address and one-time code. You can join without receiving the server administrator key.",
            "The server administrator key is used once to issue a separate member token. That token stays in Keychain and cannot read raw server data. Friends is not end-to-end encrypted, so use a server operator you trust.",
            "%lld people in your private circle",
            "Leave circle & delete server copy…",
            "Join my private Noop circle",
            "Open the Friends tab in Noop and enter the server address and one-time code.",
            "Trust the server operator",
            "Private server",
            "Sharing is directional and enforced by your server.",
        ]

        for key in retiredKeys {
            XCTAssertNil(
                strings[key],
                "Retired self-hosted Friends copy returned: \(key)"
            )
        }
    }

    func testEnrollmentUsesProjectTenantBindingWithoutMovingLegacyData()
        throws
    {
        let source = try serviceSource()
        let enrollment = try section(
            source,
            from: "    func enroll(repo: Repository) async",
            to: "    func syncNow(repo: Repository) async"
        )
        let binding = try section(
            source,
            from: "    private func accountScopeBinding(",
            to: "    private func scheduleManagedDocumentProfileBinding("
        )

        XCTAssertTrue(enrollment.contains("accountScopeBinding("))
        XCTAssertTrue(
            enrollment.contains(
                "binding.dataScopeHash"
            )
        )
        XCTAssertTrue(
            binding.contains(
                "projectID: try Self.firebaseValues().projectID"
            )
        )
        XCTAssertTrue(binding.contains("tenantID: user.tenantID"))
        XCTAssertTrue(
            binding.contains(
                "forKey: Key.enrolledScopeHash"
            )
        )
        XCTAssertTrue(
            enrollment.contains(
                "preserveAccountScopeRecoveryBinding(binding)"
            )
        )
        XCTAssertTrue(
            binding.contains(
                "let recoveryMapping = try accountScopeRecoveryStore.load()"
            )
        )
        XCTAssertTrue(
            binding.contains(
                "recoveryMapping: recoveryMapping"
            )
        )
        XCTAssertTrue(
            binding.contains(
                "try preserveAccountScopeRecoveryBinding(binding)"
            )
        )
        XCTAssertFalse(
            binding.contains(
                #"noop-managed-account-v1\0\(user.uid)"#
            )
        )
    }
}
