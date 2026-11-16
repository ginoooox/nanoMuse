import Foundation
import Security

/// Device-local secrets, intentionally absent from provider exports and cloud sync.
enum NanoMuseProviderHeaders {
    private struct Saved: Codable {
        let origin: String
        let rows: [NanoMuseProviderHeaderRules.Header]
    }

    enum Failure: Error { case keychain(OSStatus) }

    private static func query(_ instanceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.nanomuse.app.provider.\(instanceId)",
            kSecAttrAccount as String: "custom-request-headers",
        ]
    }

    static func load(instanceId: String, baseURL: String?) -> [NanoMuseProviderHeaderRules.Header] {
        guard let origin = NanoMuseProviderHeaderRules.origin(baseURL) else { return [] }
        var q = query(instanceId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.origin == origin,
              let rows = try? NanoMuseProviderHeaderRules.validated(saved.rows) else { return [] }
        return rows
    }

    static func values(instanceId: String, baseURL: String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: load(instanceId: instanceId, baseURL: baseURL).map { ($0.name, $0.value) })
    }

    static func save(_ rows: [NanoMuseProviderHeaderRules.Header], instanceId: String, baseURL: String?) throws {
        guard let origin = NanoMuseProviderHeaderRules.origin(baseURL) else {
            throw NanoMuseProviderHeaderRules.Failure.invalidEndpoint
        }
        let rows = try NanoMuseProviderHeaderRules.validated(rows)
        if rows.isEmpty {
            let status = SecItemDelete(query(instanceId) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
            return
        }
        let data = try JSONEncoder().encode(Saved(origin: origin, rows: rows))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(instanceId) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(instanceId).merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    static func remove(instanceId: String) {
        SecItemDelete(query(instanceId) as CFDictionary)
    }
}

/// Keep gateway credentials on their original origin if the server redirects.
final class NanoMuseProviderHeaderRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let original = NanoMuseProviderHeaderRules.origin(task.originalRequest?.url?.absoluteString)
        let destination = NanoMuseProviderHeaderRules.origin(request.url?.absoluteString)
        completionHandler(original != nil && original == destination ? request : nil)
    }
}
