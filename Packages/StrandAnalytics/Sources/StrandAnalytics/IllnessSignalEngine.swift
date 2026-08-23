import Foundation

// IllnessSignalEngine.swift - multi-signal "Heads-Up" early-warning. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of the published multi-parameter pre-symptomatic signature documented
// across the wearable literature (e.g. the Stanford/Snyder resting-HR-elevation work and successor
// studies): resting HR ↑, skin temperature ↑, HRV (RMSSD) ↓ and respiration ↑ tend to move TOGETHER,
// days before symptoms. NOOP re-derives the PATTERN, transparently, against the user's OWN rolling
// baseline — never a population cutoff.
//
// This replaces the blunt 2-of-4 threshold rule in AppModel.evaluateIllness with:
//   • a calibrated 0–100 composite anomaly score (so the surface can read "mild" vs "strong"),
//   • a minimum-corroboration gate (≥ 2 signals) so a single noisy night never fires,
//   • explanatory context cross-checked against same-day journal tags (alcohol / stress / sauna /
//     late-or-intense workout / travel). Context is shown but NEVER suppresses or downgrades a
//     corroborated shift: those factors can coexist with illness or another health concern,
//   • a visible "why" (which signals fired) AND nearby context,
//   • honest gating: a trusted baseline is required; below that the engine is silent.
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. The engine never names a condition, illness, infection
// or fever; the copy is always "a heads-up to rest" / "consider taking it easy" (see the shipped
// IllnessNotifier copy: "On-device estimate (approximate) - not a diagnosis").
public enum IllnessSignalEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Composite score (0–100) at/above which the heads-up is RAISED. Below this it is "mild" - surfaced
    /// only in a detail view, never a notification (keeps the banner from re-introducing noise).
    public static let raiseThreshold: Double = 50.0
    /// Score floor below which there is nothing worth saying at all (engine returns `.quiet`).
    public static let mildThreshold: Double = 25.0
    /// Minimum number of signals pointing the illness way before anything can raise — guards against a
    /// single noisy night driving the score on its own.
    public static let minCorroboratingSignals: Int = 2

    /// A signal's |z| must reach this to count as "firing" toward the score. Roughly the user's own ~95th
    /// percentile night (matches VitalBands.sigmaK), so normal night-to-night wobble doesn't register.
    public static let signalZThreshold: Double = 2.0
    /// Per-signal sub-score is `min(perSignalCap, kZToScore · max(0, zIllnessward − signalZThreshold))`,
    /// then the composite is their sum clamped to 100. Each strong signal caps so no single one saturates.
    public static let kZToScore: Double = 22.0
    public static let perSignalCap: Double = 40.0

    /// Retained for source compatibility with older clients. Context no longer changes the score.
    @available(*, deprecated, message: "Journal context is explanatory and no longer dampens health signals.")
    public static let confounderDampen: Double = 0.45

    // MARK: - Inputs

    /// One signal's recent-vs-baseline reading, already z-scored against the personal baseline by the
    /// caller (reusing `Baselines.deviation`). `zIllnessward` is the deviation ORIENTED so that a
    /// positive value always means "more illness-like": RHR ↑, skin-temp ↑, respiration ↑ pass their raw
    /// z; HRV ↓ passes the NEGATED z (a drop is illness-ward). `present == false` means the signal had no
    /// usable data this window and is skipped (not counted as corroboration).
    public struct SignalReading: Equatable, Sendable {
        public let zIllnessward: Double
        public let present: Bool
        public init(zIllnessward: Double, present: Bool = true) {
            self.zIllnessward = zIllnessward
            self.present = present
        }
    }

    /// All four signal readings for the recent window. Any may be absent (sparse 5/MG nights).
    public struct Inputs: Equatable, Sendable {
        public var restingHR: SignalReading?   // z of recent RHR vs baseline (↑ illness-ward)
        public var skinTemp: SignalReading?    // z of recent skin-temp deviation vs baseline (↑ illness-ward)
        public var hrv: SignalReading?         // NEGATED z of recent HRV vs baseline (drop = illness-ward)
        public var respiration: SignalReading? // z of recent respiration vs baseline (↑ illness-ward)
        public init(restingHR: SignalReading? = nil, skinTemp: SignalReading? = nil,
                    hrv: SignalReading? = nil, respiration: SignalReading? = nil) {
            self.restingHR = restingHR; self.skinTemp = skinTemp
            self.hrv = hrv; self.respiration = respiration
        }
    }

    /// Same-day behaviour context that may contribute to a shift. It is explanatory only and can never
    /// hide or downgrade the signal result. All values default false so a caller with no journal still
    /// gets the raw signal read. `travelPhaseJump` is the cross-feature hook from CircadianEngine.
    public struct Context: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var hardOrLateWorkout: Bool
        public var travelPhaseJump: Bool
        public var alreadyUnwell: Bool
        /// A user-entered recent medication start or dose change. Explanatory only: medication names,
        /// doses, and schedules never enter this engine, and this flag cannot change score or level.
        public var recentMedicationChange: Bool
        /// True iff the caller's baseline for the anomaly is `trusted` (≥ 14 valid nights, not stale).
        /// Below this the engine stays silent — we don't warn off a cold-start baseline.
        public var baselineTrusted: Bool
        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    hardOrLateWorkout: Bool = false, travelPhaseJump: Bool = false,
                    alreadyUnwell: Bool = false, recentMedicationChange: Bool = false,
                    baselineTrusted: Bool = true) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna
            self.hardOrLateWorkout = hardOrLateWorkout; self.travelPhaseJump = travelPhaseJump
            self.alreadyUnwell = alreadyUnwell
            self.recentMedicationChange = recentMedicationChange
            self.baselineTrusted = baselineTrusted
        }
    }

    // MARK: - Output

    /// How loud the heads-up is. `.quiet` shows nothing; `.alreadyUnwell` is the symptom-first path when
    /// the user has already logged feeling unwell. `.suppressed` is retained only for decoding old data;
    /// current evaluation never emits it because journal context cannot rule out a health concern.
    public enum Level: String, Equatable, Sendable, Codable {
        case quiet           // nothing worth saying (below mild, or not enough corroboration, or untrusted baseline)
        case mild            // some signals up — detail view only, no notification
        case raised          // clear multi-signal anomaly, no confounder — surface + notify
        case suppressed      // legacy only; current evaluation never emits this level
        case alreadyUnwell   // user logged feeling unwell - "rest up", not a scare
    }

    /// Presentation-safe interpretation of an illness result. In particular, `.quiet` is only `.steady`
    /// when the result was backed by enough fresh trusted signals; missing data remains `.building`.
    public enum DisplayState: String, Equatable, Sendable, Codable {
        case building
        case steady
        case watch
        case alert
    }

    public struct Result: Equatable, Sendable {
        /// 0–100 composite anomaly score.
        public let score: Double
        public let level: Level
        /// Human-readable reasons a signal fired, e.g. "RHR +6", "HRV −22%", "skin temp +0.7 °C". The
        /// caller supplies the rendered phrases; the engine decides which to include (only firing ones).
        public let firedSignals: [String]
        /// Historical field name retained for compatibility. These are nearby contextual factors, not
        /// explanations and not reasons to suppress the result.
        public let suppressedBy: [String]
        /// Count of signals over the firing threshold (corroboration), regardless of level.
        public let signalCount: Int
        /// One-line non-clinical copy, terminating in the shipped not-a-diagnosis framing where it raises.
        public let copy: String
        /// Fresh, finite signals backed by their own trusted personal baseline. This is deliberately
        /// separate from `signalCount`, which counts only anomalous signals.
        public let trustedSignalCount: Int

        public var displayState: DisplayState {
            switch level {
            case .raised, .alreadyUnwell:
                return .alert
            case .mild, .suppressed:
                return .watch
            case .quiet:
                return trustedSignalCount >= minCorroboratingSignals ? .steady : .building
            }
        }

        public init(score: Double, level: Level, firedSignals: [String], suppressedBy: [String],
                    signalCount: Int, copy: String, trustedSignalCount: Int = 0) {
            self.score = score; self.level = level; self.firedSignals = firedSignals
            self.suppressedBy = suppressedBy; self.signalCount = signalCount; self.copy = copy
            self.trustedSignalCount = trustedSignalCount
        }
    }

    /// Standing not-a-diagnosis tail reused verbatim from the shipped IllnessNotifier copy.
    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    // MARK: - Evaluate

    /// Score the recent window and decide the heads-up level + copy.
    ///
    /// `firedLabels` maps a signal key to the caller-rendered phrase to show when that signal fires
    /// (e.g. ["restingHR": "RHR +6", "hrv": "HRV −22%"]). Only keys for signals that clear
    /// `signalZThreshold` are surfaced. Keeping the rendering in the caller keeps the engine free of
    /// number-formatting locale concerns and identical across platforms.
    public static func evaluate(_ inputs: Inputs, context: Context,
                                firedLabels: [String: String] = [:]) -> Result {
        // Order is fixed so firedSignals is deterministic across platforms.
        let ordered: [(key: String, reading: SignalReading?)] = [
            ("restingHR", inputs.restingHR),
            ("skinTemp", inputs.skinTemp),
            ("hrv", inputs.hrv),
            ("respiration", inputs.respiration),
        ]

        var rawScore = 0.0
        var firedKeys: [String] = []
        for (key, reading) in ordered {
            guard let r = reading, r.present, r.zIllnessward.isFinite else { continue }
            let over = r.zIllnessward - signalZThreshold
            guard over > 0 else { continue }
            firedKeys.append(key)
            rawScore += min(perSignalCap, kZToScore * over)
        }
        let score = min(100.0, rawScore)
        let signalCount = firedKeys.count
        let firedSignals = firedKeys.compactMap { firedLabels[$0] }
        let trustedSignalCount = context.baselineTrusted
            ? ordered.filter { $0.reading?.present == true && $0.reading?.zIllnessward.isFinite == true }.count
            : 0

        // A symptom report outranks every wearable-data gate. Wearables cannot assess symptom severity,
        // so this path remains visible even with no baseline or no sensor data.
        if context.alreadyUnwell {
            let agreeing = score >= mildThreshold && signalCount >= 1
            let copy = agreeing
                ? "You logged feeling unwell, and some wearable signals also shifted. Wearable data cannot assess severity. If symptoms are severe or worsening, seek urgent help. \(disclaimerTail)"
                : "You logged feeling unwell. Missing or unchanged wearable data cannot rule out a problem or assess severity. If symptoms are severe or worsening, seek urgent help. \(disclaimerTail)"
            return Result(score: score, level: .alreadyUnwell, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy,
                          trustedSignalCount: trustedSignalCount)
        }

        // Untrusted or insufficient per-signal baselines are not a normal result. The adapter marks only
        // fresh, baseline-backed readings present; this gate prevents cold-start or sparse data alerts.
        if !context.baselineTrusted {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Not enough fresh, baseline-backed signals to assess a pattern. Missing data is not a healthy result.",
                          trustedSignalCount: trustedSignalCount)
        }

        // Corroboration + magnitude gate: need ≥ 2 firing signals and a mild-or-better composite, else quiet.
        guard signalCount >= minCorroboratingSignals, score >= mildThreshold else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "No corroborated shift in the fresh signals checked. This does not assess overall health or symptoms.",
                          trustedSignalCount: trustedSignalCount)
        }

        // Collect nearby context for explainability only. It never changes score or level because a
        // plausible contributor can coexist with illness or another health concern.
        var contextualFactors: [String] = []
        if context.alcohol { contextualFactors.append("alcohol") }
        if context.stress { contextualFactors.append("stress") }
        if context.sauna { contextualFactors.append("sauna") }
        if context.hardOrLateWorkout { contextualFactors.append("a hard or late workout") }
        if context.travelPhaseJump { contextualFactors.append("travel") }
        if context.recentMedicationChange { contextualFactors.append("a recent medication change") }

        let signalsPhrase = firedSignals.isEmpty ? "Some signals are up" : firedSignals.joined(separator: ", ")
        let contextSuffix = contextualFactors.isEmpty
            ? ""
            : " You also logged \(joinReasons(contextualFactors)); that may contribute but does not rule out the shift."

        // Mild stays in the detail view; a strong composite raises.
        if score < raiseThreshold {
            let copy = "A few signals are mildly up (\(signalsPhrase)). The shift is small; keep monitoring "
                + "how you feel.\(contextSuffix) \(disclaimerTail)"
            return Result(score: score, level: .mild, firedSignals: firedSignals,
                          suppressedBy: contextualFactors, signalCount: signalCount, copy: copy,
                          trustedSignalCount: trustedSignalCount)
        }

        let copy = "Several signals shifted together (\(signalsPhrase)). Many things can cause this "
            + "pattern; review how you feel.\(contextSuffix) Symptoms matter more than this estimate. \(disclaimerTail)"
        return Result(score: score, level: .raised, firedSignals: firedSignals,
                      suppressedBy: contextualFactors, signalCount: signalCount, copy: copy,
                      trustedSignalCount: trustedSignalCount)
    }

    // MARK: - Helpers

    /// Join named confounders into a natural list ("alcohol", "alcohol and stress", "a, b and c").
    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default:
            let head = reasons.dropLast().joined(separator: ", ")
            return "\(head) and \(reasons.last!)"
        }
    }
}
