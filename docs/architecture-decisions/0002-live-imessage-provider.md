# ADR 0002: Live iMessage provider via direct read-only SQL + AppleScript send

## Status

Accepted (supersedes the safety gate consequence of ADR 0001 while keeping its analysis).

> **Amended 2026-07-18:** the native path described here stays read-only and remains what ships. Separately, the *policy* has since been relaxed so a vetted, well-maintained third-party library may write to `chat.db` on Trill's behalf — see the current [Core invariant](../security.md). That does not change this ADR's decision; it only means the `platform-imessage` route is no longer categorically off the table.

## Context

ADR 0001 gated the `platform-imessage` adapter because its public `PlatformAPI`
opens a read-write connection to Apple's `chat.db` and can create indexes.
Waiting for an upstream `createIndexes: false` path stalled the product at
fixtures-only. The user decision for this repo is to read and send real
messages now.

## Decision

Bypass `platform-imessage` for live use and implement the provider natively:

- **Reads:** `ChatDatabaseReader` opens `chat.db` with `SQLITE_OPEN_READONLY`
  per call and issues plain SELECTs (chats, messages, handles, reactions,
  attachments, search). Message bodies with NULL `text` are decoded from the
  typedstream `attributedBody` blob (`TypedstreamText`), validated against
  real rows before adoption.
- **Sends:** `MessagesSender` shells to `osascript`, targeting
  `chat id <chat.guid>` in Messages.app with a participant fallback for 1:1
  chats. Messages.app owns persistence; the app never writes `chat.db`.
- **Live updates:** the provider polls `MAX(message.ROWID)` every 2 seconds
  and emits `messageAdded`/`conversationUpdated` events.
- **Names:** `ContactsNameResolver` maps handles to contact names (suffix-10
  phone matching, lowercased emails) when Contacts access is granted.

The gated `PlatformIMessageProvider` and its mapper stay in the tree for the
mapping tests, but the UI no longer offers it.

## Consequences

- The write-risk ADR 0001 identified is structurally absent: no write-capable
  connection to `chat.db` exists anywhere in the app.
- Requires Full Disk Access (reads) and the Automation permission (sends).
- Mark-as-read, tapbacks, editing, and typing indicators are not possible on
  this path — they would require writing to `chat.db` or private APIs.
- The chat.db schema is undocumented; queries pin to long-stable columns and
  the provider surfaces `unsupportedSchema` health if the probe fails.
