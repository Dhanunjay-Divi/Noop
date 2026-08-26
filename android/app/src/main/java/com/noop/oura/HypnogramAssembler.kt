package com.noop.oura

// Time-axis reconstruction for Oura's burst-written SleepNet hypnogram.
// Kotlin twin of the Swift implementation, adapted from Dhanunjay-Divi/Noop's clean-room Oura pipeline
// (upstream #1246); project LICENSE/NOTICE/ATTRIBUTION retain provenance and terms.

data class OuraHypnogramRecord(val ringTimestamp: Long, val phases: List<OuraSleepPhase>)
data class OuraHypnogramCode(val phase: OuraSleepPhase, val ts: Long)

data class OuraHypnogramBurst(val records: List<OuraHypnogramRecord>) {
    val totalCodes: Int get() = records.sumOf { it.phases.size }
    val lastRingTimestamp: Long get() = records.lastOrNull()?.ringTimestamp ?: 0L

    val hasNonMonotonicRingTimes: Boolean
        get() = records.zipWithNext().any { (first, second) ->
            second.ringTimestamp < first.ringTimestamp
        }

    /**
     * Lay every phase backward from the anchored burst end at the 30-second SleepNet epoch. Erased-flash
     * placeholders are filtered only after the full sequence receives timestamps, so missing pages remain
     * gaps and do not pull the surrounding real phases together.
     */
    fun codesWithTimes(
        endUnixSeconds: Long,
        sleepStartUnixSeconds: Long? = null,
        secondsPerCode: Long = 30L,
    ): List<OuraHypnogramCode> {
        val laid = ArrayList<OuraHypnogramCode>(totalCodes)
        var position = 0
        for (record in records) {
            for (phase in record.phases) {
                laid.add(
                    OuraHypnogramCode(
                        phase = phase,
                        ts = endUnixSeconds - (totalCodes - position) * secondsPerCode,
                    ),
                )
                position += 1
            }
        }

        val written = laid.filter { !it.phase.unwritten }
        if (sleepStartUnixSeconds == null) return written
        val clipped = written.filter { it.ts >= sleepStartUnixSeconds }
        return if (clipped.isEmpty()) written else clipped
    }
}

class OuraHypnogramAssembler(val burstGapTicks: Long = 600L) {
    private var current = ArrayList<OuraHypnogramRecord>()

    fun feed(ringTimestamp: Long, phases: List<OuraSleepPhase>): OuraHypnogramBurst? {
        if (phases.isEmpty()) return null
        val record = OuraHypnogramRecord(ringTimestamp, phases)
        current.lastOrNull()?.let { last ->
            val gap = if (ringTimestamp >= last.ringTimestamp) {
                ringTimestamp - last.ringTimestamp
            } else {
                last.ringTimestamp - ringTimestamp
            }
            if (gap > burstGapTicks) {
                val completed = OuraHypnogramBurst(current)
                current = arrayListOf(record)
                return completed
            }
        }
        current.add(record)
        return null
    }

    fun flush(): OuraHypnogramBurst? {
        if (current.isEmpty()) return null
        val completed = OuraHypnogramBurst(current)
        current = ArrayList()
        return completed
    }

    fun reset() {
        current = ArrayList()
    }

    val pendingRecordCount: Int get() = current.size
}
