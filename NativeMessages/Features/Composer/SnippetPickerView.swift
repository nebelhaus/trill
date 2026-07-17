import SwiftUI

/// The `/`-trigger autocomplete popover that floats above the composer box.
/// Keyboard navigation lives in `GrowingTextView` (which keeps first responder);
/// this view just renders the ranked matches and supports click-to-insert.
struct SnippetPickerView: View {
    let matches: [Snippet]
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
        .accessibilityLabel("Snippet suggestions")
    }

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, snippet in
                SnippetRow(snippet: snippet, isSelected: index == selection)
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

private struct SnippetRow: View {
    let snippet: Snippet
    let isSelected: Bool

    @Environment(\.riceAccent) private var accent

    var body: some View {
        HStack(spacing: 9) {
            Text("/\(snippet.title)")
                .riceFont(12, .semibold)
                .foregroundStyle(accent)
                .lineLimit(1)
                .layoutPriority(1)
            Text(snippet.body)
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if MessageTemplate.hasPlaceholders(snippet.body) {
                // Marks a fill-in template; ⇥ steps through the blanks on insert.
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .riceFont(9)
                    .foregroundStyle(Rice.overlay0)
                    .layoutPriority(1)
                    .accessibilityLabel("Fill-in template")
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
        .accessibilityLabel("\(snippet.title): \(snippet.body)")
    }
}
