import Foundation
import Compression

public enum ManagedChunkCompression: String, Codable, Sendable {
    case gzip
    case none
}

public enum ManagedChunkCodec {
    public static let maximumUncompressedBytes = 64 * 1_024 * 1_024

    public static func encode(
        _ data: Data,
        compression: ManagedChunkCompression
    ) throws -> Data {
        guard !data.isEmpty, data.count <= maximumUncompressedBytes else {
            throw ManagedStorageError.encoding
        }
        switch compression {
        case .none:
            return data
        case .gzip:
            return try gzip(data)
        }
    }

    public static func decode(
        _ data: Data,
        compression: String,
        expectedUncompressedBytes: Int
    ) throws -> Data {
        guard expectedUncompressedBytes > 0,
              expectedUncompressedBytes <= maximumUncompressedBytes else {
            throw ManagedStorageError.decoding
        }
        let decoded: Data
        switch compression {
        case ManagedChunkCompression.none.rawValue:
            decoded = data
        case ManagedChunkCompression.gzip.rawValue:
            decoded = try gunzip(
                data,
                expectedUncompressedBytes: expectedUncompressedBytes
            )
        default:
            throw ManagedStorageError.decoding
        }
        guard decoded.count == expectedUncompressedBytes else {
            throw ManagedStorageError.decoding
        }
        return decoded
    }

    private static func gzip(_ data: Data) throws -> Data {
        let overhead = max(64, data.count / 8)
        var deflated = [UInt8](repeating: 0, count: data.count + overhead)
        let encodedCount = data.withUnsafeBytes { source in
            compression_encode_buffer(
                &deflated,
                deflated.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard encodedCount > 0 else { throw ManagedStorageError.encoding }

        var result = Data([
            0x1f, 0x8b, 0x08, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0xff,
        ])
        result.append(contentsOf: deflated.prefix(encodedCount))
        result.appendLittleEndian(crc32(data))
        result.appendLittleEndian(UInt32(truncatingIfNeeded: data.count))
        return result
    }

    private static func gunzip(
        _ data: Data,
        expectedUncompressedBytes: Int
    ) throws -> Data {
        guard data.count >= 18,
              data[0] == 0x1f,
              data[1] == 0x8b,
              data[2] == 0x08,
              data[3] == 0 else {
            throw ManagedStorageError.decoding
        }
        let trailerStart = data.count - 8
        let expectedCRC = data.littleEndianUInt32(at: trailerStart)
        let expectedSize = data.littleEndianUInt32(at: trailerStart + 4)
        guard expectedSize == UInt32(truncatingIfNeeded: expectedUncompressedBytes) else {
            throw ManagedStorageError.decoding
        }

        let compressed = data[10..<trailerStart]
        var output = [UInt8](repeating: 0, count: expectedUncompressedBytes)
        let decodedCount = compressed.withUnsafeBytes { source in
            compression_decode_buffer(
                &output,
                output.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                compressed.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decodedCount == expectedUncompressedBytes else {
            throw ManagedStorageError.decoding
        }
        let decoded = Data(output)
        guard crc32(decoded) == expectedCRC else {
            throw ManagedStorageError.digestMismatch
        }
        return decoded
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1
                    ? (value >> 1) ^ 0xedb8_8320
                    : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func littleEndianUInt32(at index: Int) -> UInt32 {
        UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }
}
