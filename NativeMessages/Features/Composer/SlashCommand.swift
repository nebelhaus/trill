import Foundation

/// A built-in `/`-command: a keyword the composer expands to text on the spot,
/// living in the same `/`-trigger picker as the user's snippets. Unlike a
/// snippet, its output is code-defined and can be dynamic (`/date` resolves to
/// today), so it carries an `Expansion` resolved at insert time rather than a
/// stored body. No table, no migration — the set ships with the app.
struct SlashCommand: Identifiable, Hashable, Sendable {
    let keyword: String
    let expansion: Expansion
    var id: String { keyword }

    enum Expansion: Hashable, Sendable {
        /// Fixed text — kaomoji and the like.
        case literal(String)
        /// Localized current date, e.g. "July 17, 2026".
        case date
        /// Localized current time, e.g. "3:42 PM".
        case time
    }

    /// The text inserted when the command is picked, resolved against `now` so
    /// dynamic commands read the clock at insert time rather than at trigger.
    func expand(now: Date = Date()) -> String {
        switch expansion {
        case let .literal(text): text
        case .date: DateFormatter.localizedString(from: now, dateStyle: .long, timeStyle: .none)
        case .time: DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        }
    }

    /// A short peek at what the command inserts, shown dim beside its `/keyword`
    /// in the picker. For literals it's the output itself; for dynamic commands
    /// it's a live sample resolved against `now`.
    func preview(now: Date = Date()) -> String { expand(now: now) }

    /// The built-in command set, offered on every `/`-trigger. Kaomoji use raw
    /// string literals so their backslashes stay literal.
    static let all: [SlashCommand] = [
        SlashCommand(keyword: "shrug", expansion: .literal(#"¯\_(ツ)_/¯"#)),
        SlashCommand(keyword: "flip", expansion: .literal("(╯°□°)╯︵ ┻━┻")),
        SlashCommand(keyword: "unflip", expansion: .literal("┬─┬ ノ( ゜-゜ノ)")),
        SlashCommand(keyword: "lenny", expansion: .literal("( ͡° ͜ʖ ͡°)")),
        SlashCommand(keyword: "date", expansion: .date),
        SlashCommand(keyword: "time", expansion: .time),
    ]
}

/// One row in the composer's `/`-trigger picker: either a built-in slash command
/// or one of the user's snippets. Both fuzzy-rank together and insert on pick;
/// the only differences are what text lands (a command expands, a snippet copies
/// its body) and whether a template fill session follows (snippets only).
enum CompletionItem: Identifiable, Hashable {
    case command(SlashCommand)
    case snippet(Snippet)

    var id: String {
        switch self {
        case let .command(command): "cmd:" + command.id
        case let .snippet(snippet): "snip:" + snippet.id
        }
    }

    /// The keyword rendered as `/title`.
    var title: String {
        switch self {
        case let .command(command): command.keyword
        case let .snippet(snippet): snippet.title
        }
    }

    /// The dim preview text shown beside the title.
    var preview: String {
        switch self {
        case let .command(command): command.preview()
        case let .snippet(snippet): snippet.body
        }
    }

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    /// Whether picking begins a fill session — true only for snippets whose body
    /// carries `{blank}` markers. Commands never fill.
    var isTemplate: Bool {
        switch self {
        case .command: false
        case let .snippet(snippet): MessageTemplate.hasPlaceholders(snippet.body)
        }
    }

    /// The text this item inserts when picked, resolved against `now` (commands
    /// only — a snippet's body is fixed).
    func resolvedText(now: Date = Date()) -> String {
        switch self {
        case let .command(command): command.expand(now: now)
        case let .snippet(snippet): snippet.body
        }
    }
}

/// Pure ranking for the composer's `/`-trigger picker, merging built-in commands
/// with the user's snippets into one list. Empty query lists everything usable
/// alphabetically; a non-empty query fuzzy-ranks both together, best first. Kept
/// out of the view so it's unit testable.
enum CompletionRanking {
    static let limit = 8

    static func matches(
        query: String,
        commands: [SlashCommand],
        snippets: [Snippet]
    ) -> [CompletionItem] {
        let items = commands.map(CompletionItem.command)
            + snippets.filter(\.isUsable).map(CompletionItem.snippet)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(
                items.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(limit)
            )
        }
        var scored: [(item: CompletionItem, score: Int)] = []
        for item in items {
            if let score = FuzzyMatch.bestScore(trimmed, haystacks(for: item)) {
                scored.append((item, score))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.item.title < rhs.item.title
        }
        return scored.prefix(limit).map(\.item)
    }

    /// A command matches on its keyword alone; a snippet also matches its body so
    /// "thank" can find a `ty` snippet.
    private static func haystacks(for item: CompletionItem) -> [String] {
        switch item {
        case let .command(command): [command.keyword]
        case let .snippet(snippet): [snippet.title, snippet.body]
        }
    }
}
