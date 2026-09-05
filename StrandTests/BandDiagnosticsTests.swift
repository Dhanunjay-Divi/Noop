import XCTest
@testable import Strand

final class BandDiagnosticsTests: XCTestCase {
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
