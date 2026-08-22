import XCTest
@testable import StrandAnalytics

final class SafetyShareMessageTests: XCTestCase {
    private let captured = 1_787_395_200 // 2026-08-22T10:40:00Z

    func testNeedHelpMessageWithValidLocation() {
        let message = SafetyShareMessage.build(
            intent: .needHelpNow,
            displayName: "  Alex\nRiver  ",
            note: "Blue jacket.\nNear the south entrance.",
            location: SafetyLocation(
                latitude: 40.7128,
                longitude: -74.0060,
                horizontalAccuracyMeters: 8.6,
                capturedAtUnix: captured
            ),
            preparedAtUnix: captured + 60
        )

        XCTAssertTrue(message.hasPrefix("Alex River: I need help now. Please call me."), message)
        XCTAssertTrue(message.contains(
            "https://www.google.com/maps/search/?api=1&query=40.712800,-74.006000"), message)
        XCTAssertTrue(message.contains("accuracy about 9 m"), message)
        XCTAssertTrue(message.contains("Note: Blue jacket. Near the south entrance."), message)
        XCTAssertTrue(message.hasSuffix(
            "NOOP did not send this automatically and does not monitor or contact emergency services."), message)
    }

    func testPlatformSuppliedCopyIsUsedWithoutWeakeningMessageSafety() {
        let copy = SafetyShareCopy(
            needHelpNowOpening: "AYUDA AHORA.",
            feelUnsafeOpening: "NO ESTOY SEGURA.",
            missedCheckInOpening: "FALTÉ A LA CITA.",
            immediateDangerInstruction: "PELIGRO INMEDIATO.",
            locationLabel: "UBICACIÓN",
            locationCapturedFormat: "CAPTURADA %1$@.",
            locationCapturedAccuracyFormat: "CAPTURADA %1$@, PRECISIÓN %2$lld M.",
            noteLabel: "NOTA",
            preparedAtFormat: "PREPARADA %1$@.",
            deliveryBoundary: "BORRADOR MANUAL; SIN ENVÍO AUTOMÁTICO."
        )
        let message = SafetyShareMessage.build(
            intent: .needHelpNow,
            displayName: "  Ana\nSol  ",
            note: "puerta\u{0000}\nazul",
            location: SafetyLocation(
                latitude: 40.7128,
                longitude: -74.0060,
                horizontalAccuracyMeters: 8.6,
                capturedAtUnix: captured
            ),
            preparedAtUnix: captured + 60,
            copy: copy
        )

        XCTAssertTrue(message.hasPrefix("Ana Sol: AYUDA AHORA.\nPELIGRO INMEDIATO."), message)
        XCTAssertTrue(message.contains("UBICACIÓN: https://www.google.com/maps/"), message)
        XCTAssertTrue(message.contains(
            "CAPTURADA \(SafetyShareMessage.utcTimestamp(captured)), PRECISIÓN 9 M."
        ), message)
        XCTAssertTrue(message.contains("NOTA: puerta azul"), message)
        XCTAssertTrue(message.contains(
            "PREPARADA \(SafetyShareMessage.utcTimestamp(captured + 60))."
        ), message)
        XCTAssertTrue(message.hasSuffix("BORRADOR MANUAL; SIN ENVÍO AUTOMÁTICO."), message)
        XCTAssertFalse(message.contains("I need help now"), message)
        XCTAssertFalse(message.contains("\u{0000}"), message)
    }

    func testInvalidLocationIsOmitted() {
        let message = SafetyShareMessage.build(
            intent: .feelUnsafe,
            location: SafetyLocation(latitude: 95, longitude: 0, capturedAtUnix: captured),
            preparedAtUnix: captured
        )
        XCTAssertFalse(message.contains("Location:"), message)
        XCTAssertFalse(message.contains("maps"), message)
    }

    func testNonFiniteLocationIsOmitted() {
        let message = SafetyShareMessage.build(
            intent: .missedCheckIn,
            location: SafetyLocation(latitude: .nan, longitude: 0, capturedAtUnix: captured),
            preparedAtUnix: captured
        )
        XCTAssertFalse(message.contains("Location:"), message)
    }

    func testStaleAndFarFutureLocationsAreOmitted() {
        let stale = SafetyLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAtUnix: captured - SafetyLocation.maximumAgeSeconds - 1
        )
        let future = SafetyLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAtUnix: captured + SafetyLocation.maximumFutureClockSkewSeconds + 1
        )

        XCTAssertFalse(stale.isUsable(atUnix: captured))
        XCTAssertFalse(future.isUsable(atUnix: captured))
        XCTAssertFalse(SafetyShareMessage.build(
            intent: .feelUnsafe,
            location: stale,
            preparedAtUnix: captured
        ).contains("Location:"))
        XCTAssertFalse(SafetyShareMessage.build(
            intent: .feelUnsafe,
            location: future,
            preparedAtUnix: captured
        ).contains("Location:"))
    }

    func testLocationFreshnessBoundsAreInclusive() {
        XCTAssertTrue(SafetyLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAtUnix: captured - SafetyLocation.maximumAgeSeconds
        ).isUsable(atUnix: captured))
        XCTAssertTrue(SafetyLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAtUnix: captured + SafetyLocation.maximumFutureClockSkewSeconds
        ).isUsable(atUnix: captured))
        XCTAssertFalse(SafetyLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAtUnix: captured
        ).isUsable(atUnix: 0))
    }

    func testBlankNameAndNoteAreOmitted() {
        let message = SafetyShareMessage.build(
            intent: .missedCheckIn,
            displayName: " \n\t ",
            note: "  ",
            preparedAtUnix: captured
        )
        XCTAssertTrue(message.hasPrefix("I missed a planned check-in."), message)
        XCTAssertFalse(message.contains("Note:"), message)
    }

    func testUserTextIsCappedAndControlFree() {
        let longName = String(repeating: "a", count: SafetyShareMessage.maxNameCharacters + 20)
        let longNote = String(repeating: "b", count: SafetyShareMessage.maxNoteCharacters + 20)
        let message = SafetyShareMessage.build(
            intent: .needHelpNow,
            displayName: longName,
            note: "one\u{0000}\n" + longNote,
            preparedAtUnix: captured
        )
        XCTAssertFalse(message.contains("\u{0000}"), message)
        XCTAssertTrue(message.contains(String(repeating: "a", count: SafetyShareMessage.maxNameCharacters) + ":"))
        XCTAssertFalse(message.contains(String(repeating: "b", count: SafetyShareMessage.maxNoteCharacters + 1)))
    }
}

final class SafetyCheckInPolicyTests: XCTestCase {
    func testDurationClampsToSafeRange() {
        XCTAssertEqual(SafetyCheckInPolicy.clampedDurationSeconds(10), 5 * 60)
        XCTAssertEqual(SafetyCheckInPolicy.clampedDurationSeconds(30 * 60), 30 * 60)
        XCTAssertEqual(SafetyCheckInPolicy.clampedDurationSeconds(7 * 24 * 60 * 60), 24 * 60 * 60)
    }

    func testDueTimestamp() {
        XCTAssertEqual(
            SafetyCheckInPolicy.dueAtUnix(startedAtUnix: 1_000, requestedDurationSeconds: 30 * 60),
            2_800
        )
        XCTAssertNil(SafetyCheckInPolicy.dueAtUnix(startedAtUnix: 0, requestedDurationSeconds: 30 * 60))
        XCTAssertNil(SafetyCheckInPolicy.dueAtUnix(
            startedAtUnix: Int.max - 10, requestedDurationSeconds: 30 * 60))
    }

    func testStateTransitions() {
        XCTAssertEqual(SafetyCheckInPolicy.state(dueAtUnix: nil, nowUnix: 1_000), .inactive)
        XCTAssertEqual(
            SafetyCheckInPolicy.state(dueAtUnix: 3_000, nowUnix: 1_000),
            .active(remainingSeconds: 2_000)
        )
        XCTAssertEqual(
            SafetyCheckInPolicy.state(dueAtUnix: 1_500, nowUnix: 1_000),
            .dueSoon(remainingSeconds: 500)
        )
        XCTAssertEqual(
            SafetyCheckInPolicy.state(dueAtUnix: 900, nowUnix: 1_000),
            .overdue(elapsedSeconds: 100)
        )
        XCTAssertEqual(
            SafetyCheckInPolicy.state(dueAtUnix: 1_000, nowUnix: 1_000),
            .overdue(elapsedSeconds: 0)
        )
    }

    func testLabelsStateNoAutomaticSend() {
        XCTAssertEqual(
            SafetyCheckInPolicy.statusLabel(.active(remainingSeconds: 5_400)),
            "Check-in due in 1h 30m."
        )
        XCTAssertEqual(
            SafetyCheckInPolicy.statusLabel(.dueSoon(remainingSeconds: 300)),
            "Check-in due soon: 5m remaining."
        )
        let overdue = SafetyCheckInPolicy.statusLabel(.overdue(elapsedSeconds: 90))
        XCTAssertEqual(overdue, "Check-in overdue by 1m. No message was sent automatically.")
        XCTAssertTrue(overdue.contains("No message was sent automatically."))
    }

    func testNotificationContainsNoHealthValueOrEmergencyPromise() {
        XCTAssertEqual(SafetyCheckInPolicy.notificationTitle, "Personal check-in")
        XCTAssertEqual(
            SafetyCheckInPolicy.notificationBody,
            "Your timer ended. Check in with someone you trust if you still need to."
        )
        let text = SafetyCheckInPolicy.notificationTitle + " " + SafetyCheckInPolicy.notificationBody
        XCTAssertFalse(text.lowercased().contains("heart"))
        XCTAssertFalse(text.lowercased().contains("recovery"))
        XCTAssertFalse(text.lowercased().contains("emergency services notified"))
    }
}
