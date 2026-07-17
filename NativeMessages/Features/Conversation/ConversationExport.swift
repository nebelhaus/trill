import Foundation

/// The three text formats a conversation can be exported to. Pure data — the
/// `UTType` / save-panel mapping lives in the view so this file stays
/// Foundation-only and directly unit-testable.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText
    case html

    var id: String { rawValue }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .html: "HTML"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .html: "html"
        }
    }
}

/// Pure, testable serialization of a thread's messages to Markdown, plain text,
/// or HTML — the export feature's core. Read-only: it turns `Message` values we
/// already fetch into a document and never touches chat.db. Kept out of the
/// view/model like `ConversationStatsBuilder` so it can be exercised directly
/// over message arrays.
enum ConversationExporter {
    /// Serializes `messages` (in any order) for `conversation`. An optional
    /// inclusive `range` clips to a date window; `generatedAt`/`calendar` are
    /// injected so day grouping and the export stamp are testable off the wall
    /// clock.
    static func export(
        conversation: Conversation,
        messages: [Message],
        format: ExportFormat,
        range: ClosedRange<Date>? = nil,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let selected = filter(messages, range: range)
        switch format {
        case .markdown:
            return markdown(conversation: conversation, messages: selected, generatedAt: generatedAt, calendar: calendar)
        case .plainText:
            return plainText(conversation: conversation, messages: selected, generatedAt: generatedAt, calendar: calendar)
        case .html:
            return html(conversation: conversation, messages: selected, generatedAt: generatedAt, calendar: calendar)
        }
    }

    /// Messages inside the inclusive `range` (or all of them), oldest → newest.
    /// Ties on timestamp break on the stable id so the order is deterministic.
    static func filter(_ messages: [Message], range: ClosedRange<Date>?) -> [Message] {
        let scoped = range.map { window in messages.filter { window.contains($0.createdAt) } } ?? messages
        return scoped.sorted { left, right in
            left.createdAt == right.createdAt ? left.id.id < right.id.id : left.createdAt < right.createdAt
        }
    }

    /// A filesystem-safe default file name (no extension): the thread name, plus
    /// the date window when one is set.
    static func filenameStem(
        for conversation: Conversation,
        range: ClosedRange<Date>? = nil,
        calendar: Calendar = .current
    ) -> String {
        let base = sanitize(conversation.displayName).nonEmpty ?? "Conversation"
        guard let range else { return base }
        let from = isoDay(range.lowerBound, calendar: calendar)
        let to = isoDay(range.upperBound, calendar: calendar)
        return from == to ? "\(base) \(from)" : "\(base) \(from) to \(to)"
    }

    // MARK: - Plain text

    private static func plainText(
        conversation: Conversation,
        messages: [Message],
        generatedAt: Date,
        calendar: Calendar
    ) -> String {
        var lines: [String] = []
        lines.append("Conversation with \(conversation.displayName)")
        lines.append(subtitle(conversation: conversation, count: messages.count, generatedAt: generatedAt))
        lines.append(String(repeating: "=", count: 48))

        var lastDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day != lastDay {
                lines.append("")
                lines.append("— \(dayHeader(day)) —")
                lines.append("")
                lastDay = day
            }
            let time = message.createdAt.formatted(.dateTime.hour().minute())
            let name = senderName(message, conversation: conversation)
            var head = "[\(time)] \(name):"
            if let body = message.text.nonEmpty {
                head += " \(body)"
            }
            if message.isEdited { head += " (edited)" }
            lines.append(head)
            for attachment in message.attachments {
                lines.append("    · \(attachmentLabel(attachment))")
            }
            if let reactions = reactionSummary(message) {
                lines.append("    ♥ \(reactions)")
            }
        }
        if messages.isEmpty { lines.append("\n(No messages in this range.)") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Markdown

    private static func markdown(
        conversation: Conversation,
        messages: [Message],
        generatedAt: Date,
        calendar: Calendar
    ) -> String {
        var lines: [String] = []
        lines.append("# Conversation with \(conversation.displayName)")
        lines.append("")
        lines.append("*\(subtitle(conversation: conversation, count: messages.count, generatedAt: generatedAt))*")

        var lastDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day != lastDay {
                lines.append("")
                lines.append("## \(dayHeader(day))")
                lastDay = day
            }
            let time = message.createdAt.formatted(.dateTime.hour().minute())
            let name = senderName(message, conversation: conversation)
            lines.append("")
            var head = "**\(name)** · \(time)"
            if message.isEdited { head += " *(edited)*" }
            lines.append(head)
            if let body = message.text.nonEmpty {
                lines.append("")
                // Blockquote the body so multi-line messages stay visually one unit.
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
                }
            }
            for attachment in message.attachments {
                lines.append("")
                lines.append("📎 \(attachmentLabel(attachment))")
            }
            if let reactions = reactionSummary(message) {
                lines.append("")
                lines.append("_\(reactions)_")
            }
        }
        if messages.isEmpty {
            lines.append("")
            lines.append("_No messages in this range._")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - HTML

    private static func html(
        conversation: Conversation,
        messages: [Message],
        generatedAt: Date,
        calendar: Calendar
    ) -> String {
        var body: [String] = []
        var lastDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day != lastDay {
                body.append("    <div class=\"day\">\(escape(dayHeader(day)))</div>")
                lastDay = day
            }
            let side = message.isOutgoing ? "me" : "them"
            let time = message.createdAt.formatted(.dateTime.hour().minute())
            var bubble = ["    <div class=\"msg \(side)\">"]
            bubble.append("      <div class=\"meta\">\(escape(senderName(message, conversation: conversation))) · \(escape(time))\(message.isEdited ? " · edited" : "")</div>")
            if let text = message.text.nonEmpty {
                bubble.append("      <div class=\"text\">\(escape(text).replacingOccurrences(of: "\n", with: "<br>"))</div>")
            }
            for attachment in message.attachments {
                bubble.append("      <div class=\"attachment\">📎 \(escape(attachmentLabel(attachment)))</div>")
            }
            if let reactions = reactionSummary(message) {
                bubble.append("      <div class=\"reactions\">\(escape(reactions))</div>")
            }
            bubble.append("    </div>")
            body.append(bubble.joined(separator: "\n"))
        }
        if messages.isEmpty {
            body.append("    <div class=\"empty\">No messages in this range.</div>")
        }

        let title = escape("Conversation with \(conversation.displayName)")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; padding: 32px 16px; background: #f5f5f7; color: #1d1d1f; }
          .thread { max-width: 680px; margin: 0 auto; }
          h1 { font-size: 20px; margin: 0 0 4px; }
          .subtitle { color: #6e6e73; font-size: 13px; margin-bottom: 24px; }
          .day { text-align: center; color: #8a8a8e; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; margin: 28px 0 14px; }
          .msg { max-width: 74%; margin: 6px 0; padding: 8px 12px; border-radius: 16px; clear: both; }
          .msg.them { background: #e9e9eb; float: left; }
          .msg.me { background: #2f7bf6; color: #fff; float: right; }
          .meta { font-size: 11px; opacity: 0.7; margin-bottom: 2px; }
          .text { white-space: normal; word-wrap: break-word; }
          .attachment, .reactions { font-size: 12px; opacity: 0.85; margin-top: 4px; }
          .empty { text-align: center; color: #8a8a8e; margin-top: 40px; }
          @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; color: #f5f5f7; }
            .msg.them { background: #303032; }
            .subtitle { color: #98989d; }
          }
        </style>
        </head>
        <body>
        <div class="thread">
          <h1>\(title)</h1>
          <div class="subtitle">\(escape(subtitle(conversation: conversation, count: messages.count, generatedAt: generatedAt)))</div>
        \(body.joined(separator: "\n"))
        </div>
        </body>
        </html>

        """
    }

    // MARK: - Shared bits

    private static func subtitle(conversation: Conversation, count: Int, generatedAt: Date) -> String {
        let stamp = generatedAt.formatted(.dateTime.month(.abbreviated).day().year())
        let noun = count == 1 ? "message" : "messages"
        return "Exported \(stamp) · \(count) \(noun)"
    }

    private static func senderName(_ message: Message, conversation: Conversation) -> String {
        if message.isOutgoing { return "You" }
        return message.sender?.displayName
            ?? message.sender?.handle
            ?? conversation.displayName
    }

    private static func attachmentLabel(_ attachment: MessageAttachment) -> String {
        let kind = attachment.isImage ? "Image" : "Attachment"
        let name = attachment.displayName.nonEmpty ?? "unnamed"
        return "\(kind): \(name)"
    }

    /// A compact one-line summary of the message's tapbacks, or nil if none —
    /// e.g. `❤️ Alice · 👍 You`.
    private static func reactionSummary(_ message: Message) -> String? {
        guard !message.reactions.isEmpty else { return nil }
        return message.reactions
            .map { "\($0.glyph) \($0.isFromMe ? "You" : $0.senderDisplayName)" }
            .joined(separator: " · ")
    }

    private static func dayHeader(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Strips path-hostile characters so the stem is safe as a file name.
    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        return String(name.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
