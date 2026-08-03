import Foundation

/// The network — and, where it matters, the *account* — a conversation or
/// message belongs to.
///
/// Replaces the closed `MessageServiceKind` enum. `key` is any stable string, so
/// "WhatsApp", "Signal", and *two different Signal accounts* are three distinct
/// filterable identities rather than three things that don't fit in an enum. The
/// well-known constants below keep iMessage/SMS/RCS reading exactly as they did.
///
/// `key` is persisted (the sidebar's hidden-service list) and must therefore
/// never change for a given account — see `ServiceIdentity.migratedLegacyKey`
/// for the one time it did.
struct ServiceIdentity: Hashable, Codable, Sendable, Identifiable {
    /// Stable, filterable identity. Unique per network *and* account.
    let key: String
    /// What the chip and the service filter menu show ("iMessage", "WhatsApp").
    let displayName: String
    /// Network family, shared by every account on it. Drives the chip color, so
    /// two Signal accounts read as one color carrying two labels.
    let networkKey: String
    /// The owning account, when a network can have more than one. Nil for the
    /// native services and for any network reporting a single account.
    let accountID: String?

    var id: String { key }

    init(key: String, displayName: String, networkKey: String, accountID: String? = nil) {
        self.key = key
        self.displayName = displayName
        self.networkKey = networkKey
        self.accountID = accountID
    }

    /// Identity for one account on a network. The key folds the account in only
    /// when there is one, so a single-account network keeps the bare network key
    /// (and a user who later adds a second account doesn't have the first one's
    /// filter state re-keyed out from under them until they say so).
    init(network: String, displayName: String, accountID: String?) {
        self.init(
            key: accountID.map { "\(network):\($0)" } ?? network,
            displayName: displayName,
            networkKey: network,
            accountID: accountID
        )
    }

    // MARK: - Well-known services

    /// The native services. Their `key`s are lowercased (the legacy enum spelled
    /// iMessage's with a capital M) so every key in the system reads the same
    /// way; `migratedLegacyKey` carries existing filter state across.
    static let iMessage = ServiceIdentity(key: "imessage", displayName: "iMessage", networkKey: "imessage")
    static let sms = ServiceIdentity(key: "sms", displayName: "SMS", networkKey: "sms")
    static let rcs = ServiceIdentity(key: "rcs", displayName: "RCS", networkKey: "rcs")
    /// The catch-all. Never offered in the filter menu and never hidden, so a
    /// thread we couldn't classify can't vanish behind a filter nobody can see.
    static let unknown = ServiceIdentity(key: "unknown", displayName: "Chat", networkKey: "unknown")

    /// Menu order for the natives; dynamic services sort after them by label.
    static let wellKnown: [ServiceIdentity] = [.iMessage, .sms, .rcs]

    var isUnknown: Bool { key == ServiceIdentity.unknown.key }

    /// Whether the user is allowed to hide this service. Mirrors the old
    /// `MessageServiceKind.togglable` exclusion of `.unknown`.
    var isTogglable: Bool { !isUnknown }

    /// Maps a `MessageServiceKind` raw value persisted before this type existed
    /// onto its current key. Returns the input unchanged for anything already in
    /// the new spelling, so the migration is idempotent.
    static func migratedLegacyKey(_ stored: String) -> String {
        switch stored {
        case "iMessage": ServiceIdentity.iMessage.key
        case "sms": ServiceIdentity.sms.key
        case "rcs": ServiceIdentity.rcs.key
        case "unknown": ServiceIdentity.unknown.key
        default: stored
        }
    }

    /// Reads the sidebar's persisted hidden-service CSV, migrating in place from
    /// the `MessageServiceKind` raw values it used to hold. On read and
    /// idempotent, so an existing filter survives the upgrade without a schema
    /// change — this list lives in `UserDefaults`, not in `AppDatabase`.
    /// `.unknown` is dropped: it was never togglable and a stale stored value
    /// must not make it hideable now.
    static func migratedHiddenServices(csv raw: String) -> Set<String> {
        Set(
            raw.split(separator: ",")
                .map { migratedLegacyKey(String($0)) }
                .filter { $0 != ServiceIdentity.unknown.key }
        )
    }
}
