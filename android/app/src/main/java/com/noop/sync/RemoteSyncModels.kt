package com.noop.sync

import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale

/** Wire models for the self-hosted `/v1/sync` API. Keys are encoded explicitly in snake_case. */
data class RemoteDeviceInfo(
    val displayName: String? = null,
    val model: String? = null,
    val firmwareVersion: String? = null,
    val hardwareRevision: String? = null,
)

data class RemoteSourceDraft(
    val deviceId: String,
    val appVersion: String? = null,
    val platform: String = "android",
    val device: RemoteDeviceInfo = RemoteDeviceInfo(),
    val metadata: Map<String, String> = emptyMap(),
)

data class RemoteSample(
    val recordedAt: Long,
    val value: Double,
    val quality: Double? = null,
    val metadata: Map<String, String> = emptyMap(),
)

data class RemoteEvent(
    val eventId: String,
    val recordedAt: Long,
    /** Original decoder label. The server stores this verbatim; no lossy normalization occurs. */
    val kind: String,
    val value: Double? = null,
    val metadata: Map<String, String> = emptyMap(),
)

data class RemoteStreams(
    val hr: List<RemoteSample> = emptyList(),
    val rr: List<RemoteSample> = emptyList(),
    val battery: List<RemoteSample> = emptyList(),
    val spo2: List<RemoteSample> = emptyList(),
    val skinTemp: List<RemoteSample> = emptyList(),
    val respiration: List<RemoteSample> = emptyList(),
    val steps: List<RemoteSample> = emptyList(),
    val events: List<RemoteEvent> = emptyList(),
) {
    val isEmpty: Boolean
        get() = hr.isEmpty() && rr.isEmpty() && battery.isEmpty() && spo2.isEmpty() &&
            skinTemp.isEmpty() && respiration.isEmpty() && steps.isEmpty() && events.isEmpty()

    val count: Int
        get() = hr.size + rr.size + battery.size + spo2.size + skinTemp.size +
            respiration.size + steps.size + events.size
}

data class RemoteSleepSession(
    val sessionId: String,
    val startTs: Long,
    val endTs: Long,
    /** Canonical fraction in 0...1. */
    val efficiency: Double? = null,
    val restingHr: Int? = null,
    val avgHrv: Double? = null,
    /** Per-stage duration in whole seconds. */
    val stages: Map<String, Int> = emptyMap(),
    val metadata: Map<String, String> = emptyMap(),
)

data class RemoteWorkout(
    val workoutId: String,
    val startTs: Long,
    val endTs: Long,
    val sport: String,
    val source: String? = null,
    val metrics: Map<String, Double> = emptyMap(),
    val metadata: Map<String, String> = emptyMap(),
)

data class RemoteJournalEntry(
    val day: String,
    val question: String,
    val answeredYes: Boolean,
    val notes: String? = null,
    val numericValue: Double? = null,
)

/**
 * Everything in a sync request except its retry identity. Keeping this immutable makes the content
 * fingerprint stable; [RemoteBatchIdentityStore] then reuses the same UUID and sent_at after a crash.
 */
data class RemoteEnvelopeDraft(
    val source: RemoteSourceDraft,
    val streams: RemoteStreams = RemoteStreams(),
    val dailyMetrics: Map<String, Map<String, Double>> = emptyMap(),
    val sleepSessions: List<RemoteSleepSession> = emptyList(),
    val workouts: List<RemoteWorkout> = emptyList(),
    val journal: List<RemoteJournalEntry> = emptyList(),
) {
    val isEmpty: Boolean
        get() = streams.isEmpty && dailyMetrics.isEmpty() && sleepSessions.isEmpty() &&
            workouts.isEmpty() && journal.isEmpty()
}

data class RemoteBatchIdentity(val batchId: String, val sentAt: String)

data class RemoteEnvelope(
    val batchId: String,
    val sentAt: String,
    val draft: RemoteEnvelopeDraft,
)

data class RemoteSyncAck(
    val batchId: String,
    val status: String,
    val duplicate: Boolean,
    val counts: Map<String, Int>,
)

data class RemoteStatus(val status: String)

/** Explicit, deterministic JSON codec shared by production and plain-JVM contract tests. */
object RemoteSyncJson {
    const val SCHEMA_VERSION = 1

    fun encode(envelope: RemoteEnvelope): String {
        val root = encodeDraft(envelope.draft)
        root.put("batch_id", envelope.batchId)
        root.getJSONObject("source").put("sent_at", envelope.sentAt)
        return root.toString()
    }

    /**
     * Hash all request content except the retry identity (`batch_id`, `source.sent_at`). The caller
     * persists those two small values against this fingerprint, avoiding a large duplicate outbox.
     */
    fun fingerprint(draft: RemoteEnvelopeDraft): String {
        val bytes = encodeDraft(draft).toString().toByteArray(StandardCharsets.UTF_8)
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { "%02x".format(Locale.US, it.toInt() and 0xff) }
    }

    private fun encodeDraft(draft: RemoteEnvelopeDraft): JSONObject = JSONObject()
        .put("schema_version", SCHEMA_VERSION)
        .put("source", source(draft.source))
        .put("streams", streams(draft.streams))
        .put("daily_metrics", metricDays(draft.dailyMetrics))
        .put("sleep_sessions", array(draft.sleepSessions.map(::sleep)))
        .put("workouts", array(draft.workouts.map(::workout)))
        .put("journal", array(draft.journal.map(::journal)))

    private fun source(source: RemoteSourceDraft): JSONObject = JSONObject()
        .put("device_id", source.deviceId)
        .putIfNotNull("app_version", source.appVersion)
        .put("platform", source.platform)
        .put(
            "device",
            JSONObject()
                .putIfNotNull("display_name", source.device.displayName)
                .putIfNotNull("model", source.device.model)
                .putIfNotNull("firmware_version", source.device.firmwareVersion)
                .putIfNotNull("hardware_revision", source.device.hardwareRevision),
        )
        .put("metadata", stringMap(source.metadata))

    private fun streams(streams: RemoteStreams): JSONObject = JSONObject()
        .put("hr", samples(streams.hr))
        .put("rr", samples(streams.rr))
        .put("battery", samples(streams.battery))
        .put("spo2", samples(streams.spo2))
        .put("skin_temp", samples(streams.skinTemp))
        .put("respiration", samples(streams.respiration))
        .put("steps", samples(streams.steps))
        .put("events", array(streams.events.map(::event)))

    private fun samples(samples: List<RemoteSample>): JSONArray = array(samples.map { sample ->
        JSONObject()
            .put("recorded_at", sample.recordedAt)
            .put("value", sample.value)
            .putIfNotNull("quality", sample.quality)
            .put("metadata", stringMap(sample.metadata))
    })

    private fun event(event: RemoteEvent): JSONObject = JSONObject()
        .put("event_id", event.eventId)
        .put("recorded_at", event.recordedAt)
        .put("kind", event.kind)
        .putIfNotNull("value", event.value)
        .put("metadata", stringMap(event.metadata))

    private fun sleep(sleep: RemoteSleepSession): JSONObject = JSONObject()
        .put("session_id", sleep.sessionId)
        .put("start_ts", sleep.startTs)
        .put("end_ts", sleep.endTs)
        .putIfNotNull("efficiency", sleep.efficiency)
        .putIfNotNull("resting_hr", sleep.restingHr)
        .putIfNotNull("avg_hrv", sleep.avgHrv)
        .put("stages", intMap(sleep.stages))
        .put("metadata", stringMap(sleep.metadata))

    private fun workout(workout: RemoteWorkout): JSONObject = JSONObject()
        .put("workout_id", workout.workoutId)
        .put("start_ts", workout.startTs)
        .put("end_ts", workout.endTs)
        .put("sport", workout.sport)
        .putIfNotNull("source", workout.source)
        .put("metrics", doubleMap(workout.metrics))
        .put("metadata", stringMap(workout.metadata))

    private fun journal(entry: RemoteJournalEntry): JSONObject = JSONObject()
        .put("day", entry.day)
        .put("question", entry.question)
        .put("answered_yes", entry.answeredYes)
        .putIfNotNull("notes", entry.notes)
        .putIfNotNull("numeric_value", entry.numericValue)

    private fun metricDays(days: Map<String, Map<String, Double>>): JSONObject {
        val objectValue = JSONObject()
        for (day in days.keys.sorted()) objectValue.put(day, doubleMap(days.getValue(day)))
        return objectValue
    }

    private fun stringMap(values: Map<String, String>): JSONObject {
        val objectValue = JSONObject()
        for (key in values.keys.sorted()) objectValue.put(key, values.getValue(key))
        return objectValue
    }

    private fun intMap(values: Map<String, Int>): JSONObject {
        val objectValue = JSONObject()
        for (key in values.keys.sorted()) objectValue.put(key, values.getValue(key))
        return objectValue
    }

    private fun doubleMap(values: Map<String, Double>): JSONObject {
        val objectValue = JSONObject()
        for (key in values.keys.sorted()) {
            val value = values.getValue(key)
            if (value.isFinite()) objectValue.put(key, value)
        }
        return objectValue
    }

    private fun array(values: List<JSONObject>): JSONArray = JSONArray().also { result ->
        values.forEach(result::put)
    }

    private fun JSONObject.putIfNotNull(key: String, value: Any?): JSONObject {
        if (value != null) put(key, value)
        return this
    }
}

/** Cross-runtime-stable identifiers that stay inside the server's bounded identifier grammar. */
object RemoteIdentifiers {
    fun event(deviceId: String, ts: Long, kind: String): String =
        "event:$ts:${fnv1a64("$deviceId|$ts|$kind")}"

    fun sleep(deviceId: String, startTs: Long): String =
        "sleep:$startTs:${fnv1a64(deviceId)}"

    fun workout(deviceId: String, startTs: Long, sport: String): String =
        "workout:$startTs:${fnv1a64("$deviceId|$sport")}"

    /** FNV-1a over UTF-16 code units, matching the repository's platform-neutral hash contract. */
    internal fun fnv1a64(value: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325 as signed Long
        for (ch in value) {
            hash = hash xor ch.code.toLong()
            hash *= 0x100000001b3L
        }
        return java.lang.Long.toUnsignedString(hash, 16).padStart(16, '0')
    }
}
