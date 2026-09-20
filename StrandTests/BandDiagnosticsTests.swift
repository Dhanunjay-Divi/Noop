import XCTest
import StrandAnalytics
@testable import Strand

final class BandDiagnosticsTests: XCTestCase {
    func testLifecycleRecorderUsesOnlyFixedPrivacySafeCategories() {
        var captured: [(String, [String: String])] = []
        let recorder: BandDiagnostics.Recorder = { captured.append(($0, $1)) }

        BandDiagnostics.recordScan(.noResult, family: .whoop4, reason: "timeout", recorder: recorder)
        BandDiagnostics.recordReadiness(
            .notifications,
            state: .ready,
            family: .whoop5,
            channel: "live_hr",
            recorder: recorder
        )
        BandDiagnostics.recordRetry(
            .paused,
            family: .whoop5,
            reason: "bond_loop",
            recorder: recorder
        )

        XCTAssertEqual(captured[0].0, "band.scan")
        XCTAssertEqual(captured[0].1, ["state": "no_result", "family": "legacy", "reason": "timeout"])
        XCTAssertEqual(captured[1].0, "band.readiness")
        XCTAssertEqual(
            captured[1].1,
            ["stage": "notifications", "state": "ready", "family": "modern", "channel": "live_hr"]
        )
        XCTAssertEqual(captured[2].0, "band.retry")
        XCTAssertEqual(captured[2].1, ["state": "paused", "family": "modern", "reason": "bond_loop"])
    }

    func testLifecycleRecorderMapsUnknownReasonAndChannelToOther() {
        var captured: [(String, [String: String])] = []
        let recorder: BandDiagnostics.Recorder = { captured.append(($0, $1)) }

        BandDiagnostics.recordScan(
            .unavailable,
            family: .whoop4,
            reason: "private dynamic failure",
            recorder: recorder
        )
        BandDiagnostics.recordReadiness(
            .notifications,
            state: .failed,
            family: .whoop5,
            channel: "fd4b-private",
            reason: "localized platform detail",
            recorder: recorder
        )
        BandDiagnostics.recordRetry(
            .cancelled,
            family: .whoop5,
            reason: "arbitrary retry detail",
            recorder: recorder
        )

        XCTAssertEqual(captured[0].1["reason"], "other")
        XCTAssertEqual(captured[1].1["channel"], "other")
        XCTAssertEqual(captured[1].1["reason"], "other")
        XCTAssertEqual(captured[2].1["reason"], "other")
    }

    @MainActor
    func testTranscriptRedactsBLEIdentifiersSignalAndHealthValues() {
        let live = LiveState()
        live.append(
            log: "Discovered WHOOP 4C1594026 01:23:45:67:89:AB "
                + "A1B2C3D4-E5F6-7890-ABCD-EF0123456789 rssi=-71 bpm=137 hrv=42 soc=88.5%"
        )

        let line = live.log.last ?? ""
        XCTAssertFalse(line.contains("4C1594026"))
        XCTAssertFalse(line.contains("01:23:45:67:89:AB"))
        XCTAssertFalse(line.contains("A1B2C3D4-E5F6-7890-ABCD-EF0123456789"))
        XCTAssertFalse(line.contains("-71"))
        XCTAssertFalse(line.contains("137"))
        XCTAssertFalse(line.contains("42"))
        XCTAssertFalse(line.contains("88.5"))
        XCTAssertTrue(line.contains("<address>"))
        XCTAssertTrue(line.contains("<uuid>"))
        XCTAssertTrue(line.contains("bpm=<health>"))

        live.append(log: "advertising name=Bedroom Band; error: private CoreBluetooth detail")
        let detail = live.log.last ?? ""
        XCTAssertFalse(detail.contains("Bedroom Band"))
        XCTAssertFalse(detail.contains("private CoreBluetooth detail"))
        XCTAssertTrue(detail.contains("name=<redacted>"))
        XCTAssertTrue(detail.contains("error=<redacted>"))

        live.append(
            log: "Discovered Bedroom Band "
                + "(A1B2C3D4-E5F6-7890-ABCD-EF0123456789) rssi=-57 "
                + "candidate raw (12 B): 00112233445566778899aabb"
        )
        let raw = live.log.last ?? ""
        XCTAssertFalse(raw.contains("Bedroom Band"))
        XCTAssertFalse(raw.contains("00112233445566778899aabb"))
        XCTAssertTrue(raw.lowercased().contains("discovered <device>"))
        XCTAssertTrue(raw.contains("<raw-bytes>"))
    }

    func testPersistedTranscriptIsRedactedAgainBeforeExport() {
        let key = "strapLog.tail"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(
            [
                "Discovered Bedroom Band "
                    + "(A1B2C3D4-E5F6-7890-ABCD-EF0123456789) rssi=-57 "
                    + "candidate raw (12 B): 00112233445566778899aabb",
            ],
            forKey: key
        )

        let line = LiveState.persistedLogTail().first ?? ""
        XCTAssertFalse(line.contains("Bedroom Band"))
        XCTAssertFalse(line.contains("A1B2C3D4-E5F6-7890-ABCD-EF0123456789"))
        XCTAssertFalse(line.contains("00112233445566778899aabb"))
        XCTAssertTrue(line.lowercased().contains("discovered <device>"))
        XCTAssertTrue(line.contains("<uuid>"))
        XCTAssertTrue(line.contains("rssi=<redacted>"))
        XCTAssertTrue(line.contains("<raw-bytes>"))
    }

    func testTransportReasonsStayStableAndCategorical() {
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: false,
                timedOut: false,
                pairingReset: true,
                hasTransportError: true,
                wasConnected: false
            ),
            "pairing_reset"
        )
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: false,
                timedOut: true,
                pairingReset: false,
                hasTransportError: true,
                wasConnected: true
            ),
            "timeout"
        )
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: true,
                timedOut: false,
                pairingReset: false,
                hasTransportError: false,
                wasConnected: true
            ),
            "intentional"
        )
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: false,
                timedOut: false,
                pairingReset: false,
                hasTransportError: true,
                wasConnected: true
            ),
            "transport_error"
        )
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: false,
                timedOut: false,
                pairingReset: false,
                hasTransportError: false,
                wasConnected: true
            ),
            "remote"
        )
        XCTAssertEqual(
            BandDiagnostics.transportReason(
                intentional: false,
                timedOut: false,
                pairingReset: false,
                hasTransportError: false,
                wasConnected: false
            ),
            "unavailable"
        )
    }

    func testRadioReasonsStayStableAndCategorical() {
        XCTAssertEqual(BandDiagnostics.radioReason(.unauthorized), "permission")
        XCTAssertEqual(BandDiagnostics.radioReason(.poweredOff), "powered_off")
        XCTAssertEqual(BandDiagnostics.radioReason(.unsupported), "unsupported")
        XCTAssertEqual(BandDiagnostics.radioReason(.resetting), "resetting")
        XCTAssertEqual(BandDiagnostics.radioReason(.unknown), "unknown")
        XCTAssertEqual(BandDiagnostics.radioReason(.poweredOn), "available")
    }

    @MainActor
    func testSafeTaggedTestCentreEvidenceSurvivesAndRemainsParseable() {
        let live = LiveState()
        live.append(log: "bank soc=80.0 t=1789831200s", domain: .battery)
        live.append(
            log: "connect up gen=7 latencyMs=420 uptimeStart=1789831200",
            domain: .connection
        )

        let battery = live.taggedTail(domain: .battery)
        let connection = live.taggedTail(domain: .connection)
        XCTAssertEqual(battery, ["[battery] bank soc=80.0 t=1789831200s"])
        XCTAssertEqual(
            connection,
            ["[connection] connect up gen=7 latencyMs=420 uptimeStart=1789831200"]
        )
        XCTAssertEqual(
            CaptureAccumulator.capturedDays(
                domain: .battery,
                reportText: battery.joined(separator: "\n"),
                tzOffsetSeconds: 0
            ),
            1
        )
        XCTAssertEqual(
            ConnectionReadout.uptimeLabel(
                taggedTail: connection,
                nowUnix: 1789831200 + 192
            ),
            "3m 12s"
        )

        let untagged = LiveState.redactPii("bank soc=80.0 t=1789831200s")
        XCTAssertFalse(untagged.contains("80.0"))
        XCTAssertFalse(untagged.contains("1789831200"))
        let taggedLookalike = LiveState.redactPii(
            "[battery] bank soc=80.0 t=1789831200s owner=private"
        )
        XCTAssertFalse(taggedLookalike.contains("80.0"))
        XCTAssertFalse(taggedLookalike.contains("1789831200"))
    }

    func testCandidateDiagnosticsDedupePerFamilyAndResetPerSession() {
        var deduper = BandDiagnostics.CandidateSessionDeduper()
        XCTAssertTrue(deduper.shouldRecord(.whoop4))
        XCTAssertFalse(deduper.shouldRecord(.whoop4))
        XCTAssertTrue(deduper.shouldRecord(.whoop5))
        XCTAssertFalse(deduper.shouldRecord(.whoop5))

        deduper.reset()
        XCTAssertTrue(deduper.shouldRecord(.whoop4))
        XCTAssertTrue(deduper.shouldRecord(.whoop5))
    }

    func testServiceAndNotificationReadinessReasonsStayCategorical() {
        XCTAssertEqual(
            BandDiagnostics.serviceFailureReason(supportedCustomServiceCount: 0),
            "unsupported_service"
        )
        XCTAssertEqual(
            BandDiagnostics.serviceFailureReason(supportedCustomServiceCount: 2),
            "ambiguous_service"
        )
        XCTAssertEqual(
            BandDiagnostics.serviceFailureReason(
                supportedCustomServiceCount: 1,
                hasRequiredCommandCharacteristic: false
            ),
            "command_missing"
        )
        XCTAssertNil(
            BandDiagnostics.serviceFailureReason(
                supportedCustomServiceCount: 1,
                hasRequiredCommandCharacteristic: true
            )
        )
        XCTAssertEqual(
            BandDiagnostics.notificationObservation(
                hasError: false,
                isNotifying: false,
                rearmPending: true
            ),
            .pending
        )
        XCTAssertEqual(
            BandDiagnostics.notificationObservation(
                hasError: false,
                isNotifying: true,
                rearmPending: true
            ),
            .ready
        )
        XCTAssertEqual(
            BandDiagnostics.notificationObservation(
                hasError: true,
                isNotifying: false,
                rearmPending: true
            ),
            .failed
        )
        XCTAssertEqual(
            BandDiagnostics.notificationObservation(
                hasError: false,
                isNotifying: false,
                rearmPending: false
            ),
            .failed
        )
        XCTAssertEqual(
            BandDiagnostics.notificationRearmAction(
                phase: .awaitingDisable,
                hasError: false,
                isNotifying: false
            ),
            .enable
        )
        XCTAssertEqual(
            BandDiagnostics.notificationRearmAction(
                phase: .awaitingEnable,
                hasError: false,
                isNotifying: true
            ),
            .ready
        )
        XCTAssertEqual(
            BandDiagnostics.notificationRearmAction(
                phase: .awaitingDisable,
                hasError: false,
                isNotifying: true
            ),
            .failed
        )
        XCTAssertEqual(
            BandDiagnostics.notificationRearmAction(
                phase: .awaitingEnable,
                hasError: true,
                isNotifying: false
            ),
            .failed
        )
        XCTAssertTrue(
            BandDiagnostics.notificationRearmTimeoutShouldReconnect(
                expectedGeneration: 7,
                currentGeneration: 7,
                isPending: true,
                isConnected: true
            )
        )
        XCTAssertFalse(
            BandDiagnostics.notificationRearmTimeoutShouldReconnect(
                expectedGeneration: 7,
                currentGeneration: 8,
                isPending: true,
                isConnected: true
            )
        )
        XCTAssertFalse(
            BandDiagnostics.notificationRearmTimeoutShouldReconnect(
                expectedGeneration: 7,
                currentGeneration: 7,
                isPending: false,
                isConnected: true
            )
        )
        XCTAssertFalse(
            BandDiagnostics.notificationRearmTimeoutShouldReconnect(
                expectedGeneration: 7,
                currentGeneration: 7,
                isPending: true,
                isConnected: false
            )
        )
    }

    func testReconnectAndHistoryOutcomesUseFixedVocabulary() {
        XCTAssertEqual(
            BandDiagnostics.reconnectPlan(
                intentional: false,
                paused: false,
                pairingReset: false
            ),
            "retry"
        )
        XCTAssertEqual(
            BandDiagnostics.reconnectPlan(
                intentional: false,
                paused: true,
                pairingReset: false
            ),
            "user_action"
        )
        XCTAssertEqual(BandDiagnostics.historyOutcome(reason: "HISTORY_COMPLETE"), "completed")
        XCTAssertEqual(BandDiagnostics.historyOutcome(reason: "timeout"), "idle_timeout")
        XCTAssertEqual(BandDiagnostics.historyOutcome(reason: "durableProgressTimeout"), "progress_stalled")
        XCTAssertEqual(BandDiagnostics.historyOutcome(reason: "disconnect"), "interrupted")
        XCTAssertEqual(BandDiagnostics.historyOutcome(reason: "dynamic error text"), "other")
    }
}
