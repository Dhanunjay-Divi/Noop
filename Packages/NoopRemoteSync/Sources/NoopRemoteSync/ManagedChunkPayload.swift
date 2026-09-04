import CryptoKit
import Foundation

public enum ManagedJSONValue: Codable, Equatable, Sendable {
    case integer(Int64)
    case number(Double)
    case string(String)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw ManagedStorageError.encoding }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var timestampMilliseconds: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }
}

public struct ManagedChunkStreamPayload: Codable, Equatable, Sendable {
    public let streamKey: String
    public let schemaRevision: Int
    public let columns: [String]
    public let rows: [[ManagedJSONValue]]

    private enum CodingKeys: String, CodingKey {
        case streamKey = "stream_key"
        case schemaRevision = "schema_revision"
        case columns
        case rows
    }

    public init(
        streamKey: String,
        columns: [String],
        rows: [[ManagedJSONValue]],
        schemaRevision: Int = 1
    ) {
        self.streamKey = streamKey
        self.schemaRevision = schemaRevision
        self.columns = columns
        self.rows = rows
    }
}

public struct ManagedChunkPayload: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let sourceID: UUID
    public let dataClass: String
    public let schemaVersion: Int
    public let eventStartMs: Int64
    public let eventEndMs: Int64
    public let streams: [ManagedChunkStreamPayload]

    public init(
        chunkID: UUID,
        sourceID: UUID,
        dataClass: String,
        eventStartMs: Int64,
        eventEndMs: Int64,
        streams: [ManagedChunkStreamPayload],
        schemaVersion: Int = 1
    ) {
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.dataClass = dataClass
        self.schemaVersion = schemaVersion
        self.eventStartMs = eventStartMs
        self.eventEndMs = eventEndMs
        self.streams = streams
    }

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case sourceID = "source_id"
        case dataClass = "data_class"
        case schemaVersion = "schema_version"
        case eventStartMs = "event_start_ms"
        case eventEndMs = "event_end_ms"
        case streams
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chunkID = try container.decode(UUID.self, forKey: .chunkID)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        dataClass = try container.decode(String.self, forKey: .dataClass)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventStartMs = try container.decode(Int64.self, forKey: .eventStartMs)
        eventEndMs = try container.decode(Int64.self, forKey: .eventEndMs)
        streams = try container.decode(
            [ManagedChunkStreamPayload].self,
            forKey: .streams
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chunkID.uuidString.lowercased(), forKey: .chunkID)
        try container.encode(sourceID.uuidString.lowercased(), forKey: .sourceID)
        try container.encode(dataClass, forKey: .dataClass)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventStartMs, forKey: .eventStartMs)
        try container.encode(eventEndMs, forKey: .eventEndMs)
        try container.encode(streams, forKey: .streams)
    }
}

public struct ManagedPreparedChunk: Equatable, Sendable {
    public let payload: ManagedChunkPayload
    public let uncompressed: Data
    public let uncompressedSHA256: String
    public let manifests: [ManagedChunkStreamManifest]

    public static func prepare(
        sourceID: UUID,
        dataClass: String,
        eventStartMs: Int64,
        eventEndMs: Int64,
        streams: [ManagedChunkStreamPayload]
    ) throws -> ManagedPreparedChunk? {
        guard eventStartMs >= 0,
              eventEndMs >= eventStartMs,
              !dataClass.isEmpty else {
            throw ManagedStorageError.encoding
        }
        let ordered = streams.sorted { $0.streamKey < $1.streamKey }
        guard !ordered.isEmpty,
              Set(ordered.map(\.streamKey)).count == ordered.count else {
            return nil
        }

        for stream in ordered {
            guard !stream.streamKey.isEmpty,
                  stream.columns.first == "event_at_ms",
                  Set(stream.columns).count == stream.columns.count,
                  stream.rows.allSatisfy({ row in
                      row.count == stream.columns.count
                          && row.first?.timestampMilliseconds.map {
                              eventStartMs <= $0 && $0 <= eventEndMs
                          } == true
                  }) else {
                throw ManagedStorageError.encoding
            }
        }

        let seedPayload = ManagedChunkPayload(
            chunkID: UUID(),
            sourceID: sourceID,
            dataClass: dataClass,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            streams: ordered
        )
        let contentWithoutID = try canonicalData(seedPayload, replacingChunkID: nil)
        let chunkID = ManagedStableIdentifier.uuid(
            seed: Data("noop-managed-chunk-v1\0".utf8) + contentWithoutID
        )
        let payload = ManagedChunkPayload(
            chunkID: chunkID,
            sourceID: sourceID,
            dataClass: dataClass,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            streams: ordered
        )
        let data = try canonicalData(payload)
        let manifests = try ordered.map { stream in
            let encoded = try canonicalData(stream)
            let timestamps = stream.rows.compactMap { $0.first?.timestampMilliseconds }
            return ManagedChunkStreamManifest(
                streamKey: stream.streamKey,
                sampleCount: stream.rows.count,
                firstEventAt: timestamps.min().map {
                    ManagedTimestamp.iso8601(milliseconds: $0)
                },
                lastEventAt: timestamps.max().map {
                    ManagedTimestamp.iso8601(milliseconds: $0)
                },
                encodedBytes: encoded.count
            )
        }
        return ManagedPreparedChunk(
            payload: payload,
            uncompressed: data,
            uncompressedSHA256: ManagedDigest.sha256(data),
            manifests: manifests
        )
    }

    public func reservation(
        compressed: Data,
        compression: String
    ) -> ManagedChunkReservation {
        ManagedChunkReservation(
            chunkID: payload.chunkID,
            requestID: ManagedStableIdentifier.uuid(
                seed: Data("noop-managed-reservation-v1\0\(payload.chunkID.uuidString)".utf8)
            ),
            sourceID: payload.sourceID,
            dataClass: payload.dataClass,
            eventStart: ManagedTimestamp.iso8601(milliseconds: payload.eventStartMs),
            eventEnd: ManagedTimestamp.iso8601(milliseconds: payload.eventEndMs),
            compression: compression,
            expectedSHA256: ManagedDigest.sha256(compressed),
            expectedCompressedBytes: compressed.count,
            expectedUncompressedBytes: uncompressed.count,
            streams: manifests
        )
    }

    private static func canonicalData<T: Encodable>(
        _ value: T,
        replacingChunkID: UUID? = UUID()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let encoded = try encoder.encode(value)
            guard replacingChunkID == nil,
                  var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                return encoded
            }
            object.removeValue(forKey: "chunk_id")
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ManagedStorageError.encoding
        }
    }
}

public enum ManagedStableIdentifier {
    public static func uuid(seed: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum ManagedAccountIdentifier {
    public static func installationID(
        baseInstallationID: String,
        accountScopeHash: String
    ) throws -> String {
        guard baseInstallationID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
            options: .regularExpression
        ) != nil,
        accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidConfiguration
        }
        let seed = Data(
            "noop-managed-installation-v2\0\(baseInstallationID)\0\(accountScopeHash)".utf8
        )
        return ManagedStableIdentifier.uuid(seed: seed).uuidString.lowercased()
    }
}

public enum ManagedDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ManagedTimestamp {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let wholeSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func iso8601(milliseconds: Int64) -> String {
        fractionalFormatter.string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    public static func milliseconds(iso8601 value: String) -> Int64? {
        guard let date = fractionalFormatter.date(from: value)
            ?? wholeSecondsFormatter.date(from: value) else {
            return nil
        }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
