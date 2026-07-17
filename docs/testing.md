# Testing

## Fixture policy

All automated and normal development tests use `FixtureProvider`. Its content is deterministic and synthetic; it does not copy or derive from a developer's Messages database. The fixture covers direct iMessage, SMS, a group conversation, pagination, search, events, reply/reaction relationships, available and missing attachments, and metadata-only image rendering.

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

1. Select **Messages (Safety-gated)** without Full Disk Access. Confirm the permission-specific recovery screen appears rather than an empty inbox.
2. Use **Open Full Disk Access**, grant access to the exact built Trill app if desired, relaunch, and recheck.
3. Confirm the screen changes to **Live Provider Safety-gated** and still lists no real conversations.
4. Confirm no Accessibility, Automation, Contacts, or notification prompt appears merely from selecting the provider.
5. Confirm the composer cannot send and no message appears in Messages.app.

Do not disable SIP. Do not add Terminal to Full Disk Access as a substitute for validating the app's own TCC identity.

Once a safe no-index upstream API exists, the expanded signed-Mac checklist must cover read-only file tracing, a signed-in Messages account, pagination across schema variants, clean event cancellation/reconnect, permission revocation while running, and manually addressed test-account sends. Those sends must never run in CI.
