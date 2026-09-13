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

final class FeedbackArchiveOutboxTests: XCTestCase {
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
