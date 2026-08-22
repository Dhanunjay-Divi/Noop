import Foundation

public enum SleepGoalMode: String, CaseIterable, Codable, Sendable {
    /// Keep the user-entered target fixed; recent balance is shown but does not change tonight.
    case target
    /// Add only the bounded amount supported by the recent arithmetic sleep-balance ledger.
    case balance
    /// Reserve at least 30 extra minutes of opportunity, still capped at one hour total.
    case extraOpportunity
}

// SleepPlanner.swift — one deterministic contract for tonight's sleep opportunity.
//
// This planner deliberately does less than a clinical sleep prescription. It combines:
//   • the wake time the user chose,
//   • the user's explicit sleep target,
//   • a short wind-down buffer, and
//   • a bounded contribution from the recent arithmetic sleep-balance ledger.
//
// It never reduces the user's target because of a recent surplus, never tries to repay
// an entire multi-night deficit in one night, and never invents a personalized plan when
// fewer than three usable nights exist. The Kotlin mirror must stay value-for-value.

public struct SleepPlan: Equatable, Sendable {
    /// User-selected wake minute in [0, 1439].
    public let wakeMinute: Int
    /// Suggested lights-out minute in [0, 1439].
    public let bedtimeMinute: Int
    /// Suggested start-winding-down minute in [0, 1439].
    public let windDownMinute: Int
    /// User-controlled baseline target, clamped to 5–11 hours.
    public let baseSleepMinutes: Int
    /// User-selected planning behavior.
    public let goalMode: SleepGoalMode
    /// Extra opportunity selected by the goal mode, always 0–60 minutes.
    public let recoveryMinutes: Int
    /// Total planned sleep opportunity: base + recovery.
    public let sleepOpportunityMinutes: Int
    /// Recent arithmetic balance passed by the caller. Negative means debt.
    public let debtBalanceMinutes: Double?
    /// Number of usable nights behind that balance.
    public let historyNights: Int
    /// Certainty of the planning basis, not certainty that sleep will occur as planned.
    public let confidence: ScoreConfidence

    public init(
        wakeMinute: Int,
        bedtimeMinute: Int,
        windDownMinute: Int,
        baseSleepMinutes: Int,
        goalMode: SleepGoalMode,
        recoveryMinutes: Int,
        sleepOpportunityMinutes: Int,
        debtBalanceMinutes: Double?,
        historyNights: Int,
        confidence: ScoreConfidence
    ) {
        self.wakeMinute = wakeMinute
        self.bedtimeMinute = bedtimeMinute
        self.windDownMinute = windDownMinute
        self.baseSleepMinutes = baseSleepMinutes
        self.goalMode = goalMode
        self.recoveryMinutes = recoveryMinutes
        self.sleepOpportunityMinutes = sleepOpportunityMinutes
        self.debtBalanceMinutes = debtBalanceMinutes
        self.historyNights = historyNights
        self.confidence = confidence
    }
}

public enum SleepPlanner {
    public static let minimumSleepMinutes = 5 * 60
    public static let maximumSleepMinutes = 11 * 60
    public static let maximumRecoveryMinutes = 60
    public static let recoveryStepMinutes = 15
    public static let minimumDebtNights = 3
    public static let solidHistoryNights = 7

    /// Build tonight's plan. `debtBalanceMinutes` should come from `SleepDebt.ledger`
    /// using the same explicit sleep target. Negative balance may add a small recovery
    /// buffer; a positive balance never subtracts from the target.
    public static func plan(
        wakeMinute: Int,
        sleepTargetMinutes: Int,
        windDownLeadMinutes: Int,
        debtBalanceMinutes: Double?,
        historyNights: Int,
        goalMode: SleepGoalMode = .balance
    ) -> SleepPlan {
        let wake = wrappedMinute(wakeMinute)
        let base = min(max(sleepTargetMinutes, minimumSleepMinutes), maximumSleepMinutes)
        let lead = min(max(windDownLeadMinutes, 0), 120)
        let nights = max(historyNights, 0)
        let balanceRecovery = recoveryMinutes(
            debtBalanceMinutes: debtBalanceMinutes,
            historyNights: nights
        )
        let recovery: Int = {
            switch goalMode {
            case .target:
                return 0
            case .balance:
                return balanceRecovery
            case .extraOpportunity:
                return min(max(balanceRecovery, 30), maximumRecoveryMinutes)
            }
        }()
        let opportunity = base + recovery
        let bedtime = wrappedMinute(wake - opportunity)
        let windDown = wrappedMinute(bedtime - lead)
        let confidence: ScoreConfidence = {
            if nights < minimumDebtNights { return .calibrating }
            if nights < solidHistoryNights { return .building }
            return .solid
        }()

        return SleepPlan(
            wakeMinute: wake,
            bedtimeMinute: bedtime,
            windDownMinute: windDown,
            baseSleepMinutes: base,
            goalMode: goalMode,
            recoveryMinutes: recovery,
            sleepOpportunityMinutes: opportunity,
            debtBalanceMinutes: debtBalanceMinutes,
            historyNights: nights,
            confidence: confidence
        )
    }

    /// Spread recent debt over the nights that produced it, round upward to an
    /// actionable 15-minute increment, and cap tonight's addition at one hour.
    ///
    /// A balance inside SleepDebt's ±30-minute deadband, a surplus, or fewer than
    /// three usable nights yields no adjustment.
    public static func recoveryMinutes(
        debtBalanceMinutes: Double?,
        historyNights: Int
    ) -> Int {
        guard historyNights >= minimumDebtNights,
              let balance = debtBalanceMinutes,
              balance < -SleepDebt.onTargetBandMin else { return 0 }

        let averageDeficit = abs(balance) / Double(historyNights)
        let stepped = Int(ceil(averageDeficit / Double(recoveryStepMinutes))) * recoveryStepMinutes
        return min(max(stepped, recoveryStepMinutes), maximumRecoveryMinutes)
    }

    public static func wrappedMinute(_ minute: Int) -> Int {
        let day = 24 * 60
        return ((minute % day) + day) % day
    }

    /// Difference between tonight's planned midpoint and the midpoint observed in prior main sleeps.
    /// Positive values mean later; negative values mean earlier. This is behavioral timing context,
    /// not a biological chronotype or medical inference.
    public static func observedTimingShiftMinutes(
        plan: SleepPlan,
        habitualMidsleepSeconds: Int?
    ) -> Int? {
        guard let seconds = habitualMidsleepSeconds else { return nil }
        let observed = wrappedMinute(seconds / 60)
        let planned = wrappedMinute(plan.bedtimeMinute + plan.sleepOpportunityMinutes / 2)
        var delta = planned - observed
        if delta > 12 * 60 { delta -= 24 * 60 }
        if delta < -(12 * 60) { delta += 24 * 60 }
        return delta
    }
}
