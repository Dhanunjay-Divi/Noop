import Foundation
import WhoopProtocol

// ActiveZoneMinutes.swift — weekly moderate-to-vigorous physical activity (MVPA) against the
// public-health guideline, computed from time-in-zone.
//
// WHY THIS EXISTS
// Every serious competitor surfaces an activity-minutes metric: Fitbit Active Zone Minutes,
// Garmin Intensity Minutes, Apple Exercise Minutes. NOOP had heart-rate zones and Effort but no
// guideline-referenced minutes total, which left a real question unanswered: "am I meeting the
// recommended amount of activity?" Effort answers "how hard was today"; that is a different question
// and cannot substitute.
//
// THE STANDARD
// WHO 2020 physical-activity guidelines and the AHA recommend adults get, per week, either
// 150 minutes of moderate-intensity aerobic activity OR 75 minutes of vigorous-intensity, or an
// equivalent combination. The 2:1 equivalence is the guideline's own, not a NOOP invention, which is
// why one vigorous minute counts as two credited minutes here. The default weekly target is therefore
// 150 credited minutes, reachable by 150 moderate, 75 vigorous, or any mix.
//
// INTENSITY MAPPING, AND ITS HONEST LIMIT
// ACSM classifies intensity by %HRmax as moderate 64-76% and vigorous 77-95%. NOOP's display zones
// (HRZones.swift) use edges at 50/60/70/80/90/100 %HRmax, so the two do not align exactly. This maps
// moderate to Zone 3 (70-80%) and vigorous to Zones 4-5 (>=80%), which keeps every credited minute
// inside or above the ACSM moderate band rather than crediting light activity. The consequence is
// deliberate and stated plainly: activity in the 64-70% window is real moderate activity by ACSM and
// is NOT credited here, so this total is CONSERVATIVE. Under-crediting is the right direction for a
// guideline metric; a total that flatters the user is worse than one that slightly understates.
//
// Zones 1-2 are not credited by this conservative mapping. That includes some real moderate activity
// in the 64-70% window described above; it is withheld rather than mislabeled or over-counted.
//
// PROVENANCE
// Guideline: WHO Guidelines on physical activity and sedentary behaviour (2020); AHA adult
// recommendations. Intensity bands: ACSM Guidelines for Exercise Testing and Prescription.
// Zone edges and HRmax come from NOOP's own HRZones (Tanaka 2001). No competitor implementation was
// referenced; the 2:1 credit and 150-minute target are the published guideline's.

/// Credited moderate-to-vigorous minutes for one period, against the weekly guideline.
public struct ActiveZoneMinutes: Equatable, Sendable {
    /// Minutes in the moderate band (Zone 3), credited 1:1.
    public let moderateMinutes: Double
    /// Minutes in the vigorous band (Zones 4-5), credited 2:1 per the guideline.
    public let vigorousMinutes: Double
    /// Credited total: `moderateMinutes + 2 * vigorousMinutes`.
    public let creditedMinutes: Double
    /// Heart-rate minutes directly covered by usable sample intervals.
    public let observedMinutes: Double
    /// The weekly guideline target this total is measured against (default 150).
    public let weeklyTarget: Double

    public init(moderateMinutes: Double, vigorousMinutes: Double, weeklyTarget: Double,
                observedMinutes: Double? = nil) {
        self.moderateMinutes = moderateMinutes
        self.vigorousMinutes = vigorousMinutes
        self.creditedMinutes = moderateMinutes + 2.0 * vigorousMinutes
        self.observedMinutes = observedMinutes ?? (moderateMinutes + vigorousMinutes)
        self.weeklyTarget = weeklyTarget
    }

    /// Progress toward the weekly target as a fraction. Not clamped: exceeding the guideline is a real
    /// and reportable outcome, and silently capping it at 1.0 would hide it.
    public var targetFraction: Double {
        guard weeklyTarget > 0 else { return 0 }
        return creditedMinutes / weeklyTarget
    }

    /// True once the weekly guideline is met.
    public var meetsWeeklyGuideline: Bool { creditedMinutes >= weeklyTarget }
}

public enum ActiveZoneMinutesCalculator {

    /// WHO/AHA weekly target in credited minutes.
    public static let defaultWeeklyTarget: Double = 150

    /// Lowest zone credited as moderate. Zone 3 is 70-80% HRmax.
    public static let moderateZone = 3
    /// Lowest zone credited as vigorous. Zone 4 is 80-90% HRmax; Zone 5 is above it.
    public static let vigorousZoneFloor = 4
    /// Raw-HR gaps longer than this are missing coverage, not continuous activity.
    public static let maximumSampleGapSeconds: Double = 10

    /// Generic metric-series keys. They are shared by the scorer, persistence, and both clients.
    public static let moderateSeriesKey = "active_zone_moderate_min"
    public static let vigorousSeriesKey = "active_zone_vigorous_min"
    public static let creditedSeriesKey = "active_zone_credited_min"
    public static let observedSeriesKey = "active_zone_observed_min"
    public static let managedSeriesKeys: Set<String> = [
        moderateSeriesKey, vigorousSeriesKey, creditedSeriesKey, observedSeriesKey
    ]

    /// Credit one period's time-in-zone against the guideline.
    ///
    /// Returns nil when there is no counted time at all, because "no data" and "no activity" are
    /// different claims and only one of them is honest to render as a zero.
    public static func minutes(from timeInZone: TimeInZone?,
                               weeklyTarget: Double = defaultWeeklyTarget) -> ActiveZoneMinutes? {
        guard weeklyTarget.isFinite, weeklyTarget > 0,
              let timeInZone,
              timeInZone.total.isFinite, timeInZone.total > 0,
              timeInZone.belowZone1.isFinite, timeInZone.belowZone1 >= 0,
              timeInZone.seconds.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }
        let moderateSeconds = timeInZone.seconds(inZone: moderateZone)
        let vigorousSeconds = (vigorousZoneFloor...5).reduce(0.0) { sum, zone in
            sum + timeInZone.seconds(inZone: zone)
        }
        return ActiveZoneMinutes(moderateMinutes: moderateSeconds / 60.0,
                                 vigorousMinutes: vigorousSeconds / 60.0,
                                 weeklyTarget: weeklyTarget,
                                 observedMinutes: timeInZone.total / 60.0)
    }

    /// Compute from raw HR without filling sensor gaps. Only the interval between two plausible readings
    /// at most `maximumGapSeconds` apart is observed; the final sample receives no invented tail duration.
    /// This is the production path. The general HR-zone display helper deliberately infers a tail interval,
    /// which is useful for a chart but too optimistic for a public-health activity total.
    public static func minutes(from hr: [HRSample],
                               zoneSet: HRZoneSet,
                               maximumGapSeconds: Double = maximumSampleGapSeconds,
                               weeklyTarget: Double = defaultWeeklyTarget) -> ActiveZoneMinutes? {
        guard maximumGapSeconds.isFinite, maximumGapSeconds > 0,
              zoneSet.maxHR.isFinite, zoneSet.maxHR > 0 else { return nil }

        var samples: [HRSample] = []
        for sample in hr.sorted(by: { $0.ts < $1.ts }) where (25...250).contains(sample.bpm) {
            if samples.last?.ts != sample.ts {
                samples.append(sample)
            }
        }
        guard samples.count >= 2 else { return nil }

        var durations = [Double](repeating: 0, count: samples.count)
        for index in 0..<(samples.count - 1) {
            let gap = Double(samples[index + 1].ts) - Double(samples[index].ts)
            if gap > 0, gap <= maximumGapSeconds {
                durations[index] = gap
            }
        }
        let timeInZone = HRZones.timeInZone(samples, durationsSeconds: durations, zoneSet: zoneSet)
        return minutes(from: timeInZone, weeklyTarget: weeklyTarget)
    }

    /// Sum several periods (for example seven daily time-in-zone records) into one weekly total.
    ///
    /// Days with no counted time contribute nothing rather than dragging the week toward zero, and a
    /// week with no usable day at all returns nil rather than a fabricated 0 of 150.
    public static func weekly(from periods: [TimeInZone?],
                              weeklyTarget: Double = defaultWeeklyTarget) -> ActiveZoneMinutes? {
        let credited = periods.compactMap { minutes(from: $0, weeklyTarget: weeklyTarget) }
        guard !credited.isEmpty else { return nil }
        return ActiveZoneMinutes(
            moderateMinutes: credited.reduce(0) { $0 + $1.moderateMinutes },
            vigorousMinutes: credited.reduce(0) { $0 + $1.vigorousMinutes },
            weeklyTarget: weeklyTarget,
            observedMinutes: credited.reduce(0) { $0 + $1.observedMinutes }
        )
    }

    /// Stable long-format projection used by both persistence lanes.
    public static func seriesValues(_ minutes: ActiveZoneMinutes?) -> [String: Double] {
        guard let minutes,
              minutes.moderateMinutes.isFinite, minutes.moderateMinutes >= 0,
              minutes.vigorousMinutes.isFinite, minutes.vigorousMinutes >= 0,
              minutes.creditedMinutes.isFinite, minutes.creditedMinutes >= 0,
              minutes.observedMinutes.isFinite, minutes.observedMinutes > 0
        else { return [:] }
        return [
            moderateSeriesKey: minutes.moderateMinutes,
            vigorousSeriesKey: minutes.vigorousMinutes,
            creditedSeriesKey: minutes.creditedMinutes,
            observedSeriesKey: minutes.observedMinutes
        ]
    }
}
