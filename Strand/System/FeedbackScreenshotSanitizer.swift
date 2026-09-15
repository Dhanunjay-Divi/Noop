import Foundation

struct FeedbackScreenshotCaptureGuard {
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(
        _ token: UInt64,
        isPresented: Bool,
        isOptedIn: Bool
    ) -> Bool {
        isPresented && isOptedIn && token == generation
    }
}

/// Removes metadata-bearing PNG chunks before an explicitly approved screenshot reaches feedback
/// review. The server independently decodes and validates the resulting PNG.
enum FeedbackScreenshotSanitizer {
    static let maximumBytes = 8 * 1024 * 1024

    private static let signature = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ])
    private static let preservedChunkTypes: Set<String> = [
        "IHDR", "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "pHYs", "IDAT", "IEND",
    ]
    private static let singletonChunkTypes: Set<String> = [
        "IHDR", "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "pHYs", "IEND",
    ]
    private static let preImageChunkTypes: Set<String> = [
        "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "pHYs",
    ]
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? 0xedb8_8320 ^ (crc >> 1)
                : crc >> 1
        }
        return crc
    }

    static func sanitize(
        _ png: Data,
        maximumBytes: Int = maximumBytes
    ) -> Data? {
        guard maximumBytes >= signature.count,
              png.count >= signature.count,
              png.count <= maximumBytes,
              png.prefix(signature.count) == signature else {
            return nil
        }

        let bytes = [UInt8](png)
        var output = signature
        var offset = signature.count
        var sawHeader = false
        var sawImageData = false
        var sawEnd = false
        var seenSingletons = Set<String>()

        while offset < bytes.count {
            guard !sawEnd,
                  bytes.count - offset >= 12 else {
                return nil
            }

            let chunkLengthValue = readUInt32(bytes, at: offset)
            guard chunkLengthValue <= UInt32(maximumBytes) else {
                return nil
            }
            let chunkLength = Int(chunkLengthValue)
            guard chunkLength <= bytes.count - offset - 12 else {
                return nil
            }

            let typeOffset = offset + 4
            let dataOffset = typeOffset + 4
            let checksumOffset = dataOffset + chunkLength
            let chunkEnd = checksumOffset + 4
            let typeBytes = Array(bytes[typeOffset..<(typeOffset + 4)])
            guard typeBytes.allSatisfy(isASCIIAlpha),
                  typeBytes[2] & 0x20 == 0,
                  let chunkType = String(bytes: typeBytes, encoding: .ascii),
                  crc32(bytes, range: typeOffset..<checksumOffset)
                    == readUInt32(bytes, at: checksumOffset) else {
                return nil
            }

            switch chunkType {
            case "IHDR":
                guard offset == signature.count,
                      chunkLength == 13,
                      !sawHeader else {
                    return nil
                }
                sawHeader = true
            case "IDAT":
                guard sawHeader else { return nil }
                sawImageData = true
            case "IEND":
                guard sawHeader,
                      sawImageData,
                      chunkLength == 0,
                      chunkEnd == bytes.count else {
                    return nil
                }
                sawEnd = true
            case let type where preImageChunkTypes.contains(type):
                guard sawHeader, !sawImageData else { return nil }
            default:
                guard sawHeader else { return nil }
                let isAncillary = typeBytes[0] & 0x20 != 0
                guard isAncillary else { return nil }
            }

            if preservedChunkTypes.contains(chunkType) {
                if singletonChunkTypes.contains(chunkType),
                   !seenSingletons.insert(chunkType).inserted {
                    return nil
                }
                output.append(contentsOf: bytes[offset..<chunkEnd])
                guard output.count <= maximumBytes else { return nil }
            }
            offset = chunkEnd
        }

        guard sawHeader, sawImageData, sawEnd, offset == bytes.count else {
            return nil
        }
        return output
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func crc32(
        _ bytes: [UInt8],
        range: Range<Int>
    ) -> UInt32 {
        var crc = UInt32.max
        for index in range {
            let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xff)
            crc = crcTable[tableIndex] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }
}
