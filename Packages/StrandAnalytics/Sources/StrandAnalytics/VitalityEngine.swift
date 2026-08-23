import Foundation

// VitalityEngine.swift — an experimental, transparent 0–100 wellness composite plus an age-shaped
// "Wellness Age" readout. The persisted `body_age` key/result property remain for database compatibility.
//
// This is NOT WHOOP Age, a biological clock, or a validated multivariable clinical model. It maps each
// wearable-measurable input to a literature-inspired all-cause-mortality hazard ratio relative to a reference,
// sum the log-hazards with an overlap correction (the inputs are correlated, so the naive sum overstates),
// and convert that combined hazard into a "years of aging" offset using the Gompertz mortality-rate
// doubling time (mortality roughly doubles every ~8 years, so 1 doubling of hazard ≈ 8 years of age).
//
// Wellness Age = chronological age + Δage. An average-for-their-age person nets ~0 and reads at their own age;
// healthier-than-average reads younger, less healthy reads older. Presented with a ±band and a hard
// "wellness trend, not a biological/clinical age" disclaimer, gated on a minimum number of inputs.
//
// Per-factor hazard ratios are taken from large cohorts / meta-analyses (UK Biobank, FRIEND, pooled
// step- and activity-mortality meta-analyses, sleep-regularity and HRV cohorts). They are deliberately
// CONSERVATIVE and the model is clamped, because this is a wellness estimate, not a diagnosis.
public enum VitalityEngine {

    // Gompertz: mortality-rate doubling time ≈ 8 years → ln(hazard) per year of age = ln(2)/8.
    // SOURCE: the Gompertz–Makeham law of mortality; the ~8-year adult mortality-rate doubling time
    // (MRDT) is a long-standing demographic regularity (Gompertz 1825; modern MRDT reviews).
    static let lnHazardPerYear = 0.6931471805599453 / 8.0   // ≈ 0.0866
    /// Correlated inputs (fitness, RHR, activity all move together) → shrink the naive log-hazard sum so
    /// we don't multiply the same underlying signal several times. 0.75 is a deliberately gentle shrink.
    ///
    /// PROVENANCE (2026-08-22): **internal, uncited.** There is no published shrink coefficient for this
    /// particular basket of wearable inputs; 0.75 is a conservative engineering choice (it always REDUCES
    /// the magnitude of the age offset, i.e. it errs toward "closer to your real age"). It is not a
    /// population-derived constant and must not be presented as one.
    static let overlapShrink = 0.75
    /// Body Age is clamped to a sane band; Vitality maps Δage linearly around 50 (= "at your age").
    static let minBodyAge = 20.0, maxBodyAge = 90.0
    /// PROVENANCE: **internal, uncited** presentation scaling (points of Vitality per year of Δage).
    /// Chosen so a ±10-year offset spans most of the 0–100 axis; carries no epidemiological meaning.
    static let vitalityPerYear = 2.5   // each year younger than your age = +2.5 Vitality points

    /// The wearable inputs Vitality reads. All optional — the score uses whatever is present (≥ minFactors).
    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        public var restingHR: Double?          // bpm
        public var vo2max: Double?             // ml/kg/min (e.g. from FitnessAgeEngine)
        public var expectedVO2max: Double?     // age/sex-expected ml/kg/min (the reference for vo2max)
        public var sleepHours: Double?         // mean nightly sleep
        public var sleepConsistency: Double?   // 0–1 regularity (1 = perfectly regular)
        public var rmssd: Double?              // ms, nocturnal HRV
        public var rmssdNorm: Double?          // age/sex-normative RMSSD (the reference)
        public var steps: Double?              // mean daily steps
        public init(chronoAge: Double, restingHR: Double? = nil, vo2max: Double? = nil,
                    expectedVO2max: Double? = nil, sleepHours: Double? = nil,
                    sleepConsistency: Double? = nil, rmssd: Double? = nil,
                    rmssdNorm: Double? = nil, steps: Double? = nil) {
            self.chronoAge = chronoAge; self.restingHR = restingHR; self.vo2max = vo2max
            self.expectedVO2max = expectedVO2max; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.rmssd = rmssd
            self.rmssdNorm = rmssdNorm; self.steps = steps
        }
    }

    /// One factor's contribution: its label and signed log-hazard vs the population reference
    /// (positive = ages you, negative = protective).
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let lnHazard: Double
        public init(key: String, label: String, lnHazard: Double) {
            self.key = key; self.label = label; self.lnHazard = lnHazard
        }
    }

    public struct Result: Equatable, Sendable {
        public let vitality: Double        // 0–100 (50 = typical for your age)
        public let bodyAge: Double         // years, clamped
        public let chronoAge: Double
        public let deltaYears: Double      // chronoAge − bodyAge (positive = younger than your age)
        public let bandYears: Double
        public let contributions: [Contribution]   // for the "what's driving this" breakdown
        public let factorsUsed: Int
        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
        }
    }

    /// Minimum distinct factors and physiological domains before we'll show a number. Duration and
    /// duration-consistency are one sleep domain; they cannot manufacture readiness by themselves.
    public static let minFactors = 3
    public static let minDomains = 3
    /// The ± presentation range (years) for Wellness Age.
    ///
    /// HONESTY CORRECTION (2026-08-22, peer review): this was 0.0, which implied a point estimate and made
    /// Wellness Age look MORE precise than Fitness Age — even though Fitness Age honestly publishes a
    /// ~±19–21 y band from its model's SEE, and Wellness Age is the more speculative of the two (it chains
    /// literature hazard ratios through a Gompertz conversion with an uncited overlap shrink).
    ///
    /// There is no published confidence interval for this composite, so the band is **explicitly a
    /// model-level honesty floor, not a computed CI**. One Gompertz doubling (~8 y of age-equivalent) is
    /// the natural unit of this conversion, so the range says "this model cannot resolve better than
    /// about one doubling." It does not narrow when more inputs are present: no fitted covariance/error
    /// model proves that another correlated wearable signal improves individual precision. It NEVER
    /// claims statistical coverage; UI copy must read "approximately ±8 years", not "95% CI".
    public static let bandYears: Double = 8.0

    /// Kept as a function so callers do not invent their own factor-count adjustment. `factorsUsed` is
    /// intentionally ignored until external validation supplies a defensible uncertainty model.
    public static func bandYears(factorsUsed _: Int) -> Double { bandYears }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Nocturnal RMSSD ~50th-percentile by age (ms), piecewise-linear between decade anchors (the WHOOP-
    /// window norms banked in the spec — never mixed with daytime clinical norms). The reference for the
    /// HRV factor: a person at the age norm contributes 0.
    public static func rmssdNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 47), (30, 40), (40, 33), (50, 29), (60, 25), (70, 22), (80, 20)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1]; let (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    /// Sleep regularity (0–1) from a window of nightly sleep durations (hours): 1 − coefficient of
    /// variation, clamped. A rough but honest on-device proxy for the Sleep Regularity Index when we only
    /// have durations, not full timing. Fewer than 3 nights → nil (not enough to judge).
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let cv = variance.squareRoot() / mean
        return clamp(1 - cv, 0, 1)
    }

    /// Compute the per-factor log-hazard contributions present in `inputs`. Each references a population
    /// value, so an average person nets ~0. Published per-unit hazard ratios (conservative, clamped):
    ///   • Resting HR: +~10.5% all-cause mortality per +10 bpm (UK Biobank / meta-analyses). ref 65.
    ///   • VO₂max: ~14% per MET (3.5 ml/kg/min) vs the age/sex-expected value (FRIEND). fitter = protective.
    ///   • Sleep duration: U-shaped, optimum ~7.5 h; only deviation beyond ±0.5 h adds hazard (~12%/h).
    ///   • Sleep-duration consistency: coefficient 0.450, ref 0.75 of the 0–1 range. INTERNAL, UNCITED —
    ///     do NOT re-attribute this to the UK Biobank Sleep Regularity Index. The published SRI hazard
    ///     ratios are derived from sleep–wake TIMING across 24-hour epochs; our input is
    ///     `sleepConsistency`, which is 1 − CV of nightly DURATION (see its doc comment). Duration
    ///     variability is a weaker, partial correlate of SRI, so borrowing the SRI hazard ratio wholesale
    ///     would overstate what this input can support. The term is retained because duration regularity
    ///     is plausibly associated with outcomes, but the magnitude is a product choice, not a citation.
    ///     OPEN: attenuate once we compute a true timing-based SRI (see ROUND-13 doc, validation backlog).
    ///   • HRV (RMSSD): ~16% per relative SD below the age norm (lower HRV = higher hazard).
    ///   • Steps: ~12% per 1,000 steps/day up to ~7k, diminishing to ~11k (pooled step-mortality meta).
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        var out: [Contribution] = []
        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate",
                                    lnHazard: ((rhr - 65) / 10) * 0.100))
        }
        if let vo2 = inputs.vo2max, let exp = inputs.expectedVO2max, exp > 0 {
            // (expected − vo2): if fitter than expected this is negative → protective.
            out.append(Contribution(key: "vo2max", label: "Cardio fitness",
                                    lnHazard: clamp((exp - vo2) / 3.5, -4, 4) * 0.130))
        }
        if let sh = inputs.sleepHours {
            let dev = max(0, abs(sh - 7.5) - 0.5)   // only deviation > ±0.5 h is a risk; optimum is neutral
            out.append(Contribution(key: "sleep", label: "Sleep duration",
                                    lnHazard: clamp(dev, 0, 3) * 0.110))
        }
        if let c = inputs.sleepConsistency {
            out.append(Contribution(key: "consistency", label: "Sleep-duration consistency",
                                    lnHazard: (0.75 - clamp(c, 0, 1)) * 0.450))
        }
        if let h = inputs.rmssd, let norm = inputs.rmssdNorm, norm > 0 {
            out.append(Contribution(key: "hrv", label: "Heart-rate variability",
                                    lnHazard: clamp((norm - h) / norm, -1, 1) * 0.160))
        }
        if let s = inputs.steps {
            // Below ~7k each −1,000 steps adds hazard; protection caps near 11k (diminishing returns).
            let deficit = (7000 - clamp(s, 0, 11000)) / 1000
            out.append(Contribution(key: "steps", label: "Daily steps",
                                    lnHazard: clamp(deficit, -4, 4) * 0.064))
        }
        return out
    }

    private static func domain(for key: String) -> String {
        switch key {
        case "rhr", "vo2max": return "cardiorespiratory"
        case "hrv": return "autonomic"
        case "sleep", "consistency": return "sleep"
        case "steps": return "activity"
        default: return key
        }
    }

    /// Full Vitality + compatibility age readout. Returns nil until there are enough factors across
    /// independent domains; callers also enforce long-window coverage before constructing inputs.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard (20...80).contains(inputs.chronoAge) else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }
        guard Set(contribs.map { domain(for: $0.key) }).count >= minDomains else { return nil }
        let sumLn = contribs.reduce(0) { $0 + $1.lnHazard } * overlapShrink
        let deltaAge = sumLn / lnHazardPerYear              // +ve = ages you
        let bodyAge = clamp(inputs.chronoAge + deltaAge, minBodyAge, maxBodyAge)
        let delta = inputs.chronoAge - bodyAge              // +ve = younger than your age
        let vitality = clamp(50 + delta * vitalityPerYear, 0, 100)
        return Result(vitality: vitality, bodyAge: bodyAge, chronoAge: inputs.chronoAge,
                      deltaYears: delta, bandYears: bandYears(factorsUsed: contribs.count),
                      contributions: contribs, factorsUsed: contribs.count)
    }
}
