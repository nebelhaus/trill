# Beeper client refactor

## Decision

Turn Trill into an always-aggregated native client with two transports:

- `LiveIMessageProvider` remains the source for local iMessage/SMS/RCS.
- A new `BeeperProvider` supplies every enabled Beeper network except iMessage.
- A composite provider merges both into one inbox. Network/account filtering stays
  a secondary filter; the provider-mode dropdown remains fixtures vs. live.

This keeps Beeper Desktop optional. Trill may connect to a local or remote headless
Beeper Server, and native Messages remains usable when Beeper is absent.

## Spike result (2026-07-30)

- Beeper CLI `0.6.2` installed signed headless Server `4.3.0`; Client API is v5.
- Server runs independently on localhost, but the current download is
  staging/nightly and used roughly 288–450 MB RSS while idle.
- Its catalog exposes cloud/local bridges for the expected non-iMessage networks.
- `imessage` and `local-imessage` both return `404 Bridge not found`.
- The binary starts `platform-imessage` internally, but does not expose it as a
  connectable headless bridge.

Therefore a single headless Beeper provider cannot replace Trill's native iMessage
provider today. Re-evaluate only when Beeper exposes headless iMessage and it passes
history, identity, feature, and reliability parity tests.

## Product requirements

- The default live inbox contains all available native and Beeper conversations.
- Beeper is optional; a Beeper outage must not hide or disable native Messages.
- Filters support dynamic network and account identities, including multiple
  accounts on one network.
- Capabilities and health are resolved per owning provider/conversation.
- Credentials live in Keychain. Endpoints are configurable for local or remote use.
- Beeper DTOs never escape the provider adapter.
- Partial failure is visible and recoverable; successful providers keep working.
- Existing provider-qualified conversation/message persistence remains compatible.

Non-goals: bundling or auto-installing the experimental Server, requiring Beeper
Desktop, direct per-network protocol implementations, or self-hosting a Matrix stack.

## Target architecture

```text
LiveIMessageProvider ─┐
                     ├─ CompositeMessagesProvider ─ Repository ─ UI
BeeperProvider ──────┘
```

- Add provider-scoped capability/health lookup before aggregation.
- Replace the closed `MessageServiceKind` filter model with stable string-backed
  service/account IDs plus display metadata.
- Merge conversation/search pages by timestamp using an opaque composite cursor.
- Route conversation/message/send/media calls by provider-qualified ID.
- Merge event streams with independent cursors and reconnect policies.
- Use Beeper REST v1 first. Treat its WebSocket as optional with polling/reload
  fallback because the event API is experimental.
- Exclude Beeper iMessage at mapping time to prevent duplicates.

## Task list

### 1. Aggregation foundation

- [ ] Add per-provider/per-conversation capabilities and health.
- [ ] Introduce dynamic service/account identity and migrate persisted filters.
- [ ] Implement and test composite paging, routing, search, events, and partial failure.

### 2. Beeper adapter

- [ ] Add typed REST client, confined DTOs, Keychain auth, configurable endpoint.
- [ ] Map accounts, chats, participants, messages, replies, reactions, attachments,
      delivery state, and cursors into Domain models.
- [ ] Implement read-only conversations, messages, search, contacts, media, and health.
- [ ] Add contract fixtures captured from the versioned API without real user data.

### 3. Product integration

- [ ] Make live mode the composite provider; preserve fixture mode.
- [ ] Keep “All” implicit and extend the existing service filter for networks/accounts.
- [ ] Add Beeper connection settings, onboarding, reconnect, and partial-health UI.
- [ ] Ensure tabs, drafts, folders, saved messages, exports, stats, and notifications
      work across provider-qualified IDs.

### 4. Writes and liveness

- [ ] Add send text/files, reactions, direct-chat creation, and mark-read only when the
      owning Beeper account reports support.
- [ ] Add WebSocket events behind a polling fallback; test disconnect and replay.
- [ ] Prevent duplicate/unknown-outcome sends and cross-provider routing mistakes.

### 5. Ship gate

- [ ] Validate supported Server release, update/removal path, license, CPU/RAM, and logs.
- [ ] Test native-only, Beeper-only, combined, offline, expired-auth, and multi-account.
- [ ] Update PRD/architecture/security/README when implementation changes shipped truth.

## Acceptance

With no Beeper configured, Trill behaves as it does today. With Beeper configured,
one inbox shows native iMessage/SMS/RCS plus selected Beeper networks, filters and
local overlays compose across both, actions follow the owning provider's runtime
capabilities, and either provider may fail without taking down the other.
