# ADR 0004: Beeper transport — read-only REST adapter over a headless Server

## Status

Accepted. Implements §2 of [`../beeper-client-refactor.md`](../beeper-client-refactor.md);
rides on the aggregation foundation in [ADR 0003](0003-provider-aggregation.md).
Read-only: no sending, no connection UI (§3/§4).

## Naming, before anything else

`Trill/Providers/PlatformIMessageProvider/` **is also Beeper code** — the
`beeper/platform-imessage` Swift package, a *local iMessage* library that opens
`chat.db` read-write and is compiled but never instantiated (ADR 0001).

`BeeperProvider` in `Trill/Providers/Beeper/` is unrelated: an HTTP client
against a local-or-remote headless **Beeper Server**, serving *non*-iMessage
networks, touching no database at all. The two are never merged and never
renamed into each other.

## Context

Trill's live inbox is native iMessage/SMS/RCS. Beeper bridges the networks it
isn't: WhatsApp, Signal, Slack, Telegram, Discord and the rest. Its headless
Server exposes them over a local REST API, so a second provider can put them in
the same inbox without Trill implementing a single network protocol.

Beeper's own iMessage bridge is *not* a replacement for the native provider —
the spike found `imessage` and `local-imessage` both return `404 Bridge not
found` as connectable headless bridges.

## Contract source, and what was NOT validated

**No Beeper Server was available on the machine this was written on**, so the
prompt's intended path — `GET /v1/info` → `endpoints.spec` → the running
Server's own OpenAPI document — was not open. The contract here is instead
derived from the **official `@beeper/desktop-api` TypeScript SDK, version
5.0.0** (MIT, read not vendored), whose types are generated from that same
OpenAPI document. That is materially better than hand-writing from prose: the
field lists, optionality, enum cases and pagination shapes are the generated
ones.

It is *not* equivalent, and the difference is worth naming:

- **No `app.version` was validated against.** §5's ship gate asks for a
  supported-Server version and this ADR cannot supply one. That gate is not
  satisfied by this change.
- **No response was ever observed.** Every fixture is synthesized from the type
  definitions. A field the SDK types as present but the Server omits in practice
  would show up as a nil, not as a test failure.
- Decoding is therefore written to be *tolerant everywhere* — every optional
  field is optional, unknown enum values degrade to a safe default rather than
  failing the page, and `BeeperPage` treats a missing `items` as empty. A Server
  newer or older than these types must not blank the inbox.

**Before this ships, run it against a real Server** and record the validated
`app.version` here. `scripts/beeper-contract-check.sh` is that run: it calls the
same endpoints `BeeperClient` calls, with the same parameters, and reports
`app.version`, per-field presence across real responses, any key the Server
returns that `BeeperDTOs.swift` doesn't model, whether the `accountIDs`
allowlist actually excludes Beeper's iMessage, and whether resending
`oldestCursor` pages backward as assumed. It prints field names, JSON types and
counts only, so its report can be shared; a raw capture cannot.

> **Validated `app.version`:** *(none yet — run the script and fill this in,
> alongside the date and the observed drift, if any)*

### One contract detail worth recording

`GET /v1/chats/{chatID}/messages` takes `{cursor, direction}` and the SDK types
`direction` as an unconstrained string. Getting it wrong pages *into the future*
and quietly returns nothing useful. The SDK's own pagination resolves this: it
advances by resending `oldestCursor` and **never sets `direction`**. So neither
do we — the default direction is backward into history, which is exactly Trill's
`before` paging.

## Decision

### Transport

`URLSession` only, no third-party HTTP dependency. Bearer auth, a configurable
base URL defaulting to `http://127.0.0.1:23373`, 15s request / 60s resource
timeouts, cooperative cancellation, an ephemeral session with no cookie store or
URL cache, and a 32 MB response ceiling.

Errors are **categories**, not transcripts: `notConfigured`, `unreachable`,
`unauthorized`, `http<status>`, `malformedResponse`, `payloadTooLarge`. Nothing
carries a server message, a body, or a URL. The `Authorization` header is
constructed in exactly one function and appears nowhere else — never in a log,
never in a URL, never in an error.

### Credentials

The token lives in the **Keychain** (`Trill/Platform/Keychain/`, new — nothing
existed), as a generic password with `kSecAttrAccessibleAfterFirstUnlock`. The
endpoint URL is an ordinary `UserDefaults` preference.

Loopback endpoints may be plain HTTP: the traffic never leaves the machine and
that is what the Server serves. **A non-loopback endpoint must be HTTPS** with
normal certificate validation — enforced in `BeeperConfiguration.init`, so a
remote endpoint over HTTP cannot be constructed at all. Same rules
`ARCHITECTURE.md §11.3` already writes for a remote relay.

### DTOs stay in the folder

Every wire type is `internal` to `Trill/Providers/Beeper/`. Nothing above
`Providers/` references one — the acceptance criterion in `ARCHITECTURE.md §20`,
not a style preference.

### Beeper's iMessage is excluded twice

Trill already has native iMessage, so surfacing Beeper's would show every thread
twice. The refactor doc says "at mapping time"; this does better:

1. **At request time.** `chats.list`, `chats.search` and `messages.search` all
   take an `accountIDs` allowlist, and only non-iMessage accounts go in it.
   Fetching then discarding would also corrupt page sizes.
2. **At mapping time**, because the event stream hands us whatever it likes: a
   chat whose account has no service identity is dropped.

An account counts as iMessage when its `accountID` or `bridge.type` contains
`imessage`.

### Identity

`Chat.id`, **never `localChatID`**. The latter is documented as specific to one
Beeper Desktop installation; baking it into a `ConversationID` would silently
detach every pin, draft, folder membership and saved message the moment the user
reinstalls Beeper or moves the Server to another machine.

`Account.bridge.type` is the network key, `accountID` the account, `network` the
display label — which is the shape `ServiceIdentity` (ADR 0003) was designed
against. The account qualifier is folded into the key only when a network
actually has more than one account, so a single-account network keeps the bare
key and doesn't re-key the user's saved filter the day they add a second one.

### Text is Matrix HTML

`Message.text` is Matrix HTML on the wire; `Domain.Message.text` is a plain
`String` that views render with `Text`. `MatrixHTMLText` flattens it —
hand-written rather than `NSAttributedString(html:)`, which needs the main
thread, spins a WebKit parser, and will fetch remote subresources referenced by
the markup, which on a message body is a privacy leak. Script and style content
is dropped; block boundaries become single newlines; entities are unescaped.

### The message stream carries non-messages

`type: 'REACTION'` arrives as a `Message`, and so do `NOTICE` state events,
`isDeleted` rows and `isHidden` rows. All are filtered at mapping time; letting
them through renders blank bubbles.

### Attachments are remote and perishable

`srcURL` "may be temporary or local-only to this device", and the local path
`/v1/assets/download` reports is inside **Beeper's** storage. Neither may become
a `MessageAttachment.localURL`. Everything maps to `.downloadRequired`;
`BeeperAssetCache` streams bytes through `/v1/assets/serve` into an app-owned
Caches directory, content-addressed by SHA-256 of the remote handle so an
untrusted `fileName` never reaches the filesystem, capped at 64 MB per file and
restricted to image/video/audio types.

Only the media gallery materializes bytes, and it is bounded by its `limit`.
Paging a thread deliberately does not: that would turn one scroll into dozens of
downloads.

### Health has no honest slot, so it uses the one that fits

`ProviderHealth`'s first field is literally `messagesDatabase` and this provider
has no database. It reports `.notRequested` there and puts the real state in
`remoteRelay`, which is the dimension that actually describes a remote
transport. ADR 0003's `headline` prefers `remoteRelay`, so the composite lists
this provider as a **degradation** rather than folding it into anything that
blanks the inbox. A rejected token reads as `.permissionMissing`; an unreachable
Server as `.providerFailure`.

### Search is pushed down, honestly

Trill already parses `from:`/`in:`/`has:`/`before:`/`after:` into
`SearchFilters`. Those map onto `MessageSearchParams` so the Server narrows
before the wire. **`is:unread` has no server equivalent** and stays local — and
because the push-down isn't guaranteed exhaustive, the same local predicate every
other provider applies still runs over the results.

### Events poll

`endpoints.ws_events` exists and is experimental, and a polling fallback has to
exist anyway. So this phase polls `chats.list` on a 15s tick, emits
`conversationUpdated` plus a `messageAdded` from the chat's own preview, and
carries a watermark cursor (the newest `lastActivity` emitted) so a relaunch
doesn't replay the whole list. A transient failure yields a `healthChanged` and
keeps polling rather than ending the stream, which would make the composite back
off and reconnect a child that is fine.

The socket lands in a later phase *in front of* this, not instead of it.

### Read-only means read-only

The API offers `markRead`, `archive`, drafts, reactions, sends and chat
creation. Every one is out of scope. `send`/`react` **reject** with
`.unsupported` rather than silently no-op, and the send capability is not
advertised, so nothing can offer an action that then fails.

`messages(ids:)` returns nothing: the API resolves a message only *within* a
chat (`GET /v1/chats/{chatID}/messages/{messageID}`) and a bare `MessageID`
doesn't carry its chat. Rather than guess, Beeper bookmarks are absent from the
saved-messages tab until §3 stores the owning chat alongside them.

### Not bundled

Trill connects to a Server the user runs. Bundling or auto-installing it is an
explicit non-goal — the spike measured 288–450 MB RSS idle.

## Consequences

- Live mode gains a second child **only when a token is stored**. With none, the
  composite has one child and behaves exactly as before.
- Fixture mode is untouched and still cannot reach a network or the Keychain.
- Contract fixtures are synthesized and must stay that way: the Server holds the
  user's real messages, and no real name, handle, phone number, body, avatar or
  `mxc://` URL may appear in a fixture, test, log, commit message or PR body.
- The ship gate (§5) is **not** met: no validated Server version, and none of
  the live-Server manual checks have been run.
