import Foundation
import WhoopProtocol
import OuraProtocol

/// Pure, testable mapping from a batch of decoded `OuraEvent` (emitted by `OuraProtocol.OuraDriver`)
/// onto the datastore's `Streams` shape, so the isolated live Oura source (`OuraLiveSource` in the app
/// target) can persist its samples through the SAME `StreamStore.insert` path the WHOOP pipeline uses,
/// keyed by the ring's own `deviceId`, without duplicating row-construction logic in the app target
/// where it can't be unit-tested. Parallels `StandardHRMapping`.
///
/// Honest-data invariant (hard): we surface only the ring's decoded raw signals + its own open event
/// tags (HR/IBI/HRV/SpO2/temp/sleep-phase/battery). We NEVER read or surface Oura's encrypted readiness
/// or sleep scores. NOOP computes its own Charge/Rest downstream from these per-device streams. The
/// `OuraHRV` 0x5D tag is the ring's OWN RMSSD-derived HRV signal (OURA_PROTOCOL.md s6.9), not a readiness
/// score; NOOP also independently reconstructs RMSSD from the IBI streams for its own scoring.
///
/// Timestamping: the live source streams a batch and stamps every row at the arrival wall-clock `ts`
/// (unix seconds), exactly as `StandardHRMapping.samples(...at:)` does. The decoded events carry only a
/// ring-clock `ringTimestamp` (a `(session << 16) | counter` value, NOT wall-clock), so anchoring is the
/// transport's job; the mapping stays pure and deterministic by taking the wall-clock `ts` as input. A
/// signal that could not be decoded never reaches this layer (the decoders return nil upstream), so a
/// missing stream stays empty here, never faked (Huami precedent).
///
/// Tier-B (UNVERIFIED) events are dropped: only Tier-A decoded signals map into `Streams`, so an
/// unverified summary can never silently feed scoring.
public enum OuraStreamMapping {
    /// WhoopEvent.kind for the ring's own HRV 0x5D tag. The payload carries the RAW decoded fields
    /// (`time_ms`/`b1`/`b2`) only, never a fabricated `rmssd_ms` (the b1/b2 byte -> ms scale is not
    /// Tier-A; see OURA_PROTOCOL.md s6.9). Must match the Kotlin twin (OuraStreamMapping.kt) exactly.
    public static let hrvEventKind = "OURA_HRV"
    /// WhoopEvent.kind for a decoded sleep-phase code (2-bit: awake/light/deep/rem).
    public static let sleepPhaseEventKind = "OURA_SLEEP_PHASE"

    /// Build a `Streams` from a batch of decoded Oura events, all stamped at the arrival wall-clock `ts`
    /// (unix seconds). Pure → unit-testable. Section-4 table:
    ///   - `.hr`         (0x55 live-HR push)            → `hr:[HRSample]`
    ///   - `.ibi`        (0x44/0x60 IBI)                → `rr:[RRInterval]`
    ///   - `.hrv`        (0x5D HRV tag, raw int8 b1/b2)  → `events:[WhoopEvent(kind: OURA_HRV)]`
    ///   - `.spo2`       (0x6F/0x70/0x77)              → `spo2:[SpO2Sample(raw_adc)]`
    ///   - `.temp`       (0x46/0x75)                    → `skinTemp:[SkinTempSample(raw_adc)]`
    ///   - `.sleepPhase` (0x4E/0x5A 2-bit codes)        → `events:[WhoopEvent(kind: OURA_SLEEP_PHASE)]`
    ///   - `.battery`                                   → `battery:[BatterySample]`
    /// Every other event case (`.motion`, `.state`, `.timeSync`, `.rtcBeacon`, `.debugText`, `.tierB`,
    /// `.activityInfo`) is intentionally not folded into a durable stream here. In particular the 0x50
    /// activity/MET decode NEVER mints a `steps` row: the formula is third-party and unvalidated (Tier B,
    /// OURA_PROTOCOL.md s6.13), and MET is not a step count - fabricating one would break the honest-data
    /// invariant and the per-source day-owner rules.
    public static func streams(from events: [OuraEvent], at ts: Int) -> Streams {
        var out = Streams()
        for e in events {
            switch e {
            case .hr(let v):
                // Honest HR: surface only the ring's decoded BPM. The push also carries one IBI, but the
                // dedicated `.ibi` events are the R-R source, so we do not synthesise an RR row from the HR
                // push here to avoid double-counting the same interval.
                out.hr.append(HRSample(ts: ts, bpm: v.bpm))

            case .ibi(let v):
                out.rr.append(RRInterval(ts: ts, rrMs: v.ibiMs,
                                         srcChannel: rrChannel(v.channel)))

            case .hrv(let v):
                // The first pair is the oldest bucket; the record timestamp marks the covered span's end.
                // A bucket is stamped at its start, and count includes padding omitted by the decoder.
                let bucketTs = ts - (v.count - v.index) * 300
                out.events.append(WhoopEvent(ts: bucketTs, kind: hrvEventKind, payload: [
                    "pair_index": .int(v.index),
                    "hr_bpm": .int(v.hrBpm),
                    "rmssd_ms": .int(v.rmssdMs),
                ]))

            case .spo2(let v):
                // Oura reports a single SpO2 channel; `SpO2Sample` is the WHOOP-shaped two-channel raw row,
                // so we record the decoded value on `red` and leave `ir` at 0 (no second channel). `unit`
                // carries the decoder's own scale tag ("raw"/"dc_raw") so downstream never assumes a %.
                let sampleTs = ts - max(0, v.count - 1 - v.index)
                out.spo2.append(SpO2Sample(ts: sampleTs, red: v.value, ir: 0, unit: v.unit))

            case .temp(let v):
                // The decoder yields degrees C. The durable `SkinTempSample.raw` is an integer in the
                // codebase-wide CENTI-degree-C convention: the WHOOP @73 historical path stores raw at
                // this scale and the analytics reader (AnalyticsEngine.skinTempFunnel) divides raw by 100
                // to recover °C. We store the SAME centi-°C scale so an Oura night reads on the SAME gates
                // as a WHOOP night with no scorer change, and tag the unit so the convention is explicit
                // and never silently assumed. PARITY: the Kotlin twin stores the SAME celsius * 100, so a
                // given decoded celsius yields an IDENTICAL raw integer on both platforms.
                out.skinTemp.append(SkinTempSample(ts: ts, raw: Int((v.celsius * 100).rounded()), unit: "centi_c"))

            case .sleepPhase(let v):
                // Erased-flash placeholders preserve decoder positions but are missing data, not awake
                // sleep. Drop them at the persistence boundary so live/import/replay callers all receive
                // the same protection (#1246).
                guard !v.unwritten else { continue }
                out.events.append(WhoopEvent(ts: ts, kind: sleepPhaseEventKind, payload: [
                    "phase": .int(v.stage.rawValue),
                    "index": .int(v.index),
                ]))

            case .battery(let v):
                out.battery.append(BatterySample(
                    ts: ts,
                    soc: Double(v.percent),
                    mv: v.voltageMv,
                    charging: v.charging))

            case .motion, .state, .timeSync, .rtcBeacon, .debugText, .tierB, .activityInfo:
                // Not a durable per-device stream row (timeSync/rtcBeacon anchor the transport's clock;
                // motion/state/debug are diagnostics; Tier-B / .activityInfo are UNVERIFIED and must
                // never feed scoring or the steps stream).
                continue
            }
        }
        return out
    }

    /// Fold timestamped event groups into one transaction-sized `Streams` value while preserving each
    /// row's own timestamp and arrival order. A reconstructed full-night hypnogram can contain roughly
    /// 960 30-second stages; persisting those as 960 separate transactions can outlive the history cursor
    /// barrier. This keeps all rows distinct but lets the store commit them together.
    public static func mergedStreams(
        from batches: [(events: [OuraEvent], ts: Int)]
    ) -> Streams {
        var merged = Streams()
        for batch in batches {
            let next = streams(from: batch.events, at: batch.ts)
            merged.hr.append(contentsOf: next.hr)
            merged.rr.append(contentsOf: next.rr)
            merged.spo2.append(contentsOf: next.spo2)
            merged.skinTemp.append(contentsOf: next.skinTemp)
            merged.resp.append(contentsOf: next.resp)
            merged.gravity.append(contentsOf: next.gravity)
            merged.steps.append(contentsOf: next.steps)
            merged.sleepState.append(contentsOf: next.sleepState)
            merged.ppgHr.append(contentsOf: next.ppgHr)
            merged.ppgWaveform.append(contentsOf: next.ppgWaveform)
            merged.events.append(contentsOf: next.events)
            merged.battery.append(contentsOf: next.battery)
        }
        return merged
    }

    /// Group already-stamped events into one insert per timestamp while preserving arrival order.
    /// StreamStore's R-R `ord` counter is batch-local, so per-beat inserts would reset it to zero.
    public static func batched(_ stamped: [(event: OuraEvent, ts: Int)])
        -> [(ts: Int, events: [OuraEvent])] {
        var order: [Int] = []
        var byTs: [Int: [OuraEvent]] = [:]
        for value in stamped {
            if byTs[value.ts] == nil {
                order.append(value.ts)
                byTs[value.ts] = []
            }
            byTs[value.ts]?.append(value.event)
        }
        return order.map { (ts: $0, events: byTs[$0] ?? []) }
    }

    public static func rrChannel(_ channel: OuraIBIChannel?) -> RRSourceChannel? {
        switch channel {
        case .greenQuality: return .greenQuality
        case .spo2Ibi: return .spo2Ibi
        case .ibiAmplitude: return .ibiAmplitude
        case .ibiBare: return .ibiBare
        case nil: return nil
        }
    }
}
