# trill reference

Build, test, and provider detail — the material that used to live in the README.

## Requirements

- macOS 14 or newer
- Xcode 26.2 or a compatible Swift 6.2 toolchain
- System Integrity Protection enabled

Never disable SIP for this project.

Fixture mode needs none of the runtime permissions: no Full Disk Access, no
Contacts, no Accessibility, no Automation, and no signed-in Messages account.

## Build and run in Xcode

1. Open `Trill.xcodeproj`.
2. Wait for Swift Package Manager to resolve dependencies.
3. If Xcode asks whether to trust the `PlatformSDKMacros` build macro from the
   pinned package, review and approve it.
4. Select the **Trill** scheme and **My Mac** destination.
5. Press **⌘R**. The app opens in **Synthetic Fixture** mode.

Worth trying in fixture mode: select conversations, scroll back through a thread
(older pages load automatically as you near the top; **Load Earlier Messages**
stays as a manual fallback), **⌘K** search, pin from a sidebar context menu, edit
a draft, zoom with **⌘+/⌘−/⌘0**, pick an accent in Settings, and open the health
popover from the sidebar footer. The composer is deliberately disabled in fixture
mode and never fakes a send.

## Tests

Run with **⌘U**, or from Terminal:

```sh
xcodebuild -skipMacroValidation \
  -project Trill.xcodeproj \
  -scheme Trill \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

`-skipMacroValidation` is for unattended command-line builds; it does not replace
reviewing the macro trust prompt in Xcode.

If this checkout lives in an iCloud-synced folder (e.g. `~/Documents`), point
`-derivedDataPath` somewhere unsynced (or omit it to use Xcode's default).
iCloud's file provider tags freshly built bundles with extended attributes, which
fails codesign with "resource fork, Finder information, or similar detritus not
allowed".

## Providers

The provider picker offers **Synthetic Fixtures** and **Live**. (It said
"Messages" until live mode became a composite of the native provider and the
Beeper adapter — see ADR 0003/0004. The persisted `providerMode` value is still
`messages`; only the label moved.)

Selecting Live performs only a direct `SQLITE_OPEN_READONLY` probe. If Full
Disk Access is absent, the app explains it and links to System Settings. If
access exists, Live reads over `LiveIMessageProvider` — nothing further gates
it — plus `BeeperProvider` when a Beeper token is stored.

### The live provider

`Providers/LiveIMessage/` — read-only SQL over `chat.db` for iMessage, SMS, and
RCS conversations, messages, reactions, replies, attachments, and search
(including typedstream `attributedBody` decoding). Sending goes via AppleScript
to Messages.app. New-message polling drives live updates. Contact-name resolution
uses the Contacts framework.

App-owned SQLite migrations cover pins, drafts, provider cursors, and local read
marks — Trill's own state, in Trill's own database.

### The dormant adapter

The older [`beeper/platform-imessage`](https://github.com/beeper/platform-imessage)
adapter remains in the tree but is unused by the UI: its public `PlatformAPI`
opens `chat.db` read-write to create indexes. Trill's policy no longer forbids
that outright — a vetted, well-maintained library may manage its own `chat.db`
writes — so enabling the adapter is gated on vetting it plus a signed-host
validation pass. The UI never constructs `PlatformIMessageProvider`.

See [ADR 0001](architecture-decisions/0001-messages-provider.md) and
[ADR 0002](architecture-decisions/0002-live-imessage-provider.md).

## Design system

Flat dark UI on the Nebelung palette (desaturated Catppuccin) with a selectable
accent and display density — see `Trill/DesignSystem/`.

## Brand assets

The logo set lives in [`../assets/`](../assets/) — the mark is a pair of cat-ears
over a typing-indicator speech bubble in Nebelung sky (`#9be0d5`-ish teal) on the
house grey.

| File | Use |
|---|---|
| `trill-icon.png` | app icon — cyan mark on grey (primary) |
| `trill-icon-sky.png` | app icon — grey mark on sky (inverted) |
| `trill-banner.png` | wordmark banner, cyan on grey (the README header) |

## Future BlueBubbles relay

No relay or push networking is included. The provider interface preserves that
option for a later milestone; see the
[future BlueBubbles relay design in ARCHITECTURE.md](../ARCHITECTURE.md#11-future-bluebubbles-relay-design).
