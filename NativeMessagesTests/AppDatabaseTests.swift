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

    func testVIPMembership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMessagesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))

        let provider = ProviderID(rawValue: "fixture")
        let alice = ConversationID(provider: provider, externalGUID: "alice")
        let bob = ConversationID(provider: provider, externalGUID: "bob")

        var vips = try await database.vipConversationIDs()
        XCTAssertTrue(vips.isEmpty)

        try await database.setVIP(true, conversationID: alice)
        try await database.setVIP(true, conversationID: bob)
        vips = try await database.vipConversationIDs()
        XCTAssertEqual(vips, [alice, bob])

        // Setting VIP twice is idempotent (INSERT OR REPLACE).
        try await database.setVIP(true, conversationID: alice)
        vips = try await database.vipConversationIDs()
        XCTAssertEqual(vips, [alice, bob])

        try await database.setVIP(false, conversationID: alice)
        vips = try await database.vipConversationIDs()
        XCTAssertEqual(vips, [bob])
    }

    func testFoldersAndMembership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMessagesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))

        let version = try await database.schemaVersion()
        XCTAssertEqual(version, AppDatabase.currentSchemaVersion)
        XCTAssertEqual(AppDatabase.currentSchemaVersion, 9)

        let provider = ProviderID(rawValue: "fixture")
        let alice = ConversationID(provider: provider, externalGUID: "alice")
        let bob = ConversationID(provider: provider, externalGUID: "bob")

        // Insert two folders and confirm they read back in sort order.
        let work = Folder(id: UUID().uuidString, name: "Work", colorName: "blue", sortOrder: 1)
        let family = Folder(id: UUID().uuidString, name: "Family", colorName: "green", sortOrder: 2)
        try await database.insertFolder(work, createdAt: Date())
        try await database.insertFolder(family, createdAt: Date())
        let loaded = try await database.folders()
        XCTAssertEqual(loaded.map(\.name), ["Work", "Family"])
        XCTAssertEqual(loaded.first?.colorName, "blue")

        // Alice is in both folders; Bob only in Work.
        try await database.setFolderMembership(folderID: work.id, conversationID: alice, member: true)
        try await database.setFolderMembership(folderID: family.id, conversationID: alice, member: true)
        try await database.setFolderMembership(folderID: work.id, conversationID: bob, member: true)
        var members = try await database.folderMembers()
        XCTAssertEqual(members[work.id], [alice, bob])
        XCTAssertEqual(members[family.id], [alice])

        // Rename + recolor round-trips.
        try await database.updateFolder(id: work.id, name: "Job", colorName: "peach")
        let afterRename = try await database.folders()
        let renamed = afterRename.first { $0.id == work.id }
        XCTAssertEqual(renamed?.name, "Job")
        XCTAssertEqual(renamed?.colorName, "peach")

        // Removing one membership leaves the others intact.
        try await database.setFolderMembership(folderID: work.id, conversationID: bob, member: false)
        members = try await database.folderMembers()
        XCTAssertEqual(members[work.id], [alice])

        // Deleting a folder removes it and cascades its membership rows.
        try await database.deleteFolder(id: work.id)
        let afterDelete = try await database.folders()
        XCTAssertEqual(afterDelete.map(\.id), [family.id])
        members = try await database.folderMembers()
        XCTAssertNil(members[work.id])
        XCTAssertEqual(members[family.id], [alice])
    }

    func testLinkPreviewCacheRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMessagesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))

        // Unknown URL → nil, signalling "never fetched" so the loader hits the network.
        let missing = try await database.linkPreview(forURL: "https://none.example")
        XCTAssertNil(missing)

        // A full preview survives the round-trip.
        let rich = LinkPreview(
            title: "Title",
            summary: "Summary",
            imageURL: URL(string: "https://cdn.example/a.jpg"),
            siteName: "Example"
        )
        try await database.saveLinkPreview(rich, forURL: "https://example.com/a")
        let loaded = try await database.linkPreview(forURL: "https://example.com/a")
        XCTAssertEqual(loaded, rich)

        // An empty preview persists as a real (non-nil) row so we don't refetch a
        // page that has no metadata — but it reads back as empty.
        try await database.saveLinkPreview(.empty, forURL: "https://bare.example")
        let empty = try await database.linkPreview(forURL: "https://bare.example")
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.isEmpty, true)
    }
}
