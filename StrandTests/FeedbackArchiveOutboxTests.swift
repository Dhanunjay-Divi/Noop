import XCTest
import ZIPFoundation
@testable import Strand

private final class OneShotArchiveRemovalFailureFileManager:
    FileManager,
    @unchecked Sendable {
    private let stateLock = NSLock()
    private var remainingFailures = 1
    private var archiveRemovalAttempts = 0

    override func removeItem(at url: URL) throws {
        guard url.lastPathComponent == FeedbackOutboxRecord.archiveFileName else {
            try super.removeItem(at: url)
            return
        }

        stateLock.lock()
        archiveRemovalAttempts += 1
        let shouldFail = remainingFailures > 0
        if shouldFail {
            remainingFailures -= 1
        }
        stateLock.unlock()

        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }

    func removalAttemptCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return archiveRemovalAttempts
    }
}

private actor FeedbackAuthorizationGateProbe {
    private var active = 0
    private var maximumActive = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }

    func observedMaximum() -> Int {
        maximumActive
    }
}

final class FeedbackArchiveOutboxTests: XCTestCase {
    func testLateUploadCallbacksTreatOnlyDurableEndStatesAsTerminal() {
        XCTAssertTrue(FeedbackDeliveryState.sent.isTerminal)
        XCTAssertTrue(FeedbackDeliveryState.cancelled.isTerminal)
        XCTAssertTrue(FeedbackDeliveryState.failed.isTerminal)

        for state in [
            FeedbackDeliveryState.queued,
            .reserving,
            .uploading,
            .completing,
            .retryScheduled,
            .cancelling,
        ] {
            XCTAssertFalse(state.isTerminal, "\(state) must remain actionable")
        }
    }

    private let stableIdentitySubjectSHA256 =
        "ec30fc0d19bfcf530cef1568030a772991e0ac96633c822987f7932b4a368bcd"

    private var signedGCSURL: URL {
        URL(
            string:
                "https://storage.googleapis.com/noop-feedback/report.zip"
                + "?X-Goog-Algorithm=GOOG4-RSA-SHA256"
                + "&X-Goog-Credential=credential"
                + "&X-Goog-Date=20260912T180000Z"
                + "&X-Goog-Expires=300"
                + "&X-Goog-SignedHeaders="
                + "content-length%3Bcontent-type%3Bhost%3Bx-goog-content-sha256"
                + "%3Bx-goog-if-generation-match%3Bx-goog-meta-noop-sha256"
                + "&X-Goog-Signature=abc123"
        )!
    }

    func testReservationRecoveryKeepsUnknownRetryableAndRetiredTerminal() {
        XCTAssertEqual(
            FeedbackReservationRecoveryHTTPPolicy.pendingStatusCodes,
            [404]
        )
        XCTAssertEqual(
            FeedbackReservationRecoveryHTTPPolicy.terminalStatusCodes,
            [410]
        )
        XCTAssertFalse(
            FeedbackReservationRecoveryHTTPPolicy.acceptedStatusCodes
                .contains(404)
        )
        XCTAssertTrue(
            FeedbackReservationRecoveryHTTPPolicy.acceptedStatusCodes
                .contains(410)
        )
    }

    private func sampleEntries(
        includeNote: Bool = false,
        includeScreenshot: Bool = false
    ) -> [FileExport.BundleEntry] {
        var entries = [
            FileExport.BundleEntry(
                name: "report.txt",
                data: Data("bounded report".utf8)
            ),
            FileExport.BundleEntry(
                name: "meta.json",
                data: Data("{\"schema\":1}".utf8)
            ),
            FileExport.BundleEntry(
                name: "app-session-current.jsonl",
                data: Data("{\"event\":\"fixed\"}\n".utf8)
            ),
        ]
        if includeNote {
            entries.append(
                FileExport.BundleEntry(
                    name: "user-note.txt",
                    data: Data("private optional context".utf8)
                )
            )
        }
        if includeScreenshot {
            entries.append(
                FileExport.BundleEntry(
                    name: "screenshot.png",
                    data: FeedbackScreenshotFixture.sanitized
                )
            )
        }
        return entries
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func testArchiveContainsOnlyReviewedEntriesAndVerifiedManifest() throws {
        let directory = temporaryDirectory("feedback-archive")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("feedback.zip")

        let package = try FeedbackArchiveBuilder.build(
            entries: sampleEntries(includeNote: true, includeScreenshot: true),
            appVersion: "9.2.1",
            destinationURL: url,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000)
        )
        XCTAssertTrue(package.manifest.includesUserNote)
        XCTAssertTrue(package.manifest.includesScreenshot)
        XCTAssertEqual(
            Set(package.manifest.entries.map(\.name)),
            Set([
                "app-session-current.jsonl",
                "meta.json",
                "report.txt",
                "screenshot.png",
                "user-note.txt",
            ])
        )
        XCTAssertNoThrow(try FeedbackArchiveBuilder.verify(package: package))

        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertEqual(
            Set(archive.filter { $0.type == .file }.map(\.path)),
            Set(package.manifest.entries.map(\.name))
                .union([FeedbackArchiveBuilder.manifestName])
        )
    }

    func testArchiveRequiresScreenshotMetadataRemovalBeforeSealing() throws {
        let directory = temporaryDirectory("feedback-screenshot-metadata")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = sampleEntries() + [
            FileExport.BundleEntry(
                name: "screenshot.png",
                data: FeedbackScreenshotFixture.rawMetadataBearing
            ),
        ]

        XCTAssertThrowsError(
            try FeedbackArchiveBuilder.build(
                entries: entries,
                appVersion: "9.2.1",
                destinationURL: directory.appendingPathComponent("feedback.zip")
            )
        ) {
            XCTAssertEqual($0 as? FeedbackArchiveError, .invalidArchive)
        }
    }

    func testArchiveRejectsUnknownTraversalDuplicateAndPrivateRawEntries() throws {
        let directory = temporaryDirectory("feedback-rejections")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidCases: [([FileExport.BundleEntry], FeedbackArchiveError)] = [
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "unexpected.txt",
                        data: Data()
                    ),
                ],
                .unknownEntry
            ),
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "../screenshot.png",
                        data: Data()
                    ),
                ],
                .invalidEntryName
            ),
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "report.txt",
                        data: Data("duplicate".utf8)
                    ),
                ],
                .duplicateEntry
            ),
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "raw-capture.jsonl",
                        data: Data("private".utf8)
                    ),
                ],
                .privateRawEntry
            ),
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "screenshot.png",
                        data: Data([0x89, 0x50, 0x4e, 0x47])
                    ),
                ],
                .invalidArchive
            ),
            (
                sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "health.sqlite",
                        data: Data("private".utf8)
                    ),
                ],
                .privateRawEntry
            ),
        ]

        for (index, value) in invalidCases.enumerated() {
            let url = directory.appendingPathComponent("invalid-\(index).zip")
            XCTAssertThrowsError(
                try FeedbackArchiveBuilder.build(
                    entries: value.0,
                    appVersion: "9.2.1",
                    destinationURL: url
                )
            ) {
                XCTAssertEqual($0 as? FeedbackArchiveError, value.1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFailedEnqueueIsAtomicAndLeavesNoPartialReport() async throws {
        let root = temporaryDirectory("feedback-atomic")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)

        do {
            _ = try await outbox.enqueue(
                entries: sampleEntries() + [
                    FileExport.BundleEntry(
                        name: "../private.db",
                        data: Data("private".utf8)
                    ),
                ],
                appVersion: "9.2.1"
            )
            XCTFail("Invalid entries must fail closed.")
        } catch {
            XCTAssertEqual(error as? FeedbackArchiveError, .invalidEntryName)
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(children.isEmpty)
    }

    func testOutboxRecoversQueuedRecordAndFrozenConsent() async throws {
        let root = temporaryDirectory("feedback-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        var source = sampleEntries(includeNote: true)
        let first = FeedbackOutbox(rootURL: root)
        let queued = try await first.enqueue(
            entries: source,
            appVersion: "9.2.1",
            now: now
        )

        source.removeAll()
        source.append(
            FileExport.BundleEntry(
                name: "screenshot.png",
                data: Data([0x89])
            )
        )

        let relaunched = FeedbackOutbox(rootURL: root)
        let recovered = try await relaunched.recover(
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(recovered, [queued])
        XCTAssertTrue(recovered[0].includesUserNote)
        XCTAssertFalse(recovered[0].includesScreenshot)
        XCTAssertEqual(recovered[0].state, .queued)
    }

    func testIdentitySubjectHashIsStableBoundedAndPrivacySafe() {
        XCTAssertEqual(
            FeedbackIdentitySubject.sha256("stable-feedback-owner"),
            stableIdentitySubjectSHA256
        )
        XCTAssertNil(FeedbackIdentitySubject.sha256(""))
        XCTAssertNil(
            FeedbackIdentitySubject.sha256(
                String(repeating: "a", count: 257)
            )
        )
        XCTAssertFalse(stableIdentitySubjectSHA256.contains("owner"))
        XCTAssertTrue(
            FeedbackProtocolValidation.validIdentitySubjectSHA256(
                stableIdentitySubjectSHA256
            )
        )
    }

    func testIdentityAuthorizationGateSerializesReentrantAsyncWork() async {
        let gate = FeedbackIdentityAuthorizationGate()
        let probe = FeedbackAuthorizationGateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await probe.leave()
                    await gate.release()
                }
            }
        }

        let observedMaximum = await probe.observedMaximum()
        XCTAssertEqual(observedMaximum, 1)
    }

    func testOutboxBindsIdentityBeforeReservationAndRejectsRotation() async throws {
        let root = temporaryDirectory("feedback-identity-binding")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )

        do {
            _ = try await outbox.storeReservation(
                id: queued.id,
                reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                reportToken: String(repeating: "a", count: 40),
                upload: nil,
                retainedUntil: nil
            )
            XCTFail("A reservation must not be stored before identity binding.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }

        let bound = try await outbox.bindIdentity(
            id: queued.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        XCTAssertEqual(
            bound.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        _ = try await outbox.bindIdentity(
            id: queued.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )

        let replacement = try XCTUnwrap(
            FeedbackIdentitySubject.sha256("replacement-feedback-owner")
        )
        do {
            _ = try await outbox.bindIdentity(
                id: queued.id,
                identitySubjectSHA256: replacement
            )
            XCTFail("A durable feedback identity must not rotate.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }

        let reserved = try await outbox.storeReservation(
            id: queued.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: nil
        )
        XCTAssertEqual(
            reserved.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertFalse(
            FeedbackIdentityContinuityPolicy
                .permitsAnonymousIdentityReplacement(reserved)
        )
        XCTAssertEqual(
            FeedbackRemoteAbsencePolicy.statusAction(
                for: reserved,
                authorizedIdentitySubjectSHA256: stableIdentitySubjectSHA256
            ),
            .retryReservation
        )
        XCTAssertEqual(
            FeedbackRemoteAbsencePolicy.cancellationAction(
                for: reserved,
                authorizedIdentitySubjectSHA256: stableIdentitySubjectSHA256
            ),
            .confirmDeletion
        )
        XCTAssertEqual(
            FeedbackRemoteAbsencePolicy.cancellationAction(
                for: reserved,
                authorizedIdentitySubjectSHA256: replacement
            ),
            .rejectIdentity,
            "A principal-mismatch 404 must not prove remote deletion."
        )
    }

    func testLegacyLocalRecordMigratesOnFirstIdentityBinding() async throws {
        let root = temporaryDirectory("feedback-legacy-local")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        let stateURL = root
            .appendingPathComponent(queued.id.uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        state.removeValue(forKey: "identity_subject_sha256")
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)

        let relaunched = FeedbackOutbox(rootURL: root)
        let recoveredRecords = try await relaunched.recover()
        let recovered = try XCTUnwrap(recoveredRecords.first)
        XCTAssertNil(recovered.identitySubjectSHA256)
        XCTAssertTrue(
            FeedbackIdentityContinuityPolicy.canContactRemote(recovered)
        )

        _ = try await relaunched.bindIdentity(
            id: recovered.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            migrated["identity_subject_sha256"] as? String,
            stableIdentitySubjectSHA256
        )
    }

    func testAnonymousIdentityLifetimePolicyRequiresFullRetentionCoverage() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let maximumAge =
            FeedbackAnonymousIdentityLifetimePolicy
                .maximumExistingIdentityAge
        XCTAssertEqual(maximumAge, 22 * 60 * 60 + 55 * 60)

        XCTAssertEqual(
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAt:
                    now.addingTimeInterval(-maximumAge),
                now: now,
                hasActiveBoundReports: true
            ),
            .reuse
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAt:
                    now.addingTimeInterval(-maximumAge - 1),
                now: now,
                hasActiveBoundReports: false
            ),
            .replace
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAt:
                    now.addingTimeInterval(-maximumAge - 1),
                now: now,
                hasActiveBoundReports: true
            ),
            .deferReservation
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAt: nil,
                now: now,
                hasActiveBoundReports: false
            ),
            .replace
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
                identityCreatedAt: now.addingTimeInterval(1),
                now: now,
                hasActiveBoundReports: true
            ),
            .deferReservation
        )
    }

    func testPreviousStateAddsReservationContinuityStartWithoutLosingBinding()
        async throws {
        let root = temporaryDirectory("feedback-continuity-start-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(1)
        )
        let stateURL = root
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        state.removeValue(forKey: "reservation_continuity_started_at")
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)

        let relaunched = FeedbackOutbox(rootURL: root)
        let records = try await relaunched.records(
            now: created.addingTimeInterval(2)
        )
        let migrated = try XCTUnwrap(records.first)

        XCTAssertEqual(
            migrated.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertEqual(
            migrated.reservationContinuityStartedAt,
            created
        )
    }

    func testProviderPolicyPreservesAmbiguousBindingAndDefersNewReport()
        throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let oldCreation = now.addingTimeInterval(
            -FeedbackAnonymousIdentityLifetimePolicy
                .maximumExistingIdentityAge
            - 1
        )
        let unrelatedIdentity = try XCTUnwrap(
            FeedbackIdentitySubject.sha256("unrelated-feedback-owner")
        )

        XCTAssertEqual(
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime: false,
                identityCreatedAt: oldCreation,
                now: now,
                identitySubjectSHA256: stableIdentitySubjectSHA256,
                reservationContinuityIdentitySubjectSHA256s: [
                    stableIdentitySubjectSHA256
                ]
            ),
            .reuse,
            "An already-bound ambiguous reservation must keep its exact identity."
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime: true,
                identityCreatedAt: oldCreation,
                now: now,
                identitySubjectSHA256: stableIdentitySubjectSHA256,
                reservationContinuityIdentitySubjectSHA256s: [
                    stableIdentitySubjectSHA256
                ]
            ),
            .deferReservation
        )
        XCTAssertFalse(
            FeedbackAnonymousIdentityProviderPolicy
                .permitsStaleIdentityReplacement(
                    identitySubjectSHA256: stableIdentitySubjectSHA256,
                    reservationContinuityIdentitySubjectSHA256s: [
                        stableIdentitySubjectSHA256
                    ]
                )
        )
        XCTAssertEqual(
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime: true,
                identityCreatedAt: oldCreation,
                now: now,
                identitySubjectSHA256: stableIdentitySubjectSHA256,
                reservationContinuityIdentitySubjectSHA256s: [
                    unrelatedIdentity
                ]
            ),
            .replace
        )
        XCTAssertTrue(
            FeedbackAnonymousIdentityProviderPolicy
                .permitsStaleIdentityReplacement(
                    identitySubjectSHA256: stableIdentitySubjectSHA256,
                    reservationContinuityIdentitySubjectSHA256s: [
                        unrelatedIdentity
                    ]
                )
        )
    }

    func testCoordinatorTracksReservationContinuityBindings() async throws {
        let root = temporaryDirectory("feedback-identity-coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let active = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        let bound = try await outbox.bindIdentity(
            id: active.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy
                .requiresIdentityLifetimeCheck(bound)
        )
        XCTAssertTrue(
            FeedbackIdentityContinuityPolicy.accepts(
                identitySubjectSHA256: stableIdentitySubjectSHA256,
                for: bound
            )
        )

        let terminalIdentity = try XCTUnwrap(
            FeedbackIdentitySubject.sha256("terminal-feedback-owner")
        )
        let terminal = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy
                .requiresIdentityLifetimeCheck(terminal)
        )
        _ = try await outbox.bindIdentity(
            id: terminal.id,
            identitySubjectSHA256: terminalIdentity
        )
        _ = try await outbox.storeReservation(
            id: terminal.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: Date(timeIntervalSince1970: 1_791_419_200)
        )
        _ = try await outbox.markSent(
            id: terminal.id,
            receipt: "NF-ABCDEFGHIJKLMNOP",
            retainedUntil: Date(timeIntervalSince1970: 1_791_419_200)
        )

        let continuitySubjects = try await outbox
            .reservationContinuityIdentitySubjectSHA256s()
        XCTAssertEqual(
            continuitySubjects,
            [stableIdentitySubjectSHA256]
        )
    }

    func testReservationContinuityDeadlineIsBoundedAndUsesServerRetention()
        async throws {
        let root = temporaryDirectory("feedback-continuity-deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(2)
        )
        let retainedUntil = created.addingTimeInterval(2 * 24 * 60 * 60)
        let bound = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: retainedUntil,
            now: created.addingTimeInterval(3)
        )
        let serverBoundDeadline = retainedUntil.addingTimeInterval(
            FeedbackReservationContinuityPolicy.expirySafetyMargin
        )

        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.continuityDeadline(for: bound),
            serverBoundDeadline
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy
                .identitySubjectSHA256sRequiringContinuity(
                    in: [bound],
                    now: serverBoundDeadline.addingTimeInterval(-1)
                ),
            [stableIdentitySubjectSHA256]
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy
                .identitySubjectSHA256sRequiringContinuity(
                    in: [bound],
                    now: serverBoundDeadline
                ),
            [stableIdentitySubjectSHA256],
            "An unconfirmed remote deletion must keep the original identity pinned."
        )

        var lateServerBound = bound
        lateServerBound.retainedUntil = created.addingTimeInterval(
            90 * 24 * 60 * 60
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.continuityDeadline(
                for: lateServerBound
            ),
            FeedbackReservationContinuityPolicy
                .maximumServerRetainedUntil(for: lateServerBound)
                .addingTimeInterval(
                FeedbackReservationContinuityPolicy.expirySafetyMargin
            )
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                try XCTUnwrap(lateServerBound.retainedUntil),
                for: lateServerBound,
                now: created
            )
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                retainedUntil,
                for: bound,
                now: created
            )
        )

        var ambiguous = bound
        ambiguous.reportID = nil
        ambiguous.reportToken = nil
        ambiguous.retainedUntil = nil
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.continuityDeadline(
                for: ambiguous
            ),
            created.addingTimeInterval(2).addingTimeInterval(
                FeedbackReservationContinuityPolicy
                .maximumAmbiguousBindingLifetime
            )
        )
        let reservationCutoff = created.addingTimeInterval(
            FeedbackReservationContinuityPolicy
                .maximumLocalDelayBeforeCancellation
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                ambiguous,
                now: reservationCutoff.addingTimeInterval(-1)
            )
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                ambiguous,
                now: reservationCutoff
            )
        )
        var futureUpdated = ambiguous
        futureUpdated.updatedAt = created.addingTimeInterval(
            FeedbackReservationContinuityPolicy.maximumClockSkew + 1
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                futureUpdated,
                now: created
            )
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                futureUpdated,
                now: created
            )
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                futureUpdated,
                now: futureUpdated.updatedAt.addingTimeInterval(
                    -FeedbackReservationContinuityPolicy.maximumClockSkew
                )
            )
        )
    }

    func testFutureClockAnomalyRequiresBoundedRemoteCancellation()
        async throws {
        let root = temporaryDirectory("feedback-future-clock-anomaly")
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let future = observedAt.addingTimeInterval(365 * 24 * 60 * 60)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: future
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: future.addingTimeInterval(1)
        )
        _ = try await outbox.markReserving(
            id: source.id,
            now: future.addingTimeInterval(2)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: future.addingTimeInterval(3)
        )

        let recovered = try await outbox.recover(now: observedAt)
        let cancelling = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertTrue(cancelling.cancelRequested)
        XCTAssertEqual(cancelling.clockAnomalyObservedAt, observedAt)
        XCTAssertEqual(cancelling.updatedAt, observedAt)
        XCTAssertEqual(cancelling.nextRetryAt, observedAt)
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.permitsNewReservation(
                cancelling,
                now: observedAt
            )
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                cancelling,
                now: observedAt
            )
        )
        let deadline = observedAt.addingTimeInterval(
            FeedbackReservationContinuityPolicy
                .maximumAmbiguousBindingLifetime
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.continuityDeadline(
                for: cancelling
            ),
            deadline
        )

        let expired = try await outbox.recover(now: deadline)
        let unconfirmed = try XCTUnwrap(expired.first)
        XCTAssertEqual(unconfirmed.state, .failed)
        XCTAssertEqual(unconfirmed.failureKind, .capabilityExpired)
        XCTAssertTrue(unconfirmed.cancelRequested)
        XCTAssertEqual(
            unconfirmed.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertTrue(unconfirmed.localArchiveIsRemoved)
        XCTAssertEqual(unconfirmed.clockAnomalyObservedAt, observedAt)
    }

    func testFutureClockAnomalyRemovesNeverAttemptedLocalReport()
        async throws {
        let root = temporaryDirectory("feedback-future-local-clock-anomaly")
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let future = observedAt.addingTimeInterval(365 * 24 * 60 * 60)
        let outbox = FeedbackOutbox(rootURL: root)
        _ = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: future
        )

        let recovered = try await outbox.recover(now: observedAt)
        XCTAssertTrue(recovered.isEmpty)
    }

    func testSecondMaterialClockRollbackPreservesRemoteDeletionContinuity()
        async throws {
        let root = temporaryDirectory("feedback-second-clock-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let observedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let future = observedAt.addingTimeInterval(365 * 24 * 60 * 60)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: future
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: future.addingTimeInterval(1)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: future.addingTimeInterval(2)
        )
        _ = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: nil,
            now: future.addingTimeInterval(3)
        )

        let recovered = try await outbox.recover(now: observedAt)
        let cancelling = try XCTUnwrap(recovered.first)
        XCTAssertEqual(cancelling.state, .cancelling)
        let rolledBack = observedAt.addingTimeInterval(
            -FeedbackReservationContinuityPolicy.maximumClockSkew - 1
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.hasSecondaryClockRollback(
                cancelling,
                now: rolledBack
            )
        )

        let rolledBackRecords = try await outbox.recover(now: rolledBack)
        let preserved = try XCTUnwrap(rolledBackRecords.first)
        XCTAssertEqual(preserved.state, .cancelling)
        XCTAssertTrue(preserved.cancelRequested)
        XCTAssertEqual(
            preserved.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertEqual(
            preserved.reportID,
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(preserved.reportToken, String(repeating: "a", count: 40))
        XCTAssertTrue(preserved.localArchiveIsRemoved)
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.requiresContinuity(
                preserved,
                now: rolledBack
            )
        )
        XCTAssertFalse(
            FeedbackReservationContinuityPolicy.hasExpired(
                preserved,
                now: rolledBack
            )
        )
        XCTAssertEqual(preserved.clockAnomalyObservedAt, rolledBack)
        XCTAssertEqual(preserved.nextRetryAt, rolledBack)
        XCTAssertFalse(
            FeedbackRetryWakePolicy.shouldWait(
                preserved,
                now: rolledBack
            )
        )

        let recoveredForward = rolledBack.addingTimeInterval(
            FeedbackReservationContinuityPolicy.maximumClockSkew + 10
        )
        let forward = try await outbox.markCancellationPending(
            id: source.id,
            nextRetryAt: recoveredForward.addingTimeInterval(60),
            now: recoveredForward
        )
        XCTAssertEqual(forward.clockAnomalyObservedAt, rolledBack)
        XCTAssertEqual(forward.updatedAt, recoveredForward)

        let laterRollback = recoveredForward.addingTimeInterval(
            -FeedbackReservationContinuityPolicy.maximumClockSkew - 1
        )
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.hasSecondaryClockRollback(
                forward,
                now: laterRollback
            )
        )
        let normalizedRecords = try await outbox.recover(now: laterRollback)
        let normalizedAgain = try XCTUnwrap(normalizedRecords.first)
        XCTAssertEqual(normalizedAgain.clockAnomalyObservedAt, laterRollback)
        XCTAssertEqual(normalizedAgain.nextRetryAt, laterRollback)
    }

    func testReservationContinuityWaitDoesNotConsumeAutomaticAttempts()
        async throws {
        let root = temporaryDirectory("feedback-continuity-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )

        for index in 1...12 {
            _ = try await outbox.beginAutomaticAttempt(
                id: source.id,
                now: created.addingTimeInterval(Double(index * 2))
            )
            _ = try await outbox.markReserving(
                id: source.id,
                now: created.addingTimeInterval(Double(index * 2 + 1))
            )
            let waiting = try await outbox.markReservationContinuityWaiting(
                id: source.id,
                lane: .delivery,
                now: created.addingTimeInterval(Double(index * 2 + 1))
            )
            XCTAssertEqual(waiting.state, .retryScheduled)
            XCTAssertEqual(waiting.failureKind, .identity)
            XCTAssertEqual(waiting.attemptCount, 0)
            XCTAssertEqual(
                waiting.nextRetryAt,
                created.addingTimeInterval(Double(index * 2 + 2))
            )
        }
    }

    func testReservationContinuityWaitDoesNotConsumeCancellationAttempts()
        async throws {
        let root = temporaryDirectory("feedback-cancel-continuity-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(2)
        )

        for index in 1...12 {
            _ = try await outbox.beginCancellationAttempt(
                id: source.id,
                now: created.addingTimeInterval(Double(index * 2 + 1))
            )
            _ = try await outbox.markReserving(
                id: source.id,
                now: created.addingTimeInterval(Double(index * 2 + 2))
            )
            let waiting = try await outbox.markReservationContinuityWaiting(
                id: source.id,
                lane: .cancellation,
                now: created.addingTimeInterval(Double(index * 2 + 2))
            )
            XCTAssertEqual(waiting.state, .cancelling)
            XCTAssertTrue(waiting.cancelRequested)
            XCTAssertEqual(waiting.attemptCount, 1)
            XCTAssertEqual(waiting.cancellationAttempts, 0)
            XCTAssertEqual(
                waiting.nextRetryAt,
                created.addingTimeInterval(Double(index * 2 + 3))
            )
        }
    }

    func testBoundReservationContinuityWaitPreservesDeliveryAttemptBudget()
        async throws {
        let root = temporaryDirectory("feedback-bound-continuity-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(2)
        )
        _ = try await outbox.markReserving(
            id: source.id,
            now: created.addingTimeInterval(3)
        )

        let waiting = try await outbox.markReservationContinuityWaiting(
            id: source.id,
            lane: .delivery,
            allowBoundIdentity: true,
            failureKind: .reservationUnavailable,
            now: created.addingTimeInterval(4)
        )

        XCTAssertEqual(waiting.state, .retryScheduled)
        XCTAssertEqual(waiting.attemptCount, 0)
        XCTAssertEqual(waiting.failureKind, .reservationUnavailable)
        XCTAssertEqual(
            waiting.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertFalse(waiting.hasRemoteBinding)
    }

    func testBoundReservationContinuityWaitPreservesCancellationAttemptBudget()
        async throws {
        let root = temporaryDirectory("feedback-bound-cancel-continuity-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(2)
        )
        _ = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(3)
        )
        _ = try await outbox.beginCancellationAttempt(
            id: source.id,
            now: created.addingTimeInterval(4)
        )
        _ = try await outbox.markReserving(
            id: source.id,
            now: created.addingTimeInterval(5)
        )

        let waiting = try await outbox.markReservationContinuityWaiting(
            id: source.id,
            lane: .cancellation,
            allowBoundIdentity: true,
            failureKind: .cancellationUnavailable,
            now: created.addingTimeInterval(6)
        )

        XCTAssertEqual(waiting.state, .cancelling)
        XCTAssertEqual(waiting.cancellationAttempts, 0)
        XCTAssertEqual(waiting.failureKind, .cancellationUnavailable)
        XCTAssertEqual(
            waiting.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertFalse(waiting.hasRemoteBinding)
    }

    func testDeliveryContinuityWaitRefundsDeliveryAttemptWhenCancellationRaces()
        async throws {
        let root = temporaryDirectory("feedback-delivery-cancel-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.markReserving(
            id: source.id,
            now: created.addingTimeInterval(2)
        )
        _ = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(3)
        )

        let waiting = try await outbox.markReservationContinuityWaiting(
            id: source.id,
            lane: .delivery,
            now: created.addingTimeInterval(4)
        )
        XCTAssertEqual(waiting.state, .cancelling)
        XCTAssertTrue(waiting.cancelRequested)
        XCTAssertEqual(waiting.attemptCount, 0)
        XCTAssertEqual(waiting.cancellationAttempts, 0)
        XCTAssertFalse(waiting.hasRemoteBinding)

        let cancelled = try await outbox.markCancelled(
            id: source.id,
            now: created.addingTimeInterval(5)
        )
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(cancelled.cancelRequested)
        XCTAssertEqual(cancelled.attemptCount, 0)
        XCTAssertFalse(cancelled.hasRemoteBinding)
    }

    func testExpiredContinuityPreservesUnconfirmedDeletionCapability()
        async throws {
        let root = temporaryDirectory("feedback-continuity-expiry")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let limits = FeedbackOutboxLimits(
            maximumReports: 1,
            maximumTerminalReports: 1,
            maximumArchiveBytes: 4 * 1024 * 1024,
            maximumTotalArchiveBytes: 4 * 1024 * 1024,
            retention: FeedbackOutboxLimits.production.retention,
            terminalRetention: 24 * 60 * 60
        )
        let outbox = FeedbackOutbox(rootURL: root, limits: limits)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(2)
        )
        _ = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(3)
        )
        _ = try await outbox.markFailed(
            id: source.id,
            failureKind: .retryLimit,
            now: created.addingTimeInterval(4)
        )
        let bindingAt = created.addingTimeInterval(2)
        let deadline = bindingAt.addingTimeInterval(
            FeedbackReservationContinuityPolicy
                .maximumAmbiguousBindingLifetime
        )

        let expiredRecords = try await outbox.records(now: deadline)
        let expired = try XCTUnwrap(expiredRecords.first)
        XCTAssertEqual(expired.state, .failed)
        XCTAssertEqual(expired.failureKind, .capabilityExpired)
        XCTAssertTrue(expired.cancelRequested)
        XCTAssertNil(expired.reportID)
        XCTAssertNil(expired.reportToken)
        XCTAssertEqual(
            expired.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertTrue(expired.localArchiveIsRemoved)
        let protectedIdentities =
            try await outbox.reservationContinuityIdentitySubjectSHA256s(
                now: deadline
            )
        XCTAssertEqual(
            protectedIdentities,
            [stableIdentitySubjectSHA256]
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.retryDelay(
                in: [expired],
                now: deadline
            ),
            FeedbackReservationContinuityPolicy.maximumRetryDelay
        )
        let expiredUpdatedAt = expired.updatedAt
        let recoveredAgain = try await outbox.records(
            now: deadline.addingTimeInterval(60)
        )
        XCTAssertEqual(
            try XCTUnwrap(recoveredAgain.first).updatedAt,
            expiredUpdatedAt
        )

        do {
            _ = try await outbox.enqueue(
                entries: sampleEntries(),
                appVersion: "9.2.1",
                now: deadline.addingTimeInterval(1)
            )
            XCTFail("Unconfirmed remote deletion must keep the outbox fail-closed.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .outboxFull)
        }

        let retrying = try await outbox.prepareManualRetry(
            id: source.id,
            now: deadline.addingTimeInterval(2)
        )
        XCTAssertEqual(retrying.state, .cancelling)
        XCTAssertTrue(retrying.cancelRequested)
        XCTAssertEqual(
            retrying.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        let attempted = try await outbox.beginCancellationAttempt(
            id: source.id,
            now: deadline.addingTimeInterval(3)
        )
        XCTAssertEqual(attempted.cancellationAttempts, 1)
    }

    func testActiveReservationLeaseDefersContinuityExpiryWithoutExtendingRetry()
        async throws {
        let root = temporaryDirectory("feedback-continuity-active-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        let bindingAt = created.addingTimeInterval(2)
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: bindingAt
        )
        let deadline = bindingAt.addingTimeInterval(
            FeedbackReservationContinuityPolicy
                .maximumAmbiguousBindingLifetime
        )
        _ = try await outbox.markReserving(
            id: source.id,
            now: deadline.addingTimeInterval(-1)
        )

        let leasedRecords = try await outbox.records(now: deadline)
        let leased = try XCTUnwrap(leasedRecords.first)
        XCTAssertEqual(leased.state, .reserving)
        XCTAssertTrue(
            FeedbackReservationContinuityPolicy.requiresContinuity(
                leased,
                now: deadline
            )
        )
        XCTAssertEqual(
            FeedbackReservationContinuityPolicy.retryDelay(
                in: [leased],
                now: deadline
            ),
            FeedbackReservationContinuityPolicy.activeWorkLease - 1
        )

        let expiredAt = deadline.addingTimeInterval(
            FeedbackReservationContinuityPolicy.activeWorkLease
        )
        let expiredRecords = try await outbox.records(now: expiredAt)
        let expired = try XCTUnwrap(expiredRecords.first)
        XCTAssertEqual(expired.state, .failed)
        XCTAssertEqual(expired.failureKind, .capabilityExpired)
        XCTAssertTrue(expired.cancelRequested)
        XCTAssertEqual(
            expired.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertTrue(expired.localArchiveIsRemoved)
        let cancellationRetry = try await outbox.markRetryScheduled(
            id: source.id,
            failureKind: .interrupted,
            nextRetryAt: expiredAt.addingTimeInterval(60),
            now: expiredAt
        )
        XCTAssertEqual(cancellationRetry.state, .retryScheduled)
        XCTAssertTrue(cancellationRetry.cancelRequested)
        XCTAssertEqual(
            cancellationRetry.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )

        let retryRoot = temporaryDirectory(
            "feedback-continuity-retry-no-lease"
        )
        defer { try? FileManager.default.removeItem(at: retryRoot) }
        let retryOutbox = FeedbackOutbox(rootURL: retryRoot)
        let retrySource = try await retryOutbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await retryOutbox.beginAutomaticAttempt(
            id: retrySource.id,
            now: created.addingTimeInterval(1)
        )
        _ = try await retryOutbox.bindIdentity(
            id: retrySource.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: bindingAt
        )
        _ = try await retryOutbox.markRetryScheduled(
            id: retrySource.id,
            failureKind: .interrupted,
            nextRetryAt: deadline.addingTimeInterval(60),
            now: deadline.addingTimeInterval(-1)
        )
        let retryExpiredRecords = try await retryOutbox.records(now: deadline)
        let retryExpired = try XCTUnwrap(retryExpiredRecords.first)
        XCTAssertEqual(retryExpired.state, .failed)
        XCTAssertEqual(retryExpired.failureKind, .capabilityExpired)
        XCTAssertTrue(retryExpired.cancelRequested)
        XCTAssertEqual(
            retryExpired.identitySubjectSHA256,
            stableIdentitySubjectSHA256
        )
        XCTAssertTrue(retryExpired.localArchiveIsRemoved)
    }

    func testLegacyServerBindingWithoutIdentityFailsClosedButIsPreserved() async throws {
        let root = temporaryDirectory("feedback-legacy-remote")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        _ = try await outbox.bindIdentity(
            id: queued.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        _ = try await outbox.storeReservation(
            id: queued.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: nil
        )
        let reportDirectory = root.appendingPathComponent(
            queued.id.uuidString,
            isDirectory: true
        )
        let stateURL = reportDirectory.appendingPathComponent("state.json")
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        state.removeValue(forKey: "identity_subject_sha256")
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)

        let relaunched = FeedbackOutbox(rootURL: root)
        let recoveredRecords = try await relaunched.recover()
        let recovered = try XCTUnwrap(recoveredRecords.first)
        XCTAssertNil(recovered.identitySubjectSHA256)
        XCTAssertTrue(recovered.hasRemoteBinding)
        XCTAssertFalse(
            FeedbackIdentityContinuityPolicy.canContactRemote(recovered)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: reportDirectory
                    .appendingPathComponent(queued.archiveFileName)
                    .path
            )
        )
    }

    func testOutboxBoundsDoNotEvictPendingConsent() async throws {
        let root = temporaryDirectory("feedback-bounds")
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = FeedbackOutboxLimits(
            maximumReports: 1,
            maximumTerminalReports: 1,
            maximumArchiveBytes: 4 * 1024 * 1024,
            maximumTotalArchiveBytes: 4 * 1024 * 1024,
            retention: 60,
            terminalRetention: 10
        )
        let outbox = FeedbackOutbox(rootURL: root, limits: limits)
        let first = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )

        do {
            _ = try await outbox.enqueue(
                entries: sampleEntries(),
                appVersion: "9.2.1"
            )
            XCTFail("A full outbox must reject the new report.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .outboxFull)
        }
        let remainingIDs = try await outbox.records().map(\.id)
        XCTAssertEqual(remainingIDs, [first.id])
    }

    func testOutboxExpiresServerBoundReportIntoDurableCancellation() async throws {
        let root = temporaryDirectory("feedback-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = FeedbackOutboxLimits(
            maximumReports: 3,
            maximumTerminalReports: 2,
            maximumArchiveBytes: 4 * 1024 * 1024,
            maximumTotalArchiveBytes: 8 * 1024 * 1024,
            retention: 120,
            terminalRetention: 30
        )
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root, limits: limits)
        let record = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.beginAutomaticAttempt(
            id: record.id,
            now: created.addingTimeInterval(4)
        )
        _ = try await outbox.markReserving(
            id: record.id,
            now: created.addingTimeInterval(5)
        )

        let relaunched = FeedbackOutbox(rootURL: root, limits: limits)
        let recovered = try await relaunched.recover(
            now: created.addingTimeInterval(10)
        )
        XCTAssertEqual(recovered.first?.state, .retryScheduled)
        XCTAssertEqual(recovered.first?.failureKind, .interrupted)
        XCTAssertEqual(
            recovered.first?.nextRetryAt,
            created.addingTimeInterval(10)
        )

        let expired = try await relaunched.recover(
            now: created.addingTimeInterval(121)
        )
        let cancelling = try XCTUnwrap(expired.first)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertTrue(cancelling.cancelRequested)
        XCTAssertEqual(cancelling.nextRetryAt, created.addingTimeInterval(121))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent(record.id.uuidString)
                    .appendingPathComponent(record.archiveFileName)
                    .path
            )
        )
    }

    func testOutboxExpiresNeverAttemptedReportLocally() async throws {
        let root = temporaryDirectory("feedback-local-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = FeedbackOutboxLimits(
            maximumReports: 3,
            maximumTerminalReports: 2,
            maximumArchiveBytes: 4 * 1024 * 1024,
            maximumTotalArchiveBytes: 8 * 1024 * 1024,
            retention: 120,
            terminalRetention: 30
        )
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root, limits: limits)
        _ = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )

        let expired = try await outbox.recover(
            now: created.addingTimeInterval(121)
        )
        let cancelled = try XCTUnwrap(expired.first)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(cancelled.cancelRequested)
        XCTAssertNil(cancelled.reportID)
        XCTAssertNil(cancelled.reportToken)

        let pruned = try await outbox.recover(
            now: created.addingTimeInterval(152)
        )
        XCTAssertTrue(pruned.isEmpty)
    }

    func testCompletingRecoveryStaysCompletingAndRetriesImmediately() async throws {
        let root = temporaryDirectory("feedback-completing-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let recoveryTime = created.addingTimeInterval(10)
        let outbox = FeedbackOutbox(rootURL: root)
        let record = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.markCompleting(
            id: record.id,
            now: created.addingTimeInterval(5)
        )

        let relaunched = FeedbackOutbox(rootURL: root)
        let recovered = try await relaunched.recover(now: recoveryTime)
        let completing = try XCTUnwrap(recovered.first)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(completing.id, record.id)
        XCTAssertEqual(completing.state, .completing)
        XCTAssertEqual(completing.uploadProgress, 1)
        XCTAssertEqual(completing.failureKind, .interrupted)
        XCTAssertEqual(completing.nextRetryAt, recoveryTime)
        XCTAssertEqual(completing.updatedAt, recoveryTime)
    }

    func testCancellationWinsOverReservationCompletionAndRecovery() async throws {
        let root = temporaryDirectory("feedback-terminal-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let archiveURL = root
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            .appendingPathComponent(source.archiveFileName)
        let cancelling = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertTrue(cancelling.cancelRequested)
        XCTAssertTrue(cancelling.localArchiveIsRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(1.5)
        )
        let reserved = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: created.addingTimeInterval(86_400),
            now: created.addingTimeInterval(2)
        )
        XCTAssertEqual(reserved.state, .cancelling)
        XCTAssertTrue(reserved.cancelRequested)
        XCTAssertEqual(
            FeedbackCompletionRacePolicy.action(for: reserved),
            .cancelRemote
        )

        do {
            _ = try await outbox.markSent(
                id: source.id,
                receipt: "NF-ABCDEFGHJKLMNPQR",
                retainedUntil: created.addingTimeInterval(86_400),
                now: created.addingTimeInterval(3)
            )
            XCTFail("A completion response must not overwrite cancellation.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }

        do {
            _ = try await outbox.markFailed(
                id: source.id,
                failureKind: .reportRejected,
                unlessCancellationRequested: true,
                now: created.addingTimeInterval(3)
            )
            XCTFail("A rejection response must not overwrite cancellation.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }

        _ = try await outbox.markRetryScheduled(
            id: source.id,
            failureKind: .cancellationUnavailable,
            nextRetryAt: created.addingTimeInterval(60),
            now: created.addingTimeInterval(4)
        )

        let relaunched = FeedbackOutbox(rootURL: root)
        let recoveredRecords = try await relaunched.recover(
            now: created.addingTimeInterval(5)
        )
        let recovered = try XCTUnwrap(recoveredRecords.first)
        XCTAssertEqual(recovered.state, .retryScheduled)
        XCTAssertEqual(recovered.failureKind, .cancellationUnavailable)
        XCTAssertTrue(recovered.cancelRequested)

        let retry = try await relaunched.prepareManualRetry(
            id: source.id,
            now: created.addingTimeInterval(6)
        )
        XCTAssertEqual(retry.state, .cancelling)
        XCTAssertTrue(retry.cancelRequested)

        let cancelled = try await relaunched.markCancelled(
            id: source.id,
            now: created.addingTimeInterval(7)
        )
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(cancelled.cancelRequested)
    }

    func testOneAutomaticAttemptCoversReservationUploadAndCompletionStages() async throws {
        let root = temporaryDirectory("feedback-attempt-cycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )

        let firstAttempt = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(1)
        )
        XCTAssertEqual(firstAttempt.attemptCount, 1)

        let reserving = try await outbox.markReserving(
            id: source.id,
            now: created.addingTimeInterval(2)
        )
        XCTAssertEqual(reserving.attemptCount, 1)

        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(2.5)
        )
        let reserved = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: FeedbackUploadCapability(
                method: "PUT",
                url: signedGCSURL.absoluteString,
                headers: [:],
                expiresAt: created.addingTimeInterval(300)
            ),
            retainedUntil: created.addingTimeInterval(86_400),
            now: created.addingTimeInterval(3)
        )
        XCTAssertEqual(reserved.attemptCount, 1)

        let uploading = try await outbox.markUploading(
            id: source.id,
            now: created.addingTimeInterval(4)
        )
        XCTAssertEqual(uploading.attemptCount, 1)

        let completing = try await outbox.markCompleting(
            id: source.id,
            uploadAttemptID: uploading.uploadAttemptID,
            now: created.addingTimeInterval(5)
        )
        XCTAssertEqual(completing.attemptCount, 1)

        _ = try await outbox.markCompletionRetryScheduled(
            id: source.id,
            failureKind: .completionUnavailable,
            nextRetryAt: created.addingTimeInterval(30),
            now: created.addingTimeInterval(6)
        )
        let secondAttempt = try await outbox.beginAutomaticAttempt(
            id: source.id,
            now: created.addingTimeInterval(30)
        )
        XCTAssertEqual(secondAttempt.attemptCount, 2)
    }

    func testCancellationHasIndependentRetryBudgetAfterDeliveryExhaustion() async throws {
        let root = temporaryDirectory("feedback-cancellation-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )

        for attempt in 1...FeedbackRetryPolicy.maximumAutomaticAttempts {
            let record = try await outbox.beginAutomaticAttempt(
                id: source.id,
                now: created.addingTimeInterval(Double(attempt))
            )
            XCTAssertEqual(record.attemptCount, attempt)
        }

        let cancelling = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(20)
        )
        XCTAssertEqual(cancelling.attemptCount, 8)
        XCTAssertEqual(cancelling.cancellationAttempts, 0)

        let cleanupAttempt = try await outbox.beginCancellationAttempt(
            id: source.id,
            now: created.addingTimeInterval(21)
        )
        XCTAssertEqual(cleanupAttempt.attemptCount, 8)
        XCTAssertEqual(cleanupAttempt.cancellationAttempts, 1)

        let repeated = try await outbox.requestCancellation(
            id: source.id,
            now: created.addingTimeInterval(22)
        )
        XCTAssertEqual(repeated.cancellationAttempts, 1)
    }

    func testUploadResumePolicyRejectsCancellationAfterUploadingTransition() async throws {
        let root = temporaryDirectory("feedback-upload-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        _ = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: nil
        )
        let uploading = try await outbox.markUploading(id: source.id)
        XCTAssertTrue(FeedbackUploadStartPolicy.permitsResume(uploading))

        let cancelling = try await outbox.requestCancellation(id: source.id)
        XCTAssertFalse(FeedbackUploadStartPolicy.permitsResume(cancelling))
        XCTAssertTrue(cancelling.localArchiveIsRemoved)
    }

    func testUploadTaskContextRoundTripsAndRejectsLegacyDescription() throws {
        let context = FeedbackUploadTaskContext(
            reportID: UUID(),
            attemptID: UUID()
        )

        XCTAssertEqual(
            FeedbackUploadTaskContext(
                taskDescription: context.taskDescription
            ),
            context
        )
        XCTAssertNil(
            FeedbackUploadTaskContext(
                taskDescription: context.reportID.uuidString
            ),
            "A report-only legacy task must never be adopted as a current attempt."
        )
        XCTAssertNil(
            FeedbackUploadTaskContext(
                taskDescription: "noop-feedback-upload-v1|bad|bad"
            )
        )
    }

    func testStaleUploadAttemptCannotMutateManualRetry() async throws {
        let root = temporaryDirectory("feedback-stale-upload-attempt")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let firstAttemptID = UUID()
        _ = try await outbox.markUploading(
            id: source.id,
            attemptID: firstAttemptID,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.markFailed(
            id: source.id,
            failureKind: .uploadUnavailable,
            now: created.addingTimeInterval(2)
        )
        _ = try await outbox.prepareManualRetry(
            id: source.id,
            now: created.addingTimeInterval(3)
        )

        let secondAttemptID = UUID()
        let secondAttempt = try await outbox.markUploading(
            id: source.id,
            attemptID: secondAttemptID,
            now: created.addingTimeInterval(4)
        )
        XCTAssertEqual(secondAttempt.uploadAttemptID, secondAttemptID)

        do {
            _ = try await outbox.updateProgress(
                id: source.id,
                attemptID: firstAttemptID,
                fraction: 0.75,
                now: created.addingTimeInterval(5)
            )
            XCTFail("A stale progress callback must be rejected.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }
        do {
            _ = try await outbox.markCompleting(
                id: source.id,
                uploadAttemptID: firstAttemptID,
                now: created.addingTimeInterval(6)
            )
            XCTFail("A stale completion callback must be rejected.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }

        let persisted = try await outbox.record(
            id: source.id,
            now: created.addingTimeInterval(7)
        )
        let unchanged = try XCTUnwrap(persisted)
        XCTAssertEqual(unchanged.state, .uploading)
        XCTAssertEqual(unchanged.uploadAttemptID, secondAttemptID)
        XCTAssertEqual(unchanged.uploadProgress, 0)

        let progressed = try await outbox.updateProgress(
            id: source.id,
            attemptID: secondAttemptID,
            fraction: 0.5,
            now: created.addingTimeInterval(8)
        )
        XCTAssertEqual(progressed.uploadProgress, 0.5)
        let completing = try await outbox.markCompleting(
            id: source.id,
            uploadAttemptID: secondAttemptID,
            now: created.addingTimeInterval(9)
        )
        XCTAssertEqual(completing.state, .completing)
        XCTAssertNil(completing.uploadAttemptID)
    }

    func testCancellationPersistsArchiveCleanupFailureAndRecoveryRetries() async throws {
        let root = temporaryDirectory("feedback-cancel-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let fileManager = OneShotArchiveRemovalFailureFileManager()
        let outbox = FeedbackOutbox(
            rootURL: root,
            fileManager: fileManager
        )
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let archiveURL = root
            .appendingPathComponent(queued.id.uuidString, isDirectory: true)
            .appendingPathComponent(queued.archiveFileName)

        let cancelling = try await outbox.requestCancellation(
            id: queued.id,
            now: created.addingTimeInterval(1)
        )

        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertTrue(cancelling.cancelRequested)
        XCTAssertFalse(cancelling.localArchiveIsRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(fileManager.removalAttemptCount(), 1)

        let relaunched = FeedbackOutbox(
            rootURL: root,
            fileManager: fileManager
        )
        let recovered = try await relaunched.recover(
            now: created.addingTimeInterval(2)
        )
        let recoveredCancellation = try XCTUnwrap(recovered.first)

        XCTAssertEqual(recoveredCancellation.state, .cancelling)
        XCTAssertTrue(recoveredCancellation.cancelRequested)
        XCTAssertTrue(recoveredCancellation.localArchiveIsRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(fileManager.removalAttemptCount(), 2)
    }

    func testDeletingRemainsActionableUntilServerConfirmsDeletion() async throws {
        let root = temporaryDirectory("feedback-deleting-pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let archiveURL = root
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            .appendingPathComponent(source.archiveFileName)
        let token = String(repeating: "b", count: 40)
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(0.5)
        )
        _ = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: token,
            upload: nil,
            retainedUntil: created.addingTimeInterval(86_400),
            now: created.addingTimeInterval(1)
        )

        let retryAt = created.addingTimeInterval(60)
        let deleting = try await outbox.markCancellationPending(
            id: source.id,
            nextRetryAt: retryAt,
            now: created.addingTimeInterval(2)
        )

        XCTAssertEqual(deleting.state, .cancelling)
        XCTAssertTrue(deleting.cancelRequested)
        XCTAssertEqual(deleting.reportToken, token)
        XCTAssertEqual(deleting.nextRetryAt, retryAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        let actionable = try await outbox.latestActionable(
            now: created.addingTimeInterval(3)
        )
        XCTAssertEqual(actionable?.id, source.id)

        let cancelled = try await outbox.markCancelled(
            id: source.id,
            now: created.addingTimeInterval(61)
        )
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.reportToken)
        XCTAssertFalse(cancelled.cancelRequested)
    }

    func testLatestActionableExcludesTerminalRecordsAndBoundsReceipts() async throws {
        let root = temporaryDirectory("feedback-latest-actionable")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)

        for offset in 0..<3 {
            let record = try await outbox.enqueue(
                entries: sampleEntries(),
                appVersion: "9.2.1",
                now: created.addingTimeInterval(Double(offset * 2))
            )
            _ = try await outbox.markSent(
                id: record.id,
                receipt: "NF-ABCDEFGHJKLMNPQR",
                retainedUntil: created.addingTimeInterval(86_400),
                now: created.addingTimeInterval(Double(offset * 2 + 1))
            )
        }

        let latest = try await outbox.latestActionable(
            now: created.addingTimeInterval(10)
        )
        XCTAssertNil(latest)
        let retained = try await outbox.records(
            now: created.addingTimeInterval(10)
        )
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.allSatisfy { $0.state == .sent })
    }

    func testCorruptRecordDoesNotBlockValidRecordRecovery() async throws {
        let root = temporaryDirectory("feedback-isolated-corruption")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let valid = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let corrupt = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created.addingTimeInterval(1)
        )
        let corruptDirectory = root.appendingPathComponent(
            corrupt.id.uuidString,
            isDirectory: true
        )
        try Data("{not-json".utf8).write(
            to: corruptDirectory.appendingPathComponent("state.json"),
            options: .atomic
        )

        let relaunched = FeedbackOutbox(rootURL: root)
        let recovered = try await relaunched.recover(
            now: created.addingTimeInterval(10)
        )

        XCTAssertEqual(recovered.map(\.id), [valid.id])
        XCTAssertEqual(recovered.first?.state, .queued)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: corruptDirectory.path)
        )
        _ = try await relaunched.verifiedArchiveURL(id: valid.id)
    }

    func testTerminalRecoveryRetriesArchiveDeletionWithoutRevertingState() async throws {
        let root = temporaryDirectory("feedback-terminal-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let fileManager = OneShotArchiveRemovalFailureFileManager()
        let outbox = FeedbackOutbox(
            rootURL: root,
            fileManager: fileManager
        )
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        let terminal = try await outbox.markSent(
            id: queued.id,
            receipt: "NF-ABCDEFGHJKLMNPQR",
            retainedUntil: created.addingTimeInterval(86_400),
            now: created.addingTimeInterval(1)
        )
        let archiveURL = root
            .appendingPathComponent(queued.id.uuidString, isDirectory: true)
            .appendingPathComponent(queued.archiveFileName)

        XCTAssertEqual(terminal.state, .sent)
        XCTAssertFalse(terminal.cancelRequested)
        XCTAssertFalse(terminal.localArchiveIsRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(fileManager.removalAttemptCount(), 1)

        let relaunched = FeedbackOutbox(
            rootURL: root,
            fileManager: fileManager
        )
        let recovered = try await relaunched.recover(
            now: created.addingTimeInterval(2)
        )
        let recoveredTerminal = try XCTUnwrap(recovered.first)

        XCTAssertEqual(recoveredTerminal.id, queued.id)
        XCTAssertEqual(recoveredTerminal.state, .sent)
        XCTAssertFalse(recoveredTerminal.cancelRequested)
        XCTAssertTrue(recoveredTerminal.localArchiveIsRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(fileManager.removalAttemptCount(), 2)

        let recoveredAgain = try await relaunched.recover(
            now: created.addingTimeInterval(3)
        )
        XCTAssertEqual(recoveredAgain.first?.state, .sent)
        XCTAssertEqual(fileManager.removalAttemptCount(), 2)
    }

    func testTransientStateReadFailurePreservesPendingReport() async throws {
        let root = temporaryDirectory("feedback-state-unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        let reportDirectory = root.appendingPathComponent(
            source.id.uuidString,
            isDirectory: true
        )
        let stateURL = reportDirectory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: false
        )

        let relaunched = FeedbackOutbox(rootURL: root)
        do {
            _ = try await relaunched.recover()
            XCTFail("An unreadable state file must defer the report.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .persistence)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: reportDirectory.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: reportDirectory
                    .appendingPathComponent(source.archiveFileName)
                    .path
            )
        )
    }

    func testStartupRecoveryRetriesReadFailureAndPreservesOrphanUpload() async throws {
        let root = temporaryDirectory("feedback-startup-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let outbox = FeedbackOutbox(rootURL: root)
        let source = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1",
            now: created
        )
        _ = try await outbox.bindIdentity(
            id: source.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256,
            now: created.addingTimeInterval(1)
        )
        _ = try await outbox.storeReservation(
            id: source.id,
            reportID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken: String(repeating: "a", count: 40),
            upload: nil,
            retainedUntil: created.addingTimeInterval(86_400),
            now: created.addingTimeInterval(2)
        )
        let uploading = try await outbox.markUploading(
            id: source.id,
            now: created.addingTimeInterval(3)
        )
        XCTAssertTrue(FeedbackUploadStartPolicy.permitsResume(uploading))

        let stateURL = root
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        let stateData = try Data(contentsOf: stateURL)
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: false
        )

        var gate = FeedbackStartupRecoveryGate()
        XCTAssertTrue(gate.requestStart())
        do {
            _ = try await outbox.recover(now: created.addingTimeInterval(4))
            XCTFail("Protected-data or state-read failure must defer startup.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .persistence)
            XCTAssertFalse(gate.recoveryFailed())
        }

        try FileManager.default.removeItem(at: stateURL)
        try stateData.write(to: stateURL, options: .atomic)

        XCTAssertTrue(gate.requestStart(), "Foreground/unlock must retry recovery.")
        let recovered = try await outbox.recover(
            now: created.addingTimeInterval(5)
        )
        gate.complete()

        let orphan = try XCTUnwrap(recovered.first)
        XCTAssertEqual(orphan.id, source.id)
        XCTAssertEqual(orphan.state, .uploading)
        XCTAssertTrue(FeedbackUploadStartPolicy.permitsResume(orphan))
        XCTAssertFalse(gate.requestStart(), "Successful startup remains idempotent.")
        XCTAssertEqual(
            FeedbackDiagnostics.fields(
                state: .retryScheduled,
                outcome: .deferred,
                failureKind: .interrupted
            ),
            [
                "failure_kind": "interrupted",
                "outcome": "deferred",
                "state": "retry_scheduled",
            ]
        )
    }

    func testStartupRecoveryCoalescesUnlockWhileReadIsInFlight() {
        var gate = FeedbackStartupRecoveryGate()

        XCTAssertTrue(gate.requestStart())
        XCTAssertFalse(gate.requestStart())
        XCTAssertTrue(
            gate.recoveryFailed(),
            "An unlock request arriving during recovery must trigger one retry."
        )
        XCTAssertTrue(gate.requestStart())
        gate.complete()
        XCTAssertFalse(gate.requestStart())
    }

    func testPumpGateCoalescesWorkRequestedDuringAnActiveAttempt() {
        let first = UUID()
        let second = UUID()
        var gate = FeedbackPumpGate()

        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(first))
        XCTAssertFalse(gate.begin(first))
        XCTAssertTrue(gate.begin(second))

        XCTAssertTrue(gate.finish(first))
        XCTAssertFalse(gate.finish(second))
        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.finish(first))
    }

    func testCorruptedArchiveNeverRecoversAsUploadable() async throws {
        let root = temporaryDirectory("feedback-integrity")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let record = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        let archiveURL = root
            .appendingPathComponent(record.id.uuidString)
            .appendingPathComponent(record.archiveFileName)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()

        let relaunched = FeedbackOutbox(rootURL: root)
        let recovered = try await relaunched.recover()
        XCTAssertEqual(recovered.first?.state, .failed)
        XCTAssertEqual(recovered.first?.failureKind, .archiveIntegrity)
    }

    func testReportTokenStaysOutsideImmutableArchive() async throws {
        let root = temporaryDirectory("feedback-token")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        let queued = try await outbox.enqueue(
            entries: sampleEntries(),
            appVersion: "9.2.1"
        )
        let token = "private-report-token"
        _ = try await outbox.bindIdentity(
            id: queued.id,
            identitySubjectSHA256: stableIdentitySubjectSHA256
        )
        _ = try await outbox.storeReservation(
            id: queued.id,
            reportID: "report_1",
            reportToken: token,
            upload: FeedbackUploadCapability(
                method: "PUT",
                url: "https://upload.example.invalid/signed",
                headers: ["x-upload": "signed"],
                expiresAt: Date().addingTimeInterval(300)
            ),
            retainedUntil: Date().addingTimeInterval(86_400)
        )

        let reportDirectory = root.appendingPathComponent(
            queued.id.uuidString,
            isDirectory: true
        )
        let archiveData = try Data(
            contentsOf: reportDirectory.appendingPathComponent(
                queued.archiveFileName
            )
        )
        XCTAssertFalse(String(decoding: archiveData, as: UTF8.self).contains(token))
        let state = try Data(
            contentsOf: reportDirectory.appendingPathComponent("state.json")
        )
        XCTAssertTrue(String(decoding: state, as: UTF8.self).contains(token))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: reportDirectory.appendingPathComponent("state.json").path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testFeedbackDiagnosticsExposeOnlyFixedCategories() {
        let fields = FeedbackDiagnostics.fields(
            state: .retryScheduled,
            outcome: .deferred,
            failureKind: .uploadUnavailable
        )
        XCTAssertEqual(
            Set(fields.keys),
            Set(["failure_kind", "outcome", "state"])
        )
        XCTAssertEqual(fields["state"], "retry_scheduled")
        XCTAssertEqual(fields["outcome"], "deferred")
        XCTAssertEqual(fields["failure_kind"], "upload_unavailable")
        XCTAssertFalse(fields.values.contains { $0.contains("/") })
    }

    func testBackgroundCompletionHandlerInstalledBeforeFinishRunsOnce() {
        var gate = FeedbackBackgroundCompletionGate()
        var completions = 0

        XCTAssertNil(gate.install { completions += 1 })
        let completion = gate.finishEvents()
        XCTAssertNotNil(completion)
        completion?()
        XCTAssertEqual(completions, 1)
    }

    func testBackgroundCompletionFinishBeforeHandlerIsDelivered() {
        var gate = FeedbackBackgroundCompletionGate()
        var completions = 0

        XCTAssertNil(gate.finishEvents())
        let completion = gate.install { completions += 1 }
        XCTAssertNotNil(completion)
        completion?()
        XCTAssertEqual(completions, 1)
    }

    func testProductionArchiveLimitMatchesServerBoundary() {
        let limit = FeedbackOutboxLimits.production
        let serverMaximum = Int64(20 * 1024 * 1024)

        XCTAssertEqual(limit.maximumArchiveBytes, serverMaximum)
        XCTAssertEqual(limit.maximumReports, 3)
        XCTAssertEqual(limit.maximumTerminalReports, 2)
        XCTAssertTrue(limit.permitsArchive(byteCount: serverMaximum))
        XCTAssertFalse(limit.permitsArchive(byteCount: serverMaximum + 1))
        XCTAssertFalse(limit.permitsArchive(byteCount: 0))
    }

    func testAppVersionMatchesServerContractAndInvalidValueNeverQueues() async throws {
        XCTAssertTrue(
            FeedbackProtocolValidation.validAppVersion(
                "1" + String(repeating: "a", count: 31)
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validAppVersion(
                "1" + String(repeating: "a", count: 32)
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validAppVersion("1.0 beta")
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validAppVersion("v1_+.-🙂")
        )

        let root = temporaryDirectory("feedback-app-version")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = FeedbackOutbox(rootURL: root)
        do {
            _ = try await outbox.enqueue(
                entries: sampleEntries(),
                appVersion: String(repeating: "a", count: 33)
            )
            XCTFail("An app version the server rejects must not be queued.")
        } catch {
            XCTAssertEqual(error as? FeedbackOutboxError, .invalidRecord)
        }
        let records = try await outbox.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testServerStatusReceiptAndReportIDContractsAreExact() throws {
        let decoder = JSONDecoder()
        for value in FeedbackServerStatus.allCases {
            let encoded = Data("\"\(value.rawValue)\"".utf8)
            XCTAssertEqual(
                try decoder.decode(FeedbackServerStatus.self, from: encoded),
                value
            )
        }
        for rejected in ["canceled", "cancelled", "failed", "uploading"] {
            XCTAssertThrowsError(
                try decoder.decode(
                    FeedbackServerStatus.self,
                    from: Data("\"\(rejected)\"".utf8)
                )
            )
        }

        XCTAssertTrue(
            FeedbackProtocolValidation.validReceipt(
                "NF-ABCDEFGHJKLMNPQR"
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validReceipt(
                "NF-ABCDEFGHJKLMNPQ1"
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validReceipt(
                "nf-ABCDEFGHJKLMNPQR"
            )
        )

        let id = "01234567-89AB-CDEF-0123-456789ABCDEF"
        XCTAssertEqual(
            FeedbackProtocolValidation.canonicalReportID(id),
            id.lowercased()
        )
        XCTAssertNil(
            FeedbackProtocolValidation.canonicalReportID(
                "../01234567-89ab-cdef-0123-456789abcdef"
            )
        )
    }

    func testSignedUploadIsPinnedToGCSAndExpectedHeaders() {
        let archiveBytes: Int64 = 1_024
        let archiveSHA256 = String(repeating: "a", count: 64)
        let headers = [
            "content-length": String(archiveBytes),
            "content-type": "application/zip",
            "x-goog-content-sha256": archiveSHA256,
            "x-goog-if-generation-match": "0",
            "x-goog-meta-noop-sha256": archiveSHA256,
        ]
        XCTAssertTrue(
            FeedbackProtocolValidation.validSignedUpload(
                url: signedGCSURL,
                headers: headers,
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256,
                allowsLocalHTTP: false
            )
        )
        XCTAssertTrue(
            FeedbackProtocolValidation.validSignedUploadHeaders(
                headers,
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256
            )
        )

        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadURL(
                URL(string: "https://storage.googleapis.com.evil.invalid/upload")!,
                allowsLocalHTTP: false
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadURL(
                URL(string: "https://storage.googleapis.com/upload")!,
                allowsLocalHTTP: false
            )
        )
        let local = URL(string: "http://127.0.0.1:8080/upload")!
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadURL(
                local,
                allowsLocalHTTP: false
            )
        )
        XCTAssertTrue(
            FeedbackProtocolValidation.validSignedUploadURL(
                local,
                allowsLocalHTTP: true
            )
        )

        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadHeaders(
                ["authorization": "secret"],
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadHeaders(
                ["content-length": String(archiveBytes + 1)],
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadHeaders(
                ["content-type": "application/octet-stream"],
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256
            )
        )
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUploadHeaders(
                [
                    "content-type": "application/zip",
                    "Content-Type": "application/zip",
                ],
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256
            )
        )

        for missing in [
            "content-length",
            "content-type",
            "x-goog-content-sha256",
            "x-goog-if-generation-match",
            "x-goog-meta-noop-sha256",
        ] {
            var incomplete = headers
            incomplete.removeValue(forKey: missing)
            XCTAssertFalse(
                FeedbackProtocolValidation.validSignedUploadHeaders(
                    incomplete,
                    archiveBytes: archiveBytes,
                    archiveSHA256: archiveSHA256
                ),
                "Missing \(missing) must fail closed."
            )
        }
        var wrongDigest = headers
        wrongDigest["x-goog-meta-noop-sha256"] =
            String(repeating: "b", count: 64)
        XCTAssertFalse(
            FeedbackProtocolValidation.validSignedUpload(
                url: signedGCSURL,
                headers: wrongDigest,
                archiveBytes: archiveBytes,
                archiveSHA256: archiveSHA256,
                allowsLocalHTTP: false
            )
        )
    }

    func testReportTokenMatchesServerCapabilityGrammar() {
        XCTAssertTrue(
            FeedbackProtocolValidation.validReportToken(
                String(repeating: "a", count: 43)
            )
        )
        XCTAssertTrue(
            FeedbackProtocolValidation.validReportToken(
                "v2." + String(repeating: "_", count: 43)
            )
        )
        for rejected in [
            String(repeating: "a", count: 42),
            String(repeating: "a", count: 44),
            "v." + String(repeating: "a", count: 43),
            "v12345." + String(repeating: "a", count: 43),
            "v2." + String(repeating: "a", count: 42),
            String(repeating: "a", count: 42) + "=",
            String(repeating: "a", count: 42) + "/",
            "private-report-token",
        ] {
            XCTAssertFalse(
                FeedbackProtocolValidation.validReportToken(rejected)
            )
        }
    }
}
