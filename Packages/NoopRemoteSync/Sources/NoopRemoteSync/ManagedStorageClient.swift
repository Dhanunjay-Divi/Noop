import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ManagedStorageClient {
    private struct EmptyResponse: Decodable {}
    private struct AccessRequest: Encodable { let requestID: UUID }
    private struct OverviewResponse: Decodable {
        struct Account: Decodable {
            let status: String
            let planCode: String
            let displayTier: String
            let maxTotalBytes: Int64?
            let maxInstallations: Int
        }

        struct Storage: Decodable {
            struct Rule: Decodable {
                let committedBytes: Int64
                let reservedBytes: Int64
            }

            let installations: Int
            let rules: [Rule]
        }

        let account: Account
        let storage: Storage
    }
    private struct InstallationsResponse: Decodable {
        let installations: [ManagedInstallation]
    }
    private struct InstallationResponse: Decodable {
        let installation: ManagedInstallation
    }

    private let configuration: ManagedStorageConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: ManagedStorageConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = max(configuration.timeout, 120)
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func enroll(
        platform: ManagedStoragePlatform,
        dataClasses: [String],
        authorization: ManagedAuthorization,
        requestID: UUID
    ) async throws -> ManagedEnrollmentResponse {
        let body = ManagedEnrollmentRequest(
            installationID: authorization.installationID,
            installationToken: authorization.installationToken,
            platform: platform,
            enrollmentRequestID: requestID,
            policyVersion: configuration.policyVersion,
            policySHA256: configuration.policySHA256,
            dataClasses: dataClasses.sorted()
        )
        return try await send(
            path: "v1/managed/enroll",
            method: "POST",
            body: body,
            authorization: authorization,
            includeInstallation: false
        )
    }

    public func overview(
        authorization: ManagedAuthorization
    ) async throws -> ManagedStorageOverview {
        let response: OverviewResponse = try await send(
            path: "v1/managed/me",
            method: "GET",
            authorization: authorization
        )
        guard !response.account.status.isEmpty,
              !response.account.planCode.isEmpty,
              !response.account.displayTier.isEmpty,
              response.account.maxTotalBytes.map({ $0 > 0 }) ?? true,
              response.account.maxInstallations > 0,
              response.storage.installations >= 0 else {
            throw ManagedStorageError.invalidResponse
        }
        var committedBytes: Int64 = 0
        var reservedBytes: Int64 = 0
        for rule in response.storage.rules {
            guard rule.committedBytes >= 0, rule.reservedBytes >= 0 else {
                throw ManagedStorageError.invalidResponse
            }
            let committed = committedBytes.addingReportingOverflow(rule.committedBytes)
            let reserved = reservedBytes.addingReportingOverflow(rule.reservedBytes)
            guard !committed.overflow, !reserved.overflow else {
                throw ManagedStorageError.invalidResponse
            }
            committedBytes = committed.partialValue
            reservedBytes = reserved.partialValue
        }
        return ManagedStorageOverview(
            accountStatus: response.account.status,
            planCode: response.account.planCode,
            planTier: response.account.displayTier,
            maximumBytes: response.account.maxTotalBytes,
            committedBytes: committedBytes,
            reservedBytes: reservedBytes,
            installationCount: response.storage.installations,
            maximumInstallations: response.account.maxInstallations
        )
    }

    public func installations(
        authorization: ManagedAuthorization
    ) async throws -> [ManagedInstallation] {
        let response: InstallationsResponse = try await send(
            path: "v1/managed/installations",
            method: "GET",
            authorization: authorization
        )
        return response.installations
    }

    public func revokeInstallation(
        _ installationID: String,
        authorization: ManagedAuthorization
    ) async throws -> ManagedInstallation {
        guard installationID != authorization.installationID,
              installationID.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
                options: .regularExpression
              ) != nil else {
            throw ManagedStorageError.invalidAuthorization
        }
        let response: InstallationResponse = try await send(
            path: "v1/managed/installations/\(installationID)",
            method: "DELETE",
            authorization: authorization
        )
        guard response.installation.installationID == installationID else {
            throw ManagedStorageError.invalidResponse
        }
        return response.installation
    }

    public func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        try await send(
            path: "v1/managed/sources",
            method: "POST",
            body: source,
            authorization: authorization
        )
    }

    public func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse {
        try await send(
            path: "v1/managed/chunks:reserve",
            method: "POST",
            body: reservation,
            authorization: authorization
        )
    }

    public func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt {
        guard capability.method.uppercased() == "PUT",
              capability.url.scheme?.lowercased() == "https",
              capability.url.host != nil,
              capability.url.user == nil,
              capability.url.password == nil else {
            throw ManagedStorageError.invalidResponse
        }
        var request = URLRequest(url: capability.url)
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.timeoutInterval = max(configuration.timeout, 120)
        for (name, value) in capability.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode),
              let generation = response.value(forHTTPHeaderField: "x-goog-generation")
                .flatMap(Int64.init),
              generation > 0,
              let metageneration = response.value(forHTTPHeaderField: "x-goog-metageneration")
                .flatMap(Int64.init),
              metageneration > 0,
              let crc32c = Self.crc32c(
                from: response.value(forHTTPHeaderField: "x-goog-hash")
              ),
              crc32c.range(
                of: #"^[A-Za-z0-9+/]{6}==$"#,
                options: .regularExpression
              ) != nil else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedObjectUploadReceipt(
            objectGeneration: generation,
            objectMetageneration: metageneration,
            objectCRC32C: crc32c
        )
    }

    public func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws {
        let _: EmptyResponse = try await send(
            path: "v1/managed/chunks/\(chunkID.uuidString.lowercased())/complete",
            method: "POST",
            body: receipt,
            authorization: authorization,
            acceptAnyJSONObject: true
        )
    }

    public func changes(
        after sequence: Int64,
        limit: Int = 200,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed {
        guard sequence >= 0, (1...500).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        return try await send(
            path: "v1/managed/changes?after_sequence=\(sequence)&limit=\(limit)",
            method: "GET",
            authorization: authorization
        )
    }

    public func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        let classes = dataClasses.sorted()
        guard !classes.isEmpty,
              Set(classes).count == classes.count,
              classes.allSatisfy({
                  $0.range(
                      of: #"^[a-z][a-z0-9_]{1,63}$"#,
                      options: .regularExpression
                  ) != nil
              }) else {
            throw ManagedStorageError.invalidConfiguration
        }
        let response: ManagedRestoreResponse = try await send(
            path: "v1/managed/restores",
            method: "POST",
            body: ManagedRestoreRequest(
                requestID: requestID,
                dataClasses: classes,
                includeDocuments: true
            ),
            authorization: authorization
        )
        if ["expired", "completed"].contains(response.restore.status) {
            throw ManagedStorageError.conflict
        }
        try Self.validate(response.restore, expectedStatus: "running")
        return response.restore
    }

    public func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage {
        guard dataClass.range(
            of: #"^[a-z][a-z0-9_]{1,63}$"#,
            options: .regularExpression
        ) != nil,
        ManagedTimestamp.milliseconds(iso8601: snapshotAt) != nil,
        (1...200).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        var query = [
            "data_class=\(Self.queryValue(dataClass))",
            "snapshot_at=\(Self.queryValue(snapshotAt))",
            "limit=\(limit)",
        ]
        if let cursor {
            guard ManagedTimestamp.milliseconds(iso8601: cursor.afterEventStart) != nil else {
                throw ManagedStorageError.invalidConfiguration
            }
            query.append(
                "after_event_start=\(Self.queryValue(cursor.afterEventStart))"
            )
            query.append(
                "after_chunk_id=\(cursor.afterChunkID.uuidString.lowercased())"
            )
        }
        let page: ManagedChunkPage = try await send(
            path: "v1/managed/chunks?\(query.joined(separator: "&"))",
            method: "GET",
            authorization: authorization
        )
        for chunk in page.chunks {
            guard chunk.dataClass == dataClass,
                  chunk.state == "available",
                  chunk.contentMode == "server_readable",
                  chunk.schemaVersion > 0,
                  chunk.expectedSHA256.range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  chunk.expectedCompressedBytes > 0,
                  chunk.expectedUncompressedBytes > 0,
                  chunk.objectGeneration > 0,
                  ManagedTimestamp.milliseconds(iso8601: chunk.eventStart) != nil,
                  ManagedTimestamp.milliseconds(iso8601: chunk.eventEnd) != nil else {
                throw ManagedStorageError.invalidResponse
            }
        }
        if let next = page.nextCursor {
            guard let last = page.chunks.last,
                  next.afterChunkID == last.chunkID,
                  next.afterEventStart == last.eventStart else {
                throw ManagedStorageError.invalidResponse
            }
        }
        return page
    }

    public func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        guard deliveredObjects >= 0, deliveredBytes >= 0 else {
            throw ManagedStorageError.invalidConfiguration
        }
        let response: ManagedRestoreResponse = try await send(
            path: "v1/managed/restores/"
                + restoreJobID.uuidString.lowercased()
                + "/complete",
            method: "POST",
            body: ManagedRestoreCompletion(
                deliveredObjects: deliveredObjects,
                deliveredBytes: deliveredBytes
            ),
            authorization: authorization
        )
        try Self.validate(response.restore, expectedStatus: "completed")
        guard response.restore.restoreJobID == restoreJobID,
              response.restore.deliveredObjects == deliveredObjects,
              response.restore.deliveredBytes == deliveredBytes else {
            throw ManagedStorageError.invalidResponse
        }
        return response.restore
    }

    public func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability {
        try await send(
            path: "v1/managed/chunks/\(chunkID.uuidString.lowercased())/download",
            method: "POST",
            body: AccessRequest(requestID: requestID),
            authorization: authorization
        )
    }

    public func download(
        using capability: ManagedDownloadCapability
    ) async throws -> Data {
        guard capability.method.uppercased() == "GET",
              capability.url.scheme?.lowercased() == "https",
              capability.url.host != nil,
              capability.url.user == nil,
              capability.url.password == nil else {
            throw ManagedStorageError.invalidResponse
        }
        var request = URLRequest(url: capability.url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(configuration.timeout, 120)
        for (name, value) in capability.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ManagedStorageError.server(status: response.statusCode)
        }
        guard ManagedDigest.sha256(data).caseInsensitiveCompare(
            capability.chunk.expectedSHA256
        ) == .orderedSame else {
            throw ManagedStorageError.digestMismatch
        }
        return data
    }

    public func putDocument(
        _ mutation: ManagedDocumentMutation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        let response: ManagedDocumentResponse = try await send(
            path: "v1/managed/documents/\(mutation.documentKind.rawValue)/"
                + mutation.documentID.uuidString.lowercased(),
            method: "PUT",
            body: mutation,
            authorization: authorization
        )
        return response.document
    }

    public func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64? = nil,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        guard revision.map({ $0 > 0 }) ?? true else {
            throw ManagedStorageError.invalidConfiguration
        }
        let query = revision.map { "?revision=\($0)" } ?? ""
        let response: ManagedDocumentResponse = try await send(
            path: "v1/managed/documents/\(kind.rawValue)/"
                + id.uuidString.lowercased() + query,
            method: "GET",
            authorization: authorization
        )
        return response.document
    }

    public func documents(
        snapshotAt: String,
        after cursor: ManagedDocumentPage.Cursor? = nil,
        limit: Int = 100,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocumentPage {
        guard ManagedTimestamp.milliseconds(iso8601: snapshotAt) != nil,
              (1...200).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        var query = [
            "include_deleted=false",
            "snapshot_at=\(Self.queryValue(snapshotAt))",
            "limit=\(limit)",
        ]
        if let cursor {
            guard ManagedTimestamp.milliseconds(
                iso8601: cursor.afterUpdatedAt
            ) != nil else {
                throw ManagedStorageError.invalidConfiguration
            }
            query.append(
                "after_updated_at=\(Self.queryValue(cursor.afterUpdatedAt))"
            )
            query.append(
                "after_document_kind=\(cursor.afterDocumentKind.rawValue)"
            )
            query.append(
                "after_document_id=\(cursor.afterDocumentID.uuidString.lowercased())"
            )
        }
        let page: ManagedDocumentPage = try await send(
            path: "v1/managed/documents?\(query.joined(separator: "&"))",
            method: "GET",
            authorization: authorization
        )
        for document in page.documents {
            guard document.revision > 0,
                  document.contentMode == "server_readable",
                  document.clientKeyID == nil,
                  document.payloadJSON != nil,
                  document.payloadCiphertextBase64 == nil,
                  document.deletedAt == nil,
                  document.contentSHA256.range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  ManagedTimestamp.milliseconds(
                      iso8601: document.updatedAt
                  ) != nil else {
                throw ManagedStorageError.invalidResponse
            }
        }
        if let next = page.nextCursor {
            guard let last = page.documents.last,
                  next == last.pageCursor else {
                throw ManagedStorageError.invalidResponse
            }
        }
        return page
    }

    public func requestErasure(
        _ request: ManagedErasureRequest,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure",
            method: "POST",
            body: request,
            authorization: authorization
        )
        return response.erasure
    }

    public func erasure(
        jobID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure/\(jobID.uuidString.lowercased())",
            method: "GET",
            authorization: authorization
        )
        return response.erasure
    }

    public func cancelErasure(
        jobID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedErasureJob {
        let response: ManagedErasureResponse = try await send(
            path: "v1/managed/erasure/\(jobID.uuidString.lowercased())/cancel",
            method: "POST",
            body: Optional<Int>.none,
            authorization: authorization
        )
        return response.erasure
    }

    func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        authorization: ManagedAuthorization,
        includeInstallation: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.scheme == configuration.baseURL.scheme,
              url.host == configuration.baseURL.host,
              url.port == configuration.baseURL.port else {
            throw ManagedStorageError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        request.setValue(
            "Bearer \(authorization.identityToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            authorization.appCheckToken,
            forHTTPHeaderField: "X-Firebase-AppCheck"
        )
        if includeInstallation {
            request.setValue(
                authorization.installationID,
                forHTTPHeaderField: "X-Noop-Installation-ID"
            )
            request.setValue(
                authorization.installationToken,
                forHTTPHeaderField: "X-Noop-Installation-Token"
            )
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw ManagedStorageError.encoding
            }
        }
        return request
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        authorization: ManagedAuthorization
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: Optional<Int>.none,
            authorization: authorization
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        authorization: ManagedAuthorization,
        includeInstallation: Bool = true,
        acceptAnyJSONObject: Bool = false
    ) async throws -> Response {
        let request = try makeRequest(
            path: path,
            method: method,
            body: body,
            authorization: authorization,
            includeInstallation: includeInstallation
        )
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response.statusCode, data: data)
        }
        if acceptAnyJSONObject, Response.self == EmptyResponse.self {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw ManagedStorageError.decoding
            }
            return EmptyResponse() as! Response
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ManagedStorageError.decoding
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ManagedStorageError.invalidResponse
            }
            return (data, response)
        } catch let error as ManagedStorageError {
            throw error
        } catch {
            throw ManagedStorageError.transport
        }
    }

    private static func error(for status: Int, data: Data) -> ManagedStorageError {
        switch status {
        case 401, 403:
            return .authentication
        case 404:
            return .notFound
        case 409:
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("policy") { return .policyChanged }
            if text.contains("quota") || text.contains("allowance") || text.contains("maximum_bytes") {
                return .quotaExceeded
            }
            return .conflict
        case 410:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"] as? [String: Any]
            return .cursorExpired(minimumSequence: (detail?["minimum_sequence"] as? NSNumber)?.int64Value)
        default:
            return .server(status: status)
        }
    }

    private static func crc32c(from hashHeader: String?) -> String? {
        hashHeader?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("crc32c=") }
            .map { String($0.dropFirst("crc32c=".count)) }
    }

    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? ""
    }

    private static func validate(
        _ restore: ManagedRestoreJob,
        expectedStatus: String
    ) throws {
        guard restore.status == expectedStatus,
              ManagedTimestamp.milliseconds(iso8601: restore.snapshotAt) != nil,
              restore.changeSequence >= 0,
              restore.selectedObjects >= 0,
              restore.selectedBytes >= 0,
              restore.deliveredObjects >= 0,
              restore.deliveredBytes >= 0,
              restore.deliveredObjects <= restore.selectedObjects,
              restore.deliveredBytes <= restore.selectedBytes,
              ManagedTimestamp.milliseconds(iso8601: restore.expiresAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }
    }
}
