import Foundation

/// Conservative, local-only classification for calendar titles.
///
/// Callers must discard the title immediately after this boolean decision. Ambiguous work-oriented
/// titles fail closed so a meeting called "training" cannot become a health-planning signal.
public enum PlannedWorkoutTitleClassifier {
    private static let directActivityTokens: Set<String> = [
        "workout", "gym", "exercise", "hiit", "crossfit", "pilates", "yoga", "barre",
        "cardio", "lifting", "weights", "jog", "jogging", "ride",
        "cycling", "bike", "swim", "swimming", "hike", "hiking", "rowing", "boxing",
        "tennis", "soccer", "football", "basketball", "volleyball", "climbing",
        "bootcamp",
    ]

    private static let ambiguousActivityTokens: Set<String> = [
        "run", "running", "spin",
    ]

    private static let fitnessContextTokens: Set<String> = [
        "strength", "fitness", "marathon", "triathlon", "race", "5k", "10k",
        "morning", "afternoon", "evening", "night", "lunch", "trail", "track",
        "treadmill", "tempo", "interval", "intervals", "easy", "long", "recovery",
        "outdoor", "indoor", "club", "class", "practice",
    ]

    private static let workContextTokens: Set<String> = [
        "meeting", "interview", "webinar", "workshop", "conference", "standup",
        "onboarding", "presentation", "planning", "demo", "review", "sync", "project",
        "payroll", "backup", "backups", "staging", "deploy", "deployment", "server",
        "database", "script", "pipeline", "batch", "runbook",
    ]

    private static let nonParticipationContextTokens: Set<String> = [
        "repair", "service", "shop", "shopping", "watch", "party", "ticket", "tickets",
        "viewing",
    ]

    private static let excludedPhrases = [
        "run errands", "school run", "coffee run", "dry run", "test run",
    ]

    public static func isWorkoutTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let tokens = title
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }

        let normalized = tokens.joined(separator: " ")
        guard !excludedPhrases.contains(where: normalized.contains) else { return false }

        let tokenSet = Set(tokens)
        guard tokenSet.isDisjoint(with: workContextTokens),
              tokenSet.isDisjoint(with: nonParticipationContextTokens)
        else { return false }
        if !tokenSet.isDisjoint(with: directActivityTokens) { return true }
        if !tokenSet.isDisjoint(with: ambiguousActivityTokens) {
            return tokens.count == 1 || !tokenSet.isDisjoint(with: fitnessContextTokens)
        }
        return tokenSet.contains("training")
            && !tokenSet.isDisjoint(with: fitnessContextTokens)
    }
}
