import Foundation
import XCTest
@testable import NativeMessages

final class SnippetTriggerTests: XCTestCase {
    func testTriggersOnLeadingSlash() {
        let text = "/omw"
        let match = SnippetTrigger.parse(text)
        XCTAssertEqual(match?.query, "omw")
        XCTAssertEqual(match.map { String(text[$0.range]) }, "/omw")
    }

    func testTriggersMidTextAfterWhitespace() {
        let text = "hey there /om"
        let match = SnippetTrigger.parse(text)
        XCTAssertEqual(match?.query, "om")
        XCTAssertEqual(match.map { String(text[$0.range]) }, "/om")
    }

    func testBareSlashMatchesWithEmptyQuery() {
        let match = SnippetTrigger.parse("/")
        XCTAssertEqual(match?.query, "")
    }

    func testWhitespaceAfterSlashClosesTheToken() {
        XCTAssertNil(SnippetTrigger.parse("/omw "))
        XCTAssertNil(SnippetTrigger.parse("/omw now"))
    }

    func testNoTriggerWithoutLeadingSlashOnToken() {
        XCTAssertNil(SnippetTrigger.parse("check http://example.com"))
        XCTAssertNil(SnippetTrigger.parse("no slash here"))
        XCTAssertNil(SnippetTrigger.parse(""))
    }
}

final class SnippetRankingTests: XCTestCase {
    private let snippets = [
        Snippet(title: "omw", body: "On my way!"),
        Snippet(title: "brb", body: "Be right back."),
        Snippet(title: "ty", body: "Thank you!"),
        Snippet(title: "blank", body: ""),
    ]

    func testEmptyQueryListsUsableSnippetsAlphabetically() {
        let matches = SnippetRanking.matches(query: "", snippets: snippets)
        XCTAssertEqual(matches.map(\.title), ["brb", "omw", "ty"])
    }

    func testFuzzyRanksByKeyword() {
        let matches = SnippetRanking.matches(query: "omw", snippets: snippets)
        XCTAssertEqual(matches.first?.title, "omw")
    }

    func testMatchesAgainstBody() {
        let matches = SnippetRanking.matches(query: "thank", snippets: snippets)
        XCTAssertEqual(matches.first?.title, "ty")
    }

    func testSkipsSnippetsWithoutBody() {
        let matches = SnippetRanking.matches(query: "blank", snippets: snippets)
        XCTAssertTrue(matches.isEmpty)
    }
}

final class SnippetDatabaseTests: XCTestCase {
    func testSnippetCRUDAndMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMessagesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))

        let schemaVersion = try await database.schemaVersion()
        XCTAssertEqual(schemaVersion, AppDatabase.currentSchemaVersion)
        let empty = try await database.snippets()
        XCTAssertTrue(empty.isEmpty)

        let snippet = Snippet(id: "s1", title: "omw", body: "On my way!")
        try await database.upsertSnippet(snippet)
        let loaded = try await database.snippets()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "omw")
        XCTAssertEqual(loaded.first?.body, "On my way!")

        try await database.upsertSnippet(Snippet(id: "s1", title: "omw", body: "Heading over now."))
        let updated = try await database.snippets()
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.body, "Heading over now.")

        try await database.upsertSnippet(Snippet(id: "s2", title: "brb", body: "Back soon."))
        let ordered = try await database.snippets()
        XCTAssertEqual(ordered.map(\.title), ["brb", "omw"]) // ORDER BY title COLLATE NOCASE

        try await database.deleteSnippet(id: "s1")
        let remaining = try await database.snippets()
        XCTAssertEqual(remaining.map(\.id), ["s2"])
    }
}
