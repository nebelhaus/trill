import Foundation

enum HealthAvailability: String, Codable, Sendable {
    case available
    case limited
    case unavailable
    case unknown
}

enum HealthReason: String, Codable, Sendable {
    case ready
    case fixtureMode
    case permissionMissing
    case databaseMissing
    case unsupportedSchema
    case providerFailure
    case reconnecting
    case disabled
    case notRequested
    case manualVerificationRequired
}

struct HealthState: Hashable, Codable, Sendable {
    let availability: HealthAvailability
    let reason: HealthReason
    let recoverySuggestion: String?

    static let ready = HealthState(availability: .available, reason: .ready, recoverySuggestion: nil)
    static let fixture = HealthState(availability: .available, reason: .fixtureMode, recoverySuggestion: nil)
    static let notRequested = HealthState(availability: .unknown, reason: .notRequested, recoverySuggestion: nil)
    static let disabled = HealthState(availability: .limited, reason: .disabled, recoverySuggestion: nil)
}

/// A non-primary provider that is unwell, carried alongside the aggregate health
/// rather than folded into it.
///
/// Aggregation is deliberately *not* a `min()` over the health dimensions.
/// `InboxModel.load` turns `messagesDatabase`'s failure reasons into a
/// full-screen recovery view that replaces the conversation list — correct when
/// the native provider can't read `chat.db`, catastrophic when a remote server
/// is merely unreachable. So the composite reports the **primary** child's
/// health verbatim for the blocking dimensions and lists every other unwell
/// child here, where it can degrade to a banner and a health row instead of
/// blanking the inbox.
struct ProviderDegradation: Hashable, Codable, Sendable, Identifiable {
    let providerID: ProviderID
    /// Which dimension is unwell — the one worth naming to the user.
    let state: HealthState

    var id: String { providerID.rawValue }
}

struct ProviderHealth: Hashable, Codable, Sendable {
    var messagesDatabase: HealthState
    var liveEvents: HealthState
    var sending: HealthState
    var contacts: HealthState
    var notifications: HealthState
    var remoteRelay: HealthState?
    /// Non-blocking failures from auxiliary providers. Never influences the
    /// dimensions above; see `ProviderDegradation`.
    var degraded: [ProviderDegradation]

    init(
        messagesDatabase: HealthState,
        liveEvents: HealthState,
        sending: HealthState,
        contacts: HealthState,
        notifications: HealthState,
        remoteRelay: HealthState? = nil,
        degraded: [ProviderDegradation] = []
    ) {
        self.messagesDatabase = messagesDatabase
        self.liveEvents = liveEvents
        self.sending = sending
        self.contacts = contacts
        self.notifications = notifications
        self.remoteRelay = remoteRelay
        self.degraded = degraded
    }

    static let fixture = ProviderHealth(
        messagesDatabase: .fixture,
        liveEvents: .fixture,
        sending: .disabled,
        contacts: .notRequested,
        notifications: .notRequested,
        remoteRelay: nil
    )
}

enum ProviderCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case readConversations
    case readMessages
    case search
    case watchLiveEvents
    case sendText
    case sendAttachments
    case sendStandardReactions
    case startDirectChat
    case markRead
    case createInlineReply
    case editOrUnsend
    case typingIndicators
    case groupManagement
}

struct ProviderCapabilities: Hashable, Codable, Sendable {
    private(set) var values: Set<ProviderCapability>

    init(_ values: Set<ProviderCapability> = []) {
        self.values = values
    }

    func supports(_ capability: ProviderCapability) -> Bool {
        values.contains(capability)
    }
}

enum CapabilityGate {
    static func canSend(capabilities: ProviderCapabilities, health: ProviderHealth) -> Bool {
        capabilities.supports(.sendText) && health.sending.availability == .available
    }
}

