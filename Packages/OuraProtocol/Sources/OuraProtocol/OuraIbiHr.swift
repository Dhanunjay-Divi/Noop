import Foundation

/// Derives one heart-rate row from each banked IBI record.
///
/// The ring banks overnight IBI records but not a matching per-record HR stream. Nightly ownership and
/// scoring require HR rows as well as R-R rows, so the history transport materializes HR from the median
/// physiological IBI in each record. Live pushes already contain `.hr` and must not call this helper.
public enum OuraIbiHr {
    /// Append one derived HR event for every IBI record that does not already have an HR event.
    ///
    /// All beats decoded from one record share its ring timestamp. Grouping by that timestamp therefore
    /// collapses the record to one row, matching the `(deviceId, ts)` HR key. Invalid intervals and
    /// implausible resulting rates are omitted rather than clamped.
    public static func appendingDerivedHR(toHistoryEvents events: [OuraEvent]) -> [OuraEvent] {
        let existing = Set(events.compactMap { event -> UInt32? in
            if case .hr(let hr) = event { return hr.ringTimestamp }
            return nil
        })
        let ibis = events.compactMap { event -> OuraIBI? in
            if case .ibi(let ibi) = event { return ibi }
            return nil
        }
        let derived = perRecordMedianHR(ibis)
            .filter { !existing.contains($0.ringTimestamp) }
            .map(OuraEvent.hr)
        guard !derived.isEmpty else { return events }
        return events + derived
    }

    /// Return one median HR per IBI record, ordered by ring timestamp.
    public static func perRecordMedianHR(_ ibis: [OuraIBI]) -> [OuraHR] {
        var byRingTime: [UInt32: [Int]] = [:]
        for ibi in ibis where (300...2_000).contains(ibi.ibiMs) {
            byRingTime[ibi.ringTimestamp, default: []].append(ibi.ibiMs)
        }

        return byRingTime.keys.sorted().compactMap { ringTimestamp in
            guard let intervals = byRingTime[ringTimestamp], !intervals.isEmpty else { return nil }
            let medianIbi = median(intervals)
            let bpm = Int((60_000.0 / Double(medianIbi)).rounded())
            guard (30...220).contains(bpm) else { return nil }
            return OuraHR(ringTimestamp: ringTimestamp, bpm: bpm, ibiMs: medianIbi)
        }
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
