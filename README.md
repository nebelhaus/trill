<div align="center">

<!-- identity banner — sky wordmark on grey (assets/trill-banner.png) -->
<img src="./assets/trill-banner.png" alt="trill" width="420">

**your Messages, native**

a fast, flat, provider-neutral Messages client for macOS — iMessage, SMS, and RCS
in a real native window, reading straight from `chat.db` (always read-only).

![part of nebelhaus](https://img.shields.io/badge/part_of-nebelhaus-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![brew](https://img.shields.io/badge/brew-nebelhaus%2Ftap-f5b58e?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

</div>

---

Trill is a provider-neutral macOS Messages client in SwiftUI. The live provider reads
your real conversations straight from Apple's `chat.db` (always read-only) and sends by
driving Messages.app over Apple Events; a deterministic synthetic provider remains
available for development.

## Install

```sh
# Homebrew (nebelhaus tap)
brew install --cask nebelhaus/tap/trill
```

The app is signed with our Apple Developer ID and notarized by Apple, so the cask
installs it and it opens straight away — no Gatekeeper prompt, no quarantine hack.
(If you build or copy the app by hand instead of installing the cask, macOS may
still quarantine your copy; clear it with
`xattr -dr com.apple.quarantine /Applications/Trill.app`.)

Trill is part of the [nebelhaus](https://github.com/nebelhaus) family and ships by
default in the rice, but it stands alone — install the cask above on any Mac.

## What works

- Native macOS 14+ split-view app with conversation sidebar, paged timeline, ⌘K search palette, ⌘[ / ⌘] back/forward through recently-viewed threads, pins, draft persistence, health UI, keyboard commands, and accessibility labels.
- Flat dark UI on the Nebelung palette (desaturated Catppuccin) with a selectable accent, display density, and ⌘+/⌘−/⌘0 zoom — see `Trill/DesignSystem/`.
- **Live Messages provider** (`Providers/LiveIMessage/`): read-only SQL over `chat.db` for iMessage/SMS/RCS conversations, messages, reactions, replies, attachments, and search (including typedstream `attributedBody` decoding); sending via AppleScript to Messages.app; new-message polling for live updates; contact-name resolution via the Contacts framework.
- Read receipts and delivery status on outgoing messages, inline image thumbnails, Quick Look previews on attachments, clickable links, edited markers, hidden unsent messages, sender avatars in group timelines, and a Dock badge with the total unread count.
- Quoted reply bubbles with jump-to-original, reply-count links, and tapbacks grouped by emoji with counts and own-reaction tinting (display only — Messages.app has no automation surface for sending tapbacks or threaded replies).
- macOS notifications for incoming messages (click opens the thread, or type an inline Reply to send straight from the banner), ⌘N compose to any contact with autocomplete (existing 1:1 threads open in place), attach via paperclip / drag-drop / paste, and search results that jump to the matched message with a highlight.
- Synthetic iMessage, SMS, and group conversations with long history, reactions, replies, image/file metadata, and missing-attachment states.
- Provider-neutral IDs, models, capabilities, pagination, events, and send outcomes.
- App-owned SQLite migrations for pins, drafts, provider cursors, and local read marks.
- Read-only Messages database permission/schema probe.

The live provider never writes to `chat.db` — every connection is `SQLITE_OPEN_READONLY` and sends go through Messages.app, which owns its own persistence. The older [`beeper/platform-imessage`](https://github.com/beeper/platform-imessage) adapter remains in the tree but unused by the UI: its public `PlatformAPI` opens `chat.db` read-write to create indexes. Trill's policy no longer forbids that outright — a vetted, well-maintained library may manage its own `chat.db` writes — so enabling the adapter is gated on vetting it plus a signed-host validation pass (see [ADR 0001](docs/architecture-decisions/0001-messages-provider.md)); this milestone simply ships the direct read-only reader instead.

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

1. Open `Trill.xcodeproj`.
2. Wait for Swift Package Manager to resolve dependencies.
3. If Xcode asks whether to trust the `PlatformSDKMacros` build macro from the pinned package, review and approve it.
4. Select the **Trill** scheme and **My Mac** destination.
5. Press **⌘R**. The app opens in **Synthetic Fixture** mode.

Try selecting conversations, scrolling back through a thread (older pages load automatically as you near the top; **Load Earlier Messages** stays as a manual fallback), **⌘K** search, pinning from a sidebar context menu, editing a draft, zooming with **⌘+/⌘−/⌘0**, picking an accent in Settings, and opening the health popover from the sidebar footer. The composer is deliberately disabled and never fakes a send.

Run tests with **⌘U**, or use Terminal:

```sh
xcodebuild -skipMacroValidation \
  -project Trill.xcodeproj \
  -scheme Trill \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

`-skipMacroValidation` is for unattended command-line builds; it does not replace reviewing the macro trust prompt in Xcode.

If this checkout lives in an iCloud-synced folder (e.g. `~/Documents`), point `-derivedDataPath` somewhere unsynced (or omit it to use Xcode's default). iCloud's file provider tags freshly built bundles with extended attributes, which fails codesign with "resource fork, Finder information, or similar detritus not allowed".

## Provider and permissions

The provider picker offers **Synthetic Fixture** and **Messages (Safety-gated)**. Selecting Messages performs only a direct `SQLITE_OPEN_READONLY` probe. If Full Disk Access is absent, the app explains it and links to System Settings. If access exists, Messages mode reads live over `LiveIMessageProvider` — nothing further gates it. The vetting/signed-host gate applies only to the dormant `PlatformIMessageProvider`, which the UI never constructs (see [ADR 0002](docs/architecture-decisions/0002-live-imessage-provider.md)).

Never disable SIP for this project. Full Disk Access, when eventually used, belongs to the built app's bundle identity—not Terminal—when launched from Xcode or Finder.

## Documentation

- [Product requirements](PRD.md)
- [Architecture](ARCHITECTURE.md)
- [Provider decision](docs/architecture-decisions/0001-messages-provider.md)
- [Testing guide](docs/testing.md)
- [Security boundaries](docs/security.md)
- [Ideas & feature backlog](docs/ideas.md)

## Brand assets

The logo set lives in [`assets/`](assets/) — the mark is a cat-eared speech
bubble in Nebelung sky (`#9be0d5`-ish teal) on the house grey.

| File | Use |
|---|---|
| [`trill-icon.png`](assets/trill-icon.png) | app icon — sky bubble on grey (primary) |
| [`trill-icon-sky.png`](assets/trill-icon-sky.png) | app icon — grey bubble on sky (inverted) |
| [`trill-banner.png`](assets/trill-banner.png) | wordmark banner, sky on grey (the header above) |
| [`trill-banner-sky.png`](assets/trill-banner-sky.png) | wordmark banner, grey on sky, with the "your Messages, native" line |
| [`trill-repo-banner.png`](assets/trill-repo-banner.png) | 1280×640 repo header / GitHub social-preview + OG image |

`trill-repo-banner.png` is the one to upload under **Settings → Social preview**.

## Future BlueBubbles relay

No relay or push networking is included. The provider interface preserves that option for a later milestone; see the [future BlueBubbles relay design in ARCHITECTURE.md](ARCHITECTURE.md#11-future-bluebubbles-relay-design).
