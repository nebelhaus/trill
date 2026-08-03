import Foundation
import Security

/// Minimal generic-password wrapper — the app's only secret store.
///
/// Credentials never go in `UserDefaults`: it's world-readable within the user
/// account, it lands in backups and sync, and it's trivially dumped. The endpoint
/// URL is fine there; the token is not (`docs/security.md`).
///
/// Values are stored with `kSecAttrAccessibleAfterFirstUnlock` so a token stays
/// readable for a background poll after the user has unlocked once, but never
/// while the device is locked.
struct KeychainStore: Sendable {
    enum Failure: LocalizedError, Sendable {
        /// Carries the OSStatus, which is a non-content diagnostic code.
        case unhandled(OSStatus)
        case malformedValue

        var errorDescription: String? {
            switch self {
            case .unhandled: "The keychain could not be read or written."
            case .malformedValue: "The stored credential could not be decoded."
            }
        }
    }

    let service: String

    init(service: String = "com.nebelhaus.trill") {
        self.service = service
    }

    func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw Failure.malformedValue
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unhandled(status)
        }
    }

    /// Upserts, or deletes when `value` is nil. Deleting something that isn't
    /// there is a success, not an error — callers shouldn't have to know.
    func set(_ value: String?, for account: String) throws {
        let query = baseQuery(account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.unhandled(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unhandled(addStatus) }
        default:
            throw Failure.unhandled(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
