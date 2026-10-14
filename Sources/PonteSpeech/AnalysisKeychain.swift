import Foundation
import Security

// The API keys of the call analysis live only in the macOS Keychain: one generic password per provider, service
// "ponte-analysis-<id>" (AnalysisRules.keychainService), account "ponte". The key is never written to a file, the
// settings or the log; the app reads it when a call starts or the settings change.

extension Keychain {
    /// Writes (or replaces) a generic password. Returns the Security status (errSecSuccess on success).
    @discardableResult
    static func setGenericPassword(_ value: String, service: String, account: String = "ponte") -> OSStatus {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let data = Data(value.utf8)
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: data,
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Removes every generic password of the service. Returns the Security status (absent counts as success).
    @discardableResult
    static func deleteGenericPassword(service: String) -> OSStatus {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(match as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// Where the analysis keys are kept. The app uses the Keychain; tests use memory, so no test touches a real key.
public protocol AnalysisKeyStore: AnyObject, Sendable {
    /// The provider's key, or nil when none is saved.
    func key(for provider: Int) -> String?
    func save(_ key: String, for provider: Int) throws
    func delete(for provider: Int) throws
}

/// A Keychain write or delete failed.
public struct AnalysisKeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "код \(status)"
        return "Связка ключей не сохранила изменение: \(detail)"
    }
}

/// The macOS Keychain (login keychain), one item per provider.
public final class KeychainAnalysisKeyStore: AnalysisKeyStore, @unchecked Sendable {
    public init() {}

    public func key(for provider: Int) -> String? {
        Keychain.genericPassword(service: AnalysisRules.keychainService(provider))
    }

    public func save(_ key: String, for provider: Int) throws {
        let status = Keychain.setGenericPassword(key, service: AnalysisRules.keychainService(provider))
        guard status == errSecSuccess else { throw AnalysisKeychainError(status: status) }
    }

    public func delete(for provider: Int) throws {
        let status = Keychain.deleteGenericPassword(service: AnalysisRules.keychainService(provider))
        guard status == errSecSuccess else { throw AnalysisKeychainError(status: status) }
    }
}

/// Keys in memory only: for tests and demos.
public final class MemoryAnalysisKeyStore: AnalysisKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Int: String] = [:]

    public init(_ keys: [Int: String] = [:]) { self.keys = keys }

    public func key(for provider: Int) -> String? { lock.withLock { keys[provider] } }
    public func save(_ key: String, for provider: Int) throws { lock.withLock { keys[provider] = key } }
    public func delete(for provider: Int) throws { _ = lock.withLock { keys.removeValue(forKey: provider) } }
}
