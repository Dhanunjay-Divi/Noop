import XCTest
@testable import NoopRemoteSync

final class ManagedChunkCompressionTests: XCTestCase {
    func testGzipRoundTripIsDeterministicAndBounded() throws {
        let input = Data(
            (0..<20_000).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 3)) }
        )
        let first = try ManagedChunkCodec.encode(input, compression: .gzip)
        let second = try ManagedChunkCodec.encode(input, compression: .gzip)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(4)), [0x1f, 0x8b, 0x08, 0x00])
        XCTAssertLessThan(first.count, input.count)
        XCTAssertEqual(
            try ManagedChunkCodec.decode(
                first,
                compression: "gzip",
                expectedUncompressedBytes: input.count
            ),
            input
        )
    }

    func testGzipRejectsCorruptTrailerAndUnexpectedSize() throws {
        let input = Data("managed health payload".utf8)
        var compressed = try ManagedChunkCodec.encode(input, compression: .gzip)
        compressed[compressed.count - 8] ^= 0xff

        XCTAssertThrowsError(
            try ManagedChunkCodec.decode(
                compressed,
                compression: "gzip",
                expectedUncompressedBytes: input.count
            )
        )
        XCTAssertThrowsError(
            try ManagedChunkCodec.decode(
                try ManagedChunkCodec.encode(input, compression: .gzip),
                compression: "gzip",
                expectedUncompressedBytes: input.count + 1
            )
        )
    }
}
