# ADR 0001: Use `platform-imessage`, with live access safety-gated

- Status: Accepted for the foundation; live provider blocked pending a safe upstream API
- Date: 2026-07-13

## Context

The planning documents originally proposed `openclaw/imsg`. The product direction was changed to Beeper's [`platform-imessage`](https://github.com/beeper/platform-imessage), and user safety requires that the application never write to an Apple-owned Messages database.

The inspected dependency is the exact 0.24.4 tag at revision `78cd285e30a5afc109102553bbbe17ea80d66d27`. It is MIT licensed, declares Swift tools 5.9, publishes the `IMessage` and `PlatformSDK` library products, and declares macOS 11 support in the package configuration. This app retains its macOS 14 deployment target.

## Investigation result

The public `PlatformAPI` surface includes structured thread/message DTOs, paged `getThreads` and `getMessages`, search, event callbacks, and send methods. Direct Swift Package integration therefore compiles and the adapter can map public `PlatformSDK` DTOs without leaking them into domain or UI code.

It is not safe to instantiate the API in this app today:

- `src/IMessage/Sources/IMessage/PlatformAPI.swift` constructs `IMDatabase(createIndexes: true)`.
- `IMDatabase.createIndexesIfNecessary` opens Apple's Messages database read-write and can execute `CREATE INDEX IF NOT EXISTS`.
- The public `PlatformAPI` initializer does not expose an end-to-end `createIndexes: false` option or injected read-only database.

That behavior conflicts with the product's absolute no-write rule. Full Disk Access does not make the write acceptable.

## Decision

Pin `platform-imessage` 0.24.4 directly in the Xcode project and compile the `IMessage` and `PlatformSDK` products. Keep `PlatformIMessageProvider` as a partial adapter that:

- Maps public provider DTOs into provider-neutral domain values.
- Performs only our own explicit `SQLITE_OPEN_READONLY` permission/schema probe.
- Advertises no live capabilities.
- Rejects send and reaction requests with `manualVerificationRequired`.
- Never constructs `PlatformAPI`.

Synthetic fixture mode remains the default and complete implementation for this milestone. We do not add the old `imsg rpc` fallback because the selected dependency changed and maintaining two production adapters would broaden the safety surface.

## Spike answers

| Question | Result |
|---|---|
| Public paged chats/history? | API exists, but cannot be called through the public facade without triggering unsafe index setup. |
| Long-lived GUI event stream? | Callback/event machinery exists, but the same construction issue blocks safe integration; lifecycle behavior remains unverified in a signed host app. |
| Safe sending? | Methods exist, but sending requires Accessibility/Automation behavior and a signed-host test. It is disabled; automated tests never send. |
| Structured health errors? | The package throws errors, but permission/schema/automation mapping has not been validated safely. The app exposes its own explicit health dimensions meanwhile. |
| TCC identity? | For direct in-process integration, Full Disk Access, Accessibility, Contacts, and Automation prompts apply to the signed NativeMessages app bundle identity. |

## Safe enablement criteria

The smallest acceptable upstream change is a public construction path that propagates `createIndexes: false` (or a read-only database dependency) through every read and event path. Before capabilities are enabled, tests must also verify:

1. No write-capable open, index, migration, vacuum, repair, or write pragma reaches `chat.db`.
2. Paged thread/history reads and event shutdown work in a signed app.
3. Permission and unsupported-schema errors map to distinct health states.
4. Send-once behavior can reconcile confirmed, rejected, and unknown outcomes without automatic retry.
5. Accessibility and Automation prompts name the built app, with SIP left enabled.

If upstream cannot provide this boundary, maintain a narrowly reviewed fork that changes only database construction and pins a commit. A helper-process design is a separate ADR and milestone, not an implicit fallback.

## Consequences

The app is useful and testable with synthetic data now, and the third-party contract is exercised at compile/test time. Real inbox data is intentionally unavailable until the safety invariant is provable. Future providers, including the BlueBubbles relay described in [ARCHITECTURE.md](../../ARCHITECTURE.md), continue to fit behind `MessagesProvider`.
