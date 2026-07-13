import Foundation
import XCTest
@testable import NativeMessages

final class AppDatabaseTests: XCTestCase {
    func testMigrationsPinsDraftsAndProviderCursors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMessagesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "fixture"),
            externalGUID: "draft-and-pin"
        )

        let schemaVersion = try await database.schemaVersion()
        XCTAssertEqual(schemaVersion, AppDatabase.currentSchemaVersion)

        try await database.setPinned(true, conversationID: conversation)
        let pinned = try await database.pinnedConversationIDs()
        XCTAssertEqual(pinned, [conversation])
        try await database.setPinned(false, conversationID: conversation)
        let unpinned = try await database.pinnedConversationIDs()
        XCTAssertTrue(unpinned.isEmpty)

        try await database.saveDraft("unsent synthetic draft", conversationID: conversation)
        let savedDraft = try await database.draft(conversationID: conversation)
        XCTAssertEqual(savedDraft, "unsent synthetic draft")
        try await database.saveDraft("", conversationID: conversation)
        let clearedDraft = try await database.draft(conversationID: conversation)
        XCTAssertEqual(clearedDraft, "")

        let provider = ProviderID(rawValue: "fixture")
        try await database.saveCursor(EventCursor(rawValue: "cursor-42"), providerID: provider)
        let cursor = try await database.cursor(providerID: provider)
        XCTAssertEqual(cursor?.rawValue, "cursor-42")
    }
}
