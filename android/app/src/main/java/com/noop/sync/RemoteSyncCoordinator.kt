package com.noop.sync

import com.noop.analytics.DetailedSleepStagePublication
import com.noop.analytics.SleepStageTotals
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.DailyHrvMethod
import com.noop.data.PairedDeviceRow
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import kotlin.math.roundToInt

/**
 * Wire identity for the current on-device Charge/Effort/Rest formulas.
 *
 * [CHARGE] is the cross-platform contract and must match Apple's
 * `NoopScoreAlgorithmRevision.charge`. Bump [METADATA] and [ID_SUFFIX] together so a formula revision
 * cannot overwrite derived rows or resume a cursor from an older remote namespace.
 */
internal object RemoteNoopAlgorithmRevision {
    const val CHARGE = "noop-charge-v2"
    const val EFFORT = "noop-effort-v2"
    const val REST = "noop-rest-v1"
    const val METADATA = "$CHARGE+$EFFORT+$REST"
    const val ID_SUFFIX = "cer-v2"
}

data class RemoteNamespace(
    /** Installation-scoped server ID; different phones never overwrite each other's observations. */
    val remoteDeviceId: String,
    /** Human/logical source before platform + installation scoping. */
    val logicalSourceId: String = remoteDeviceId,
    /** Existing Room deviceId from which this namespace reads. */
    val localDeviceId: String,
    val role: String,
    val pairedDeviceId: String,
    val appVersion: String,
    val installationId: String,
    val firmwareVersion: String? = null,
    val includeRaw: Boolean = false,
    val includeDerived: Boolean = true,
)

data class RemoteSyncRunResult(
    val uploadedRawRows: Int,
    val uploadedBatches: Int,
    val hasMoreRawRows: Boolean,
    val hasMoreDerivedRows: Boolean,
    val lastAck: RemoteSyncAck?,
)

/**
 * Bridges Room's durable outbox to the v1 API. Raw rows are acknowledged only after a matching 2xx.
 * Low-volume derived data is replayed over a bounded window because the server upserts natural keys;
 * this propagates local edits without a second schema migration/outbox.
 */
class RemoteSyncCoordinator(
    private val store: RemoteSyncDataStore,
    private val uploader: RemoteSyncUploading,
    private val identities: RemoteBatchIdentityStore,
    private val cursors: RemoteDerivedCursorStore,
) {
    suspend fun sync(
        namespace: RemoteNamespace,
        now: Instant = Instant.now(),
        derivedHistoryDays: Int = 400,
        derivedWindow: RemoteDerivedWindow? = null,
        retainDerivedCompletion: Boolean = false,
        limitPerStream: Int = 2_000,
        maxBatches: Int = 6,
    ): RemoteSyncRunResult {
        val batchLimit = maxBatches.coerceIn(1, 50)
        val window = derivedWindow ?: RemoteDerivedWindow.endingAt(now, derivedHistoryDays)
        if (!window.isValid) {
            throw RemoteSyncConfigurationException("The derived-data sync window is invalid.")
        }
        val paired = store.pairedDevice(namespace.pairedDeviceId)

        var rawCount = 0
        var batches = 0
        var lastAck: RemoteSyncAck? = null
        var sendDerived = namespace.includeDerived
        var derivedCursor = if (sendDerived) {
            cursors.derivedCursor(namespace.remoteDeviceId)
        } else {
            RemoteDerivedCursor()
        }
        if (derivedCursor.isComplete) {
            if (retainDerivedCompletion) {
                sendDerived = false
            } else {
                derivedCursor = RemoteDerivedCursor()
                cursors.clearDerivedCursor(namespace.remoteDeviceId)
            }
        }

        for (iteration in 0 until batchLimit) {
            val pending = if (namespace.includeRaw) {
                store.pending(namespace.localDeviceId, limitPerStream)
            } else {
                PendingRemoteStreams()
            }
            val derivedPage = if (sendDerived) {
                store.derived(
                    namespace.localDeviceId,
                    window.fromTs,
                    window.toTs,
                    window.fromDay,
                    window.toDay,
                    cursor = derivedCursor,
                    limit = DERIVED_PAGE_LIMIT,
                    includeDaily = !derivedCursor.started,
                )
            } else {
                RemoteDerivedRows()
            }
            val derivedPageIsFull = sendDerived && derivedPage.hasFullPage(DERIVED_PAGE_LIMIT)
            val draft = buildDraft(namespace, paired, pending, derivedPage)
            if (draft.isEmpty) {
                // An official-reference page can be entirely legacy Health Connect shadow rows.
                // Those rows are intentionally ineligible for upload, so advancing needs no server
                // acknowledgement. Natural-key cursors cannot shift when an earlier row is deleted.
                if (sendDerived && derivedPageIsFull) {
                    derivedCursor = derivedCursor.advancedBy(derivedPage)
                    cursors.setDerivedCursor(namespace.remoteDeviceId, derivedCursor)
                } else if (sendDerived) {
                    derivedCursor = derivedCursor.advancedBy(derivedPage)
                    if (retainDerivedCompletion) {
                        cursors.setDerivedCursor(
                            namespace.remoteDeviceId,
                            derivedCursor.markingComplete(),
                        )
                    } else {
                        cursors.clearDerivedCursor(namespace.remoteDeviceId)
                    }
                    sendDerived = false
                }
                if (pending.isEmpty && !sendDerived) break
                continue
            }

            val fingerprint = RemoteSyncJson.fingerprint(draft)
            val identity = identities.resolve(fingerprint, now)
            val ack = uploader.upload(RemoteEnvelope(identity.batchId, identity.sentAt, draft))
            if (!ack.batchId.equals(identity.batchId, ignoreCase = true)) {
                throw RemoteSyncException.BatchMismatch()
            }
            if (ack.status != "accepted") {
                throw RemoteSyncException.InvalidResponse(
                    "The server did not accept the sync batch.",
                )
            }

            // This order is deliberate. A crash after server acceptance but before/during the raw
            // acknowledgement or derived watermark retries an idempotent upsert. The batch identity
            // is cleared only after both applicable local durability steps succeed.
            store.acknowledge(namespace.localDeviceId, pending)
            rawCount += pending.count
            batches += 1
            lastAck = ack
            if (sendDerived && derivedPageIsFull) {
                derivedCursor = derivedCursor.advancedBy(derivedPage)
                cursors.setDerivedCursor(namespace.remoteDeviceId, derivedCursor)
            } else if (sendDerived) {
                derivedCursor = derivedCursor.advancedBy(derivedPage)
                if (retainDerivedCompletion) {
                    cursors.setDerivedCursor(
                        namespace.remoteDeviceId,
                        derivedCursor.markingComplete(),
                    )
                } else {
                    cursors.clearDerivedCursor(namespace.remoteDeviceId)
                }
                sendDerived = false
            }
            identities.acknowledge(fingerprint)

            // A completed derived page and/or full raw page loops to drain bounded history.
            if (pending.isEmpty && !sendDerived) break
        }

        return RemoteSyncRunResult(
            uploadedRawRows = rawCount,
            uploadedBatches = batches,
            hasMoreRawRows = namespace.includeRaw && store.hasPending(namespace.localDeviceId),
            hasMoreDerivedRows = namespace.includeDerived && sendDerived,
            lastAck = lastAck,
        )
    }

    internal fun buildDraft(
        namespace: RemoteNamespace,
        paired: PairedDeviceRow?,
        pending: PendingRemoteStreams,
        derived: RemoteDerivedRows,
    ): RemoteEnvelopeDraft {
        val eligibleDerived = eligibleDerivedRows(namespace, derived)
        val device = RemoteDeviceInfo(
            displayName = (paired?.nickname ?: paired?.let { "${it.brand} ${it.model}".trim() })
                ?.takeIf(String::isNotBlank)
                ?.takeCodePoints(128),
            model = paired?.model?.takeIf(String::isNotBlank)?.takeCodePoints(128),
            firmwareVersion = namespace.firmwareVersion
                ?.takeIf(String::isNotBlank)
                ?.takeCodePoints(64),
        )
        return RemoteEnvelopeDraft(
            source = RemoteSourceDraft(
                deviceId = namespace.remoteDeviceId,
                appVersion = namespace.appVersion,
                device = device,
                metadata = buildMap {
                    put("installation_id", namespace.installationId)
                    put("namespace", namespace.role)
                    put("logical_source_id", namespace.logicalSourceId)
                    put("paired_device_id", namespace.pairedDeviceId)
                    put("privacy", "explicit_opt_in")
                    put(
                        "score_provenance",
                        when (namespace.role) {
                            "strap_measured" -> "strap_measured"
                            "official_reference" -> "user_imported_whoop_export"
                            "noop_computed" -> "noop_transparent_algorithm"
                            "noop_journal" -> "user_entered_noop_journal"
                            "apple_health_import" -> "user_imported_apple_health"
                            "health_connect_import" -> "user_imported_health_connect"
                            "activity_file_import" -> "user_imported_activity_file"
                            "wearable_import" -> "user_imported_wearable"
                            else -> throw RemoteSyncConfigurationException(
                                "Unsupported remote namespace role: ${namespace.role}",
                            )
                        },
                    )
                    if (namespace.role == "official_reference") {
                        put("reference_filter", "whoop_export_signal_shape_v1")
                    }
                    if (namespace.role == "noop_computed") {
                        put("algorithm_revision", RemoteNoopAlgorithmRevision.METADATA)
                    }
                },
            ),
            streams = mapStreams(namespace.remoteDeviceId, pending),
            dailyMetrics = mapDaily(eligibleDerived, namespace.role),
            sleepSessions = eligibleDerived.sleep
                .asSequence()
                .filter {
                    val duration = it.endTs - it.effectiveStartTs
                    duration in 1..MAX_SESSION_DURATION_SECONDS
                }
                .map { row ->
                    RemoteSleepSession(
                        sessionId = RemoteIdentifiers.sleep(namespace.remoteDeviceId, row.startTs),
                        startTs = row.effectiveStartTs,
                        endTs = row.endTs,
                        efficiency = canonicalEfficiency(row.efficiency),
                        restingHr = row.restingHr,
                        avgHrv = row.avgHrv?.takeIf(Double::isFinite),
                        stages = stageSeconds(row.stagesJSON),
                        metadata = buildMap {
                            put("detected_start_ts", row.startTs.toString())
                            put("user_edited", row.userEdited.toString())
                            put("provenance", namespace.role)
                            row.avgHrv?.takeIf(Double::isFinite)?.let {
                                // Session-level HRV producers are RMSSD. Health Connect/Apple
                                // SDNN is represented only on typed daily rows.
                                put("hrv_method", DailyHrvMethod.RMSSD)
                            }
                            // Preserve the nullable pair together. Omitting both is the fail-closed
                            // representation for imports, legacy rows, and incomplete/corrupt evidence.
                            DetailedSleepStagePublication.exactRrWindowCounts(row)?.let { counts ->
                                put("rr_eligible_window_count", counts.eligible.toString())
                                put("rr_valid_window_count", counts.valid.toString())
                            }
                        },
                    )
                }
                .toList(),
            workouts = eligibleDerived.workouts
                .asSequence()
                .filter {
                    val duration = it.endTs - it.startTs
                    duration in 1..MAX_SESSION_DURATION_SECONDS
                }
                .map { row ->
                    val metrics = buildMap {
                        putFinite("duration_s", row.durationS)
                        putFinite("energy_kcal", row.energyKcal)
                        putFinite("avg_hr", row.avgHr?.toDouble())
                        putFinite("max_hr", row.maxHr?.toDouble())
                        putFinite("effort", row.strain)
                        if (namespace.role == "official_reference") {
                            putFinite("whoop_strain", row.strain?.times(WHOOP_STRAIN_SCALE))
                        }
                        putFinite("distance_m", row.distanceM)
                    }
                    RemoteWorkout(
                        workoutId = RemoteIdentifiers.workout(
                            namespace.remoteDeviceId,
                            row.startTs,
                            row.sport,
                        ),
                        startTs = row.startTs,
                        endTs = row.endTs,
                        sport = row.sport.ifBlank { "Workout" }.takeCodePoints(512),
                        source = row.source.takeIf(String::isNotBlank)?.takeCodePoints(256),
                        metrics = metrics,
                        metadata = buildMap {
                            put("provenance", namespace.role)
                            row.notes?.takeIf(String::isNotBlank)?.let { put("notes", it.take(2_000)) }
                            row.zonesJSON?.takeIf(String::isNotBlank)?.let {
                                put("zones_json", it.take(MAX_INLINE_JSON))
                            }
                        },
                    )
                }
                .toList(),
            journal = eligibleDerived.journal
                .asSequence()
                .filter { it.question.isNotBlank() }
                .map { row ->
                    RemoteJournalEntry(
                        day = row.day,
                        question = row.question.takeCodePoints(512),
                        answeredYes = row.answeredYes,
                        notes = row.notes?.takeCodePoints(100_000),
                        numericValue = row.numericValue?.takeIf(Double::isFinite),
                    )
                }
                .toList(),
        )
    }

    private fun mapStreams(deviceId: String, pending: PendingRemoteStreams): RemoteStreams =
        RemoteStreams(
            hr = pending.hr.map {
                RemoteSample(
                    it.ts,
                    it.bpm.toDouble(),
                    metadata = mapOf("unit" to "bpm", "provenance" to "strap_measured"),
                )
            },
            rr = pending.rr.map {
                RemoteSample(
                    it.ts,
                    it.rrMs.toDouble(),
                    metadata = mapOf(
                        "unit" to "ms",
                        "seq" to it.seq.toString(),
                        "provenance" to "strap_measured",
                    ),
                )
            },
            battery = pending.battery.map {
                val value = it.soc ?: it.mv?.toDouble() ?: 0.0
                buildMap<String, String> {
                    put("unit", if (it.soc != null) "percent" else if (it.mv != null) "millivolts" else "unknown")
                    put("provenance", "strap_measured")
                    it.mv?.let { mv -> put("millivolts", mv.toString()) }
                    it.charging?.let { charging -> put("charging", charging.toString()) }
                    if (it.soc == null && it.mv == null) put("missing_value", "true")
                }.let { metadata -> RemoteSample(it.ts, value, metadata = metadata) }
            },
            spo2 = pending.spo2.map {
                RemoteSample(
                    it.ts,
                    it.red.toDouble(),
                    metadata = mapOf(
                        "unit" to "raw_adc",
                        "infrared" to it.ir.toString(),
                        "uncalibrated" to "true",
                        "provenance" to "strap_raw_optical",
                    ),
                )
            },
            skinTemp = pending.skinTemp.map {
                RemoteSample(
                    it.ts,
                    it.raw.toDouble(),
                    metadata = mapOf(
                        "unit" to "raw_adc",
                        "uncalibrated" to "true",
                        "provenance" to "strap_raw_sensor",
                    ),
                )
            },
            respiration = pending.respiration.map {
                RemoteSample(
                    it.ts,
                    it.raw.toDouble(),
                    metadata = mapOf(
                        "unit" to "raw_adc",
                        "uncalibrated" to "true",
                        "provenance" to "strap_raw_sensor",
                    ),
                )
            },
            steps = pending.steps.map {
                RemoteSample(
                    it.ts,
                    it.counter.toDouble(),
                    metadata = buildMap {
                        put("unit", "cumulative_counter")
                        put("approximate", "true")
                        put("provenance", "strap_counter")
                        it.activityClass?.let { value -> put("activity_class", value.toString()) }
                    },
                )
            },
            events = pending.events.map {
                RemoteEvent(
                    eventId = RemoteIdentifiers.event(deviceId, it.ts, it.kind),
                    recordedAt = it.ts,
                    kind = it.kind
                        .takeIf(String::isNotBlank)
                        ?.takeCodePoints(128)
                        ?: "unknown",
                    metadata = boundedEventMetadata(it.payloadJSON, it.kind.isBlank()),
                )
            },
        )

    /** Keep the fully JSON-escaped metadata under the server's 16 KiB object ceiling. */
    private fun boundedEventMetadata(
        payload: String,
        originalKindBlank: Boolean,
    ): Map<String, String> {
        val payloadCodePoints = payload.codePointCount(0, payload.length)
        var low = 0
        var high = minOf(payloadCodePoints, MAX_INLINE_JSON_CODE_POINTS)
        var best = ""
        while (low <= high) {
            val middle = (low + high) ushr 1
            val candidate = payload.takeCodePoints(middle)
            val truncated = middle < payloadCodePoints
            val metadata = eventMetadata(candidate, truncated, originalKindBlank)
            val encodedBytes = JSONObject(metadata).toString()
                .toByteArray(StandardCharsets.UTF_8)
                .size
            if (encodedBytes <= MAX_METADATA_BYTES) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return eventMetadata(
            best,
            best.codePointCount(0, best.length) < payloadCodePoints,
            originalKindBlank,
        )
    }

    private fun eventMetadata(
        payload: String,
        truncated: Boolean,
        originalKindBlank: Boolean,
    ): Map<String, String> = buildMap {
        put("payload_json", payload)
        put("provenance", "strap_event")
        if (truncated) put("payload_truncated", "true")
        if (originalKindBlank) put("original_kind_blank", "true")
    }

    /**
     * `my-whoop` predates source-separated imports and can also contain sparse Health Connect
     * shadows. Only rows carrying WHOOP-export-specific score/stage shape are allowed into the
     * official comparison namespace. It is safer to omit an ambiguous sparse row than mislabel it.
     */
    private fun eligibleDerivedRows(
        namespace: RemoteNamespace,
        rows: RemoteDerivedRows,
    ): RemoteDerivedRows {
        if (namespace.role == "noop_journal") {
            return RemoteDerivedRows(journal = rows.journal)
        }
        if (namespace.role != "official_reference") return rows
        return rows.copy(
            daily = rows.daily.filter { row ->
                row.efficiency != null ||
                    row.deepMin != null ||
                    row.remMin != null ||
                    row.lightMin != null ||
                    row.disturbances != null ||
                    row.recovery != null ||
                    row.strain != null
            },
            sleep = rows.sleep.filter { row ->
                row.efficiency != null || row.restingHr != null || row.avgHrv != null
            },
            workouts = rows.workouts.filter { it.source == OFFICIAL_WHOOP_SOURCE },
        )
    }

    private fun RemoteDerivedRows.hasFullPage(limit: Int): Boolean =
        sleep.size >= limit || workouts.size >= limit || journal.size >= limit

    private fun RemoteDerivedCursor.advancedBy(rows: RemoteDerivedRows): RemoteDerivedCursor {
        val lastWorkout = rows.workouts.lastOrNull()
        val lastJournal = rows.journal.lastOrNull()
        return copy(
            started = true,
            sleepStartTs = rows.sleep.lastOrNull()?.startTs ?: sleepStartTs,
            workoutStartTs = lastWorkout?.startTs ?: workoutStartTs,
            workoutSport = lastWorkout?.sport ?: workoutSport,
            journalDay = lastJournal?.day ?: journalDay,
            journalQuestion = lastJournal?.question ?: journalQuestion,
        )
    }

    private fun mapDaily(
        rows: RemoteDerivedRows,
        namespaceRole: String,
    ): Map<String, Map<String, Double>> {
        val result = linkedMapOf<String, MutableMap<String, Double>>()
        rows.daily.forEach { row ->
            val metrics = result.getOrPut(row.day) { linkedMapOf() }
            mapDailyRow(row, metrics, namespaceRole)
        }
        rows.platformDaily.forEach { row ->
            val metrics = result.getOrPut(row.day) { linkedMapOf() }
            mapPlatformDailyRow(row, metrics)
        }
        return result.mapValues { (_, values) -> values.toMap() }
    }

    private fun mapDailyRow(
        row: DailyMetric,
        out: MutableMap<String, Double>,
        namespaceRole: String,
    ) {
        out.putFinite("total_sleep_min", row.totalSleepMin)
        out.putFinite("efficiency", canonicalEfficiency(row.efficiency))
        out.putFinite("deep_min", row.deepMin)
        out.putFinite("rem_min", row.remMin)
        out.putFinite("light_min", row.lightMin)
        out.putFinite("disturbances", row.disturbances?.toDouble())
        out.putFinite("resting_hr", row.restingHr?.toDouble())
        out.putFinite("avg_hrv", row.avgHrv)
        when (DailyHrvMethod.normalized(row.hrvMethod)) {
            DailyHrvMethod.RMSSD -> out.putFinite("avg_hrv_rmssd", row.avgHrv)
            DailyHrvMethod.SDNN -> out.putFinite("avg_hrv_sdnn", row.avgHrv)
            else -> Unit
        }
        out.putFinite("recovery", row.recovery)
        out.putFinite("effort", row.strain)
        if (namespaceRole == "official_reference") {
            out.putFinite("whoop_strain", row.strain?.times(WHOOP_STRAIN_SCALE))
        }
        out.putFinite("exercise_count", row.exerciseCount?.toDouble())
        out.putFinite("spo2_pct", row.spo2Pct)
        out.putFinite(
            if (namespaceRole == "official_reference") "skin_temp_c" else "skin_temp_dev_c",
            row.skinTempDevC,
        )
        out.putFinite("resp_rate_bpm", row.respRateBpm)
        out.putFinite("steps", row.steps?.toDouble())
        out.putFinite("active_kcal_est", row.activeKcalEst)
        out.putFinite("spo2_red_raw", row.spo2Red?.toDouble())
        out.putFinite("spo2_ir_raw", row.spo2Ir?.toDouble())
    }

    private fun mapPlatformDailyRow(row: AppleDaily, out: MutableMap<String, Double>) {
        out.putFinite("steps", row.steps?.toDouble())
        out.putFinite("active_kcal", row.activeKcal)
        out.putFinite("basal_kcal", row.basalKcal)
        out.putFinite("vo2max", row.vo2max)
        out.putFinite("avg_hr", row.avgHr?.toDouble())
        out.putFinite("max_hr", row.maxHr?.toDouble())
        out.putFinite("walking_hr", row.walkingHr?.toDouble())
        out.putFinite("weight_kg", row.weightKg)
    }

    private fun stageSeconds(stagesJSON: String?): Map<String, Int> {
        val totals = SleepStageTotals.minutes(stagesJSON) ?: return emptyMap()
        return buildMap {
            putPositive("awake", totals.awake)
            putPositive("light", totals.light)
            putPositive("deep", totals.deep)
            putPositive("rem", totals.rem)
        }
    }

    private fun MutableMap<String, Int>.putPositive(key: String, minutes: Double) {
        val seconds = (minutes * 60.0).roundToInt()
        if (seconds > 0) put(key, seconds)
    }

    private fun canonicalEfficiency(value: Double?): Double? {
        val finite = value?.takeIf(Double::isFinite) ?: return null
        return (if (finite > 1.0) finite / 100.0 else finite).coerceIn(0.0, 1.0)
    }

    private fun MutableMap<String, Double>.putFinite(key: String, value: Double?) {
        if (value != null && value.isFinite()) put(key, value)
    }

    private fun String.takeCodePoints(maximum: Int): String {
        if (codePointCount(0, length) <= maximum) return this
        return substring(0, offsetByCodePoints(0, maximum))
    }

    companion object {
        private const val MAX_INLINE_JSON = 8_000
        private const val MAX_INLINE_JSON_CODE_POINTS = 8_000
        private const val MAX_METADATA_BYTES = 16_384
        private const val MAX_SESSION_DURATION_SECONDS = 2L * 86_400L
        private const val DERIVED_PAGE_LIMIT = 5_000
        private const val OFFICIAL_WHOOP_SOURCE = "my-whoop"
        private const val WHOOP_STRAIN_SCALE = 21.0 / 100.0
    }
}
