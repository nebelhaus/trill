# Testing

## Fixture policy

All automated and normal development tests use `FixtureProvider`. The Beeper
adapter's tests run against **synthesized** contract fixtures
(`TrillTests/BeeperFixtures.swift`) through a stubbed `URLProtocol`: no test
reaches the network or the Keychain, and no capture of a real Beeper Server —
which holds the user's actual messages — may ever be committed. Its content is deterministic and synthetic; it does not copy or derive from a developer's Messages database. The fixture covers direct iMessage, SMS, a group conversation, pagination, search, events, reply/reaction relationships, available and missing attachments, and metadata-only image rendering.

Automated tests must never enable a send capability or invoke a real send. An unknown send result is explicitly non-retryable.

## Automated tests

In Xcode, select the **Trill** scheme and press **⌘U**. Review and approve the pinned package's `PlatformSDKMacros` prompt if Xcode presents it.

For an unattended Terminal run from the repository root:

```sh
xcodebuild -skipMacroValidation \
  -project Trill.xcodeproj \
  -scheme Trill \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

The suite verifies:

- Provider-qualified ID equality and reversible encoding.
- Deterministic conversation, history, and search pagination.
- Controllable fixture events and repository message deduplication.
- `platform-imessage` thread/message/attachment/reaction/reply DTO mapping.
- Version-zero SQLite migration plus pins, drafts, and cursors.
- Permission/schema health mapping and capability gating.
- No automatic retry for unknown send outcomes.
- Composite aggregation: merged conversation/search paging across children with
  interleaved timestamps, routing (a call for one child's conversation never
  reaches another), identifiers never re-qualified, merged events with per-child
  cursors, partial failure, and composite-cursor round-trip — including a cursor
  naming a child that's since gone, a child added after the cursor was minted,
  and a child rejecting the cursor handed to it.
- `ServiceIdentity`: the hidden-service filter's `UserDefaults` migration off the
  old `MessageServiceKind` raw values, and per-account filter identity.
- Beeper adapter: wire decoding (including `seen`'s three shapes), account →
  service identity with two accounts on one network, `Chat.id` used as the
  identifier rather than `localChatID`, Beeper's iMessage excluded both at
  request time and at mapping time, Matrix HTML flattening, non-messages
  (`REACTION`/`NOTICE`/deleted/hidden) filtered out, delivery-state and reaction
  mapping, attachments left `.downloadRequired`, search push-down, health landing
  on `remoteRelay` rather than `messagesDatabase`, and sends staying refused.

The Inbox suites each run against their own `UserDefaults` suite
(`InboxModel(defaults:)`). XCTest runs suites in parallel *processes* that share
one defaults domain, so the sidebar filter / provider mode / open-tab keys would
otherwise race.

## Manual fixture checklist

1. Run the app without granting Full Disk Access; confirm **Synthetic Fixture** loads.
2. Confirm the sidebar shows iMessage, SMS, group, unread, preview, timestamp, and pin states.
3. Open **Avery Chen**, load all earlier pages, and confirm the visible anchor does not jump to the newest message.
4. Confirm text, reply, reaction, image metadata, file metadata, and unavailable attachment states render.
5. Use **⌘K** and search for `synthetic`; select a result.
6. Pin and unpin a conversation, restart, and confirm persistence.
7. Enter a draft, switch conversations or restart, and confirm it returns.
8. Confirm the send button stays disabled and its help text explains why.
9. Check light/dark appearance, text size, keyboard navigation, and VoiceOver summaries.

## Live-provider checklist (currently expected to stop at the gate)

This is a diagnostic checklist, not authorization to enable live reads or sends.

1. Select **Live** without Full Disk Access. Confirm the permission-specific recovery screen appears rather than an empty inbox.
2. Use **Open Full Disk Access**, grant access to the exact built Trill app if desired, relaunch, and recheck.
3. Confirm the screen changes to **Live Provider Safety-gated** and still lists no real conversations.
4. Confirm no Accessibility, Automation, Contacts, or notification prompt appears merely from selecting the provider.
5. Confirm the composer cannot send and no message appears in Messages.app.

Do not disable SIP. Do not add Terminal to Full Disk Access as a substitute for validating the app's own TCC identity.

## Beeper contract check (manual, needs a Server — not part of the suite)

The Beeper adapter's contract came from the official `@beeper/desktop-api` 5.0.0
types, not from a running Server (ADR 0004), so no response has ever been
observed. `scripts/beeper-contract-check.sh` closes that: it calls exactly the
endpoints `BeeperClient` calls, with exactly the parameters it sends, and
reports the Server's `app.version`, which mapper-consumed fields are actually
present, any field the Server returns that `BeeperDTOs.swift` doesn't model, and
whether the `accountIDs` allowlist really keeps Beeper's own iMessage out.

```sh
security add-generic-password -U -s com.nebelhaus.trill \
  -a beeper.accessToken -w '<token from Beeper → Settings → Advanced → API>'
scripts/beeper-contract-check.sh
```

It is read-only and prints **field names, JSON types and counts only** — never a
message body, name, handle, or ID. Its report is safe to paste; a raw capture of
this API is a capture of the user's messages and must never be committed.

Then, in the app:

1. Live mode with no token stored: identical to before the adapter existed.
2. Live mode with the token: Beeper threads interleave with iMessage by recency,
   chips carry the right network, filters compose, and **no thread appears twice**.
3. Stop the Beeper Server mid-session: native Messages keeps working, the failure
   shows as a health row, and the inbox does not blank.
4. Revoke Full Disk Access with the Server up: the native permission screen still
   wins — Beeper's health never outranks the blocking one.
5. Fixture mode throughout: unchanged, and still unable to reach the network or
   the Keychain.

Record the validated `app.version` in ADR 0004; §5 of the refactor's ship gate
asks for it.

Once `platform-imessage` has been vetted for live use, the expanded signed-Mac checklist must cover file-write tracing (confirming every `chat.db` write comes from the vetted library, none from Trill's own SQL), a signed-in Messages account, pagination across schema variants, clean event cancellation/reconnect, permission revocation while running, and manually addressed test-account sends. Those sends must never run in CI.
