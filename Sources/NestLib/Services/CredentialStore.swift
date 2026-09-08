import Foundation
import Security

public protocol CredentialStore {
    func load() throws -> String
    func save(_ token: String) throws
}

public final class MemoryCredentialStore: CredentialStore {
    private var token: String
    public init(token: String = "") { self.token = token }
    public func load() throws -> String { token }
    public func save(_ token: String) throws { self.token = token }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String = AppSettings.currentBundleIdentifier + ".cloudflare") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-token"]
    }
    public func load() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return String(decoding: data, as: UTF8.self)
    }
    public func save(_ token: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var new = query.merging(values) { _, new in new }
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> ConfigurationFailure {
        ConfigurationFailure("Keychain could not access the Cloudflare token: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status)). Settings were not saved.")
    }
}
