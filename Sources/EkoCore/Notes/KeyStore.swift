import Foundation
import Security

/// The Gemini API key. Kept in the login Keychain (generic password); never written anywhere else and never
/// logged. `GEMINI_API_KEY` in the environment wins, which is what the CLI normally uses.
///
/// The file-based login keychain is used, not the data-protection keychain: the latter needs a provisioning
/// profile, which the self-signed release identity does not have. Keychain access is tied to the app's
/// signature, so signed updates keep access; ad-hoc development builds trigger a Keychain prompt.
public enum KeyStore {
    static let service = "com.altslate.eko.gemini"
    static let account = "api-key"

    public enum KeyError: LocalizedError {
        case empty, keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .empty: return "The key is empty."
            case let .keychain(status):
                return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")"
            }
        }
    }

    /// Environment first, then the Keychain.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let env = environment["GEMINI_API_KEY"].map(clean), !env.isEmpty { return env }
        return loadFromKeychain()
    }

    public static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = clean(key)
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func save(_ key: String) throws {
        let key = clean(key)
        guard !key.isEmpty else { throw KeyError.empty }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(key.utf8)
        // The comment holds "…last4", readable without unlocking the secret (see `summary()`).
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data,
                                                          kSecAttrComment as String: masked(key)] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrComment as String] = masked(key)
            add[kSecAttrLabel as String] = "Eko – Gemini API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    /// Whether a key is stored, and its "…last4" hint, read from the item's attributes only. Unlike reading the
    /// key itself, this never makes macOS ask for Keychain access, so the app can show its state at launch.
    /// (Each new build of a self-signed app counts as a new app to the Keychain and must be allowed again.)
    public static func summary() -> (stored: Bool, hint: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return (false, nil) }
        return (true, (item as? [String: Any])?[kSecAttrComment as String] as? String)
    }

    public static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// "…uM": enough to recognise a key, useless to anyone else.
    public static func masked(_ key: String) -> String { "…" + key.suffix(4) }

    /// Pasted keys often carry spaces, newlines or quotes.
    public static func clean(_ key: String) -> String {
        key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }
}
