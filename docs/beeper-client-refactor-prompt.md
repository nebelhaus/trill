# Passoff prompt — Beeper client refactor, phases 1 + 2

*Written to be pasted whole into a fresh Claude session in a trill worktree. It
covers §1 (aggregation foundation) and §2 (read-only Beeper adapter) of
[`beeper-client-refactor.md`](beeper-client-refactor.md). It re-derives ground truth
on both sides — Trill's current shape and the Beeper API's actual DTOs — so the
session doesn't have to trust a stale summary, and it front-loads the failure modes
that compile fine and break silently. Phases 3–5 get their own prompt.*

---

## Prompt

You're implementing sections **1 and 2** of `docs/beeper-client-refactor.md` in
`nebelhaus/trill`: the aggregation foundation, then the read-only Beeper adapter that
rides on it. Read that doc first — it's the spec, and it's short.

The end state for this work: Trill's live mode is a composite of two providers, the
native `LiveIMessageProvider` and a new read-only `BeeperProvider`, and a user with a
Beeper Server running sees their non-iMessage networks in the same inbox as their
iMessage threads. **No sending through Beeper, no connection UI** — those are §3/§4.

You have a **live headless Beeper Server available on this machine** (see "Talking to
the real server"). Use it. Do not hand-write a client from this prompt's field lists.

### Land it as two PRs

Phase 1 changes no user-visible behavior and is provable entirely against
`FixtureProvider` with zero permissions. Phase 2 adds a network dependency. Reviewing
them together is miserable, so:

- **PR 1 — aggregation foundation.** Open it when phase 1 is green. Base: `main`.
- **PR 2 — Beeper adapter.** Continue on a branch based off phase 1's; open it when
  phase 2 is green. Say in the body that it stacks on PR 1 and merges after it.

Don't merge either. Report both links.

### Why phase 1 has to come first

Trill is *structurally* single-provider in four places, and all four must move before
a second provider can exist at all. Doing them together yields a PR nobody can review;
doing phase 1 first makes phase 2 a mostly-additive file drop.

---

## Part A — ground truth: what Trill looks like today

Verify rather than trust; this was read at `1c4e1df`.

**The provider seam.** `Trill/Providers/MessagesProvider.swift:3` — one protocol,
~15 requirements plus 8 defaulted extension methods (`sendDirect`,
`contactSuggestions`, `media`, `libraryItems`, `messages(ids:)`, `statSamples`,
`myMessages`, `exportMessages`, and the `messages(in:around:limit:)` fallback). Three
conformers: `FixtureProvider` (id `"fixture"`), `LiveIMessageProvider` (id
`"imessage"`), `PlatformIMessageProvider` (id `"platform-imessage"`, dormant).

**The repository holds exactly one.** `Trill/Repositories/MessagesRepository.swift:17`
— `private let provider: any MessagesProvider`. It logs, dedupes events, persists
cursors, and assembles the saved-messages library tab. No concept of a second provider.

**The UI holds one capability set and one health.**
`Trill/Features/Inbox/InboxModel.swift:56` and `:55`, fed once per load at
`:367–368`, handed wholesale to the composer at `:720`/`:724`.
`CapabilityGate.canSend` (`Trill/Domain/ProviderHealth.swift:81`) is the single gate.

**Provider selection is a two-case enum.** `InboxModel.swift:4` `ProviderMode`
(`.fixture` / `.messages`), constructed at `:286`, switched at `:439`, built at `:354`,
persisted in `UserDefaults` under `"providerMode"`.

**Service is a closed enum.** `Trill/Domain/Models.swift:3` `MessageServiceKind`
(`iMessage`/`sms`/`rcs`/`unknown`, `.togglable` excludes `.unknown`), a field on
`Conversation` (`:40`) and `Message` (`:142`). Display comes from
`Trill/DesignSystem/Components.swift:89` (`displayLabel`, `chipColor`, `ServiceChip`),
consumed at `InboxView.swift:921`/`:943`, `CommandPaletteView.swift:369`,
`ConversationView.swift:309`, `MenuBarInboxView.swift:190`.

**The service filter is a UserDefaults CSV**, not a table. `InboxModel.swift:169` —
`hiddenServices` persisted as comma-joined rawValues under `"hiddenServices"`, loaded
at `:273`, applied at `:496`, menu at `InboxView.swift:529`.

**Identity is already provider-qualified.** `Trill/Domain/Identifiers.swift:43`/`:72`
— `ConversationID`/`MessageID` are `(ProviderID, externalGUID)` pairs whose
`persistenceKey` is a base64url encoding of both, and that key is the primary key of
*every* overlay table in `AppDatabase.swift` (pins, drafts, read marks, folders,
folder members, VIP, archive, mute, snooze, saved messages) plus the persisted tab
list. Schema version 13 (`AppDatabase.swift:19`).

**Cursors today.** `provider_cursors` is keyed by `provider_id` (migration 3); the
repository saves at `MessagesRepository.swift:136`, reads at `:124`. Page cursors are
per-provider private strings: Fixture uses integer offsets
(`FixtureProvider.swift:213`, which *throws* `.invalidCursor` on anything non-integer);
Live uses min-rowID for message paging (`LiveIMessageProvider.swift:77`) and **doesn't
paginate conversations or search at all** — both return `nextCursor: nil` (`:63`,
`:176`), and `InboxModel` just asks for 100 conversations in one shot.

**What doesn't exist yet.** No Keychain code anywhere (`Trill/Platform/` has only
`Logging/` and `Permissions/`). `URLSession` appears only in `UpdateCheck.swift:295`
and `LinkPreviewLoader.swift`. Tests are XCTest under `TrillTests/`, fixture-only by
policy (`docs/testing.md`).

### Name collision — read before naming a single type

`Trill/Providers/PlatformIMessageProvider/` **is** Beeper code: the
`beeper/platform-imessage` Swift package, pinned and compiled but never instantiated,
gated on the vetting pass in `docs/architecture-decisions/0001-messages-provider.md`.
It is a *local iMessage* library that opens `chat.db` **read-write**.

The `BeeperProvider` you're building is unrelated: an HTTP client against a
local-or-remote headless **Beeper Server**'s REST API, serving *non*-iMessage
networks, touching no database at all. Don't merge them, don't rename one into the
other, and say which you mean every time. Put yours in `Trill/Providers/Beeper/`.

---

## Part B — phase 1: the aggregation foundation

Four things.

**1. Provider-scoped capabilities and health.** Capability and health lookup must
become answerable *per conversation*, because the composer's send gate now depends on
which thread is open. Keep a whole-app aggregate too — `InboxModel` needs something for
the health screen. `capabilities(for: ConversationID)` on the protocol with a defaulted
whole-provider fallback is the obvious shape; justify whatever you pick in the ADR.
(Phase 2 will vindicate this: Beeper reports capabilities **per chat**, not per
account — see `Chat.capabilities` below.)

**2. Dynamic service/account identity.** Replace the closed `MessageServiceKind` with a
stable string-backed identity carrying display metadata, able to express "WhatsApp",
"Signal", and *two different Signal accounts* as distinct filterable things. Keep
iMessage/SMS/RCS as well-known constants so `ServiceChip`'s colors and labels survive.
Migrate the `hiddenServices` UserDefaults CSV in place, on read, without losing
existing filter state. **Design this against `Account` in Part C, not from
imagination** — that DTO is what has to fit through it.

**3. `CompositeMessagesProvider`.** Conforms to `MessagesProvider`, owns an ordered
list of children, and implements: routing by `ConversationID.provider` /
`MessageID.provider` for every per-conversation call; timestamp-merged conversation
and search paging behind one opaque cursor; merged event streams with independent
per-child cursors and reconnect policy; fan-out-and-merge for global reads
(`libraryItems`, `myMessages`, `contactSuggestions`, `messages(ids:)`); fail-soft
partial results throughout.

**4. Tests.** Deterministic merged paging across two fixture children with interleaved
timestamps; routing (a call for provider A's conversation never reaches B); merged
search ordering; merged events with dedup; composite cursor round-trip *and* graceful
handling of a cursor naming a child that's since gone; partial failure (one child
throws, the other's results still arrive); the `hiddenServices` migration.

Plus `docs/architecture-decisions/0003-*.md`.

### Phase 1 landmines

Every one of these compiles.

**Never re-qualify an ID.** The composite passes child `ConversationID`s and
`MessageID`s through *verbatim*. Its own `ProviderID` exists for protocol conformance
and must never appear inside an ID that reaches the domain models. If a conversation
that was `("imessage", guid)` starts arriving as `("composite", …)`, its
`persistenceKey` changes and every pin, draft, folder membership, VIP mark, snooze,
archive flag, saved message, read mark, and restored tab for that thread is orphaned —
no error, just missing state next launch.

**Don't collapse event cursors.** `provider_cursors` is one row per `provider_id`. A
merged cursor under the composite's id makes both children resume from the wrong place
after relaunch — replaying or skipping, and the skip is the one you won't notice.
Persist per child: either push cursor persistence into the composite or teach
`MessagesRepository.eventStream` (`:123–147`) about multiple cursors. Decide, and say
why in the ADR.

**A Beeper outage must not blank the inbox.** `InboxModel.load` (`:370–382`) switches
on `health.messagesDatabase.reason` and turns `.permissionMissing` /
`.unsupportedSchema` / `.providerFailure` / `.databaseMissing` into a full-screen error
that replaces the conversation list. Correct when the *native* provider can't read
`chat.db`; catastrophic when a remote server is merely unreachable. Aggregation is not
a min() over health dimensions — decide explicitly which child's failures are blocking
(native) and which degrade to a non-blocking banner plus a degraded health row
(Beeper), and encode that rather than letting it fall out of a fold.

**Merged paging needs over-fetch, not interleaving.** Taking N/2 from each child and
zipping loses conversations whenever the children's activity rates differ. Fetch at
least the full limit from each child, merge by `lastActivity`, and cut the page at the
**earliest of the children's last-returned timestamps** — past that you can't know
whether an unfetched item from the other child sorts first. Carry the unemitted
remainder plus each child's native cursor in your composite cursor. Also tolerate a
child that never paginates (`LiveIMessageProvider.conversations` returns `nil` always).

**Composite cursor: opaque, versioned, forgiving.** It encodes child-provider → child
cursor. Children can be added, removed, or disabled between two calls. An unknown or
missing child should restart *that child*, not throw the page away — note
`FixtureProvider.offset` throws `.invalidCursor` on anything it doesn't recognize, so
a naive pass-through of the wrong child's cursor is a hard error.

**Fail soft, and decide the reporting shape once.** One child throwing must not fail
the merged call — but a partial page indistinguishable from a complete one is how "half
my messages vanished" ships. Pick one mechanism (a `failures: [ProviderID: Error]`
sidecar on the page types is least invasive) and use it everywhere.

**Fixture mode stays pure.** The dev default and the entire test suite run on
`.fixture`. It stays a single provider with no composite wrapper, no network, no
Keychain access, and no Beeper code path reachable from it.

---

## Part C — phase 2: the Beeper adapter

### Talking to the real server

The headless server listens on **`http://127.0.0.1:23373`**, installed/started with
`beeper --server --install`. Every endpoint needs `Authorization: Bearer <token>`;
the token comes from Beeper's **Settings → Advanced → API**. OAuth endpoints exist too
(see `/v1/info`), but a pasted bearer token is the phase-2 path.

**Your first request is `GET /v1/info`.** It returns `{app, endpoints, platform,
server}` where `endpoints.spec` is the **OpenAPI spec URL for the running server** and
`endpoints.ws_events` is the live-events socket. Pull that spec and treat it — not this
prompt — as the contract. Record the `app.version` you validated against in the ADR;
§5's ship gate asks for a supported-Server version and right now the doc only knows
about a staging build.

The official TypeScript SDK (`@beeper/desktop-api`, currently 5.0.0) is a useful
cross-check on shapes and is MIT — read it, don't vendor it. Note "Client API v5" is
the *SDK package* version; the URL paths are `/v1`. Don't go looking for `/v5`.

### The DTOs you'll map

Abbreviated to the fields that matter; optional unless noted.

**`Account`** (`GET /v1/accounts`) — `accountID` (required; e.g. `matrix`,
`discordgo`, `slackgo.TEAM-USER`, `local-whatsapp…`), `bridge {id, provider:
cloud|self-hosted|local|platform-sdk, type}` (required; `type` is `whatsapp`,
`telegram`, `slackgo`, …), `user` (a `User`, the account's own identity), `network`
(human-friendly display name). **This is the source for phase 1's service/account
identity**: `bridge.type` is the stable service key, `accountID` distinguishes two
accounts on one network, `network` is the display label.

**`Chat`** (`GET /v1/chats`, `GET /v1/chats/search`) — `id` (required, globally
unique), `accountID`, `network`, `title`, `type: 'single'|'group'`, `unreadCount`,
`participants {items: [User + isAdmin/isNetworkBot/isPending], total, hasMore}`,
`lastActivity` (ISO 8601 string), `isArchived`/`isMuted`/`isPinned`/`isReadOnly`/
`isMarkedUnread`, `unreadMentionsCount`, `lastReadMessageSortKey`, `imgURL`,
`description`, `draft`, `snooze`, `reminder`, `localChatID`, and **`capabilities`** —
a per-chat structure (`allowedReactions`, `attachments` keyed by Matrix msgtype,
`customEmojiReactions`, `delete: -2|-1|0|1|2`, `deleteForMe`, `edit`, …).

**`Message`** (`GET /v1/chats/{chatID}/messages`, `GET /v1/messages/search`) — `id`,
`accountID`, `chatID`, `senderID` (Matrix-style FQ user ID), `sortKey` (**the sortable
key — this is your cursor/sequence, not the timestamp**), `timestamp` (ISO 8601), all
required; then `text` (**Matrix HTML**), `type: TEXT|NOTICE|IMAGE|VIDEO|VOICE|AUDIO|
FILE|STICKER|LOCATION|REACTION`, `senderName`, `isSender`, `isUnread`, `isDeleted`,
`isHidden`, `editedTimestamp`, `linkedMessageID` (reply parent), `attachments[]`,
`reactions[]`, `links[]` (link previews: title/url/img/summary/favicon), `mentions`,
`seen` (bool | string | map — read receipts), `sendStatus {status: SUCCESS|PENDING|
FAIL_RETRIABLE|FAIL_PERMANENT, timestamp, deliveredToUsers, reason, message}`.

**`Attachment`** — `type: unknown|img|video|audio` (required), `id` (typically an
`mxc://` URL), `srcURL` (*"may be temporary or local-only to this device; download
promptly if durable access is needed"*), `mimeType`, `fileName`, `fileSize`,
`size {width,height}`, `isGif`/`isSticker`/`isVoiceNote`, `posterImg`, `duration`,
`transcription {engine, transcription, language}`.

**`Reaction`** — `id`, `participantID`, `reactionKey` (an emoji, a network key, or a
shortcode like `smiling-face`), `emoji: bool`, `imgURL`.

**`User`** — `id` (required, stable — the primary key for a person), `fullName`,
`username`, `phoneNumber` (E.164), `email`, `imgURL`, `isSelf`, `cannotMessage`.

**Pagination** is uniform: responses are `{items, hasMore, oldestCursor, newestCursor}`;
params are `{cursor, direction, limit?}` (`chats.list` takes no `limit`). Cursors are
bidirectional via `direction`, which maps cleanly onto Trill's backward `before` paging
— get the direction right or you'll page into the future.

**Assets** — `POST /v1/assets/download` takes an `mxc://`/`localmxc://` URL and
returns a local `srcURL`; `GET /v1/assets/serve` streams one with Range support.

### What to build in phase 2

- A typed REST client in `Trill/Providers/Beeper/`: `URLSession`, bearer auth,
  configurable base URL (default `http://127.0.0.1:23373`), typed errors, cancellation,
  bounded timeouts. No third-party HTTP dependency.
- DTOs — `Codable` structs mirroring the above, **`internal` to that folder**.
- Keychain storage for the token: build `Trill/Platform/Keychain/` (nothing exists
  yet). The endpoint URL can live in `UserDefaults`; **the token may not**.
- `BeeperProvider: MessagesProvider`, read-only: `conversations`, `messages`,
  `messages(in:around:)` if the cursor model supports it, `search`,
  `contactSuggestions`, `media`, `libraryItems`, `health`, `capabilities`
  (whole-provider *and* per-chat), and an `events` stream — REST polling for now.
- Contract fixtures + mapper tests, in the shape of the existing
  `PlatformIMessageMapperTests`.

### The mapping table

| Beeper | Trill domain |
|---|---|
| `Chat.id` | `ConversationID.externalGUID` (**not `localChatID`** — see landmines) |
| `Chat.title` | `Conversation.displayName` |
| `Chat.type` | `ConversationKind.direct` / `.group` |
| `Chat.accountID` + `bridge.type` + `network` | the phase-1 service/account identity |
| `Chat.lastActivity` | `Conversation.lastActivity` (ISO 8601 → `Date`) |
| `Chat.unreadCount` | `Conversation.unreadCount` |
| `Chat.participants.items[]` | `[Participant]` — `User.id` → `id`, `fullName` → `displayName`, `username`/`phoneNumber`/`email` → `handle` |
| `Chat.capabilities` | per-conversation `ProviderCapabilities` |
| `Message.id` | `MessageID.externalGUID` |
| `Message.sortKey` | `Message.providerSequence` **and** the paging cursor |
| `Message.text` (Matrix HTML) | `Message.text` — **must be converted to plain text** |
| `Message.isSender` | `isOutgoing` |
| `Message.linkedMessageID` | `replyTo` (and hydrate `quoted` where you can) |
| `Message.sendStatus.status` | `MessageDeliveryState` (`SUCCESS`→`.sent`, `PENDING`→`.pending`, `FAIL_*`→`.failed`) |
| `Message.editedTimestamp` | `isEdited` |
| `Message.seen` | `readAt` where a timestamp is available |
| `Reaction.reactionKey` | `MessageReaction` — glyph verbatim, `kind` almost always `.custom` |
| `Attachment` | `MessageAttachment` — `.downloadRequired` until fetched into our cache |

Trill's search already parses operators into `SearchFilters`
(`Domain/Models.swift:250`) and applies them locally. Beeper can do most of it
server-side — push it down:

| `SearchFilters` | `MessageSearchParams` |
|---|---|
| `text` | `query` (literal word search, non-semantic) |
| `sender` | `sender` — `'me'` / `'others'` / a `User.id` |
| `conversationKind` | `chatType: 'group'|'single'` |
| `after` / `before` | `dateAfter` / `dateBefore` (ISO 8601) |
| `requiresImage` / `requiresLink` / `requiresAttachment` | `mediaTypes: ['image'|'link'|'file'|'any']` |
| `unreadOnly` | no server equivalent — filter locally, and say so |

### Phase 2 landmines

**Use `Chat.id`, never `localChatID`.** `localChatID` is documented as *"specific to
this Beeper Desktop installation"*. Bake it into a `ConversationID` and every pin,
draft, folder membership and saved message silently detaches the moment the user
reinstalls Beeper or runs the server on another machine. `Chat.id` is the globally
unique one.

**`text` is Matrix HTML, and the domain field is a plain `String`.** Convert
deliberately — unescape entities, flatten the markup, keep newlines. Don't hand HTML
to a `Text` view, and don't hand unsanitized markup to anything that renders.

**The message stream carries non-messages.** `type: 'REACTION'` arrives as a
`Message`; so do state events (`NOTICE`), `isDeleted`, and `isHidden` rows. Filter them
at mapping time or they render as blank bubbles in the timeline.

**Exclude Beeper's iMessage twice.** The doc says "at mapping time"; do better —
`chats.list`, `chats.search`, and `messages.search` all accept an **`accountIDs`**
allowlist, so filter at *request* time (fetching then discarding also corrupts your
page sizes), **and** defend at mapping time, because the event stream will hand you
whatever it likes. The spike found `imessage` and `local-imessage` both 404 as
bridges, but an account can still surface — dropping it is what keeps native iMessage
threads from appearing twice in one inbox.

**Attachments are remote and perishable.** `srcURL` "may be temporary or local-only".
Map to `.downloadRequired`, fetch through `/v1/assets/download` into an
app-controlled cache with size and type limits, and only then populate `localURL`.
Never point `localURL` at a path inside Beeper's own storage.

**`ReactionKind` is iMessage-shaped.** It's a closed enum
(love/like/dislike/laugh/emphasis/question/custom). An arbitrary emoji or a shortcode
maps to `.custom` with `reactionKey` as the glyph. Don't extend the enum per network.

**Health has no honest slot for a REST provider.** `ProviderHealth` is a fixed struct
whose first field is literally `messagesDatabase` (`Domain/ProviderHealth.swift:34`);
`remoteRelay` is the optional one that actually fits. Decide the mapping in the ADR
rather than jamming HTTP failures into a field named after a database — and remember
phase 1's rule that Beeper's failures are non-blocking.

**The server holds the user's real messages.** Contract fixtures must be
*synthesized* — real shapes, invented content. No real names, handles, phone numbers,
message bodies, avatars, or `mxc://` URLs, in fixtures, tests, logs, commit messages,
or the PR body. Never commit a raw capture; hand-write the fixture from the shape you
observed. This is `docs/security.md` and it is not negotiable.

**Secrets discipline.** Token in Keychain, never `UserDefaults`, never a log line.
Redact the `Authorization` header everywhere. `OSLog` gets status codes, durations and
counts — never bodies. Loopback is the default; a non-loopback endpoint must require
HTTPS with real certificate validation (`ARCHITECTURE.md §11.3` already writes these
rules for BlueBubbles — same rules apply).

**REST first; the socket is experimental.** `endpoints.ws_events` (`GET /v1/ws`, with
per-chat `subscriptions.set`) exists, and the doc explicitly defers it to §4 behind a
polling fallback. Phase 2 polls. Don't get clever.

**Read-only means read-only.** The API offers `markRead`, `archive`, `update` (drafts),
reactions, sends, and chat creation. Every one is out of scope here — §4 gates them
behind per-account capability checks. Implementing one "since it's right there" is the
easiest way to make this PR unmergeable.

**Don't bundle or auto-install the Server.** Explicit non-goal in the doc; the spike
measured 288–450 MB RSS idle. Trill connects to a server the user runs.

---

## Verify

```sh
xcodebuild -skipMacroValidation -project Trill.xcodeproj -scheme Trill \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The suite must stay fixture-only — no test may hit the network or read the Keychain.

Then, by hand:

1. Fixture mode (⌘R, the default): sidebar, service filter menu, chips, tabs and
   composer gating **unchanged** — phase 1 is a refactor, and a visible difference in
   fixture mode is a bug.
2. Live mode with no Beeper token configured: behaves exactly as today.
3. Live mode with the token: Beeper threads appear interleaved by recency with
   iMessage, chips carry the right network, filters compose, and **no thread appears
   twice**.
4. Kill the Beeper Server mid-session: native Messages keeps working, the failure is
   visible, and the inbox does not blank.
5. Full Disk Access revoked with Beeper up: the native permission screen still wins.

Trill is an Xcode project, not a Nix build — `bench try` is not the verification path.

## Docs to update

- `docs/architecture-decisions/0003-*.md` — the phase-1 decisions.
- A second ADR (or a section in 0003) for the Beeper transport: base URL, auth
  storage, polling, attachment caching, validated Server version.
- `docs/beeper-client-refactor.md` — tick §1 and §2, and fix two things: "migrate
  persisted filters" is a `UserDefaults` CSV migration, not a schema one; and the doc
  is currently **orphaned** — nothing in `ARCHITECTURE.md`, `README.md`, or
  `docs/ideas.md` links to it.
- `ARCHITECTURE.md` — the composite in §5/§6, a roadmap entry in §22, and reconcile
  the conflict this creates: §6.4 and §11 currently cast **BlueBubbles** as the future
  second provider and the whole relay story, which Beeper now displaces. Don't leave
  two competing second-provider plans in one document.
- `docs/security.md` — the new network boundary, token storage, redaction.
- `docs/ideas.md`, `docs/testing.md`, `README.md` — status, new tests, shipped state.

## Two calls to make, not assume

1. **Provider-mode naming.** Once live *is* the composite, the dropdown's "Messages"
   label is misleading. That's user-visible — propose a rename in the PR, don't just
   make one.
2. **Whether the repository stays single-provider-shaped.** The cheap, correct answer
   is yes: a `CompositeMessagesProvider` conforming to `MessagesProvider` means
   `MessagesRepository`, `ConversationModel` and most of `InboxModel` need no change,
   and the seam stays where it already is. If you'd rather give the repository real
   multi-provider awareness, that's legitimate — but make it deliberately, in the ADR,
   with the reason.

## Workflow

Commit on your `worktree-*` branch, push, and open each PR against `main` with a
**What / Why / Verify / Watch-out** body — you have standing permission for all of
that, no need to ask. Don't merge. If phase 2 turns out to need something from §3/§4,
note it in the PR rather than pulling it in.
