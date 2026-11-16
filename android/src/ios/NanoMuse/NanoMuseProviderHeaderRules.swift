import Foundation

/// Validation and merging shared by the settings editor and the request factory.
enum NanoMuseProviderHeaderRules {
    struct Header: Codable, Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var value = ""
    }

    enum Failure: Error { case invalidHeader, invalidEndpoint }

    // URLSession owns framing and routing. Authentication stays in the API-key field.
    private static let reserved: Set<String> = [
        "host", "content-length", "content-type", "connection", "transfer-encoding",
        "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer",
        "authorization", "api-key", "x-api-key",
    ]

    static func validated(_ rows: [Header]) throws -> [Header] {
        var seen = Set<String>()
        return try rows.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespaces)
            let value = row.value.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && value.isEmpty { return nil }
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ token.contains($0) }),
                  !reserved.contains(name.lowercased()), seen.insert(name.lowercased()).inserted,
                  !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw Failure.invalidHeader
            }
            return Header(id: row.id, name: name, value: value)
        }
    }

    /// Bind credentials to a scheme/host/port, so editing the endpoint cannot leak them.
    static func origin(_ baseURL: String?) -> String? {
        guard let baseURL, let parts = URLComponents(string: baseURL),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// Last configured spelling wins, including against differently cased default names.
    static func merging(_ custom: [String: String], into defaults: [String: String]) -> [String: String] {
        var result = defaults
        for (name, value) in custom {
            for existing in Array(result.keys) where existing.caseInsensitiveCompare(name) == .orderedSame {
                result.removeValue(forKey: existing)
            }
            result[name] = value
        }
        return result
    }

    static func redacted(_ headers: [String: String]) -> [String: String] {
        // Custom header names are open-ended. Mask every value in request diagnostics.
        headers.mapValues { _ in "***" }
    }
}
