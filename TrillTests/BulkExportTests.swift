import XCTest
@testable import Trill

final class BulkExportTests: XCTestCase {
    private let provider = ProviderID(rawValue: "fixture")

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-07-18 00:00:00 UTC.
    private let stampDate = Date(timeIntervalSince1970: 1_784_332_800)

    private func conversation(_ guid: String, name: String) -> Conversation {
        Conversation(
            id: ConversationID(provider: provider, externalGUID: guid),
            displayName: name,
            systemName: nil,
            participants: [],
            kind: .direct,
            service: .iMessage,
            lastActivity: stampDate,
            lastMessagePreview: "",
            unreadCount: nil,
            lastMessageFromMe: false,
            reactedToLatestInbound: false
        )
    }

    // MARK: - Filenames

    func testFilenamesAppendExtensionAndPreserveOrder() {
        let names = BulkExportPlanner.filenames(
            for: [conversation("a", name: "Mom"), conversation("b", name: "Alex Rivera")],
            fileExtension: "md"
        )
        XCTAssertEqual(names, ["Mom.md", "Alex Rivera.md"])
    }

    func testFilenamesDisambiguateCollisions() {
        // Two threads named "Mom" — and a third whose slash sanitizes to a space
        // and collides with "Mom Dad".
        let names = BulkExportPlanner.filenames(
            for: [
                conversation("a", name: "Mom"),
                conversation("b", name: "Mom"),
                conversation("c", name: "Mom"),
            ],
            fileExtension: "md"
        )
        XCTAssertEqual(names, ["Mom.md", "Mom 2.md", "Mom 3.md"])
        // No two files share a (case-insensitive) name.
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count)
    }

    func testFilenamesStripPathHostileCharacters() {
        let names = BulkExportPlanner.filenames(
            for: [conversation("a", name: "Design/Team: Q3")],
            fileExtension: "md"
        )
        let name = try! XCTUnwrap(names.first)
        XCTAssertFalse(name.dropLast(3).contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    func testFilenamesFallBackForEmptyName() {
        let names = BulkExportPlanner.filenames(
            for: [conversation("a", name: "   "), conversation("b", name: "")],
            fileExtension: "md"
        )
        XCTAssertEqual(names, ["Conversation 1.md", "Conversation 2.md"])
    }

    // MARK: - Index

    func testIndexLinksEachThreadWithCounts() {
        let conversations = [conversation("a", name: "Mom"), conversation("b", name: "Alex")]
        let filenames = ["Mom.md", "Alex.md"]
        let index = BulkExportPlanner.indexMarkdown(
            conversations: conversations,
            filenames: filenames,
            counts: [3, 1],
            generatedAt: stampDate
        )
        XCTAssertTrue(index.contains("# Trill Export"))
        XCTAssertTrue(index.contains("2 conversations · 4 messages"))
        XCTAssertTrue(index.contains("[Mom](Mom.md) — 3 messages"))
        XCTAssertTrue(index.contains("[Alex](Alex.md) — 1 message"))
    }

    func testIndexPercentEncodesSpacesInLinks() {
        let index = BulkExportPlanner.indexMarkdown(
            conversations: [conversation("a", name: "Design Team")],
            filenames: ["Design Team.md"],
            counts: [5],
            generatedAt: stampDate
        )
        XCTAssertTrue(index.contains("(Design%20Team.md)"), "expected an encoded link target, got: \(index)")
        XCTAssertTrue(index.contains("[Design Team]"), "link text should stay human-readable")
    }

    func testIndexHandlesEmptyExport() {
        let index = BulkExportPlanner.indexMarkdown(
            conversations: [], filenames: [], counts: [], generatedAt: stampDate
        )
        XCTAssertTrue(index.contains("0 conversations · 0 messages"))
        XCTAssertTrue(index.contains("No conversations to export."))
    }

    // MARK: - Archive stem

    func testArchiveStemIsDayStamped() {
        XCTAssertEqual(
            BulkExportPlanner.archiveStem(generatedAt: stampDate, calendar: calendar),
            "Trill Export 2026-07-18"
        )
    }
}
