import SwiftUI

/// The `/`-trigger autocomplete popover that floats above the composer box.
/// Renders the ranked completions — built-in slash commands and the user's
/// snippets, blended — and supports click-to-insert. Keyboard navigation lives
/// in `GrowingTextView` (which keeps first responder); this view just draws.
struct CompletionPickerView: View {
    let matches: [CompletionItem]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            list
            RiceDivider()
            hint
        }
        // Overlays are proposed the anchor's (one-line) height; without this the
        // rows squish. `fixedSize` lets the popover take its natural height. The
        // ranking is capped at 8 rows, so it never needs to scroll.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320)
        .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Rice.surface1, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .accessibilityLabel("Completion suggestions")
    }

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                CompletionRow(item: item, isSelected: index == selection)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(index) }
            }
        }
        .padding(6)
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Text("↑↓")
                .foregroundStyle(Rice.subtext0)
            Text("navigate")
                .foregroundStyle(Rice.overlay0)
            Text("↵")
                .foregroundStyle(Rice.subtext0)
            Text("insert")
                .foregroundStyle(Rice.overlay0)
            Text("esc")
                .foregroundStyle(Rice.subtext0)
            Text("dismiss")
                .foregroundStyle(Rice.overlay0)
        }
        .riceFont(9, .medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let isSelected: Bool

    @Environment(\.riceAccent) private var accent

    var body: some View {
        HStack(spacing: 9) {
            Text("/\(item.title)")
                .riceFont(12, .semibold)
                .foregroundStyle(accent)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.preview)
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let badge {
                Image(systemName: badge.symbol)
                    .riceFont(9)
                    .foregroundStyle(Rice.overlay0)
                    .layoutPriority(1)
                    .accessibilityLabel(badge.label)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isSelected ? accent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.preview)")
    }

    /// A trailing glyph that marks what kind of row this is: a built-in command,
    /// or a fill-in template (⇥ steps through its blanks on insert). Plain
    /// snippets get none.
    private var badge: (symbol: String, label: String)? {
        if item.isCommand {
            ("slash.circle", "Slash command")
        } else if item.isTemplate {
            ("rectangle.and.pencil.and.ellipsis", "Fill-in template")
        } else {
            nil
        }
    }
}
