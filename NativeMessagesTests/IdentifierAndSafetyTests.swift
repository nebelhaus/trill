import Foundation
import XCTest
@testable import NativeMessages

final class IdentifierAndSafetyTests: XCTestCase {
    func testProviderQualificationPreventsCrossProviderCollisions() {
        let fixture = ConversationID(provider: ProviderID(rawValue: "fixture"), externalGUID: "same-guid")
        let platform = ConversationID(provider: ProviderID(rawValue: "platform-imessage"), externalGUID: "same-guid")

        XCTAssertNotEqual(fixture, platform)
        XCTAssertNotEqual(fixture.persistenceKey, platform.persistenceKey)
    }

    func testPersistenceKeysRoundTripArbitraryProviderAndGUIDText() {
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "provider.with/separators"),
            externalGUID: "SMS;+1.555/💬"
        )
        let message = MessageID(
            provider: ProviderID(rawValue: "provider.with/separators"),
            externalGUID: "message.+/🦦"
        )

        XCTAssertEqual(ConversationID(persistenceKey: conversation.persistenceKey), conversation)
        XCTAssertEqual(MessageID(persistenceKey: message.persistenceKey), message)
        XCTAssertNil(ConversationID(persistenceKey: "not-a-valid-key"))
    }

    func testCapabilityGateRequiresCapabilityAndHealthySending() {
        var health = ProviderHealth.fixture
        let capable = ProviderCapabilities([.sendText])

        XCTAssertFalse(CapabilityGate.canSend(capabilities: capable, health: health))
        health.sending = .ready
        XCTAssertTrue(CapabilityGate.canSend(capabilities: capable, health: health))
        XCTAssertFalse(CapabilityGate.canSend(capabilities: ProviderCapabilities(), health: health))
    }

    func testUnknownSendOutcomesAreNeverAutomaticallyRetried() {
        let operationID = UUID()
        XCTAssertFalse(SendRetryPolicy.shouldAutomaticallyRetry(.unknown(
            operationID: operationID,
            diagnosticCode: "timeout-after-dispatch"
        )))
    }

    func testHealthMappingKeepsPermissionAndSchemaFailuresDistinct() {
        let permission = MessagesDatabaseAccessChecker.health(for: .failure(.permissionDenied))
        let schema = MessagesDatabaseAccessChecker.health(for: .failure(.unsupportedSchema))

        XCTAssertEqual(permission.reason, .permissionMissing)
        XCTAssertEqual(schema.reason, .unsupportedSchema)
        XCTAssertNotEqual(permission.recoverySuggestion, schema.recoverySuggestion)
    }
}
