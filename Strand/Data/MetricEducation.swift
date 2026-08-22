import Foundation
import StrandAnalytics

/// Reusable, medically conservative education for a metric. The copy deliberately separates:
/// what the value IS, why it can be useful, how NOOP obtains it, ordinary influences, and safe actions.
/// It never turns a wearable signal into a diagnosis.
struct MetricEducation: Equatable {
    let whatItIs: String
    let whyItMatters: String
    let method: String
    let limitations: String
    let commonInfluences: [String]
    let actions: [String]
    let relatedKeys: [String]
    let cadence: String
}

/// A factual comparison of the newest value with the preceding personal history.
/// This intentionally contains no medical interpretation; the UI can render it as "above", "below",
/// "within", or "building" without calling a population range normal or abnormal.
struct MetricBaselineRead: Equatable {
    enum Position: Equatable {
        case building
        case within
        case above
        case below
    }

    let position: Position
    let latest: Double?
    let baseline: Double?
    let delta: Double?
    let zScore: Double?
    let sampleCount: Int

    /// Compare the latest finite value with up to `maxSamples` values immediately before it.
    /// Seven prior readings is a useful daily-metric cold-start; weekly estimates can request three.
    static func analyze(
        _ rawValues: [Double],
        minimumSamples: Int = 7,
        maxSamples: Int = 30
    ) -> MetricBaselineRead {
        let values = rawValues.filter(\.isFinite)
        guard let latest = values.last else {
            return MetricBaselineRead(
                position: .building,
                latest: nil,
                baseline: nil,
                delta: nil,
                zScore: nil,
                sampleCount: 0
            )
        }

        let history = Array(values.dropLast().suffix(max(1, maxSamples)))
        guard history.count >= max(1, minimumSamples) else {
            return MetricBaselineRead(
                position: .building,
                latest: latest,
                baseline: nil,
                delta: nil,
                zScore: nil,
                sampleCount: history.count
            )
        }

        let mean = history.reduce(0, +) / Double(history.count)
        let delta = latest - mean
        let variance: Double = {
            guard history.count > 1 else { return 0 }
            return history.reduce(0) { $0 + pow($1 - mean, 2) } / Double(history.count - 1)
        }()
        let sd = sqrt(max(0, variance))
        let z = sd > 0.000_001 ? delta / sd : nil

        let position: Position
        if let z, z >= 1 {
            position = .above
        } else if let z, z <= -1 {
            position = .below
        } else if z != nil {
            position = .within
        } else {
            // A perfectly flat baseline has no useful standard deviation. Treat tiny movement as within
            // range and only call a change above/below when it clears a small value-aware tolerance.
            let tolerance = max(abs(mean) * 0.02, 0.01)
            if delta > tolerance {
                position = .above
            } else if delta < -tolerance {
                position = .below
            } else {
                position = .within
            }
        }

        return MetricBaselineRead(
            position: position,
            latest: latest,
            baseline: mean,
            delta: delta,
            zScore: z,
            sampleCount: history.count
        )
    }
}

enum MetricKnowledge {
    static let safetyBoundary = String(localized:
        "NOOP cannot diagnose a condition. If a change is persistent, worsening, or accompanied by symptoms, speak with a qualified clinician. Seek urgent care for urgent symptoms.")

    static func education(for metric: MetricDescriptor) -> MetricEducation {
        switch metric.key {
        case "recovery":
            return item(
                what: "Recovery is NOOP's 0–100 estimate of how ready your body appears for load today.",
                why: "It turns several overnight recovery signals into one glanceable training-readiness trend.",
                method: "Computed on device. HRV versus your personal baseline leads the score, with resting heart rate, Sleep Score, breathing rate, skin-temperature deviation and recent load contributing when available.",
                limits: "Recovery is a wellness model, not a measurement of health or proof that you should or should not train.",
                influences: ["Training load", "Sleep quantity and timing", "Stress", "Alcohol", "Heat or dehydration", "Travel or illness"],
                actions: ["Match today's training to how you feel as well as the score.", "Prioritize sleep, food and fluids after unusually hard load.", "Log likely contributors so NOOP can test them against future Recovery."],
                related: ["hrv", "rhr", "sleep_performance", "resp_rate", "skin_temp", "strain"],
                cadence: "Updated after a scored sleep")

        case "strain":
            return item(
                what: "Effort is NOOP's cardiovascular-load score for the day.",
                why: "It helps compare how much internal load different workouts and active days placed on you.",
                method: "Computed on device from time and intensity across your heart-rate zones. The same stored score can be displayed on NOOP's 0–100 scale or the familiar 0–21 scale.",
                limits: "Heart-rate load does not fully capture muscular, technical or emotional difficulty, and wrist heart rate can miss short spikes.",
                influences: ["Workout duration", "Heart-rate intensity", "Heat", "Fitness level", "Caffeine or stress", "Sensor fit"],
                actions: ["Balance a high-load run with recovery that matches how you feel.", "Use workout type and duration alongside the score.", "Check band fit when the heart-rate trace looks implausible."],
                related: ["recovery", "sleep_performance", "hr_zones45_min", "active_kcal", "rhr"],
                cadence: "Builds through the day")

        case "sleep_performance", "sleep_score":
            return item(
                what: "Sleep Score summarizes how much useful sleep you got relative to your need and the quality of that sleep window.",
                why: "Sleep quantity, continuity and timing can affect recovery, attention, mood and training response.",
                method: "Computed on device from detected sleep, awake time and stage estimates. Imported sleep scores remain clearly separated from NOOP's Sleep Score.",
                limits: "Wearables estimate sleep and stages; they do not perform clinical sleep testing and can mistake quiet wakefulness for sleep.",
                influences: ["Time in bed", "Sleep timing", "Awakenings", "Alcohol", "Stress", "Room temperature", "Late meals or training"],
                actions: ["Protect enough time in bed for your current sleep need.", "Keep wake time reasonably consistent for several nights.", "Use how you feel and the overnight timeline to check an unusual score."],
                related: ["sleep_total_min", "sleep_efficiency", "sleep_consistency", "sleep_debt_min", "hrv", "rhr"],
                cadence: "Updated after sleep")

        case "fitness_age":
            return item(
                what: "Fitness Age compares your estimated cardiorespiratory fitness with an age-associated fitness model. It is not biological age.",
                why: "It provides a slow-moving way to see whether long-term aerobic fitness is trending younger or older than your chronological age.",
                method: "Computed on device from the Nes/HUNT fitness model using profile age and sex, resting heart rate and recent activity. VO₂max appears only when the additional profile inputs required by that estimate are available.",
                limits: "The source model's error translates to a very wide age-axis range (roughly ±19–21 years), not a precise personal confidence interval. Profile errors, sparse wear and medication that changes heart rate can move the estimate.",
                influences: ["Aerobic fitness", "Resting heart rate trend", "Recent activity coverage", "Profile accuracy", "Heart-rate-affecting medication"],
                actions: ["Judge change over months, not from one weekly update.", "Build consistent aerobic work and regular strength training.", "Keep age, sex and body-profile inputs accurate."],
                related: ["vo2max_est", "rhr", "vitality", "body_age", "strain"],
                cadence: "Updated weekly")

        case "vitality":
            return item(
                what: "Vitality is NOOP's transparent 0–100 long-term wellness composite.",
                why: "It combines several slow-moving inputs so improving one area does not hide weakening signals elsewhere.",
                method: "Computed on device from a trailing 21-day window. Each included factor needs at least 14 observed days, and the score needs at least three physiological domains.",
                limits: "This experimental combination has not been clinically validated and cannot measure overall health or longevity.",
                influences: ["Resting heart rate", "Sleep duration and consistency", "HRV", "Profile age"],
                actions: ["Open the contribution view before acting on the total.", "Choose one sustainable input to improve for several weeks.", "Treat short-term movement as noise unless the contributors moved too."],
                related: ["body_age", "fitness_age", "rhr", "hrv", "sleep_consistency", "body_fat"],
                cadence: "Long-term estimate")

        case "body_age":
            return item(
                what: "Wellness Age is the age-shaped readout of NOOP's experimental Vitality model. It is not biological, medical, or WHOOP Age.",
                why: "It offers one slow-moving comparison between supported lifestyle signals and your profile age.",
                method: "Derived on device from at least 14 observed days per included factor and at least three physiological domains. It is not read directly from any sensor.",
                limits: "The literature-inspired factors were not validated together as a clinical model, and NOOP has no validated personal confidence interval. Do not use it to estimate ageing, disease risk, or lifespan.",
                influences: ["Vitality inputs", "Profile age", "Sleep duration and consistency", "Resting heart rate", "HRV"],
                actions: ["Inspect the contributing factors rather than chasing the age number.", "Look for sustained movement across several weeks.", "Keep your profile age current."],
                related: ["vitality", "fitness_age", "rhr", "hrv", "body_fat"],
                cadence: "Long-term estimate")

        case "hrv":
            return item(
                what: "Heart-rate variability (HRV) is the variation in time between consecutive heart beats. NOOP uses RMSSD in milliseconds.",
                why: "Compared with your own baseline, overnight HRV can reflect shifts in autonomic recovery and accumulated stress.",
                method: "Derived from clean beat-to-beat intervals. Dense overnight strap data is preferred; sparse imported readings remain source-labelled.",
                limits: "HRV differs greatly between people. Rhythm artifacts, short samples and timing can change it, so compare with your own trend.",
                influences: ["Training load", "Sleep", "Alcohol", "Psychological stress", "Heat or dehydration", "Travel or illness", "Measurement timing"],
                actions: ["Compare like-for-like overnight readings.", "Consider an easier day when HRV and other recovery signals shift together and you also feel run down.", "Log alcohol, travel, stress and hard training to test patterns."],
                related: ["rhr", "recovery", "sleep_performance", "resp_rate", "skin_temp"],
                cadence: "Best read overnight")

        case "rhr", "resting_hr":
            return item(
                what: "Resting heart rate is your heart rate during a low-activity or sleep period.",
                why: "A sustained change versus your own baseline can reflect changes in recovery, fitness, stress or environment.",
                method: "Taken from the lowest stable overnight/rest period available from the selected source.",
                limits: "Medication, posture, sensor fit and measurement timing can shift the number. One reading is rarely meaningful alone.",
                influences: ["Fitness", "Training fatigue", "Sleep loss", "Stress", "Alcohol", "Heat or dehydration", "Travel or illness"],
                actions: ["Compare several similar nights rather than one point.", "Check sleep, recent load, fluids and how you feel when it rises with other recovery signals.", "Confirm an implausible value with another reliable measurement."],
                related: ["hrv", "recovery", "resp_rate", "skin_temp", "sleep_performance"],
                cadence: "Best read overnight")

        case "resp_rate":
            return item(
                what: "Respiratory rate is the estimated number of breaths per minute during rest or sleep.",
                why: "It is usually steady for an individual, so a sustained shift can be a useful context signal.",
                method: "Estimated from the selected wearable or derived overnight signal and compared with your personal history.",
                limits: "Movement, fit and source algorithms affect it. It is not a lung-function test.",
                influences: ["Altitude", "Sleep environment", "Allergies", "Hard training", "Stress", "Travel or illness", "Sensor quality"],
                actions: ["Recheck across another night when you feel well.", "Look for corroborating HRV, resting-HR or temperature shifts.", "Speak with a clinician for persistent changes or breathing symptoms."],
                related: ["rhr", "hrv", "skin_temp", "spo2", "recovery"],
                cadence: "Best read overnight")

        case "spo2":
            return item(
                what: "Blood oxygen (SpO₂) estimates the percentage of hemoglobin carrying oxygen.",
                why: "Repeated, trustworthy measurements can provide context about overnight oxygenation and altitude response.",
                method: "Imported or measured by a compatible optical sensor; NOOP preserves the source rather than treating every device as equivalent.",
                limits: "Cold skin, motion, fit, skin characteristics and device quality can distort wrist readings. NOOP is not a pulse oximeter or medical device.",
                influences: ["Altitude", "Sensor fit", "Cold skin", "Movement", "Sleep position", "Respiratory changes"],
                actions: ["Repeat an unexpected reading with warm skin and a secure fit.", "Confirm concerning values with a validated device.", "Seek medical advice for repeated low validated readings or symptoms."],
                related: ["resp_rate", "rhr", "skin_temp", "sleep_performance"],
                cadence: "Source dependent")

        case "skin_temp", "skin_temp_dev_c":
            return item(
                what: "Skin temperature is either an absolute wearable reading or a deviation from your personal overnight baseline, depending on source.",
                why: "Its direction over several nights can add context to recovery, environment and cycle-aware trends.",
                method: "Measured at the wearable surface or computed as a deviation. NOOP labels source and preserves the distinction from core body temperature.",
                limits: "Skin temperature is not core temperature. Bedding, room temperature, placement and circulation can move it.",
                influences: ["Room and bedding temperature", "Menstrual-cycle phase", "Alcohol", "Travel", "Training load", "Illness", "Sensor placement"],
                actions: ["Compare nights with similar room and wear conditions.", "Use it only with other signals and how you feel.", "Use a clinical thermometer when body temperature itself matters."],
                related: ["resp_rate", "rhr", "hrv", "recovery", "sleep_performance"],
                cadence: "Best read overnight")

        case "body_temp":
            return item(
                what: "Body temperature is an absolute temperature reading imported from Apple Health.",
                why: "A repeated change can add context to how you feel, but one consumer-device reading should not be interpreted alone.",
                method: "NOOP preserves Apple Health's absolute body-temperature value in its own series. It is never substituted for WHOOP skin temperature or baseline deviation.",
                limits: "Source devices, measurement site and timing vary. NOOP is not a thermometer or medical device.",
                influences: ["Measurement method", "Time of day", "Recent activity", "Environment", "Illness", "Medications"],
                actions: ["Check the original source and time in Apple Health.", "Confirm an unexpected value with a suitable thermometer.", "Seek medical advice when symptoms or a confirmed concerning temperature warrant it."],
                related: ["wrist_temp", "skin_temp", "resp_rate", "rhr"],
                cadence: "When recorded")

        case "wrist_temp":
            return item(
                what: "Sleeping wrist temperature is an absolute peripheral-temperature reading imported from Apple Health.",
                why: "Its overnight trend can add context to recovery, environment and cycle-aware patterns.",
                method: "NOOP stores it in a dedicated Apple Health series, separate from body temperature and WHOOP skin-temperature deviation.",
                limits: "Wrist temperature is not core body temperature. Fit, bedding, room conditions and circulation affect it.",
                influences: ["Room and bedding temperature", "Sensor fit", "Menstrual-cycle phase", "Alcohol", "Travel", "Illness"],
                actions: ["Compare readings from the same device over several nights.", "Check fit and sleeping conditions when the trend changes.", "Use a clinical thermometer when body temperature itself matters."],
                related: ["body_temp", "skin_temp", "resp_rate", "sleep_performance"],
                cadence: "Best read overnight")

        case "avg_hr", "max_hr":
            return item(
                what: metric.key == "max_hr" ? "Maximum heart rate is the highest captured heart-rate sample in the selected period." : "Average heart rate is the mean captured heart rate across the selected period.",
                why: "Together with activity context, it helps explain cardiovascular demand and sensor coverage.",
                method: "Calculated from the source's available heart-rate samples.",
                limits: "Sampling cadence and optical artifacts can miss peaks or bias an average.",
                influences: ["Activity intensity", "Heat", "Stress", "Caffeine", "Fitness", "Sensor fit"],
                actions: ["View the full heart-rate trace with workout context.", "Check fit when peaks look implausible.", "Compare similar activities rather than unrelated days."],
                related: ["strain", "active_kcal", "hr_zones45_min", "rhr"],
                cadence: "Builds with heart-rate coverage")

        case "vo2max", "vo2max_est":
            return item(
                what: "VO₂max estimates maximal oxygen use relative to body mass.",
                why: "It is a useful long-term marker of cardiorespiratory fitness when measured consistently.",
                method: metric.key == "vo2max_est"
                    ? "Estimated on device from the Fitness Age model when the required profile inputs are available."
                    : "Imported from the named source and kept separate from NOOP's estimate.",
                limits: "A wearable estimate is not a laboratory exercise test and can move with profile or heart-rate errors.",
                influences: ["Aerobic training", "Body mass", "Resting heart rate", "Profile accuracy", "Exercise-test quality"],
                actions: ["Follow the multi-week trend.", "Use consistent aerobic training plus recovery.", "Use a supervised lab test when precision matters."],
                related: ["fitness_age", "rhr", "strain", "weight"],
                cadence: "Long-term estimate")

        case "stress":
            return item(
                what: "Stress is a non-clinical estimate of current autonomic load.",
                why: "It can help connect physiology with work, exercise, sleep and self-reported context.",
                method: "Computed from heart-rate and variability signals or imported from the named source; source scales remain distinct.",
                limits: "It cannot tell whether arousal is harmful, emotional or exercise-related and is not a mental-health assessment.",
                influences: ["Exercise", "Work or emotional load", "Caffeine", "Sleep", "Heat", "Illness", "Measurement quality"],
                actions: ["Add context before judging the number.", "Try a short breathing or movement break when you also feel tense.", "Track which routines repeatedly bring it back toward your range."],
                related: ["hrv", "rhr", "sleep_performance", "mood", "strain"],
                cadence: "Changes through the day")

        case "steps", "steps_est":
            let imported = metric.source == "apple-health" || metric.source == "xiaomi-band"
            let motionDerived = metric.source == "my-whoop"
            return item(
                what: imported
                    ? "Steps are a count imported from the named pedometer source."
                    : "This is an on-device estimate that maps strap motion to a step-like daily total.",
                why: "Daily movement complements workout load and is an easy long-term activity habit to follow.",
                method: imported
                    ? "Imported from the source named on the reading; NOOP preserves it separately from strap estimates."
                    : (metric.key == "steps"
                        ? "Estimated on device from WHOOP 5/MG @57 motion-counter deltas divided by your step-scale setting. It is not a validated pedometer count."
                        : "Estimated on device from strap motion and personal calibration. It is not a validated pedometer count."),
                limits: motionDerived
                    ? "Strap motion can differ from footfalls, and the scale is a user preference rather than a validated step calibration. Treat the number as an estimate."
                    : "Devices differ, and cycling, pushing a stroller or arm movement can under- or over-count.",
                influences: ["Walking", "Daily routine", "Device placement", "Activity type", "Source algorithm"],
                actions: ["Compare against the same source over time.", "Build movement gradually around your current routine.", "Use minutes or distance when the activity type is not step-like."],
                related: ["strain", "active_kcal", "vitality", "fitness_age"],
                cadence: "Builds through the day")

        case "sleep_efficiency":
            return item(
                what: "Sleep efficiency is the fraction of your in-bed window that NOOP classified as asleep.",
                why: "It helps distinguish too little opportunity from a fragmented or wakeful sleep window.",
                method: "Calculated as asleep time divided by time in bed and displayed as a percentage.",
                limits: "Quiet wakefulness can be classified as sleep, so it is an estimate rather than a clinical measure.",
                influences: ["Awakenings", "Time awake in bed", "Stress", "Alcohol", "Room conditions", "Detection quality"],
                actions: ["Use the sleep timeline to inspect long awake periods.", "Keep wake time consistent for several nights.", "Discuss persistent sleep concerns with a clinician."],
                related: ["sleep_total_min", "sleep_consistency", "sleep_debt_min", "sleep_performance"],
                cadence: "Updated after sleep")

        case let key where key.hasPrefix("sleep_") || ["in_bed_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct"].contains(key):
            return item(
                what: "This metric describes one part of your detected sleep window, need or stage estimate.",
                why: "Breaking Sleep Score into components can show whether opportunity, continuity, timing or restorative sleep changed.",
                method: "Calculated on device from the sleep timeline or imported from the named source.",
                limits: "Wearable sleep stages are estimates and should not be interpreted as clinical sleep staging.",
                influences: ["Time in bed", "Sleep timing", "Awakenings", "Alcohol", "Stress", "Room conditions"],
                actions: ["Use several nights rather than one stage estimate.", "Protect enough sleep opportunity.", "Check the timeline when a total looks wrong."],
                related: ["sleep_performance", "hrv", "rhr"],
                cadence: "Updated after sleep")

        case "weight", "body_fat", "lean_mass", "bmi":
            return item(
                what: "This body-composition value is imported from Apple Health or another connected source.",
                why: "Long-term trends can provide context for training, nutrition and cardiorespiratory estimates.",
                method: "NOOP displays the source value and does not infer a clinical assessment from it.",
                limits: "Hydration, device method and measurement timing can shift body-composition estimates.",
                influences: ["Hydration", "Measurement timing", "Device method", "Nutrition", "Training"],
                actions: ["Measure under similar conditions.", "Follow the multi-week trend.", "Use a clinician-grade assessment when precision matters."],
                related: ["vitality", "body_age", "fitness_age", "active_kcal"],
                cadence: "Source dependent")

        case "energy_kcal", "active_kcal", "basal_kcal", "total_kcal":
            return item(
                what: "Energy describes calories expended over the selected period. Active energy is movement above rest; resting energy is baseline metabolism; total energy is their sum.",
                why: "It gives broad activity context but is most useful as a consistent trend, not an exact food target.",
                method: "Apple Health active and resting components stay separate and are summed only when both exist. A strap-only reading is shown as one combined HR-derived estimate; NOOP does not invent its split or add it to Apple Health.",
                limits: "Wearable calorie estimates can have large individual error. A partial day or gaps in heart-rate wear can understate a combined estimate.",
                influences: ["Activity duration", "Intensity", "Body profile", "Heart-rate coverage", "Source algorithm"],
                actions: ["Use the same source for comparisons.", "Pair the estimate with activity and weight trends.", "Avoid matching food intake to a single-day number exactly."],
                related: ["strain", "steps", "avg_hr", "weight"],
                cadence: "Builds through the day")

        case "calories_in", "protein_g", "carbs_g", "fat_g":
            return item(
                what: "This nutrition value comes from meals you logged in NOOP or imported from a food tracker.",
                why: "Logged intake can be tested against sleep, training and recovery trends.",
                method: "Manual meals and imported daily summaries are added as entered. A nutrient you did not provide stays missing; NOOP does not invent a zero or a meal.",
                limits: "Portion estimates and incomplete logging can outweigh small day-to-day differences.",
                influences: ["Portion accuracy", "Missing entries", "Food database", "Meal timing"],
                actions: ["Aim for consistent logging before drawing conclusions.", "Use weekly patterns rather than one day.", "Consult a qualified professional for individualized nutrition care."],
                related: ["weight", "strain", "recovery", "sleep_performance"],
                cadence: "Depends on logging")

        case "mood":
            return item(
                what: "Mood is your own non-clinical daily check-in.",
                why: "It keeps subjective experience beside physiology instead of assuming the sensors know how you feel.",
                method: "Stored exactly as you log it and kept on device unless you choose to share it.",
                limits: "A simple check-in is not a mental-health screening or diagnosis.",
                influences: ["Sleep", "Stress", "Social context", "Training", "Pain", "Life events"],
                actions: ["Log at a consistent time.", "Add journal context for unusual days.", "Seek qualified support for persistent distress or safety concerns."],
                related: ["stress", "sleep_performance", "recovery", "strain"],
                cadence: "Depends on logging")

        default:
            return item(
                what: metric.description ?? "\(metric.title) is a \(MetricCatalog.categoryDisplayName(metric.category).lowercased()) metric recorded in your NOOP timeline.",
                why: "Its trend can add context when compared with your own history and related signals.",
                method: "Measured, imported or derived by the source shown on each reading.",
                limits: "Source algorithms and coverage differ. One value should not be treated as a diagnosis or a complete picture of health.",
                influences: ["Measurement coverage", "Sensor fit", "Daily routine", "Sleep", "Training", "Environment"],
                actions: ["Follow the trend from a consistent source.", "Check related metrics and how you feel.", "Confirm implausible readings before acting on them."],
                related: [],
                cadence: "Source dependent")
        }
    }

    static func dataKind(for metric: MetricDescriptor) -> String {
        let derived: Set<String> = [
            "recovery", "strain", "sleep_performance", "fitness_age", "vo2max_est",
            "vitality", "body_age", "stress", "steps_est",
        ]
        // WHOOP 5/MG `steps` under `my-whoop` is the @57 motion-counter estimate. It deliberately keeps
        // the legacy series key for compatibility, so source + key—not key alone—must classify it.
        if derived.contains(metric.key) || (metric.key == "steps" && metric.source == "my-whoop") {
            return String(localized: "Derived on device")
        }
        if metric.source == "nutrition-log" {
            return String(localized: "Logged / imported")
        }
        if metric.source == "apple-health" || metric.source == "xiaomi-band"
            || metric.source == "nutrition-csv" {
            return String(localized: "Imported")
        }
        return String(localized: "Measured / resolved")
    }

    private static func item(
        what: String,
        why: String,
        method: String,
        limits: String,
        influences: [String],
        actions: [String],
        related: [String],
        cadence: String
    ) -> MetricEducation {
        MetricEducation(
            whatItIs: what,
            whyItMatters: why,
            method: method,
            limitations: limits,
            commonInfluences: influences,
            actions: actions,
            relatedKeys: related,
            cadence: cadence
        )
    }
}
