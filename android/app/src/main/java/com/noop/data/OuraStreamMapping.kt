package com.noop.data

import com.noop.oura.OuraEvent
import com.noop.oura.OuraIbiChannel
import com.noop.protocol.RrSourceChannel
import com.noop.protocol.SkinTempSample
import com.noop.protocol.Spo2Sample
import com.noop.protocol.Streams
import com.noop.protocol.WhoopEvent

/**
 * Pure, JVM-testable mapping from the Oura ring's decoded [OuraEvent]s onto the datastore's
 * protocol [Streams] shape, so the WHOOP-isolated `OuraLiveSource` can persist its samples through
 * the SAME [WhoopRepository.insert] path (via [StreamPersistence.toBatch]) the WHOOP pipeline uses,
 * without duplicating row construction in the (untestable) app/BLE target. Kotlin twin of the Swift
 * `OuraStreamMapping` (WhoopStore), built from the architecture plan's section-4 table.
 *
 * HONEST-DATA INVARIANT (hard): we surface ONLY the ring's decoded raw signals and its OWN open
 * event tags. We never read or display Oura's encrypted readiness/sleep scores. NOOP computes its
 * own Charge/Rest downstream:
 *   - the IBI stream becomes [Streams.rr], from which RecoveryScorer reconstructs NOOP's OWN RMSSD;
 *   - the HR stream feeds resting-HR + strain;
 *   - the ring's open 0x5D HRV tag is recorded as `OURA_HRV` events carrying its validated
 *     pair_index/hr_bpm/rmssd_ms fields; NOOP's scoring RMSSD still comes from `rr`;
 *   - the open sleep-phase tags become `OURA_SLEEP_PHASE` events folded into a sleep session.
 *
 * Each event carries a ring-clock `ringTimestamp` (not wall-clock). To stay pure and avoid baking a
 * clock model in here, the caller supplies an [anchor] resolving a ring timestamp to wall-clock unix
 * seconds (driven by the ring's 0x42/0x85 time-sync events upstream). When the anchor cannot place a
 * record (anchor returns null), the sample is DROPPED rather than stamped with a guessed time
 * (honest-data invariant), a ts-less biometric row is unstorable anyway.
 */
object OuraStreamMapping {

    /** The event `kind` recorded for the ring's own open HRV (0x5D) tag. Must match Swift exactly. */
    const val EVENT_HRV = "OURA_HRV"

    /** The event `kind` recorded for the ring's own open sleep-phase (0x49.../0x58) tags. */
    const val EVENT_SLEEP_PHASE = "OURA_SLEEP_PHASE"

    /**
     * Fold a batch of decoded [events] into a protocol [Streams] for one flush. [anchor] maps a
     * ring-clock timestamp to wall-clock unix seconds (null => drop the sample). Pure: no BLE, no DB,
     * no clock, fully JVM-unit-testable. Tier-B events never reach scoring; if any leak in (they only
     * appear when the driver's allowTierB is set), they are ignored here so they cannot fabricate a
     * stream value.
     */
    fun streams(events: List<OuraEvent>, anchor: (Long) -> Int?): Streams {
        val out = Streams()
        for (ev in events) {
            when (ev) {
                is OuraEvent.Hr -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.hr.add(com.noop.protocol.HrSample(ts, ev.value.bpm))
                }

                is OuraEvent.Ibi -> {
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.rr.add(
                        com.noop.protocol.RrInterval(
                            ts,
                            ev.value.ibiMs,
                            rrChannel(ev.value.channel),
                        ),
                    )
                }

                is OuraEvent.Hrv -> {
                    // The first pair is the record's oldest bucket; the record time marks the span's end.
                    val base = anchor(ev.value.ringTimestamp) ?: continue
                    val ts = base - (ev.value.count - ev.value.index) * 300
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_HRV,
                            payload = linkedMapOf(
                                "pair_index" to ev.value.index,
                                "hr_bpm" to ev.value.hrBpm,
                                "rmssd_ms" to ev.value.rmssdMs,
                            ),
                        ),
                    )
                }

                is OuraEvent.Spo2 -> {
                    // The ring exposes ONE combined SpO2 reading (not separate red/ir channels): its
                    // raw value goes in `red`; `ir` stays 0 (an unread channel, never a fabricated
                    // second reading). `unit` carries the decoder's own scale tag so downstream never
                    // assumes a percentage, mirroring the Swift twin's SpO2Sample(unit:).
                    val base = anchor(ev.value.ringTimestamp) ?: continue
                    val ts = base - maxOf(0, ev.value.count - 1 - ev.value.index)
                    out.spo2.add(Spo2Sample(ts = ts, red = ev.value.value, ir = 0, unit = ev.value.unit))
                }

                is OuraEvent.Temp -> {
                    // The ring exposes skin temperature in degrees C; the store's raw integer uses the
                    // codebase-wide CENTI-degree-C convention (°C = raw / 100, the scale the analytics
                    // reader divides by), so persist celsius * 100 and tag the unit. PARITY: the Swift
                    // twin stores the IDENTICAL celsius * 100, so the same decoded celsius yields the same
                    // raw integer on both platforms.
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.skinTemp.add(
                        SkinTempSample(
                            ts = ts,
                            raw = Math.round(ev.value.celsius * 100.0).toInt(),
                            unit = "centi_c",
                        ),
                    )
                }

                is OuraEvent.SleepPhaseEvent -> {
                    // Erased-flash placeholders are gaps, not awake epochs. Drop at the persistence
                    // boundary so every live/import/replay path receives the same protection (#1246).
                    if (ev.value.unwritten) continue
                    val ts = anchor(ev.value.ringTimestamp) ?: continue
                    out.events.add(
                        WhoopEvent(
                            ts = ts,
                            kind = EVENT_SLEEP_PHASE,
                            payload = linkedMapOf<String, Any?>(
                                "phase" to ev.value.stage.raw,
                                "index" to ev.value.index,
                            ),
                        ),
                    )
                }

                is OuraEvent.Battery -> {
                    // Live battery percent. No ring timestamp on a battery reading (it is a command
                    // response), so it is stamped by the live source's `onBattery` path, not persisted
                    // as a tied-to-ts row here. Leave the batch's battery list empty (honest: no faked ts).
                }

                // Motion / state / time-sync / rtc / debug / TierB / ActivityInfo never map onto a
                // scored stream. In particular the 0x50 activity/MET decode (PR #960) NEVER mints a
                // `steps` row: the formula is third-party and unvalidated (Tier B, OURA_PROTOCOL.md
                // s6.13), and MET is not a step count - fabricating one would break the honest-data
                // invariant and the per-source day-owner rules.
                else -> Unit
            }
        }
        return out
    }

    /**
     * Fold timestamped event groups into one transaction-sized [Streams] value. Each event keeps the
     * supplied batch timestamp, but a full-night hypnogram no longer requires one Room transaction per
     * 30-second stage.
     */
    fun mergedStreams(batches: List<Pair<List<OuraEvent>, Int>>): Streams {
        val merged = Streams()
        for ((events, ts) in batches) {
            val next = streams(events) { ts }
            merged.hr.addAll(next.hr)
            merged.rr.addAll(next.rr)
            merged.events.addAll(next.events)
            merged.battery.addAll(next.battery)
            merged.spo2.addAll(next.spo2)
            merged.skinTemp.addAll(next.skinTemp)
        }
        return merged
    }

    /** Group stamped events by second while retaining first-timestamp and event arrival order. */
    fun batched(stamped: List<Pair<OuraEvent, Int>>): List<Pair<Int, List<OuraEvent>>> {
        val byTs = LinkedHashMap<Int, MutableList<OuraEvent>>()
        for ((event, ts) in stamped) byTs.getOrPut(ts) { mutableListOf() }.add(event)
        return byTs.map { (ts, events) -> ts to events.toList() }
    }

    internal fun rrChannel(channel: OuraIbiChannel?): RrSourceChannel? = when (channel) {
        OuraIbiChannel.GREEN_QUALITY -> RrSourceChannel.GREEN_QUALITY
        OuraIbiChannel.SPO2_IBI -> RrSourceChannel.SPO2_IBI
        OuraIbiChannel.IBI_AMPLITUDE -> RrSourceChannel.IBI_AMPLITUDE
        OuraIbiChannel.IBI_BARE -> RrSourceChannel.IBI_BARE
        null -> null
    }
}
