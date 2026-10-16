import Foundation
import Security

// The API keys of the call analysis live only in the macOS Keychain: one generic password per provider, service
// "ponte-analysis-<id>" (AnalysisRules.keychainService), account "ponte". The secret is JSON {"key", "baseURL"}:
// the key together with the base URL it was saved for, so the key goes only to that address (AnalysisRules.bindCheck)
// whatever another process writes into the settings. An item of an older Ponte holds the bare key (no address).
// The key is never written to a file, the settings or the log; the app reads it when a call starts or the settings
// change.

/// A saved key and the base URL it was saved for.
public struct AnalysisStoredKey: Sendable, Equatable {
    public let key: String
    /// The address the key may go to; nil for a key saved by Ponte before keys were bound to addresses.
    public let baseURL: String?

    public init(key: String, baseURL: String?) {
        self.key = key
        self.baseURL = baseURL
    }

    /// The secret of the Keychain item: {"baseURL": …, "key": …}.
    public var payload: Data {
        var object = ["key": key]
        if let baseURL { object["baseURL"] = baseURL }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(key.utf8)
    }

    /// Reads a secret: the JSON of this version, else the bare key of an older one; nil when there is no key.
    public init?(payload: Data) {
        if let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
           let key = (object["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !key.isEmpty else { return nil }
            self.init(key: key, baseURL: object["baseURL"] as? String)
            return
        }
        guard let key = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        self.init(key: key, baseURL: nil)
    }
}

/// Where the analysis keys are kept. The app uses the Keychain; tests use memory, so no test touches a real key.
public protocol AnalysisKeyStore: AnyObject, Sendable {
    /// The provider's key and its address, or nil when none is saved.
    func stored(for provider: Int) -> AnalysisStoredKey?
    /// Saves the key bound to `baseURL`, replacing Ponte's own item. Throws AnalysisKeychainError.
    func save(_ key: String, baseURL: String, for provider: Int) throws
    func delete(for provider: Int) throws
}

/// A Keychain write or delete failed (AnalysisRules.save*). The text is Russian: the settings show it as it is.
public struct AnalysisKeychainError: Error, LocalizedError, Equatable {
    /// AnalysisRules.saveForeign or saveFailed.
    public let outcome: Int
    public let status: OSStatus
    public let service: String

    public init(outcome: Int, status: OSStatus, service: String) {
        self.outcome = outcome
        self.status = status
        self.service = service
    }

    public var errorDescription: String? {
        if outcome == AnalysisRules.saveForeign {
            return "Ключ не сохранён: в связке ключей уже есть запись «\(service)», которую Ponte не может заменить "
                + "(её мог создать другой процесс). Откройте программу «Связка ключей», найдите «\(service)», удалите "
                + "эту запись и сохраните ключ ещё раз."
        }
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "код \(status)"
        return "Связка ключей не сохранила изменение: \(detail)"
    }
}

/// The Security calls of the store, so tests can play a Keychain (another app's item included) without touching
/// the real one. Each returns the OSStatus; `copy` also returns the secret.
public struct AnalysisKeychainCalls: Sendable {
    public var copy: @Sendable (_ service: String, _ account: String) -> (OSStatus, Data?)
    public var add: @Sendable (_ service: String, _ account: String, _ secret: Data) -> OSStatus
    public var delete: @Sendable (_ service: String, _ account: String) -> OSStatus

    public init(copy: @escaping @Sendable (String, String) -> (OSStatus, Data?),
                add: @escaping @Sendable (String, String, Data) -> OSStatus,
                delete: @escaping @Sendable (String, String) -> OSStatus) {
        self.copy = copy
        self.add = add
        self.delete = delete
    }

    /// The login keychain. Every query names the service and Ponte's account, so an item another app made under a
    /// different account is never read or touched.
    public static let system = AnalysisKeychainCalls(
        copy: { service, account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        add: { service, account, secret in
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: service,
                kSecValueData as String: secret,
            ]
            return SecItemAdd(add as CFDictionary, nil)
        },
        delete: { service, account in
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            return SecItemDelete(match as CFDictionary)
        })
}

/// The macOS Keychain (login keychain), one item per provider.
public final class KeychainAnalysisKeyStore: AnalysisKeyStore, @unchecked Sendable {
    public static let account = "ponte"
    private let calls: AnalysisKeychainCalls

    public init(calls: AnalysisKeychainCalls = .system) { self.calls = calls }

    /// OSStatus as AnalysisRules.kc*.
    public static func statusCode(_ status: OSStatus) -> Int {
        switch status {
        case errSecSuccess: AnalysisRules.kcOK
        case errSecItemNotFound: AnalysisRules.kcNotFound
        case errSecDuplicateItem: AnalysisRules.kcDuplicate
        default: AnalysisRules.kcOther
        }
    }

    public func stored(for provider: Int) -> AnalysisStoredKey? {
        let (status, data) = calls.copy(AnalysisRules.keychainService(provider), Self.account)
        guard status == errSecSuccess, let data else { return nil }
        return AnalysisStoredKey(payload: data)
    }

    /// Deletes Ponte's own item, then adds the new one; never updates an item in place, so a key never lands in an
    /// item someone else made. A duplicate on add is such an item (AnalysisRules.keyWriteOutcome): refused.
    public func save(_ key: String, baseURL: String, for provider: Int) throws {
        let service = AnalysisRules.keychainService(provider)
        _ = calls.delete(service, Self.account)
        let added = calls.add(service, Self.account, AnalysisStoredKey(key: key, baseURL: baseURL).payload)
        let outcome = AnalysisRules.keyWriteOutcome(added: Self.statusCode(added))
        guard outcome == AnalysisRules.saveOK else {
            throw AnalysisKeychainError(outcome: outcome, status: added, service: service)
        }
    }

    public func delete(for provider: Int) throws {
        let service = AnalysisRules.keychainService(provider)
        let status = calls.delete(service, Self.account)
        guard AnalysisRules.keyDeleteOK(deleted: Self.statusCode(status)) else {
            throw AnalysisKeychainError(outcome: AnalysisRules.saveFailed, status: status, service: service)
        }
    }
}

/// Keys in memory only: for tests and demos.
public final class MemoryAnalysisKeyStore: AnalysisKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Int: AnalysisStoredKey] = [:]

    public init(_ keys: [Int: AnalysisStoredKey] = [:]) { self.keys = keys }

    public func stored(for provider: Int) -> AnalysisStoredKey? { lock.withLock { keys[provider] } }
    public func save(_ key: String, baseURL: String, for provider: Int) throws {
        lock.withLock { keys[provider] = AnalysisStoredKey(key: key, baseURL: baseURL) }
    }
    public func delete(for provider: Int) throws { _ = lock.withLock { keys.removeValue(forKey: provider) } }
}
