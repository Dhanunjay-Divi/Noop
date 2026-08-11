import Foundation

/// A compact, explainable synthesis of the signal engines NOOP already computes.
///
/// This engine deliberately does not diagnose conditions and does not invent another set of biometric
/// thresholds. It composes the already-audited `ReadinessEngine` and `IllnessSignalEngine` results, then
/// deduplicates overlapping inputs into at most two useful observations. A single shifted metric is only
/// a prompt to recheck; stronger wording requires signals from more than one family.
public enum CrossMetricBriefEngine {

    public enum State: String, Sendable, Equatable {
        case building
        case steady
        case watch
    }

    public enum Confidence: String, Sendable, Equatable {
        case early
        case moderate
        case strong

        public var label: String {
            switch self {
            case .early: return "Recheck"
            case .moderate: return "Corroborated"
            case .strong: return "Strong shift"
            }
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case multiVital
        case loadRecovery
        case sleepRecovery
        case singleSignal
    }

    public struct Finding: Identifiable, Sendable, Equatable {
        public let kind: Kind
        public let title: String
        public let summary: String
        public let evidence: [String]
        public let possibleContributors: [String]
        public let safeActions: [String]
        public let confidence: Confidence

        public var id: String { kind.rawValue }

        public init(kind: Kind, title: String, summary: String, evidence: [String],
                    possibleContributors: [String], safeActions: [String],
                    confidence: Confidence) {
            self.kind = kind
            self.title = title
            self.summary = summary
            self.evidence = evidence
            self.possibleContributors = possibleContributors
            self.safeActions = safeActions
            self.confidence = confidence
        }
    }

    public struct Result: Sendable, Equatable {
        public let state: State
        public let headline: String
        public let summary: String
        public let findings: [Finding]
        public let checkedSignals: [String]

        public init(state: State, headline: String, summary: String,
                    findings: [Finding], checkedSignals: [String]) {
            self.state = state
            self.headline = headline
            self.summary = summary
            self.findings = findings
            self.checkedSignals = checkedSignals
        }
    }

    /// Standing boundary shown on every detailed pattern surface.
    public static let disclaimer =
        "Signal patterns show associations in your wearable data. They are not a diagnosis."

    /// Compose already-computed snapshots. This is O(number of readiness signals), performs no store reads,
    /// and is safe to call from a small SwiftUI leaf.
    public static func evaluate(readiness: ReadinessEngine.Readiness,
                                illness: IllnessSignalEngine.Result? = nil,
                                restScore: Double? = nil) -> Result {
        let recoveryKeys: Set<String> = ["hrv", "rhr", "respRate"]
        let loadKeys: Set<String> = ["acwr", "monotony"]
        let flagged = readiness.signals.filter { $0.flag == .watch || $0.flag == .bad }
        let recovery = flagged.filter { recoveryKeys.contains($0.key) }
        let load = flagged.filter { loadKeys.contains($0.key) }

        var checked = readiness.signals.map(\.label)
        if restScore != nil { checked.append("Sleep Score") }
        if let illness, illness.signalCount > 0 {
            checked.append(contentsOf: illness.firedSignals.map { signalFamilyName($0) })
        }
        checked = unique(checked)

        var findings: [Finding] = []

        // The illness engine is the existing corroboration + journal-confounder gate. We intentionally
        // discard its condition-oriented presentation copy and describe only the observed co-movement.
        if let illness, illness.level != .quiet {
            let evidence = illness.firedSignals.isEmpty
                ? recovery.compactMap(\.evidence)
                : illness.firedSignals
            let context = illness.suppressedBy.isEmpty
                ? ["Hard or unfamiliar training", "Short sleep", "Alcohol, heat or dehydration", "Travel or life stress"]
                : illness.suppressedBy.map { "Logged \($0)" }
            let summary: String
            switch illness.level {
            case .suppressed:
                summary = "Several vitals shifted together. Your recent log may be contributing, but the data cannot prove the cause."
            case .alreadyUnwell:
                summary = "Your recent check-in and several vitals moved together. Use this as context for a gentler day."
            case .mild, .raised:
                summary = "Several vitals moved away from your usual range together. Many short-term factors can cause this pattern."
            case .quiet:
                summary = ""
            }
            let confidence: Confidence
            if illness.level == .raised && illness.signalCount >= 3 {
                confidence = .strong
            } else {
                confidence = .moderate
            }
            findings.append(Finding(
                kind: .multiVital,
                title: "Several overnight signals shifted",
                summary: summary,
                evidence: Array(evidence.prefix(4)),
                possibleContributors: context,
                safeActions: [
                    "Check how you feel before choosing today's intensity",
                    "Keep today easier and prioritize sleep if you feel run down",
                    "Recheck after another night; seek medical advice for persistent changes or symptoms",
                ],
                confidence: confidence
            ))
        }

        // Load is allowed to form a finding only when an independent recovery family also shifted.
        if let loadSignal = load.first, let recoverySignal = recovery.first {
            findings.append(Finding(
                kind: .loadRecovery,
                title: "Load is outpacing recovery",
                summary: "Recent Effort is elevated while a recovery signal is lower. This describes load balance, not overtraining or injury risk.",
                evidence: evidence(from: [loadSignal, recoverySignal]),
                possibleContributors: ["Hard or unfamiliar training", "Short sleep", "Travel or life stress"],
                safeActions: [
                    "Reduce duration or intensity if you feel run down",
                    "Protect tonight's sleep opportunity",
                    "Reassess after one or two nights",
                ],
                confidence: loadSignal.flag == .bad && recoverySignal.flag == .bad ? .strong : .moderate
            ))
        }

        // Sleep Score is a separate sleep family, but a single day's score stays explicitly provisional.
        if findings.count < 2, let restScore, restScore < 70, let recoverySignal = recovery.first {
            var sleepEvidence = ["Sleep Score \(Int(restScore.rounded())) of 100"]
            if let e = recoverySignal.evidence { sleepEvidence.append("\(recoverySignal.label): \(e)") }
            findings.append(Finding(
                kind: .sleepRecovery,
                title: "Sleep and recovery moved together",
                summary: "Sleep Score is lower while a recovery signal is shifted. This is an association, not proof that sleep caused the change.",
                evidence: sleepEvidence,
                possibleContributors: ["Less sleep opportunity", "Interrupted sleep", "Late training, alcohol or stress"],
                safeActions: [
                    "Add a little more sleep opportunity for the next few nights",
                    "Keep your wake time consistent",
                    "Open Sleep to inspect the timeline before drawing a conclusion",
                ],
                confidence: .early
            ))
        }

        // One metric can never become an inferred condition. It is still useful to make the change
        // discoverable, framed as a measurement to repeat rather than a conclusion.
        if findings.isEmpty, let signal = flagged.first {
            findings.append(Finding(
                kind: .singleSignal,
                title: "\(signal.label) is worth rechecking",
                summary: "One signal moved from your usual range. One reading is context, not a conclusion.",
                evidence: evidence(from: [signal]),
                possibleContributors: contributors(for: signal.key),
                safeActions: [
                    "Check measurement quality and how you feel",
                    "Keep normal context in your Journal",
                    "Look for persistence over another night",
                ],
                confidence: .early
            ))
        }

        let capped = Array(findings.prefix(2))
        if !capped.isEmpty {
            return Result(
                state: .watch,
                headline: capped[0].title,
                summary: capped[0].summary,
                findings: capped,
                checkedSignals: checked
            )
        }

        if readiness.level == .insufficient {
            return Result(
                state: .building,
                headline: "Building your baseline",
                summary: "A few more consistent nights will make cross-metric patterns trustworthy.",
                findings: [],
                checkedSignals: checked
            )
        }

        return Result(
            state: .steady,
            headline: "No clear pattern",
            summary: "The fresh signals checked today do not form a corroborated shift.",
            findings: [],
            checkedSignals: checked
        )
    }

    private static func evidence(from signals: [ReadinessEngine.Signal]) -> [String] {
        signals.map { signal in
            if let evidence = signal.evidence { return "\(signal.label): \(evidence)" }
            return "\(signal.label): \(signal.detail)"
        }
    }

    private static func contributors(for key: String) -> [String] {
        switch key {
        case "hrv", "rhr":
            return ["Training load", "Sleep", "Stress", "Alcohol, heat or dehydration", "Travel"]
        case "respRate":
            return ["Sleep environment", "Altitude or travel", "Hard training", "Sensor fit"]
        case "acwr", "monotony":
            return ["A recent training block", "Similar effort on consecutive days", "Less recovery time"]
        default:
            return ["Training", "Sleep", "Stress", "Travel", "Measurement context"]
        }
    }

    private static func signalFamilyName(_ rendered: String) -> String {
        let lower = rendered.lowercased()
        if lower.contains("hrv") { return "HRV" }
        if lower.contains("rhr") { return "Resting HR" }
        if lower.contains("temp") { return "Skin temperature" }
        if lower.contains("resp") { return "Respiratory rate" }
        return rendered
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
