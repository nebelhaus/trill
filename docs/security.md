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

`platform-imessage` 0.24.4 is present for compilation and DTO contract mapping. Its `PlatformAPI` is not instantiated yet — not because its `IMDatabase(createIndexes: true)` write is categorically forbidden (a vetted, well-maintained library managing its own `chat.db` writes is now allowed), but because the library still owes a signed-host vetting/validation pass before we trust it live. Until then live capabilities stay empty and calls fail closed. See [ADR 0001](architecture-decisions/0001-messages-provider.md).

Third-party DTOs are confined to their provider folder — `Providers/PlatformIMessageProvider` for `platform-imessage`, `Providers/Beeper` for the Beeper Desktop API wire types. Domain, repositories, persistence, features, and views do not import them.

## Network boundary (Beeper adapter)

`BeeperProvider` is the app's first outbound network dependency beyond the update check and link previews. It talks to a **headless Beeper Server the user runs** — Trill neither bundles nor installs one. See [ADR 0004](architecture-decisions/0004-beeper-transport.md).

- **Transport.** `URLSession` only, no third-party HTTP dependency. Ephemeral session with no cookie store and no URL cache, 15s request / 60s resource timeouts, a 32 MB response ceiling, and cooperative cancellation.
- **Endpoint.** Loopback (`127.0.0.1`/`localhost`/`::1`) may use plain HTTP — the traffic never leaves the machine and that is what the Server serves. **Any non-loopback endpoint must be HTTPS** with normal certificate validation; `BeeperConfiguration.init` throws otherwise, so a remote plaintext endpoint cannot be constructed. No ATS exception, no pinning bypass.
- **Credentials.** The access token is stored **only** in the Keychain (`KeychainStore`, generic password, `kSecAttrAccessibleAfterFirstUnlock`) — never in `UserDefaults`, never in a file, never in a log line, never in a URL query. The endpoint URL is an ordinary preference and may live in `UserDefaults`.
- **Redaction.** The `Authorization` header is constructed in exactly one function and appears nowhere else. Client errors are *categories* (`unreachable`, `unauthorized`, `http503`, `malformedResponse`, …) that carry a status code at most — never a server message, response body, URL, or query string.
- **Untrusted input.** Message bodies arrive as Matrix HTML from a network boundary and are flattened to plain text by `MatrixHTMLText` (script/style content dropped, entities unescaped); no markup reaches a rendering view. Attachment bytes are streamed into an app-owned cache directory, content-addressed by SHA-256 of the remote handle so an attacker-chosen `fileName` never reaches the filesystem, capped at 64 MB per file and restricted to image/video/audio MIME types. A `localURL` never points inside Beeper's own storage.
- **Read-only.** The adapter issues no write of any kind. `send`/`react` reject with `.unsupported` and the send capability is not advertised, so no UI can offer an action the provider will not perform.
- **Fixtures.** The Server holds the user's real messages. Contract fixtures are **synthesized** — real shapes, invented content — and a raw capture must never be committed. No real name, handle, phone number, message body, avatar or `mxc://` URL in fixtures, tests, logs, commit messages or PR bodies.
- **Contract check.** `scripts/beeper-contract-check.sh` is the one place a real Server is queried by hand. It is GET-only, reads the token from the same Keychain item the app uses, keeps response bodies in a temp file deleted on exit, and emits **field names, JSON types and counts only** — values are replaced by their type, `seen`'s user-ID keys are elided, and account IDs are counted rather than printed. Its report is shareable; the responses it parses are not.

## Permissions

- Fixture mode: no sensitive permission required.
- Messages database: Full Disk Access, requested only after explanation and only for the signed app identity.
- Sending: Apple Events Automation permission to control Messages.app, prompted on first send. No Accessibility permission is required on the native send path.
- Contacts and notifications: independent health dimensions; not requested at launch.
- Beeper: no macOS permission at all — an access token the user pastes, stored in the Keychain. Optional; absent means the provider simply isn't constructed.
- BlueBubbles relay: absent from this milestone.

Granting Full Disk Access does not enable live integration by itself; a write-capable provider still requires a vetted, trusted library and its signed-host validation pass.

## Logging and sensitive data

OSLog categories cover provider, database, repository, UI, and permissions. Logs may contain operation type, duration, count, provider ID, and non-content error category. They must not contain:

- Message bodies or provider DTO dumps.
- Phone numbers, email addresses, contact names, or other handles.
- Attachment paths or contents.
- Tokens, credentials, raw database rows, or SQL query results.
- `Authorization` headers, request URLs with query strings, or HTTP response bodies.

Fixtures use reserved/example values and synthetic prose. Real Messages data must never be promoted into tests, snapshots, bug reports, or source control.

## Sending boundary

Provider capabilities and sending health must both allow an action before UI enablement. The live provider sends text and attachments by driving Messages.app over AppleScript (`osascript`) — Messages.app owns persistence, so no write ever reaches `chat.db`. Message content is passed as an AppleScript argument, never interpolated into the script source. The providers expose no send capability for tapbacks, replies, edits or mark-as-read, which the native path cannot perform. A rejected or unknown result is never presented as success, and unknown outcomes are never automatically retried because the original message may already have been delivered.

## Current threat boundary

This milestone trusts the local macOS user and does not attempt device compromise, malicious local administrator, or dependency-build isolation. It adds no analytics, push service, or background data export. It *does* now make outbound network requests: the update check, link previews, and — only when the user has stored a token — a headless Beeper Server, whose boundary is specified above. Swift Package code and its build macro remain supply-chain inputs; exact resolution is recorded in `Package.resolved`, and changes require review.

Before enabling live data, review the full dependency diff, validate a signed release identity, trace all opens against the Messages directory, and confirm that every write to `chat.db` originates from the vetted third-party library and stays within its documented, schema-aware surface — never from Trill's own SQL.
