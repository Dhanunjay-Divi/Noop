import Foundation
import Security

/// One active medication the user chose to record. The name and optional dose/timing note remain inside
/// the device-only secure store; analytics receives only whether any entry has a recent change date.
struct MedicationEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var details: String
    /// Optional local ISO day for a medication start or dose change. Editing the text does not
    /// automatically change this clinical-context date.
    var changeDay: String?

    init(id: UUID = UUID(), name: String, details: String = "", changeDay: String? = nil) {
        self.id = id
        self.name = name
        self.details = details
        self.changeDay = changeDay
    }
}

/// Pure policy kept separate from Keychain I/O so the recency boundary is deterministic and testable.
enum MedicationContextPolicy {
    static let recentChangeDays = 14

    static func hasRecentChange(_ entries: [MedicationEntry], asOfDay: String) -> Bool {
        guard let asOf = parseDay(asOfDay) else { return false }
        return entries.contains { entry in
            guard let day = entry.changeDay,
                  let changed = parseDay(day) else { return false }
            let age = calendar.dateComponents([.day], from: changed, to: asOf).day ?? Int.max
            return age >= 0 && age <= recentChangeDays
        }
    }

    static func validDay(_ value: String) -> Bool {
        parseDay(value) != nil
    }

    static func localDayKey(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            year,
            month,
            day
        )
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private static func parseDay(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
            ? date
            : nil
    }
}

/// Device-only Keychain storage for active medications. This data is intentionally outside the app
/// database, UserDefaults, portable backups, self-hosted sync, Coach context, analytics, and logs.
enum MedicationStore {
    private static let service = "com.noop.medication-context"
    private static let account = "active-medications"
    private static let maximumEntries = 30
    private static let maximumNameCharacters = 120
    private static let maximumDetailsCharacters = 240

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static var active: [MedicationEntry] {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([MedicationEntry].self, from: data) else {
            return []
        }
        return normalized(decoded)
    }

    static var hasRecentChange: Bool {
        MedicationContextPolicy.hasRecentChange(
            active,
            asOfDay: MedicationContextPolicy.localDayKey(Date())
        )
    }

    @discardableResult
    static func upsert(_ entry: MedicationEntry) -> Bool {
        guard let clean = normalized(entry) else { return false }
        var entries = active
        if let index = entries.firstIndex(where: { $0.id == clean.id }) {
            entries[index] = clean
        } else {
            guard entries.count < maximumEntries else { return false }
            entries.append(clean)
        }
        return save(entries)
    }

    @discardableResult
    static func remove(id: UUID) -> Bool {
        let entries = active
        let updated = entries.filter { $0.id != id }
        guard updated.count != entries.count else { return true }
        return save(updated)
    }

    private static func save(_ entries: [MedicationEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(normalized(entries)) else { return false }
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func normalized(_ entries: [MedicationEntry]) -> [MedicationEntry] {
        var seen = Set<UUID>()
        return entries.compactMap(normalized)
            .filter { seen.insert($0.id).inserted }
            .prefix(maximumEntries)
            .map { $0 }
    }

    private static func normalized(_ entry: MedicationEntry) -> MedicationEntry? {
        let name = String(
            entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumNameCharacters)
        )
        guard !name.isEmpty else { return nil }
        let details = String(
            entry.details.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumDetailsCharacters)
        )
        let changeDay = entry.changeDay.flatMap {
            MedicationContextPolicy.validDay($0) ? $0 : nil
        }
        return MedicationEntry(id: entry.id, name: name, details: details, changeDay: changeDay)
    }
}
