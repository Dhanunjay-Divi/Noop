import Foundation

/// The two request fields that must remain identical while retrying the same payload.
public struct RemoteBatchIdentity: Equatable, Sendable {
    public let batchId: UUID
    public let sentAt: String

    public init(batchId: UUID, sentAt: String) {
        self.batchId = batchId
        self.sentAt = sentAt
    }
}

/// Durable clients persist an identity against the content fingerprint before network I/O.
///
/// If a server commits a batch but its response is lost, the next process can resend the exact
/// `batch_id` and `sent_at`; the server then returns its stored idempotent acknowledgement.
public protocol RemoteBatchIdentityStoring: Sendable {
    func resolve(fingerprint: String, now: Date) async throws -> RemoteBatchIdentity
    func acknowledge(fingerprint: String) async
}

/// Package default for embeddings that do not provide platform persistence.
///
/// The Noop apps inject their durable preference-backed implementation. Keeping a volatile default
/// preserves the small public coordinator API for tests and third-party package users.
public actor VolatileRemoteBatchIdentityStore: RemoteBatchIdentityStoring {
    private var identities: [String: RemoteBatchIdentity] = [:]

    public init() {}

    public func resolve(fingerprint: String, now: Date) -> RemoteBatchIdentity {
        if let existing = identities[fingerprint] { return existing }
        let identity = RemoteBatchIdentity(
            batchId: UUID(),
            sentAt: ISO8601DateFormatter().string(from: now)
        )
        identities[fingerprint] = identity
        return identity
    }

    public func acknowledge(fingerprint: String) {
        identities.removeValue(forKey: fingerprint)
    }
}

/// Fixed bounds for one replay of derived history.
///
/// A multi-launch replay must not recompute these from `Date()` on every run: doing so moves the
/// lower/upper bounds while natural-key cursors are already in flight and can omit boundary rows.
public struct RemoteDerivedWindow: Codable, Equatable, Sendable {
    public let fromTs: Int
    public let toTs: Int
    public let fromDay: String
    public let toDay: String

    public init(fromTs: Int, toTs: Int, fromDay: String, toDay: String) {
        self.fromTs = fromTs
        self.toTs = toTs
        self.fromDay = fromDay
        self.toDay = toDay
    }

    public init(endingAt now: Date, historyDays: Int, timeZone: TimeZone) {
        let boundedDays = max(1, min(historyDays, 3_650))
        let upper = Int(now.timeIntervalSince1970)
        let lower = upper - boundedDays * 86_400
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.init(
            fromTs: lower,
            toTs: upper,
            fromDay: formatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(lower))
            ),
            toDay: formatter.string(from: now)
        )
    }

    public var isValid: Bool {
        fromTs <= toTs && !fromDay.isEmpty && !toDay.isEmpty && fromDay <= toDay
    }
}

/// Durable position inside one bounded replay of derived history.
///
/// These are exclusive natural-key watermarks, not mutable row offsets. Deleting or inserting a row
/// before a watermark therefore cannot shift the next page. `isComplete` is deliberately persisted
/// during a global replay so a namespace that finished early is not restarted while another namespace
/// still has backlog.
public struct RemoteDerivedCursor: Codable, Equatable, Sendable {
    public var sleepStartTs: Int?
    public var workoutStartTs: Int?
    public var workoutSport: String?
    public var journalDay: String?
    public var journalQuestion: String?
    public var dailySent: Bool
    public var isComplete: Bool

    public init(
        sleepStartTs: Int? = nil,
        workoutStartTs: Int? = nil,
        workoutSport: String? = nil,
        journalDay: String? = nil,
        journalQuestion: String? = nil,
        dailySent: Bool = false,
        isComplete: Bool = false
    ) {
        self.sleepStartTs = sleepStartTs
        if let workoutStartTs, let workoutSport {
            self.workoutStartTs = workoutStartTs
            self.workoutSport = workoutSport
        } else {
            self.workoutStartTs = nil
            self.workoutSport = nil
        }
        if let journalDay, let journalQuestion {
            self.journalDay = journalDay
            self.journalQuestion = journalQuestion
        } else {
            self.journalDay = nil
            self.journalQuestion = nil
        }
        self.dailySent = dailySent
        self.isComplete = isComplete
    }

    public static let start = RemoteDerivedCursor()

    public var markingComplete: RemoteDerivedCursor {
        RemoteDerivedCursor(
            sleepStartTs: sleepStartTs,
            workoutStartTs: workoutStartTs,
            workoutSport: workoutSport,
            journalDay: journalDay,
            journalQuestion: journalQuestion,
            dailySent: true,
            isComplete: true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sleepStartTs
        case workoutStartTs
        case workoutSport
        case journalDay
        case journalQuestion
        case dailySent
        case isComplete
    }

    /// Defaults make preferences written by pre-keyset development builds harmless: their old
    /// offsets are ignored and the replay safely restarts from its fixed lower bound.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sleepStartTs: try values.decodeIfPresent(Int.self, forKey: .sleepStartTs),
            workoutStartTs: try values.decodeIfPresent(Int.self, forKey: .workoutStartTs),
            workoutSport: try values.decodeIfPresent(String.self, forKey: .workoutSport),
            journalDay: try values.decodeIfPresent(String.self, forKey: .journalDay),
            journalQuestion: try values.decodeIfPresent(String.self, forKey: .journalQuestion),
            dailySent: try values.decodeIfPresent(Bool.self, forKey: .dailySent) ?? false,
            isComplete: try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        )
    }
}

public protocol RemoteDerivedCursorStoring: Sendable {
    func cursor(for namespace: String) async -> RemoteDerivedCursor
    func save(_ cursor: RemoteDerivedCursor, for namespace: String) async
    func resetCursor(for namespace: String) async
}

public actor VolatileRemoteDerivedCursorStore: RemoteDerivedCursorStoring {
    private var cursors: [String: RemoteDerivedCursor] = [:]

    public init() {}

    public func cursor(for namespace: String) -> RemoteDerivedCursor {
        cursors[namespace] ?? .start
    }

    public func save(_ cursor: RemoteDerivedCursor, for namespace: String) {
        cursors[namespace] = cursor
    }

    public func resetCursor(for namespace: String) {
        cursors.removeValue(forKey: namespace)
    }
}
