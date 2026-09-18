import Foundation
import Security

/// The TypeSafe API key, in the Keychain and nowhere else.
///
/// Read only when a decision actually needs TypeSafe — never at launch, and never when the
/// model loaded here can answer — so the consent dialog a rebuilt app triggers cannot stall
/// startup, and a Mac with no key pays nothing for having the lane available.
enum TypeSafeCredential {
    private static let service = "dev.siliconoptimizer.credentials"
    private static let account = "typesafe-api-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Whether a key is stored, without reading it back. Attribute-only queries do not
    /// need the item's access control, so this never prompts.
    static var isSet: Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }

    /// Stores the key; an empty string removes it.
    @discardableResult
    static func write(_ rawValue: String) -> Bool {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
