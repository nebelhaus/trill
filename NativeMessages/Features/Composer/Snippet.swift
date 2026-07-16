import Foundation

/// A reusable canned response. `title` is the keyword you fuzzy-match against a
/// `/`-trigger in the composer; `body` is the text inserted when you pick it.
/// Snippets are global (not per-conversation) and live entirely in `AppDatabase`
/// — no chat.db write, same overlay pattern as pins and drafts.
struct Snippet: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var body: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, body: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }

    /// A snippet the picker can offer: it needs a keyword to trigger on and text
    /// to insert. Blank drafts left in Settings simply never surface.
    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.isEmpty
    }
}

/// Detects a `/`-trigger token at the end of the composer text. A trigger is the
/// trailing whitespace-delimited token when it starts with `/` — so `"/omw"`,
/// `"hey /om"` both match, while `"http://x"` (no leading `/` on the token) and
/// `"/omw "` (space closes the token) do not. Pure and caret-free: typing lands
/// at the end, so the trailing token is the one being written.
enum SnippetTrigger {
    struct Match: Equatable {
        /// Range of the whole `/token` in the source string, replaced on commit.
        let range: Range<String.Index>
        /// The text after the slash, fuzzy-matched against snippet keywords.
        let query: String
    }

    static func parse(_ text: String) -> Match? {
        guard !text.isEmpty else { return nil }
        let tokenStart: String.Index
        if let lastBoundary = text.lastIndex(where: { $0.isWhitespace }) {
            tokenStart = text.index(after: lastBoundary)
        } else {
            tokenStart = text.startIndex
        }
        guard tokenStart < text.endIndex, text[tokenStart] == "/" else { return nil }
        let queryStart = text.index(after: tokenStart)
        return Match(
            range: tokenStart..<text.endIndex,
            query: String(text[queryStart...])
        )
    }
}

/// Pure ranking for the snippet picker, kept out of the view so it's unit
/// testable. Empty query lists every usable snippet alphabetically; a non-empty
/// query fuzzy-ranks keyword and body together, best first.
enum SnippetRanking {
    static let limit = 8

    static func matches(query: String, snippets: [Snippet]) -> [Snippet] {
        let usable = snippets.filter(\.isUsable)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(
                usable.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(limit)
            )
        }
        var scored: [(snippet: Snippet, score: Int)] = []
        for snippet in usable {
            if let score = FuzzyMatch.bestScore(trimmed, [snippet.title, snippet.body]) {
                scored.append((snippet, score))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.snippet.title < rhs.snippet.title
        }
        return scored.prefix(limit).map(\.snippet)
    }
}
