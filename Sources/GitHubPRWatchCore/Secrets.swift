import Foundation
import os
import Security

/// Where device-flow and pasted tokens are kept. The GitHub CLI's token never goes here.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Stores `value`, or deletes the item when `value` is empty.
    @discardableResult
    func write(_ value: String, for key: String) -> Bool
}

public enum SecretKeys {
    /// The token from the device flow or a pasted token.
    public static let githubToken = "github.token"
}

/// Generic-password items under the app's own service name.
public struct KeychainSecrets: SecretStore {
    public static let service = "dev.lubelski.GitHubPRWatch"

    public init() {}

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    public func write(_ value: String, for key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

/// Keeps secrets in memory. For tests and windowless renders.
public final class InMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func read(_ key: String) -> String? {
        lock.withLock { values[key] }
    }

    @discardableResult
    public func write(_ value: String, for key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { values[key] = trimmed.isEmpty ? nil : trimmed }
        return true
    }
}
