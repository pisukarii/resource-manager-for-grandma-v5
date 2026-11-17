import Foundation
import Security

/// Stores each SFTP Source's password in the user's login Keychain, keyed by
/// the `SourceConfig.id`. Password-only auth for v1 (no SSH keys).
enum KeychainCredentialStore {
    private static let service = "com.pisukari.grandmaresourcemanager.sftp"

    static func savePassword(_ password: String, for sourceID: UUID) {
        let account = sourceID.uuidString
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func password(for sourceID: UUID) -> String? {
        password(for: sourceID, service: service)
    }

    static func deletePassword(for sourceID: UUID) {
        let account = sourceID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func password(for sourceID: UUID, service: String) -> String? {
        let account = sourceID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
