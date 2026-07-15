# Ideas & feature backlog

A living idea pool for NativeMessages, regenerated 2026-07-15. This is a
brainstorm, not a commitment — it exists so good ideas don't evaporate between
sessions. It extends the [PRD](../PRD.md) vision (local-first, keyboard-first,
user-owned organization) with concrete, prioritized, feasibility-tagged items.

## How to read this

- **Effort** — `S` ≈ hours · `M` ≈ a day · `L` ≈ multi-day.
- **Feasibility** — `✅` clean within our constraints · `⚠️` possible but
  constrained/tricky · `⛔` blocked by a hard constraint (kept here so it isn't
  re-proposed).
- **Status** — `🚢` shipped · blank = open.

The single biggest asset this app has that Apple's Messages does not: **direct,
read-only access to the entire local `chat.db`.** The retrieval, analytics, and
organization sections lean on that superpower hardest — that's where we can beat
Messages outright. Sending is the weak axis (AppleScript-only), so send-side
ideas are deliberately modest and clearly bounded.

## Constraint reality (read before proposing send-side features)

These are provably out of reach on the current architecture. Listed so we stop
rediscovering them:

| Wish | Why it's blocked |
|------|------------------|
| Send a tapback / react to a message | ⛔ Messages.app exposes no automation surface for tapbacks. Best we can do is a one-click *handoff* that focuses the message in Messages.app. |
| Send a threaded/inline reply | ⛔ Same — AppleScript `send` has no reply-target parameter. |
| Edit or unsend a sent message | ⛔ Read-only DB + no automation verb. |
| Typing indicators (send or receive) | ⛔ Not durably recorded in `chat.db`; no automation to emit. |
| Message effects, polls, group admin | ⛔ Out of scope per PRD non-goals. |
| Anything that writes `chat.db` | ⛔ Hard rule. All user-owned state (stars, tags, snoozes, notes, read marks) lives in our own `AppDatabase` overlay instead — a pattern already proven by pins and read marks. |

Everything below respects these.

## Retrieval & memory — the superpower axis

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Universal Library (⌘⇧L)** | One browser for every image, link, and doc across *all* conversations, with type tabs and jump-to-source | M | ✅ | Generalizes the existing per-conversation gallery + `media()` query to an all-chats query. |
| **Advanced search operators** | `from:`, `in:group`, `has:link`, `has:image`, `before:`/`after:`, `is:unread` in the global search box | M | ✅ | Search + FTS-ish query already exist; this is a parser + SQL predicates over columns we already read. |
| **Scoped in-thread find (⌘F)** | Find-in-conversation with match highlight and next/prev, without leaving the thread | S–M | ✅ | Reuse the reveal/highlight machinery already built for search-jump. |
| **Link inbox** | Every URL ever received, deduped, newest-first, with sender + timestamp + optional OG preview | M | ✅ | Extract from message text; OG fetch is optional/networked and can be a later toggle. |
| **Saved / starred messages** | Local bookmarks on any message, browsable in one place | M | ✅ | Store `MessageID`s in `AppDatabase`; no chat.db write. |
| **Jump to date** | Date scrubber / "go to date" to leap anywhere in a long thread instantly | M | ✅ | Cursor paging already keyed on message date. |
| **On this day** | Surface messages from today's date in prior years | M | ✅ | Pure query over `date`; delightful and unique. |
| **Attachment search** | Find attachments by filename, type, or size across chats | S–M | ✅ | We already index attachment rows. |
| **Conversation export** | Export a thread (or date range) to Markdown / plain text / HTML | M | ✅ | Read-only serialization of what's already loaded. |

## Insight & analytics — impossible in Apple Messages

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Conversation stats panel** | Per-thread: total messages, you-vs-them ratio, median response time, most-active hours, current streak | M | ✅ | All derivable from `date` + `is_from_me`. High delight, low risk. |
| **Relationship timeline** | Per contact: first message ever, total volume, media count, longest silence, cadence over time | M–L | ✅ | Great "wow" surface for the primary persona. |
| **Needs-reply detector** | Smart filter/section: threads whose last message is *from them* and unanswered for N hours | S–M | ✅ | Direction of last message is one query; feeds triage. Arguably the highest-utility analytic. |
| **Year in review** | An annual "wrapped" recap: top contacts, message counts, busiest day, top emoji/tapback | L | ✅ | Seasonal delight; reuses the stats primitives. |
| **Response-time insights** | How fast you reply to whom, and who leaves you on read | M | ✅ | Sensitive framing; keep it private/local and non-judgy. |

## Organization & triage

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Command palette (⌘K)** | Fuzzy jump to any conversation, action, or setting; the keyboard spine of the app | M | ✅ | PRD explicitly wants this. Pairs with everything. |
| **Snooze a thread** | Hide a conversation until a chosen time, then resurface it | M | ✅ | Local scheduler + overlay flag. PRD-aligned. |
| **Folders / tags** | User-defined labels and folders for conversations, local-only | M–L | ✅ | Overlay in `AppDatabase`; sidebar sections. PRD core. |
| **Archive** | Remove a thread from the main list without losing it | S | ✅ | Overlay flag; filter in `visibleConversations`. |
| **Mute a conversation** | Suppress that thread's notifications locally | S | ✅ | Overlay flag checked in `maybeNotify`. |
| **VIP contacts** | Always-notify + always-pin a chosen set, in their own section | S–M | ✅ | Overlay set; complements existing pins. |
| **Filter by service** | Toggle iMessage / SMS / RCS visibility | S | ✅ | Service is already on every conversation. |

## Power-user velocity

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Vim-ish list nav** | `j`/`k` move threads, `Enter` opens, `g`/`G` ends, all without the mouse | S–M | ✅ | Focus/selection model already exists. |
| **Quick switcher** | ⌘K-style recent-conversation switcher (editor tab-switch feel) | S–M | ✅ | Subset of the command palette; could ship first. |
| **Canned responses / snippets** | Reusable text with a picker or `/`-trigger in the composer | M | ✅ | Overlay-stored; pure composer sugar. |
| **Slash commands** | `/shrug`, `/unflip`, `/date`, insert-snippet in the composer | S | ✅ | Text transforms before send. |
| **Shortcut cheat-sheet (⌘/)** | Overlay listing every keybinding | S | ✅ | Discoverability for a keyboard-first app. |

## Composition & sending (deliberately modest — see Constraint reality)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Scheduled send** | Queue a message to dispatch at a chosen time via the existing AppleScript path | M | ✅ | Fully feasible and genuinely useful; a local scheduler fires the send. Highest-value send-side idea. |
| **Undo send window** | Buffer the dispatch a few seconds so an accidental send can be cancelled | S | ✅ | Delay the AppleScript call; cancel before it fires. |
| **Tapback handoff** | Since we can't send tapbacks, one click focuses the target message in Messages.app so the user reacts there | S | ⚠️ | AppleScript can reveal/activate; the react itself is manual. Honest bridge over a hard limit. |
| **Message templates** | Structured, fill-in-the-blank outgoing messages | S–M | ✅ | Composer-side only. |
| **Multi-send / broadcast** | Send one message to several chats | M | ⚠️ | Feasible but needs careful, non-spammy UX and clear confirmation. |

## Ambient presence

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Menu-bar mini-inbox** | `NSStatusItem` with unread count + a dropdown of recent threads; click opens the window on that thread. Optional launch-at-login | M | ✅ | Glance without keeping the window up. |
| **Notification Center widget** | A small widget showing recent unread | M | ⚠️ | Widgets need an extension target + shared container; more plumbing than it looks. |
| **Focus/DND awareness** | Respect macOS Focus when deciding whether to alert | S–M | ✅ | Pairs with the sound-design idea. |

## Notifications (foundation already in place)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Inline quick reply** | Reply straight from the banner | S | ✅ 🚢 | Shipped (`8328cd9`). |
| **Mark-as-read / mute action** | Extra banner actions beyond Reply | S | ✅ | Category actions on the existing `NotificationCoordinator`. |
| **Per-contact rules** | Granular notify/mute/VIP per person or group | M | ✅ | PRD core; overlay-driven. |
| **Scheduled digests** | Batch quiet-hours messages into a periodic summary instead of one alert each | M–L | ✅ | PRD future-notification goal; the WAL watcher already knows when things arrive. |

## Craft & delight

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Send / receive sounds** | Subtle "thock" on send, "chirp" on receive, Rice-flavored, DND-aware, toggleable | S–M | ✅ | Small, high-charm. |
| **Density modes** | Compact / comfortable spacing presets | S | ✅ | Extends existing `uiScale`. |
| **Per-conversation accent** | Optional accent color or subtle wallpaper per thread | M | ✅ | Overlay-stored; fits the Rice system. |
| **Insert/appear animations** | Smooth bubble entry, tapback pop matching iMessage | M | ✅ | Pure SwiftUI polish. |
| **Light mode / theme variants** | Beyond the current dark Rice palette | M | ✅ | Theming plumbing (`riceAccent`) already exists. |
| **Delivery timeline detail** | Tap a message to see the sent → delivered → read timeline | S | ✅ | We already read all three timestamps. |

## Privacy & trust (this app reads everything — earn it)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Privacy blur** | Blur message previews until hover/focus — screen-share and shoulder-surf safe | S–M | ✅ | High trust-per-effort. |
| **App lock** | Touch ID / passcode gate on launch or after idle | M | ✅ | `LocalAuthentication`. |
| **Incognito peek** | Open a thread without writing a local read mark | S | ✅ | Skip `markCleared`. Cheap, thoughtful. |
| **Data transparency panel** | Show exactly what local data the app stores + a one-click clear | S–M | ✅ | Reinforces the local-first promise. |

## Accessibility & reach

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **VoiceOver pass** | Proper labels/roles across the timeline and sidebar | M | ✅ | Some `accessibility*` already present; needs a real audit. |
| **Dynamic type** | Honor system text-size, extend beyond `uiScale` | M | ✅ | |
| **High-contrast theme** | A legibility-first palette variant | S–M | ✅ | Pairs with theme variants. |

## Liveness & latency (largely done)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **WAL-driven live updates** | Replace the 2s poll with a `chat.db-wal` event source | L | ✅ 🚢 | Shipped (`3b7cc0c`). |
| **WAL-driven open thread** | Instant in-place edits/tapbacks/receipts; dropped the 4s timer | M | ✅ 🚢 | Shipped (`7982fac`). |
| **Tapback removal correctness** | Cancel removed/changed tapbacks | S | ✅ 🚢 | Shipped (`375db47`). |

## Recommended next slate

If picking without further discussion, this order maximizes value per effort and
compounds well:

1. **Command palette (⌘K)** — `M`. The keyboard spine; every other feature
   becomes reachable through it. PRD-central.
2. **Needs-reply detector** — `S–M`. Highest day-to-day utility; turns the app
   into a triage tool, not just a viewer.
3. **Advanced search operators** — `M`. Unlocks the retrieval superpower with
   modest work atop existing search.
4. **Scheduled send** — `M`. The one genuinely powerful send-side capability
   available to us, and a clear differentiator.
5. **Menu-bar mini-inbox** — `M`. Ambient presence; "leave it open all day."
6. **Privacy blur** — `S–M`. Small, trust-building, and demoable.

Delight pairing when a lighter turn is wanted: **send/receive sounds** +
**delivery timeline detail** — both `S`, both charming.
