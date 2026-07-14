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

        let markedAt = Date(timeIntervalSince1970: 1_750_000_000)
        try await database.setReadMark(markedAt, conversationID: conversation)
        let marks = try await database.readMarks()
        XCTAssertEqual(marks[conversation]?.timeIntervalSince1970 ?? 0, markedAt.timeIntervalSince1970, accuracy: 0.001)
        let laterMark = markedAt.addingTimeInterval(60)
        try await database.setReadMark(laterMark, conversationID: conversation)
        let updatedMarks = try await database.readMarks()
        XCTAssertEqual(updatedMarks.count, 1)
        XCTAssertEqual(updatedMarks[conversation]?.timeIntervalSince1970 ?? 0, laterMark.timeIntervalSince1970, accuracy: 0.001)
    }
}
