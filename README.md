<div align="center">

<!-- identity banner — cyan wordmark on grey (assets/trill-banner.png) -->
<img src="./assets/trill-banner.png" alt="trill" width="420">

**your Messages, native**

the messages — iMessage, SMS, and RCS in a real macOS window, read straight from
`chat.db`.

![part of nebelhaus](https://img.shields.io/badge/part_of-nebelhaus-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![brew](https://img.shields.io/badge/brew-nebelhaus%2Ftap-f5b58e?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

</div>

---

Trill is a fast, flat, provider-neutral Messages client in SwiftUI. It reads your
real conversations directly from Apple's `chat.db` — **always read-only** — and
sends by driving Messages.app over Apple Events.

Your messages stay on your Mac. Nothing is relayed, uploaded, or phoned home.

📖 **[nebelhaus.com/trill](https://nebelhaus.com/trill)**

## why trill

- **read-only, by construction** — every connection is `SQLITE_OPEN_READONLY`. Sends go through Messages.app, which owns its own persistence. Trill never writes to your message database.
- **flat and fast** — a native macOS 14+ split view on the nebelung palette. no web view, no chat bubbles pretending to be a website.
- **themeable at runtime** — dark or latte, normal or high-contrast, following macOS or pinned; drop any nebelung/Catppuccin hex JSON into `~/.config/trill/themes/` and pick it in Settings. no rebuild.
- **keyboard-first** — ⌘K search palette, ⌘[ / ⌘] through recently-viewed threads, ⌘N compose, ⌘+/−/0 zoom.
- **provider-neutral** — the live reader is one provider behind a neutral interface. a deterministic synthetic provider ships alongside it for development.

## install

```sh
brew install --cask nebelhaus/tap/trill
```

Signed with our Apple Developer ID and notarized, so it opens straight away — no
Gatekeeper prompt, no quarantine hack.

Trill ships by default in the [nebelhaus](https://github.com/nebelhaus) rice, but
it stands alone — the cask works on any Mac running macOS 14 or newer.

## the taste

Launch it and pick **Messages** in the provider picker. That's it — if Full Disk
Access is granted, your threads are there. Without it, Trill explains what's
missing and links you to the right System Settings pane.

Two permissions matter:

- **Full Disk Access** — required, to read `~/Library/Messages/chat.db`. Grant it to the app bundle, not Terminal.
- **Automation ("control Messages")** — prompted on first send.

Contacts and Notifications are both optional. Full detail in
[`docs/permissions.md`](docs/permissions.md).

## what works

- Conversation sidebar, paged timeline that loads older messages as you scroll, pins, draft persistence, and a health popover.
- Reactions grouped by emoji with counts, quoted reply bubbles with jump-to-original, edited markers, and hidden unsent messages.
- Read receipts and delivery status, inline image thumbnails, Quick Look on attachments, clickable links, sender avatars in group threads, and a Dock badge for unread count.
- Notifications for incoming messages — click to open the thread, or type an inline reply to send straight from the banner.
- ⌘N compose to any contact with autocomplete; attach via paperclip, drag-drop, or paste.
- Search across conversations that jumps to the matched message and highlights it, including typedstream `attributedBody` decoding.
- Contact names and photos via the Contacts framework, falling back to the local AddressBook store when Contacts is denied.
- Update checking that knows how you installed it: a drag-install updates itself, a Homebrew cask defers to `brew`, and a rice/Nix install is told the command to run instead. Hourly, off by a Settings toggle, plus ⌘-menu › Check for Updates.

Two things Messages.app gives no automation surface for, so Trill displays but
cannot send: **tapbacks** and **threaded replies**. Marking conversations read
upstream is likewise impossible — that would mean writing to `chat.db` — so
opening a thread clears its badge locally, in Trill's own database.

## more

- [nebelhaus.com/trill](https://nebelhaus.com/trill) — the product page
- [Reference](docs/reference.md) — building, testing, and the provider architecture
- [Permissions](docs/permissions.md) — what Trill asks for, and why
- [Architecture](ARCHITECTURE.md) · [Security boundaries](docs/security.md) · [Testing guide](docs/testing.md)
- [The trill guide](https://nebelhaus.com/guides/trill/) — using trill inside the rice

## the family

- 🏠 [**nebelhaus**](https://github.com/nebelhaus/nebelhaus) — the house. the whole rice, one Nix flake. start here.
- 🐾 [**pounce**](https://github.com/nebelhaus/pounce) — the palette. keyboard-first launcher; every command a file.
- 🐦 [**trill**](https://github.com/nebelhaus/trill) — the messages. native iMessage/SMS/RCS, read from `chat.db`. *(you are here)*
- 🪺 [**perch**](https://github.com/nebelhaus/perch) — the shelf. files, caught in the notch.
- 🌫️ [**nebelung**](https://github.com/nebelhaus/nebelung) — the theme. the silver-mist palette.
- 🧰 [**workshop**](https://github.com/nebelhaus/workshop) — the bench. where the family is built.

Each one stands alone. Together they're a house.

## license

MIT © nebelhaus
