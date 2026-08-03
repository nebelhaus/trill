# Copilot instructions

**Read [`AGENTS.md`](../AGENTS.md) at the repo root first — it is the full,
authoritative instruction set for every agent working here, and this file is
only a pointer to it.** (Copilot doesn't follow file imports, hence the
duplication below; if the two ever disagree, `AGENTS.md` wins.)

The short version:

- Trill is a provider-neutral **Messages client for macOS** (iMessage / SMS /
  RCS) in a native SwiftUI window, in the
  [nebelhaus](https://github.com/nebelhaus) family.
- **The one rule that explains everything: trill's own code never writes to
  `chat.db`.** Every connection to Apple's Messages database is
  `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX` — no `INSERT`/`UPDATE`/
  `DELETE`, no index creation, migration, vacuum, repair, or write-capable
  pragma. Sending drives Messages.app over Apple Events; it is not a DB write.
  **A PR that hand-rolls a `chat.db` write is wrong no matter what it fixes.**
- **Two databases, never confused:** Apple's `chat.db` (read-only, providers
  only) and the app-owned overlay `app.sqlite3`. Provider message history is
  never copied into the overlay.
- **Provider-neutral by construction:** third-party DTOs stay confined to their
  `Providers/*` folder; nothing outside `Providers/` imports them. That's an
  acceptance criterion (`ARCHITECTURE.md §20`), not a style preference.
- **Migration renumber discipline:** overlay migrations are numbered, parallel
  branches collide, and **the second PR to land renumbers** — in the
  `migrations` array, `currentSchemaVersion`, and the `AppDatabaseTests`
  assertion. A migration numbered ≤ the DB's current version is silently
  skipped.
- **No sensitive data in logs, tests, snapshots or bug reports** — OSLog carries
  operation type / duration / count only, never bodies, handles, attachment
  paths or SQL rows.
- **CI owns the version pins.** `VERSION` is CalVer, cut with `bench release
  trill`; the release workflow rewrites `nix/release.nix` here and
  `Casks/trill.rb` in the tap. Never hand-bump either.

For review comments, the same bar applies as anywhere in the family:
correctness and boundaries (does this change belong in *this* repo?) over style.
