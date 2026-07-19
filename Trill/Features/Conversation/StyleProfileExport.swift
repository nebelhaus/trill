import Foundation

/// Renders a `StyleProfile` into a single Markdown document designed to be pasted
/// into an AI model so it can write in your voice — a ready-to-use prompt, a
/// human-readable metrics sheet, and a spread of verbatim examples. Pure and
/// Foundation-only like `ConversationExporter`, so it's directly unit-testable and
/// never touches chat.db. Markdown is the only format: the artifact's whole job is
/// to be model-legible, and Markdown is what models read best.
enum StyleProfileExporter {
    static func export(_ profile: StyleProfile, generatedAt: Date = Date()) -> String {
        guard profile.messageCount > 0 else {
            return "# How you text\n\n_No messages of yours were found in this conversation to analyze._\n"
        }

        var lines: [String] = []
        lines.append("# How you text")
        lines.append("")
        let stamp = generatedAt.formatted(.dateTime.month(.abbreviated).day().year())
        lines.append("*Generated \(stamp) from \(profile.messageCount) of your messages in \(profile.scope.sourcePhrase). Everything below was computed on-device by counting your own texts — no message left this Mac. Paste it into an AI model to have it write in your style.*")

        lines.append("")
        lines.append("## Ready-to-use prompt")
        lines.append("")
        for line in promptBlock(profile) {
            lines.append("> \(line)")
        }

        lines.append("")
        lines.append("## Style at a glance")
        lines.append("")
        lines.append(contentsOf: glance(profile))

        if !profile.sampleMessages.isEmpty {
            lines.append("")
            lines.append("## Sample messages")
            lines.append("")
            lines.append("*Real texts of yours, oldest to newest — the ground truth for the voice. Imitate their rhythm and word choice, not their literal content.*")
            for sample in profile.sampleMessages {
                lines.append("")
                for physical in sample.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(physical)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Prompt

    /// A short, natural-language brief the model can act on directly, composed
    /// from the loudest signals in the profile.
    private static func promptBlock(_ profile: StyleProfile) -> [String] {
        var traits: [String] = []
        traits.append("keep messages around \(profile.medianWordCount) words")
        if profile.shortShare >= 0.4 { traits.append("lean short and clipped") }
        if profile.burstShare >= 0.3 { traits.append("often split a thought across several quick messages instead of one") }
        if profile.lowercaseShare >= 0.6 { traits.append("write in all lowercase") }
        if profile.noTerminalPunctuationShare >= 0.5 { traits.append("usually skip ending punctuation") }
        else if profile.endsWithPeriodShare >= 0.5 { traits.append("end sentences with a period") }
        if profile.endsWithExclamationShare >= 0.2 { traits.append("use exclamation points freely") }
        if profile.emojiShare >= 0.25 {
            let glyphs = profile.topEmoji.prefix(4).map(\.value).joined()
            traits.append(glyphs.isEmpty ? "sprinkle in emoji" : "sprinkle in emoji like \(glyphs)")
        } else if profile.emojiShare < 0.05 {
            traits.append("rarely use emoji")
        }

        var block = ["You are writing text messages as me. Match my voice: \(sentence(traits))."]
        if !profile.topPhrases.isEmpty {
            block.append("I reach for phrases like \(quotedList(profile.topPhrases, 5)).")
        }
        block.append("Study the sample messages below and imitate their tone, rhythm, and word choice.")
        return block
    }

    // MARK: - Glance

    private static func glance(_ profile: StyleProfile) -> [String] {
        var rows: [String] = []
        rows.append("- **Message length:** typically \(profile.medianWordCount) words (avg \(oneDecimal(profile.averageWordCount))) — \(pct(profile.shortShare)) are 3 words or fewer, \(pct(profile.longShare)) run long")
        // Bursts need turn boundaries to be meaningful; the global scan pulls only
        // my messages, so it has none — omit the row there rather than print noise.
        if profile.scope != .everyone {
            rows.append("- **Bursts:** \(pct(profile.burstShare)) of my texts come in rapid-fire runs")
        }
        rows.append("- **Capitalization:** \(pct(profile.lowercaseShare)) all-lowercase")
        rows.append("- **Endings:** \(pct(profile.noTerminalPunctuationShare)) no punctuation · \(pct(profile.endsWithPeriodShare)) period · \(pct(profile.endsWithQuestionShare)) question · \(pct(profile.endsWithExclamationShare)) exclamation")
        if profile.ellipsisShare >= 0.03 {
            rows.append("- **Ellipses:** \(pct(profile.ellipsisShare)) of messages use `...`")
        }
        rows.append("- **Emoji:** \(pct(profile.emojiShare)) of messages" + tallyList(profile.topEmoji, prefix: " — top: ", joinPlain: true))
        rows.append("- **Typical openers:** \(bareList(profile.topOpeners, 5))")
        rows.append("- **Typical closers:** \(bareList(profile.topClosers, 5))")
        rows.append("- **Characteristic words:** \(bareList(profile.topWords, 10))")
        if !profile.topPhrases.isEmpty {
            rows.append("- **Common phrases:** \(quotedList(profile.topPhrases, 6))")
        }
        if let minutes = profile.medianReplyMinutes {
            rows.append("- **Reply speed:** median \(replyLabel(minutes))")
        }
        return rows
    }

    // MARK: - Formatting

    private static func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Joins a trait list into one sentence with commas and a trailing "and".
    private static func sentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    private static func bareList(_ tallies: [StyleTally], _ limit: Int) -> String {
        let values = tallies.prefix(limit).map(\.value)
        return values.isEmpty ? "—" : values.joined(separator: ", ")
    }

    private static func quotedList(_ tallies: [StyleTally], _ limit: Int) -> String {
        let values = tallies.prefix(limit).map { "\u{201C}\($0.value)\u{201D}" }
        return values.isEmpty ? "—" : sentence(values)
    }

    /// Emoji glyphs read fine run together; only used for the emoji row.
    private static func tallyList(_ tallies: [StyleTally], prefix: String, joinPlain: Bool) -> String {
        guard !tallies.isEmpty else { return "" }
        let glyphs = tallies.prefix(6).map(\.value).joined(separator: joinPlain ? " " : ", ")
        return "\(prefix)\(glyphs)"
    }

    private static func replyLabel(_ minutes: Double) -> String {
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(oneDecimal(hours)) hr" }
        return "\(oneDecimal(hours / 24)) days"
    }
}
