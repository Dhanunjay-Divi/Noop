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
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "managedDocumentRuntime(").count - 1,
            3
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
                "let scopeHash = defaults.string("
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
        XCTAssertTrue(disconnect.contains("await cancelAndAwaitAccountRefreshes()"))
        XCTAssertTrue(disconnect.contains("Auth.auth().signOut()"))
        XCTAssertTrue(disconnect.contains("clearEnrollment()"))
        XCTAssertTrue(
            disconnect.contains(
                #"beginAccountBoundaryTransition(reason: "disconnect_completed")"#
            )
        )
        XCTAssertFalse(
            disconnect.contains("stopManagedSafetyLocationSharing")
        )
        let signOut = try XCTUnwrap(disconnect.range(of: "Auth.auth().signOut()"))
        let boundary = try XCTUnwrap(
            disconnect.range(
                of: #"beginAccountBoundaryTransition(reason: "disconnect_completed")"#
            )
        )
        let clear = try XCTUnwrap(disconnect.range(of: "clearEnrollment()"))
        XCTAssertLessThan(signOut.lowerBound, boundary.lowerBound)
        XCTAssertLessThan(boundary.lowerBound, clear.lowerBound)
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
            from: "    private func makeAccountOperationFence()",
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
        XCTAssertTrue(boundary.contains("managedSyncTask?.cancel()"))
        XCTAssertTrue(boundary.contains("socialRefreshTask?.cancel()"))
        XCTAssertTrue(boundary.contains("safetyRefreshTask?.cancel()"))
        XCTAssertTrue(boundary.contains("cancelAndAwaitAccountRefreshes()"))
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
