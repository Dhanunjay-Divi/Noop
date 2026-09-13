import Foundation
import Combine
import SwiftUI
import StrandAnalytics

/// Profile provenance carried beside age-shaped computed metrics. These compact numeric tokens fit
/// exactly in a SQLite `REAL` and let every read reject a value produced from a different profile
/// without adding columns or changing the backup schema.
enum AgeMetricProfile {
    /// v1 values may have been computed before activity required four observed days. Keep the old
    /// markers only for computed-source cleanup; readers require the exact v2 marker.
    static let legacyFitnessAgeKey = "fitness_age_profile_v1"
    static let fitnessAgeKey = "fitness_age_profile_v2"
    static let legacyVO2maxEstimateKey = "vo2max_est_profile_v1"
    static let vo2maxEstimateKey = "vo2max_est_profile_v2"
    /// The v2 marker identifies the provenance-safe Vitality model, which no longer treats the legacy
    /// `DailyMetric.steps` column as measured activity. Keep the old key only so the computed-row cleanup
    /// can remove it during upgrade; raw/imported/vendor namespaces are never part of that cleanup.
    static let legacyVitalityKey = "vitality_profile_v1"
    static let vitalityKey = "vitality_profile_v2"

    static func fitnessAgeToken(age: Int, sex: String) -> Double? {
        guard let sexCode = sexCode(sex) else { return nil }
        return Double(age * 10 + sexCode)
    }

    static func vo2maxEstimateToken(age: Int, sex: String, waistCm: Double) -> Double? {
        guard let fitness = fitnessAgeToken(age: age, sex: sex),
              waistCm.isFinite, (50...200).contains(waistCm) else { return nil }
        return fitness * 100_000 + Double(Int((waistCm * 100).rounded()))
    }

    static func vitalityToken(age: Int) -> Double { Double(age) }

    static func accepts(stored: Double?, current: Double?, provenanceRequired: Bool) -> Bool {
        guard let current else { return false }
        if let stored { return stored == current }
        return !provenanceRequired
    }

    /// Fitness Age v2 is a calibration-version boundary as well as a profile boundary. Missing markers
    /// can describe rows produced with the old activity gate, so there is no legacy grace period.
    static func acceptsFitnessAgeV2(stored: Double?, current: Double?) -> Bool {
        guard let current else { return false }
        return stored == current
    }

    /// The optional VO2 estimate is produced by the same gated calculation and follows the same
    /// fail-closed version boundary.
    static func acceptsVO2maxEstimateV2(stored: Double?, current: Double?) -> Bool {
        guard let current else { return false }
        return stored == current
    }

    /// Vitality v2 is a model-version boundary, not only a profile-edit boundary. A missing v2 marker
    /// therefore cannot accept an older steps-influenced headline, even for users whose profile has never
    /// been edited and whose general provenance-required preference is still false.
    static func acceptsVitalityV2(stored: Double?, current: Double) -> Bool {
        stored == current
    }

    private static func sexCode(_ sex: String) -> Int? {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male": return 1
        case "female": return 2
        default: return nil
        }
    }
}

/// Provenance for the external measurement currently reflected by `ProfileStore.weightKg`.
/// The canonical measurement itself lives in SQLite; this compact pointer prevents an older HealthKit
/// or Bluetooth backlog row from rolling the profile backwards.
struct ExternalWeightProvenance: Equatable, Sendable {
    let measuredAt: Date
    let source: String
}

/// Pure freshness/validity gate shared by the live ProfileStore boundary and its tests.
enum ExternalWeightUpdatePolicy {
    /// Deliberately wider than onboarding's ordinary adult stepper, while still rejecting zero,
    /// negative, NaN, infinity, and corrupt outliers before they can affect zones/calorie estimates.
    static let validWeightKg = 20.0...400.0
    static let futureTolerance: TimeInterval = 5 * 60

    static func accepts(weightKg: Double,
                        measuredAt: Date,
                        receivedAt: Date,
                        previousExternalAt: Date?,
                        manualOverrideAt: Date?) -> Bool {
        guard weightKg.isFinite, validWeightKg.contains(weightKg),
              measuredAt.timeIntervalSince1970.isFinite,
              receivedAt.timeIntervalSince1970.isFinite,
              measuredAt <= receivedAt.addingTimeInterval(futureTolerance) else { return false }
        if let previousExternalAt, measuredAt <= previousExternalAt { return false }
        // Once an external source has populated weight, an explicit user edit wins over any cached
        // measurement older than that edit. A genuinely new weigh-in after the edit can still update it.
        if let manualOverrideAt, measuredAt <= manualOverrideAt { return false }
        return true
    }
}

/// User profile (age/sex/body metrics/HR-max) persisted in UserDefaults.
/// Powers HR zones, calories and recovery baselines.
@MainActor
final class ProfileStore: ObservableObject {
    static let defaultDisplayName = "Noop"
    static let maxDisplayNameLength = 32

    /// Friendly name used only in this device's UI. It is intentionally separate from Friends identity,
    /// Self-hosted Sync, and shareable backups.
    @Published private(set) var displayName: String

    /// Canonical source of truth for age (#146): a date of birth, so age advances on its own instead
    /// of silently going stale until the user remembers to bump a number. `age` is derived from this.
    @Published var dateOfBirth: Date {
        didSet {
            d.set(dateOfBirth, forKey: K.dateOfBirth)
            // Mirror the DERIVED age under the legacy `profile.age` key so the `.noopbak` backup
            // whitelist (which carries an Int age, not a Date) keeps exporting a correct value with no
            // change to the cross-platform backup contract. `BackupSettings.apply` clears
            // `profile.dateOfBirth` on restore so a restored Int age re-derives the DOB here.
            d.set(age, forKey: K.legacyAge)
            requireAgeMetricProvenance(age: true, sex: false, waist: false)
            confirmAgeInput()
        }
    }
    @Published var sex: String {
        didSet {
            d.set(sex, forKey: K.sex)
            requireAgeMetricProvenance(age: false, sex: true, waist: false)
            confirmSexInput()
        }
    } // "male" | "female" | "nonbinary"
    @Published var weightKg: Double {
        didSet {
            d.set(weightKg, forKey: K.weight)
            d.set(true, forKey: K.weightConfirmed)
            // Direct setters are user/profile edits. Only create a manual-precedence marker after an
            // external value has existed; otherwise the harmless onboarding seed/first manual entry
            // would prevent a user's older-but-latest HealthKit history from bootstrapping the profile.
            if !applyingExternalWeight, d.object(forKey: K.externalWeightAt) != nil {
                d.set(Date().timeIntervalSince1970, forKey: K.manualWeightOverrideAt)
            }
        }
    }
    /// Optional target selected by the user. This is a remembered preference, not a recommendation:
    /// NOOP never derives a target or a rate of change. Stored canonically in kilograms.
    @Published private(set) var targetWeightKg: Double?
    @Published var heightCm: Double {
        didSet {
            d.set(heightCm, forKey: K.height)
            d.set(true, forKey: K.heightConfirmed)
        }
    }
    /// Optional waist circumference (cm); 0 = not set. Only used to ALSO show an estimated VO₂max
    /// alongside Fitness Age — the Fitness Age itself does not need it (the body term cancels).
    @Published var waistCm: Double {
        didSet {
            d.set(waistCm, forKey: K.waist)
            requireAgeMetricProvenance(age: false, sex: false, waist: true)
        }
    }
    /// 0 = auto-estimate from age.
    @Published var hrMaxOverride: Int { didSet { d.set(hrMaxOverride, forKey: K.hrMax) } }
    /// Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
    /// counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
    /// (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
    @Published var stepTicksPerStep: Double {
        didSet { d.set(min(max(stepTicksPerStep, 0.5), 30.0), forKey: K.stepScale) }
    }

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Written by IntelligenceEngine each analytics pass from the auto-fit against phone steps, and
    // read by the Settings/Steps screen to display + adjust the calibration. `stepsManualCoefficient`
    // is the ONLY user-settable field (0 = auto-fit; > 0 = manual override fed into calibrate()); the
    // other three are fitted outputs, surfaced read-only.
    /// Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine.
    @Published var stepsCalibrationCoefficient: Double { didSet { d.set(stepsCalibrationCoefficient, forKey: K.stepsCoeff) } }
    /// How many calibration days fed the last auto-fit (0 when purely manual / not yet fit).
    @Published var stepsCalibrationSampleDays: Int { didSet { d.set(stepsCalibrationSampleDays, forKey: K.stepsSampleDays) } }
    /// 0–1 trust in the last fit (1.0 for a manual coefficient).
    @Published var stepsCalibrationConfidence: Double { didSet { d.set(stepsCalibrationConfidence, forKey: K.stepsConfidence) } }
    /// True when the persisted coefficient came from the user's manual override, not an auto-fit.
    @Published var stepsCalibrationManual: Bool { didSet { d.set(stepsCalibrationManual, forKey: K.stepsManualFlag) } }
    /// User-set manual coefficient. 0 = auto-fit (nil to the engine); > 0 = manual override.
    @Published var stepsManualCoefficient: Double { didSet { d.set(max(0, stepsManualCoefficient), forKey: K.stepsManualCoeff) } }

    // ── Profile picture (optional, on-device only) ──────────────────────────────────────────────
    /// The user's chosen profile photo as JPEG bytes, or nil for the default SF-Symbol fallback.
    /// LOCAL-ONLY — like every other field here it lives in UserDefaults on this device; NOOP is
    /// fully offline so this is never uploaded anywhere. Always set via ``setAvatar(_:)`` (which
    /// downscales) rather than written directly, so the persisted blob stays small (~256px).
    @Published var avatarImageData: Data? {
        didSet {
            if let avatarImageData { d.set(avatarImageData, forKey: K.avatar) }
            else { d.removeObject(forKey: K.avatar) }
        }
    }

    private let d: UserDefaults
    private var applyingExternalWeight = false
    private enum K {
        static let dateOfBirth = "profile.dateOfBirth"
        /// Pre-#146 age key. No longer the source of truth; kept mirrored from `dateOfBirth` so the
        /// cross-platform `.noopbak` whitelist keeps round-tripping an Int age unchanged.
        static let legacyAge = "profile.age"
        static let sex = "profile.sex", weight = "profile.weightKg"
        static let targetWeight = "profile.targetWeightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride"
        static let stepScale = "profile.stepTicksPerStep"
        static let waist = "profile.waistCm"
        static let stepsCoeff = "profile.stepsCalibrationCoefficient"
        static let stepsSampleDays = "profile.stepsCalibrationSampleDays"
        static let stepsConfidence = "profile.stepsCalibrationConfidence"
        static let stepsManualFlag = "profile.stepsCalibrationManual"
        static let stepsManualCoeff = "profile.stepsManualCoefficient"
        static let avatar = "profile.avatarImageData"
        static let displayName = "profile.displayName"
        /// Explicit confirmation gates for age-shaped estimates. Defaults seeded in `init` are useful
        /// for ordinary UI previews but must never masquerade as user-supplied Fitness Age inputs.
        static let ageConfirmed = "profile.ageInputConfirmed"
        static let sexConfirmed = "profile.sexInputConfirmed"
        static let weightConfirmed = "profile.weightInputConfirmed"
        static let heightConfirmed = "profile.heightInputConfirmed"
        static let onboarded = "noop.onboarded"
        static let fitnessAgeProvenanceRequired = "profile.fitnessAgeProvenanceRequired"
        static let vo2maxProvenanceRequired = "profile.vo2maxProvenanceRequired"
        static let vitalityProvenanceRequired = "profile.vitalityProvenanceRequired"
        static let externalWeightAt = "profile.externalWeightMeasuredAt"
        static let externalWeightSource = "profile.externalWeightSource"
        static let manualWeightOverrideAt = "profile.manualWeightOverrideAt"
        /// The user's/profile's value before the first external measurement took control. Kept only
        /// on-device so deleting every sample from that source can restore a meaningful value instead
        /// of substituting an arbitrary default. Never exported as measurement history.
        static let externalWeightFallback = "profile.externalWeightFallbackKg"
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        displayName = Self.normalizedDisplayName(d.string(forKey: K.displayName))
        // #146 age migration. `dateOfBirth` is authoritative whenever it exists, so age advances on
        // its own. A pre-#146 install — or a `.noopbak` restore, which writes only the legacy Int age
        // and clears any stale DOB (see `BackupSettings.apply`) — has no DOB yet, so derive one from
        // the stored age. Nothing stored → the age-30 default. Deliberately NO equality heuristic: a
        // present DOB is never second-guessed against the mirrored age (doing so would re-freeze age
        // every birthday, the exact staleness #146 fixes).
        let resolvedDOB: Date
        if let dob = d.object(forKey: K.dateOfBirth) as? Date {
            resolvedDOB = dob
        } else if let legacyAge = d.object(forKey: K.legacyAge) as? Int {
            resolvedDOB = Self.dateOfBirth(forAge: legacyAge)
        } else {
            resolvedDOB = Self.dateOfBirth(forAge: 30)
        }
        dateOfBirth = resolvedDOB
        // `didSet` doesn't fire for the initial assignment inside `init`, so persist the resolved DOB
        // and its mirrored age explicitly — otherwise a migrated/derived DOB never reaches storage
        // until the user next edits it. Written from the LOCAL (not `self.dateOfBirth`, which Swift
        // forbids reading before every stored property is initialized).
        d.set(resolvedDOB, forKey: K.dateOfBirth)
        d.set(Self.years(from: resolvedDOB, to: Date()), forKey: K.legacyAge)
        sex = d.string(forKey: K.sex) ?? "male"
        weightKg = d.object(forKey: K.weight) as? Double ?? 75
        let storedTargetWeight = d.object(forKey: K.targetWeight) as? Double
        targetWeightKg = storedTargetWeight.flatMap {
            $0.isFinite && Self.targetWeightRange.contains($0) ? $0 : nil
        }
        heightCm = d.object(forKey: K.height) as? Double ?? 178
        waistCm = d.object(forKey: K.waist) as? Double ?? 0
        hrMaxOverride = d.object(forKey: K.hrMax) as? Int ?? 0
        stepTicksPerStep = min(max(d.object(forKey: K.stepScale) as? Double ?? 1.0, 0.5), 30.0)
        stepsCalibrationCoefficient = d.object(forKey: K.stepsCoeff) as? Double ?? 0
        stepsCalibrationSampleDays = d.object(forKey: K.stepsSampleDays) as? Int ?? 0
        stepsCalibrationConfidence = d.object(forKey: K.stepsConfidence) as? Double ?? 0
        stepsCalibrationManual = d.object(forKey: K.stepsManualFlag) as? Bool ?? false
        stepsManualCoefficient = max(0, d.object(forKey: K.stepsManualCoeff) as? Double ?? 0)
        avatarImageData = d.data(forKey: K.avatar)
        if storedTargetWeight != nil, targetWeightKg == nil {
            d.removeObject(forKey: K.targetWeight)
        }
    }

    /// Persist a compact single-line UI name. Empty input resets to the private default.
    func setDisplayName(_ raw: String) {
        let resolved = Self.normalizedDisplayName(raw)
        displayName = resolved
        if resolved == Self.defaultDisplayName {
            d.removeObject(forKey: K.displayName)
        } else {
            d.set(resolved, forKey: K.displayName)
        }
    }

    static func normalizedDisplayName(_ raw: String?) -> String {
        let words = (raw ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limited = String(words.prefix(maxDisplayNameLength))
        return limited.isEmpty ? defaultDisplayName : limited
    }

    // MARK: - Optional target weight

    static let targetWeightRange: ClosedRange<Double> = 30...250

    /// Persist a user-selected target, or clear it with nil. Invalid values are ignored rather than
    /// replacing a valid target. The range matches the profile weight editor and portable backup.
    func setTargetWeightKg(_ value: Double?) {
        guard let value else {
            targetWeightKg = nil
            d.removeObject(forKey: K.targetWeight)
            return
        }
        guard value.isFinite, Self.targetWeightRange.contains(value) else { return }
        targetWeightKg = value
        d.set(value, forKey: K.targetWeight)
    }

    // MARK: - External weight provenance

    /// The external measurement currently allowed to drive profile weight, if any. Device-specific
    /// provenance intentionally stays in local UserDefaults (the weight measurement history itself is
    /// in the backed-up SQLite store).
    var externalWeightProvenance: ExternalWeightProvenance? {
        guard let source = d.string(forKey: K.externalWeightSource), !source.isEmpty,
              let seconds = d.object(forKey: K.externalWeightAt) as? Double,
              seconds.isFinite else { return nil }
        return ExternalWeightProvenance(measuredAt: Date(timeIntervalSince1970: seconds), source: source)
    }

    /// Accept a measured weight from a trusted external adapter (HealthKit, Bluetooth SIG WSS, etc.).
    /// Returns true only when it changed the profile. The caller must persist the actual measurement in
    /// its canonical source store independently; this method owns only the profile projection.
    ///
    /// Freshness rules:
    /// - the measurement must be a plausible finite human weight and no more than five minutes ahead;
    /// - it must be newer than the last accepted external measurement;
    /// - after an external value exists, a direct/manual profile edit wins until a later measurement.
    @discardableResult
    func acceptExternalWeight(weightKg: Double,
                              measuredAt: Date,
                              source: String,
                              receivedAt: Date = Date()) -> Bool {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty else { return false }
        let previous = externalWeightProvenance?.measuredAt
        let manualAt = (d.object(forKey: K.manualWeightOverrideAt) as? Double)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        guard ExternalWeightUpdatePolicy.accepts(weightKg: weightKg,
                                                 measuredAt: measuredAt,
                                                 receivedAt: receivedAt,
                                                 previousExternalAt: previous,
                                                 manualOverrideAt: manualAt) else { return false }

        if externalWeightProvenance == nil,
           ExternalWeightUpdatePolicy.validWeightKg.contains(self.weightKg) {
            d.set(self.weightKg, forKey: K.externalWeightFallback)
        }
        applyingExternalWeight = true
        self.weightKg = weightKg
        applyingExternalWeight = false
        d.set(measuredAt.timeIntervalSince1970, forKey: K.externalWeightAt)
        d.set(String(cleanSource.prefix(160)), forKey: K.externalWeightSource)
        d.removeObject(forKey: K.manualWeightOverrideAt)
        return true
    }

    /// Reconcile an external source after its backing health store reports deletions. Unlike the normal
    /// monotonic `acceptExternalWeight` path, this method may intentionally move to an older remaining
    /// measurement from the *same* source family. A newer Bluetooth/manual source is never displaced.
    /// Passing nil means that source now has no measurements: restore the pre-external profile value
    /// when known, or retain the current value as an unlinked snapshot for installations predating the
    /// fallback key. In either case stale external provenance is removed.
    @discardableResult
    func reconcileExternalWeight(weightKg: Double?,
                                 measuredAt: Date?,
                                 source: String,
                                 receivedAt: Date = Date()) -> Bool {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty else { return false }
        let sourceFamily = cleanSource.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? cleanSource

        guard let current = externalWeightProvenance else {
            guard let weightKg, let measuredAt else { return false }
            return acceptExternalWeight(weightKg: weightKg,
                                        measuredAt: measuredAt,
                                        source: cleanSource,
                                        receivedAt: receivedAt)
        }
        let currentFamily = current.source.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? current.source
        guard currentFamily == sourceFamily else {
            guard let weightKg, let measuredAt else { return false }
            return acceptExternalWeight(weightKg: weightKg,
                                        measuredAt: measuredAt,
                                        source: cleanSource,
                                        receivedAt: receivedAt)
        }

        let manualAt = (d.object(forKey: K.manualWeightOverrideAt) as? Double)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        if let weightKg, let measuredAt,
           ExternalWeightUpdatePolicy.accepts(weightKg: weightKg,
                                              measuredAt: measuredAt,
                                              receivedAt: receivedAt,
                                              previousExternalAt: nil,
                                              manualOverrideAt: manualAt) {
            applyingExternalWeight = true
            self.weightKg = weightKg
            applyingExternalWeight = false
            d.set(measuredAt.timeIntervalSince1970, forKey: K.externalWeightAt)
            d.set(String(cleanSource.prefix(160)), forKey: K.externalWeightSource)
            d.removeObject(forKey: K.manualWeightOverrideAt)
            return true
        }

        // A manual edit after the source measurement is already the correct current value. Otherwise
        // recover the profile value captured before the source first took control, when available.
        if manualAt == nil,
           let fallback = d.object(forKey: K.externalWeightFallback) as? Double,
           ExternalWeightUpdatePolicy.validWeightKg.contains(fallback) {
            applyingExternalWeight = true
            self.weightKg = fallback
            applyingExternalWeight = false
        }
        d.removeObject(forKey: K.externalWeightAt)
        d.removeObject(forKey: K.externalWeightSource)
        d.removeObject(forKey: K.externalWeightFallback)
        return true
    }

    // MARK: - Profile picture

    /// The profile photo as a SwiftUI `Image`, or nil when none is set (callers fall back to the
    /// `person.crop.circle` SF Symbol). Bridges the stored JPEG bytes through the platform bitmap
    /// type (`NSImage`/`UIImage`) via the shared `Image(platformImage:)` initializer.
    var avatarImage: Image? {
        guard let data = avatarImageData, let img = PlatformImage(data: data) else { return nil }
        return Image(platformImage: img)
    }

    /// Whether a profile photo is set.
    var hasAvatar: Bool { avatarImageData != nil }

    /// Set the profile photo from raw image bytes (e.g. from a `PhotosPicker` / `NSOpenPanel`),
    /// downscaling to a small square so the persisted UserDefaults blob stays tiny. Passing nil
    /// clears it. If downscaling can't decode the bytes, the originals are stored as-is rather than
    /// dropping the user's pick. To remove a photo, pass nil or call ``clearAvatar()``.
    func setAvatar(_ data: Data?) {
        guard let data else { avatarImageData = nil; return }
        // Downscale to ~256px before persisting; fall back to the raw bytes if decoding fails so a
        // valid-but-unusual image still saves rather than silently dropping.
        avatarImageData = AvatarImage.downscaledJPEG(from: data, maxDimension: 256) ?? data
    }

    /// Remove the profile photo (reverts the header / Settings to the default icon).
    func clearAvatar() { avatarImageData = nil }

    /// The manual override to feed into `StepsEstimateEngine.calibrate(_:manualOverride:)`:
    /// nil when 0 (auto-fit), the positive value otherwise.
    var stepsManualOverride: Double? { stepsManualCoefficient > 0 ? stepsManualCoefficient : nil }

    /// Current age in whole years, derived from `dateOfBirth` (#146) rather than a number the user has
    /// to remember to update. Every existing caller (HR zones, calories, Fitness/Wellness Age) reads this
    /// unchanged (including the experimental Wellness Age compatibility calculation).
    var age: Int { Self.years(from: dateOfBirth, to: Date()) }

    /// Whether the user explicitly accepted the two profile inputs required by the published
    /// Fitness-Age model. Existing users who completed the old onboarding flow migrate as confirmed;
    /// a fresh install remains unconfirmed even though the editor displays harmless seed values.
    var ageInputConfirmed: Bool { d.bool(forKey: K.ageConfirmed) || d.bool(forKey: K.onboarded) }
    var sexInputConfirmed: Bool { d.bool(forKey: K.sexConfirmed) || d.bool(forKey: K.onboarded) }
    var fitnessInputsConfirmed: Bool { ageInputConfirmed && sexInputConfirmed }
    /// Display seeds do not become health inputs until the user accepts the profile page, edits the
    /// field, restores it, or a trusted external measurement updates weight.
    var weightInputConfirmed: Bool {
        d.bool(forKey: K.weightConfirmed) || d.object(forKey: K.weight) != nil
    }
    var heightInputConfirmed: Bool {
        d.bool(forKey: K.heightConfirmed) || d.object(forKey: K.height) != nil
    }
    var bodyInputsConfirmed: Bool { weightInputConfirmed && heightInputConfirmed }

    var adultBMI: Double? {
        BodyProfilePolicy.adultBMI(
            age: age,
            weightKg: weightKg,
            heightCm: heightCm,
            measurementsConfirmed: ageInputConfirmed && bodyInputsConfirmed
        )
    }

    func targetWeightAvailability(
        currentWeightKg: Double? = nil,
        targetWeightKg: Double? = nil,
        currentWeightConfirmed: Bool? = nil
    ) -> BodyWeightTargetAvailability {
        BodyProfilePolicy.targetAvailability(
            age: age,
            currentWeightKg: currentWeightKg ?? weightKg,
            heightCm: heightCm,
            targetWeightKg: targetWeightKg ?? self.targetWeightKg,
            measurementsConfirmed: ageInputConfirmed && heightInputConfirmed
                && (currentWeightConfirmed ?? weightInputConfirmed)
        )
    }

    var fitnessAgeProvenanceRequired: Bool { d.bool(forKey: K.fitnessAgeProvenanceRequired) }
    var vo2maxProvenanceRequired: Bool { d.bool(forKey: K.vo2maxProvenanceRequired) }
    var vitalityProvenanceRequired: Bool { d.bool(forKey: K.vitalityProvenanceRequired) }
    var fitnessAgeProfileToken: Double? { AgeMetricProfile.fitnessAgeToken(age: age, sex: sex) }
    var vo2maxProfileToken: Double? {
        AgeMetricProfile.vo2maxEstimateToken(age: age, sex: sex, waistCm: waistCm)
    }
    var vitalityProfileToken: Double { AgeMetricProfile.vitalityToken(age: age) }

    /// Included in view task/cache identities so returning from a profile editor cannot restore values
    /// computed from the previous age, sex, or waist.
    var ageMetricStateToken: String {
        let fitness = fitnessAgeProfileToken.map { String($0) } ?? "nil"
        let vo2 = vo2maxProfileToken.map { String($0) } ?? "nil"
        return [fitness, vo2, String(vitalityProfileToken),
                String(fitnessAgeProvenanceRequired), String(vo2maxProvenanceRequired),
                String(vitalityProvenanceRequired),
                String(ageInputConfirmed), String(sexInputConfirmed),
                String(weightKg), String(weightInputConfirmed)].joined(separator: "|")
    }

    func acceptsFitnessAge(provenance: Double?) -> Bool {
        AgeMetricProfile.acceptsFitnessAgeV2(
            stored: provenance, current: fitnessAgeProfileToken)
    }

    func acceptsVO2maxEstimate(provenance: Double?) -> Bool {
        AgeMetricProfile.acceptsVO2maxEstimateV2(
            stored: provenance, current: vo2maxProfileToken)
    }

    func acceptsVitality(provenance: Double?) -> Bool {
        AgeMetricProfile.acceptsVitalityV2(stored: provenance, current: vitalityProfileToken)
    }

    private func requireAgeMetricProvenance(age: Bool, sex: Bool, waist: Bool) {
        if age || sex { d.set(true, forKey: K.fitnessAgeProvenanceRequired) }
        if age || sex || waist { d.set(true, forKey: K.vo2maxProvenanceRequired) }
        if age { d.set(true, forKey: K.vitalityProvenanceRequired) }
    }

    func confirmAgeInput() {
        d.set(true, forKey: K.ageConfirmed)
        requireAgeMetricProvenance(age: true, sex: false, waist: false)
    }
    func confirmSexInput() {
        d.set(true, forKey: K.sexConfirmed)
        requireAgeMetricProvenance(age: false, sex: true, waist: false)
    }
    func confirmFitnessInputs() {
        confirmAgeInput()
        confirmSexInput()
    }

    func confirmBodyInputs() {
        d.set(true, forKey: K.weightConfirmed)
        d.set(true, forKey: K.heightConfirmed)
    }

    /// The onboarding shell intentionally does not observe `ProfileStore` (live profile updates used
    /// to restart its animations). This narrow static boundary lets the Profile CTA record acceptance
    /// without subscribing that shell to the store; the computed confirmation properties read through
    /// UserDefaults, so the existing environment object sees the new state immediately.
    static func confirmFitnessInputsInDefaults(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: K.ageConfirmed)
        defaults.set(true, forKey: K.sexConfirmed)
        defaults.set(true, forKey: K.fitnessAgeProvenanceRequired)
        defaults.set(true, forKey: K.vo2maxProvenanceRequired)
        defaults.set(true, forKey: K.vitalityProvenanceRequired)
    }

    static func confirmBodyInputsInDefaults(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: K.weightConfirmed)
        defaults.set(true, forKey: K.heightConfirmed)
    }

    /// Pure decision used by platform tests and migrations.
    nonisolated static func fitnessInputsAreConfirmed(
        ageConfirmed: Bool, sexConfirmed: Bool, onboardingCompleted: Bool
    ) -> Bool {
        (ageConfirmed || onboardingCompleted) && (sexConfirmed || onboardingCompleted)
    }

    /// Whole years elapsed `from`→`to` (floor — a birthday not yet reached this year doesn't count).
    nonisolated static func years(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.year], from: from, to: to).year ?? 0
    }

    /// A date of birth `age` whole years before today, anchored to today's month/day so the derived
    /// age is exactly `age`. Used to migrate a stored manual age and to seed the DOB picker.
    nonisolated static func dateOfBirth(forAge age: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -age, to: Date()) ?? Date()
    }

    /// Bounds for the DOB picker, matching the old 13...100 age `Stepper` range so a pick can't derive
    /// an out-of-range age.
    nonisolated static var dateOfBirthRange: ClosedRange<Date> {
        dateOfBirth(forAge: 100)...dateOfBirth(forAge: 13)
    }

    /// Tanaka estimate unless overridden.
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded()) }

    /// Whether the cycle-awareness opt-in applies to this profile (#801). Cycle phase is read from the
    /// MENSTRUAL skin-temperature shift, so the opt-in (the Health card + the Automations toggle) is only
    /// offered to profiles it can apply to and is NOT shown for male profiles. `sex` is the free String
    /// "male" | "female" | "nonbinary"; we gate by excluding "male" (case-insensitive) so any non-male
    /// value, including unrecognised ones, still sees the opt-in rather than being silently excluded.
    var cycleAwarenessApplies: Bool { Self.cycleAwarenessApplies(sex: sex) }

    /// Pure form of ``cycleAwarenessApplies`` for the given `sex` token, so the gate can be unit-tested
    /// without a live store / UserDefaults. `nonisolated` because it is a pure function over its argument
    /// (no actor state), so the gate and its tests can call it from any context.
    nonisolated static func cycleAwarenessApplies(sex: String) -> Bool {
        sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "male"
    }

    /// Allowed range for the step-calibration divisor (#132). 5/MG straps overcount by
    /// up to ~24×, so the old 4.0 ceiling could never reach the truth.
    static let stepScaleRange: ClosedRange<Double> = 0.5...30.0

    /// Variable step for the calibration stepper so high values stay reachable: fine near
    /// the 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat
    /// 0.1 step from 0.5 to 30 would be ~295 taps — unusable.
    /// - `< 2.0` → 0.1   (precision around the default)
    /// - `2.0–5.0` → 0.5
    /// - `≥ 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
    static func stepScaleIncrement(for value: Double) -> Double {
        switch value {
        case ..<2.0: return 0.1
        case ..<5.0: return 0.5
        default: return 1.0
        }
    }

    /// One increment/decrement of the calibration divisor, snapped to the increment grid and
    /// clamped to ``stepScaleRange``. Decrement uses the increment for the *target* band so the
    /// up/down sequence is symmetric at the band boundaries (e.g. 5.0 −1 → 4.0, 4.0 +0.5 → 4.5).
    static func steppedStepScale(_ value: Double, up: Bool) -> Double {
        let delta = up ? stepScaleIncrement(for: value)
                       : stepScaleIncrement(for: value - 0.0001)
        let next = ((value + (up ? delta : -delta)) / delta).rounded() * delta
        return min(max(next, stepScaleRange.lowerBound), stepScaleRange.upperBound)
    }
}
