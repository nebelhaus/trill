# Native Messages

Native Messages is a provider-neutral macOS Messages client in SwiftUI. The live provider reads your real conversations straight from Apple's `chat.db` (always read-only) and sends by driving Messages.app over Apple Events; a deterministic synthetic provider remains available for development.

## What works

- Native macOS 14+ split-view app with conversation sidebar, paged timeline, ⌘K search palette, pins, draft persistence, health UI, keyboard commands, and accessibility labels.
- Flat dark UI on the Nebelung palette (desaturated Catppuccin) with a selectable accent, display density, and ⌘+/⌘−/⌘0 zoom — see `NativeMessages/DesignSystem/`.
- **Live Messages provider** (`Providers/LiveIMessage/`): read-only SQL over `chat.db` for iMessage/SMS/RCS conversations, messages, reactions, replies, attachments, and search (including typedstream `attributedBody` decoding); sending via AppleScript to Messages.app; new-message polling for live updates; contact-name resolution via the Contacts framework.
- Read receipts and delivery status on outgoing messages, inline image thumbnails, Quick Look previews on attachments, clickable links, edited markers, hidden unsent messages, sender avatars in group timelines, and a Dock badge with the total unread count.
- Quoted reply bubbles with jump-to-original, reply-count links, and tapbacks grouped by emoji with counts and own-reaction tinting (display only — Messages.app has no automation surface for sending tapbacks or threaded replies).
- macOS notifications for incoming messages (click opens the thread, or type an inline Reply to send straight from the banner), ⌘N compose to any contact with autocomplete (existing 1:1 threads open in place), attach via paperclip / drag-drop / paste, and search results that jump to the matched message with a highlight.
- Synthetic iMessage, SMS, and group conversations with long history, reactions, replies, image/file metadata, and missing-attachment states.
- Provider-neutral IDs, models, capabilities, pagination, events, and send outcomes.
- App-owned SQLite migrations for pins, drafts, provider cursors, and local read marks.
- Read-only Messages database permission/schema probe.

The live provider never writes to `chat.db` — every connection is `SQLITE_OPEN_READONLY` and sends go through Messages.app, which owns its own persistence. The older [`beeper/platform-imessage`](https://github.com/beeper/platform-imessage) adapter remains in the tree but unused by the UI: its public `PlatformAPI` can create indexes in `chat.db`, which is why it was gated (see [ADR 0001](docs/architecture-decisions/0001-messages-provider.md)) and ultimately bypassed in favor of the direct reader.

## Permissions

- **Full Disk Access** — required to read `~/Library/Messages/chat.db`. Grant it to the built app bundle (not Terminal) in System Settings → Privacy & Security.
- **Automation ("control Messages")** — prompted on first send.
- **Contacts** — optional; grants names *and* contact photos via the Contacts framework. Without it, names still resolve by reading the local AddressBook store directly (covered by Full Disk Access); only photos are missing.

- **Notifications** — optional; prompted on first launch with the live provider.

Marking conversations as read upstream is not possible (that would require writing to `chat.db`); opening a thread clears its badge locally and the mark persists in the app's own database.

## Requirements

- macOS 14 or newer
- Xcode 26.2 or a compatible Swift 6.2 toolchain
- System Integrity Protection enabled

Fixture mode does not need Full Disk Access, Contacts, Accessibility, Automation, or a signed-in Messages account.

## Build and run in Xcode

1. Open `NativeMessages.xcodeproj`.
2. Wait for Swift Package Manager to resolve dependencies.
3. If Xcode asks whether to trust the `PlatformSDKMacros` build macro from the pinned package, review and approve it.
4. Select the **NativeMessages** scheme and **My Mac** destination.
5. Press **⌘R**. The app opens in **Synthetic Fixture** mode.

Try selecting conversations, **Load Earlier Messages**, **⌘K** search, pinning from a sidebar context menu, editing a draft, zooming with **⌘+/⌘−/⌘0**, picking an accent in Settings, and opening the health popover from the sidebar footer. The composer is deliberately disabled and never fakes a send.

Run tests with **⌘U**, or use Terminal:

```sh
xcodebuild -skipMacroValidation \
  -project NativeMessages.xcodeproj \
  -scheme NativeMessages \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

`-skipMacroValidation` is for unattended command-line builds; it does not replace reviewing the macro trust prompt in Xcode.

If this checkout lives in an iCloud-synced folder (e.g. `~/Documents`), point `-derivedDataPath` somewhere unsynced (or omit it to use Xcode's default). iCloud's file provider tags freshly built bundles with extended attributes, which fails codesign with "resource fork, Finder information, or similar detritus not allowed".

## Provider and permissions

The provider picker offers **Synthetic Fixture** and **Messages (Safety-gated)**. Selecting Messages performs only a direct `SQLITE_OPEN_READONLY` probe. If Full Disk Access is absent, the app explains it and links to System Settings. If access exists, the provider still remains gated until `platform-imessage` exposes a public, end-to-end `createIndexes: false` construction path and a signed-host validation pass succeeds.

Never disable SIP for this project. Full Disk Access, when eventually used, belongs to the built app's bundle identity—not Terminal—when launched from Xcode or Finder.

## Documentation

- [Product requirements](PRD.md)
- [Architecture](ARCHITECTURE.md)
- [Provider decision](docs/architecture-decisions/0001-messages-provider.md)
- [Testing guide](docs/testing.md)
- [Security boundaries](docs/security.md)
- [Ideas & feature backlog](docs/ideas.md)

## Future BlueBubbles relay

No relay or push networking is included. The provider interface preserves that option for a later milestone; see the [future BlueBubbles relay design in ARCHITECTURE.md](ARCHITECTURE.md#11-future-bluebubbles-relay-design).
