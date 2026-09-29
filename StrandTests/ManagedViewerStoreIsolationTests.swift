import Foundation
import NoopRemoteSync
import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class ManagedViewerStoreIsolationTests: XCTestCase {
    private enum TestFailure: Error {
        case sourceIndex
    }

    private let localScope = String(repeating: "a", count: 64)
    private let secondScope = String(repeating: "b", count: 64)
    private let firstManagedSourceID = UUID(
        uuidString: "a5d81396-88bf-4b50-b12c-d40b65467c31"
    )!
    private let secondManagedSourceID = UUID(
        uuidString: "f65833a0-c357-4f5b-a751-c0fb0bbef63d"
    )!

    func testManagedViewerPathUsesOnlyValidatedScopeHash() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let path = try StorePaths.managedViewerDatabasePath(
            accountScopeHash: localScope.uppercased(),
            applicationSupportDirectory: root
        )

        XCTAssertEqual(
            URL(fileURLWithPath: path).standardizedFileURL,
            root
                .appendingPathComponent("OpenWhoop", isDirectory: true)
                .appendingPathComponent(
                    "ManagedViewer",
                    isDirectory: true
                )
                .appendingPathComponent(localScope, isDirectory: true)
                .appendingPathComponent("whoop.sqlite")
                .standardizedFileURL
        )
        XCTAssertThrowsError(
            try StorePaths.managedViewerDatabasePath(
                accountScopeHash: "../other-account",
                applicationSupportDirectory: root
            )
        ) { error in
            XCTAssertEqual(
                error as? StorePathError,
                .invalidManagedViewerAccountScope
            )
        }
    }

    func testRepositoryReadsManagedRestoreSourcesAndKeepsExactHandlesIsolated()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStorePathResolverForTesting { scope in
            root.appendingPathComponent(
                (scope ?? "local") + ".sqlite"
            ).path
        }

        let localStore = try await requiredStore(repository)
        try await seedLocal(
            store: localStore,
            day: "2026-09-01",
            recovery: 11
        )
        await repository.refresh()
        XCTAssertEqual(repository.days.map(\.recovery), [11])
        let initialScopeRevision = repository.storeScopeRevision

        let firstAccountStore = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        XCTAssertEqual(
            repository.managedViewerAccountScopeForTesting,
            localScope
        )
        XCTAssertEqual(
            repository.storeScopeRevision,
            initialScopeRevision + 1
        )
        XCTAssertTrue(repository.days.isEmpty)
        let firstLocalSourceID = try await seedManagedRestore(
            store: firstAccountStore,
            sourceID: firstManagedSourceID,
            day: "2026-09-02",
            recovery: 22
        )
        XCTAssertEqual(
            firstLocalSourceID,
            "noop-plus-\(firstManagedSourceID.uuidString.lowercased())"
        )
        let firstManagedRestoreSourceIDs =
            try await firstAccountStore.managedRestoreLocalSourceIDs()
        XCTAssertEqual(firstManagedRestoreSourceIDs, [firstLocalSourceID])
        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.days.map(\.recovery), [22])
        XCTAssertEqual(repository.importedReadIds, [firstLocalSourceID])
        XCTAssertTrue(repository.computedReadIds.isEmpty)
        XCTAssertEqual(repository.vitalRows.count, 1)
        XCTAssertEqual(repository.vitalRows.first?.source, .managedHistory)
        XCTAssertEqual(repository.freshness.managedDays, 1)
        XCTAssertEqual(repository.freshness.importedDays, 0)
        XCTAssertEqual(repository.freshness.computedDays, 0)

        let secondAccountStore = try await repository.activateManagedViewerStore(
            accountScopeHash: secondScope
        )
        XCTAssertEqual(
            repository.managedViewerAccountScopeForTesting,
            secondScope
        )
        XCTAssertNotEqual(
            ObjectIdentifier(firstAccountStore),
            ObjectIdentifier(secondAccountStore)
        )
        XCTAssertEqual(
            repository.storeScopeRevision,
            initialScopeRevision + 2
        )
        XCTAssertTrue(repository.days.isEmpty)
        let secondLocalSourceID = try await seedManagedRestore(
            store: secondAccountStore,
            sourceID: secondManagedSourceID,
            day: "2026-09-03",
            recovery: 33
        )
        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.days.map(\.recovery), [33])
        XCTAssertEqual(repository.importedReadIds, [secondLocalSourceID])
        XCTAssertTrue(repository.computedReadIds.isEmpty)

        // A handle captured for the first account must remain bound to that
        // account after the repository switches to a second account.
        _ = try await seedManagedRestore(
            store: firstAccountStore,
            sourceID: firstManagedSourceID,
            day: "2026-09-04",
            recovery: 24
        )
        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.days.map(\.recovery), [33])

        _ = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.days.map(\.recovery), [22, 24])

        await repository.deactivateManagedViewerStore()
        XCTAssertNil(repository.managedViewerAccountScopeForTesting)
        XCTAssertEqual(repository.days.map(\.recovery), [11])
        XCTAssertEqual(
            repository.storeScopeRevision,
            initialScopeRevision + 4
        )

        // Deactivation must not redirect a retained account handle into the
        // local store. A later write through that exact handle remains visible
        // only after the same account is mounted again.
        _ = try await seedManagedRestore(
            store: firstAccountStore,
            sourceID: firstManagedSourceID,
            day: "2026-09-05",
            recovery: 25
        )
        await repository.refresh()
        XCTAssertEqual(repository.days.map(\.recovery), [11])

        _ = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.days.map(\.recovery), [22, 24, 25])
    }

    func testManagedRefreshFailsClosedWhenSourceIndexIsUnavailable()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStorePathResolverForTesting { scope in
            root.appendingPathComponent(
                (scope ?? "local") + ".sqlite"
            ).path
        }
        _ = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        repository.setManagedViewerSourceIDsReaderForTesting { _ in
            throw TestFailure.sourceIndex
        }

        do {
            _ = try await repository.refreshManagedViewer()
            XCTFail("Expected a source-index failure")
        } catch let error as RepositoryRefreshError {
            XCTAssertEqual(error, .sourceIndexUnavailable)
        } catch {
            XCTFail("Unexpected refresh error: \(error)")
        }
        XCTAssertFalse(repository.loaded)
        XCTAssertTrue(repository.days.isEmpty)
        XCTAssertTrue(repository.vitalRows.isEmpty)
    }

    func testManagedViewerRawReadsUseRestoredSourceUnionNotCanonical()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStorePathResolverForTesting { scope in
            root.appendingPathComponent(
                (scope ?? "local") + ".sqlite"
            ).path
        }

        let store = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        let firstSource = try await seedManagedRestore(
            store: store,
            sourceID: firstManagedSourceID,
            day: "2026-09-07",
            recovery: 47
        )
        let secondSource = try await seedManagedRestore(
            store: store,
            sourceID: secondManagedSourceID,
            day: "2026-09-08",
            recovery: 48
        )
        let base = 1_800_000_000
        _ = try await store.insert(
            Streams(
                hr: [
                    HRSample(ts: base, bpm: 61),
                    HRSample(ts: base + 60, bpm: 63),
                ],
                rr: [
                    RRInterval(ts: base, rrMs: 810),
                    RRInterval(ts: base + 60, rrMs: 830),
                ],
                gravity: [
                    GravitySample(ts: base, x: 0.1, y: 0.2, z: 0.9),
                    GravitySample(
                        ts: base + 60,
                        x: 0.2,
                        y: 0.3,
                        z: 0.85
                    ),
                ]
            ),
            deviceId: firstSource
        )
        _ = try await store.insert(
            Streams(
                hr: [
                    HRSample(ts: base, bpm: 81),
                    HRSample(ts: base + 120, bpm: 72),
                ],
                rr: [
                    RRInterval(ts: base, rrMs: 810),
                    RRInterval(ts: base + 120, rrMs: 920),
                ],
                gravity: [
                    GravitySample(
                        ts: base,
                        x: 0.3,
                        y: 0.4,
                        z: 0.8
                    ),
                    GravitySample(
                        ts: base + 120,
                        x: 0.4,
                        y: 0.5,
                        z: 0.75
                    ),
                ]
            ),
            deviceId: secondSource
        )

        // A canonical row in the account database is a decoy: managed-viewer
        // reads must use only the exact source index restored for this account.
        try await store.upsertDevice(
            id: Repository.whoopSource,
            mac: nil,
            name: "Canonical decoy"
        )
        _ = try await store.insert(
            Streams(
                hr: [HRSample(ts: base + 600, bpm: 199)],
                rr: [RRInterval(ts: base + 600, rrMs: 1_999)],
                gravity: [
                    GravitySample(ts: base + 600, x: 9, y: 9, z: 9),
                ]
            ),
            deviceId: Repository.whoopSource
        )

        _ = try await repository.refreshManagedViewer()
        XCTAssertEqual(repository.deviceId, Repository.whoopSource)
        XCTAssertEqual(repository.importedReadIds, [secondSource, firstSource])

        let hr = await repository.hrSamples(
            from: base,
            to: base + 900
        )
        XCTAssertEqual(hr, [
            HRSample(ts: base, bpm: 81),
            HRSample(ts: base + 60, bpm: 63),
            HRSample(ts: base + 120, bpm: 72),
        ])
        let limitedHR = await repository.hrSamples(
            from: base,
            to: base + 900,
            limit: 2
        )
        XCTAssertEqual(limitedHR, [
            HRSample(ts: base, bpm: 81),
            HRSample(ts: base + 60, bpm: 63),
        ])

        let buckets = await repository.hrBuckets(
            from: base,
            to: base + 900,
            bucketSeconds: 300
        )
        XCTAssertEqual(
            buckets,
            [
                HRBucket(ts: base, bpm: 72),
            ]
        )

        let rr = await repository.rrIntervals(
            from: base,
            to: base + 900
        )
        XCTAssertEqual(rr, [
            RRInterval(ts: base, rrMs: 810),
            RRInterval(ts: base + 60, rrMs: 830),
            RRInterval(ts: base + 120, rrMs: 920),
        ])

        let gravity = await repository.gravitySamples(
            from: base,
            to: base + 900
        )
        XCTAssertEqual(
            gravity,
            [
                GravitySample(ts: base, x: 0.3, y: 0.4, z: 0.8),
                GravitySample(
                    ts: base + 60,
                    x: 0.2,
                    y: 0.3,
                    z: 0.85
                ),
                GravitySample(
                    ts: base + 120,
                    x: 0.4,
                    y: 0.5,
                    z: 0.75
                ),
            ]
        )
    }

    func testManagedRefreshCancellationBeforePublicationLeavesCachesUntouched()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStorePathResolverForTesting { scope in
            root.appendingPathComponent(
                (scope ?? "local") + ".sqlite"
            ).path
        }
        let store = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        _ = try await seedManagedRestore(
            store: store,
            sourceID: firstManagedSourceID,
            day: "2026-09-06",
            recovery: 46
        )
        let refreshSequence = repository.refreshSeq

        do {
            _ = try await repository.refreshManagedViewer(
                validateBeforePublication: {
                    throw CancellationError()
                }
            )
            XCTFail("Expected publication cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected refresh error: \(error)")
        }
        XCTAssertFalse(repository.loaded)
        XCTAssertTrue(repository.days.isEmpty)
        XCTAssertTrue(repository.vitalRows.isEmpty)
        XCTAssertEqual(repository.refreshSeq, refreshSequence)

        let successfulResult = try await repository.refreshManagedViewer()
        XCTAssertEqual(successfulResult, .published)
        XCTAssertEqual(repository.days.map(\.recovery), [46])
        XCTAssertEqual(repository.vitalRows.map(\.source), [.managedHistory])
    }

    func testManagedRefreshPaginatesFullSleepPage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStorePathResolverForTesting { scope in
            root.appendingPathComponent(
                (scope ?? "local") + ".sqlite"
            ).path
        }
        let store = try await repository.activateManagedViewerStore(
            accountScopeHash: localScope
        )
        let localSourceID = try await seedManagedRestore(
            store: store,
            sourceID: firstManagedSourceID,
            day: "2026-09-06",
            recovery: 46
        )
        var requestedFromValues: [Int] = []
        repository.strictSleepSessionReaderForTesting = {
            source, from, _, limit in
            XCTAssertEqual(source, localSourceID)
            XCTAssertEqual(limit, 4_000)
            requestedFromValues.append(from)
            if requestedFromValues.count == 1 {
                return (0..<limit).map { offset in
                    CachedSleepSession(
                        startTs: from + offset,
                        endTs: from + offset + 1,
                        efficiency: nil,
                        restingHr: nil,
                        avgHrv: nil,
                        stagesJSON: nil
                    )
                }
            }
            return [
                CachedSleepSession(
                    startTs: from,
                    endTs: from + 1,
                    efficiency: nil,
                    restingHr: nil,
                    avgHrv: nil,
                    stagesJSON: nil
                ),
            ]
        }

        let result = try await repository.refreshManagedViewer()

        XCTAssertEqual(result, .published)
        XCTAssertEqual(requestedFromValues.count, 2)
        XCTAssertEqual(
            requestedFromValues[1],
            requestedFromValues[0] + 4_000
        )
        XCTAssertTrue(repository.loaded)
        XCTAssertFalse(repository.sleeps.isEmpty)
    }

    func testContinuationDrainsUntilComplete() async throws {
        var remaining = [
            ManagedRestoreOnlyRunResult(
                appliedChanges: 4,
                hasMoreChanges: true
            ),
            ManagedRestoreOnlyRunResult(
                appliedChanges: 3,
                hasMoreChanges: false
            ),
        ]
        var validations = 0

        let summary = try await MacManagedHistoryContinuationRunner.run(
            initialHasMoreChanges: true,
            maxBatches: 4,
            delayNanoseconds: 0,
            validate: {
                validations += 1
            },
            restoreNext: {
                remaining.removeFirst()
            }
        )

        XCTAssertEqual(validations, 2)
        XCTAssertEqual(
            summary,
            MacManagedHistoryContinuationSummary(
                batches: 2,
                appliedChanges: 7,
                hasMoreChanges: false,
                reachedLimit: false
            )
        )
    }

    func testContinuationStopsAtBoundedLimit() async throws {
        var calls = 0
        let summary = try await MacManagedHistoryContinuationRunner.run(
            initialHasMoreChanges: true,
            maxBatches: 3,
            delayNanoseconds: 0,
            validate: {},
            restoreNext: {
                calls += 1
                return ManagedRestoreOnlyRunResult(
                    appliedChanges: 1,
                    hasMoreChanges: true
                )
            }
        )

        XCTAssertEqual(calls, 3)
        XCTAssertEqual(summary.batches, 3)
        XCTAssertEqual(summary.appliedChanges, 3)
        XCTAssertTrue(summary.hasMoreChanges)
        XCTAssertTrue(summary.reachedLimit)
    }

    func testContinuationCancellationStopsBeforeNextRestore() async {
        let validationStarted = expectation(
            description: "continuation validation started"
        )
        var restoreCalls = 0
        let task = Task {
            try await MacManagedHistoryContinuationRunner.run(
                initialHasMoreChanges: true,
                maxBatches: 4,
                delayNanoseconds: 0,
                validate: {
                    validationStarted.fulfill()
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                },
                restoreNext: {
                    restoreCalls += 1
                    return ManagedRestoreOnlyRunResult(
                        appliedChanges: 1,
                        hasMoreChanges: false
                    )
                }
            )
        }

        await fulfillment(of: [validationStarted], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to terminate the continuation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected continuation error: \(error)")
        }
        XCTAssertEqual(restoreCalls, 0)
    }

    private func requiredStore(
        _ repository: Repository
    ) async throws -> WhoopStore {
        guard let store = await repository.storeHandle() else {
            throw RepositoryReadError.storeUnavailable
        }
        return store
    }

    private func seedLocal(
        store: WhoopStore,
        day: String,
        recovery: Double
    ) async throws {
        _ = try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: day,
                    totalSleepMin: 420,
                    efficiency: 0.9,
                    deepMin: 90,
                    remMin: 100,
                    lightMin: 230,
                    disturbances: 2,
                    restingHr: 52,
                    avgHrv: 70,
                    recovery: recovery,
                    strain: 8,
                    exerciseCount: 0
                ),
            ],
            deviceId: Repository.whoopSource
        )
    }

    private func seedManagedRestore(
        store: WhoopStore,
        sourceID: UUID,
        day: String,
        recovery: Double
    ) async throws -> String {
        let eventMs = try milliseconds(forDay: day)
        let payloadData = try JSONSerialization.data(
            withJSONObject: [
                "record_type": "daily_metric",
                "total_sleep_min": 420.0,
                "efficiency": 0.9,
                "deep_min": 90.0,
                "rem_min": 100.0,
                "light_min": 230.0,
                "disturbances": 2,
                "resting_hr": 52,
                "avg_hrv": 70.0,
                "recovery": recovery,
                "strain": 8.0,
                "exercise_count": 0,
            ],
            options: [.sortedKeys]
        )
        let payload = try XCTUnwrap(
            String(data: payloadData, encoding: .utf8)
        )
        let result = try await store.applyManagedSyncChunk(
            ManagedSyncRestoreChunk(
                chunkID: UUID(),
                sourceID: sourceID,
                dataClass: "derived_summaries",
                schemaVersion: 1,
                eventStartMs: eventMs,
                eventEndMs: eventMs,
                streams: [
                    ManagedSyncTabularStream(
                        streamKey: "daily_metrics",
                        columns: [
                            "event_at_ms", "day", "source_id",
                            "payload_json", "updated_at_ms", "deleted",
                        ],
                        rows: [[
                            .integer(eventMs),
                            .string(day),
                            .string(sourceID.uuidString.lowercased()),
                            .string(payload),
                            .integer(eventMs),
                            .boolean(false),
                        ]]
                    ),
                ]
            )
        )
        let source = try await store.managedSyncSource(
            localSourceID: result.localSourceID
        )
        XCTAssertEqual(source?.sourceKind, "managed_restore")
        XCTAssertEqual(
            source?.sourceID,
            sourceID.uuidString.lowercased()
        )
        return result.localSourceID
    }

    private func milliseconds(forDay day: String) throws -> Int64 {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = try XCTUnwrap(formatter.date(from: day))
        return Int64(date.timeIntervalSince1970) * 1_000
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noop-managed-viewer-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
