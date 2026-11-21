import Foundation
import Security

enum Keychain {
    private static let service = "labs.triherm.cluinnoss.connections" // Stable so preview profiles retain their credentials.

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    static func read(_ id: UUID) throws -> String {
        var attrs = query(id)
        attrs[kSecReturnData as String] = true
        attrs[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attrs as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data,
              let secret = String(data: data, encoding: .utf8) else { throw failure(status) }
        return secret
    }

    static func write(_ secret: String, for id: UUID) throws {
        let attrs = query(id)
        if secret.isEmpty {
            let status = SecItemDelete(attrs as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }

        let data = Data(secret.utf8)
        var status = SecItemUpdate(attrs as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = attrs
            entry[kSecValueData as String] = data
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> WorkspaceError {
        WorkspaceError("Could not access macOS Keychain (\(status)).")
    }
}
