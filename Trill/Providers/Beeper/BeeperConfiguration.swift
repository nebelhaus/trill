import Foundation

/// Where the Beeper Server is and how to authenticate to it.
///
/// The endpoint is an ordinary preference; the token is a secret and lives only
/// in the Keychain. Loopback is the default and the expected deployment — a
/// non-loopback endpoint is a network boundary, so it must be HTTPS with normal
/// certificate validation (no pinning bypass, no ATS exception). Same rules
/// `ARCHITECTURE.md §11.3` already writes for a remote relay.
struct BeeperConfiguration: Sendable {
    static let defaultEndpoint = URL(string: "http://127.0.0.1:23373")!
    static let endpointDefaultsKey = "beeperEndpoint"
    static let keychainAccount = "beeper.accessToken"

    let endpoint: URL
    let accessToken: String

    enum Problem: LocalizedError, Sendable {
        case notConfigured
        case insecureRemoteEndpoint

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "No Beeper access token is configured."
            case .insecureRemoteEndpoint:
                "A non-local Beeper endpoint must use HTTPS."
            }
        }
    }

    /// Loopback hosts may use plain HTTP: the traffic never leaves the machine,
    /// and the headless Server serves HTTP there by default.
    static func isLoopback(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1", "[::1]": true
        default: false
        }
    }

    static func validate(endpoint: URL) throws {
        guard isLoopback(endpoint) || endpoint.scheme?.lowercased() == "https" else {
            throw Problem.insecureRemoteEndpoint
        }
    }

    init(endpoint: URL, accessToken: String) throws {
        try Self.validate(endpoint: endpoint)
        self.endpoint = endpoint
        self.accessToken = accessToken
    }
}

/// How `BeeperProvider` obtains its configuration. A protocol so tests can
/// supply one without touching `UserDefaults` or the real Keychain.
protocol BeeperConfigurationProviding: Sendable {
    /// Nil when Beeper simply isn't set up — a normal state, not a failure.
    func current() throws -> BeeperConfiguration?
}

/// Resolves the configuration at call time rather than caching it, so a token
/// pasted (or revoked) mid-session takes effect without a relaunch.
struct BeeperConfigurationSource: BeeperConfigurationProviding, @unchecked Sendable {
    /// `UserDefaults` isn't `Sendable`, but it is documented thread-safe and this
    /// only ever reads one string from it.
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var endpoint: URL {
        defaults.string(forKey: BeeperConfiguration.endpointDefaultsKey)
            .flatMap(URL.init(string:))
            ?? BeeperConfiguration.defaultEndpoint
    }

    func current() throws -> BeeperConfiguration? {
        guard let token = try keychain.string(for: BeeperConfiguration.keychainAccount),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return try BeeperConfiguration(endpoint: endpoint, accessToken: token)
    }
}
