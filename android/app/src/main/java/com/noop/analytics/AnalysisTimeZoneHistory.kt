package com.noop.analytics

import android.content.Context
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.time.ZoneId

/**
 * Durable, local-only observations of the device timezone used by on-device scoring.
 *
 * The file lives under [Context.getNoBackupFilesDir], so timezone history is neither included in Android
 * Auto Backup nor exposed through NOOP's diagnostics/cloud paths. Observations are points, not fabricated
 * capture metadata: consecutive points with the same ZoneId form one exact rules segment; a change of
 * ZoneId leaves the interval between the last old-zone observation and the first new-zone observation
 * unresolved. History before the first-ever observation also fails closed: opening after travel or
 * upgrading an existing database cannot safely assign old samples to the phone's current zone.
 */
internal class AnalysisTimeZoneHistory private constructor(
    private val persistence: Persistence,
    private val maxObservations: Int,
) {
    init {
        require(maxObservations >= 2)
    }

    data class Observation(
        val observedAtEpochSeconds: Long,
        val zoneId: String,
        val offsetSeconds: Int,
    )

    data class ExactSegment(
        val startTs: Long,
        val endTs: Long,
        val zoneId: ZoneId,
        val permitsHistoryBeforeStart: Boolean,
        val openEnded: Boolean,
    )

    enum class Uncertainty {
        NO_OBSERVATION,
        TRUNCATED_HISTORY,
        RECORDED_ZONE_BOUNDARY,
    }

    data class TerminalUnknownRange(
        val startTs: Long,
        val endTs: Long,
        val reason: Uncertainty,
    ) {
        init {
            require(startTs >= 0L)
            require(endTs >= startTs)
            require(
                reason == Uncertainty.TRUNCATED_HISTORY ||
                    reason == Uncertainty.RECORDED_ZONE_BOUNDARY,
            )
        }

        operator fun contains(epochSeconds: Long): Boolean =
            epochSeconds in startTs..endTs
    }

    sealed interface Resolution {
        data class Exact(val segment: ExactSegment) : Resolution
        data class Uncertain(val reason: Uncertainty) : Resolution
    }

    class Snapshot internal constructor(
        val observations: List<Observation>,
        val unresolvableBeforeEpochSeconds: Long?,
    ) {
        init {
            require(observations.zipWithNext().all { (older, newer) ->
                newer.observedAtEpochSeconds > older.observedAtEpochSeconds
            })
            require(
                unresolvableBeforeEpochSeconds == null ||
                    unresolvableBeforeEpochSeconds == observations.firstOrNull()
                        ?.observedAtEpochSeconds,
            )
        }

        fun exactSegments(): List<ExactSegment> {
            if (observations.isEmpty()) return emptyList()
            data class Run(
                val startTs: Long,
                val endTs: Long,
                val zoneId: ZoneId,
            )

            val runs = ArrayList<Run>()
            var start = observations.first().observedAtEpochSeconds
            var end = start
            var zone = ZoneId.of(observations.first().zoneId)
            for (observation in observations.drop(1)) {
                if (observation.zoneId == zone.id) {
                    end = observation.observedAtEpochSeconds
                } else {
                    runs += Run(startTs = start, endTs = end, zoneId = zone)
                    start = observation.observedAtEpochSeconds
                    end = start
                    zone = ZoneId.of(observation.zoneId)
                }
            }
            runs += Run(startTs = start, endTs = end, zoneId = zone)
            return runs.mapIndexed { index, run ->
                ExactSegment(
                    startTs = run.startTs,
                    endTs = run.endTs,
                    zoneId = run.zoneId,
                    permitsHistoryBeforeStart =
                        index == 0 && unresolvableBeforeEpochSeconds == null,
                    openEnded = index == runs.lastIndex,
                )
            }
        }

        fun resolve(epochSeconds: Long): Resolution {
            val segments = exactSegments()
            if (segments.isEmpty()) {
                return Resolution.Uncertain(Uncertainty.NO_OBSERVATION)
            }
            segments.firstOrNull { epochSeconds in it.startTs..it.endTs }?.let {
                return Resolution.Exact(it)
            }
            if (epochSeconds < segments.first().startTs) {
                return Resolution.Uncertain(Uncertainty.TRUNCATED_HISTORY)
            }
            if (epochSeconds > segments.last().endTs) {
                return Resolution.Exact(segments.last())
            }
            return Resolution.Uncertain(Uncertainty.RECORDED_ZONE_BOUNDARY)
        }

        private fun civilDayRange(
            epochSeconds: Long,
            zoneId: ZoneId,
        ): LongRange? = runCatching {
            val localDate = Instant.ofEpochSecond(epochSeconds)
                .atZone(zoneId)
                .toLocalDate()
            val start = localDate.atStartOfDay(zoneId).toEpochSecond()
            val next = localDate.plusDays(1L).atStartOfDay(zoneId).toEpochSecond()
            require(start >= 0L && next > start)
            start..(next - 1L)
        }.getOrNull()

        /**
         * Permanently unscorable timezone-provenance range containing [epochSeconds], if any.
         *
         * Partial boundary days are included because a daily score cannot truthfully assign the unknown
         * portion to either timezone. Missing/corrupt history remains retryable and never enters this path.
         */
        fun terminalUnknownRangeContaining(epochSeconds: Long): TerminalUnknownRange? {
            if (epochSeconds < 0L) return null
            val segments = runCatching { exactSegments() }.getOrNull() ?: return null
            val first = segments.firstOrNull() ?: return null

            if (unresolvableBeforeEpochSeconds != null) {
                val firstDay = civilDayRange(first.startTs, first.zoneId)
                if (firstDay != null) {
                    val endTs = if (firstDay.first == first.startTs) {
                        first.startTs - 1L
                    } else {
                        firstDay.last
                    }
                    if (endTs >= 0L) {
                        val terminal = TerminalUnknownRange(
                            startTs = 0L,
                            endTs = endTs,
                            reason = Uncertainty.TRUNCATED_HISTORY,
                        )
                        if (epochSeconds in terminal) return terminal
                    }
                }
            }

            for ((older, newer) in segments.zipWithNext()) {
                if (older.endTs >= newer.startTs) continue
                val olderDay = civilDayRange(older.endTs, older.zoneId) ?: continue
                val newerDay = civilDayRange(newer.startTs, newer.zoneId) ?: continue
                val lowerBounds = mutableListOf(older.endTs + 1L)
                val upperBounds = mutableListOf(newer.startTs - 1L)
                if (older.endTs < olderDay.last) {
                    lowerBounds += olderDay.first
                    upperBounds += olderDay.last
                }
                if (newer.startTs > newerDay.first) {
                    lowerBounds += newerDay.first
                    upperBounds += newerDay.last
                }
                val startTs = lowerBounds.minOrNull() ?: continue
                val endTs = upperBounds.maxOrNull() ?: continue
                if (startTs < 0L || endTs < startTs) continue
                val terminal = TerminalUnknownRange(
                    startTs = startTs,
                    endTs = endTs,
                    reason = Uncertainty.RECORDED_ZONE_BOUNDARY,
                )
                if (epochSeconds in terminal) return terminal
            }
            return null
        }
    }

    private data class StoredHistory(
        val observations: List<Observation>,
        val unresolvableBeforeEpochSeconds: Long?,
    )

    internal sealed interface ReadResult {
        data object Missing : ReadResult
        data class Available(val bytes: ByteArray) : ReadResult
        data object Failed : ReadResult
    }

    internal interface Persistence {
        fun read(): ReadResult
        fun write(bytes: ByteArray): Boolean
    }

    @Synchronized
    fun observe(
        observedAtEpochSeconds: Long,
        zoneId: ZoneId,
    ): Snapshot? {
        if (observedAtEpochSeconds < 0L || zoneId.id.length > MAX_ZONE_ID_LENGTH) return null
        val observedInstant = runCatching {
            Instant.ofEpochSecond(observedAtEpochSeconds)
        }.getOrNull() ?: return null
        val current = Observation(
            observedAtEpochSeconds = observedAtEpochSeconds,
            zoneId = zoneId.id,
            offsetSeconds = zoneId.rules
                .getOffset(observedInstant)
                .totalSeconds,
        )
        val existing = when (val stored = persistence.read()) {
            ReadResult.Missing -> StoredHistory(
                observations = emptyList(),
                unresolvableBeforeEpochSeconds = observedAtEpochSeconds,
            )
            is ReadResult.Available -> decode(stored.bytes) ?: return null
            ReadResult.Failed -> return null
        }
        val appended = appendObservation(existing.observations, current) ?: return null
        if (appended == existing.observations) {
            return Snapshot(
                existing.observations,
                existing.unresolvableBeforeEpochSeconds,
            )
        }
        val retained = appended.takeLast(maxObservations)
        val unresolvableBefore = if (retained.size < appended.size) {
            maxOf(
                existing.unresolvableBeforeEpochSeconds ?: 0L,
                retained.first().observedAtEpochSeconds,
            )
        } else {
            existing.unresolvableBeforeEpochSeconds
        }
        val updated = StoredHistory(
            observations = retained,
            unresolvableBeforeEpochSeconds =
                unresolvableBefore ?: retained.firstOrNull()?.observedAtEpochSeconds,
        )
        if (!persistence.write(encode(updated))) return null
        return Snapshot(updated.observations, updated.unresolvableBeforeEpochSeconds)
    }

    @Synchronized
    fun load(): Snapshot? = when (val stored = persistence.read()) {
        ReadResult.Missing -> Snapshot(emptyList(), null)
        is ReadResult.Available -> decode(stored.bytes)?.let {
            Snapshot(it.observations, it.unresolvableBeforeEpochSeconds)
        }
        ReadResult.Failed -> null
    }

    private fun appendObservation(
        existing: List<Observation>,
        current: Observation,
    ): List<Observation>? {
        val last = existing.lastOrNull()
        if (last == null) return listOf(current)
        if (current.observedAtEpochSeconds < last.observedAtEpochSeconds) return null
        if (current.observedAtEpochSeconds == last.observedAtEpochSeconds) {
            if (last.zoneId == current.zoneId && last.offsetSeconds == current.offsetSeconds) {
                return existing
            }
            if (last.zoneId == current.zoneId || last.observedAtEpochSeconds == Long.MAX_VALUE) {
                return null
            }
            val boundaryTs = last.observedAtEpochSeconds + 1L
            val boundaryZone = ZoneId.of(current.zoneId)
            return existing + current.copy(
                observedAtEpochSeconds = boundaryTs,
                offsetSeconds = boundaryZone.rules
                    .getOffset(Instant.ofEpochSecond(boundaryTs))
                    .totalSeconds,
            )
        }

        val updated = existing.toMutableList()
        if (last.zoneId != current.zoneId) {
            updated += current
        } else {
            val sameZoneTail = existing.asReversed().takeWhile { it.zoneId == current.zoneId }
            if (sameZoneTail.size < 2) {
                updated += current
            } else {
                updated[updated.lastIndex] = current
            }
        }
        return updated
    }

    private fun encode(history: StoredHistory): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            output.writeInt(FILE_MAGIC)
            output.writeInt(FILE_VERSION)
            output.writeLong(history.unresolvableBeforeEpochSeconds ?: NO_TRUNCATION_MARKER)
            output.writeInt(history.observations.size)
            for (observation in history.observations) {
                output.writeLong(observation.observedAtEpochSeconds)
                output.writeUTF(observation.zoneId)
                output.writeInt(observation.offsetSeconds)
            }
        }
        return bytes.toByteArray()
    }

    private fun decode(bytes: ByteArray): StoredHistory? = runCatching {
        require(bytes.size <= MAX_ENCODED_BYTES)
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            require(input.readInt() == FILE_MAGIC)
            val version = input.readInt()
            require(version == LEGACY_FILE_VERSION || version == FILE_VERSION)
            val encodedUnresolvableBefore = if (version == FILE_VERSION) {
                input.readLong()
            } else {
                NO_TRUNCATION_MARKER
            }
            require(encodedUnresolvableBefore >= NO_TRUNCATION_MARKER)
            val count = input.readInt()
            require(count in 0..MAX_DECODED_OBSERVATIONS)
            val observations = ArrayList<Observation>(count)
            repeat(count) {
                val observedAt = input.readLong()
                val zoneName = input.readUTF()
                val offset = input.readInt()
                require(observedAt >= 0L)
                require(zoneName.length <= MAX_ZONE_ID_LENGTH)
                require(offset in MIN_OFFSET_SECONDS..MAX_OFFSET_SECONDS)
                // The offset is bounded evidence from observation time. Current OS tzdata may revise
                // historical rules, which must not make an otherwise readable history corrupt.
                ZoneId.of(zoneName)
                observations += Observation(observedAt, zoneName, offset)
            }
            require(input.available() == 0)
            require(observations.zipWithNext().all { (older, newer) ->
                newer.observedAtEpochSeconds > older.observedAtEpochSeconds
            })
            val retained = observations.takeLast(maxObservations)
            val decodedMarker = encodedUnresolvableBefore
                .takeUnless { it == NO_TRUNCATION_MARKER }
            val marker = if (retained.size < observations.size) {
                maxOf(
                    decodedMarker ?: 0L,
                    retained.first().observedAtEpochSeconds,
                )
            } else {
                decodedMarker ?: retained.firstOrNull()?.observedAtEpochSeconds
            }
            require(
                marker == null ||
                    marker == retained.firstOrNull()?.observedAtEpochSeconds,
            )
            StoredHistory(
                observations = retained,
                unresolvableBeforeEpochSeconds = marker,
            )
        }
    }.getOrNull()

    private class NoBackupAtomicPersistence(context: Context) : Persistence {
        private val file = File(context.applicationContext.noBackupFilesDir, FILE_NAME)
        private val atomicFile = AtomicFile(file)

        override fun read(): ReadResult {
            if (!file.exists()) return ReadResult.Missing
            if (file.length() !in 1L..MAX_ENCODED_BYTES.toLong()) return ReadResult.Failed
            return runCatching {
                atomicFile.openRead().use { ReadResult.Available(it.readBytes()) }
            }.getOrElse { ReadResult.Failed }
        }

        override fun write(bytes: ByteArray): Boolean {
            if (bytes.isEmpty() || bytes.size > MAX_ENCODED_BYTES) return false
            var stream: FileOutputStream? = null
            return try {
                stream = atomicFile.startWrite()
                stream.write(bytes)
                atomicFile.finishWrite(stream)
                true
            } catch (_: Throwable) {
                stream?.let(atomicFile::failWrite)
                false
            }
        }
    }

    companion object {
        private const val FILE_NAME = "analysis-timezone-history-v1.bin"
        private const val FILE_MAGIC = 0x4E545A48
        private const val LEGACY_FILE_VERSION = 1
        private const val FILE_VERSION = 2
        private const val NO_TRUNCATION_MARKER = -1L
        private const val DEFAULT_MAX_OBSERVATIONS = 256
        private const val MAX_DECODED_OBSERVATIONS = 4_096
        private const val MAX_ENCODED_BYTES = 128 * 1_024
        private const val MAX_ZONE_ID_LENGTH = 128
        private const val MIN_OFFSET_SECONDS = -18 * 3_600
        private const val MAX_OFFSET_SECONDS = 18 * 3_600

        @Volatile
        private var shared: AnalysisTimeZoneHistory? = null

        fun from(context: Context): AnalysisTimeZoneHistory =
            shared ?: synchronized(this) {
                shared ?: AnalysisTimeZoneHistory(
                    persistence = NoBackupAtomicPersistence(context),
                    maxObservations = DEFAULT_MAX_OBSERVATIONS,
                ).also { shared = it }
            }

        internal fun forTesting(
            persistence: Persistence,
            maxObservations: Int = DEFAULT_MAX_OBSERVATIONS,
        ): AnalysisTimeZoneHistory = AnalysisTimeZoneHistory(persistence, maxObservations)
    }
}
