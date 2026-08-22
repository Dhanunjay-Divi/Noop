import Foundation

// SafetyCheckInPolicy.swift - pure policy and message construction for NOOP's manual Safety Center.
//
// This is deliberately NOT a fall detector, medical-event detector, dispatcher, or background delivery
// service. It only (a) describes the state of a user-armed local reminder and (b) prepares text the user
// may choose to share through the operating system. The platform layer owns permissions, notifications,
// location capture, calling, and the final user-confirmed send action.
//
// Keep this byte-for-byte behavior aligned with Android SafetyCheckInPolicy.kt.

public enum SafetyShareIntent: String, CaseIterable, Equatable, Sendable {
    case needHelpNow
    case feelUnsafe
    case missedCheckIn
}

/// Platform-supplied copy for the user-confirmed safety draft.
///
/// The pure policy keeps an English default for deterministic tests and headless callers. App targets
/// pass localized values at the final presentation boundary so a translated Safety Center does not
/// unexpectedly open an English-only message.
public struct SafetyShareCopy: Equatable, Sendable {
    public let needHelpNowOpening: String
    public let feelUnsafeOpening: String
    public let missedCheckInOpening: String
    public let immediateDangerInstruction: String
    public let locationLabel: String
    public let locationCapturedFormat: String
    public let locationCapturedAccuracyFormat: String
    public let noteLabel: String
    public let preparedAtFormat: String
    public let deliveryBoundary: String

    public init(needHelpNowOpening: String,
                feelUnsafeOpening: String,
                missedCheckInOpening: String,
                immediateDangerInstruction: String,
                locationLabel: String,
                locationCapturedFormat: String,
                locationCapturedAccuracyFormat: String,
                noteLabel: String,
                preparedAtFormat: String,
                deliveryBoundary: String) {
        self.needHelpNowOpening = needHelpNowOpening
        self.feelUnsafeOpening = feelUnsafeOpening
        self.missedCheckInOpening = missedCheckInOpening
        self.immediateDangerInstruction = immediateDangerInstruction
        self.locationLabel = locationLabel
        self.locationCapturedFormat = locationCapturedFormat
        self.locationCapturedAccuracyFormat = locationCapturedAccuracyFormat
        self.noteLabel = noteLabel
        self.preparedAtFormat = preparedAtFormat
        self.deliveryBoundary = deliveryBoundary
    }

    public static let english = SafetyShareCopy(
        needHelpNowOpening: "I need help now. Please call me.",
        feelUnsafeOpening: "I feel unsafe. Please call me and stay on the line if you can.",
        missedCheckInOpening: "I missed a planned check-in. Please contact me.",
        immediateDangerInstruction:
            "If you think I am in immediate danger, contact local emergency services.",
        locationLabel: "Location",
        locationCapturedFormat: "Location captured at %1$@.",
        locationCapturedAccuracyFormat:
            "Location captured at %1$@, accuracy about %2$lld m.",
        noteLabel: "Note",
        preparedAtFormat: "Prepared at %1$@.",
        deliveryBoundary:
            "NOOP did not send this automatically and does not monitor or contact emergency services."
    )

    fileprivate func opening(for intent: SafetyShareIntent) -> String {
        switch intent {
        case .needHelpNow: return needHelpNowOpening
        case .feelUnsafe: return feelUnsafeOpening
        case .missedCheckIn: return missedCheckInOpening
        }
    }
}

public struct SafetyLocation: Equatable, Sendable {
    /// A user-requested one-shot fix must stay recent enough to describe where they are now. Both
    /// platforms can return cached locations, so structural coordinate validation is not sufficient.
    public static let maximumAgeSeconds = 5 * 60
    public static let maximumFutureClockSkewSeconds = 60

    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double?
    public let capturedAtUnix: Int

    public init(latitude: Double,
                longitude: Double,
                horizontalAccuracyMeters: Double? = nil,
                capturedAtUnix: Int) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capturedAtUnix = capturedAtUnix
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude)
            && (-180.0...180.0).contains(longitude)
            && capturedAtUnix > 0
    }

    public func isUsable(atUnix nowUnix: Int) -> Bool {
        guard isValid, nowUnix > 0 else { return false }
        let (age, overflow) = nowUnix.subtractingReportingOverflow(capturedAtUnix)
        guard !overflow else { return false }
        return age >= -Self.maximumFutureClockSkewSeconds
            && age <= Self.maximumAgeSeconds
    }
}

public enum SafetyShareMessage {
    public static let maxNameCharacters = 80
    public static let maxNoteCharacters = 240

    /// Build a compact, user-shareable message. Invalid coordinates are omitted rather than guessed.
    /// The final sentence is load-bearing safety copy: NOOP prepared the draft but did not dispatch it.
    public static func build(intent: SafetyShareIntent,
                             displayName: String? = nil,
                             note: String? = nil,
                             location: SafetyLocation? = nil,
                             preparedAtUnix: Int,
                             copy: SafetyShareCopy = .english) -> String {
        let cleanName = clean(displayName, maxCharacters: maxNameCharacters)
        let cleanNote = clean(note, maxCharacters: maxNoteCharacters)
        var parts: [String] = []
        let opening = copy.opening(for: intent)

        if let cleanName {
            parts.append("\(cleanName): \(opening)")
        } else {
            parts.append(opening)
        }

        parts.append(copy.immediateDangerInstruction)

        if let location, location.isUsable(atUnix: preparedAtUnix) {
            parts.append("\(copy.locationLabel): \(mapURL(location))")
            let accuracy = location.horizontalAccuracyMeters
                .flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
            if let accuracy {
                parts.append(String(
                    format: copy.locationCapturedAccuracyFormat,
                    locale: Locale.current,
                    arguments: [utcTimestamp(location.capturedAtUnix), Int64(accuracy)]
                ))
            } else {
                parts.append(String(
                    format: copy.locationCapturedFormat,
                    locale: Locale.current,
                    arguments: [utcTimestamp(location.capturedAtUnix)]
                ))
            }
        }

        if let cleanNote {
            parts.append("\(copy.noteLabel): \(cleanNote)")
        }

        if preparedAtUnix > 0 {
            parts.append(String(
                format: copy.preparedAtFormat,
                locale: Locale.current,
                arguments: [utcTimestamp(preparedAtUnix)]
            ))
        }
        parts.append(copy.deliveryBoundary)
        return parts.joined(separator: "\n")
    }

    static func mapURL(_ location: SafetyLocation) -> String {
        let latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), location.latitude)
        let longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), location.longitude)
        return "https://www.google.com/maps/search/?api=1&query=\(latitude),\(longitude)"
    }

    static func utcTimestamp(_ unix: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Remove controls/newlines, collapse whitespace, trim, and cap by Unicode characters.
    static func clean(_ raw: String?, maxCharacters: Int) -> String? {
        guard let raw else { return nil }
        let normalized = raw.unicodeScalars.map { scalar -> Character in
            Character(scalar.properties.isWhitespace || scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let collapsed = String(normalized)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(max(0, maxCharacters)))
    }
}

public enum SafetyCheckInState: Equatable, Sendable {
    case inactive
    case active(remainingSeconds: Int)
    case dueSoon(remainingSeconds: Int)
    case overdue(elapsedSeconds: Int)
}

public enum SafetyCheckInPolicy {
    public static let minimumDurationSeconds = 5 * 60
    public static let maximumDurationSeconds = 24 * 60 * 60
    public static let dueSoonWindowSeconds = 10 * 60

    public static let notificationTitle = "Personal check-in"
    public static let notificationBody =
        "Your timer ended. Check in with someone you trust if you still need to."

    public static func clampedDurationSeconds(_ requested: Int) -> Int {
        min(max(requested, minimumDurationSeconds), maximumDurationSeconds)
    }

    public static func dueAtUnix(startedAtUnix: Int, requestedDurationSeconds: Int) -> Int? {
        guard startedAtUnix > 0 else { return nil }
        let duration = clampedDurationSeconds(requestedDurationSeconds)
        let (due, overflow) = startedAtUnix.addingReportingOverflow(duration)
        return overflow ? nil : due
    }

    /// Resolve current state from a persisted due timestamp. The reminder is local-only; overdue does
    /// not imply that a contact or emergency service was notified.
    public static func state(dueAtUnix: Int?, nowUnix: Int) -> SafetyCheckInState {
        guard let dueAtUnix, dueAtUnix > 0, nowUnix > 0 else { return .inactive }
        let remaining = dueAtUnix - nowUnix
        if remaining <= 0 {
            return .overdue(elapsedSeconds: max(0, -remaining))
        }
        if remaining <= dueSoonWindowSeconds {
            return .dueSoon(remainingSeconds: remaining)
        }
        return .active(remainingSeconds: remaining)
    }

    public static func statusLabel(_ state: SafetyCheckInState) -> String {
        switch state {
        case .inactive:
            return "No check-in timer is active."
        case let .active(remainingSeconds):
            return "Check-in due in \(durationLabel(remainingSeconds))."
        case let .dueSoon(remainingSeconds):
            return "Check-in due soon: \(durationLabel(remainingSeconds)) remaining."
        case let .overdue(elapsedSeconds):
            return "Check-in overdue by \(durationLabel(elapsedSeconds)). No message was sent automatically."
        }
    }

    static func durationLabel(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 60 { return "\(safe)s" }
        if safe < 3_600 { return "\(safe / 60)m" }
        let hours = safe / 3_600
        let minutes = (safe % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
