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
        // German
        "fitnessstudio", "schwimmen", "radfahren", "joggen", "wandern", "rudern",
        "boxen", "klettern", "krafttraining",
        // Spanish
        "gimnasio", "ejercicio", "natacion", "ciclismo", "correr", "senderismo",
        "remo", "boxeo", "escalada",
        // French
        "musculation", "natation", "cyclisme", "velo", "randonnee", "aviron",
        "boxe", "escalade",
        // Italian
        "palestra", "esercizio", "nuoto", "corsa", "escursione", "canottaggio",
        "pugilato",
        // Portuguese
        "ginasio", "exercicio", "natacao", "corrida", "caminhada",
        // Russian
        "спортзал", "тренировка", "фитнес", "плавание", "бег", "велоспорт",
        "йога", "пилатес", "бокс", "гребля", "скалолазание",
        // Simplified and Traditional Chinese
        "健身", "锻炼", "鍛鍊", "运动", "運動", "游泳", "跑步", "骑行", "騎行",
        "瑜伽", "普拉提", "皮拉提斯", "拳击", "拳擊", "力量训练", "重量訓練",
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
        "besprechung", "vorstellungsgespräch", "konferenz",
        "reunion", "entrevista", "conferencia", "taller",
        "entretien", "atelier",
        "riunione", "colloquio", "conferenza",
        "reuniao",
        "встреча", "собеседование", "конференция",
        "会议", "會議", "面试", "面試", "研讨会", "研討會",
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
        let normalizedTitle = title
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let tokens = normalizedTitle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }

        let normalized = tokens.joined(separator: " ")
        guard !excludedPhrases.contains(where: normalized.contains) else { return false }

        let tokenSet = Set(tokens)
        guard tokenSet.isDisjoint(with: workContextTokens),
              tokenSet.isDisjoint(with: nonParticipationContextTokens),
              !containsUnsegmentedHanTerm(in: tokens, candidates: workContextTokens),
              !containsUnsegmentedHanTerm(in: tokens, candidates: nonParticipationContextTokens)
        else { return false }
        if !tokenSet.isDisjoint(with: directActivityTokens)
            || containsUnsegmentedHanTerm(in: tokens, candidates: directActivityTokens)
        {
            return true
        }
        if !tokenSet.isDisjoint(with: ambiguousActivityTokens) {
            return tokens.count == 1 || !tokenSet.isDisjoint(with: fitnessContextTokens)
        }
        return tokenSet.contains("training")
            && !tokenSet.isDisjoint(with: fitnessContextTokens)
    }

    private static func containsUnsegmentedHanTerm(
        in tokens: [String],
        candidates: Set<String>
    ) -> Bool {
        candidates.contains { candidate in
            candidate.unicodeScalars.contains(where: isHanScalar)
                && tokens.contains(where: { $0.contains(candidate) })
        }
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
