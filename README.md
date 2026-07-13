# Native Messages

Native Messages is a SwiftUI foundation for a provider-neutral macOS Messages client. The current milestone is intentionally safe-by-default: a deterministic synthetic provider drives the complete inbox and timeline UI, while the real Messages adapter is compiled but safety-gated.

## What works

- Native macOS 14+ split-view app with conversation sidebar, paged timeline, ⌘K search palette, pins, draft persistence, health UI, keyboard commands, and accessibility labels.
- Flat dark UI on the Nebelung palette (desaturated Catppuccin) with a selectable accent, display density, and ⌘+/⌘−/⌘0 zoom — see `NativeMessages/DesignSystem/`.
- Synthetic iMessage, SMS, and group conversations with long history, reactions, replies, image/file metadata, and missing-attachment states.
- Provider-neutral IDs, models, capabilities, pagination, events, and send outcomes.
- App-owned SQLite migrations for pins, drafts, and provider cursors.
- Exact integration of [`beeper/platform-imessage`](https://github.com/beeper/platform-imessage) 0.24.4 and mapping tests for its public `PlatformSDK` DTOs.
- Read-only Messages database permission/schema probe.

Real Messages reads and sends are **not enabled**. Version 0.24.4 constructs its public `PlatformAPI` with index creation enabled, which can write indexes into Apple's `chat.db`. The adapter therefore never constructs `PlatformAPI`; see [ADR 0001](docs/architecture-decisions/0001-messages-provider.md).

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

## Future BlueBubbles relay

No relay or push networking is included. The provider interface preserves that option for a later milestone; see the [future BlueBubbles relay design in ARCHITECTURE.md](ARCHITECTURE.md#11-future-bluebubbles-relay-design).
