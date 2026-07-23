# CLAUDE.md

**Trill** — a fast, flat, provider-neutral Messages client for macOS (iMessage /
SMS / RCS) in a real native SwiftUI window, reading straight from Apple's
`chat.db` **always read-only**. Part of the [nebelhaus](https://github.com/nebelhaus)
family. Ships by default in the rice, but stands alone — `brew install --cask
nebelhaus/tap/trill` on any Mac.

## Am I in the right repo? (routing)

**This repo (`~/code/nebelhaus/trill`) owns THE MESSAGES CLIENT** — the SwiftUI app,
its providers over `chat.db`, and its own local overlay database. Nothing about how
it's launched, themed at the source, or packaged.

| Want to change… | Repo |
|---|---|
| the trill app (UI, providers, inbox/conversation/search/library) | `~/code/nebelhaus/trill` ← **you are here** |
| how trill is *installed* on the system (the `nebelhaus.trill.enable` cask wiring) | `~/code/nebelhaus/nebelhaus` → `modules/trill` |
| the palette trill is themed with (the source hex) | `~/code/nebelhaus/nebelung` |
| trill's Homebrew cask (`Casks/trill.rb`) | `~/code/nebelhaus/homebrew-tap` — **CI-owned**; never hand-bump url/sha/version |
| user-facing docs / guides (nebelhaus.com) | `~/code/nebelhaus/workshop` (`web/`, Astro Starlight) |

> **Claude: enforce this.** If a request is about launching/signing trill, its cask,
> or the palette's source values, STOP and point at the right repo before editing here.

## The one rule that explains everything

**Trill's own code never writes to `chat.db`.** Every connection the app opens to
Apple's Messages database is `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` — no
hand-rolled `INSERT`/`UPDATE`/`DELETE`, no index creation, migration, vacuum, repair,
or write-capable pragma. Sending is **not** a DB write: it drives Messages.app over
Apple Events (`osascript`), and Messages.app owns its own persistence. Marking read
upstream, tapbacks, threaded replies, edits/unsends — none are possible from the
native path, so the providers expose **no send capability** for them (display only).

The one sanctioned exception, still dormant: a **vetted, well-maintained third-party
library** (Beeper's `platform-imessage` is the intended example) may manage its own
`chat.db` writes. It's pinned and compiled but **not instantiated** — gated on a
signed-host vetting/validation pass (see `docs/architecture-decisions/0001-messages-provider.md`).
Until then live capabilities are empty and calls fail closed. Never hand-roll a
`chat.db` write to "just make it work." SIP stays enabled throughout.

## Architecture

```
Trill/
  App/                     # @main, window/scene, AppCommands (menu + keybindings)
  Domain/                  # provider-neutral models (Message, Conversation, IDs, capabilities)
  Providers/
    MessagesProvider.swift # the protocol: IDs, models, capabilities, pagination, events, send outcomes
    LiveIMessage/          # SHIPPING provider — read-only chat.db + AppleScript send (ADR 0002)
      ChatDatabaseReader.swift    # read-only SELECTs over chats/messages/handles/reactions/attachments
      ChatDatabaseWatcher.swift   # chat.db-wal watcher (live updates) + polling fallback
      TypedstreamText.swift       # decode NULL text bodies from the attributedBody blob
      MessagesSender.swift        # osascript → Messages.app (content passed as arg, never interpolated)
      ContactsNameResolver.swift / AddressBookReader.swift  # names/photos
    FixtureProvider/       # deterministic synthetic data — the dev default, no permissions needed
    PlatformIMessageProvider/  # Beeper adapter — compiled, gated, not instantiated
  Persistence/             # AppDatabase — the app-owned overlay DB (app.sqlite3)
  Repositories/            # bridge providers ↔ features
  Features/                # Inbox, Conversation, Composer, CommandPalette, Search, Library,
                           #   MenuBar, Settings, Shortcuts, Compose
  Notifications/           # local notifications + inline reply
  Platform/
    Permissions/           # read-only FDA/schema probe; health states
    Logging/               # AppLog.swift — OSLog, non-content only (see Gotchas)
  DesignSystem/            # Rice.swift (the nebelung palette) + shared views
  Config/                  # Trill.entitlements
  Assets.xcassets          # app icon + asset catalog
```

**Two databases, never confused:** Apple's `chat.db` (read-only, providers only) and
the app-owned `app.sqlite3` under Application Support (`Persistence/AppDatabase`).
The overlay DB stores pins, drafts, provider cursors, local read marks, folders/tags,
VIP, snooze/archive/mute, saved messages, link previews — **provider message history
is never copied into it**. Every overlay feature is an additive table; nothing that
touches it reaches `chat.db`.

**Provider-neutral by construction:** features and views speak the `Domain` models
only. Third-party DTOs (`platform-imessage`/`PlatformSDK`, future BlueBubbles) stay
confined to their `Providers/*` folder — nothing outside `Providers/` imports them.
This is an acceptance criterion (`ARCHITECTURE.md §20`), not a style preference.

## Build / test

It's an Xcode project (Swift 6.0 language mode / Xcode 26.2, min macOS 14), no SPM
manifest of its own; it pins `beeper/platform-imessage` as a package.

```sh
# Xcode: open Trill.xcodeproj, Trill scheme, My Mac, ⌘R — opens in Synthetic Fixture mode.
# CLI:
xcodebuild -skipMacroValidation -project Trill.xcodeproj -scheme Trill \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

- **Fixture mode is the dev default** — no Full Disk Access, Contacts, Automation, or
  signed-in Messages account. The composer is deliberately disabled in fixtures and
  never fakes a send.
- `-skipMacroValidation` is for unattended CLI builds only; in Xcode you still review
  the `PlatformSDKMacros` macro-trust prompt.
- CI (`.github/workflows`) builds + tests on macOS; `release.yml` cuts the cask.

## Gotchas

- **iCloud-synced checkout breaks codesign.** If the repo lives under `~/Documents`
  (or any iCloud folder), point `-derivedDataPath` somewhere unsynced — iCloud tags
  fresh bundles with xattrs and codesign dies with "resource fork … not allowed."
- **Full Disk Access belongs to the built app bundle, not Terminal/Xcode.** Grant it
  to `Trill.app`'s signed identity. Automation ("control Messages") is prompted on
  first send; Contacts + Notifications are optional health dimensions, not requested
  at launch.
- **Migration renumber discipline (the merge trap).** Overlay features add
  `AppDatabase` migrations by number; parallel worktree branches routinely collide on
  the same number. Rule: **the second PR to land renumbers** (rebase before
  merging) — in the `migrations` array, `currentSchemaVersion`, and the
  `AppDatabaseTests` assertion. All migrations
  are `CREATE TABLE IF NOT EXISTS` so a shared overlay DB advanced by another branch
  still upgrades instead of failing `init` and dropping to a throwaway temp store. A
  migration numbered ≤ the DB's current version is silently skipped — that's the bug
  this discipline prevents. (`docs/ideas.md` records the actual renumber history.)
- **Capability + health gate the UI, together.** A feature enables only when the
  provider's capabilities AND sending health both allow it. Unknown send outcomes are
  surfaced, never presented as success, and never auto-retried (the message may
  already have gone).
- **No sensitive data in logs/tests/snapshots.** OSLog carries operation type /
  duration / count / non-content error category — never bodies, handles, attachment
  paths, or SQL rows. Real Messages data must never be promoted into tests, fixtures,
  bug reports, or source control (`docs/security.md`).

## Theming

Colors live in `DesignSystem/Rice.swift` (the **nebelung** palette). Because Trill
builds outside Nix, it can't consume nebelung's generated `palette` flake output the
way pounce does — the hex literals are **hand-copied** from
`nebelung/palette/nebelung.hex.json`. A palette change in nebelung must be mirrored
here by hand (Trill uses a subset — `overlay2`/`rosewater`/`flamingo` omitted). The
accent is user-selectable at runtime; density and ⌘+/⌘−/⌘0 zoom are settings.

## Release

**CalVer, date-based** — same as the rest of the family. `bench release trill` (from
the workshop) stamps today's date into `VERSION` (`YYYY.MM.DD`, `-N` on a same-day
repeat), commits, tags `v<date>`; CI then builds the `.app`, signs it with our Apple
Developer ID (hardened runtime) and notarizes it with Apple, publishes the GitHub
release, and bumps `homebrew-tap`'s `Casks/trill.rb` over a deploy key.
Never hand-edit the cask's url/sha/version. `MARKETING_VERSION` in `project.pbxproj`
is injected from `VERSION` at release time — keep the checked-in default roughly in
sync so local dev builds don't report a stale version, but the release value is
authoritative.

## Conventions

- MIT, public. No secrets, no real message data, no personal identity in the tree.
- Docs live downstream: user-facing guides belong in `workshop/web/` (nebelhaus.com),
  not here. Keep `README.md` (shipped state), `PRD.md` (durable requirements),
  `ARCHITECTURE.md` (design + roadmap), and `docs/ideas.md` (the running idea pool
  with per-feature 🚢/🔨/🚫 status) in sync as features land — when a feature ships,
  move it out of "remaining/next" in ARCHITECTURE and flip its ideas.md status.
- Any AI/summarization feature is gated on a separate privacy/design review
  (`PRD.md`, `ARCHITECTURE.md §22`) — local-first, nothing sent off-device without an
  explicit decision.
