import Foundation

enum FeedbackServerStatus: String, Codable, CaseIterable {
    case reserved
    case sent
    case rejected
    case deleting
    case deleted
}

enum FeedbackProtocolValidation {
    static let maximumAppVersionBytes = 32
    static let productionUploadHost = "storage.googleapis.com"

    static func validAppVersion(_ value: String) -> Bool {
        value.utf8.count <= maximumAppVersionBytes
            && value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$"#,
                options: .regularExpression
            ) != nil
    }

    static func canonicalReportID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    static func validReportToken(_ value: String) -> Bool {
        value.range(
            of: #"^(?:v[0-9]{1,4}\.)?[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil
    }

    static func validReceipt(_ value: String) -> Bool {
        value.range(
            of: #"^NF-[A-Z2-7]{16}$"#,
            options: .regularExpression
        ) != nil
    }

    static func validIdentitySubjectSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    static func validSignedUploadURL(
        _ url: URL,
        allowsLocalHTTP: Bool
    ) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(),
        components.user == nil,
        components.password == nil,
        components.fragment == nil,
        !components.path.isEmpty else {
            return false
        }

        if scheme == "https" {
            return host == productionUploadHost
                && (components.port == nil || components.port == 443)
                && gcsSignedHeaderNames(components) != nil
        }
        return scheme == "http"
            && allowsLocalHTTP
            && isLocalHost(host)
    }

    static func validSignedUploadHeaders(
        _ headers: [String: String],
        archiveBytes: Int64,
        archiveSHA256: String
    ) -> Bool {
        guard headers.count <= 32,
              archiveSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil else {
            return false
        }
        var foldedNames = Set<String>()
        var foldedHeaders: [String: String] = [:]

        for (name, value) in headers {
            let folded = name.lowercased()
            guard foldedNames.insert(folded).inserted,
                  validHeaderName(name),
                  value.utf8.count <= 4_096,
                  !value.contains("\r"),
                  !value.contains("\n"),
                  folded == "content-length"
                    || folded == "content-type"
                    || folded.hasPrefix("x-goog-") else {
                return false
            }

            if folded == "content-length" {
                guard Int64(value) == archiveBytes else { return false }
            } else if folded == "content-type" {
                guard value.lowercased() == "application/zip" else {
                    return false
                }
            }
            foldedHeaders[folded] = value
        }
        return foldedHeaders["content-length"] == String(archiveBytes)
            && foldedHeaders["content-type"]?.lowercased() == "application/zip"
            && foldedHeaders["x-goog-content-sha256"] == archiveSHA256
            && foldedHeaders["x-goog-meta-noop-sha256"] == archiveSHA256
            && foldedHeaders["x-goog-if-generation-match"] == "0"
    }

    static func validSignedUpload(
        url: URL,
        headers: [String: String],
        archiveBytes: Int64,
        archiveSHA256: String,
        allowsLocalHTTP: Bool
    ) -> Bool {
        guard validSignedUploadURL(
            url,
            allowsLocalHTTP: allowsLocalHTTP
        ),
        validSignedUploadHeaders(
            headers,
            archiveBytes: archiveBytes,
            archiveSHA256: archiveSHA256
        ) else {
            return false
        }
        guard url.scheme?.lowercased() == "https" else {
            return true
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let signedNames = gcsSignedHeaderNames(components) else {
            return false
        }
        return Set(headers.keys.map { $0.lowercased() })
            .isSubset(of: signedNames)
    }

    private static func gcsSignedHeaderNames(
        _ components: URLComponents
    ) -> Set<String>? {
        let items = components.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            let name = item.name.lowercased()
            guard values[name] == nil, let value = item.value else {
                return nil
            }
            values[name] = value
        }
        let required = [
            "x-goog-algorithm",
            "x-goog-credential",
            "x-goog-date",
            "x-goog-expires",
            "x-goog-signature",
            "x-goog-signedheaders",
        ]
        guard required.allSatisfy({ values[$0]?.isEmpty == false }),
              values["x-goog-algorithm"] == "GOOG4-RSA-SHA256",
              let rawSignedHeaders = values["x-goog-signedheaders"] else {
            return nil
        }
        let signedHeaders = rawSignedHeaders
            .split(separator: ";")
            .map { $0.lowercased() }
        let uniqueHeaders = Set(signedHeaders)
        guard signedHeaders.count == uniqueHeaders.count,
              uniqueHeaders.contains("host") else {
            return nil
        }
        return uniqueHeaders
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.range(
                of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#,
                options: .regularExpression
            ) != nil
    }
}
