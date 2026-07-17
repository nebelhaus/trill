# Security boundaries

## Core invariant

Trill never modifies `~/Library/Messages/chat.db` or another Apple-owned Messages database. System Integrity Protection stays enabled.

The app's permission checker opens the database only with:

```text
SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
```

It reads `sqlite_master` only to verify that the required `chat` and `message` tables exist. It does not issue migrations, index creation, repair, vacuum, write-capable pragmas, or data mutations.

The app-owned `app.sqlite3` under Application Support is a separate database. It stores provider-qualified pin IDs, drafts, and provider event cursors; provider message history is not copied into it.

## Third-party boundary

`platform-imessage` 0.24.4 is present for compilation and DTO contract mapping. Its `PlatformAPI` is never instantiated because that facade currently initializes `IMDatabase(createIndexes: true)`. Live capabilities stay empty and calls fail closed. See [ADR 0001](architecture-decisions/0001-messages-provider.md).

Third-party DTOs are confined to `Providers/PlatformIMessageProvider`. Domain, repositories, persistence, features, and views do not import them.

## Permissions

- Fixture mode: no sensitive permission required.
- Messages database: Full Disk Access, requested only after explanation and only for the signed app identity.
- Sending: future Accessibility and Apple Events Automation permission; currently disabled.
- Contacts and notifications: independent health dimensions; not requested at launch.
- Remote relay: absent from this milestone.

Granting Full Disk Access does not enable live integration by itself and does not relax the read-only invariant.

## Logging and sensitive data

OSLog categories cover provider, database, repository, UI, and permissions. Logs may contain operation type, duration, count, provider ID, and non-content error category. They must not contain:

- Message bodies or provider DTO dumps.
- Phone numbers, email addresses, contact names, or other handles.
- Attachment paths or contents.
- Tokens, credentials, raw database rows, or SQL query results.

Fixtures use reserved/example values and synthetic prose. Real Messages data must never be promoted into tests, snapshots, bug reports, or source control.

## Sending boundary

Provider capabilities and sending health must both allow an action before UI enablement. The current providers expose no send capability. A rejected or unknown result is never presented as success, and unknown outcomes are never automatically retried because the original message may already have been delivered.

## Current threat boundary

This milestone trusts the local macOS user and does not attempt device compromise, malicious local administrator, or dependency-build isolation. It adds no analytics, updater, remote networking, push service, or background data export. Swift Package code and its build macro remain supply-chain inputs; exact resolution is recorded in `Package.resolved`, and changes require review.

Before enabling live data, review the full dependency diff, validate a signed release identity, trace all opens against the Messages directory, and prove that the safe construction path cannot regress to `createIndexes: true`.
