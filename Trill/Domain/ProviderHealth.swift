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

struct ProviderHealth: Hashable, Codable, Sendable {
    var messagesDatabase: HealthState
    var liveEvents: HealthState
    var sending: HealthState
    var contacts: HealthState
    var notifications: HealthState
    var remoteRelay: HealthState?
    /// Readiness of the write-backed advanced actions (tapbacks, and later
    /// replies/edits/mark-read) delegated to a vetted third-party library over an
    /// Accessibility surface — a permission dimension distinct from `sending`
    /// (Apple Events text send). `nil` for providers with no such backend (the
    /// default), so the read-only baseline is unchanged. Defaulted so existing
    /// memberwise-init call sites keep compiling.
    var advancedActions: HealthState? = nil

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

    /// Tapbacks enable only when the provider advertises the capability AND the
    /// write-backed advanced-actions surface is live — the same capability+health
    /// pairing `canSend` uses, but keyed to the Accessibility-backed dimension.
    static func canReact(capabilities: ProviderCapabilities, health: ProviderHealth) -> Bool {
        capabilities.supports(.sendStandardReactions)
            && health.advancedActions?.availability == .available
    }
}

