import Foundation

/// One keybinding row in the cheat-sheet: a human label and the sequence of
/// keycaps that trigger it. `keys` is rendered as individual caps (e.g.
/// `["⇧", "⌘", "F"]`), so a multi-character token like `"1–9"` becomes one wider
/// cap. Kept as plain data so the catalog stays testable and view-free.
struct ShortcutReference: Identifiable, Hashable {
    let keys: [String]
    let label: String
    var id: String { label }
}

/// A titled group of related shortcuts, mirroring how they read in the menus.
struct ShortcutSection: Identifiable, Hashable {
    let title: String
    let shortcuts: [ShortcutReference]
    var id: String { title }
}

/// The single source of truth for the ⌘/ cheat-sheet. Hand-maintained to stay in
/// lockstep with `AppCommands` (SwiftUI's `Commands` don't expose their bindings
/// for reflection) plus the contextual keys the composer and overlays own. When a
/// shortcut changes in `AppCommands`, update the matching row here.
enum ShortcutCatalog {
    static let sections: [ShortcutSection] = [
        ShortcutSection(title: "Navigation & Search", shortcuts: [
            ShortcutReference(keys: ["⌘", "K"], label: "Command palette"),
            ShortcutReference(keys: ["⇧", "⌘", "F"], label: "Search messages"),
            ShortcutReference(keys: ["⇧", "⌘", "L"], label: "Universal library"),
            ShortcutReference(keys: ["⌘", "F"], label: "Find in conversation"),
            ShortcutReference(keys: ["⌘", "G"], label: "Find next match"),
            ShortcutReference(keys: ["⇧", "⌘", "G"], label: "Find previous match"),
            ShortcutReference(keys: ["⌘", "J"], label: "Jump to date"),
            ShortcutReference(keys: ["⌘", "["], label: "Back (previously viewed)"),
            ShortcutReference(keys: ["⌘", "]"], label: "Forward"),
            ShortcutReference(keys: ["⌘", "1–9"], label: "Jump to pinned conversation"),
        ]),
        ShortcutSection(title: "Conversations", shortcuts: [
            ShortcutReference(keys: ["⌘", "N"], label: "New message"),
            ShortcutReference(keys: ["⌃", "⌘", "V"], label: "Add / remove VIP"),
            ShortcutReference(keys: ["⇧", "⌘", "P"], label: "Pin / unpin conversation"),
            ShortcutReference(keys: ["⇧", "⌘", "U"], label: "Unread only"),
            ShortcutReference(keys: ["⇧", "⌘", "R"], label: "Needs reply only"),
            ShortcutReference(keys: ["⌘", "R"], label: "Reload"),
        ]),
        ShortcutSection(title: "View", shortcuts: [
            ShortcutReference(keys: ["⌃", "⌘", "S"], label: "Toggle sidebar"),
            ShortcutReference(keys: ["⌘", "="], label: "Zoom in"),
            ShortcutReference(keys: ["⌘", "-"], label: "Zoom out"),
            ShortcutReference(keys: ["⌘", "0"], label: "Actual size"),
            ShortcutReference(keys: ["⌘", ","], label: "Settings"),
            ShortcutReference(keys: ["⌘", "/"], label: "Keyboard shortcuts"),
        ]),
        ShortcutSection(title: "Composer", shortcuts: [
            ShortcutReference(keys: ["/"], label: "Snippets & slash commands"),
            ShortcutReference(keys: ["⇥"], label: "Next template blank"),
            ShortcutReference(keys: ["⇧", "⇥"], label: "Previous template blank"),
            ShortcutReference(keys: ["esc"], label: "Undo send · dismiss picker"),
        ]),
    ]
}
