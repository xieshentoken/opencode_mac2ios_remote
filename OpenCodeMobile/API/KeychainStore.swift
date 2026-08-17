import Foundation
import Security

enum KeychainStore {
    private static let service = "dev.opencodemobile.app"

    /// Saves a server config (password stored in Keychain, name/URL in UserDefaults).
    static func save(config: ServerConfig) throws {
        let passwordData = Data(config.password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(config.id)",
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = passwordData
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.osStatus(status)
        }

        // Persist non-secret metadata in UserDefaults
        let defaults = UserDefaults.standard
        var stored = storedConfigs()
        if let idx = stored.firstIndex(where: { $0.id == config.id }) {
            stored[idx] = config
        } else {
            stored.append(config)
        }
        defaults.set(try JSONEncoder().encode(stored), forKey: "servers")
    }

    static func storedConfigs() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let configs = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    /// Re-attaches the stored Keychain password for a config.
    static func resolvePassword(for config: ServerConfig) -> ServerConfig {
        var c = config
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(config.id)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let pw = String(data: data, encoding: .utf8) {
            c.password = pw
        }
        return c
    }

    static func delete(config: ServerConfig) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(config.id)",
        ]
        SecItemDelete(query as CFDictionary)
        let defaults = UserDefaults.standard
        var stored = storedConfigs()
        stored.removeAll { $0.id == config.id }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: "servers")
        }
    }

    enum KeychainError: Error {
        case osStatus(OSStatus)
    }
}
