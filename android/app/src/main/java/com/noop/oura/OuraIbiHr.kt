package com.noop.oura

/**
 * Derives one heart-rate row from each banked IBI record.
 *
 * The ring banks overnight IBI records but not a matching per-record HR stream. Nightly ownership and
 * scoring require HR rows as well as R-R rows, so the history transport materializes HR from the median
 * physiological IBI in each record. Live pushes already contain [OuraEvent.Hr] and must not call this
 * helper. Swift twin: `OuraIbiHr`.
 */
object OuraIbiHr {
    /**
     * Append one derived HR event for every IBI record that does not already have an HR event.
     *
     * All beats decoded from one record share its ring timestamp. Invalid intervals and implausible
     * resulting rates are omitted rather than clamped.
     */
    fun appendingDerivedHrToHistoryEvents(events: List<OuraEvent>): List<OuraEvent> {
        val existing = events.mapNotNull { (it as? OuraEvent.Hr)?.value?.ringTimestamp }.toSet()
        val derived = perRecordMedianHR(events.mapNotNull { (it as? OuraEvent.Ibi)?.value })
            .filterNot { it.ringTimestamp in existing }
            .map { OuraEvent.Hr(it) }
        return if (derived.isEmpty()) events else events + derived
    }

    /** Return one median HR per IBI record, ordered by ring timestamp. */
    fun perRecordMedianHR(ibis: List<OuraIBI>): List<OuraHR> {
        val byRingTime = HashMap<Long, MutableList<Int>>()
        for (ibi in ibis) {
            if (ibi.ibiMs in 300..2_000) {
                byRingTime.getOrPut(ibi.ringTimestamp) { ArrayList() }.add(ibi.ibiMs)
            }
        }

        return byRingTime.keys.sorted().mapNotNull { ringTimestamp ->
            val intervals = byRingTime[ringTimestamp].orEmpty()
            if (intervals.isEmpty()) return@mapNotNull null
            val medianIbi = median(intervals)
            val bpm = Math.round(60_000.0 / medianIbi).toInt()
            if (bpm !in 30..220) return@mapNotNull null
            OuraHR(ringTimestamp = ringTimestamp, bpm = bpm, ibiMs = medianIbi)
        }
    }

    private fun median(values: List<Int>): Int {
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[middle - 1] + sorted[middle]) / 2
        } else {
            sorted[middle]
        }
    }
}
