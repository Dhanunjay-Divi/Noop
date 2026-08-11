import XCTest
@testable import WhoopProtocol

final class WeightScaleTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    func testDecodesSIWeightOnly() throws {
        // 72.500 kg / 0.005 = 14500 = 0x38A4.
        let m = try WeightScaleMeasurementDecoder.decode([0x00, 0xA4, 0x38], calendar: utc)
        XCTAssertEqual(m.weightKg, 72.5, accuracy: 0.000_001)
        XCTAssertEqual(m.unit, .si)
        XCTAssertNil(m.timestamp)
        XCTAssertNil(m.userID)
        XCTAssertNil(m.bmi)
        XCTAssertNil(m.heightCm)
    }

    func testDecodesImperialTimestampUserBMIAndHeight() throws {
        // Flags: imperial + timestamp + user + BMI/height. 180.00 lb, 2026-08-11 14:34:56,
        // user 7, BMI 24.6, height 70.0 in.
        let bytes: [UInt8] = [
            0x0F, 0x50, 0x46,
            0xEA, 0x07, 0x08, 0x0B, 0x0E, 0x22, 0x38,
            0x07,
            0xF6, 0x00,
            0xBC, 0x02,
        ]
        let m = try WeightScaleMeasurementDecoder.decode(bytes, calendar: utc)
        XCTAssertEqual(m.unit, .imperial)
        XCTAssertEqual(m.weightKg, 180 * 0.453_592_37, accuracy: 0.000_001)
        XCTAssertEqual(m.userID, 7)
        XCTAssertEqual(try XCTUnwrap(m.bmi), 24.6, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(m.heightCm), 177.8, accuracy: 0.000_001)
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(m.timestamp))
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 11)
        XCTAssertEqual(c.hour, 14)
        XCTAssertEqual(c.minute, 34)
        XCTAssertEqual(c.second, 56)
    }

    func testPreservesUnknownUserID() throws {
        let m = try WeightScaleMeasurementDecoder.decode([0x04, 0x20, 0x4E, 0xFF], calendar: utc)
        XCTAssertEqual(m.userID, 0xFF)
        XCTAssertTrue(m.hasUnknownUser)
    }

    func testRejectsUnsuccessfulTruncatedReservedAndInvalidTimestamp() {
        XCTAssertThrowsError(try WeightScaleMeasurementDecoder.decode([0, 0xFF, 0xFF], calendar: utc)) {
            XCTAssertEqual($0 as? WeightScaleDecodeError, .measurementUnsuccessful)
        }
        XCTAssertThrowsError(try WeightScaleMeasurementDecoder.decode([0x08, 1, 0], calendar: utc)) {
            XCTAssertEqual($0 as? WeightScaleDecodeError, .truncatedField)
        }
        XCTAssertThrowsError(try WeightScaleMeasurementDecoder.decode([0x10, 1, 0], calendar: utc)) {
            XCTAssertEqual($0 as? WeightScaleDecodeError, .reservedFlags(0x10))
        }
        let february30: [UInt8] = [0x02, 1, 0, 0xEA, 0x07, 2, 30, 12, 0, 0]
        XCTAssertThrowsError(try WeightScaleMeasurementDecoder.decode(february30, calendar: utc)) {
            XCTAssertEqual($0 as? WeightScaleDecodeError, .invalidTimestamp)
        }
    }

    func testFeatureBitmapDecode() throws {
        // timestamp, multi-user, BMI, weight resolution 6, height resolution 4.
        let raw = UInt32(0b111) | (UInt32(6) << 3) | (UInt32(4) << 7)
        let f = try XCTUnwrap(WeightScaleFeatures.decode([
            UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), 0, 0,
        ]))
        XCTAssertTrue(f.supportsTimestamp)
        XCTAssertTrue(f.supportsMultipleUsers)
        XCTAssertTrue(f.supportsBMI)
        XCTAssertEqual(f.weightResolutionCode, 6)
        XCTAssertEqual(f.heightResolutionCode, 4)
    }

    func testLifecycleReconnectsOnlyRememberedScaleAndStopsExplicitly() {
        var life = WeightScaleLifecycle()
        XCTAssertEqual(life.handle(.userRequestedScan), .scanning)
        XCTAssertEqual(life.handle(.candidateChosen), .connecting)
        XCTAssertEqual(life.handle(.transportConnected), .discovering)
        XCTAssertEqual(life.handle(.measurementCharacteristicValidated), .listening)
        XCTAssertEqual(life.handle(.transportDisconnected(hasRememberedScale: true)), .waitingToReconnect)
        XCTAssertEqual(life.handle(.rememberedScaleResume), .connecting)
        XCTAssertEqual(life.handle(.userStopped), .idle)
        XCTAssertEqual(life.handle(.transportDisconnected(hasRememberedScale: false)), .idle)
    }

    func testProfileUserPolicyRequiresExplicitMatchForMultiUserScale() {
        XCTAssertTrue(WeightScaleProfileUserPolicy.allows(measurementUserID: nil, selectedUserID: nil))
        XCTAssertFalse(WeightScaleProfileUserPolicy.allows(measurementUserID: 0xFF, selectedUserID: 0xFF))
        XCTAssertFalse(WeightScaleProfileUserPolicy.allows(measurementUserID: 3, selectedUserID: nil))
        XCTAssertFalse(WeightScaleProfileUserPolicy.allows(measurementUserID: 3, selectedUserID: 2))
        XCTAssertTrue(WeightScaleProfileUserPolicy.allows(measurementUserID: 3, selectedUserID: 3))
    }
}
