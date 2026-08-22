package com.noop.analytics

/**
 * StressHeatmap — pure week×hour aggregation of the intraday autonomic-load timeline (R7).
 *
 * Kotlin twin of the Swift `StressHeatmap`; keep every cut point, ordering rule and tie-break
 * BYTE-IDENTICAL so iOS and Android resolve the same grid + pattern from the same inputs. No I/O, no
 * Android types — unit-testable on the JVM.
 *
 * Answers the pattern question the daily score and today's timeline can't: which hours of which days run
 * habitually loaded ("Wednesday afternoons run hot"). Derived entirely from data NOOP already computes;
 * an hour with no usable signal stays null and renders as an empty cell — never zero-filled, never
 * invented. Bands match the shared 0–3 scale: <1 low, <2 medium, >=2 high.
 *
 * APPROXIMATE and non-clinical, exactly like the underlying score: a wellness pattern view of an
 * autonomic-load proxy, never a stress diagnosis and never a medical reading.
 */
object StressHeatmap {

    /** Upper bound (exclusive) of the LOW band on the shared 0–3 scale. */
    const val LOW_BAND_CEILING: Double = 1.0
    /** Upper bound (exclusive) of MEDIUM; at/above this is HIGH (= DaytimeStress high band floor). */
    const val HIGH_BAND_FLOOR: Double = 2.0

    /** Default row window — the same waking band the intraday timeline uses (06:00–22:00). */
    const val DEFAULT_START_HOUR: Int = 6
    const val DEFAULT_END_HOUR: Int = 22

    enum class Band { LOW, MEDIUM, HIGH }

    /** Band for a 0–3 level. Matches the UI's StressBand cut points exactly. */
    fun band(level: Double): Band = when {
        level < LOW_BAND_CEILING -> Band.LOW
        level < HIGH_BAND_FLOOR -> Band.MEDIUM
        else -> Band.HIGH
    }

    /**
     * One day's hourly levels: [levels] maps local hour (0..23) -> 0–3 autonomic load. Hours absent from
     * the map are treated as no-data. Callers build this from the intraday timeline.
     */
    data class DayColumn(val day: String, val levels: Map<Int, Double>)

    /** One grid cell. [level] == null means no usable signal for that day/hour (render empty). */
    data class Cell(
        val day: String,
        val dayIndex: Int,
        val hour: Int,
        val level: Double?,
    ) {
        /** Band for the cell, or null when there's no level (never guesses a band). */
        val band: Band? get() = level?.let { band(it) }
    }

    /** Pattern read-out over a grid, with honest coverage so the UI can gate the narrative. */
    data class Summary(
        val peakHour: Int?,
        val peakHourMean: Double?,
        val calmestHour: Int?,
        val calmestHourMean: Double?,
        val overallMean: Double?,
        val coverage: Double,
        val scoredCells: Int,
        val totalCells: Int,
    ) {
        companion object {
            val EMPTY = Summary(null, null, null, null, null, 0.0, 0, 0)
        }
    }

    /**
     * Build the grid in row-major order (for each hour, each column) so a UI can lay out rows directly.
     * Hours outside [startHour, endHour) are omitted; an inverted/empty window yields an empty list.
     */
    fun grid(
        columns: List<DayColumn>,
        startHour: Int = DEFAULT_START_HOUR,
        endHour: Int = DEFAULT_END_HOUR,
    ): List<Cell> {
        val lo = startHour.coerceIn(0, 23)
        val hi = endHour.coerceIn(0, 24)
        if (hi <= lo || columns.isEmpty()) return emptyList()
        val out = ArrayList<Cell>((hi - lo) * columns.size)
        for (hour in lo until hi) {
            columns.forEachIndexed { i, col ->
                out.add(Cell(day = col.day, dayIndex = i, hour = hour, level = col.levels[hour]))
            }
        }
        return out
    }

    /**
     * Mean level per hour-of-day across all columns (only scored cells contribute). Hours with no scored
     * cell are ABSENT from the result — never zero-filled.
     */
    fun meanByHour(cells: List<Cell>): Map<Int, Double> {
        val sums = HashMap<Int, Double>()
        val counts = HashMap<Int, Int>()
        for (c in cells) {
            val l = c.level ?: continue
            sums[c.hour] = (sums[c.hour] ?: 0.0) + l
            counts[c.hour] = (counts[c.hour] ?: 0) + 1
        }
        val out = HashMap<Int, Double>()
        for ((hour, sum) in sums) {
            val n = counts[hour] ?: 0
            if (n > 0) out[hour] = sum / n
        }
        return out
    }

    /**
     * Pattern summary over a grid. Ties on peak/calmest resolve to the EARLIER hour so the result is
     * deterministic and identical to the Swift twin.
     */
    fun summary(cells: List<Cell>): Summary {
        if (cells.isEmpty()) return Summary.EMPTY
        val byHour = meanByHour(cells)
        val scored = cells.mapNotNull { it.level }
        val total = cells.size
        if (scored.isEmpty() || byHour.isEmpty()) {
            return Summary(null, null, null, null, null, 0.0, 0, total)
        }
        // Deterministic: ascending by (mean, hour) — first = calmest, and the peak takes the highest mean
        // with the EARLIEST hour among equals.
        val ascending = byHour.entries.sortedWith(
            compareBy({ it.value }, { it.key }),
        )
        val calmest = ascending.first()
        val maxMean = ascending.last().value
        val peak = ascending.filter { it.value == maxMean }.minByOrNull { it.key }!!
        val overall = scored.sum() / scored.size
        return Summary(
            peakHour = peak.key,
            peakHourMean = peak.value,
            calmestHour = calmest.key,
            calmestHourMean = calmest.value,
            overallMean = overall,
            coverage = scored.size.toDouble() / total.toDouble(),
            scoredCells = scored.size,
            totalCells = total,
        )
    }
}
