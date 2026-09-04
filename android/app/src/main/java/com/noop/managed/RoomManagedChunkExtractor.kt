package com.noop.managed

import androidx.sqlite.db.SimpleSQLiteQuery
import com.noop.data.ManagedSyncSourceEntity
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.math.BigDecimal
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Base64

class RoomManagedChunkExtractor(
    private val database: WhoopDatabase,
    private val clock: () -> Long = System::currentTimeMillis,
) : ManagedChunkExtracting {
    private val dao get() = database.whoopDao()
    private val state get() = database.managedSyncDao()

    override suspend fun nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Long,
        beforeMs: Long,
    ): Long? {
        require(atOrAfterMs >= 0L && beforeMs > atOrAfterMs)
        remember(source)
        val expressions = when (dataClass) {
            "essential_timeseries" -> listOf(
                "hrSample" to "ts * 1000",
                "rrInterval" to "ts * 1000",
                "event" to "ts * 1000",
                "battery" to "ts * 1000",
                "stepSample" to "ts * 1000",
                "ppgHrSample" to "ts * 1000",
                "bodyMeasurement" to "measuredAt * 1000",
            )
            "raw_auxiliary" -> listOf(
                "skinTempSample" to "ts * 1000",
                "respSample" to "ts * 1000",
                "sleepStateSample" to "ts * 1000",
            )
            "raw_ppg" -> listOf(
                "spo2Sample" to "ts * 1000",
                "ppgWaveformSample" to "ts * 1000",
            )
            "raw_motion" -> listOf(
                "gravitySample" to "ts * 1000",
                "rawImuSample" to "ts * 1000",
            )
            "derived_summaries" -> listOf(
                "dailyMetric" to "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000",
                "appleDaily" to "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000",
                "metricSeries" to "CAST(strftime('%s', day || 'T00:00:00Z') AS INTEGER) * 1000",
                "sleepSession" to "startTs * 1000",
                "workout" to "startTs * 1000",
                "liveSession" to "startTs * 1000",
            )
            else -> throw IllegalArgumentException("Unsupported managed data class")
        }
        val parts = expressions.joinToString(" UNION ALL ") { (table, timestamp) ->
            "SELECT $timestamp AS eventAtMs FROM $table " +
                "WHERE deviceId = ? AND $timestamp >= ? AND $timestamp < ?"
        }
        val args = buildList<Any> {
            repeat(expressions.size) {
                add(source.localSourceId)
                add(atOrAfterMs)
                add(beforeMs)
            }
        }.toTypedArray()
        return withContext(Dispatchers.IO) {
            database.openHelper.readableDatabase.query(
                SimpleSQLiteQuery("SELECT MIN(eventAtMs) FROM ($parts)", args),
            ).use { cursor ->
                if (!cursor.moveToFirst() || cursor.isNull(0)) null else cursor.getLong(0)
            }
        }
    }

    override suspend fun streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
    ): List<ManagedChunkStreamPayload> {
        remember(source)
        val from = (window.startMs + 999) / 1_000
        val to = (window.endExclusiveMs - 1) / 1_000
        return when (dataClass) {
            "essential_timeseries" -> essential(source.localSourceId, from, to)
            "raw_auxiliary" -> auxiliary(source.localSourceId, from, to)
            "raw_ppg" -> ppg(source.localSourceId, from, to)
            "raw_motion" -> motion(source.localSourceId, from, to)
            "derived_summaries" -> derived(
                source.localSourceId,
                from,
                to,
                utcDay(window.startMs),
                utcDay(window.endExclusiveMs - 1),
            )
            else -> throw IllegalArgumentException("Unsupported managed data class")
        }
    }

    private suspend fun remember(source: ManagedSourceDescriptor) {
        val now = clock()
        val existing = state.source(source.localSourceId)
        state.upsertSource(
            ManagedSyncSourceEntity(
                sourceId = source.sourceId.toString(),
                localSourceId = source.localSourceId,
                sourceKind = source.sourceKind,
                platform = "android",
                logicalSourceHash = source.logicalSourceHash,
                createdAtMs = existing?.createdAtMs ?: now,
                updatedAtMs = now,
            ),
        )
    }

    private suspend fun essential(
        source: String,
        from: Long,
        to: Long,
    ): List<ManagedChunkStreamPayload> {
        val hr = bounded(dao.rawHrSamples(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), int(it.bpm), nil(), string("sensor"))
        }
        val rr = bounded(dao.managedRrIntervals(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                int(it.rrMs),
                int(it.seq),
                it.ord?.let(::int) ?: nil(),
                it.srcChannel?.let(::int) ?: nil(),
                bool(it.tsSuspect == 1),
            )
        }
        val battery = bounded(dao.batterySamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                it.soc?.let(::number) ?: nil(),
                it.mv?.let(::int) ?: nil(),
                it.charging?.let(::bool) ?: nil(),
            )
        }
        val derivedHr = bounded(dao.ppgHrSamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                number(it.bpm.toDouble()),
                number(it.conf),
                string("local_autocorrelation_v1"),
            )
        }
        val events = bounded(dao.events(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), string(it.kind), string(it.payloadJSON))
        }
        val steps = bounded(dao.stepSamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                int(it.counter),
                it.activityClass?.let(::int) ?: nil(),
            )
        }
        val body = bounded(dao.bodyMeasurements(source, from, to, LIMIT)).map {
            row(
                int(it.measuredAt * 1_000),
                number(it.weightKg),
                it.bmi?.let(::number) ?: nil(),
                it.heightCm?.let(::number) ?: nil(),
                int(it.userId),
                string(it.source),
            )
        }
        return listOf(
            stream("heart_rate", listOf("event_at_ms", "bpm", "quality", "provenance"), hr),
            stream(
                "rr_intervals",
                listOf(
                    "event_at_ms",
                    "rr_ms",
                    "seq",
                    "ord",
                    "source_channel",
                    "timestamp_suspect",
                ),
                rr,
            ),
            stream(
                "battery",
                listOf("event_at_ms", "percent", "millivolts", "charging"),
                battery,
            ),
            stream(
                "derived_heart_rate",
                listOf("event_at_ms", "bpm", "confidence", "algorithm_revision"),
                derivedHr,
            ),
            stream(
                "device_events",
                listOf("event_at_ms", "kind", "payload_json"),
                events,
            ),
            stream(
                "step_counter",
                listOf("event_at_ms", "counter", "activity_class"),
                steps,
            ),
            stream(
                "body_measurement",
                listOf(
                    "event_at_ms",
                    "weight_kg",
                    "bmi",
                    "height_cm",
                    "user_id",
                    "source",
                ),
                body,
            ),
        )
    }

    private suspend fun auxiliary(
        source: String,
        from: Long,
        to: Long,
    ): List<ManagedChunkStreamPayload> {
        val skin = bounded(dao.skinTempSamples(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), int(it.raw))
        }
        val respiration = bounded(dao.respSamples(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), int(it.raw))
        }
        val sleep = bounded(dao.sleepStateSamples(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), int(it.state))
        }
        return listOf(
            stream("skin_temperature_adc", listOf("event_at_ms", "adc"), skin),
            stream("respiration_adc", listOf("event_at_ms", "adc"), respiration),
            stream("sleep_state", listOf("event_at_ms", "state_code"), sleep),
        )
    }

    private suspend fun ppg(
        source: String,
        from: Long,
        to: Long,
    ): List<ManagedChunkStreamPayload> {
        val optical = bounded(dao.spo2Samples(source, from, to, LIMIT)).map {
            row(int(it.ts * 1_000), int(it.red), int(it.ir))
        }
        val waveform = bounded(dao.ppgWaveformSamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                number(24.0),
                int(it.samples.size / 2),
                string(Base64.getEncoder().encodeToString(it.samples)),
            )
        }
        return listOf(
            stream(
                "spo2_optical_adc",
                listOf("event_at_ms", "red_adc", "infrared_adc"),
                optical,
            ),
            stream(
                "ppg_waveform",
                listOf("event_at_ms", "sample_rate_hz", "sample_count", "samples_base64"),
                waveform,
            ),
        )
    }

    private suspend fun motion(
        source: String,
        from: Long,
        to: Long,
    ): List<ManagedChunkStreamPayload> {
        val gravity = bounded(dao.gravitySamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                number(it.x),
                number(it.y),
                number(it.z),
            )
        }
        val imu = bounded(dao.rawImuSamples(source, from, to, LIMIT)).map {
            row(
                int(it.ts * 1_000),
                number(100.0),
                int(it.samples.size / 12),
                string("ax_ay_az_gx_gy_gz"),
                string(Base64.getEncoder().encodeToString(it.samples)),
            )
        }
        return listOf(
            stream("gravity", listOf("event_at_ms", "x_g", "y_g", "z_g"), gravity),
            stream(
                "raw_imu",
                listOf(
                    "event_at_ms",
                    "sample_rate_hz",
                    "sample_count",
                    "axis_order",
                    "samples_base64",
                ),
                imu,
            ),
        )
    }

    private suspend fun derived(
        source: String,
        from: Long,
        to: Long,
        fromDay: String,
        toDay: String,
    ): List<ManagedChunkStreamPayload> {
        val daily = bounded(dao.dailyMetricsRange(source, fromDay, toDay)).map {
            val event = utcDayMilliseconds(it.day)
            row(
                int(event),
                string(it.day),
                string(source),
                string(
                    payload(
                        "record_type" to "daily_metric",
                        "total_sleep_min" to it.totalSleepMin,
                        "efficiency" to it.efficiency,
                        "deep_min" to it.deepMin,
                        "rem_min" to it.remMin,
                        "light_min" to it.lightMin,
                        "disturbances" to it.disturbances,
                        "resting_hr" to it.restingHr,
                        "avg_hrv" to it.avgHrv,
                        "recovery" to it.recovery,
                        "strain" to it.strain,
                        "exercise_count" to it.exerciseCount,
                        "spo2_pct" to it.spo2Pct,
                        "skin_temp_dev_c" to it.skinTempDevC,
                        "resp_rate_bpm" to it.respRateBpm,
                        "steps" to it.steps,
                        "active_kcal_est" to it.activeKcalEst,
                        "spo2_red" to it.spo2Red,
                        "spo2_ir" to it.spo2Ir,
                        "hrv_method" to it.hrvMethod,
                    ),
                ),
                int(event),
                bool(false),
            )
        }
        val platform = bounded(dao.appleDaily(source, fromDay, toDay)).map {
            val event = utcDayMilliseconds(it.day)
            row(
                int(event),
                string(it.day),
                string(source),
                string(
                    payload(
                        "record_type" to "platform_daily",
                        "steps" to it.steps,
                        "active_kcal" to it.activeKcal,
                        "basal_kcal" to it.basalKcal,
                        "vo2max" to it.vo2max,
                        "avg_hr" to it.avgHr,
                        "max_hr" to it.maxHr,
                        "walking_hr" to it.walkingHr,
                        "weight_kg" to it.weightKg,
                    ),
                ),
                int(event),
                bool(false),
            )
        }
        val metrics = bounded(dao.managedMetricSeries(source, fromDay, toDay)).map {
            val event = utcDayMilliseconds(it.day)
            row(
                int(event),
                string(it.day),
                string(it.key),
                number(it.value),
                string(source),
                int(event),
                bool(false),
            )
        }
        val sleep = bounded(dao.sleepSessions(source, from, to, LIMIT)).map {
            row(
                int(it.startTs * 1_000),
                string("$source:${it.startTs}"),
                int(it.endTs * 1_000),
                string(
                    payload(
                        "efficiency" to it.efficiency,
                        "resting_hr" to it.restingHr,
                        "avg_hrv" to it.avgHrv,
                        "stages_json" to it.stagesJSON,
                        "user_edited" to it.userEdited,
                        "start_ts_adjusted" to it.startTsAdjusted,
                        "motion_json" to it.motionJSON,
                        "sleep_state_json" to it.sleepStateJSON,
                        "gravity_sparse" to null,
                        "rr_eligible_window_count" to it.rrEligibleWindowCount,
                        "rr_valid_window_count" to it.rrValidWindowCount,
                    ),
                ),
                int(it.startTs * 1_000),
                bool(false),
            )
        }
        val workouts = bounded(dao.workouts(source, from, to, LIMIT)).map {
            row(
                int(it.startTs * 1_000),
                string("$source:${it.startTs}:${it.sport}"),
                int(it.endTs * 1_000),
                string(
                    payload(
                        "sport" to it.sport,
                        "source" to it.source,
                        "duration_s" to it.durationS,
                        "energy_kcal" to it.energyKcal,
                        "avg_hr" to it.avgHr,
                        "max_hr" to it.maxHr,
                        "strain" to it.strain,
                        "distance_m" to it.distanceM,
                        "zones_json" to it.zonesJSON,
                        "notes" to it.notes,
                        "steps" to it.steps,
                    ),
                ),
                int(it.startTs * 1_000),
                bool(false),
            )
        }
        val live = bounded(dao.managedLiveSessions(source, from, to, LIMIT)).map {
            row(
                int(it.startTs * 1_000),
                string("$source:${it.startTs}"),
                it.endTs?.let { end -> int(end * 1_000) } ?: nil(),
                string(
                    payload(
                        "charge_at_start" to it.chargeAtStart,
                        "floor_bpm" to it.floorBpm,
                        "ceiling_bpm" to it.ceilingBpm,
                        "in_band_sec" to it.inBandSec,
                        "below_sec" to it.belowSec,
                        "above_sec" to it.aboveSec,
                        "push_count" to it.pushCount,
                        "ease_count" to it.easeCount,
                        "hr_source" to it.hrSource,
                    ),
                ),
                int(it.startTs * 1_000),
                bool(false),
            )
        }
        val dailyRows = (daily + platform).sortedWith(
            compareBy<List<ManagedJsonValue>>(
                { (it[0] as ManagedJsonValue.IntegerValue).value },
                { (it[3] as ManagedJsonValue.StringValue).value },
            ),
        )
        return listOf(
            stream(
                "daily_metrics",
                listOf(
                    "event_at_ms",
                    "day",
                    "source_id",
                    "payload_json",
                    "updated_at_ms",
                    "deleted",
                ),
                dailyRows,
            ),
            stream(
                "metric_series",
                listOf(
                    "event_at_ms",
                    "day",
                    "metric_key",
                    "value",
                    "source_id",
                    "updated_at_ms",
                    "deleted",
                ),
                metrics,
            ),
            stream(
                "sleep_summary",
                listOf(
                    "event_at_ms",
                    "record_id",
                    "end_at_ms",
                    "payload_json",
                    "updated_at_ms",
                    "deleted",
                ),
                sleep,
            ),
            stream(
                "workout_summary",
                listOf(
                    "event_at_ms",
                    "record_id",
                    "end_at_ms",
                    "payload_json",
                    "updated_at_ms",
                    "deleted",
                ),
                workouts,
            ),
            stream(
                "live_session",
                listOf(
                    "event_at_ms",
                    "record_id",
                    "end_at_ms",
                    "payload_json",
                    "updated_at_ms",
                    "deleted",
                ),
                live,
            ),
        )
    }

    private fun payload(vararg values: Pair<String, Any?>): String = buildString {
        append('{')
        values.sortedBy { it.first }.forEachIndexed { index, (key, value) ->
            if (index > 0) append(',')
            append(JSONObject.quote(key)).append(':')
            appendPayloadValue(value)
        }
        append('}')
    }

    private fun StringBuilder.appendPayloadValue(value: Any?) {
        when (value) {
            null -> append("null")
            is String -> append(JSONObject.quote(value))
            is Boolean -> append(if (value) "true" else "false")
            is Byte, is Short, is Int, is Long -> append(value)
            is Float -> appendPayloadNumber(value.toDouble())
            is Double -> appendPayloadNumber(value)
            else -> throw IllegalArgumentException("Unsupported managed payload value")
        }
    }

    private fun StringBuilder.appendPayloadNumber(value: Double) {
        require(value.isFinite())
        append(BigDecimal.valueOf(value).stripTrailingZeros().toPlainString())
    }

    private fun utcDay(milliseconds: Long): String =
        Instant.ofEpochMilli(milliseconds).atZone(ZoneOffset.UTC).toLocalDate().toString()

    private fun utcDayMilliseconds(day: String): Long =
        LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

    private fun <T> bounded(rows: List<T>): List<T> {
        if (rows.size > MAX_ROWS_PER_STREAM) {
            throw IllegalStateException("Managed sync window is too dense")
        }
        return rows
    }

    private fun stream(
        key: String,
        columns: List<String>,
        rows: List<List<ManagedJsonValue>>,
    ) = ManagedChunkStreamPayload(key, columns, rows)

    private fun row(vararg values: ManagedJsonValue): List<ManagedJsonValue> = values.toList()
    private fun int(value: Long) = ManagedJsonValue.IntegerValue(value)
    private fun int(value: Int) = ManagedJsonValue.IntegerValue(value.toLong())
    private fun number(value: Double) = ManagedJsonValue.NumberValue(value)
    private fun string(value: String) = ManagedJsonValue.StringValue(value)
    private fun bool(value: Boolean) = ManagedJsonValue.BooleanValue(value)
    private fun nil() = ManagedJsonValue.NullValue

    companion object {
        private const val MAX_ROWS_PER_STREAM = 100_000
        private const val LIMIT = MAX_ROWS_PER_STREAM + 1
    }
}
