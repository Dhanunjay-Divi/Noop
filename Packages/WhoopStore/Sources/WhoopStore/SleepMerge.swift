import Foundation

/// Merge imported and on-device-computed sleep sessions for display and export.
public enum SleepMerge {
    /// Merge imported + computed sleep, preserving EVERY session.
    ///
    /// A day with two sessions (e.g. a main night and an afternoon nap, or two nights ending the same
    /// local day) must keep BOTH — the previous per-day dictionary overwrote on collision and silently
    /// dropped one (#715). Imported sessions take precedence per day: if any imported session ends on a
    /// given local day, the computed sessions for that day yield to it (the existing imported-over-computed
    /// rule); on days with no imported session the computed sessions stand. Result is sorted by start time.
    ///
    /// Richness exception: a sparse import (no stage data on ANY of its sessions that day) must not
    /// clobber a computed day that HAS stage data — otherwise a stage-less WHOOP/Apple re-import blanks
    /// the stage breakdown for a night the strap fully staged. Days where the import carries stages, or
    /// where neither side does, keep the imported-over-computed rule unchanged. (Swift twin of the
    /// Android HealthConnectImporter richness fix, Dhanunjay-Divi/Noop#240.)
    ///
    /// - Parameter endDay: maps a session to its canonical LOCAL end-day key (callers inject their
    ///   timezone-aware keyer so this stays pure and testable).
    public static func merge(imported: [CachedSleepSession],
                             computed: [CachedSleepSession],
                             endDay: (CachedSleepSession) -> String) -> [CachedSleepSession] {
        merge(
            imported: imported,
            computed: computed,
            importedEndDay: endDay,
            computedEndDay: endDay)
    }

    /// Source-aware variant for callers that bridge each source timeline before assigning wake days.
    /// Separate keyers prevent a computed fragment from borrowing an imported source's day assignment
    /// when both namespaces contain an otherwise identical row.
    public static func merge(
        imported: [CachedSleepSession],
        computed: [CachedSleepSession],
        importedEndDay: (CachedSleepSession) -> String,
        computedEndDay: (CachedSleepSession) -> String
    ) -> [CachedSleepSession] {
        var importedByDay: [String: [CachedSleepSession]] = [:]
        for s in imported { importedByDay[importedEndDay(s), default: []].append(s) }
        var computedByDay: [String: [CachedSleepSession]] = [:]
        for s in computed { computedByDay[computedEndDay(s), default: []].append(s) }

        var out: [CachedSleepSession] = []
        out.reserveCapacity(imported.count + computed.count)
        for (day, imp) in importedByDay {
            let oura = imp.filter(OuraSleepSessionMapping.hasOuraProvenance)
            let otherImported = imp.filter { !OuraSleepSessionMapping.hasOuraProvenance($0) }
            if !oura.isEmpty, let comp = computedByDay[day] {
                // Ring-provided phases beat an overlapping local reconstruction, but a nap/fragment must
                // not erase a separate computed main night. A conventional import still outranks an
                // overlapping Oura row; non-overlapping ring blocks remain visible.
                let acceptedOura = oura.filter { ring in
                    !otherImported.contains { SleepSessionDedup.isDuplicate($0, ring) }
                }
                if otherImported.isEmpty {
                    out.append(contentsOf: acceptedOura)
                    out.append(contentsOf: comp.filter { local in
                        !acceptedOura.contains { SleepSessionDedup.isDuplicate($0, local) }
                    })
                } else {
                    out.append(contentsOf: otherImported)
                    out.append(contentsOf: acceptedOura)
                }
            } else if let comp = computedByDay[day],
                      !imp.contains(where: hasStages),
                      comp.contains(where: hasStages) {
                out.append(contentsOf: comp)   // richer computed day survives a stage-less import
            } else {
                out.append(contentsOf: imp)    // imported wins its day (unchanged rule)
            }
        }
        for (day, comp) in computedByDay where importedByDay[day] == nil {
            out.append(contentsOf: comp)
        }
        return out.sorted { $0.startTs < $1.startTs }
    }

    /// True only when the session carries a decodable, positive-duration stage payload. A nonblank but
    /// malformed string is not a richness signal and must not displace a valid computed night.
    static func hasStages(_ s: CachedSleepSession) -> Bool {
        guard let json = s.stagesJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        let recognized = Set(["wake", "awake", "light", "deep", "rem"])
        if let segments = object as? [[String: Any]] {
            return segments.contains { segment in
                guard let stage = (segment["stage"] as? String)?.lowercased(),
                      recognized.contains(stage) else { return false }
                if let start = segment["start"] as? NSNumber,
                   let end = segment["end"] as? NSNumber {
                    return end.doubleValue > start.doubleValue
                }
                return ((segment["min"] as? NSNumber)?.doubleValue ?? 0) > 0
            }
        }
        if let totals = object as? [String: Any] {
            return recognized.contains { key in
                ((totals[key] as? NSNumber)?.doubleValue ?? 0) > 0
            }
        }
        return false
    }
}
