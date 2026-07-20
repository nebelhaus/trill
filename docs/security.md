# Security boundaries

## Core invariant

Trill's own code never writes to `~/Library/Messages/chat.db` (or any Apple-owned Messages database) — no hand-rolled `INSERT`/`UPDATE`/`DELETE`, index creation, migration, vacuum, repair, or write-capable pragma from our own SQL. Writes to that database are permitted **only** through a well-maintained, schema-aware third-party library we have deliberately vetted and trust to keep the on-disk schema correct (Beeper's `platform-imessage` is the intended example). System Integrity Protection stays enabled throughout.

Today Trill ships no such library live, so its own database access — the permission checker and the live `ChatDatabaseReader` — is strictly read-only, opened only with:

```text
SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
```

It reads `sqlite_master` only to verify that the required `chat` and `message` tables exist. It does not issue migrations, index creation, repair, vacuum, write-capable pragmas, or data mutations.

The app-owned `app.sqlite3` under Application Support is a separate database. It stores provider-qualified pin IDs, drafts, and provider event cursors; provider message history is not copied into it.

## Third-party boundary

`platform-imessage` 0.24.4 is present for compilation, DTO contract mapping, and — behind the gate described next — sending tapbacks. Its `PlatformAPI` is instantiated only through `PlatformWriteBackend`, and only for **write-backed advanced actions** (currently tapbacks). Reads never route through it: `CompositeMessagesProvider` forwards every read, search, event, and text send to the read-only `LiveIMessageProvider` baseline and delegates only `react(_:)` to the write backend. The tapback itself is Accessibility UI-automation of Messages.app, not a `chat.db` write; the sole `chat.db` write in the path is `PlatformAPI`'s own `IMDatabase(createIndexes: true)` index creation at construction — the sanctioned vetted-library exception.

This write path is **gated off by default**: `PlatformAPI` is constructed only when the hidden `platformWritesEnabled` flag is set on a host that has passed the signed-host validation pass, and tapback actions additionally require a live Accessibility grant (`AXIsProcessTrusted`) via `CapabilityGate.canReact` — capability + health, fail-closed. With the flag off, `PlatformAPI` is never constructed and behavior is byte-identical to the read-only baseline. See [ADR 0001](architecture-decisions/0001-messages-provider.md).

Third-party DTOs are confined to `Providers/PlatformIMessageProvider`. Domain, repositories, persistence, features, and views do not import them.

## Permissions

- Fixture mode: no sensitive permission required.
- Messages database: Full Disk Access, requested only after explanation and only for the signed app identity.
- Sending text: Apple Events Automation permission to control Messages.app, prompted on first send. No Accessibility permission is required on the native text-send path.
- Sending tapbacks (gated write overlay): macOS **Accessibility** permission, since `platform-imessage` drives the Messages.app tapback UI via `AXUIElement`. This is a distinct dimension from text-send Automation, surfaced as `ProviderHealth.advancedActions`; without it the tapback UI stays hidden and calls fail closed.
- Contacts and notifications: independent health dimensions; not requested at launch.
- Remote relay: absent from this milestone.

Granting Full Disk Access does not enable live integration by itself; a write-capable provider still requires a vetted, trusted library and its signed-host validation pass.

## Logging and sensitive data

OSLog categories cover provider, database, repository, UI, and permissions. Logs may contain operation type, duration, count, provider ID, and non-content error category. They must not contain:

- Message bodies or provider DTO dumps.
- Phone numbers, email addresses, contact names, or other handles.
- Attachment paths or contents.
- Tokens, credentials, raw database rows, or SQL query results.

Fixtures use reserved/example values and synthetic prose. Real Messages data must never be promoted into tests, snapshots, bug reports, or source control.

## Sending boundary

Provider capabilities and sending health must both allow an action before UI enablement. The live provider sends text and attachments by driving Messages.app over AppleScript (`osascript`) — Messages.app owns persistence, so no write ever reaches `chat.db`. Message content is passed as an AppleScript argument, never interpolated into the script source. The providers expose no send capability for tapbacks, replies, edits or mark-as-read, which the native path cannot perform. A rejected or unknown result is never presented as success, and unknown outcomes are never automatically retried because the original message may already have been delivered.

## Current threat boundary

This milestone trusts the local macOS user and does not attempt device compromise, malicious local administrator, or dependency-build isolation. It adds no analytics, updater, remote networking, push service, or background data export. Swift Package code and its build macro remain supply-chain inputs; exact resolution is recorded in `Package.resolved`, and changes require review.

Before enabling live data, review the full dependency diff, validate a signed release identity, trace all opens against the Messages directory, and confirm that every write to `chat.db` originates from the vetted third-party library and stays within its documented, schema-aware surface — never from Trill's own SQL.
