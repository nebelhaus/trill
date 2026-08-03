import Foundation

/// Flattens a Matrix HTML message body to plain text.
///
/// `Message.text` on the wire is **Matrix HTML**; `Domain.Message.text` is a
/// plain `String` that views render with `Text`. Handing markup to a `Text` view
/// shows the tags; handing it to anything that *renders* HTML is worse. So this
/// converts deliberately rather than hoping.
///
/// Written by hand rather than via `NSAttributedString(html:)`: that API needs
/// the main thread, spins a WebKit parser, and will happily fetch remote
/// subresources referenced by the markup — a privacy leak on a message body.
enum MatrixHTMLText {
    /// Block-level tags whose boundaries are a line break in plain text.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table",
    ]

    static func plainText(from html: String) -> String {
        guard !html.isEmpty else { return "" }
        var output = ""
        output.reserveCapacity(html.count)

        var index = html.startIndex
        var pendingEntity = ""
        var inEntity = false
        /// Content inside these never renders as message text.
        var suppressDepth = 0

        while index < html.endIndex {
            let character = html[index]
            switch character {
            case "<":
                guard let close = html[index...].firstIndex(of: ">") else {
                    // Unclosed `<` — treat the remainder as literal text.
                    output.append(contentsOf: html[index...])
                    index = html.endIndex
                    continue
                }
                let raw = String(html[html.index(after: index)..<close])
                let name = tagName(raw)
                if name == "script" || name == "style" {
                    if raw.hasPrefix("/") {
                        suppressDepth = max(0, suppressDepth - 1)
                    } else if !raw.hasSuffix("/") {
                        suppressDepth += 1
                    }
                } else if suppressDepth == 0, blockTags.contains(name) {
                    appendBreak(to: &output)
                }
                index = html.index(after: close)
                continue
            case "&":
                inEntity = true
                pendingEntity = "&"
            case ";" where inEntity:
                pendingEntity.append(";")
                if suppressDepth == 0 { output.append(decode(entity: pendingEntity)) }
                inEntity = false
                pendingEntity = ""
            default:
                if inEntity {
                    pendingEntity.append(character)
                    // Entities are short; anything longer isn't one.
                    if pendingEntity.count > 12 || character == " " {
                        if suppressDepth == 0 { output.append(contentsOf: pendingEntity) }
                        inEntity = false
                        pendingEntity = ""
                    }
                } else if suppressDepth == 0 {
                    output.append(character)
                }
            }
            index = html.index(after: index)
        }
        if inEntity, suppressDepth == 0 { output.append(contentsOf: pendingEntity) }

        return collapse(output)
    }

    private static func tagName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("/") { name.removeFirst() }
        let stop = name.firstIndex { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "/" }
        return String(stop.map { name[..<$0] } ?? name.dropLast(0)).lowercased()
    }

    /// One break per boundary — `</p><p>` is a single newline, not two.
    private static func appendBreak(to output: inout String) {
        guard !output.isEmpty, output.last != "\n" else { return }
        output.append("\n")
    }

    private static func decode(entity: String) -> String {
        switch entity {
        case "&amp;": "&"
        case "&lt;": "<"
        case "&gt;": ">"
        case "&quot;": "\""
        case "&apos;", "&#39;": "'"
        case "&nbsp;": " "
        default: numeric(entity) ?? entity
        }
    }

    private static func numeric(_ entity: String) -> String? {
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let body = entity.dropFirst(2).dropLast()
        let value: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body)
        }
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// Trailing/leading whitespace goes; interior newlines stay, because a
    /// multi-line message is multi-line on purpose. Runs of three or more
    /// newlines collapse to two.
    private static func collapse(_ value: String) -> String {
        var result = ""
        var newlineRun = 0
        for character in value {
            if character == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { result.append(character) }
            } else {
                newlineRun = 0
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
