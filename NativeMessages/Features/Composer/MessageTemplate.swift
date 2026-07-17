import Foundation

/// A *message template* is just a `Snippet` whose body carries `{blank}`
/// markers. Inserting one drops the body into the composer and steps the caret
/// through each blank with ⇥ — so the same `/`-snippet machinery doubles as
/// fill-in-the-blank templates, with no new store and no schema change.
///
/// A blank is a `{...}` run with a non-empty label that spans no nested `{` and
/// no newline (those are literal braces, not a field). The braces are part of
/// each returned range, so selecting one and typing replaces the whole marker;
/// ⇥ / ⇧⇥ jump to the next / previous blank. Ranges are `NSRange` (UTF-16) so
/// they hand straight to `NSTextView.setSelectedRange`.
enum MessageTemplate {
    /// Every `{...}` blank in `body`, in document order.
    static func placeholderRanges(in body: String) -> [NSRange] {
        let ns = body as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let open = ns.range(
                of: "{",
                range: NSRange(location: cursor, length: ns.length - cursor)
            )
            guard open.location != NSNotFound else { break }
            let afterOpen = open.location + 1
            let close = ns.range(
                of: "}",
                range: NSRange(location: afterOpen, length: ns.length - afterOpen)
            )
            guard close.location != NSNotFound else { break }
            let label = ns.substring(with: NSRange(location: afterOpen, length: close.location - afterOpen))
            if !label.isEmpty, !label.contains("{"), !label.contains(where: \.isNewline) {
                ranges.append(NSRange(location: open.location, length: close.location - open.location + 1))
                cursor = close.location + 1
            } else {
                // Not a blank (`{}`, `{{…`, or a brace run across a newline) —
                // step past this `{` and keep scanning for a real one.
                cursor = afterOpen
            }
        }
        return ranges
    }

    static func hasPlaceholders(_ body: String) -> Bool {
        !placeholderRanges(in: body).isEmpty
    }

    /// The first blank starting at or after `location`, or `nil` once the caret
    /// has passed the last one. Live-searched on every ⇥ so edits to earlier
    /// blanks never invalidate the offsets of later ones.
    static func nextPlaceholder(in text: String, from location: Int) -> NSRange? {
        placeholderRanges(in: text).first { $0.location >= location }
    }

    /// The last blank ending at or before `location`, for ⇧⇥.
    static func previousPlaceholder(in text: String, before location: Int) -> NSRange? {
        placeholderRanges(in: text).last { $0.location + $0.length <= location }
    }
}
