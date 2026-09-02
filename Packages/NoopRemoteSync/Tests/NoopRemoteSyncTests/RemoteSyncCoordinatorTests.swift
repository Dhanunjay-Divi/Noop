import XCTest
import WhoopStore
import WhoopProtocol
@testable import NoopRemoteSync

final class RemoteSyncCoordinatorTests: XCTestCase {
    func testLegacySleepPayloadWithoutMetadataStillDecodes() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = Data(
            """
            {
              "session_id": "legacy-night",
              "start_ts": 1700000000,
              "end_ts": 1700028800,
              "stages": {"light": 14400}
            }
            """.utf8)

        let session = try decoder.decode(RemoteSleepSession.self, from: payload)

        XCTAssertEqual(session.sessionId, "legacy-night")
        XCTAssertEqual(session.stages, ["light": 14_400])
        XCTAssertTrue(session.metadata.isEmpty)
    }

    func testCanonicalSleepStagesNormalisesImportedMinuteObjectToSeconds() {
        let stages = RemoteSyncCoordinator.canonicalSleepStages(
            #"{"light":245.5,"deep":60,"rem":42,"wake":10,"unknown":99}"#
        )

        XCTAssertEqual(
            stages,
            ["light": 14_730, "deep": 3_600, "rem": 2_520, "awake": 600]
        )
    }

    func testCanonicalSleepStagesNormalisesSegmentsAndLegacyMinuteRows() {
        let stages = RemoteSyncCoordinator.canonicalSleepStages(
            """
            [
              {"start":1000,"end":1060,"stage":"wake"},
              {"start":1060,"end":1180,"stage":"SWS"},
              {"stage":"rem","min":1.5},
              {"start":2000,"end":1900,"stage":"light"},
              {"start":2000,"end":2060,"stage":"unknown"}
            ]
            """
        )

        XCTAssertEqual(stages, ["awake": 60, "deep": 120, "rem": 90])
        XCTAssertNil(RemoteSyncCoordinator.canonicalSleepStages(#"["not-a-stage"]"#))
        XCTAssertNil(RemoteSyncCoordinator.canonicalSleepStages("not json"))
    }

    func testSleepEvidenceMetadataPreservesOnlyExactCountPairs() {
        let supported = CachedSleepSession(
            startTs: 1_700_000_000,
            endTs: 1_700_028_800,
            efficiency: 0.9,
            restingHr: 52,
            avgHrv: 64,
            stagesJSON: #"{"light":480}"#,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24
        )
        XCTAssertEqual(
            RemoteSyncCoordinator.sleepEvidenceMetadata(supported),
            [
                "hrv_method": "RMSSD",
                "rr_eligible_window_count": "96",
                "rr_valid_window_count": "24",
            ]
        )

        let partial = CachedSleepSession(
            startTs: supported.startTs,
            endTs: supported.endTs,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: nil
        )
        XCTAssertTrue(RemoteSyncCoordinator.sleepEvidenceMetadata(partial).isEmpty)

        let staleBounds = CachedSleepSession(
            startTs: supported.startTs,
            endTs: supported.endTs + 300,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24
        )
        XCTAssertTrue(RemoteSyncCoordinator.sleepEvidenceMetadata(staleBounds).isEmpty)
    }

    func testSuccessfulUploadAcknowledgesRawRowsAndMapsRawUnitsHonestly() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-1"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(
                hr: [HRSample(ts: 1_700_000_000, bpm: 72)],
                spo2: [SpO2Sample(ts: 1_700_000_001, red: 18_000, ir: 17_000)],
                gravity: [
                    GravitySample(ts: 1_700_000_003, x: 0.1, y: -0.2, z: 0.97),
                ],
                sleepState: [SleepStateSample(ts: 1_700_000_004, state: 2)],
                ppgHr: [PpgHrSample(ts: 1_700_000_005, bpm: 63, conf: 0.87)],
                ppgWaveform: [
                    PpgWaveformSample(ts: 1_700_000_006, samples: [-1_432, 7, 2_048]),
                ],
                events: [
                    WhoopEvent(
                        ts: 1_700_000_002,
                        kind: "BLE_CONNECTION_DOWN(12)",
                        payload: ["reason": .int(3)]
                    ),
                ]
            ),
            deviceId: deviceId
        )
        let uploader = RecordingUploader()
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        let result = try await coordinator.sync(
            source: RemoteSyncSource(deviceId: deviceId, sentAt: "2026-07-24T12:00:00Z"),
            now: Date(timeIntervalSince1970: 1_700_100_000),
            maxBatches: 1
        )

        XCTAssertEqual(result.uploadedRawRows, 7)
        XCTAssertEqual(result.uploadedBatches, 1)
        XCTAssertFalse(result.hasMoreRawRows)
        let afterUpload = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertTrue(afterUpload.isEmpty)
        let envelopes = await uploader.envelopes
        let sent = try XCTUnwrap(envelopes.first)
        XCTAssertEqual(sent.streams.hr.first?.value, 72)
        XCTAssertEqual(sent.streams.spo2.first?.value, 18_000)
        XCTAssertEqual(sent.streams.spo2.first?.metadata?["infrared"], "17000")
        XCTAssertEqual(sent.streams.spo2.first?.metadata?["uncalibrated"], "true")
        XCTAssertEqual(sent.streams.gravity.first?.value, 0.1)
        XCTAssertEqual(sent.streams.gravity.first?.metadata?["y"], "-0.2")
        XCTAssertEqual(sent.streams.sleepState.first?.value, 2)
        XCTAssertEqual(sent.streams.ppgHr.first?.value, 63)
        XCTAssertEqual(sent.streams.ppgHr.first?.quality, 0.87)
        XCTAssertEqual(sent.streams.ppgHr.first?.metadata?["derived"], "true")
        XCTAssertEqual(sent.streams.ppgWaveform.first?.value, 3)
        XCTAssertEqual(sent.streams.ppgWaveform.first?.metadata?["encoding"], "i16_le_base64")
        XCTAssertEqual(sent.streams.ppgWaveform.first?.metadata?["samples"], "aPoHAAAI")
        XCTAssertEqual(sent.streams.events.first?.kind, "BLE_CONNECTION_DOWN(12)")
        XCTAssertTrue(
            sent.streams.events.first?.eventId.range(
                of: #"^event-[0-9a-f]{16}$"#,
                options: .regularExpression
            ) != nil
        )
    }

    func testFailureLeavesRowsPending() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-1"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: deviceId
        )
        let uploader = RecordingUploader(error: TestError.offline)
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        do {
            _ = try await coordinator.sync(source: RemoteSyncSource(deviceId: deviceId))
            XCTFail("Expected upload failure")
        } catch TestError.offline {
            // Expected.
        }
        let pending = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertEqual(pending.hr.count, 1)
    }

    func testMismatchedAcknowledgementLeavesRowsPending() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-1"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: deviceId
        )
        let uploader = RecordingUploader(forceWrongBatch: true)
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        do {
            _ = try await coordinator.sync(source: RemoteSyncSource(deviceId: deviceId))
            XCTFail("Expected batch mismatch")
        } catch {
            XCTAssertEqual(error as? RemoteSyncError, .batchMismatch)
        }
        let pending = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertFalse(pending.isEmpty)
    }

    func testNonAcceptedAcknowledgementLeavesRowsPending() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-1"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: deviceId
        )
        let uploader = RecordingUploader(status: "queued")
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        do {
            _ = try await coordinator.sync(source: RemoteSyncSource(deviceId: deviceId))
            XCTFail("Expected a non-accepted acknowledgement to fail")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncError,
                .unexpectedAcknowledgementStatus("queued")
            )
        }
        let pending = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertEqual(pending.hr.count, 1)
    }

    func testResponseLostRetryReusesPersistedBatchIdentityAcrossCoordinators() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "strap-1"
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)]),
            deviceId: deviceId
        )
        let identities = VolatileRemoteBatchIdentityStore()
        let failedUpload = RecordingUploader(error: TestError.offline)
        let first = RemoteSyncCoordinator(
            store: store, uploader: failedUpload, identityStore: identities
        )

        do {
            _ = try await first.sync(
                source: RemoteSyncSource(
                    deviceId: "strap-1-strap", sentAt: "2026-07-24T12:00:00Z"
                ),
                storeDeviceId: deviceId
            )
            XCTFail("Expected the simulated response loss")
        } catch TestError.offline {
            // The uploader records the exact envelope before simulating a lost response.
        }
        let failedEnvelopes = await failedUpload.envelopes
        let firstEnvelope = try XCTUnwrap(failedEnvelopes.first)

        let successfulUpload = RecordingUploader()
        let retry = RemoteSyncCoordinator(
            store: store, uploader: successfulUpload, identityStore: identities
        )
        _ = try await retry.sync(
            source: RemoteSyncSource(
                deviceId: "strap-1-strap", sentAt: "2026-07-25T09:00:00Z"
            ),
            storeDeviceId: deviceId
        )
        let successfulEnvelopes = await successfulUpload.envelopes
        let retriedEnvelope = try XCTUnwrap(successfulEnvelopes.first)

        XCTAssertEqual(retriedEnvelope.batchId, firstEnvelope.batchId)
        XCTAssertEqual(retriedEnvelope.source.sentAt, firstEnvelope.source.sentAt)
        let pendingAfterRetry = try await store.pendingRemoteSyncStreams(deviceId: deviceId)
        XCTAssertTrue(pendingAfterRetry.isEmpty)
    }

    func testRemoteNamespaceCanReadAndAcknowledgeDifferentLocalDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            deviceId: "my-whoop"
        )
        let uploader = RecordingUploader()
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        _ = try await coordinator.sync(
            source: RemoteSyncSource(deviceId: "my-whoop-strap"),
            storeDeviceId: "my-whoop",
            includeDerived: false
        )

        let envelopes = await uploader.envelopes
        let sent = try XCTUnwrap(envelopes.first)
        XCTAssertEqual(sent.source.deviceId, "my-whoop-strap")
        XCTAssertEqual(sent.streams.hr.first?.value, 60)
        let pending = try await store.pendingRemoteSyncStreams(deviceId: "my-whoop")
        XCTAssertTrue(pending.isEmpty)
    }

    func testOfficialReferenceCanExcludeManualWorkoutsFromMixedLocalNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_700_000_000
        _ = try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: "2023-11-14", totalSleepMin: 420, efficiency: 91,
                    deepMin: 60, remMin: 90, lightMin: 270, disturbances: nil,
                    restingHr: 52, avgHrv: 64, recovery: 72, strain: 50,
                    exerciseCount: 1, skinTempDevC: 34.2
                ),
            ],
            deviceId: "my-whoop"
        )
        _ = try await store.upsertWorkouts(
            [
                WorkoutRow(
                    startTs: start, endTs: start + 3_600, sport: "Running",
                    source: "whoop", durationS: 3_600, energyKcal: nil,
                    avgHr: nil, maxHr: nil, strain: 50, distanceM: nil,
                    zonesJSON: nil, notes: nil
                ),
                WorkoutRow(
                    startTs: start + 7_200, endTs: start + 8_000, sport: "Yoga",
                    source: "manual", durationS: 800, energyKcal: nil,
                    avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                    zonesJSON: nil, notes: nil
                ),
            ],
            deviceId: "my-whoop"
        )
        let uploader = RecordingUploader()
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        _ = try await coordinator.sync(
            source: RemoteSyncSource(deviceId: "whoop-official-reference"),
            storeDeviceId: "my-whoop",
            includeRaw: false,
            derivedWorkoutSources: Set(["whoop"]),
            derivedMetricProvenance: .officialReference,
            now: Date(timeIntervalSince1970: TimeInterval(start + 10_000))
        )

        let envelopes = await uploader.envelopes
        let workouts = try XCTUnwrap(envelopes.first?.workouts)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.source, "whoop")
        XCTAssertEqual(workouts.first?.metrics?["effort"], 50)
        XCTAssertEqual(workouts.first?.metrics?["whoop_strain"], 10.5)
        XCTAssertNil(workouts.first?.metrics?["strain"])
        let daily = try XCTUnwrap(envelopes.first?.dailyMetrics["2023-11-14"])
        XCTAssertEqual(daily["efficiency"], 0.91)
        XCTAssertEqual(daily["effort"], 50)
        XCTAssertEqual(daily["whoop_strain"], 10.5)
        XCTAssertEqual(daily["skin_temp_c"], 34.2)
        XCTAssertNil(daily["skin_temp_dev_c"])
        XCTAssertNil(daily["strain"])
    }

    func testNoopComputedDailyIncludesBoundedCanonicalRestSeries() async throws {
        let store = try await WhoopStore.inMemory()
        let localId = "my-whoop-noop"
        _ = try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: "2026-07-24", totalSleepMin: 420, efficiency: 0.91,
                    deepMin: 60, remMin: 90, lightMin: 270, disturbances: nil,
                    restingHr: 52, avgHrv: 64, recovery: 72, strain: 50,
                    exerciseCount: 1
                ),
            ],
            deviceId: localId
        )
        _ = try await store.upsertMetricSeries(
            [
                MetricPoint(day: "2026-07-23", key: "sleep_performance", value: 61),
                MetricPoint(day: "2026-07-24", key: "sleep_performance", value: 84),
                // A Rest-only day must still cross the daily boundary; Rest's source of truth is the
                // metric-series row, so requiring a legacy DailyMetric twin would silently drop it.
                MetricPoint(day: "2026-07-25", key: "sleep_performance", value: 73),
                // A corrupt out-of-domain value is omitted rather than clamped into a believable score.
                MetricPoint(day: "2026-07-26", key: "sleep_performance", value: 101),
                MetricPoint(day: "2026-07-27", key: "sleep_performance", value: 88),
            ],
            deviceId: localId
        )
        let uploader = RecordingUploader()
        let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)

        _ = try await coordinator.sync(
            source: RemoteSyncSource(deviceId: "scoped-noop-computed"),
            storeDeviceId: localId,
            includeRaw: false,
            derivedMetricProvenance: .noopComputed,
            derivedWindow: RemoteDerivedWindow(
                fromTs: 1_721_779_200,
                toTs: 1_722_038_400,
                fromDay: "2026-07-24",
                toDay: "2026-07-26"
            )
        )

        let envelopes = await uploader.envelopes
        let daily = try XCTUnwrap(envelopes.first?.dailyMetrics)
        XCTAssertEqual(Set(daily.keys), Set(["2026-07-24", "2026-07-25"]))
        XCTAssertEqual(daily["2026-07-24"]?["sleep_performance"], 84)
        XCTAssertEqual(daily["2026-07-25"]?["sleep_performance"], 73)
        XCTAssertEqual(daily["2026-07-24"]?["recovery"], 72)
        XCTAssertNil(daily["2026-07-24"]?["rest"])
    }

    func testRestSeriesIsNotRelabelledIntoNonNoopNamespaces() async throws {
        let store = try await WhoopStore.inMemory()
        let localId = "my-whoop"
        _ = try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: "2026-07-24", totalSleepMin: 420, efficiency: 0.91,
                    deepMin: 60, remMin: 90, lightMin: 270, disturbances: nil,
                    restingHr: 52, avgHrv: 64, recovery: 72, strain: 50,
                    exerciseCount: 1
                ),
            ],
            deviceId: localId
        )
        _ = try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-07-24", key: "sleep_performance", value: 84)],
            deviceId: localId
        )
        let window = RemoteDerivedWindow(
            fromTs: 1_721_779_200,
            toTs: 1_721_865_600,
            fromDay: "2026-07-24",
            toDay: "2026-07-24"
        )

        for (sourceId, provenance) in [
            ("whoop-official-reference", RemoteDerivedMetricProvenance.officialReference),
            ("apple-health-import", RemoteDerivedMetricProvenance.userOwned),
        ] {
            let uploader = RecordingUploader()
            let coordinator = RemoteSyncCoordinator(store: store, uploader: uploader)
            _ = try await coordinator.sync(
                source: RemoteSyncSource(deviceId: sourceId),
                storeDeviceId: localId,
                includeRaw: false,
                derivedMetricProvenance: provenance,
                derivedWindow: window
            )

            let envelopes = await uploader.envelopes
            let daily = try XCTUnwrap(envelopes.first?.dailyMetrics["2026-07-24"])
            XCTAssertNil(
                daily["sleep_performance"],
                "\(sourceId) must not present a local metric-series Rest value as its own"
            )
        }
    }

    func testDerivedReplayPagesBeyondServerCollectionCapAndResumesCursor() async throws {
        let store = try await WhoopStore.inMemory()
        let localId = "my-whoop-noop"
        let now = 1_800_000_000
        let sessions = (0..<5_001).map { index in
            let start = now - 700_000 + index * 120
            return CachedSleepSession(
                startTs: start,
                endTs: start + 60,
                efficiency: 0.9,
                restingHr: 55,
                avgHrv: 60,
                stagesJSON: #"{"light":1}"#
            )
        }
        _ = try await store.upsertSleepSessions(sessions, deviceId: localId)
        let cursors = VolatileRemoteDerivedCursorStore()
        let window = RemoteDerivedWindow(
            fromTs: now - 800_000,
            toTs: now,
            fromDay: "2027-01-01",
            toDay: "2027-01-31"
        )
        let firstUploader = RecordingUploader()
        let first = RemoteSyncCoordinator(
            store: store, uploader: firstUploader, cursorStore: cursors
        )

        let firstResult = try await first.sync(
            source: RemoteSyncSource(deviceId: localId),
            includeRaw: false,
            now: Date(timeIntervalSince1970: TimeInterval(now)),
            derivedWindow: window,
            retainDerivedCompletion: true,
            maxBatches: 20
        )

        let firstEnvelopes = await firstUploader.envelopes
        XCTAssertEqual(firstEnvelopes.reduce(0) { $0 + $1.sleepSessions.count }, 5_000)
        XCTAssertTrue(firstEnvelopes.allSatisfy { $0.sleepSessions.count <= 250 })
        XCTAssertTrue(firstResult.hasMoreDerivedRows)
        let resumedCursor = await cursors.cursor(for: localId)
        XCTAssertEqual(resumedCursor.sleepStartTs, sessions[4_999].startTs)
        XCTAssertFalse(resumedCursor.isComplete)

        // Deleting a row before the watermark would shift an OFFSET cursor and skip the final row.
        // The exclusive startTs keyset still resumes at exactly session 5,001.
        _ = try await store.deleteSleepSession(
            deviceId: localId,
            startTs: sessions[0].startTs
        )

        let finalUploader = RecordingUploader()
        let final = RemoteSyncCoordinator(
            store: store, uploader: finalUploader, cursorStore: cursors
        )
        let finalResult = try await final.sync(
            source: RemoteSyncSource(deviceId: localId),
            includeRaw: false,
            now: Date(timeIntervalSince1970: TimeInterval(now + 86_400)),
            derivedWindow: window,
            retainDerivedCompletion: true,
            maxBatches: 2
        )

        let finalEnvelopes = await finalUploader.envelopes
        XCTAssertEqual(finalEnvelopes.first?.sleepSessions.count, 1)
        XCTAssertEqual(finalEnvelopes.first?.sleepSessions.first?.startTs, sessions[5_000].startTs)
        XCTAssertFalse(finalResult.hasMoreDerivedRows)
        let completedCursor = await cursors.cursor(for: localId)
        XCTAssertTrue(completedCursor.isComplete)

        // Another launch during the same global replay must not restart this finished namespace.
        let noReplayUploader = RecordingUploader()
        let noReplay = RemoteSyncCoordinator(
            store: store, uploader: noReplayUploader, cursorStore: cursors
        )
        let noReplayResult = try await noReplay.sync(
            source: RemoteSyncSource(deviceId: localId),
            includeRaw: false,
            derivedWindow: window,
            retainDerivedCompletion: true
        )
        let noReplayEnvelopes = await noReplayUploader.envelopes
        XCTAssertEqual(noReplayEnvelopes.count, 0)
        XCTAssertFalse(noReplayResult.hasMoreDerivedRows)

        // The app clears every completed marker only after the global replay is fully drained.
        await cursors.resetCursor(for: localId)
        let resetCursor = await cursors.cursor(for: localId)
        XCTAssertEqual(resetCursor, .start)
    }

    func testEventPayloadMetadataIsBoundedAndMarksTruncation() throws {
        let small = RemoteSyncCoordinator.boundedEventMetadata(payloadJSON: #"{"value":7}"#)
        XCTAssertNil(small["payload_truncated"])
        XCTAssertEqual(small["payload_json"], #"{"value":7}"#)

        let largePayload =
            "{\"quoted\":\"" + String(repeating: "\\\"abcdef\\\"", count: 5_000) + "\"}"
        let bounded = RemoteSyncCoordinator.boundedEventMetadata(payloadJSON: largePayload)
        let encoded = try JSONSerialization.data(withJSONObject: bounded)
        XCTAssertLessThan(encoded.count, 16_384)
        XCTAssertEqual(bounded["payload_truncated"], "true")
        let boundedPayload = try XCTUnwrap(bounded["payload_json"])
        XCTAssertTrue(largePayload.hasPrefix(boundedPayload))

        let unicodeLabel = String(repeating: "👨‍👩‍👧‍👦", count: 80)
        let boundedLabel = RemoteSyncCoordinator.boundedText(
            unicodeLabel,
            maxCodePoints: 128
        )
        XCTAssertLessThanOrEqual(boundedLabel.unicodeScalars.count, 128)
    }
}

private enum TestError: Error {
    case offline
}

private actor RecordingUploader: RemoteSyncUploading {
    private(set) var envelopes: [RemoteSyncEnvelope] = []
    let error: Error?
    let forceWrongBatch: Bool
    let status: String

    init(
        error: Error? = nil,
        forceWrongBatch: Bool = false,
        status: String = "accepted"
    ) {
        self.error = error
        self.forceWrongBatch = forceWrongBatch
        self.status = status
    }

    func upload(_ envelope: RemoteSyncEnvelope) async throws -> RemoteSyncResponse {
        envelopes.append(envelope)
        if let error { throw error }
        return RemoteSyncResponse(
            batchId: forceWrongBatch ? UUID() : envelope.batchId,
            status: status,
            counts: ["raw": envelope.streams.hr.count + envelope.streams.spo2.count],
            duplicate: false
        )
    }
}
