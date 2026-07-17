import Foundation

/// Pure parser + predicate for advanced search operators, kept out of the
/// providers so it can be unit-tested directly over fixtures (mirrors
/// `NeedsReply` / `PaletteRanking`).
///
/// A raw search string like `weekend from:avery in:group has:image before:2025-02-01`
/// splits into structured `SearchFilters` plus the residual free text
/// (`"weekend"`). Both the fixture and live providers parse once at the query
/// boundary and then apply the *same* `MessageSearchQuery.matches` predicate, so
/// operators behave identically no matter which backend answers.
///
/// Supported operators (all AND together, case-insensitive keys):
/// - `from:<name>` — sender contact name/handle, or `me`/`you` for my messages.
/// - `in:group` / `in:direct` — conversation kind.
/// - `has:link` / `has:image` / `has:attachment` (aliases below).
/// - `is:unread` — incoming message in a thread with unread messages.
/// - `before:YYYY-MM-DD` / `after:YYYY-MM-DD` — UTC day boundaries.
///
/// Unrecognized `key:value` tokens (e.g. `foo:bar`) are left as free text so
/// they still search literally. A recognized key with an unparseable value
/// (e.g. `before:soon`) is dropped rather than searched literally. Values may be
/// double-quoted to include spaces: `from:"Avery Chen"`.
enum SearchQueryParser {
    private static let knownKeys: Set<String> = ["from", "in", "has", "is", "before", "after"]

    static func parse(_ raw: String) -> (text: String, filters: SearchFilters) {
        var filters = SearchFilters()
        var freeTokens: [String] = []

        for token in tokenize(raw) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                freeTokens.append(token)
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            guard knownKeys.contains(key), !value.isEmpty else {
                freeTokens.append(token)
                continue
            }
            apply(key: key, value: value, to: &filters)
        }

        let text = freeTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (text, filters)
    }

    // MARK: - Tokenizing

    /// Splits on whitespace, but a double-quoted run stays one token so
    /// `from:"Avery Chen"` and `"weekend plans"` survive intact.
    private static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in string {
            if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Operators

    private static func apply(key: String, value: String, to filters: inout SearchFilters) {
        let lowered = value.lowercased()
        switch key {
        case "from":
            filters.sender = value
        case "in":
            switch lowered {
            case "group", "groups": filters.conversationKind = .group
            case "direct", "dm", "solo", "1:1": filters.conversationKind = .direct
            default: break
            }
        case "has":
            switch lowered {
            case "link", "links", "url", "urls": filters.requiresLink = true
            case "image", "images", "img", "photo", "photos", "pic", "pics": filters.requiresImage = true
            case "attachment", "attachments", "file", "files", "attach": filters.requiresAttachment = true
            default: break
            }
        case "is":
            if lowered == "unread" { filters.unreadOnly = true }
        case "after":
            if let date = parseDate(value) { filters.after = date }
        case "before":
            if let date = parseDate(value) { filters.before = date }
        default:
            break
        }
    }

    /// `YYYY-MM-DD` interpreted at the UTC start of that day, so date filters are
    /// deterministic regardless of the machine's time zone.
    static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension MessageSearchQuery {
    /// Parse a raw search string (operators + free text) into a query the
    /// providers can run directly.
    init(raw: String, conversationID: ConversationID? = nil, limit: Int = 50, cursor: String? = nil) {
        let parsed = SearchQueryParser.parse(raw)
        self.init(
            text: parsed.text,
            conversationID: conversationID,
            limit: limit,
            cursor: cursor,
            filters: parsed.filters
        )
    }

    /// The single predicate both providers apply to each candidate message. The
    /// `conversation` supplies thread-level context (`in:` kind, `is:unread`
    /// count); pass nil when unknown and those filters simply won't match.
    func matches(_ message: Message, in conversation: Conversation?) -> Bool {
        if !text.isEmpty, !message.text.localizedCaseInsensitiveContains(text) { return false }
        return filters.matches(message, in: conversation)
    }
}

extension SearchFilters {
    func matches(_ message: Message, in conversation: Conversation?) -> Bool {
        if let sender, !SearchMatching.senderMatches(message, query: sender) { return false }
        if let conversationKind, conversation?.kind != conversationKind { return false }
        if requiresLink, !SearchMatching.containsLink(message.text) { return false }
        if requiresImage, !message.attachments.contains(where: \.isImage) { return false }
        if requiresAttachment, message.attachments.isEmpty { return false }
        if unreadOnly {
            guard !message.isOutgoing, (conversation?.unreadCount ?? 0) > 0 else { return false }
        }
        if let after, message.createdAt < after { return false }
        if let before, message.createdAt >= before { return false }
        return true
    }
}

/// Small matching primitives shared by the filter predicate.
enum SearchMatching {
    static func senderMatches(_ message: Message, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if message.isOutgoing {
            return ["me", "myself", "you"].contains(needle.lowercased())
        }
        if let name = message.sender?.displayName, name.localizedCaseInsensitiveContains(needle) { return true }
        if let handle = message.sender?.handle, handle.localizedCaseInsensitiveContains(needle) { return true }
        return false
    }

    /// True when the text contains a URL. `NSDataDetector` catches bare domains
    /// (`example.com`) as well as `http(s)://` and `www.` forms. The detector is
    /// immutable and safe to share across concurrent detection calls.
    static func containsLink(_ text: String) -> Bool {
        guard !text.isEmpty, let detector = linkDetector else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range) != nil
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
}
