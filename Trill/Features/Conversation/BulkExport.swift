import Foundation

/// Pure, testable planning for the "export all conversations" job — the parts
/// that decide *what* the archive looks like, kept apart from the actual file
/// I/O and zipping (which live in `BulkExportModel`) so they can be exercised
/// directly. Foundation-only, like `ConversationExporter`.
enum BulkExportPlanner {
    /// A filesystem-safe, collision-free file name per conversation, in the same
    /// order as the input. Two threads that sanitize to the same stem (e.g. two
    /// unnamed groups, or "Mom" and "Mom/Dad") get " 2", " 3"… suffixes so no
    /// file in the archive clobbers another. Empty names fall back to a stable
    /// positional stem.
    static func filenames(for conversations: [Conversation], fileExtension ext: String) -> [String] {
        var used: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(conversations.count)
        for (index, conversation) in conversations.enumerated() {
            let stem = sanitize(conversation.displayName).nonEmpty ?? "Conversation \(index + 1)"
            var candidate = stem
            var bump = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(stem) \(bump)"
                bump += 1
            }
            used.insert(candidate.lowercased())
            result.append("\(candidate).\(ext)")
        }
        return result
    }

    /// The Markdown index that ties the archive together: a titled list linking
    /// each per-thread file, with its message count. `filenames` must line up
    /// with `conversations` (same order/length) — pass the array `filenames`
    /// returned. `counts[i]` is thread `i`'s message total.
    static func indexMarkdown(
        conversations: [Conversation],
        filenames: [String],
        counts: [Int],
        generatedAt: Date = Date()
    ) -> String {
        let stamp = generatedAt.formatted(.dateTime.month(.abbreviated).day().year())
        let total = counts.reduce(0, +)
        var lines: [String] = []
        lines.append("# Trill Export")
        lines.append("")
        let threadNoun = conversations.count == 1 ? "conversation" : "conversations"
        let msgNoun = total == 1 ? "message" : "messages"
        lines.append("*Exported \(stamp) · \(conversations.count) \(threadNoun) · \(total) \(msgNoun)*")
        lines.append("")
        for (index, conversation) in conversations.enumerated() {
            let file = filenames[safe: index] ?? ""
            let count = counts[safe: index] ?? 0
            let noun = count == 1 ? "message" : "messages"
            // Percent-encode the link target so spaces in file names don't break
            // the Markdown link; the visible text stays human-readable.
            let href = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
            lines.append("- [\(conversation.displayName)](\(href)) — \(count) \(noun)")
        }
        if conversations.isEmpty {
            lines.append("_No conversations to export._")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A default archive stem (no extension) stamped with the day, e.g.
    /// `Trill Export 2026-07-18`.
    static func archiveStem(generatedAt: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: generatedAt)
        return String(
            format: "Trill Export %04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }

    /// Strips path-hostile characters so a stem is safe as a file name. Mirrors
    /// `ConversationExporter.sanitize` (kept local so the two files stay
    /// independent).
    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        return String(name.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
