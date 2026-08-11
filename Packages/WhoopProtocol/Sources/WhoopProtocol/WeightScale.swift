import Foundation

/// Measurement units selected by bit 0 of the Bluetooth SIG Weight Measurement flags field.
public enum WeightScaleUnit: String, Codable, Sendable {
    case si
    case imperial
}

/// A decoded Bluetooth SIG Weight Measurement (characteristic 0x2A9D).
///
/// `weightKg` and `heightCm` are normalized for NOOP storage. `unit` preserves the unit the scale
/// actually transmitted, `userID` preserves 0xFF (the standard's "unknown user" value), and
/// `timestamp` is nil only when the packet did not carry the optional seven-byte Date Time field.
public struct WeightScaleMeasurement: Equatable, Sendable {
    public let weightKg: Double
    public let timestamp: Date?
    public let userID: UInt8?
    public let bmi: Double?
    public let heightCm: Double?
    public let unit: WeightScaleUnit

    public init(weightKg: Double,
                timestamp: Date?,
                userID: UInt8?,
                bmi: Double?,
                heightCm: Double?,
                unit: WeightScaleUnit) {
        self.weightKg = weightKg
        self.timestamp = timestamp
        self.userID = userID
        self.bmi = bmi
        self.heightCm = heightCm
        self.unit = unit
    }

    /// A present 0xFF user id explicitly means the scale could not identify the user.
    public var hasUnknownUser: Bool { userID == 0xFF }
}

public enum WeightScaleDecodeError: Error, Equatable, Sendable {
    case tooShort
    case reservedFlags(UInt8)
    case measurementUnsuccessful
    case truncatedField
    case invalidTimestamp
    case trailingBytes(Int)
}

/// Pure decoder for Bluetooth SIG Weight Measurement 0x2A9D.
///
/// Wire order and resolutions follow the Bluetooth GATT definition:
/// flags (u8), weight (u16 LE; 0.005 kg or 0.01 lb), optional Date Time (7 bytes), optional user id
/// (u8), then optional BMI (u16 LE, 0.1 kg/m²) and height (u16 LE; 0.001 m or 0.1 in).
public enum WeightScaleMeasurementDecoder {
    public static func decode(_ bytes: [UInt8], calendar: Calendar = .current) throws -> WeightScaleMeasurement {
        guard bytes.count >= 3 else { throw WeightScaleDecodeError.tooShort }
        var cursor = 0
        let flags = bytes[cursor]
        cursor += 1

        // Bits 4...7 are reserved by WSS 1.0.1. Refuse a packet with them set rather than guessing a
        // future layout and shifting every optional field onto the wrong bytes.
        let reserved = flags & 0xF0
        guard reserved == 0 else { throw WeightScaleDecodeError.reservedFlags(reserved) }

        let imperial = (flags & 0x01) != 0
        let hasTimestamp = (flags & 0x02) != 0
        let hasUserID = (flags & 0x04) != 0
        let hasBMIAndHeight = (flags & 0x08) != 0

        let weightRaw = try readUInt16LE(bytes, cursor: &cursor)
        guard weightRaw != 0xFFFF else { throw WeightScaleDecodeError.measurementUnsuccessful }
        let transmittedWeight = Double(weightRaw) * (imperial ? 0.01 : 0.005)
        let weightKg = imperial ? transmittedWeight * 0.453_592_37 : transmittedWeight

        let timestamp: Date?
        if hasTimestamp {
            timestamp = try readDateTime(bytes, cursor: &cursor, calendar: calendar)
        } else {
            timestamp = nil
        }

        let userID: UInt8?
        if hasUserID {
            guard cursor < bytes.count else { throw WeightScaleDecodeError.truncatedField }
            userID = bytes[cursor]
            cursor += 1
        } else {
            userID = nil
        }

        let bmi: Double?
        let heightCm: Double?
        if hasBMIAndHeight {
            bmi = Double(try readUInt16LE(bytes, cursor: &cursor)) * 0.1
            let heightRaw = Double(try readUInt16LE(bytes, cursor: &cursor))
            // SI height is raw millimetres; imperial height is raw tenths of an inch.
            heightCm = imperial ? heightRaw * 0.1 * 2.54 : heightRaw * 0.1
        } else {
            bmi = nil
            heightCm = nil
        }

        guard cursor == bytes.count else {
            throw WeightScaleDecodeError.trailingBytes(bytes.count - cursor)
        }
        return WeightScaleMeasurement(weightKg: weightKg,
                                      timestamp: timestamp,
                                      userID: userID,
                                      bmi: bmi,
                                      heightCm: heightCm,
                                      unit: imperial ? .imperial : .si)
    }

    private static func readUInt16LE(_ bytes: [UInt8], cursor: inout Int) throws -> UInt16 {
        guard cursor + 2 <= bytes.count else { throw WeightScaleDecodeError.truncatedField }
        let value = UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
        cursor += 2
        return value
    }

    private static func readDateTime(_ bytes: [UInt8], cursor: inout Int,
                                     calendar inputCalendar: Calendar) throws -> Date {
        guard cursor + 7 <= bytes.count else { throw WeightScaleDecodeError.truncatedField }
        let year = Int(UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8))
        let month = Int(bytes[cursor + 2])
        let day = Int(bytes[cursor + 3])
        let hour = Int(bytes[cursor + 4])
        let minute = Int(bytes[cursor + 5])
        let second = Int(bytes[cursor + 6])
        cursor += 7

        // Weight Scale Service explicitly forbids unknown (zero) year/month/day. Calendar can normalize
        // out-of-range components, so round-trip every component to reject values such as February 30.
        guard year > 0, month > 0, day > 0,
              hour <= 23, minute <= 59, second <= 59 else {
            throw WeightScaleDecodeError.invalidTimestamp
        }
        let calendar = inputCalendar
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else {
            throw WeightScaleDecodeError.invalidTimestamp
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else {
            throw WeightScaleDecodeError.invalidTimestamp
        }
        return date
    }
}

/// The optional 0x2A9E feature bitmap, retained so the UI can describe what a compliant scale says it
/// supports without inferring capabilities from a brand name.
public struct WeightScaleFeatures: Equatable, Sendable {
    public let supportsTimestamp: Bool
    public let supportsMultipleUsers: Bool
    public let supportsBMI: Bool
    public let weightResolutionCode: UInt8
    public let heightResolutionCode: UInt8

    public static func decode(_ bytes: [UInt8]) -> WeightScaleFeatures? {
        guard bytes.count == 4 else { return nil }
        let raw = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        // Defined bits end at bit 9 in WSS 1.0.1. A future/non-standard layout is not presented as a
        // known feature set.
        guard raw & 0xFFFF_FC00 == 0 else { return nil }
        return WeightScaleFeatures(
            supportsTimestamp: (raw & (1 << 0)) != 0,
            supportsMultipleUsers: (raw & (1 << 1)) != 0,
            supportsBMI: (raw & (1 << 2)) != 0,
            weightResolutionCode: UInt8((raw >> 3) & 0x0F),
            heightResolutionCode: UInt8((raw >> 7) & 0x07)
        )
    }
}

/// Pure connection-phase reducer shared by the CoreBluetooth source and lifecycle tests. It deliberately
/// contains no timers or Bluetooth objects; the transport owns those side effects.
public struct WeightScaleLifecycle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning
        case connecting
        case discovering
        case listening
        case waitingToReconnect
        case bluetoothUnavailable
        case unsupported
    }

    public enum Event: Equatable, Sendable {
        case userRequestedScan
        case rememberedScaleResume
        case candidateChosen
        case transportConnected
        case measurementCharacteristicValidated
        case transportDisconnected(hasRememberedScale: Bool)
        case bluetoothBecameUnavailable
        case protocolRejected
        case userStopped
    }

    public private(set) var phase: Phase = .idle
    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> Phase {
        switch event {
        case .userRequestedScan:
            phase = .scanning
        case .rememberedScaleResume, .candidateChosen:
            phase = .connecting
        case .transportConnected:
            phase = .discovering
        case .measurementCharacteristicValidated:
            phase = .listening
        case .transportDisconnected(let hasRememberedScale):
            phase = hasRememberedScale ? .waitingToReconnect : .idle
        case .bluetoothBecameUnavailable:
            phase = .bluetoothUnavailable
        case .protocolRejected:
            phase = .unsupported
        case .userStopped:
            phase = .idle
        }
        return phase
    }
}

/// Pure multi-user safety gate. An omitted user field means a single-user measurement; 0xFF means
/// the scale explicitly could not identify the person and must never update a personal profile.
public enum WeightScaleProfileUserPolicy {
    public static func allows(measurementUserID: UInt8?, selectedUserID: UInt8?) -> Bool {
        guard let measurementUserID else { return true }
        guard measurementUserID != 0xFF else { return false }
        return measurementUserID == selectedUserID
    }
}
