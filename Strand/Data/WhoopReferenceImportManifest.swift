import Foundation

/// Durable provenance evidence for metric/day pairs successfully written by the current WHOOP CSV
/// importer.
///
/// The daily/metric tables predate per-row import revision columns. Keeping this tiny metric/day→revision
/// manifest outside those value tables lets comparison reject legacy rows that cannot prove they came
/// through the provenance-aware importer, without rewriting or deleting any biometric value.
struct WhoopReferenceImportManifest {
    private struct State: Codable {
        var revisionByMetricDay: [String: String]
    }

    private let defaults: UserDefaults
    private let namespace: String

    init(
        defaults: UserDefaults = .standard,
        namespace: String = "noop.whoopReferenceImportManifest.v2"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    func recordOfficialMetrics(
        _ entries: [(day: String, metricKey: String)],
        deviceId: String,
        schemaRevision: String
    ) {
        guard !deviceId.isEmpty, !schemaRevision.isEmpty else { return }
        let accepted = entries.filter {
            Self.validDay($0.day) && Self.validMetricKey($0.metricKey)
        }
        guard !accepted.isEmpty else { return }
        var state = loadState(deviceId: deviceId)
        for entry in accepted {
            state.revisionByMetricDay[
                Self.metricDayKey(day: entry.day, metricKey: entry.metricKey)
            ] = schemaRevision
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(deviceId: deviceId))
    }

    func verifiedDays(
        deviceId: String,
        schemaRevision: String,
        metricKey: String
    ) -> Set<String> {
        guard !deviceId.isEmpty, !schemaRevision.isEmpty, Self.validMetricKey(metricKey)
        else { return [] }
        let state = loadState(deviceId: deviceId)
        let suffix = "|\(metricKey)"
        return Set(state.revisionByMetricDay.compactMap { metricDay, revision in
            guard revision == schemaRevision, metricDay.hasSuffix(suffix) else { return nil }
            let day = String(metricDay.dropLast(suffix.count))
            return Self.validDay(day) ? day : nil
        })
    }

    func remove(deviceId: String) {
        defaults.removeObject(forKey: key(deviceId: deviceId))
    }

    private func loadState(deviceId: String) -> State {
        guard let data = defaults.data(forKey: key(deviceId: deviceId)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State(revisionByMetricDay: [:]) }
        return state
    }

    private func key(deviceId: String) -> String { "\(namespace).\(deviceId)" }

    private static func metricDayKey(day: String, metricKey: String) -> String {
        "\(day)|\(metricKey)"
    }

    private static func validMetricKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 80
            && key.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            }
    }

    private static func validDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: year, month: month, day: dayOfMonth)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == dayOfMonth
    }
}
