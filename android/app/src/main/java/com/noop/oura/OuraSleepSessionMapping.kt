package com.noop.oura

/** Platform-neutral stage-rich night emitted by the ring-provided SleepNet classifier. */
data class OuraSleepSession(
    val startTs: Long,
    val endTs: Long,
    val efficiency: Double?,
    val stagesJson: String,
)

/**
 * Reshapes a reconstructed Oura hypnogram into the session format consumed by NOOP's sleep surfaces.
 * This is a parity twin of Swift `OuraSleepSessionMapping`, adapted from ryanbr/noop's clean-room
 * implementation. Fixed key order keeps cross-platform stored JSON byte-identical.
 */
object OuraSleepSessionMapping {
    const val PROVENANCE_TOKEN = "oura"
    const val MINIMUM_OBSERVED_SECONDS = 10L * 60L
    const val MINIMUM_ASLEEP_SECONDS = 5L * 60L

    fun hasOuraProvenance(stagesJson: String?): Boolean =
        stagesJson?.contains("\"source\":\"$PROVENANCE_TOKEN\"") == true

    fun token(stage: OuraSleepStage): String = when (stage) {
        OuraSleepStage.DEEP -> "deep"
        OuraSleepStage.LIGHT -> "light"
        OuraSleepStage.REM -> "rem"
        OuraSleepStage.AWAKE -> "wake"
    }

    fun session(
        codes: List<Pair<Long, OuraSleepStage>>,
        secondsPerCode: Long = 30L,
    ): OuraSleepSession? {
        val first = codes.firstOrNull() ?: return null
        val last = codes.last()

        data class Segment(val start: Long, var end: Long, val stage: OuraSleepStage)
        val segments = ArrayList<Segment>()
        for ((ts, stage) in codes) {
            val end = ts + secondsPerCode
            val previous = segments.lastOrNull()
            if (previous != null && previous.stage == stage && previous.end == ts) {
                previous.end = end
            } else {
                segments.add(Segment(ts, end, stage))
            }
        }

        var asleepSeconds = 0L
        var awakeSeconds = 0L
        var hasCoverageGap = false
        var previousTimestamp: Long? = null
        for ((ts, stage) in codes) {
            previousTimestamp?.let { previous ->
                if (ts != previous + secondsPerCode) hasCoverageGap = true
            }
            if (stage == OuraSleepStage.AWAKE) awakeSeconds += secondsPerCode
            else asleepSeconds += secondsPerCode
            previousTimestamp = ts
        }
        val inBedSeconds = asleepSeconds + awakeSeconds
        // Raw fragments still persist as phase events, but cannot masquerade as a credible night.
        if (inBedSeconds < MINIMUM_OBSERVED_SECONDS || asleepSeconds < MINIMUM_ASLEEP_SECONDS) return null

        val stagesJson = segments.joinToString(separator = ",", prefix = "[", postfix = "]") {
            "{\"start\":${it.start},\"end\":${it.end},\"stage\":\"${token(it.stage)}\"," +
                "\"source\":\"$PROVENANCE_TOKEN\"}"
        }

        // A missing flash page is unknown in-bed time, not permission to shrink the denominator.
        val efficiency = if (!hasCoverageGap && inBedSeconds > 0L) {
            asleepSeconds.toDouble() / inBedSeconds.toDouble()
        } else {
            null
        }

        return OuraSleepSession(
            startTs = first.first,
            endTs = last.first + secondsPerCode,
            efficiency = efficiency,
            stagesJson = stagesJson,
        )
    }
}
