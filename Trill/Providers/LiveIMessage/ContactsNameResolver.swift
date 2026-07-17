import Contacts
import Foundation

/// Resolves phone/email handles to contact names and thumbnail photos.
///
/// `prepare()` requests access (prompting once) and snapshots the contact
/// store into a lookup keyed by normalized handle. The snapshot rebuilds
/// whenever the authorization status changes, so granting access later and
/// hitting Recheck picks names up without a relaunch.
actor ContactsNameResolver {
    private struct Entry {
        let name: String
        let thumbnail: Data?
    }

    private var cache: [String: Entry] = [:]
    /// Name-sorted contact list with original (unnormalized) handles, for
    /// compose autocomplete. Original formatting matters when addressing
    /// Messages.app directly.
    private var directory: [ContactSuggestion] = []
    private var cachedStatus: CNAuthorizationStatus?
    private(set) var usesFallback = false

    func prepare() async {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                AppLog.ui.error("Contacts access request failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status != cachedStatus else { return }
        cachedStatus = status
        if status == .authorized {
            (cache, directory) = Self.buildCache()
            usesFallback = false
        } else {
            // Without framework access, fall back to reading the AddressBook
            // stores directly — Full Disk Access covers them. Names only.
            cache = AddressBookReader.nameByHandle().mapValues { Entry(name: $0, thumbnail: nil) }
            directory = cache
                .map { ContactSuggestion(name: $0.value.name, handle: $0.key) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            usesFallback = true
        }
        AppLog.ui.info("Contacts cache rebuilt status=\(String(describing: status.rawValue), privacy: .public) fallback=\(self.usesFallback, privacy: .public) entries=\(self.cache.count, privacy: .public)")
    }

    func displayName(for handle: String) -> String? {
        cache[Self.normalize(handle)]?.name
    }

    func thumbnail(for handle: String) -> Data? {
        cache[Self.normalize(handle)]?.thumbnail
    }

    func suggestions(matching term: String, limit: Int = 8) -> [ContactSuggestion] {
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var result: [ContactSuggestion] = []
        for entry in directory where result.count < limit {
            if entry.name.lowercased().contains(needle) || entry.handle.lowercased().contains(needle) {
                result.append(entry)
            }
        }
        return result
    }

    var authorizationHealth: HealthState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .ready
        case .notDetermined, .denied, .restricted:
            if usesFallback, !cache.isEmpty {
                return HealthState(
                    availability: .limited,
                    reason: .ready,
                    recoverySuggestion: "Names come from the local address book; grant Contacts access for photos."
                )
            }
            return HealthState(
                availability: .limited,
                reason: .permissionMissing,
                recoverySuggestion: "Allow Contacts access to see names and photos instead of phone numbers."
            )
        @unknown default:
            return .notRequested
        }
    }

    private static func buildCache() -> ([String: Entry], [ContactSuggestion]) {
        let store = CNContactStore()
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var map: [String: Entry] = [:]
        var directory: [ContactSuggestion] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = contact.nickname.nonEmpty
                    ?? [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .nonEmpty
                    ?? contact.organizationName.nonEmpty
                guard let name else { return }
                let entry = Entry(name: name, thumbnail: contact.thumbnailImageData)
                for phone in contact.phoneNumbers {
                    map[normalize(phone.value.stringValue)] = entry
                    directory.append(ContactSuggestion(name: name, handle: phone.value.stringValue))
                }
                for email in contact.emailAddresses {
                    map[normalize(email.value as String)] = entry
                    directory.append(ContactSuggestion(name: name, handle: email.value as String))
                }
            }
        } catch {
            AppLog.ui.error("Contacts enumeration failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
        directory.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (map, directory)
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
