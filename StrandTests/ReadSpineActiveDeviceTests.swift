import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// #814 READ SPINE + UNION MODEL: after a remove+re-add the strap gets a FRESH registry id ("whoop-<uuid>"),
/// so the Collector writes today's LIVE raw under THAT id. The read side follows the registry's active id so
/// that live data surfaces (`adoptActiveDeviceId` moves the active-strap READ id), AND it reads the UNION of
/// the active strap with the canonical "my-whoop" so history imported/computed earlier under the canonical id
/// is NOT orphaned by the move. These tests pin the contract: the active-strap id follows the re-add, the
/// re-added strap's live data surfaces, and the canonical history STILL surfaces alongside it.
final class ReadSpineActiveDeviceTests: XCTestCase {

    private let canonicalId = "my-whoop"
    private let newId = "whoop-ABC123"   // the id a re-added strap gets (AddDeviceWizard: "whoop-<uuid>")

    private func dailyMetric(day: String, recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 230,
                    disturbances: 2, restingHr: 52, avgHrv: 70, recovery: recovery, strain: 8, exerciseCount: 0,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14, steps: nil, activeKcalEst: nil)
    }

    @MainActor
    private func seedScorableNight(
        store: WhoopStore,
        deviceId: String,
        daysAgo: Int = 0
    ) async throws -> (day: String, claims: [AnalysisInputGenerationClaim]) {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let requestedDay = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -daysAgo, to: midnight)
        )
        let requestedEnd = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 7, to: requestedDay)
        )
        let endDate = daysAgo == 0 && requestedEnd > now
            ? try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: requestedEnd))
            : requestedEnd
        let end = Int(endDate.timeIntervalSince1970)
        let start = end - 7 * 3_600
        let ppg = (start..<end).map {
            PpgHrSample(ts: $0, bpm: 50, conf: 0.92)
        }
        let gravity = (start..<end).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        let rr = stride(from: start, to: end, by: 2).enumerated().map { index, ts in
            RRInterval(ts: ts, rrMs: index.isMultiple(of: 2) ? 1_195 : 1_205)
        }
        _ = try await store.insert(
            Streams(rr: rr, gravity: gravity, ppgHr: ppg),
            deviceId: deviceId
        )
        return (
            Repository.localDayKey(endDate),
            try await store.pendingAnalysisInputGenerations(deviceIds: [deviceId])
        )
    }

    /// The core regression: re-point the active-strap read id to the re-added strap, then the read deviceId
    /// equals the WRITE (Collector) id, and a latest-data lookup finds the LIVE data written under the NEW id.
    /// The lookup now unions, so the most-recent day across BOTH ids wins (the fresh today, not the stale day).
    @MainActor
    func testReadFollowsActiveIdAfterReAdd() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // Stale canonical data sits months in the past; the re-added strap's data is TODAY, under newId.
        let now = Int(Date().timeIntervalSince1970)
        let staleBase = now - 120 * 86_400
        let freshBase = now - 2 * 3_600   // a couple of hours ago (squarely "today")
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: staleBase + $0, bpm: 50) }), deviceId: canonicalId)
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: freshBase + $0, bpm: 70) }), deviceId: newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        // Seeded with the canonical id, the latest data is the stale canonical day.
        let staleLatest = await repo.latestDataDayStart()
        // Expected day = the LATEST sample's day (base + 299 for a 300-sample seed), which is what
        // latestDataDayStart (MAX ts) resolves to — NOT the seed's first sample. When a seed spans the
        // 04:00 logical-day rollover, base and base+299 land on different days, and asserting against the
        // first sample flaked in that window (only ever surfaced once app-build began running StrandTests).
        XCTAssertEqual(staleLatest, Repository.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(staleBase + 299))),
                       "before re-point the read model sees only the canonical namespace")

        // Re-add → re-point. The active-strap read id now equals the write id.
        let moved = repo.adoptActiveDeviceId(newId)
        XCTAssertTrue(moved, "adopting a different active id must move the active-strap read id")
        XCTAssertEqual(repo.deviceId, newId, "active-strap read id must equal the write (Collector) id after re-add")

        // The latest data is now TODAY's (union picks the most recent across both ids), not the stale day.
        let freshLatest = await repo.latestDataDayStart()
        XCTAssertEqual(freshLatest, Repository.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(freshBase + 299))),  // latest sample's day (MAX ts); see stale note re: 04:00 rollover straddle
                       "after re-point the auto-land reads today's live data under the new id, not the stale day")
        XCTAssertNotEqual(freshLatest, staleLatest, "Today must not snap back to the stale namespace's day")
    }

    /// UNION MODEL update: the HR facades now read the UNION of the active strap + canonical, so a re-added
    /// strap's LIVE samples AND the canonical history's samples both surface (history is NOT orphaned). Within
    /// a shared window both appear; the dedup keeps the active strap's sample on any overlapping ts.
    @MainActor
    func testHrFacadesUnionActiveAndCanonicalAfterReAdd() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // Distinct, NON-overlapping time windows: canonical history earlier, the re-added strap's live later.
        let base = 1_780_000_000
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 50) }), deviceId: canonicalId)
        try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + 10_000 + $0, bpm: 88) }), deviceId: newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(newId)

        let samples = await repo.hrSamples(from: base, to: base + 11_000)
        XCTAssertEqual(samples.count, 600, "the union must return BOTH the canonical history and the live samples")
        XCTAssertTrue(samples.contains { $0.bpm == 88 }, "the re-added strap's live samples must surface")
        XCTAssertTrue(samples.contains { $0.bpm == 50 }, "the canonical history must NOT be orphaned by the re-add")
    }

    /// Adopting an EMPTY or UNCHANGED id is a no-op (single-device install: active id stays "my-whoop"),
    /// so the default path is byte-identical to the pre-#814 behaviour (the union collapses to one id).
    @MainActor
    func testAdoptIsNoOpForEmptyOrUnchangedId() async throws {
        let repo = Repository(deviceId: canonicalId)
        XCTAssertFalse(repo.adoptActiveDeviceId(canonicalId), "same id must not move")
        XCTAssertFalse(repo.adoptActiveDeviceId(""), "empty id must not move")
        XCTAssertFalse(repo.adoptActiveDeviceId("   "), "whitespace-only id must not move")
        XCTAssertEqual(repo.deviceId, canonicalId)
    }

    /// The computed ("-noop") sibling: the union reads BOTH the active strap's computed sibling AND the
    /// canonical computed sibling, so a day scored under the canonical id before a re-add still surfaces, and
    /// a day scored under the re-added strap's sibling also surfaces.
    @MainActor
    func testComputedRowsUnionAfterReAdd() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // One computed day banked under the CANONICAL sibling (older), one under the re-added strap's sibling.
        let todayKey = Repository.localDayKey(Date())
        let yKey = Repository.localDayKey(Date().addingTimeInterval(-3 * 86_400))
        _ = try await store.upsertDailyMetrics([dailyMetric(day: yKey, recovery: 60)], deviceId: canonicalId + "-noop")
        _ = try await store.upsertDailyMetrics([dailyMetric(day: todayKey, recovery: 66)], deviceId: newId + "-noop")

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(newId)
        await repo.refresh()

        XCTAssertNotNil(repo.days.first(where: { $0.day == todayKey }),
                        "the re-added strap's computed day must surface")
        XCTAssertNotNil(repo.days.first(where: { $0.day == yKey }),
                        "the canonical computed history must NOT be orphaned by the re-add")
    }

    /// THE union-model regression (#814 follow-up): import history under the CANONICAL "my-whoop", THEN
    /// re-add a strap so the active id becomes "whoop-uuid" and write LIVE HR under it. Assert (i) the
    /// imported canonical days STILL surface in refresh(), (ii) the new live HR under the re-added id also
    /// surfaces, and (iii) Today does NOT snap to a stale day (the auto-land anchor is the fresh live day).
    @MainActor
    func testImportedHistoryUnderCanonicalSurvivesReAddWithLiveData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")

        // (1) Import history lands under the CANONICAL id (this is the STABLE import target). Three days,
        // a few days back, so they are clearly NOT today.
        let importedDays = (3...5).map { offset -> DailyMetric in
            let day = Repository.localDayKey(Date().addingTimeInterval(-Double(offset) * 86_400))
            return dailyMetric(day: day, recovery: 55 + Double(offset))
        }
        _ = try await store.upsertDailyMetrics(importedDays, deviceId: canonicalId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        await repo.refresh()
        XCTAssertEqual(repo.days.count, importedDays.count, "the canonical import is the baseline before any re-add")

        // (2) Re-add a strap: fresh registry id, active becomes "whoop-uuid". The Collector writes today's
        // LIVE raw under that id. The import target STAYS canonical (we do NOT move it).
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")
        let now = Int(Date().timeIntervalSince1970)
        let liveBase = now - 90 * 60   // 1.5h ago → today
        try await store.insert(Streams(hr: (0..<600).map { HRSample(ts: liveBase + $0, bpm: 72) }), deviceId: newId)
        repo.adoptActiveDeviceId(newId)
        await repo.refresh()

        // (i) the imported canonical days STILL surface.
        for d in importedDays {
            XCTAssertNotNil(repo.days.first(where: { $0.day == d.day }),
                            "imported canonical day \(d.day) must still surface after the re-add")
        }

        // (ii) the re-added strap's live HR surfaces under the new id.
        let liveSamples = await repo.hrSamples(from: liveBase, to: liveBase + 600)
        XCTAssertTrue(liveSamples.contains { $0.bpm == 72 }, "the re-added strap's live HR must surface")

        // (iii) Today does NOT snap to a stale day: the auto-land anchor is the fresh live day.
        let landDay = await repo.latestDataDayStart()
        XCTAssertEqual(landDay, Repository.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(liveBase + 599))),  // 600-sample seed → latest sample = liveBase+599 (MAX ts); avoids the 04:00 straddle flake
                       "Today must anchor on the fresh live day, not a stale imported day")
    }

    /// Regression for the real "slept last night, still 0/4" failure: after remove/re-add, overnight
    /// history is written under the fresh active id and a WHOOP 5/MG night may carry only PPG-derived HR.
    /// The idle dirty gate must open, the active source must own the day, and scoring must bank Sleep/RHR/HRV
    /// under the stable canonical computed id.
    @MainActor
    func testReAddedBandPpgOnlyNightAdvancesCalibration() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: newId, brand: "WHOOP", model: "WHOOP 5.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv, .sleep],
            status: .paired, addedAt: 1, lastSeenAt: 1
        ))
        try registry.setActive(newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        XCTAssertTrue(repo.adoptActiveDeviceId(newId))
        let engine = IntelligenceEngine(
            repo: repo, profile: ProfileStore(), deviceId: canonicalId)

        // A forced pass remains independent of dirty state and must still run for formula/repair callers.
        _ = await engine.analyzeRecent(maxDays: 1, force: true)

        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        let endDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 7, to: midnight))
        let end = Int(endDate.timeIntervalSince1970)
        let start = end - 7 * 3_600
        let ppg = (start..<end).map {
            PpgHrSample(ts: $0, bpm: 50, conf: 0.92)
        }
        let gravity = (start..<end).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        let rr = stride(from: start, to: end, by: 2).enumerated().map { index, ts in
            RRInterval(ts: ts, rrMs: index.isMultiple(of: 2) ? 1_195 : 1_205)
        }
        let inserted = try await store.insert(
            Streams(rr: rr, gravity: gravity, ppgHr: ppg), deviceId: newId)
        XCTAssertEqual(inserted.ppgHr, ppg.count)
        XCTAssertEqual(inserted.gravity, gravity.count)

        let receipt = await engine.analyzeRecent(maxDays: 1, force: false)
        XCTAssertNotNil(receipt, "PPG history on the active re-added source must mark analysis dirty")

        let day = Repository.localDayKey(endDate)
        let rows = try await store.dailyMetrics(
            deviceId: canonicalId + "-noop", from: day, to: day)
        let scored = try XCTUnwrap(rows.first)
        XCTAssertGreaterThan(try XCTUnwrap(scored.totalSleepMin), 0)
        XCTAssertEqual(scored.restingHr, 50)
        XCTAssertNotNil(scored.avgHrv)
        XCTAssertEqual(
            RecoveryScorer.calibrationNights(
                nightlyHrv: [scored.avgHrv], dayKeys: [scored.day],
                before: scored.day, hasRecovery: false),
            1,
            "one valid slept night must advance Recovery from 0/4 to 1/4"
        )
    }

    @MainActor
    func testOptionalRespirationReadFailurePublishesScoredNightWithoutAcknowledgingClaim() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo, profile: ProfileStore(), deviceId: canonicalId)
        let fixture = try await seedScorableNight(store: store, deviceId: canonicalId)
        XCTAssertFalse(fixture.claims.isEmpty)

        engine.setAnalysisReadFailuresForTesting([.respiration])
        let receipt = await engine.analyzeRecent(maxDays: 2, force: false)

        XCTAssertNotNil(
            receipt,
            "an optional respiration read failure must not discard valid HR/sleep scoring"
        )
        let rows = try await store.dailyMetrics(
            deviceId: canonicalId + "-noop",
            from: fixture.day,
            to: fixture.day
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(rows.first?.totalSleepMin),
            0,
            "the valid sleep result must still publish with respiration evidence omitted"
        )
        let pending = try await store.pendingAnalysisInputGenerations(deviceIds: [canonicalId])
        XCTAssertEqual(
            pending,
            fixture.claims,
            "degraded optional evidence must leave the exact claimed generation pending"
        )
    }

    @MainActor
    func testRegistrySnapshotReadFailuresPublishWithFallbackWithoutAcknowledgingClaim() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo, profile: ProfileStore(), deviceId: canonicalId)
        let fixture = try await seedScorableNight(store: store, deviceId: canonicalId)
        XCTAssertFalse(fixture.claims.isEmpty)

        engine.setAnalysisReadFailuresForTesting([.registryAll, .registryActiveDeviceId])
        let receipt = await engine.analyzeRecent(maxDays: 2, force: false)

        XCTAssertNotNil(
            receipt,
            "registry snapshot failures must retain the canonical safe fallback scoring path"
        )
        let rows = try await store.dailyMetrics(
            deviceId: canonicalId + "-noop",
            from: fixture.day,
            to: fixture.day
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(rows.first?.totalSleepMin),
            0,
            "registry fallback must still publish a valid canonical HR/sleep result"
        )
        let pending = try await store.pendingAnalysisInputGenerations(deviceIds: [canonicalId])
        XCTAssertEqual(
            pending,
            fixture.claims,
            "an incomplete registry ownership snapshot must never acknowledge source claims"
        )
    }

    func testAnalysisDirtySourcesIncludeActiveAndCanonicalButNotArchived() {
        let devices = [
            PairedDevice(
                id: newId, brand: "WHOOP", model: "WHOOP 5.0",
                sourceKind: .liveBLE, capabilities: [.hr], status: .active,
                addedAt: 1, lastSeenAt: 1
            ),
            PairedDevice(
                id: "old-band", brand: "WHOOP", model: "WHOOP 4.0",
                sourceKind: .liveBLE, capabilities: [.hr], status: .archived,
                addedAt: 0, lastSeenAt: 0
            ),
        ]

        XCTAssertEqual(
            IntelligenceEngine.analysisDirtySourceIds(
                registered: devices, readIds: [newId, canonicalId],
                fallbackDeviceId: canonicalId),
            [AnalysisInputSource.ownership, canonicalId, newId]
        )
    }

    func testAnalysisInputAcknowledgementRequiresEveryPassBoundary() {
        XCTAssertTrue(IntelligenceEngine.AnalysisPassIntegrity().canAcknowledgeInputs)

        var readFailure = IntelligenceEngine.AnalysisPassIntegrity()
        readFailure.requiredReadsSucceeded = false
        XCTAssertFalse(readFailure.canAcknowledgeInputs)

        var persistenceFailure = IntelligenceEngine.AnalysisPassIntegrity()
        persistenceFailure.requiredPersistenceSucceeded = false
        XCTAssertFalse(persistenceFailure.canAcknowledgeInputs)

        var repairFailure = IntelligenceEngine.AnalysisPassIntegrity()
        repairFailure.repairSucceeded = false
        XCTAssertFalse(repairFailure.canAcknowledgeInputs)

        var cancellation = IntelligenceEngine.AnalysisPassIntegrity()
        cancellation.cancelled = true
        XCTAssertFalse(cancellation.canAcknowledgeInputs)
    }

    func testAnalysisRunGatePreservesForcedFormulaPassAndFailsOpen() {
        let claim = AnalysisInputGenerationClaim(deviceId: canonicalId, generation: 1)

        XCTAssertTrue(IntelligenceEngine.analysisRunNeeded(
            force: true,
            generationSnapshotSucceeded: true,
            claims: []
        ), "a formula/repair upgrade must run even when no source generation is pending")
        XCTAssertFalse(IntelligenceEngine.analysisRunNeeded(
            force: false,
            generationSnapshotSucceeded: true,
            claims: []
        ))
        XCTAssertTrue(IntelligenceEngine.analysisRunNeeded(
            force: false,
            generationSnapshotSucceeded: false,
            claims: []
        ), "a failed generation snapshot must fail open into real analysis")
        XCTAssertTrue(IntelligenceEngine.analysisRunNeeded(
            force: false,
            generationSnapshotSucceeded: true,
            claims: [claim]
        ))
    }

    func testHistoricalClaimUsesBoundedAnchoredBatchForAffectedCalendarDay() {
        let now = 1_780_000_000
        let oldTs = Int64(now - 30 * 86_400)
        let historical = AnalysisInputGenerationClaim(
            deviceId: canonicalId,
            generation: 1,
            earliestAffectedTs: oldTs,
            latestAffectedTs: oldTs + 3_600
        )

        let plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays: 21,
            force: false,
            claims: [historical],
            now: now,
            timezoneOffsetSeconds: 0
        )
        let coverage = IntelligenceEngine.analysisScanCoverage(
            plan: plan,
            actualNow: now,
            timezoneOffsetSeconds: 0
        )

        XCTAssertTrue(plan.isHistoricalCatchUp)
        XCTAssertEqual(plan.maxDays, 1)
        XCTAssertEqual(
            IntelligenceEngine.midnightLocal(plan.referenceNow, offsetSec: 0),
            IntelligenceEngine.midnightLocal(Int(oldTs), offsetSec: 0)
        )
        XCTAssertTrue(coverage.covers(historical))
    }

    func testMultiYearHistoricalClaimNeverCreatesAnUnboundedPass() {
        let now = 1_780_000_000
        let latest = Int64(now - 30 * 86_400)
        let earliest = latest - 6 * 365 * 86_400
        let historical = AnalysisInputGenerationClaim(
            deviceId: canonicalId,
            generation: 1,
            earliestAffectedTs: earliest,
            latestAffectedTs: latest
        )

        let plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays: 21,
            force: false,
            claims: [historical],
            now: now,
            timezoneOffsetSeconds: 0
        )
        let coverage = IntelligenceEngine.analysisScanCoverage(
            plan: plan,
            actualNow: now,
            timezoneOffsetSeconds: 0
        )

        XCTAssertTrue(plan.isHistoricalCatchUp)
        XCTAssertEqual(plan.maxDays, 21)
        XCTAssertFalse(coverage.covers(historical))
        XCTAssertEqual(
            coverage.endTs - coverage.startTs + 1,
            Int64(21 * 86_400)
        )
    }

    func testEveryIncompleteOrCancelledAnalysisOutcomeLeavesClaimPending() async throws {
        var readFailure = IntelligenceEngine.AnalysisPassIntegrity()
        readFailure.requiredReadsSucceeded = false
        var persistenceFailure = IntelligenceEngine.AnalysisPassIntegrity()
        persistenceFailure.requiredPersistenceSucceeded = false
        var repairFailure = IntelligenceEngine.AnalysisPassIntegrity()
        repairFailure.repairSucceeded = false
        var cancellation = IntelligenceEngine.AnalysisPassIntegrity()
        cancellation.cancelled = true
        let outcomes = [
            (readFailure, "required read"),
            (persistenceFailure, "required persistence"),
            (repairFailure, "repair"),
            (cancellation, "cancellation"),
        ]

        for (index, outcome) in outcomes.enumerated() {
            let store = try await WhoopStore.inMemory()
            let source = "incomplete-\(index)"
            _ = try await store.insert(
                Streams(hr: [HRSample(ts: 100, bpm: 60)]),
                deviceId: source
            )
            let claims = try await store.pendingAnalysisInputGenerations(deviceIds: [source])
            XCTAssertEqual(claims, [
                AnalysisInputGenerationClaim(
                    deviceId: source,
                    generation: 1,
                    earliestAffectedTs: 100,
                    latestAffectedTs: 100
                ),
            ])

            try await IntelligenceEngine.finalizeAnalysisInputClaims(
                store: store,
                claims: claims,
                integrity: outcome.0,
                coverage: .init(startTs: 0, endTs: 1_000),
                consumedSourceIDs: [source],
                ownershipEvaluatedSourceIDs: []
            )

            let retried = try await store.pendingAnalysisInputGenerations(deviceIds: [source])
            XCTAssertEqual(retried, claims, "\(outcome.1) must leave the exact claim pending")
        }
    }

    func testSuccessfulPassAcknowledgesOnlyItsClaimedGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        let source = "exact-generation"
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: source
        )
        let first = try await store.pendingAnalysisInputGenerations(deviceIds: [source])

        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 101, bpm: 61)]),
            deviceId: source
        )
        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: store,
            claims: first,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [source],
            ownershipEvaluatedSourceIDs: []
        )

        let laterWrite = try await store.pendingAnalysisInputGenerations(deviceIds: [source])
        XCTAssertEqual(laterWrite, [
            AnalysisInputGenerationClaim(
                deviceId: source,
                generation: 2,
                earliestAffectedTs: 100,
                latestAffectedTs: 101
            ),
        ])
        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: store,
            claims: laterWrite,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [source],
            ownershipEvaluatedSourceIDs: []
        )
        let clean = try await store.pendingAnalysisInputGenerations(deviceIds: [source])
        XCTAssertEqual(clean, [])
    }

    @MainActor
    func testHistoricalDirtyClaimExpandsPastTwentyOneDaysAndScoresAffectedNight() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo, profile: ProfileStore(), deviceId: canonicalId)
        let fixture = try await seedScorableNight(
            store: store,
            deviceId: canonicalId,
            daysAgo: 30
        )
        XCTAssertFalse(fixture.claims.isEmpty)
        try await store.acknowledgeAnalysisInputGenerations(fixture.claims)

        let correctedTs = try XCTUnwrap(fixture.claims.first?.earliestAffectedTs)
        let correctedSecond = try XCTUnwrap(Int(exactly: correctedTs))
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: correctedSecond, bpm: 51)]),
            deviceId: canonicalId
        )
        let correctionClaims = try await store.pendingAnalysisInputGenerations(
            deviceIds: [canonicalId]
        )
        XCTAssertEqual(correctionClaims.count, 1)
        XCTAssertEqual(correctionClaims.first?.earliestAffectedTs, correctedTs)
        XCTAssertEqual(correctionClaims.first?.latestAffectedTs, correctedTs)

        let receipt = await engine.analyzeRecent(maxDays: 21, force: false)

        XCTAssertNotNil(receipt)
        let rows = try await store.dailyMetrics(
            deviceId: canonicalId + "-noop",
            from: fixture.day,
            to: fixture.day
        )
        XCTAssertFalse(
            rows.isEmpty,
            "a 30-day-old correction must expand the scoring window beyond the normal 21 days"
        )
        let pendingAfterCorrection = try await store.pendingAnalysisInputGenerations(
            deviceIds: [canonicalId]
        )
        XCTAssertEqual(
            pendingAfterCorrection,
            [],
            "the old generation may clear only after its affected night is actually scanned"
        )
    }

    func testClaimOutsideActualScanCoverageRemainsPending() async throws {
        let store = try await WhoopStore.inMemory()
        let source = "outside-scan"
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: source
        )
        let claims = try await store.pendingAnalysisInputGenerations(deviceIds: [source])

        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: store,
            claims: claims,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 101, endTs: 1_000),
            consumedSourceIDs: [source],
            ownershipEvaluatedSourceIDs: []
        )

        let pendingAfterNarrowScan = try await store.pendingAnalysisInputGenerations(
            deviceIds: [source]
        )
        XCTAssertEqual(pendingAfterNarrowScan, claims)
    }

    func testInvalidAffectedBoundsRemainPendingAfterSuccessfulPass() async throws {
        let store = try await WhoopStore.inMemory()
        let source = "invalid-bounds"
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: source
        )
        let claims = try await store.pendingAnalysisInputGenerations(deviceIds: [source])
        let pending = try XCTUnwrap(claims.first)
        let invalidClaim = AnalysisInputGenerationClaim(
            deviceId: pending.deviceId,
            generation: pending.generation,
            earliestAffectedTs: 200,
            latestAffectedTs: 100
        )
        XCTAssertNil(invalidClaim.affectedTimeRange)

        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: store,
            claims: [invalidClaim],
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [source],
            ownershipEvaluatedSourceIDs: []
        )

        let pendingAfterInvalidBounds = try await store.pendingAnalysisInputGenerations(
            deviceIds: [source]
        )
        XCTAssertEqual(pendingAfterInvalidBounds, claims)
    }

    func testInvalidOwnershipClaimAcknowledgesOnlyWhenStoreHasNoScoreBearingHistory() async throws {
        let emptyStore = try await WhoopStore.inMemory()
        try await emptyStore.seedAnalysisInputClaimForTesting(
            AnalysisInputGenerationClaim(
                deviceId: AnalysisInputSource.ownership,
                generation: 1
            )
        )
        let emptyClaim = try await emptyStore.pendingAnalysisInputGenerations(
            deviceIds: [AnalysisInputSource.ownership]
        )
        XCTAssertEqual(emptyClaim.count, 1)
        XCTAssertNil(emptyClaim.first?.affectedTimeRange)

        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: emptyStore,
            claims: emptyClaim,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [],
            ownershipEvaluatedSourceIDs: []
        )
        let emptyPending = try await emptyStore.pendingAnalysisInputGenerations(
            deviceIds: [AnalysisInputSource.ownership]
        )
        XCTAssertEqual(emptyPending, [])

        let populatedStore = try await WhoopStore.inMemory()
        _ = try await populatedStore.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: "ownership-history"
        )
        try await populatedStore.seedAnalysisInputClaimForTesting(
            AnalysisInputGenerationClaim(
                deviceId: AnalysisInputSource.ownership,
                generation: 1
            )
        )
        let populatedClaim = try await populatedStore.pendingAnalysisInputGenerations(
            deviceIds: [AnalysisInputSource.ownership]
        )

        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: populatedStore,
            claims: populatedClaim,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [],
            ownershipEvaluatedSourceIDs: []
        )
        let populatedPending = try await populatedStore.pendingAnalysisInputGenerations(
            deviceIds: [AnalysisInputSource.ownership]
        )
        XCTAssertEqual(populatedPending, populatedClaim)
    }

    func testSuccessfulPassLeavesClaimFromUnevaluatedReadSourcePending() async throws {
        let store = try await WhoopStore.inMemory()
        let selected = "registered-selected"
        let staleReadID = "unregistered-read-id"
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: selected
        )
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 61)]),
            deviceId: staleReadID
        )
        let claims = try await store.pendingAnalysisInputGenerations(
            deviceIds: [selected, staleReadID]
        )

        try await IntelligenceEngine.finalizeAnalysisInputClaims(
            store: store,
            claims: claims,
            integrity: IntelligenceEngine.AnalysisPassIntegrity(),
            coverage: .init(startTs: 0, endTs: 1_000),
            consumedSourceIDs: [selected],
            ownershipEvaluatedSourceIDs: [selected]
        )

        let pending = try await store.pendingAnalysisInputGenerations(
            deviceIds: [selected, staleReadID]
        )
        XCTAssertEqual(
            pending,
            [
                AnalysisInputGenerationClaim(
                    deviceId: staleReadID,
                    generation: 1,
                    earliestAffectedTs: 100,
                    latestAffectedTs: 100
                ),
            ]
        )
    }

    // MARK: - #316 / @63 step activity-class union (the Steps tile icon)

    /// Pure union pick: `latestActivityClass` returns the non-nil class on the greatest-ts sample across the
    /// per-id lists, resolves a ts tie in favour of the FIRST list (active strap), and passes an empty union
    /// through as nil. A nil-class sample never masks an earlier real class.
    func testLatestActivityClassUnionPickAndTieBreak() {
        // Single list reduces to "last non-nil class in that list": ts 30 is nil, so ts 20's walk (1) wins.
        let single = [[
            StepSample(ts: 10, counter: 1, activityClass: 0),
            StepSample(ts: 20, counter: 2, activityClass: 1),
            StepSample(ts: 30, counter: 3, activityClass: nil),
        ]]
        XCTAssertEqual(Repository.latestActivityClass(single), 1,
                       "the latest NON-NIL class wins; a trailing nil-class sample does not blank the icon")

        // Two lists, greatest ts across the union wins: active strap's ts=100 run (2) beats canonical ts=90.
        let active = [StepSample(ts: 100, counter: 5, activityClass: 2)]
        let canonical = [StepSample(ts: 90, counter: 4, activityClass: 0)]
        XCTAssertEqual(Repository.latestActivityClass([active, canonical]), 2,
                       "the greatest-ts classed sample across the union wins")

        // Exact ts tie: the FIRST list (active strap) wins, matching the union's active-wins rule.
        let activeTie = [StepSample(ts: 200, counter: 6, activityClass: 1)]
        let canonicalTie = [StepSample(ts: 200, counter: 7, activityClass: 0)]
        XCTAssertEqual(Repository.latestActivityClass([activeTie, canonicalTie]), 1,
                       "on a ts tie the active strap's class wins")

        // An empty union passes through as nil (no icon), never a crash.
        XCTAssertNil(Repository.latestActivityClass([[], []]), "an empty union hides the icon")
    }

    /// End-to-end #904/#908 family: a re-added strap banks its live STEP samples (carrying @63 activityClass)
    /// under its OWN fresh id, exactly like HR. A read pinned to the canonical "my-whoop" finds NO class (the
    /// tile icon vanishes); `stepActivityClassLatest` reads the union and surfaces the re-added strap's class.
    @MainActor
    func testStepActivityClassUnionSurfacesReAddedStrapClass() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: newId, mac: nil, name: "WHOOP")

        // Today's live step samples land under the re-added strap's fresh id; the latest carries class 2 (run).
        // The canonical "my-whoop" namespace has NO steps today (imports never drift to the active id).
        let base = 1_780_000_000
        let liveSteps = (0..<20).map { StepSample(ts: base + $0, counter: $0, activityClass: $0 == 19 ? 2 : 1) }
        try await store.insert(Streams(steps: liveSteps), deviceId: newId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        // Before the re-add the read model is the canonical namespace only, which has no step class today.
        let pinned = await repo.stepActivityClassLatest(from: base, to: base + 100)
        XCTAssertNil(pinned, "with only the canonical id active, a re-added strap's step class is not yet reachable")

        // Re-add → the active-strap read id follows, and the union surfaces the re-added strap's latest class.
        repo.adoptActiveDeviceId(newId)
        let surfaced = await repo.stepActivityClassLatest(from: base, to: base + 100)
        XCTAssertEqual(surfaced, 2,
                       "the union must surface the re-added strap's live activity class, not an empty pinned read")
    }
}
