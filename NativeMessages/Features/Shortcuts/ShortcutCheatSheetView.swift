import SwiftUI

/// The ⌘/ cheat-sheet: a floating panel over a dimmed backdrop listing every
/// keybinding, grouped the way the menus are. Discoverability for a
/// keyboard-first app — closes on Esc, ⌘/ again, or a tap outside. Mirrors the
/// command palette's presentation so the two overlays feel like siblings.
struct ShortcutCheatSheetView: View {
    @ObservedObject var model: InboxModel
    // The panel has no text field to hold first-responder like the command
    // palette does, so nothing would receive Esc. A focusable panel that grabs
    // focus on appear gives `.onExitCommand` / `.onKeyPress` a responder.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                header
                RiceDivider()
                columns
            }
            .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Rice.surface1, lineWidth: 1)
            )
            .frame(width: 640)
            .padding(.top, 80)
            .padding(.bottom, 40)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .transition(.opacity)
        .onExitCommand { dismiss() }
        .onAppear { isFocused = true }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "keyboard")
                .riceFont(14)
                .foregroundStyle(Rice.subtext0)
            Text("Keyboard Shortcuts")
                .riceFont(15, .semibold)
                .foregroundStyle(Rice.text)
            Spacer(minLength: 8)
            Text("esc")
                .riceFont(9, .medium)
                .foregroundStyle(Rice.overlay0)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// Two balanced columns of sections so the sheet stays wide-and-short rather
    /// than one tall scroll. Greedy bin-packing by row count (each section weighs
    /// its shortcuts plus a header row) keeps the columns close to equal height
    /// while preserving catalog order within each. A scroll cap guards against an
    /// ever-growing catalog outrunning the window.
    private var columns: some View {
        var left: [ShortcutSection] = []
        var right: [ShortcutSection] = []
        var leftRows = 0
        var rightRows = 0
        for section in ShortcutCatalog.sections {
            let weight = section.shortcuts.count + 1
            if leftRows <= rightRows {
                left.append(section)
                leftRows += weight
            } else {
                right.append(section)
                rightRows += weight
            }
        }
        return ScrollView {
            HStack(alignment: .top, spacing: 28) {
                column(left)
                column(right)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 520)
    }

    private func column(_ sections: [ShortcutSection]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title)
                        .riceSectionHeader()
                        .padding(.leading, 2)
                    ForEach(section.shortcuts) { shortcut in
                        ShortcutRow(shortcut: shortcut)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dismiss() {
        model.isShortcutsPresented = false
    }
}

/// One label-plus-keycaps row. Label on the left, caps trailing, matching the
/// macOS menu convention and the palette's shortcut column.
private struct ShortcutRow: View {
    let shortcut: ShortcutReference

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut.label)
                .riceFont(12, .medium)
                .foregroundStyle(Rice.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(symbol: key)
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortcut.label), \(shortcut.keys.joined(separator: " "))")
    }
}

/// A single keycap glyph. Sizes to its content so multi-character tokens like
/// `1–9` or `esc` stay legible.
private struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .riceFont(11, .semibold)
            .foregroundStyle(Rice.subtext1)
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Rice.surface1, lineWidth: 1)
            )
    }
}
