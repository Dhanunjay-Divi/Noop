import Foundation
import CryptoKit
import WhoopStore

public struct RemoteSyncRunResult: Sendable, Equatable {
    public let uploadedRawRows: Int
    public let uploadedBatches: Int
    public let hasMoreRawRows: Bool
    public let hasMoreDerivedRows: Bool
    public let lastResponse: RemoteSyncResponse?

    public init(
        uploadedRawRows: Int,
        uploadedBatches: Int,
        hasMoreRawRows: Bool,
        hasMoreDerivedRows: Bool = false,
        lastResponse: RemoteSyncResponse?
    ) {
        self.uploadedRawRows = uploadedRawRows
        self.uploadedBatches = uploadedBatches
        self.hasMoreRawRows = hasMoreRawRows
        self.hasMoreDerivedRows = hasMoreDerivedRows
        self.lastResponse = lastResponse
    }
}

/// Selects the explicit wire labels for derived values whose local store column is historical.
public enum RemoteDerivedMetricProvenance: Sendable {
    case officialReference
    case noopComputed
    case userOwned
}

/// Bridges Noop's durable local database to the self-hosted v1 API.
///
/// Raw rows are read from a durable outbox and acknowledged only after a matching 2xx response.
/// Low-volume derived rows are replayed over a bounded history window because the server upserts
/// their natural keys; this also propagates local edits without inventing a fragile second outbox.
public actor RemoteSyncCoordinator {
    /// The persisted, cross-platform key for Noop's 0...100 Rest composite.
    ///
    /// Rest intentionally stays in `metricSeries` locally rather than the legacy wide `DailyMetric`
    /// row. Remote sync allowlists this one series for the `noop_computed` namespace instead of
    /// widening the replication boundary to arbitrary metric-series rows.
    static let restMetricKey = "sleep_performance"

    private let store: WhoopStore
    private let uploader: any RemoteSyncUploading
    private let identityStore: any RemoteBatchIdentityStoring
    private let cursorStore: any RemoteDerivedCursorStoring

    public init(
        store: WhoopStore,
        uploader: any RemoteSyncUploading,
        identityStore: any RemoteBatchIdentityStoring = VolatileRemoteBatchIdentityStore(),
        cursorStore: any RemoteDerivedCursorStoring = VolatileRemoteDerivedCursorStore()
    ) {
        self.store = store
        self.uploader = uploader
        self.identityStore = identityStore
        self.cursorStore = cursorStore
    }

    /// Upload up to `maxBatches` bounded raw/derived pages.
    public func sync(
        source: RemoteSyncSource,
        storeDeviceId: String? = nil,
        includeRaw: Bool = true,
        includeDerived: Bool = true,
        derivedWorkoutSources: Set<String>? = nil,
        derivedMetricProvenance: RemoteDerivedMetricProvenance = .userOwned,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        derivedHistoryDays: Int = 400,
        derivedWindow: RemoteDerivedWindow? = nil,
        retainDerivedCompletion: Bool = false,
        limitPerStream: Int = 5_000,
        maxBatches: Int = 6
    ) async throws -> RemoteSyncRunResult {
        let boundedBatches = max(1, min(maxBatches, 50))
        let boundedDays = max(1, min(derivedHistoryDays, 3_650))
        let window = derivedWindow ?? RemoteDerivedWindow(
            endingAt: now,
            historyDays: boundedDays,
            timeZone: timeZone
        )
        guard window.isValid else { throw RemoteSyncError.invalidDerivedWindow }
        let localDeviceId = storeDeviceId ?? source.deviceId

        var uploadedRows = 0
        var batches = 0
        var lastResponse: RemoteSyncResponse?
        var sendDerived = includeDerived
        var derivedCursor = includeDerived
            ? await cursorStore.cursor(for: source.deviceId)
            : .start
        var derivedRemaining = false
        if derivedCursor.isComplete {
            if retainDerivedCompletion {
                sendDerived = false
            } else {
                derivedCursor = .start
                await cursorStore.resetCursor(for: source.deviceId)
            }
        }

        for _ in 0..<boundedBatches {
            let pending = includeRaw
                ? try await store.pendingRemoteSyncStreams(
                    deviceId: localDeviceId,
                    limitPerStream: limitPerStream
                )
                : PendingRemoteSyncStreams()
            let derived: DerivedPayload
            if sendDerived {
                derived = try await readDerived(
                    deviceId: localDeviceId,
                    fromTs: window.fromTs,
                    toTs: window.toTs,
                    fromDay: window.fromDay,
                    toDay: window.toDay,
                    workoutSources: derivedWorkoutSources,
                    metricProvenance: derivedMetricProvenance,
                    cursor: derivedCursor
                )
            } else {
                derived = .empty
            }

            if sendDerived && derived.isEmpty {
                if derived.hasMore {
                    derivedCursor = derived.nextCursor
                    derivedRemaining = true
                    await cursorStore.save(derivedCursor, for: source.deviceId)
                } else {
                    sendDerived = false
                    derivedRemaining = false
                    if retainDerivedCompletion {
                        await cursorStore.save(
                            derived.nextCursor.markingComplete,
                            for: source.deviceId
                        )
                    } else {
                        await cursorStore.resetCursor(for: source.deviceId)
                    }
                }
            }

            let draft = RemoteSyncEnvelope(
                source: source,
                streams: Self.mapStreams(pending, deviceId: localDeviceId),
                dailyMetrics: derived.daily,
                sleepSessions: derived.sleep,
                workouts: derived.workouts,
                journal: derived.journal
            )
            if draft.isEmpty {
                if sendDerived { continue }
                break
            }

            let fingerprint = try Self.contentFingerprint(draft)
            let identity = try await identityStore.resolve(fingerprint: fingerprint, now: now)
            let envelope = Self.materialize(draft, identity: identity)
            let response = try await uploader.upload(envelope)
            guard response.batchId == envelope.batchId else {
                throw RemoteSyncError.batchMismatch
            }
            guard response.status == "accepted" else {
                throw RemoteSyncError.unexpectedAcknowledgementStatus(response.status)
            }
            try await store.markRemoteSyncStreamsSynced(pending, deviceId: localDeviceId)
            if sendDerived {
                if derived.hasMore {
                    derivedCursor = derived.nextCursor
                    derivedRemaining = true
                    await cursorStore.save(derivedCursor, for: source.deviceId)
                } else {
                    sendDerived = false
                    derivedRemaining = false
                    if retainDerivedCompletion {
                        await cursorStore.save(
                            derived.nextCursor.markingComplete,
                            for: source.deviceId
                        )
                    } else {
                        await cursorStore.resetCursor(for: source.deviceId)
                    }
                }
            }
            await identityStore.acknowledge(fingerprint: fingerprint)
            uploadedRows += pending.count
            batches += 1
            lastResponse = response

            // Derived-only pages keep looping until complete or the caller's batch budget is reached.
            if pending.isEmpty && !sendDerived { break }
        }

        let remains = includeRaw
            ? try await !store.pendingRemoteSyncStreams(
                deviceId: localDeviceId,
                limitPerStream: 1
            ).isEmpty
            : false
        return RemoteSyncRunResult(
            uploadedRawRows: uploadedRows,
            uploadedBatches: batches,
            hasMoreRawRows: remains,
            hasMoreDerivedRows: derivedRemaining,
            lastResponse: lastResponse
        )
    }

    private struct DerivedPayload {
        let daily: [String: [String: Double]]
        let sleep: [RemoteSleepSession]
        let workouts: [RemoteWorkout]
        let journal: [RemoteJournalEntry]
        let nextCursor: RemoteDerivedCursor
        let hasMore: Bool

        var isEmpty: Bool {
            daily.isEmpty && sleep.isEmpty && workouts.isEmpty && journal.isEmpty
        }

        static let empty = DerivedPayload(
            daily: [:], sleep: [], workouts: [], journal: [],
            nextCursor: .start, hasMore: false
        )
    }

    private func readDerived(
        deviceId: String,
        fromTs: Int,
        toTs: Int,
        fromDay: String,
        toDay: String,
        workoutSources: Set<String>?,
        metricProvenance: RemoteDerivedMetricProvenance,
        cursor: RemoteDerivedCursor
    ) async throws -> DerivedPayload {
        let sleepPageSize = 250
        let workoutPageSize = 250
        // One row per request keeps even a server-maximum 100k-character note below the 10 MB body cap.
        let journalPageSize = 1
        let dailyRows = cursor.dailySent
            ? []
            : try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
        let platformRows = cursor.dailySent
            ? []
            : try await store.appleDaily(deviceId: deviceId, from: fromDay, to: toDay)
        // Rest is the one daily score whose source of truth lives in the tall metric-series table.
        // Read it only for Noop-computed producer namespaces: copying the same local key into an
        // official-reference or generic import namespace would misstate its provenance. The query is
        // bounded by the exact fixed day window used by every other derived daily field.
        let restRows: [MetricPoint]
        if !cursor.dailySent, case .noopComputed = metricProvenance {
            restRows = try await store.metricSeries(
                deviceId: deviceId,
                key: Self.restMetricKey,
                from: fromDay,
                to: toDay
            )
        } else {
            restRows = []
        }
        let fetchedSleep = try await store.remoteSyncSleepSessions(
            deviceId: deviceId, from: fromTs, to: toTs,
            limit: sleepPageSize + 1, afterStartTs: cursor.sleepStartTs
        )
        let fetchedWorkouts = try await store.remoteSyncWorkouts(
            deviceId: deviceId, from: fromTs, to: toTs,
            allowedSources: workoutSources,
            limit: workoutPageSize + 1,
            afterStartTs: cursor.workoutStartTs,
            afterSport: cursor.workoutSport
        )
        let fetchedJournal = try await store.remoteSyncJournalEntries(
            deviceId: deviceId, from: fromDay, to: toDay,
            limit: journalPageSize + 1,
            afterDay: cursor.journalDay,
            afterQuestion: cursor.journalQuestion
        )
        let sleepRows = Array(fetchedSleep.prefix(sleepPageSize))
        let workoutRows = Array(fetchedWorkouts.prefix(workoutPageSize))
        let journalRows = Array(fetchedJournal.prefix(journalPageSize))
        let hasMoreSleep = fetchedSleep.count > sleepPageSize
        let hasMoreWorkouts = fetchedWorkouts.count > workoutPageSize
        let hasMoreJournal = fetchedJournal.count > journalPageSize
        let nextCursor = RemoteDerivedCursor(
            sleepStartTs: sleepRows.last?.startTs ?? cursor.sleepStartTs,
            workoutStartTs: workoutRows.last?.startTs ?? cursor.workoutStartTs,
            workoutSport: workoutRows.last?.sport ?? cursor.workoutSport,
            journalDay: journalRows.last?.day ?? cursor.journalDay,
            journalQuestion: journalRows.last?.question ?? cursor.journalQuestion,
            dailySent: true
        )
        var daily = Dictionary(
            uniqueKeysWithValues: dailyRows.map {
                ($0.day, Self.mapDaily($0, provenance: metricProvenance))
            }
        )
        for row in platformRows {
            var metrics = daily[row.day] ?? [:]
            Self.mapPlatformDaily(row, to: &metrics)
            daily[row.day] = metrics
        }
        for row in restRows where row.value.isFinite && (0...100).contains(row.value) {
            var metrics = daily[row.day] ?? [:]
            metrics[Self.restMetricKey] = row.value
            daily[row.day] = metrics
        }
        return DerivedPayload(
            daily: daily,
            sleep: sleepRows.filter {
                $0.endTs > $0.effectiveStartTs && $0.endTs - $0.effectiveStartTs <= 172_800
            }.map {
                RemoteSleepSession(
                    sessionId: Self.stableIdentifier(
                        prefix: "sleep", components: [deviceId, String($0.startTs)]
                    ),
                    startTs: $0.effectiveStartTs,
                    endTs: $0.endTs,
                    efficiency: Self.canonicalEfficiency($0.efficiency),
                    restingHr: $0.restingHr.flatMap {
                        (20...260).contains($0) ? $0 : nil
                    },
                    avgHrv: $0.avgHrv.flatMap {
                        $0.isFinite && (0...1_000).contains($0) ? $0 : nil
                    },
                    stages: Self.canonicalSleepStages($0.stagesJSON)
                )
            },
            workouts: workoutRows.filter {
                $0.endTs > $0.startTs && $0.endTs - $0.startTs <= 172_800
            }.map {
                let sport = $0.sport.trimmingCharacters(in: .whitespacesAndNewlines)
                let workoutSource = $0.source.trimmingCharacters(in: .whitespacesAndNewlines)
                var metrics: [String: Double] = [:]
                Self.add($0.durationS, as: "duration_s", to: &metrics)
                Self.add($0.energyKcal, as: "energy_kcal", to: &metrics)
                Self.add($0.avgHr.map(Double.init), as: "avg_hr", to: &metrics)
                Self.add($0.maxHr.map(Double.init), as: "max_hr", to: &metrics)
                Self.add($0.strain, as: "effort", to: &metrics)
                if metricProvenance == .officialReference {
                    Self.add($0.strain.map { $0 * 21 / 100 }, as: "whoop_strain", to: &metrics)
                }
                Self.add($0.distanceM, as: "distance_m", to: &metrics)
                return RemoteWorkout(
                    workoutId: Self.stableIdentifier(
                        prefix: "workout",
                        components: [deviceId, String($0.startTs), $0.sport]
                    ),
                    startTs: $0.startTs,
                    endTs: $0.endTs,
                    sport: Self.boundedText(
                        sport.isEmpty ? "Workout" : sport,
                        maxCodePoints: 512
                    ),
                    source: workoutSource.isEmpty
                        ? nil
                        : Self.boundedText(workoutSource, maxCodePoints: 256),
                    metrics: metrics.isEmpty ? nil : metrics
                )
            },
            journal: journalRows.filter {
                !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map {
                RemoteJournalEntry(
                    day: $0.day,
                    question: Self.boundedText(
                        $0.question.trimmingCharacters(in: .whitespacesAndNewlines),
                        maxCodePoints: 512
                    ),
                    answeredYes: $0.answeredYes,
                    notes: $0.notes.map {
                        Self.boundedText($0, maxCodePoints: 100_000)
                    },
                    numericValue: $0.numericValue.flatMap {
                        $0.isFinite && abs($0) <= 1_000_000_000 ? $0 : nil
                    }
                )
            },
            nextCursor: nextCursor,
            hasMore: hasMoreSleep || hasMoreWorkouts || hasMoreJournal
        )
    }

    private static func mapStreams(
        _ pending: PendingRemoteSyncStreams,
        deviceId: String
    ) -> RemoteStreams {
        RemoteStreams(
            hr: pending.hr.map {
                RemoteSample(
                    recordedAt: $0.ts, value: Double($0.bpm),
                    metadata: ["unit": "bpm", "provenance": "strap_measured"]
                )
            },
            rr: pending.rr.map {
                RemoteSample(
                    recordedAt: $0.ts, value: Double($0.rrMs),
                    metadata: ["unit": "ms", "seq": String($0.seq), "provenance": "strap_measured"]
                )
            },
            battery: pending.battery.map {
                var metadata: [String: String] = [
                    "unit": $0.stateOfCharge != nil
                        ? "percent"
                        : ($0.millivolts != nil ? "millivolts" : "unknown"),
                ]
                if let mv = $0.millivolts { metadata["millivolts"] = String(mv) }
                if let charging = $0.charging { metadata["charging"] = String(charging) }
                if $0.stateOfCharge == nil && $0.millivolts == nil {
                    metadata["missing_value"] = "true"
                }
                return RemoteSample(
                    recordedAt: $0.ts,
                    value: $0.stateOfCharge ?? $0.millivolts.map(Double.init) ?? 0,
                    metadata: metadata
                )
            },
            spo2: pending.spo2.map {
                RemoteSample(
                    recordedAt: $0.ts, value: Double($0.red),
                    metadata: [
                        "unit": "raw_adc",
                        "infrared": String($0.infrared),
                        "uncalibrated": "true",
                        "provenance": "strap_raw_optical",
                    ]
                )
            },
            skinTemp: pending.skinTemp.map {
                RemoteSample(
                    recordedAt: $0.ts, value: Double($0.raw),
                    metadata: [
                        "unit": "raw_adc", "uncalibrated": "true",
                        "provenance": "strap_raw_sensor",
                    ]
                )
            },
            respiration: pending.respiration.map {
                RemoteSample(
                    recordedAt: $0.ts, value: Double($0.raw),
                    metadata: [
                        "unit": "raw_adc", "uncalibrated": "true",
                        "provenance": "strap_raw_sensor",
                    ]
                )
            },
            steps: pending.steps.map {
                var metadata: [String: String] = [
                    "unit": "cumulative_counter",
                    "approximate": "true",
                    "provenance": "strap_counter",
                ]
                if let activityClass = $0.activityClass {
                    metadata["activity_class"] = String(activityClass)
                }
                return RemoteSample(
                    recordedAt: $0.ts, value: Double($0.counter), metadata: metadata
                )
            },
            events: pending.events.map {
                let kind = $0.kind.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemoteEvent(
                    eventId: stableIdentifier(
                        prefix: "event",
                        components: [deviceId, String($0.ts), $0.kind]
                    ),
                    recordedAt: $0.ts,
                    kind: boundedText(
                        kind.isEmpty ? "unknown_event" : kind,
                        maxCodePoints: 128
                    ),
                    metadata: boundedEventMetadata(payloadJSON: $0.payloadJSON)
                )
            }
        )
    }

    private static func mapDaily(
        _ row: DailyMetric,
        provenance: RemoteDerivedMetricProvenance
    ) -> [String: Double] {
        var metrics: [String: Double] = [:]
        add(row.totalSleepMin, as: "total_sleep_min", to: &metrics)
        add(canonicalEfficiency(row.efficiency), as: "efficiency", to: &metrics)
        add(row.deepMin, as: "deep_min", to: &metrics)
        add(row.remMin, as: "rem_min", to: &metrics)
        add(row.lightMin, as: "light_min", to: &metrics)
        add(row.disturbances.map(Double.init), as: "disturbances", to: &metrics)
        add(row.restingHr.map(Double.init), as: "resting_hr", to: &metrics)
        add(row.avgHrv, as: "avg_hrv", to: &metrics)
        add(row.recovery, as: "recovery", to: &metrics)
        add(row.strain, as: "effort", to: &metrics)
        if provenance == .officialReference {
            add(row.strain.map { $0 * 21 / 100 }, as: "whoop_strain", to: &metrics)
        }
        add(row.exerciseCount.map(Double.init), as: "exercise_count", to: &metrics)
        add(row.spo2Pct, as: "spo2_pct", to: &metrics)
        add(
            row.skinTempDevC,
            as: provenance == .officialReference ? "skin_temp_c" : "skin_temp_dev_c",
            to: &metrics
        )
        add(row.respRateBpm, as: "resp_rate_bpm", to: &metrics)
        add(row.steps.map(Double.init), as: "steps", to: &metrics)
        add(row.activeKcalEst, as: "active_kcal_est", to: &metrics)
        add(row.spo2Red.map(Double.init), as: "spo2_red_raw", to: &metrics)
        add(row.spo2Ir.map(Double.init), as: "spo2_ir_raw", to: &metrics)
        return metrics
    }

    private static func mapPlatformDaily(
        _ row: AppleDaily,
        to metrics: inout [String: Double]
    ) {
        add(row.steps.map(Double.init), as: "steps", to: &metrics)
        add(row.activeKcal, as: "active_kcal", to: &metrics)
        add(row.basalKcal, as: "basal_kcal", to: &metrics)
        add(row.vo2max, as: "vo2max", to: &metrics)
        add(row.avgHr.map(Double.init), as: "avg_hr", to: &metrics)
        add(row.maxHr.map(Double.init), as: "max_hr", to: &metrics)
        add(row.walkingHr.map(Double.init), as: "walking_hr", to: &metrics)
        add(row.weightKg, as: "weight_kg", to: &metrics)
    }

    /// Convert every `stagesJSON` shape written by Noop into stage totals in integer seconds.
    ///
    /// Historical/cache representations:
    /// - `{"light": 245, ...}` — imported aggregate durations in minutes.
    /// - `[{"stage":"deep","min":62}, ...]` — older imports/demo data in minutes.
    /// - `[{"start":..., "end":..., "stage":"rem"}, ...]` — timestamped local hypnograms.
    static func canonicalSleepStages(_ stagesJSON: String?) -> [String: Int]? {
        guard let stagesJSON,
              let data = stagesJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var seconds: [String: Double] = [:]
        func canonicalKey(_ raw: String) -> String? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "awake", "wake": return "awake"
            case "light": return "light"
            case "deep", "sws": return "deep"
            case "rem": return "rem"
            default: return nil
            }
        }
        func number(_ value: Any?) -> Double? {
            guard let value, !(value is Bool), let numeric = value as? NSNumber else { return nil }
            let result = numeric.doubleValue
            return result.isFinite ? result : nil
        }
        func accumulate(stage rawStage: String, durationSeconds: Double) {
            guard let stage = canonicalKey(rawStage),
                  durationSeconds.isFinite,
                  durationSeconds > 0 else { return }
            seconds[stage, default: 0] += min(durationSeconds, 172_800)
        }

        if let dictionary = object as? [String: Any] {
            // The only aggregate-object cache shape stores minutes.
            for (rawStage, value) in dictionary {
                if let minutes = number(value), minutes > 0 {
                    accumulate(stage: rawStage, durationSeconds: minutes * 60)
                }
            }
        } else if let segments = object as? [[String: Any]] {
            for segment in segments {
                guard let stage = segment["stage"] as? String else { continue }
                if let minutes = number(segment["min"]), minutes > 0 {
                    accumulate(stage: stage, durationSeconds: minutes * 60)
                } else if let start = number(segment["start"]),
                          let end = number(segment["end"]),
                          end > start {
                    accumulate(stage: stage, durationSeconds: end - start)
                }
            }
        }

        let canonical = seconds.compactMapValues { value -> Int? in
            guard value > 0 else { return nil }
            return min(Int(value.rounded()), 172_800)
        }
        return canonical.isEmpty ? nil : canonical
    }

    private static func add(
        _ value: Double?,
        as key: String,
        to metrics: inout [String: Double]
    ) {
        if let value, value.isFinite, abs(value) <= 1_000_000_000 {
            metrics[key] = value
        }
    }

    private static func canonicalEfficiency(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, min(value > 1 ? value / 100 : value, 1))
    }

    static func boundedText(_ value: String, maxCodePoints: Int) -> String {
        let scalarCount = value.unicodeScalars.count
        guard scalarCount > maxCodePoints else { return value }
        let suffix = " … [truncated by Noop sync]"
        let prefixCount = max(1, maxCodePoints - suffix.unicodeScalars.count)
        return String(value.unicodeScalars.prefix(prefixCount)) + suffix
    }

    /// Keep the complete event metadata object below the server's 16 KiB JSON limit. The separate
    /// marker makes loss explicit instead of leaving a payload that merely happens to look complete.
    static func boundedEventMetadata(payloadJSON: String) -> [String: String] {
        let maximumEncodedBytes = 15_500
        let complete = ["payload_json": payloadJSON, "provenance": "strap_event"]
        if encodedJSONSize(complete) <= maximumEncodedBytes { return complete }

        let characters = Array(payloadJSON)
        var lower = 0
        var upper = characters.count
        var best: [String: String] = [
            "payload_json": "",
            "payload_truncated": "true",
            "provenance": "strap_event",
        ]
        while lower <= upper {
            let midpoint = lower + (upper - lower) / 2
            let candidate = [
                "payload_json": String(characters.prefix(midpoint)),
                "payload_truncated": "true",
                "provenance": "strap_event",
            ]
            if encodedJSONSize(candidate) <= maximumEncodedBytes {
                best = candidate
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        return best
    }

    private static func encodedJSONSize(_ object: [String: String]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object).count) ?? Int.max
    }

    /// Stable SHA-256 over request content with the retry identity removed.
    ///
    /// `source.sent_at` and `batch_id` are intentionally excluded. A process restart naturally
    /// creates a new source timestamp, but must still find the identity persisted for an otherwise
    /// unchanged pending page.
    private static func contentFingerprint(_ envelope: RemoteSyncEnvelope) throws -> String {
        let source = RemoteSyncSource(
            deviceId: envelope.source.deviceId,
            sentAt: "retry-identity-excluded",
            appVersion: envelope.source.appVersion,
            platform: envelope.source.platform,
            device: envelope.source.device,
            metadata: envelope.source.metadata
        )
        let canonical = RemoteSyncEnvelope(
            batchId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            source: source,
            streams: envelope.streams,
            dailyMetrics: envelope.dailyMetrics,
            sleepSessions: envelope.sleepSessions,
            workouts: envelope.workouts,
            journal: envelope.journal
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        do {
            let bytes = try encoder.encode(canonical)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw RemoteSyncError.encoding(error.localizedDescription)
        }
    }

    private static func materialize(
        _ draft: RemoteSyncEnvelope,
        identity: RemoteBatchIdentity
    ) -> RemoteSyncEnvelope {
        let source = RemoteSyncSource(
            deviceId: draft.source.deviceId,
            sentAt: identity.sentAt,
            appVersion: draft.source.appVersion,
            platform: draft.source.platform,
            device: draft.source.device,
            metadata: draft.source.metadata
        )
        return RemoteSyncEnvelope(
            batchId: identity.batchId,
            source: source,
            streams: draft.streams,
            dailyMetrics: draft.dailyMetrics,
            sleepSessions: draft.sleepSessions,
            workouts: draft.workouts,
            journal: draft.journal
        )
    }

    /// Deterministic FNV-1a identifier for natural keys whose human labels may contain spaces,
    /// parentheses, Unicode, or exceed the API's bounded identifier grammar. The original label is
    /// still sent in its own field; only the id is compacted.
    private static func stableIdentifier(prefix: String, components: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in components.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)-\(String(format: "%016llx", hash))"
    }
}
