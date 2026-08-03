# ADR 0003: Provider aggregation — one inbox over several providers

## Status

Accepted. Implements §1 of [`../beeper-client-refactor.md`](../beeper-client-refactor.md).
The Beeper adapter that motivates it (§2) lands separately and adds a child; it
changes nothing here.

## Context

Trill was single-provider by *construction*, in four places at once:

- `MessagesRepository` held exactly one `any MessagesProvider`.
- `InboxModel` held one `ProviderCapabilities` and one `ProviderHealth`, fetched
  once per load and handed wholesale to the composer.
- `MessageServiceKind` was a closed enum (`iMessage`/`sms`/`rcs`/`unknown`), a
  stored field on `Conversation` and `Message`, and the sidebar's service filter
  persisted its raw values as a `UserDefaults` CSV.
- Event cursors were one `provider_cursors` row per provider id.

None of that survives a second provider. Doing all four at once *with* a network
adapter would produce a change nobody can review, so this is the whole of the
foundation and none of the transport.

## Decision

### The repository stays single-provider-shaped

`CompositeMessagesProvider` conforms to `MessagesProvider` itself. So
`MessagesRepository`, `ConversationModel` and nearly all of `InboxModel` need no
multi-provider awareness, and the seam stays exactly where it already was.

The alternative — real multi-provider awareness in the repository — was rejected:
it would push routing, merging and partial-failure policy into a type that also
owns overlay-database concerns, and every feature that today takes a repository
would need to learn which provider it's talking to. Aggregation is a provider
concern; the composite is where it belongs.

### Identifiers pass through verbatim

The composite's `ProviderID` (`"composite"`) exists for protocol conformance and
never appears inside a `ConversationID` or `MessageID`. Child IDs are passed
through untouched, in both directions.

This is the single most consequential rule here. `ConversationID.persistenceKey`
is a base64url encoding of `(provider, externalGUID)` and is the primary key of
*every* overlay table — pins, drafts, read marks, folders and folder members,
VIP, archive, mute, snooze, saved messages — plus the persisted tab list. A
thread that was `("imessage", guid)` arriving as `("composite", …)` would silently
orphan all of it: no error, just state that isn't there next launch.

### Capabilities and health resolve per conversation

`MessagesProvider` gains `capabilities(for:)` and `health(for:)`, both defaulted
to the whole-provider answer, so the two existing conformers are unchanged. The
composite routes them to the conversation's owning child.

Whole-app `capabilities()` remains, as the **union** across children: it feeds
the health screen and the live-event gate, which are properly whole-app
questions. Anything gating an *action* on a specific thread uses
`capabilities(for:)` — otherwise a thread on a read-only provider inherits a
sibling's send capability.

`InboxModel` keeps a small per-*provider* gate cache so switching tabs can gate
the composer synchronously (no flash of a disabled composer, no delayed draft
restore), then refines to the exact per-conversation answer via
`ComposerModel.updateGate` as it arrives.

### Health aggregates by policy, not by `min()`

`InboxModel.load` turns `health.messagesDatabase`'s failure reasons into a
full-screen recovery view that *replaces* the conversation list. That is correct
when the native provider can't read `chat.db` and catastrophic when a remote
server is merely unreachable.

So the composite names one child **primary** and reports its health verbatim for
the blocking dimensions. Every other child that is unwell is listed in a new
`ProviderHealth.degraded: [ProviderDegradation]`, which nothing folds into the
blocking dimensions. A remote provider being down is therefore structurally
incapable of blanking the inbox.

### Merged paging over-fetches and cuts at a watermark

Each active child is asked for the **full** limit, results are merged by date,
and the page is cut at the earliest of the still-paging children's last-returned
timestamps — past that boundary we cannot know whether an unfetched item from
another child sorts first. Taking `limit / n` from each child and interleaving is
cheaper and wrong: it loses items whenever the children's activity rates differ.

A child that reports no next cursor is exhausted and contributes no boundary,
which is also what makes a child that never paginates at all
(`LiveIMessageProvider.conversations` always returns `nextCursor: nil`) work.

The cut is *inclusive* of the boundary timestamp. Two items sharing a timestamp
across two children may therefore emit in tiebreak order rather than true order;
an exclusive cut would stall forever on a page whose items share one timestamp.

### The composite cursor is opaque, versioned, and forgiving

Base64url JSON carrying, per child, its own next cursor; the children that
reported themselves exhausted; and the merged-but-unemitted remainder.

- Unreadable or unknown-version ⇒ decoded as nil ⇒ the page restarts, rather
  than throwing.
- A key naming a child that's since gone is ignored, and buffered items from
  that child are dropped — the user turned that provider off.
- `exhausted` is recorded **explicitly** rather than inferred from "absent",
  because "done" and "newly added since this cursor was minted" are otherwise
  indistinguishable; a new child must restart, not be assumed finished.
- A child that *rejects* its cursor (`FixtureProvider` throws `.invalidCursor`
  on anything non-integer, so a mis-routed cursor is a hard error) is reported
  as that child's failure while the rest of the page still arrives.

The remainder is carried as whole items rather than a re-fetch offset: a child's
page isn't stably re-derivable, since activity reorders it between calls. The
cursor is caller-held for the length of a paging loop, never persisted and never
logged. It is correspondingly not small — a buffered page of conversations
carries their participants, including contact thumbnails. That is acceptable for
an in-memory, single-loop value and is the reason it must stay out of
`provider_cursors`.

### Event cursors are persisted per child

`provider_cursors` is one row per provider, and a composite has several. A merged
cursor stored under the composite's id would resume both children from one
position after a relaunch — replaying some events and, worse, skipping others.

So `MessagesProvider` gains `eventCursorProviders` (defaulted to `[id]`) and
`events(resumingFrom: [ProviderID: EventCursor])` (defaulted to forwarding
`cursors[id]` to the existing `events(after:)`, so no existing conformer changes).
`MessagesRepository` reads one stored cursor per entry, and saves each event's
cursor under the provider its **payload** came from — read off the already
provider-qualified `Message.id` / `Conversation.id`, so nothing new had to be
threaded through `ProviderEvent`.

Each child stream keeps its own cursor and its own reconnect backoff. One child's
transport failing never finishes the merged stream, which would take the healthy
children down with it.

### Service identity is a string-backed struct

`MessageServiceKind` is replaced by `ServiceIdentity { key, displayName,
networkKey, accountID }`.

- `key` is the stable, filterable identity — unique per network *and* account, so
  two Signal accounts are two filter entries. It is persisted, so it must never
  change for a given account.
- `networkKey` is the family, shared by every account on a network. Chip colors
  key off it, so two accounts on one network read as one color with two labels.
- Well-known constants (`.iMessage`, `.sms`, `.rcs`, `.unknown`) keep the exact
  labels and colors the enum had.

This is shaped against Beeper's `Account` DTO, which is what has to fit through
it: `bridge.type` → `networkKey`, `accountID` → `accountID`, `network` →
`displayName`.

The service filter menu now lists the three natives **always** plus every network
actually present, plus anything currently hidden. Deriving it purely from what's
loaded would drop RCS from the menu wherever no RCS thread exists yet — a visible
change, and therefore a bug.

The persisted hidden-service list migrates **on read**: it's a `UserDefaults`
CSV, not a schema, so `ServiceIdentity.migratedHiddenServices` maps the old raw
values (`iMessage` with a capital M, `sms`, `rcs`) to the new lowercase keys,
idempotently. No `AppDatabase` migration is involved and
`currentSchemaVersion` is untouched.

### Partial failure has one reporting shape

`ConversationPage`, `MessagePage` and `MessageSearchPage` each carry
`failures: [ProviderFailure]`, defaulted empty so every existing construction
site is unchanged. One child throwing must not fail the merged call — but a
partial page indistinguishable from a complete one is how "half my messages
vanished" ships.

`ProviderFailure` carries the error's **type name**, never its message, because
these reach `OSLog` (`docs/security.md`). The fanned-out reads that return plain
arrays (`libraryItems`, `myMessages`, `messages(ids:)`, `contactSuggestions`)
have no sidecar and log instead.

### Fixture mode stays a bare provider; live mode becomes the composite

Fixture mode is the dev default and the whole test suite runs on it, so it stays
a single `FixtureProvider` with no composite wrapper, no network, and no path
that could reach one.

Live mode becomes the composite immediately, while it still has a single child. A
one-child composite is behaviorally the child — its merge is the identity, its
routing is trivial — so this ships the aggregation seam in production and makes
the Beeper adapter an additive child rather than a second rewiring.

## Consequences

- A second provider is now an additive file drop plus one child in
  `InboxModel.makeProvider`.
- `InboxModel` carries `partialFailures` and `degradedProviders` but does not yet
  render them; the banner and health rows land with the Beeper connection UI
  (§3). Until then they are logged.
- `InboxModel` takes an injectable `UserDefaults`. This is purely test isolation:
  the sidebar filter, folder scope, service filter, provider mode and open tabs
  are all `UserDefaults`-backed, and the parallel XCTest processes share one
  domain — three suites driving an `InboxModel` at once raced each other's tab
  state. Production still passes `.standard`.
- `Conversation.service` and `Message.service` change from a `String`-backed enum
  to a struct. Neither type is JSON-encoded anywhere in the app (their `Codable`
  conformance now backs the composite cursor), so no persisted or exported format
  moves.
- "Messages" is a poor name for the live mode now that it is a composite. That
  label is user-visible and its rename is proposed separately rather than made
  here.
