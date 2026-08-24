import Foundation
import Security

enum KeychainStore {
    private static let service = "dev.opencodemobile.app"
    private static let defaultsKey = "servers"

    /// Saves a server config (password stored in Keychain, name/URL in UserDefaults).
    static func save(config: ServerConfig) throws {
        try storePassword(config.password, id: config.id)

        var stored = decodeStoredConfigs()
        let metadata = config.redactedForPersistence
        if let idx = stored.firstIndex(where: { $0.id == config.id }) {
            stored[idx] = metadata
        } else {
            stored.append(metadata)
        }
        try persistMetadata(stored)
    }

    private static func storePassword(_ password: String, id: String) throws {
        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(id)",
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
    }

    static func storedConfigs() -> [ServerConfig] {
        let configs = decodeStoredConfigs()
        var migratedLegacySecret = false
        let redacted = configs.map { config -> ServerConfig in
            guard !config.password.isEmpty else { return config.redactedForPersistence }
            // Older builds accidentally encoded the password in UserDefaults.
            // Preserve it in Keychain only if no Keychain value exists, then
            // immediately rewrite the metadata without the secret.
            if keychainPassword(id: config.id) == nil {
                try? storePassword(config.password, id: config.id)
            }
            migratedLegacySecret = true
            return config.redactedForPersistence
        }
        if migratedLegacySecret {
            try? persistMetadata(redacted)
        }
        return redacted
    }

    /// Re-attaches the stored Keychain password for a config.
    static func resolvePassword(for config: ServerConfig) -> ServerConfig {
        var c = config
        if let password = keychainPassword(id: config.id) {
            c.password = password
        }
        return c
    }

    private static func keychainPassword(id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(id)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let pw = String(data: data, encoding: .utf8) {
            return pw
        }
        return nil
    }

    static func delete(config: ServerConfig) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "server-\(config.id)",
        ]
        SecItemDelete(query as CFDictionary)
        var stored = decodeStoredConfigs()
        stored.removeAll { $0.id == config.id }
        try? persistMetadata(stored)
    }

    private static func decodeStoredConfigs() -> [ServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let configs = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    private static func persistMetadata(_ configs: [ServerConfig]) throws {
        let safe = configs.map(\.redactedForPersistence)
        UserDefaults.standard.set(try JSONEncoder().encode(safe), forKey: defaultsKey)
    }

    enum KeychainError: Error {
        case osStatus(OSStatus)
    }
}
