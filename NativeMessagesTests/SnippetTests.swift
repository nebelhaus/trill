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

final class CompletionRankingTests: XCTestCase {
    private let snippets = [
        Snippet(title: "omw", body: "On my way!"),
        Snippet(title: "brb", body: "Be right back."),
        Snippet(title: "ty", body: "Thank you!"),
        Snippet(title: "blank", body: ""),
    ]

    private func snippetMatches(query: String) -> [Snippet] {
        CompletionRanking.matches(query: query, commands: [], snippets: snippets)
            .compactMap { if case let .snippet(snippet) = $0 { snippet } else { nil } }
    }

    func testEmptyQueryListsUsableSnippetsAlphabetically() {
        let matches = snippetMatches(query: "")
        XCTAssertEqual(matches.map(\.title), ["brb", "omw", "ty"])
    }

    func testFuzzyRanksByKeyword() {
        XCTAssertEqual(snippetMatches(query: "omw").first?.title, "omw")
    }

    func testMatchesAgainstBody() {
        XCTAssertEqual(snippetMatches(query: "thank").first?.title, "ty")
    }

    func testSkipsSnippetsWithoutBody() {
        XCTAssertTrue(snippetMatches(query: "blank").isEmpty)
    }

    func testEmptyQueryBlendsCommandsAndSnippetsAlphabetically() {
        let matches = CompletionRanking.matches(
            query: "",
            commands: [SlashCommand(keyword: "date", expansion: .date)],
            snippets: [Snippet(title: "omw", body: "On my way!")]
        )
        XCTAssertEqual(matches.map(\.title), ["date", "omw"])
    }

    func testQueryFindsBuiltInCommand() {
        let matches = CompletionRanking.matches(
            query: "shr",
            commands: SlashCommand.all,
            snippets: snippets
        )
        XCTAssertEqual(matches.first?.title, "shrug")
        XCTAssertTrue(matches.first?.isCommand == true)
    }
}

final class SlashCommandTests: XCTestCase {
    func testLiteralExpandsToFixedText() {
        let shrug = SlashCommand.all.first { $0.keyword == "shrug" }
        XCTAssertEqual(shrug?.expand(), #"¯\_(ツ)_/¯"#)
    }

    func testDateExpandsAgainstProvidedClock() {
        let command = SlashCommand(keyword: "date", expansion: .date)
        let reference = Date(timeIntervalSince1970: 0)
        let expected = DateFormatter.localizedString(from: reference, dateStyle: .long, timeStyle: .none)
        XCTAssertEqual(command.expand(now: reference), expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testCommandItemNeverFillsAndCarriesExpansion() {
        let command = SlashCommand(keyword: "shrug", expansion: .literal("x"))
        let item = CompletionItem.command(command)
        XCTAssertTrue(item.isCommand)
        XCTAssertFalse(item.isTemplate)
        XCTAssertEqual(item.resolvedText(), "x")
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
