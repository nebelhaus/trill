import Contacts
import Foundation

/// Resolves phone numbers and email handles to contact names.
/// Access is requested once on first use; on denial, handles display raw.
actor ContactsNameResolver {
    private var cache: [String: String]?

    func displayName(for handle: String) async -> String? {
        if cache == nil {
            cache = await buildCache()
        }
        return cache?[Self.normalize(handle)]
    }

    var authorizationHealth: HealthState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .ready
        case .notDetermined:
            return .notRequested
        case .denied, .restricted:
            return HealthState(
                availability: .limited,
                reason: .permissionMissing,
                recoverySuggestion: "Allow Contacts access to see names instead of phone numbers."
            )
        @unknown default:
            return .notRequested
        }
    }

    private func buildCache() async -> [String: String] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return [:]
        }

        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var map: [String: String] = [:]
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = contact.nickname.nonEmpty
                    ?? [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .nonEmpty
                guard let name else { return }
                for phone in contact.phoneNumbers {
                    map[Self.normalize(phone.value.stringValue)] = name
                }
                for email in contact.emailAddresses {
                    map[Self.normalize(email.value as String)] = name
                }
            }
        } catch {
            AppLog.ui.error("Contacts enumeration failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
        return map
    }

    /// Phone numbers match on their last 10 digits; emails match lowercased.
    static func normalize(_ handle: String) -> String {
        if handle.contains("@") {
            return handle.lowercased()
        }
        let digits = handle.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}
