import Foundation

/// The `settings.json` payload inside a `.noopbak` backup (#1000).
///
/// A `.noopbak` is a ZIP whose first entry is the SQLite database. That round-trips every row, but the
/// user's profile (age / sex / weight / height / HR-max override) and display preferences live in
/// UserDefaults (SharedPreferences on Android), so a restore onto a fresh device silently reset them —
/// the "restore doesn't bring back settings/weight/height" half of #1000. This adds a SECOND, optional
/// ZIP entry — `settings.json`, a flat JSON object — carrying exactly one WHITELISTED set of keys.
///
/// The whitelist is the contract. Its v1 keys remain mirrored by Android's `BackupSettingsCodec`;
/// v2 added the schema stamp and exact civil birthday; v3 added a bounded set of durable, user-authored
/// display, dashboard, reminder, and Sleep Planner preferences; v4 adds the optional user-selected
/// target weight. Additive fields are ignored safely by
/// older readers. Only stable, user-set, non-device-specific values are allowed. NEVER add device ids,
/// peripheral ids, tokens, sync cursors, delivery de-dup state, derived planner outputs,
/// or anything anonymity-sensitive: backups get copied into cloud folders and attached to GitHub
/// issues, so this file must stay safe to share. Unknown keys in an incoming `settings.json` are
/// dropped on the floor; a backup with no `settings.json` (every pre-#1000 backup) is simply a
/// DB-only restore, exactly as before.
///
/// Pure JSON + UserDefaults mapping only — no ZIP code here. The container work stays in the app's
/// `DataBackup`; this lives in the package so the codec and the defaults round-trip are unit-testable
/// headlessly (`swift test --filter BackupSettingsTests`).
public enum BackupSettings {

    /// Canonical entry name inside the `.noopbak` ZIP. Matches the Android exporter.
    public static let entryName = "settings.json"

    /// V1 carried profile/unit values; v2 added exact civil DOB; v3 added explicitly allowlisted durable
    /// preferences; v4 adds an optional user-selected target weight. Every older key remains for
    /// downgrade compatibility.
    public static let schemaVersion = 4
    public static let schemaVersionKey = "settings.schemaVersion"
    public static let dateOfBirthKey = "profile.dateOfBirth"

    /// The JSON kind a whitelisted key must decode to. Anything else (wrong type, JSON bool posing
    /// as a number, nested objects) is dropped rather than guessed at.
    public enum Kind: Sendable {
        case bool, int, double, string, civilDate
    }

    /// THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
    /// (platform-neutral) names. All keys mirror Android's `BackupSettingsCodec.WHITELIST`; later
    /// schema fields are additive and unknown-key-safe for older decoders.
    ///
    /// Profile: the body metrics that power HR zones / calories / recovery baselines, plus the manual
    /// HR-max override (`profile.hrMax`, 0 = auto/Tanaka). Display: the metric/imperial system, the
    /// separate temperature override ("" = match the system), and the Effort axis (#268) - the three
    /// display prefs that exist with identical semantics on both platforms.
    ///
    /// V3 adds only preferences that describe the person's intended app setup. Delivery cursors,
    /// scheduled alarm epochs, planner-derived recovery minutes, permission/authorization receipts,
    /// peripheral state, and feature experiments remain excluded.
    public static let whitelist: [String: Kind] = [
        schemaVersionKey: .int,
        "profile.age": .int,
        dateOfBirthKey: .civilDate,
        "profile.sex": .string,
        "profile.weightKg": .double,
        "profile.targetWeightKg": .double,
        "profile.heightCm": .double,
        "profile.waistCm": .double,
        "profile.hrMax": .int,
        "units.system": .string,
        "units.mass": .string,
        "units.height": .string,
        "units.temperature": .string,
        "effort.scale": .string,
        "hrv.window": .string,
        "theme.appearance": .string,
        "chart.style": .string,
        "trend.chart.style": .string,
        "noop.showDayCycleBackground": .bool,
        "noop.skyBehindCards": .bool,
        "noop.cardOpacityPercent": .int,
        "workoutKeepScreenOn": .bool,
        "today.sectionOrder": .string,
        "today.keyMetrics": .string,
        "today.keyMetricsDetailed": .bool,
        "today.keyMetricsWindowDays": .int,
        "noop.hydrationTracking": .bool,
        "windDown.enabled": .bool,
        "windDown.sleepNeedMinutes": .int,
        "windDown.goalMode": .string,
        "windDown.leadMinutes": .int,
        "sleepPlanner.wakeMinutes": .int,
        "notif.masterEnabled": .bool,
        "notif.onlyWhenWorn": .bool,
        "notif.quietHoursEnabled": .bool,
        "notif.quietStartMinutes": .int,
        "notif.quietEndMinutes": .int,
        "inactivity.enabled": .bool,
        "inactivity.thresholdMinutes": .int,
        "inactivity.reNudgeMinutes": .int,
        "inactivity.buzzLoops": .int,
        "inactivity.activeHoursEnabled": .bool,
        "inactivity.activeStartMinutes": .int,
        "inactivity.activeEndMinutes": .int,
        "hydrationReminders.enabled": .bool,
        "hydrationReminders.intervalMinutes": .int,
        "hydrationReminders.activeStartMinutes": .int,
        "hydrationReminders.activeEndMinutes": .int,
        "hydrationReminders.adaptiveEnabled": .bool,
        "hydrationReminders.strapBuzzEnabled": .bool,
    ]

    /// Canonical JSON key → this platform's UserDefaults key. Identity everywhere except
    /// `profile.hrMax`, which UserDefaults stores as `profile.hrMaxOverride` (see `ProfileStore.K`).
    /// Android maps the same canonical keys onto its own SharedPreferences names.
    public static let appleDefaultsKey: [String: String] = [
        "profile.age": "profile.age",
        dateOfBirthKey: "profile.dateOfBirth",
        "profile.sex": "profile.sex",
        "profile.weightKg": "profile.weightKg",
        "profile.targetWeightKg": "profile.targetWeightKg",
        "profile.heightCm": "profile.heightCm",
        "profile.waistCm": "profile.waistCm",
        "profile.hrMax": "profile.hrMaxOverride",
        "units.system": "units.system",
        "units.mass": "units.mass",
        "units.height": "units.height",
        "units.temperature": "units.temperature",
        "effort.scale": "effort.scale",
        "hrv.window": "hrv.window",
        "theme.appearance": "theme.appearance",
        "chart.style": "chart.style",
        "trend.chart.style": "trend.chart.style",
        "noop.showDayCycleBackground": "noop.showDayCycleBackground",
        "noop.skyBehindCards": "noop.skyBehindCards",
        "noop.cardOpacityPercent": "noop.cardOpacityPercent",
        "workoutKeepScreenOn": "workoutKeepScreenOn",
        "today.sectionOrder": "today.sectionOrder",
        "today.keyMetrics": "today.keyMetrics",
        "today.keyMetricsDetailed": "today.keyMetricsDetailed",
        "today.keyMetricsWindowDays": "today.keyMetricsWindowDays",
        "noop.hydrationTracking": "noop.hydrationTracking",
        "windDown.enabled": "windDown.enabled",
        "windDown.sleepNeedMinutes": "windDown.sleepNeedMinutes",
        "windDown.goalMode": "windDown.goalMode",
        "windDown.leadMinutes": "windDown.leadMinutes",
        "sleepPlanner.wakeMinutes": "windDown.wakeMinutes",
        "notif.masterEnabled": "notif.masterEnabled",
        "notif.onlyWhenWorn": "notif.onlyWhenWorn",
        "notif.quietHoursEnabled": "notif.quietHoursEnabled",
        "notif.quietStartMinutes": "notif.quietStartMinutes",
        "notif.quietEndMinutes": "notif.quietEndMinutes",
        "inactivity.enabled": "inactivity.enabled",
        "inactivity.thresholdMinutes": "inactivity.thresholdMinutes",
        "inactivity.reNudgeMinutes": "inactivity.reNudgeMinutes",
        "inactivity.buzzLoops": "inactivity.buzzLoops",
        "inactivity.activeHoursEnabled": "inactivity.activeHoursEnabled",
        "inactivity.activeStartMinutes": "inactivity.activeStartMinutes",
        "inactivity.activeEndMinutes": "inactivity.activeEndMinutes",
        "hydrationReminders.enabled": "hydrationReminders.enabled",
        "hydrationReminders.intervalMinutes": "hydrationReminders.intervalMinutes",
        "hydrationReminders.activeStartMinutes": "hydrationReminders.activeStartMinutes",
        "hydrationReminders.activeEndMinutes": "hydrationReminders.activeEndMinutes",
        "hydrationReminders.adaptiveEnabled": "hydrationReminders.adaptiveEnabled",
        "hydrationReminders.strapBuzzEnabled": "hydrationReminders.strapBuzzEnabled",
    ]

    // MARK: - Snapshot / apply (UserDefaults boundary)

    /// The whitelisted values currently SET in `defaults`, keyed canonically — the export-side
    /// snapshot. Keys the user never touched are omitted (not defaulted), so restoring this backup
    /// on another device only overwrites what was genuinely set here and leaves the rest of the
    /// target's settings alone.
    public static func snapshot(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [schemaVersionKey: schemaVersion]
        for (canonical, kind) in whitelist {
            guard canonical != schemaVersionKey else { continue }
            guard let storageKey = appleDefaultsKey[canonical],
                  let raw = defaults.object(forKey: storageKey),
                  let coerced = normalized(raw, for: canonical, as: kind) else { continue }
            out[canonical] = coerced
        }
        return out
    }

    /// Write the whitelisted `values` (canonical keys) into `defaults` under this platform's storage
    /// keys — the restore-side apply. Non-whitelisted keys and wrong-typed values are ignored. The
    /// caller decides WHEN (DataBackup applies only after a successful DB swap, never on a failed or
    /// rolled-back restore).
    public static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (canonical, kind) in whitelist {
            guard canonical != schemaVersionKey, canonical != dateOfBirthKey else { continue }
            guard let raw = values[canonical],
                  let coerced = normalized(raw, for: canonical, as: kind),
                  let storageKey = appleDefaultsKey[canonical] else { continue }
            defaults.set(coerced, forKey: storageKey)
        }
        // V2: an exact civil birthday wins over the lossy whole-years compatibility field. Store it as
        // a Date because that is ProfileStore's canonical representation, then mirror the derived age so
        // an older reader still sees a coherent value. V1: when no exact DOB exists, preserve the prior
        // migration behaviour and clear a target-device DOB so ProfileStore re-derives from restored age.
        if let rawDOB = values[dateOfBirthKey],
           let encodedDOB = normalized(rawDOB, for: dateOfBirthKey, as: .civilDate) as? String,
           let dob = civilDate(from: encodedDOB) {
            defaults.set(dob, forKey: dobDefaultsKey)
            defaults.set(age(on: Date(), from: dob), forKey: "profile.age")
            defaults.set(true, forKey: ageConfirmedDefaultsKey)
        } else if values["profile.age"] != nil {
            defaults.removeObject(forKey: dobDefaultsKey)
            defaults.set(true, forKey: ageConfirmedDefaultsKey)
        }
        if values["profile.sex"] != nil {
            defaults.set(true, forKey: sexConfirmedDefaultsKey)
        }
    }

    /// UserDefaults key `ProfileStore` stores the canonical Date under. V2 serializes only its civil
    /// `yyyy-MM-dd` value so a move across time zones cannot shift the user's birthday.
    static let dobDefaultsKey = "profile.dateOfBirth"
    static let ageConfirmedDefaultsKey = "profile.ageInputConfirmed"
    static let sexConfirmedDefaultsKey = "profile.sexInputConfirmed"

    // MARK: - JSON codec

    /// Encode the whitelisted subset of `values` as the flat `settings.json` object. Returns nil when
    /// nothing whitelisted is present (the exporter then writes a DB-only backup — indistinguishable
    /// from a legacy one, which is exactly the right degrade). `.sortedKeys` keeps the output
    /// deterministic so identical settings always produce identical bytes.
    public static func encode(_ values: [String: Any]) -> Data? {
        var filtered: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard key != schemaVersionKey else { continue }
            guard let raw = values[key],
                  let coerced = normalized(raw, for: key, as: kind) else { continue }
            filtered[key] = coerced
        }
        guard !filtered.isEmpty else { return nil }
        filtered[schemaVersionKey] = schemaVersion
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decode a `settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
    /// JSON, a non-object root, unknown keys, and wrong-typed values all degrade to "fewer keys" -
    /// never an error, because a bad settings entry must not fail a restore whose DB half is fine.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = obj[key],
                  let coerced = normalized(raw, for: key, as: kind) else { continue }
            out[key] = coerced
        }
        return out
    }

    // MARK: - Coercion

    /// Coerce a JSON-decoded (or caller-supplied) value to the whitelist's declared kind, or nil if
    /// it can't represent one. JSON booleans arrive as `NSNumber` too, so they are explicitly refused
    /// for numeric kinds — `true` must never become age 1.
    private static func coerce(_ value: Any, to kind: Kind) -> Any? {
        switch kind {
        case .bool:
            guard let n = value as? NSNumber, isBoolean(n) else { return nil }
            return n.boolValue
        case .string:
            return value as? String
        case .int:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            let double = n.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  double >= Double(Int.min),
                  double <= Double(Int.max) else { return nil }
            return Int(double)
        case .double:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            let double = n.doubleValue
            return double.isFinite ? double : nil
        case .civilDate:
            if let date = value as? Date { return civilDateString(date) }
            guard let string = value as? String, civilDate(from: string) != nil else { return nil }
            return string
        }
    }

    /// Key-specific range/enum validation. A hand-edited backup can never install an impossible
    /// schedule or unbounded layout string merely because it had the right primitive JSON type.
    private static func normalized(_ value: Any, for key: String, as kind: Kind) -> Any? {
        guard let coerced = coerce(value, to: kind) else { return nil }
        switch key {
        case "profile.age":
            return boundedInt(coerced, 13...100)
        case dateOfBirthKey:
            guard let encoded = coerced as? String,
                  let dob = civilDate(from: encoded),
                  (13...100).contains(age(on: Date(), from: dob)) else { return nil }
            return encoded
        case "profile.sex":
            return allowedString(coerced, ["male", "female", "nonbinary"])
        case "profile.weightKg":
            return boundedDouble(coerced, 30...250)
        case "profile.targetWeightKg":
            return boundedDouble(coerced, 30...250)
        case "profile.heightCm":
            return boundedDouble(coerced, 120...230)
        case "profile.waistCm":
            return boundedDouble(coerced, 0...200)
        case "profile.hrMax":
            return boundedInt(coerced, 0...230)
        case "units.system":
            return allowedString(coerced, ["metric", "imperial"])
        case "units.mass":
            return allowedString(coerced, ["", "kg", "lb"])
        case "units.height":
            return allowedString(coerced, ["", "cm", "ft_in"])
        case "units.temperature":
            return allowedString(coerced, ["", "celsius", "fahrenheit"])
        case "effort.scale":
            return allowedString(coerced, ["hundred", "whoop"])
        case "hrv.window":
            return allowedString(coerced, ["whole", "deep"])
        case "theme.appearance":
            return allowedString(coerced, ["system", "light", "dark", "black"])
        case "chart.style":
            return allowedString(coerced, ["titanium", "classic"])
        case "trend.chart.style":
            return allowedString(coerced, ["line", "bar"])
        case "today.sectionOrder":
            guard let string = coerced as? String,
                  string.utf8.count <= 2_048,
                  string.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.union(
                          CharacterSet(charactersIn: ".,_- ")).contains($0)
                  }) else { return nil }
            return string
        case "today.keyMetrics":
            guard let string = coerced as? String,
                  string.utf8.count <= 2_048,
                  string.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.union(
                          CharacterSet(charactersIn: ".,_- ")).contains($0)
                  }) else { return nil }
            return normalizedKeyMetricSelection(string)
        case "noop.cardOpacityPercent":
            return boundedInt(coerced, 0...100)
        case "today.keyMetricsWindowDays":
            guard let value = coerced as? Int, [2, 7, 14].contains(value) else { return nil }
            return value
        case "windDown.sleepNeedMinutes":
            return boundedInt(coerced, 5 * 60...11 * 60)
        case "windDown.goalMode":
            return allowedString(coerced, ["target", "balance", "extraOpportunity"])
        case "windDown.leadMinutes":
            return boundedInt(coerced, 0...120)
        case "sleepPlanner.wakeMinutes",
             "notif.quietStartMinutes", "notif.quietEndMinutes",
             "inactivity.activeStartMinutes", "inactivity.activeEndMinutes",
             "hydrationReminders.activeStartMinutes", "hydrationReminders.activeEndMinutes":
            return boundedInt(coerced, 0...(24 * 60 - 1))
        case "inactivity.thresholdMinutes", "inactivity.reNudgeMinutes":
            return boundedInt(coerced, 15...120)
        case "inactivity.buzzLoops":
            return boundedInt(coerced, 1...4)
        case "hydrationReminders.intervalMinutes":
            return boundedInt(coerced, 60...240)
        default:
            return coerced
        }
    }

    private static func allowedString(_ value: Any, _ allowed: Set<String>) -> String? {
        guard let string = value as? String, allowed.contains(string) else { return nil }
        return string
    }

    /// Keep the portable dashboard preference inside the app's one-to-five pin contract. Older backups
    /// may contain all ten metrics; their first five valid unique ids survive in the user's saved order.
    private static func normalizedKeyMetricSelection(_ raw: String) -> String? {
        let allowed: Set<String> = [
            "charge", "effort", "rest", "hrv", "restingHr",
            "bloodOxygen", "respiratory", "steps", "weight", "calories",
        ]
        var seen = Set<String>()
        var selected: [String] = []
        for part in raw.split(separator: ",") {
            let token = String(part).trimmingCharacters(in: .whitespaces)
            guard allowed.contains(token), seen.insert(token).inserted else { continue }
            selected.append(token)
            if selected.count == 5 { break }
        }
        return selected.isEmpty ? nil : selected.joined(separator: ",")
    }

    private static func boundedInt(_ value: Any, _ range: ClosedRange<Int>) -> Int? {
        guard let int = value as? Int, range.contains(int) else { return nil }
        return int
    }

    private static func boundedDouble(_ value: Any, _ range: ClosedRange<Double>) -> Double? {
        guard let double = value as? Double, range.contains(double) else { return nil }
        return double
    }

    /// Encode/decode a birthday as a local civil date, never as an absolute timestamp. Birthdays are
    /// calendar facts: preserving `1990-05-17` across a time-zone move is more exact than preserving the
    /// UTC instant that represented midnight on the exporting phone.
    private static func civilDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func civilDate(from string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    private static func age(on date: Date, from dateOfBirth: Date) -> Int {
        Calendar.current.dateComponents([.year], from: dateOfBirth, to: date).year ?? 0
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
