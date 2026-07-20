# ADR 0001: Use `platform-imessage`, with live access safety-gated

- Status: Accepted for the foundation; live provider blocked pending a safe upstream API
- Date: 2026-07-13

> **Amended 2026-07-18:** the *absolute* no-write rule this ADR relied on has been relaxed. Trill's own code still never hand-writes to `chat.db`, but writes performed by a well-maintained, vetted third-party library (e.g. `platform-imessage`) that keeps the schema correct are now permitted — see the current [Core invariant](../security.md). The gating below is therefore now a **vetting + signed-host validation** gate, not a categorical prohibition, and forcing `createIndexes: false` upstream is no longer required.

## Context

The planning documents originally proposed `openclaw/imsg`. The product direction was changed to Beeper's [`platform-imessage`](https://github.com/beeper/platform-imessage), and — under the policy in force at the time — user safety required that the application never write to an Apple-owned Messages database at all.

The inspected dependency is the exact 0.24.4 tag at revision `78cd285e30a5afc109102553bbbe17ea80d66d27`. It is MIT licensed, declares Swift tools 5.9, publishes the `IMessage` and `PlatformSDK` library products, and declares macOS 11 support in the package configuration. This app retains its macOS 14 deployment target.

## Investigation result

The public `PlatformAPI` surface includes structured thread/message DTOs, paged `getThreads` and `getMessages`, search, event callbacks, and send methods. Direct Swift Package integration therefore compiles and the adapter can map public `PlatformSDK` DTOs without leaking them into domain or UI code.

It is not safe to instantiate the API in this app today:

- `src/IMessage/Sources/IMessage/PlatformAPI.swift` constructs `IMDatabase(createIndexes: true)`.
- `IMDatabase.createIndexesIfNecessary` opens Apple's Messages database read-write and can execute `CREATE INDEX IF NOT EXISTS`.
- The public `PlatformAPI` initializer does not expose an end-to-end `createIndexes: false` option or injected read-only database.

At the time this conflicted with the product's then-absolute no-write rule (since amended — see the banner above), and Full Disk Access did not make the write acceptable.

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
| TCC identity? | For direct in-process integration, Full Disk Access, Accessibility, Contacts, and Automation prompts apply to the signed Trill app bundle identity. |

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

## Update 2026-07-19: composite write-overlay activation (tapbacks)

With a Developer-ID signing identity now available, the write path is being activated the way §6.3 sequenced it — **layering** `platform-imessage` over the read-only baseline rather than replacing it. The first write-backed action is **sending tapbacks**.

- **`CompositeMessagesProvider`** (`Trill/Providers/Composite/`) wraps `LiveIMessageProvider`: every read, search, event, and text send forwards to the vetted read-only baseline unchanged, and **only `react(_:)`** is delegated to **`PlatformWriteBackend`**, which constructs and drives `PlatformAPI`. Reads never route through the write-capable library.
- `PlatformAPI`'s tapback (`addReaction(threadID:messageID:reactionKey:)`) is **Accessibility UI-automation of Messages.app**, not a `chat.db` write. It targets by raw `chat.db` thread + message GUID — exactly the identifiers the read-only reader already produces, so no ID translation is needed. The only `chat.db` write in the path is `PlatformAPI`'s own `IMDatabase(createIndexes: true)` index creation at construction — the sanctioned vetted-library exception, no longer forbidden (see the amendment banner).
- **Gated OFF by default.** The composite is wired in only when the hidden `platformWritesEnabled` `UserDefaults` flag is set (`InboxModel.makeProvider`); with it off, `.messages` is the plain read-only provider and `PlatformAPI` is never constructed. Even with the flag on, tapback UI stays hidden until the runtime **Accessibility** health probe (`AXIsProcessTrusted`) passes — capability + health, fail-closed, via `CapabilityGate.canReact`.
- **Send-once, no auto-retry.** A confirmed `addReaction` → `.confirmed`; not Accessibility-trusted → `.rejected(.permissionDenied)`; a thrown result after a trusted attempt → `.unknown` (surfaced, never presented as success, never retried).

The unit-testable subset of the safe-enablement criteria is covered by `CompositeWriteOverlayTests` (routing, capability/health merge, fail-closed gating, reaction-key mapping). Criteria **2, 3, and 5** still require the **signed-host validation pass** below and remain the gate before the flag is flipped on for real use.
