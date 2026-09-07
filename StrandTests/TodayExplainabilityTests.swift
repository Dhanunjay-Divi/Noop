import XCTest
import SwiftUI
import StrandAnalytics
@testable import Strand

/// Renders a `LocalizedStringKey` to its user-visible string so tests can keep pinning verbatim copy.
///
/// The production `title` keys are deliberately built with interpolation ("Last night · \(date)") so the
/// string-catalog extractor sees the "Last night · %@" format key (#779). `LocalizedStringKey` equality
/// compares the key pattern + formatting flag, so an interpolated key never equals a literal one — tests
/// must compare the rendered text instead. Mirror is the only supported-ish way to get at the key and its
/// arguments; if SwiftUI's internals shift, this fails loudly (nil) rather than passing vacuously.
private func rendered(_ key: LocalizedStringKey?) -> String? {
    guard let key else { return nil }
    let mirror = Mirror(reflecting: key)
    guard let pattern = mirror.descendant("key") as? String else { return nil }
    guard let args = mirror.descendant("arguments") as? [Any], !args.isEmpty else { return pattern }
    var cvarArgs: [CVarArg] = []
    for arg in args {
        // FormatArgument(storage: .value(CVarArg, Formatter?)) — descend to the first leaf value.
        let storage = Mirror(reflecting: arg).descendant("storage") ?? arg
        guard let payload = Mirror(reflecting: storage).children.first?.value else { return nil }
        let leaf = Mirror(reflecting: payload).children.first?.value ?? payload
        guard let cvar = leaf as? CVarArg else { return nil }
        cvarArgs.append(cvar)
    }
    return String(format: pattern, arguments: cvarArgs)
}

/// Sleep & Recovery guidance / explainability layer — the Today lane pure mappers (spec 2026-06-20).
///
/// "No bare number without a STATE, a REASON, and a NEXT STEP." These pin the honest precedence and the
/// verbatim copy of the three Today components implemented in TodayView, so the wording and the honesty
/// rules can't silently regress and stay byte-for-byte in step with the Kotlin Today lane:
///   • Component 2 — explained score states (calibrating / carriedLastNight / needsStrap)
///   • Component 3 — recording status (recording / lastSynced Xm ago / notRecording)
///   • Component 4 — provenance label (On-device / Whoop / Apple Health = the real per-day merge winner)
final class TodayExplainabilityTests: XCTestCase {

    // MARK: - Component 2 — MetricTileState.resolve precedence

    func testScoreState_todayValueWins_isScored() {
        // A real today value beats everything else — the caller renders the number, not a state.
        let s = MetricTileState.resolve(hasTodayValue: true,
                                   calibratingNightsRemaining: 2,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .scored)
    }

    func testScoreState_noValueButCalibrating_isCalibratingWithRemaining() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 3,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .calibrating(nightsRemaining: 3))
    }

    func testScoreState_noValueNoCalibrationButCarry_isCarriedLastNight() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 Jun")
        XCTAssertEqual(s, .carriedLastNight(date: "14 Jun", stale: false))
    }

    func testScoreState_carryWithinCap_isFreshLastNight() {
        // #779: a recent carry keeps the "Last night" framing.
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 Jun",
                                   carriedStale: false)
        XCTAssertEqual(s, .carriedLastNight(date: "14 Jun", stale: false))
        XCTAssertEqual(rendered(s.title), "Last night · 14 Jun")
    }

    func testScoreState_staleCarry_relabelsLatestSleep() {
        // #779: a weeks-old carry is still shown (not a bare blank) but relabelled so the number is never
        // passed off as "Last night".
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: "14 May",
                                   carriedStale: true)
        XCTAssertEqual(s, .carriedLastNight(date: "14 May", stale: true))
        XCTAssertEqual(rendered(s.title), "Latest sleep · 14 May")
        XCTAssertEqual(s.accessibilityText,
                       "Latest sleep, 14 May. This is your last scored session. Wear Noop Band overnight for a fresh score.")
    }

    func testScoreState_nothingBanked_isNeedsStrap() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: nil,
                                   carriedDate: nil)
        XCTAssertEqual(s, .needsStrap)
    }

    func testScoreState_completedSeedIsBaselineReady() {
        // The completed seed night cannot score against itself. It is ready for the next qualifying
        // night, not "1 more night" away from completing the baseline.
        let zero = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 0,
                                   carriedDate: nil)
        XCTAssertEqual(zero, .baselineReady)

        let negative = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: -3,
                                   carriedDate: nil)
        XCTAssertEqual(negative, .baselineReady)
    }

    func testScoreState_baselineReadyCopyExplainsTheFirstScoreBoundary() {
        let s = MetricTileState.resolve(hasTodayValue: false,
                                   calibratingNightsRemaining: 0,
                                   carriedDate: nil)
        XCTAssertEqual(s.accessibilityText,
                       "Baseline ready. 4 of 4 valid HRV nights complete. The next qualifying night can produce your first Recovery.")
    }

    // MARK: - Component 2 — verbatim copy (via the VoiceOver text, which surfaces the visible words)

    func testScoreState_calibratingDetail_pluralisesNights() {
        XCTAssertEqual(MetricTileState.calibrating(nightsRemaining: 3).accessibilityText,
                       "Calibrating. Building your baseline. About 3 more nights until your scores are personal.")
    }

    func testScoreState_calibratingDetail_singularNight() {
        XCTAssertEqual(MetricTileState.calibrating(nightsRemaining: 1).accessibilityText,
                       "Calibrating. Building your baseline. About 1 more night until your scores are personal.")
    }

    func testScoreState_carriedLastNight_stampsDate() {
        XCTAssertEqual(MetricTileState.carriedLastNight(date: "14 Jun", stale: false).accessibilityText,
                       "Last night, 14 Jun. Tonight's lands after you sleep with Noop Band on.")
    }

    func testScoreState_needsStrap_copy() {
        XCTAssertEqual(MetricTileState.needsStrap.accessibilityText,
                       "Needs wearable data. No data for today. Was Noop Band worn and connected overnight?")
    }

    func testScoreState_scored_hasNoStateText() {
        XCTAssertNil(MetricTileState.scored.title)
        XCTAssertNil(MetricTileState.scored.detail)
        XCTAssertNil(MetricTileState.scored.accessibilityText)
    }

    func testScoreState_honesty_calibratingAndNeedsStrapShowNoNumber() {
        // The honesty rule: calibrating / needsStrap never carry a fabricated value. Their texts must
        // not contain a percent sign or a digit that could be read as a score (the night-count is fine).
        XCTAssertFalse(MetricTileState.needsStrap.accessibilityText!.contains("%"))
        XCTAssertFalse(MetricTileState.calibrating(nightsRemaining: 2).accessibilityText!.contains("%"))
    }

    func testScoreState_copy_hasNoEmDash() {
        let states: [MetricTileState] = [.calibrating(nightsRemaining: 2),
                                    .baselineReady,
                                    .carriedLastNight(date: "14 Jun", stale: false),
                                    .carriedLastNight(date: "14 May", stale: true),
                                    .needsStrap]
        for s in states {
            XCTAssertFalse(s.accessibilityText!.contains("\u{2014}"),
                           "MetricTileState \(s) must not contain an em-dash")
        }
    }

    // MARK: - Fourth-night parity across Today variants

    func testCoupledCalibrationSuppressesPriorScoreThroughCompletedSeedNight() {
        XCTAssertNil(
            CoupledView.displayedRecovery(
                today: nil, carried: 81, calibrationNights: 2),
            "a prior score must not displace active calibration")
        XCTAssertNil(
            CoupledView.displayedRecovery(
                today: nil, carried: 81,
                calibrationNights: Baselines.minNightsSeed),
            "the just-completed seed night must show Baseline ready, not a prior score")
        XCTAssertEqual(
            CoupledView.displayedRecovery(
                today: nil, carried: 81, calibrationNights: nil),
            81,
            "carry-over resumes once calibration no longer owns the state")
        XCTAssertEqual(
            CoupledView.displayedRecovery(
                today: 72, carried: 81,
                calibrationNights: Baselines.minNightsSeed),
            72,
            "a real current score always wins")
    }

    func testV2HeroVoiceOverUsesCompleteLocalizedFormats() {
        XCTAssertEqual(
            V2HeroArc.accessibilityReadout(
                value: nil, maximum: 100, caption: "Valid HRV 2/4"),
            "Not yet calculated, Valid HRV 2/4")
        XCTAssertEqual(
            V2HeroArc.accessibilityReadout(
                value: 64, maximum: 100, caption: "Moderate"),
            "64 out of 100, Moderate")
        XCTAssertEqual(
            V2HeroArc.accessibilityReadout(
                value: 64, maximum: 100, caption: nil),
            "64 out of 100")
        XCTAssertEqual(
            V2HeroArc.accessibilityReadout(
                value: 7.5, maximum: 21, caption: nil, decimals: 1),
            "7.5 out of 21")
    }

    func testRevisedPresentationCatalogKeysCoverEverySupportedLocale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Strand/Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let locales = [
            "en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"
        ]
        let keys = [
            "Baseline ready",
            "Valid HRV %lld/%lld",
            "Learning your baseline, %lld of %lld valid HRV nights.",
            "Sleep synced, but HRV was unavailable or did not pass the baseline quality and range checks. Calibration remains at %lld of %lld valid HRV nights.",
            "Usable beat-to-beat timing evidence was unavailable for this night, limiting confidence in the on-device stage estimates and Rest.",
            "Usable breathing-rate evidence was unavailable for this night, limiting confidence in the on-device stage estimates and Rest.",
            "A transparent cardiorespiratory recipe for estimating deep and REM, now used by default. It changes how already-detected nights are split into stages. Sleep detection is unchanged, but Rest and Recovery may change because stage estimates feed those scores. Turn it off to fall back to V1. Takes effect on the next nights staged.",
            "Whole night is NOOP's default measure; Deep sleep pools HRV over slow-wave sleep only, reading lower and using the deep-sleep window. Switching re-scores your recent nights over the new window and takes effect right away once you have a few nights of data.",
            "appwide.v4.not_calculated_with_context_format",
            "appwide.v4.value_out_of_format",
            "appwide.v4.value_out_of_with_context_format",
        ]

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any], key)
            let english = try XCTUnwrap(
                ((localizations["en"] as? [String: Any])?["stringUnit"]
                    as? [String: Any])?["value"] as? String,
                "\(key) en")
            for locale in locales {
                let value = try XCTUnwrap(
                    ((localizations[locale] as? [String: Any])?["stringUnit"]
                        as? [String: Any])?["value"] as? String,
                    "\(key) \(locale)")
                XCTAssertFalse(value.isEmpty, "\(key) \(locale)")
                if locale != "en" {
                    XCTAssertNotEqual(
                        value, english,
                        "\(key) must not fall back to English in \(locale)")
                }
            }
        }
    }

    // MARK: - Component 3 — RecordingState.resolve

    func testRecordingState_connectedWithLiveHR_isRecording() {
        // The canonical gate: `recording` IFF connected AND a live heart-rate sample is present.
        let s = RecordingState.resolve(connected: true, heartRate: 62, lastSyncedAt: 1000, now: 2000)
        XCTAssertEqual(s, .recording)
    }

    func testRecordingState_connectedButNoLiveHR_isNotRecording() {
        // Connected but no live HR yet (handshaking / off-wrist / no PPG) is honestly NOT recording.
        // With a known last-sync it falls back to "Last synced Xm ago" rather than a false "Recording".
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: true, heartRate: nil, lastSyncedAt: now - 120, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 2))
    }

    func testRecordingState_connectedNoLiveHR_noSync_isConnectedNoData() {
        let s = RecordingState.resolve(connected: true, heartRate: nil, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .connectedNoData)
    }

    func testRecordingState_sustainedEmptyKeepsConnectionHonest() {
        let s = RecordingState.resolve(connected: true, heartRate: nil, lastSyncedAt: 9_900,
                                       sustainedEmptyOffload: true, now: 10_000)
        XCTAssertEqual(s, .connectedNoData)
    }

    func testRecordingState_notConnectedWithStaleHR_isNotRecording() {
        // A stale HR sample without a live connection can never be "Recording".
        let s = RecordingState.resolve(connected: false, heartRate: 62, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .notRecording)
    }

    func testRecordingState_notConnectedButRecentlySynced_isLastSynced() {
        // 5 minutes (300s) ago → "Last synced 5m ago".
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 300, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 5))
    }

    func testRecordingState_subMinuteSync_roundsUpToOneMinute() {
        // 30s ago should read "1m ago", never "0m ago" (ceil).
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 30, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 1))
    }

    func testRecordingState_exactMinuteSync_isNotRoundedUp() {
        // Exactly 120s ago is exactly 2m — ceil must not bump an exact boundary to 3m.
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now - 120, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 2))
    }

    func testRecordingState_clockSkewFutureSync_clampsToZeroMinutes() {
        // A strap-clock-skew future timestamp must never read negative.
        let now: TimeInterval = 10_000
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: now + 600, now: now)
        XCTAssertEqual(s, .lastSynced(minutesAgo: 0))
    }

    func testRecordingState_neverSynced_isNotRecording() {
        let s = RecordingState.resolve(connected: false, heartRate: nil, lastSyncedAt: nil, now: 10_000)
        XCTAssertEqual(s, .notRecording)
    }

    // MARK: - Component 3 — verbatim copy

    func testRecordingState_recording_copy() {
        XCTAssertEqual(RecordingState.recording.accessibilityText,
                       "Recording. Noop Band is connected and saving data.")
    }

    func testRecordingState_lastSynced_copy() {
        XCTAssertEqual(RecordingState.lastSynced(minutesAgo: 7).accessibilityText,
                       "Last synced 7 minutes ago. Reconnect to pull the latest.")
    }

    func testRecordingState_notRecording_copy() {
        XCTAssertEqual(RecordingState.notRecording.accessibilityText,
                       "Not recording. Noop Band is not connected. Tap to connect.")
    }

    func testRecordingState_copy_hasNoEmDash() {
        let states: [RecordingState] = [.recording, .lastSynced(minutesAgo: 5), .notRecording,
                                        .connectedNoData]
        for s in states {
            XCTAssertFalse(s.accessibilityText.contains("\u{2014}"),
                           "RecordingState \(s) must not contain an em-dash")
        }
    }

    // MARK: - Component 4 — provenance label (the real per-day merge winner)

    func testProvenance_computedStrapSibling_isOnDevice() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "my-whoop-noop", deviceId: "my-whoop"),
                       "On-device")
    }

    func testProvenance_importedStrapSource_isImported() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "my-whoop", deviceId: "my-whoop"),
                       "Imported")
    }

    func testProvenance_appleHealthSource_isAppleHealth() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "apple-health", deviceId: "my-whoop"),
                       "Apple Health")
    }

    func testProvenance_nonDefaultDeviceId_stillMapsComputedAndImported() {
        // A strap with a non-"my-whoop" device id still resolves its own sibling + imported source.
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "whoop5-AB12-noop", deviceId: "whoop5-AB12"),
                       "On-device")
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "whoop5-AB12", deviceId: "whoop5-AB12"),
                       "Imported")
    }

    func testProvenance_crossStrapComputedSibling_stillOnDevice() {
        // A "-noop" sibling banked under a DIFFERENT strap id (the user re-paired straps) is still a
        // score NOOP computed on-device. The resolver matches the "-noop" suffix, not the exact
        // "\(deviceId)-noop" — otherwise these rows would fall through to the raw id verbatim.
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "whoop5-C0FF-noop", deviceId: "my-whoop"),
                       "On-device")
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "my-whoop-noop", deviceId: "strap-42"),
                       "On-device")
    }

    func testProvenance_otherKnownSource_keepsItsDisplayName() {
        // Mi Band is a real merge winner — keep its own name, never a blanket on-device claim.
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "xiaomi-band", deviceId: "my-whoop"),
                       "Mi Band")
    }

    // MARK: - Apple Watch provenance (M1) — Today-only "Apple Watch" relabel of the apple-health source

    func testIsWatchSource_appleHealthSource_isTrue() {
        XCTAssertTrue(TodayView.isWatchSource("apple-health", appleHealthSource: "apple-health"))
    }

    func testIsWatchSource_strapOrNil_isFalse() {
        // A strap-sourced score (or no resolved source at all) is never the watch.
        XCTAssertFalse(TodayView.isWatchSource("my-whoop", appleHealthSource: "apple-health"))
        XCTAssertFalse(TodayView.isWatchSource(nil, appleHealthSource: "apple-health"))
    }

    func testTodayChipLabel_appleHealthSource_readsAppleWatch() {
        // The audience knows the device, not the framework — a watch-sourced score reads "Apple Watch".
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "apple-health", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Apple Watch")
    }

    func testTodayChipLabel_usesProductFacingBandNameAndPreservesOtherSources() {
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "my-whoop", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Compatible band")
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "my-whoop-noop", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "On-device")
        XCTAssertEqual(
            TodayView.todayProvenanceChipLabel(rawSource: "xiaomi-band", deviceId: "my-whoop",
                                               appleHealthSource: "apple-health"),
            "Mi Band")
    }

    func testLiquidHeroSourceLabel_deduplicatesOneWinner() {
        XCTAssertEqual(
            LiquidTodayView.heroSourceLabel(
                rawSources: ["my-whoop-noop", "my-whoop-noop", "my-whoop-noop"],
                deviceId: "my-whoop"),
            "On-device")
    }

    func testLiquidHeroSourceLabel_capsMixedWinnersAtTwoInScoreOrder() {
        XCTAssertEqual(
            LiquidTodayView.heroSourceLabel(
                rawSources: ["my-whoop", "my-whoop-noop", "apple-health"],
                deviceId: "my-whoop"),
            "Compatible band + On-device")
    }

    func testLiquidHeroSourceLabel_hidesWhenNoScoreHasAResolvedSource() {
        XCTAssertNil(LiquidTodayView.heroSourceLabel(rawSources: [], deviceId: "my-whoop"))
    }

    func testMixedCompatibleBandSourceStillQualifiesForSyncFeedback() {
        XCTAssertTrue(LiquidTodayView.sourceLabelIncludesCompatibleBand("Compatible band"))
        XCTAssertTrue(LiquidTodayView.sourceLabelIncludesCompatibleBand("Compatible band + Apple Watch"))
        XCTAssertFalse(LiquidTodayView.sourceLabelIncludesCompatibleBand("Apple Watch"))
    }

    func testBandSyncConfirmationRequiresAdvancedCompletionEvidence() {
        XCTAssertFalse(LiquidTodayView.bandSyncCompletionAdvanced(from: nil, to: nil))
        XCTAssertTrue(LiquidTodayView.bandSyncCompletionAdvanced(from: nil, to: 1_000))
        XCTAssertFalse(LiquidTodayView.bandSyncCompletionAdvanced(from: 1_000, to: 1_000))
        XCTAssertFalse(LiquidTodayView.bandSyncCompletionAdvanced(from: 1_000, to: nil))
        XCTAssertTrue(LiquidTodayView.bandSyncCompletionAdvanced(from: 1_000, to: 1_001))
    }
}
