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

