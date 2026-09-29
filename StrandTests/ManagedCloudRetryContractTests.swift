import Foundation
@testable import NoopRemoteSync
@testable import Strand
import XCTest

final class ManagedCloudRetryContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "ManagedCloudRetryContractTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testScopedRetryStateClearsWithoutTouchingOtherScopesOrDefaults()
        throws
    {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let coreDeadline = Date(timeIntervalSince1970: 2_000_000_000)
        let safetyDeadline = Date(timeIntervalSince1970: 2_000_000_900)

        ManagedCloudRetryStateStore.store(
            scope: .core,
            failureCount: 2,
            notBefore: coreDeadline,
            defaults: defaults
        )
        ManagedCloudRetryStateStore.store(
            scope: .safety,
            failureCount: 4,
            notBefore: safetyDeadline,
            defaults: defaults
        )
        defaults.set("preserved", forKey: "unrelated")

        ManagedCloudRetryStateStore.clear(.core, defaults: defaults)

        XCTAssertNil(
            ManagedCloudRetryStateStore.pendingRetry(
                for: .core,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedCloudRetryStateStore.pendingRetry(
                for: .safety,
                defaults: defaults
            ),
            .init(failureCount: 4, notBefore: safetyDeadline)
        )
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserved")
    }

    func testLegacySharedDeadlineMigratesConservativelyOnce() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        defaults.set(3, forKey: "managedCloud.retry.failureCount.v1")
        defaults.set(
            deadline.timeIntervalSince1970,
            forKey: "managedCloud.retry.notBefore.v1"
        )

        for scope in ManagedCloudRetryScope.allCases {
            XCTAssertEqual(
                ManagedCloudRetryStateStore.pendingRetry(
                    for: scope,
                    defaults: defaults
                ),
                .init(failureCount: 3, notBefore: deadline)
            )
        }
        XCTAssertNil(
            defaults.object(forKey: "managedCloud.retry.failureCount.v1")
        )
        XCTAssertNil(
            defaults.object(forKey: "managedCloud.retry.notBefore.v1")
        )
    }

    func testCompletedAccountLifecyclesClearEveryRetryScope() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let clearEnrollment = try section(
            apple,
            from: "    private func clearEnrollment()",
            to: "    private func clearSocialPresentation()"
        )
        let disconnect = try section(
            apple,
            from: "    func disconnect() async",
            to: "    private func unregisterManagedMessagingInstallation()"
        )
        let completedErasure = try section(
            apple,
            from: "    private func completeLocalErasureState()",
            to: "    private func purgeManagedDocumentLocalState()"
        )

        XCTAssertTrue(
            clearEnrollment.contains("ManagedCloudRetryScheduler.clearAll()")
        )
        XCTAssertTrue(disconnect.contains("clearEnrollment()"))
        XCTAssertTrue(completedErasure.contains("clearEnrollment()"))
        XCTAssertTrue(
            apple.contains(
                "stopManagedSafetyLocationSharing(reason: \"signed_out\")\n"
                    + "            ManagedCloudRetryScheduler.clearAll()"
            )
        )
    }

    func testManualCoreSyncDoesNotClearAutomaticRetryState() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let start = try XCTUnwrap(
            apple.range(of: "func syncNow(repo: Repository) async")
        )
        let end = try XCTUnwrap(
            apple.range(
                of: "func exportCompleteCloudHistory",
                range: start.upperBound..<apple.endIndex
            )
        )
        let body = String(apple[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("ManagedCloudRetryScheduler.clear"))
    }

    func testDocumentConflictHasBoundedEvidenceAndVisibleManualRetry()
        throws
    {
        let appleService = try source(
            "StrandiOS/System/ManagedCloudService.swift"
        )
        XCTAssertTrue(appleService.contains("""
            case .documentConflict:
                            return "document_conflict"
            """))
        XCTAssertTrue(
            appleService.contains(
                "NOOP kept your current data. Review your latest changes, then tap Sync now to retry."
            )
        )
        let appleView = try source(
            "StrandiOS/System/ManagedCloudViews.swift"
        )
        XCTAssertTrue(appleView.contains("\"Sync now\""))

        let androidService = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt"
        )
        XCTAssertTrue(
            androidService.contains(
                "if (error.documentKind == null) \"sync_conflict\" else \"document_conflict\""
            )
        )
        XCTAssertTrue(
            androidService.contains(
                "R.string.managed_cloud_error_document_conflict"
            )
        )
        let androidView = try source(
            "android/app/src/main/java/com/noop/ui/ManagedCloudCard.kt"
        )
        XCTAssertTrue(
            androidView.contains(
                "stringResource(R.string.managed_cloud_sync_now)"
            )
        )
    }

    func testManagedHistoryExportResetPolicyClearsOnlyUnusableState() {
        let resetErrors: [Error] = [
            ManagedHistoryExportStateError.unusableStagedArchive,
            ManagedStorageError.invalidResponse,
            ManagedStorageError.decoding,
            ManagedStorageError.cursorExpired(minimumSequence: nil),
            ManagedStorageError.notFound,
            ManagedStorageError.conflict,
            ManagedStorageError.documentConflict(
                documentKind: .hydration,
                remoteRevision: 3
            ),
            ManagedStorageError.digestMismatch,
            ManagedHistoryArchiveError.invalidArchive,
        ]
        for error in resetErrors {
            XCTAssertTrue(
                managedHistoryExportNeedsReset(after: error),
                "Expected reset for \(error)"
            )
        }

        let resumableErrors: [Error] = [
            ManagedStorageError.transport,
            ManagedStorageError.authentication,
            ManagedStorageError.forbidden,
            ManagedStorageError.policyChanged,
            ManagedStorageError.quotaExceeded,
            ManagedStorageError.server(status: 503),
        ]
        for error in resumableErrors {
            XCTAssertFalse(
                managedHistoryExportNeedsReset(after: error),
                "Expected checkpoint preservation for \(error)"
            )
        }
        XCTAssertFalse(
            managedHistoryExportNeedsReset(
                after: ManagedHistoryArchiveError.invalidArchive,
                at: .localArchiveOutput
            )
        )
    }

    func testAppleExportRecoveryClearsCorruptStagedState() async throws {
        let fixture = try await managedHistoryTransferFixture()
        try Data("corrupt".utf8).write(to: fixture.stagedEntryURL)

        do {
            try await fixture.store.validateStagedExport(
                manifest: fixture.manifest
            )
            XCTFail("Expected corrupt staged state")
        } catch {
            XCTAssertEqual(
                error as? ManagedHistoryExportStateError,
                .unusableStagedArchive
            )
            let reset = await applyManagedHistoryExportRecovery(
                after: error,
                at: .stagedState,
                clearExport: {
                    await fixture.store.clearExport()
                }
            )
            XCTAssertTrue(reset)
        }

        let checkpoint = try await fixture.store.loadExportCheckpoint()
        XCTAssertNil(checkpoint)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.stagedEntryURL.path
            )
        )
    }

    func testAppleExportRecoveryPreservesStateForTransientOutputFailure()
        async throws
    {
        let fixture = try await managedHistoryTransferFixture()
        try await fixture.store.validateStagedExport(
            manifest: fixture.manifest
        )
        let outputFailure = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )

        let reset = await applyManagedHistoryExportRecovery(
            after: outputFailure,
            at: .localArchiveOutput,
            clearExport: {
                await fixture.store.clearExport()
            }
        )

        XCTAssertFalse(reset)
        let checkpoint = try await fixture.store.loadExportCheckpoint()
        XCTAssertNotNil(checkpoint)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.stagedEntryURL.path
            )
        )
    }

    func testAppleServiceClassifiesAtomicFinalizeBeforeOutputBoundary() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let finalization = try XCTUnwrap(
            apple.range(of: "try await transfer.finalizeExport(")
        )
        let outputBoundary = try XCTUnwrap(
            apple.range(
                of: "failureBoundary = .localArchiveOutput",
                range: finalization.upperBound..<apple.endIndex
            )
        )
        XCTAssertLessThan(
            finalization.lowerBound,
            outputBoundary.lowerBound
        )
        XCTAssertTrue(
            apple.contains(
                "catch let error as ManagedHistoryExportStateError"
            )
        )
        XCTAssertFalse(
            apple.contains("try await transfer.validateStagedExport(")
        )
        XCTAssertTrue(apple.contains("\"retry_state\": resetApplied"))
    }

    func testAppleCatchUpRetriesAndClearsEachScopeIndependently() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let retry = try source("StrandiOS/System/ManagedCloudRetry.swift")

        for scope in ["core", "social", "safety"] {
            XCTAssertTrue(
                apple.contains(
                    "ManagedCloudRetryScheduler.pendingRetry(for: .\(scope))"
                )
            )
            XCTAssertTrue(
                apple.contains(
                    "ManagedCloudRetryScheduler.clear(.\(scope))"
                )
            )
            XCTAssertTrue(apple.contains("scope: .\(scope)"))
        }
        XCTAssertEqual(
            apple.components(
                separatedBy:
                    "if Self.isAutomaticCatchUpCancellation(error) { return false }"
            ).count - 1,
            3
        )
        XCTAssertFalse(apple.contains("strictestRetryableFailure"))
        XCTAssertTrue(retry.contains("\"scope\": scope.rawValue"))
        XCTAssertTrue(retry.contains("retryAfter: retryAfter"))
    }

    func testAppleAccountOnlyFriendsCatchUpKeepsStorageScopesGated()
        throws
    {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        XCTAssertTrue(
            apple.contains(
                "let storageEnrolled = phase == .enrolled"
            )
        )
        XCTAssertTrue(
            apple.contains(
                "accountAccessReady && defaults.bool(forKey: Key.socialEnabled)"
            )
        )
        XCTAssertTrue(
            apple.contains(
                "let coreEnabled = storageEnrolled && automatic"
            )
        )
        XCTAssertTrue(
            apple.contains(
                "guard storageEnrolled || socialEnabled else { return true }"
            )
        )
        XCTAssertTrue(
            apple.contains(
                "guard !disconnecting,\n"
                    + "              !accountTransitioning,\n"
                    + "              !isBusy,\n"
                    + "              !running,\n"
                    + "              !socialRunning,\n"
                    + "              !safetyRunning\n"
                    + "        else { return false }"
            )
        )
        XCTAssertTrue(apple.contains("if coreEnabled"))
        XCTAssertTrue(apple.contains("if socialEnabled,"))
        XCTAssertTrue(apple.contains("if safetyEnabled,"))
    }

    func testAppleAccountEnrollmentAcceptsExistingHealthPrivacyState() throws {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let enrollment = try section(
            apple,
            from: "    func enrollAccount() async",
            to: "    func enroll(repo: Repository) async"
        )

        XCTAssertTrue(
            enrollment.contains("response.productBoundary.accountReady")
        )
        XCTAssertTrue(
            enrollment.contains(
                "response.productBoundary.edgeCollectionRequired"
            )
        )
        XCTAssertFalse(enrollment.contains("healthDataConsentGranted"))
        XCTAssertFalse(enrollment.contains("healthDataUploaded"))
        XCTAssertTrue(
            enrollment.contains(
                "localized: \"Your NOOP account is ready.\""
            )
        )
    }

    func testAccountOnlyDeletionUsesPersistedAccountInstallationScope()
        throws
    {
        let apple = try source("StrandiOS/System/ManagedCloudService.swift")
        let android = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt"
        )
        let friends = try source(
            "StrandiOS/System/ManagedFriendsView.swift"
        )
        let androidFriends = try source(
            "android/app/src/main/java/com/noop/ui/ManagedFriendsScreen.kt"
        )

        XCTAssertGreaterThanOrEqual(
            apple.components(
                separatedBy:
                    "?? defaults.string(forKey: Key.accountAccessScopeHash)"
            ).count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            android.components(
                separatedBy: "?: preferences.accountAccessScopeHash"
            ).count - 1,
            2
        )
        XCTAssertTrue(
            friends.contains(
                "if service.phase == .deletionScheduled"
            )
        )
        XCTAssertTrue(friends.contains("accountDeletionScheduledCard"))
        XCTAssertTrue(friends.contains("accountManagementCard"))
        XCTAssertTrue(apple.contains(
            "reason: \"deletion_requested\""
        ))
        XCTAssertTrue(apple.contains(
            "await cancelAndAwaitAccountOperations()"
        ))
        XCTAssertTrue(apple.contains(
            "clearSocialState(preservingEnabled: true)"
        ))
        XCTAssertTrue(android.contains(
            "private suspend fun scheduleAccountDeletion() =\n"
                + "        socialMutex.withLock"
        ))
        XCTAssertTrue(android.contains(
            "preferences.clearSocialState(preserveEnabled = true)"
        ))
        XCTAssertTrue(androidFriends.contains(
            "LaunchedEffect(service, state.accountAccessReady)"
        ))
    }

    func testAndroidFallbackReleasesDeadlineBeforeWorkerRetryAndAuthClearsState()
        throws
    {
        let source = try source(
            "android/app/src/main/java/com/noop/managed/ManagedCloudScheduler.kt"
        )
        XCTAssertTrue(source.contains("scope = failure.scope"))
        XCTAssertTrue(source.contains("return aggregateOutcome"))
        XCTAssertTrue(source.contains("scopedRetryEnqueueTransition("))
        XCTAssertTrue(source.contains("retryStore.clear(failure.scope)"))
        XCTAssertTrue(source.contains("RetryEnqueueOutcome.WORKER_RETRY"))
        XCTAssertTrue(
            source.contains(
                "if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {\n"
                    + "            ManagedCloudRetryStore(applicationContext).clearAll()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "if (!service.shouldSchedule()) {\n"
                    + "            ManagedCloudRetryStore(applicationContext).clearAll()"
            )
        )
        XCTAssertTrue(source.contains("\"enqueue_outcome\""))
    }

    private func managedHistoryTransferFixture() async throws -> (
        store: ManagedHistoryTransferStore,
        manifest: ManagedHistoryExportManifest,
        stagedEntryURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "managed-history-retry-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let scope = String(repeating: "d", count: 64)
        let store = try ManagedHistoryTransferStore(
            accountScopeHash: scope,
            baseDirectoryURL: root
        )
        let data = Data("staged-entry".utf8)
        let path =
            "chunks/essential_timeseries/"
            + "14000000-0000-5000-8000-000000000001.json"
        let chunk = ManagedHistoryExportManifest.Chunk(
            path: path,
            chunkID: UUID(
                uuidString: "14000000-0000-5000-8000-000000000001"
            )!,
            sourceID: UUID(
                uuidString: "14000000-0000-5000-8000-000000000002"
            )!,
            dataClass: "essential_timeseries",
            schemaVersion: 1,
            eventStart: "2026-09-18T00:00:00Z",
            eventEnd: "2026-09-18T00:01:00Z",
            compression: "none",
            contentType: "application/vnd.noop.chunk+json",
            sha256: ManagedDigest.sha256(data),
            compressedBytes: data.count,
            uncompressedBytes: data.count,
            objectGeneration: 1
        )
        let manifest = ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: 2,
            createdAt: "2026-09-19T12:00:00Z",
            snapshotAt: "2026-09-19T11:59:00Z",
            changeSequence: 42,
            dataClasses: ["essential_timeseries"],
            selectedObjects: 1,
            selectedChunkBytes: Int64(data.count),
            exportedObjects: 1,
            exportedChunkBytes: Int64(data.count),
            chunks: [chunk],
            documents: []
        )
        let checkpoint = ManagedHistoryExportCheckpoint(
            createdAt: manifest.createdAt,
            requestID: UUID(),
            restoreJobID: UUID(),
            snapshotAt: manifest.snapshotAt,
            changeSequence: manifest.changeSequence,
            expiresAt: "2026-09-20T12:00:00Z",
            dataClasses: manifest.dataClasses,
            pageSize: 100,
            selectedObjects: 1,
            selectedChunkBytes: Int64(data.count),
            dataClassIndex: 1,
            documentsComplete: true,
            serverCompleted: true,
            exportedObjects: 1,
            exportedChunkBytes: Int64(data.count),
            chunks: [chunk]
        )
        try await store.add(
            ManagedHistoryExportEntry(
                kind: .chunk,
                path: path,
                data: data
            )
        )
        try await store.saveExportCheckpoint(checkpoint)
        let stagedEntryURL = root
            .appendingPathComponent("ManagedHistoryTransfers", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("export-entries", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        return (store, manifest, stagedEntryURL)
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
}
