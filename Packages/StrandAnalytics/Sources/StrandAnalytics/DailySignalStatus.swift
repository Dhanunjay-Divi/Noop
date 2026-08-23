import Foundation

/// One conservative state for the Daily Signal header.
///
/// This is presentation policy, not another health formula. It combines the existing readiness and
/// multi-signal results without upgrading missing or thin data into a reassuring green state.
public enum DailySignalStatus: String, Equatable, Sendable, Codable {
    case building
    case steady
    case watch
    case alert

    public static func resolve(
        readiness: ReadinessEngine.Readiness?,
        illness: IllnessSignalEngine.Result?
    ) -> DailySignalStatus {
        if let illness {
            switch illness.displayState {
            case .alert:
                return .alert
            case .watch:
                return .watch
            case .building:
                return .building
            case .steady:
                break
            }
        }

        guard let readiness, readiness.confidence == .solid else { return .building }
        switch readiness.level {
        case .primed, .balanced:
            return .steady
        case .strained, .rundown:
            return .watch
        case .insufficient:
            return .building
        }
    }
}
