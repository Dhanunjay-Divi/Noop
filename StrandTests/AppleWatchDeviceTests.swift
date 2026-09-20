import XCTest
import WhoopStore
@testable import Strand

/// Pins `AppleWatchDevice`'s honest registration: a watch only appears once HealthKit is authorized
/// AND recent apple-health data exists, and its capability set is TRIMMED to the metrics that have
/// actually arrived (so an older watch reads honestly, never advertising a sensor it lacks).
/// Apple-only feature; this is the pure derivation that the iOS `registerIfAuthorized` stands on.
final class AppleWatchDeviceTests: XCTestCase {

    // MARK: - Row builders

    private func daily(_ day: String, restingHr: Int? = nil, avgHrv: Double? = nil,
                       totalSleepMin: Double? = nil, spo2Pct: Double? = nil,
                       skinTempDevC: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: nil, steps: steps)
    }

    private func apple(_ day: String, steps: Int? = nil, avgHr: Int? = nil,
                       vo2max: Double? = nil) -> AppleDaily {
        AppleDaily(day: day, steps: steps, activeKcal: nil, basalKcal: nil, vo2max: vo2max,
                   avgHr: avgHr, maxHr: nil, walkingHr: nil, weightKg: nil)
    }

    // MARK: - Not registered

    /// No apple-health rows → no device, even when authorized (a fresh / unused watch shows nothing).
    func testNoDataNoDevice() {
        XCTAssertNil(AppleWatchDevice.device(daily: [], apple: [], authorized: true))
    }

    /// Auth denied → no device, even with plenty of data (we never register off another source's import).
    func testUnauthorizedNoDevice() {
        let d = [daily("2026-06-20", restingHr: 52, avgHrv: 45, totalSleepMin: 420)]
        XCTAssertNil(AppleWatchDevice.device(daily: d, apple: [], authorized: false))
    }

    /// Rows present but every metric empty (all-nil) → nothing usable → no device.
    func testEmptyMetricsNoDevice() {
        XCTAssertNil(AppleWatchDevice.device(daily: [daily("2026-06-20")], apple: [], authorized: true))
    }

    // MARK: - Registered + trimmed

    /// A modern watch week (HR, HRV, sleep, steps, SpO₂, wrist temp all present) → the full set.
    func testModernWatchFullCapabilities() {
        let d = [
            daily("2026-06-19", restingHr: 53, avgHrv: 44, totalSleepMin: 410, spo2Pct: 97,
                  skinTempDevC: -0.2, steps: 8000),
            daily("2026-06-20", restingHr: 52, avgHrv: 46, totalSleepMin: 430, spo2Pct: 96,
                  skinTempDevC: 0.1, steps: 9200),
        ]
        let dev = AppleWatchDevice.device(daily: d, apple: [], authorized: true)
        XCTAssertNotNil(dev)
        XCTAssertEqual(dev?.id, "apple-health")
        XCTAssertEqual(dev?.brand, "Apple")
        XCTAssertEqual(dev?.model, "Apple Watch")
        XCTAssertEqual(dev?.sourceKind, .liveAppleWatch)
        XCTAssertEqual(dev?.status, .paired)
        XCTAssertEqual(dev?.capabilities, [.hr, .hrv, .sleep, .steps, .spo2, .skinTemp])
    }

    /// An older watch (no SpO₂ %, no wrist temp samples) → those metrics are TRIMMED OUT so the card
    /// reads honestly. HR (from resting HR), HRV, sleep and steps remain.
    func testOlderWatchTrimsMissingSensors() {
        let d = [
            daily("2026-06-19", restingHr: 55, avgHrv: 38, totalSleepMin: 400, steps: 6000),
            daily("2026-06-20", restingHr: 54, avgHrv: 40, totalSleepMin: 415, steps: 7100),
        ]
        let dev = AppleWatchDevice.device(daily: d, apple: [], authorized: true)
        XCTAssertEqual(dev?.capabilities, [.hr, .hrv, .sleep, .steps])
        XCTAssertFalse(dev?.capabilities.contains(.spo2) ?? true)
        XCTAssertFalse(dev?.capabilities.contains(.skinTemp) ?? true)
    }

    /// HR can come from the AppleDaily side (avgHr) even when no DailyMetric carries resting HR, and
    /// steps from either table. Confirms the OR across both stored shapes.
    func testCapabilitiesAcrossBothTables() {
        let d = [daily("2026-06-20", avgHrv: 42)]               // HRV only on the daily side
        let a = [apple("2026-06-20", steps: 5000, avgHr: 70)]   // HR + steps on the apple side
        let dev = AppleWatchDevice.device(daily: d, apple: a, authorized: true)
        XCTAssertEqual(dev?.capabilities, [.hr, .hrv, .steps])
    }

    // MARK: - Refresh preserves identity

    /// A refresh keeps a user nickname and the original pairing date; only the capability set and
    /// last-seen move with the freshest data.
    func testRefreshPreservesNicknameAndAddedAt() {
        let existing = PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch",
                                    nickname: "My Watch", peripheralId: nil,
                                    sourceKind: .liveAppleWatch, capabilities: [.hr],
                                    status: .active, addedAt: 1000, lastSeenAt: 1000)
        let d = [daily("2026-06-20", restingHr: 52, avgHrv: 45, totalSleepMin: 420, steps: 8000)]
        let dev = AppleWatchDevice.device(daily: d, apple: [], authorized: true,
                                          existing: existing, now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(dev?.nickname, "My Watch")
        XCTAssertEqual(dev?.addedAt, 1000)             // pairing date preserved
        XCTAssertEqual(dev?.lastSeenAt, 2000)          // last-seen advances
        XCTAssertEqual(dev?.status, .active)           // refresh does not demote the selected source
        XCTAssertEqual(dev?.capabilities, [.hr, .hrv, .sleep, .steps])
    }

    // MARK: - Safe auto-activation

    func testAutoActivatesOnlyUnusedWhoopPlaceholder() {
        let placeholder = PairedDevice(
            id: "my-whoop", brand: "WHOOP", model: "WHOOP", peripheralId: nil,
            sourceKind: .liveBLE, capabilities: [.hr], status: .active,
            addedAt: 1000, lastSeenAt: 1000)

        XCTAssertTrue(AppleWatchDevice.shouldAutoActivate(
            current: placeholder, currentHasRecentData: false))
        XCTAssertFalse(AppleWatchDevice.shouldAutoActivate(
            current: placeholder, currentHasRecentData: true))
    }

    func testDoesNotReplaceRealWhoopOrUserSelectedSource() {
        let pairedWhoop = PairedDevice(
            id: "my-whoop", brand: "WHOOP", model: "WHOOP 5.0", peripheralId: "BLE-123",
            sourceKind: .liveBLE, capabilities: [.hr], status: .active,
            addedAt: 1000, lastSeenAt: 2000)
        let oura = PairedDevice(
            id: "oura-123", brand: "Oura", model: "Ring 4", peripheralId: "BLE-456",
            sourceKind: .oura, capabilities: [.hr, .hrv], status: .active,
            addedAt: 1000, lastSeenAt: 2000)

        XCTAssertFalse(AppleWatchDevice.shouldAutoActivate(
            current: pairedWhoop, currentHasRecentData: false))
        XCTAssertFalse(AppleWatchDevice.shouldAutoActivate(
            current: oura, currentHasRecentData: false))
    }

    /// The watch workout UI lives in the watch extension and cannot be linked into this macOS unit-test
    /// host. Pin the release-critical source contract instead: both asynchronous HealthKit boundaries
    /// must fail closed, and a nil `HKWorkout` must never reach the "saved" phase.
    func testWatchWorkoutRequiresHealthKitSuccessBeforeClaimingSaved() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchWorkoutView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("guard collectionSucceeded, collectionError == nil"))
        XCTAssertTrue(source.contains("guard let savedWorkout, finishError == nil"))
        XCTAssertTrue(source.contains("self.fail(.save)"))
        XCTAssertFalse(source.contains("builder.finishWorkout { [weak self] _, _ in"))
    }

    func testWatchGlanceAuthorizationIsUserInitiatedAndSamplesExpire() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let liveHR = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchLiveHR.swift"),
            encoding: .utf8)
        let glance = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchGlanceView.swift"),
            encoding: .utf8)

        let startRange = try XCTUnwrap(liveHR.range(of: "func start()"))
        let requestRange = try XCTUnwrap(
            liveHR.range(of: "func requestAuthorization()", range: startRange.upperBound..<liveHR.endIndex)
        )
        let startBody = String(liveHR[startRange.lowerBound..<requestRange.lowerBound])

        XCTAssertTrue(startBody.contains("getRequestStatusForAuthorization"))
        XCTAssertFalse(startBody.contains("store.requestAuthorization"))
        XCTAssertTrue(glance.contains(#"Button("Allow access")"#))
        XCTAssertTrue(glance.contains("liveHR.requestAuthorization()"))

        XCTAssertTrue(liveHR.contains("static let maximumSampleAge: TimeInterval = 30"))
        XCTAssertTrue(liveHR.contains("age >= 0 && age <= WatchLiveHRPolicy.maximumSampleAge"))
        XCTAssertTrue(liveHR.contains("WatchLiveHRPolicy.plausibleBPM.contains(rounded)"))
        XCTAssertTrue(liveHR.contains("case noReadableSample"))
        XCTAssertTrue(liveHR.contains("case queryFailed"))
        XCTAssertTrue(liveHR.contains("reportNoSample: true"))
        XCTAssertTrue(liveHR.contains("owner.accessState = .queryFailed"))
        XCTAssertTrue(glance.contains("appwide.watch.live_hr.check_access"))
        XCTAssertTrue(liveHR.contains("owner.scheduleExpiry(observedAt: latest.endDate"))
        XCTAssertTrue(liveHR.contains("self.isCurrentStreamingGeneration(generation)"))
        XCTAssertTrue(liveHR.contains("self.bpm = nil"))
        XCTAssertTrue(glance.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(glance.contains("ScrollView"))
        XCTAssertTrue(glance.contains("liveHR.retry()"))
    }

    func testWatchLiveHRStopInvalidatesDelayedCallbacks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchLiveHR.swift"),
            encoding: .utf8)

        let startRange = try XCTUnwrap(source.range(of: "func start()"))
        let requestRange = try XCTUnwrap(
            source.range(
                of: "func requestAuthorization()",
                range: startRange.upperBound..<source.endIndex
            )
        )
        let stopRange = try XCTUnwrap(
            source.range(of: "func stop()", range: requestRange.upperBound..<source.endIndex)
        )
        let generationRange = try XCTUnwrap(
            source.range(
                of: "private func desiredStreamingGeneration()",
                range: stopRange.upperBound..<source.endIndex
            )
        )

        let startBody = String(source[startRange.lowerBound..<requestRange.lowerBound])
        let requestBody = String(source[requestRange.lowerBound..<stopRange.lowerBound])
        let stopBody = String(source[stopRange.lowerBound..<generationRange.lowerBound])

        XCTAssertTrue(source.contains("private var desiredStreaming = false"))
        XCTAssertTrue(startBody.contains("let generation = desiredStreamingGeneration()"))
        XCTAssertTrue(
            startBody.contains(
                "guard let self, self.isCurrentStreamingGeneration(generation) else { return }"
            )
        )
        XCTAssertTrue(requestBody.contains("let generation = desiredStreamingGeneration()"))
        XCTAssertTrue(
            requestBody.contains(
                "guard let self, self.isCurrentStreamingGeneration(generation) else { return }"
            )
        )
        XCTAssertTrue(stopBody.contains("invalidateStreamingGeneration()"))
        XCTAssertTrue(source.contains("desiredStreaming = false"))
        XCTAssertTrue(source.contains("streamGeneration &+= 1"))
        XCTAssertTrue(
            source.contains(
                "guard isCurrentStreamingGeneration(generation), let hrType, query == nil else { return }"
            )
        )
        XCTAssertTrue(
            source.contains(
                "guard let owner, owner.isCurrentStreamingGeneration(generation) else { return }"
            )
        )
        XCTAssertFalse(source.contains("private static let maximumSampleAge"))
        XCTAssertFalse(source.contains("private static let plausibleBPM"))
    }

    func testWatchGlanceSeparatesMeasuredCalibratingMissingAndStaleScores() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchGlanceView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("private enum ScoreRingState"))
        XCTAssertTrue(source.contains("case measured(Double)"))
        XCTAssertTrue(source.contains("case calibrating"))
        XCTAssertTrue(source.contains("case missing"))
        XCTAssertTrue(source.contains("case stale(freshness: String)"))
        XCTAssertTrue(source.contains("if stale {"))
        XCTAssertTrue(source.contains("} else if calibrating {"))
        XCTAssertTrue(source.contains("} else if let value {"))
        XCTAssertFalse(source.contains("calibrating: snap.chargeCalibrating || stale"))

        XCTAssertTrue(source.contains(#"Image(systemName: "hourglass")"#))
        XCTAssertTrue(source.contains(#"Image(systemName: "clock.badge.exclamationmark")"#))
        XCTAssertTrue(source.contains(#"return Text("Calibrating")"#))
        XCTAssertTrue(source.contains(#"return Text("No data")"#))
        XCTAssertTrue(
            source.contains(#"return Text("Last sync: \(freshness)")"#)
        )
        XCTAssertTrue(source.contains(".accessibilityValue(accessibilityValue)"))
    }

    func testLiveActivityStatColumnsCompressInsteadOfForcingIntrinsicWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("StrandiOSWidgets/NOOPLiveActivity.swift"),
            encoding: .utf8)
        let bannerStart = try XCTUnwrap(
            source.range(of: "private func bannerStat(label: String, value: String)")
        )
        let islandStart = try XCTUnwrap(
            source.range(
                of: "private func statColumn(label: String, value: String)",
                range: bannerStart.upperBound..<source.endIndex
            )
        )
        let bannerSource = String(source[bannerStart.lowerBound..<islandStart.lowerBound])
        let islandSource = String(source[islandStart.lowerBound...])

        for columnSource in [bannerSource, islandSource] {
            XCTAssertFalse(columnSource.contains(".fixedSize()"))
            XCTAssertGreaterThanOrEqual(columnSource.components(separatedBy: ".lineLimit(1)").count - 1, 2)
            XCTAssertTrue(columnSource.contains(".minimumScaleFactor(0.65)"))
            XCTAssertTrue(columnSource.contains(".minimumScaleFactor(0.75)"))
            XCTAssertTrue(columnSource.contains(".frame(minWidth: 0, maxWidth: .infinity)"))
            XCTAssertTrue(columnSource.contains(".accessibilityElement(children: .combine)"))
        }
    }

    func testWatchAndLiveActivityUseRecoveryVocabulary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let watch = try String(
            contentsOf: root.appendingPathComponent("NOOPWatch/WatchGlanceView.swift"),
            encoding: .utf8)
        let liveActivity = try String(
            contentsOf: root.appendingPathComponent("StrandiOSWidgets/NOOPLiveActivity.swift"),
            encoding: .utf8)

        XCTAssertTrue(watch.contains(#"ScoreRing(label: String(localized: "Recovery")"#))
        XCTAssertFalse(watch.contains(#"ScoreRing(label: String(localized: "Charge")"#))
        XCTAssertTrue(
            liveActivity.contains(
                #"bannerStat("#)
                && liveActivity.contains(
                    #"label: liveScoreLabel("Recovery", scoreDay: context.state.scoreDay)"#
                )
        )
        XCTAssertTrue(
            liveActivity.contains(
                #"statColumn("#)
                && liveActivity.contains(
                    #"label: liveScoreLabel("Recovery", scoreDay: context.state.scoreDay)"#
                )
        )
        XCTAssertFalse(liveActivity.contains(#"label: "Charge""#))
    }
}
