import Foundation

// Time-axis reconstruction for Oura's burst-written SleepNet hypnogram.
// Adapted from ryanbr/noop's clean-room Oura implementation (upstream #1246); the repository's
// LICENSE/NOTICE/ATTRIBUTION files retain the applicable provenance and terms.

/// One sleep-phase record in event-log arrival order. The envelope timestamp is the time the ring wrote
/// the analysis, not the time represented by each individual 30-second phase code.
public struct OuraHypnogramRecord: Equatable, Sendable {
    public let ringTimestamp: UInt32
    public let phases: [OuraSleepPhase]

    public init(ringTimestamp: UInt32, phases: [OuraSleepPhase]) {
        self.ringTimestamp = ringTimestamp
        self.phases = phases
    }
}

/// A completed sequence of adjacent sleep-phase records, normally one night's finalization burst.
public struct OuraHypnogramBurst: Equatable, Sendable {
    public let records: [OuraHypnogramRecord]

    public init(records: [OuraHypnogramRecord]) {
        self.records = records
    }

    public var totalCodes: Int { records.reduce(0) { $0 + $1.phases.count } }
    public var lastRingTimestamp: UInt32 { records.last?.ringTimestamp ?? 0 }

    /// Arrival order remains authoritative because burst envelope times are nearly identical write times.
    /// Surface a reversal so callers can log potentially questionable input without reordering it.
    public var hasNonMonotonicRingTimes: Bool {
        zip(records, records.dropFirst()).contains { $1.ringTimestamp < $0.ringTimestamp }
    }

    /// Lay every code backward from the anchored burst end at the documented 30-second SleepNet epoch.
    /// Erased-flash placeholders are removed only after assigning positions, leaving an honest gap without
    /// pulling the real codes on either side together. A plausible 0x49 onset may clip leading codes; an
    /// invalid clamp that would remove every written code is ignored.
    public func codesWithTimes(
        endUnixSeconds: Int,
        sleepStartUnixSeconds: Int? = nil,
        secondsPerCode: Int = 30
    ) -> [(phase: OuraSleepPhase, ts: Int)] {
        let n = totalCodes
        var laid: [(phase: OuraSleepPhase, ts: Int)] = []
        laid.reserveCapacity(n)

        var position = 0
        for record in records {
            for phase in record.phases {
                laid.append((phase, endUnixSeconds - (n - position) * secondsPerCode))
                position += 1
            }
        }

        let written = laid.filter { !$0.phase.unwritten }
        guard let start = sleepStartUnixSeconds else { return written }
        let clipped = written.filter { $0.ts >= start }
        return clipped.isEmpty ? written : clipped
    }
}

/// Groups adjacent phase records into the burst that must share one reconstructed time axis.
public final class OuraHypnogramAssembler {
    /// Oura ring timestamps use 100 ms ticks; 600 ticks is a generous 60-second burst boundary.
    public let burstGapTicks: UInt32
    private var current: [OuraHypnogramRecord] = []

    public init(burstGapTicks: UInt32 = 600) {
        self.burstGapTicks = burstGapTicks
    }

    /// Returns the preceding burst when a large timestamp gap starts a new one.
    public func feed(ringTimestamp: UInt32, phases: [OuraSleepPhase]) -> OuraHypnogramBurst? {
        guard !phases.isEmpty else { return nil }
        let record = OuraHypnogramRecord(ringTimestamp: ringTimestamp, phases: phases)
        if let last = current.last {
            let gap = ringTimestamp >= last.ringTimestamp
                ? ringTimestamp - last.ringTimestamp
                : last.ringTimestamp - ringTimestamp
            if gap > burstGapTicks {
                let completed = OuraHypnogramBurst(records: current)
                current = [record]
                return completed
            }
        }
        current.append(record)
        return nil
    }

    public func flush() -> OuraHypnogramBurst? {
        guard !current.isEmpty else { return nil }
        let completed = OuraHypnogramBurst(records: current)
        current.removeAll(keepingCapacity: true)
        return completed
    }

    public func reset() {
        current.removeAll(keepingCapacity: true)
    }

    public var pendingRecordCount: Int { current.count }
}
