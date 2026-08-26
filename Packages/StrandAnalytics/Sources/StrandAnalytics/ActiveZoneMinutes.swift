import Foundation

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
// Zones 1-2 (below 70% HRmax) are light activity. The guideline does not count light activity toward
// the 150-minute target, so neither does this.
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
    /// The weekly guideline target this total is measured against (default 150).
    public let weeklyTarget: Double

    public init(moderateMinutes: Double, vigorousMinutes: Double, weeklyTarget: Double) {
        self.moderateMinutes = moderateMinutes
        self.vigorousMinutes = vigorousMinutes
        self.creditedMinutes = moderateMinutes + 2.0 * vigorousMinutes
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

    /// Credit one period's time-in-zone against the guideline.
    ///
    /// Returns nil when there is no counted time at all, because "no data" and "no activity" are
    /// different claims and only one of them is honest to render as a zero.
    public static func minutes(from timeInZone: TimeInZone?,
                               weeklyTarget: Double = defaultWeeklyTarget) -> ActiveZoneMinutes? {
        guard let timeInZone, timeInZone.total > 0 else { return nil }
        let moderateSeconds = timeInZone.seconds(inZone: moderateZone)
        let vigorousSeconds = (vigorousZoneFloor...5).reduce(0.0) { sum, zone in
            sum + timeInZone.seconds(inZone: zone)
        }
        guard moderateSeconds.isFinite, vigorousSeconds.isFinite else { return nil }
        return ActiveZoneMinutes(moderateMinutes: moderateSeconds / 60.0,
                                 vigorousMinutes: vigorousSeconds / 60.0,
                                 weeklyTarget: weeklyTarget)
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
            weeklyTarget: weeklyTarget
        )
    }
}
