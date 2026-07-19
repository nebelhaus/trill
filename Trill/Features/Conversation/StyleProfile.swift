import Foundation

/// A tallied token — a word, emoji, opener, or phrase — with how often it
/// appeared. `id` is the value itself so SwiftUI can list them without an index.
struct StyleTally: Equatable, Sendable, Identifiable {
    let value: String
    let count: Int
    var id: String { value }
}

/// Where a style profile was sampled from — one thread, or every conversation
/// at once (the "how you text, overall" scan). Carries the phrasing the exported
/// document uses so per-thread and global profiles share one exporter.
enum StyleScope: Equatable, Sendable {
    /// A single thread, named by its display name.
    case conversation(String)
    /// Every conversation combined.
    case everyone

    /// Short label for the sheet title and export filename.
    var label: String {
        switch self {
        case .conversation(let name): name
        case .everyone: "All Conversations"
        }
    }

    /// How the exported doc names where the sample came from.
    var sourcePhrase: String {
        switch self {
        case .conversation(let name): "the thread with \(name)"
        case .everyone: "all your conversations"
        }
    }
}

/// A statistical fingerprint of *your* texting style, computed purely by counting
/// surface features of the messages you sent — length, casing, punctuation,
/// emoji, vocabulary, cadence — plus a spread of verbatim examples. No model runs
/// here: this is the deterministic half of the "scan my style" feature, and the
/// exported document (see `StyleProfileExporter`) is what you hand to an AI so it
/// can imitate the voice these numbers describe. Read-only; chat.db is untouched.
struct StyleProfile: Equatable, Sendable {
    /// Where the voice was sampled from — a thread or all conversations.
    let scope: StyleScope
    /// How many of my own text messages fed the profile (outgoing, non-empty).
    let messageCount: Int

    // Length & rhythm
    let medianWordCount: Int
    let averageWordCount: Double
    /// Share of my messages that are 3 words or fewer.
    let shortShare: Double
    /// Share of my messages that run 20 words or longer.
    let longShare: Double
    /// Share of my messages fired as part of a rapid-fire burst (another of my
    /// texts within a couple minutes, no reply in between).
    let burstShare: Double

    // Mechanics — each a share of my messages
    let lowercaseShare: Double
    let endsWithPeriodShare: Double
    let endsWithQuestionShare: Double
    let endsWithExclamationShare: Double
    let noTerminalPunctuationShare: Double
    let ellipsisShare: Double
    let emojiShare: Double

    // Vocabulary
    let topEmoji: [StyleTally]
    let topOpeners: [StyleTally]
    let topClosers: [StyleTally]
    let topWords: [StyleTally]
    let topPhrases: [StyleTally]

    // Cadence
    /// Median minutes I take to reply after they've written — nil until there's
    /// at least one such turn.
    let medianReplyMinutes: Double?

    /// A representative, deduplicated spread of my actual messages, oldest →
    /// newest — the few-shot examples an LLM learns the voice from.
    let sampleMessages: [String]

    static func empty(scope: StyleScope) -> StyleProfile {
        StyleProfile(
            scope: scope, messageCount: 0,
            medianWordCount: 0, averageWordCount: 0, shortShare: 0, longShare: 0, burstShare: 0,
            lowercaseShare: 0, endsWithPeriodShare: 0, endsWithQuestionShare: 0,
            endsWithExclamationShare: 0, noTerminalPunctuationShare: 0, ellipsisShare: 0, emojiShare: 0,
            topEmoji: [], topOpeners: [], topClosers: [], topWords: [], topPhrases: [],
            medianReplyMinutes: nil, sampleMessages: []
        )
    }
}

/// Pure aggregation from a thread's messages to a `StyleProfile`, kept out of the
/// view/model so it can be unit-tested directly over message arrays — mirrors how
/// `ConversationStatsBuilder` isolates the stats math. Everything here is plain
/// counting over the message strings we already fetched; there is no AI in the
/// loop, and nothing leaves the device.
enum StyleProfileBuilder {
    /// Two of my messages closer than this (with no reply between) read as one
    /// rapid-fire burst rather than two separate turns.
    private static let burstWindow: TimeInterval = 150

    /// How many verbatim examples to carry, and how long each may run before it's
    /// clipped — enough to convey voice without pasting an essay.
    private static let sampleTarget = 40
    private static let maxSampleLength = 280

    /// Builds the profile from `messages` in any order. Only my own (`isOutgoing`)
    /// non-empty texts shape the voice; incoming messages are read solely to
    /// measure reply latency and to break bursts. `now`/`calendar` are unused today
    /// but kept in the signature to match the stats builder and leave room for
    /// time-of-day style facets without a call-site change.
    static func build(
        from messages: [Message],
        scope: StyleScope,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StyleProfile {
        let ordered = messages.sorted { left, right in
            left.createdAt == right.createdAt ? left.id.id < right.id.id : left.createdAt < right.createdAt
        }
        let mine = ordered.filter { $0.isOutgoing && !$0.text.trimmedNonEmpty.isEmpty }
        guard !mine.isEmpty else { return .empty(scope: scope) }

        // Bursts and reply latency only mean something when we can see the other
        // side: a mine-only input (the global "everyone" scan pulls just my
        // messages) has no turn boundaries, so those two metrics are suppressed
        // rather than computed from a meaningless run.
        let hasIncoming = ordered.contains { !$0.isOutgoing }

        let bodies = mine.map { $0.text.trimmedNonEmpty }
        let count = Double(mine.count)

        // Length distribution.
        let wordCounts = bodies.map { wordCount($0) }
        let short = wordCounts.filter { $0 <= 3 }.count
        let long = wordCounts.filter { $0 >= 20 }.count

        // Mechanics — one pass tallying each per-message trait.
        var lower = 0, period = 0, question = 0, bang = 0, noPunct = 0, ellipsis = 0, withEmoji = 0
        var emojiCounts: [String: Int] = [:]
        var openerCounts: [String: Int] = [:]
        var closerCounts: [String: Int] = [:]
        var wordFreq: [String: Int] = [:]
        var bigramFreq: [String: Int] = [:]
        for body in bodies {
            if hasLetters(body), !body.contains(where: { $0.isUppercase }) { lower += 1 }
            if let end = terminal(body) {
                if end == "." { period += 1 }
                else if end == "?" { question += 1 }
                else if end == "!" { bang += 1 }
                else if !".?!,;:".contains(end) { noPunct += 1 }
            }
            if body.contains("...") || body.contains("…") { ellipsis += 1 }

            let emoji = emojiCharacters(body)
            if !emoji.isEmpty {
                withEmoji += 1
                for glyph in emoji { emojiCounts[glyph, default: 0] += 1 }
            }

            let tokens = words(body)
            if let first = tokens.first { openerCounts[first, default: 0] += 1 }
            if let last = tokens.last { closerCounts[last, default: 0] += 1 }
            for token in tokens where token.count >= 3 && !stopWords.contains(token) {
                wordFreq[token, default: 0] += 1
            }
            for pair in zip(tokens, tokens.dropFirst()) {
                bigramFreq["\(pair.0) \(pair.1)", default: 0] += 1
            }
        }

        return StyleProfile(
            scope: scope,
            messageCount: mine.count,
            medianWordCount: Int(median(wordCounts.map(Double.init)) ?? 0),
            averageWordCount: average(wordCounts),
            shortShare: Double(short) / count,
            longShare: Double(long) / count,
            burstShare: hasIncoming ? burstShare(ordered) : 0,
            lowercaseShare: Double(lower) / count,
            endsWithPeriodShare: Double(period) / count,
            endsWithQuestionShare: Double(question) / count,
            endsWithExclamationShare: Double(bang) / count,
            noTerminalPunctuationShare: Double(noPunct) / count,
            ellipsisShare: Double(ellipsis) / count,
            emojiShare: Double(withEmoji) / count,
            topEmoji: top(emojiCounts, 8),
            topOpeners: top(openerCounts, 6),
            topClosers: top(closerCounts, 6),
            topWords: top(wordFreq, 12),
            topPhrases: top(bigramFreq.filter { $0.value > 1 }, 8),
            medianReplyMinutes: hasIncoming ? median(replyGaps(ordered)).map { $0 / 60 } : nil,
            sampleMessages: samples(bodies)
        )
    }

    // MARK: - Bursts & cadence

    /// Share of my messages fired inside a burst: another of my texts within
    /// `burstWindow`, with no incoming message breaking the run.
    private static func burstShare(_ ordered: [Message]) -> Double {
        var mineCount = 0
        var burst = Set<MessageID>()
        var previousMine: Message?
        for message in ordered {
            if message.isOutgoing {
                guard !message.text.trimmedNonEmpty.isEmpty else { continue }
                mineCount += 1
                if let previous = previousMine,
                   message.createdAt.timeIntervalSince(previous.createdAt) <= burstWindow {
                    burst.insert(previous.id)
                    burst.insert(message.id)
                }
                previousMine = message
            } else {
                previousMine = nil // a reply ends my run
            }
        }
        guard mineCount > 0 else { return 0 }
        return Double(burst.count) / Double(mineCount)
    }

    /// My reply latencies: gaps where a message of mine follows one of theirs.
    /// Only turn *switches* count, so a burst isn't mistaken for a fast reply —
    /// same rule the stats builder uses.
    private static func replyGaps(_ ordered: [Message]) -> [TimeInterval] {
        var gaps: [TimeInterval] = []
        for (previous, current) in zip(ordered, ordered.dropFirst())
        where current.isOutgoing && !previous.isOutgoing {
            gaps.append(current.createdAt.timeIntervalSince(previous.createdAt))
        }
        return gaps
    }

    // MARK: - Samples

    /// A representative spread: dedupe (case-insensitively) so repeats like "lol"
    /// collapse, clip over-long ones, then take an even stride across the
    /// remaining timeline so the examples aren't all from one week.
    private static func samples(_ bodies: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for body in bodies {
            let key = body.lowercased()
            guard seen.insert(key).inserted else { continue }
            unique.append(body.count > maxSampleLength ? String(body.prefix(maxSampleLength)) + "…" : body)
        }
        guard unique.count > sampleTarget else { return unique }
        let stride = Double(unique.count) / Double(sampleTarget)
        return (0..<sampleTarget).map { unique[Int((Double($0) * stride).rounded(.down))] }
    }

    // MARK: - Token helpers

    /// Lowercased alphanumeric tokens, keeping intra-word apostrophes so "don't"
    /// and "i'm" stay whole.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: tokenSeparators)
            .map { $0.trimmingCharacters(in: apostrophes) }
            .filter { !$0.isEmpty }
    }

    private static func wordCount(_ text: String) -> Int { words(text).count }

    private static func hasLetters(_ text: String) -> Bool { text.contains { $0.isLetter } }

    /// The last non-whitespace character, for classifying how a message ends.
    private static func terminal(_ text: String) -> Character? {
        text.reversed().first { !$0.isWhitespace }
    }

    private static func emojiCharacters(_ text: String) -> [String] {
        text.filter(isEmoji).map(String.init)
    }

    /// True for pictographic emoji, false for ASCII digits/`#`/`*` (which Unicode
    /// also flags `isEmoji`): require emoji presentation or a codepoint in the
    /// pictographic planes.
    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation ||
            (scalar.properties.isEmoji && scalar.value >= 0x1F000)
        }
    }

    private static func top(_ counts: [String: Int], _ limit: Int) -> [StyleTally] {
        counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { StyleTally(value: $0.key, count: $0.value) }
    }

    /// Mean word count, rounded to one decimal for the exported figure.
    private static func average(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (Double(values.reduce(0, +)) / Double(values.count) * 10).rounded() / 10
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    private static let apostrophes = CharacterSet(charactersIn: "'’")
    private static let tokenSeparators = CharacterSet.alphanumerics.union(apostrophes).inverted

    /// A deliberately small stop list: enough to keep grammatical filler out of
    /// the "characteristic words" tally, but not so aggressive that distinctive
    /// filler ("honestly", "literally", "lol") gets scrubbed — that's signal.
    private static let stopWords: Set<String> = [
        "the", "and", "you", "that", "for", "with", "was", "are", "this", "have",
        "but", "not", "your", "its", "were", "they", "them", "what", "when", "will",
        "just", "can", "get", "got", "out", "now", "how", "all", "then", "she",
        "his", "her", "him", "our", "their", "there", "about", "would", "could",
    ]
}

private extension String {
    var trimmedNonEmpty: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
