# Beeper client refactor

> **Frozen 2026-08-04, after §1 and §2.** §3, §4 and §5 are **not planned**.
>
> The work through §2 stays — it is merged, tested, and inert (with no token
> stored the Beeper provider isn't constructed, so live mode is behaviourally
> the native provider it always was). What stops is investment.
>
> **Why.** The aggregation this doc buys is *Beeper's*, not ours: it needs their
> app installed, signed in and running, its networks route through their cloud
> bridges, and the API it rides is an experimental public beta owned by
> Automattic — who also own the aggregator client we'd be competing with. The
> question "why not just use Beeper Desktop?" has no good answer for a user who
> already has Beeper running, and finishing §3/§4 would deepen a dependency on
> the one part of Trill nobody here controls.
>
> **What would unfreeze it:** Beeper's Desktop API leaving beta with a stability
> commitment, *and* a reason for a Beeper user to prefer Trill's surface that
> doesn't depend on Beeper. Both, not either.
>
> Until then `scripts/beeper-contract-check.sh` is the only Beeper work worth
> doing, and only because it's one command. See
> `workshop/notes/perch-monetization.md` §5 for the product reasoning.

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

### 1. Aggregation foundation — shipped

See [ADR 0003](architecture-decisions/0003-provider-aggregation.md).

- [x] Add per-provider/per-conversation capabilities and health.
- [x] Introduce dynamic service/account identity and migrate the persisted filter.
      (`hiddenServices` is a `UserDefaults` CSV, migrated on read — not a schema
      migration; `AppDatabase.currentSchemaVersion` is untouched.)
- [x] Implement and test composite paging, routing, search, events, and partial failure.

### 2. Beeper adapter — shipped (not yet validated against a live Server)

See [ADR 0004](architecture-decisions/0004-beeper-transport.md).

- [x] Add typed REST client, confined DTOs, Keychain auth, configurable endpoint.
- [x] Map accounts, chats, participants, messages, replies, reactions, attachments,
      delivery state, and cursors into Domain models.
- [x] Implement read-only conversations, messages, search, contacts, media, and health.
- [x] Add contract fixtures **synthesized** from the versioned API's published types,
      with no real user data. (The doc said "captured"; a capture of this API is a
      capture of the user's messages and must never be committed — hand-write the
      fixture from the observed shape.)
- [ ] **Run it against a real Beeper Server and record the validated `app.version`.**
      The contract was derived from the official `@beeper/desktop-api` 5.0.0 types,
      not from a running Server — no response has ever been observed. This blocks §5.
      `scripts/beeper-contract-check.sh` performs the check: it calls the endpoints
      `BeeperClient` calls with the parameters it sends, and reports `app.version`,
      field presence, unmodelled fields, and whether the iMessage exclusion holds.
      Its output carries field names, types and counts only — never content.

### 3. Product integration — frozen, not planned

- [x] Make live mode the composite provider; preserve fixture mode. (Landed with §2:
      `InboxModel.makeProvider` builds the composite and adds the Beeper child only
      when a token is stored.)
- [x] Keep “All” implicit and extend the existing service filter for networks/accounts.
      (Landed with §1: `ServiceIdentity` plus a dynamic `availableServices` menu.)
- [ ] Add Beeper connection settings, onboarding, reconnect, and partial-health UI.
      Until this exists the token has to be put in the Keychain by hand
      (`security add-generic-password -s com.nebelhaus.trill -a beeper.accessToken`),
      which is fine for validation and not fine for a user.
- [x] **Provider-mode label.** “Messages” lied once live mode became a composite;
      the picker now says **“Live”**. The persisted `providerMode` value is
      unchanged (`messages`), so no stored preference moved.
- [ ] Ensure tabs, drafts, folders, saved messages, exports, stats, and notifications
      work across provider-qualified IDs.

### 4. Writes and liveness — frozen, not planned

- [ ] Add send text/files, reactions, direct-chat creation, and mark-read only when the
      owning Beeper account reports support.
- [ ] Add WebSocket events behind a polling fallback; test disconnect and replay.
- [ ] Prevent duplicate/unknown-outcome sends and cross-provider routing mistakes.

### 5. Ship gate — frozen, not planned

- [ ] Validate supported Server release, update/removal path, license, CPU/RAM, and logs.
      (Blocked: no Server has been available yet — see §2. Run
      `scripts/beeper-contract-check.sh` first; it produces the version to record.)
- [ ] Test native-only, Beeper-only, combined, offline, expired-auth, and multi-account.
      The in-app half of this is the Beeper checklist in
      [`testing.md`](testing.md#beeper-contract-check-manual-needs-a-server--not-part-of-the-suite).
- [ ] Update PRD/architecture/security/README when implementation changes shipped truth.

## Acceptance

With no Beeper configured, Trill behaves as it does today. With Beeper configured,
one inbox shows native iMessage/SMS/RCS plus selected Beeper networks, filters and
local overlays compose across both, actions follow the owning provider's runtime
capabilities, and either provider may fail without taking down the other.
