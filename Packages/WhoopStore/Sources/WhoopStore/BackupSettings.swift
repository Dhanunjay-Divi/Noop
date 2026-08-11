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
/// v2's additive schema stamp and exact civil birthday are ignored safely by older/other-platform
/// readers until they adopt them. Only stable, user-set,
/// non-device-specific values are allowed. NEVER add device ids, peripheral ids, tokens, sync cursors,
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

    /// `settings.json` v1 carried whole-years age only. V2 adds an exact civil date of birth while
    /// retaining that legacy age key for old readers and cross-platform downgrade compatibility.
    public static let schemaVersion = 2
    public static let schemaVersionKey = "settings.schemaVersion"
    public static let dateOfBirthKey = "profile.dateOfBirth"

    /// The JSON kind a whitelisted key must decode to. Anything else (wrong type, JSON bool posing
    /// as a number, nested objects) is dropped rather than guessed at.
    public enum Kind: Sendable {
        case int, double, string, civilDate
    }

    /// THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
    /// (platform-neutral) names. V1 keys mirror Android's `BackupSettingsCodec.WHITELIST`; v2 fields
    /// are additive and unknown-key-safe for older decoders.
    ///
    /// Profile: the body metrics that power HR zones / calories / recovery baselines, plus the manual
    /// HR-max override (`profile.hrMax`, 0 = auto/Tanaka). Display: the metric/imperial system, the
    /// separate temperature override ("" = match the system), and the Effort axis (#268) — the three
    /// display prefs that exist with identical semantics on both platforms. Deliberately EXCLUDED:
    /// step calibration (per-strap, not per-person), the avatar blob (bulky, and not "settings"),
    /// steps-engine fitted outputs (derived), and every noop.* toggle that is device- or
    /// install-specific.
    public static let whitelist: [String: Kind] = [
        schemaVersionKey: .int,
        "profile.age": .int,
        dateOfBirthKey: .civilDate,
        "profile.sex": .string,
        "profile.weightKg": .double,
        "profile.heightCm": .double,
        "profile.waistCm": .double,
        "profile.hrMax": .int,
        "units.system": .string,
        "units.temperature": .string,
        "effort.scale": .string,
    ]

    /// Canonical JSON key → this platform's UserDefaults key. Identity everywhere except
    /// `profile.hrMax`, which UserDefaults stores as `profile.hrMaxOverride` (see `ProfileStore.K`).
    /// Android maps the same canonical keys onto its own SharedPreferences names.
    public static let appleDefaultsKey: [String: String] = [
        "profile.age": "profile.age",
        dateOfBirthKey: "profile.dateOfBirth",
        "profile.sex": "profile.sex",
        "profile.weightKg": "profile.weightKg",
        "profile.heightCm": "profile.heightCm",
        "profile.waistCm": "profile.waistCm",
        "profile.hrMax": "profile.hrMaxOverride",
        "units.system": "units.system",
        "units.temperature": "units.temperature",
        "effort.scale": "effort.scale",
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
                  let coerced = coerce(raw, to: kind) else { continue }
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
                  let coerced = coerce(raw, to: kind),
                  let storageKey = appleDefaultsKey[canonical] else { continue }
            defaults.set(coerced, forKey: storageKey)
        }
        // V2: an exact civil birthday wins over the lossy whole-years compatibility field. Store it as
        // a Date because that is ProfileStore's canonical representation, then mirror the derived age so
        // an older reader still sees a coherent value. V1: when no exact DOB exists, preserve the prior
        // migration behaviour and clear a target-device DOB so ProfileStore re-derives from restored age.
        if let rawDOB = values[dateOfBirthKey],
           let encodedDOB = coerce(rawDOB, to: .civilDate) as? String,
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
            guard let raw = values[key], let coerced = coerce(raw, to: kind) else { continue }
            filtered[key] = coerced
        }
        guard !filtered.isEmpty else { return nil }
        filtered[schemaVersionKey] = schemaVersion
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decode a `settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
    /// JSON, a non-object root, unknown keys, and wrong-typed values all degrade to "fewer keys" —
    /// never an error, because a bad settings entry must not fail a restore whose DB half is fine.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = obj[key], let coerced = coerce(raw, to: kind) else { continue }
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
        case .string:
            return value as? String
        case .int:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.intValue
        case .double:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.doubleValue
        case .civilDate:
            if let date = value as? Date { return civilDateString(date) }
            guard let string = value as? String, civilDate(from: string) != nil else { return nil }
            return string
        }
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
