import Foundation

/// One phone-owned routine that the Watch may ask the phone to start.
public struct WatchStrengthRoutine: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let exerciseNames: [String]
    public let targetSetCount: Int

    public init(id: String, name: String, exerciseNames: [String], targetSetCount: Int) {
        self.id = id
        self.name = name
        self.exerciseNames = Array(exerciseNames.prefix(6))
        self.targetSetCount = max(0, targetSetCount)
    }
}

/// Latest-state strength handoff. The phone owns routines and the editable log; the Watch displays
/// this compact snapshot and may request that the phone start one routine.
public struct WatchStrengthPlan: Codable, Equatable, Sendable {
    public let routines: [WatchStrengthRoutine]
    public let activeSessionName: String?
    public let activeCompletedSets: Int
    public let activeTargetSets: Int
    public let updatedAt: Date

    public init(
        routines: [WatchStrengthRoutine],
        activeSessionName: String?,
        activeCompletedSets: Int,
        activeTargetSets: Int,
        updatedAt: Date
    ) {
        self.routines = Array(routines.prefix(8))
        self.activeSessionName = activeSessionName
        self.activeCompletedSets = max(0, activeCompletedSets)
        self.activeTargetSets = max(0, activeTargetSets)
        self.updatedAt = updatedAt
    }

    public static let storageKey = "latestWatchStrengthPlan"
    public static let contextKey = "strengthPlan"
    public static let startRoutineMessageKey = "startStrengthRoutine"

    /// Legacy-compatible scrub sent while the iPhone launch gate is locked. An older Watch build has no
    /// launch-state field on this payload, so absence of the key would leave its previously persisted
    /// routines and active-session name visible. Sending an explicit empty plan overwrites that cache.
    public static var launchLocked: WatchStrengthPlan {
        WatchStrengthPlan(
            routines: [],
            activeSessionName: nil,
            activeCompletedSets: 0,
            activeTargetSets: 0,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public static func load() -> WatchStrengthPlan? {
        guard let defaults = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WatchStrengthPlan.self, from: data)
    }
}
