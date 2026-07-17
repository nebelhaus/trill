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
| **Universal Library (⌘⇧L)** | One browser for every image, link, and doc across *all* conversations, with type tabs and jump-to-source | M | ✅ 🚢 | Shipped. ⌘⇧L opens a centered overlay (palette/search pattern) with Images/Links/Files tabs. New `libraryItems(kind:limit:)` provider method over all-chats `ChatDatabaseReader.allAttachments` (media vs. file split by UTI/MIME) + `linkCandidates` (http/www-prefiltered scan → `LinkExtractor` URL detection, deduped per thread). Jump-to-source reuses `select(_:focus:)`; only reaches threads in the loaded list. |
| **Advanced search operators** | `from:`, `in:group`, `has:link`, `has:image`, `before:`/`after:`, `is:unread` in the global search box | M | ✅ 🚢 | Shipped. Pure `SearchQueryParser` (raw string → `SearchFilters` + residual text) feeds one `MessageSearchQuery.matches` predicate both the fixture and live search paths apply. |
| **Scoped in-thread find (⌘F)** | Find-in-conversation with match highlight and next/prev, without leaving the thread | S–M | ✅ 🚢 | Shipped. ⌘F opens a docked find bar over the open thread; ⌘G / ⇧⌘G (or ⏎ / the chevrons) step matches. Scoped to loaded messages; reuses the reveal/highlight machinery. |
| **Link inbox** | Every URL ever received, deduped, newest-first, with sender + timestamp + optional OG preview | M | ✅ | Extract from message text; OG fetch is optional/networked and can be a later toggle. |
| **Saved / starred messages** | Local bookmarks on any message, browsable in one place | M | ✅ | Store `MessageID`s in `AppDatabase`; no chat.db write. |
| **Jump to date** | Date scrubber / "go to date" to leap anywhere in a long thread instantly | M | ✅ | Cursor paging already keyed on message date. |
| **On this day** | Surface messages from today's date in prior years | M | ✅ | Pure query over `date`; delightful and unique. |
| **Attachment search** | Find attachments by filename, type, or size across chats | S–M | ✅ | We already index attachment rows. |
| **Conversation export** | Export a thread (or date range) to Markdown / plain text / HTML | M | ✅ | Read-only serialization of what's already loaded. |

## Insight & analytics — impossible in Apple Messages

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Conversation stats panel** | Per-thread: total messages, you-vs-them ratio, median response time, most-active hours, current streak | M | ✅ 🚢 | Shipped (`b28906a`). Chart button in the header opens a sheet; a pure `ConversationStatsBuilder` over lightweight `MessageStatSample`s (`date` + `is_from_me`) feeds it, with a narrow `statSamples` provider query so whole-thread aggregation stays cheap. |
| **Relationship timeline** | Per contact: first message ever, total volume, media count, longest silence, cadence over time | M–L | ✅ | Great "wow" surface for the primary persona. |
| **Needs-reply detector** | Smart filter/section: threads whose last message is *from them* and unanswered for N hours | S–M | ✅ 🚢 | Shipped (`999debf`). ⇧⌘R toggles the triage filter; `lastMessageFromMe` + `reactedToLatestInbound` (both from chat.db — a tapback I left counts as a reply) feed a pure `NeedsReply` helper (3h default). |
| **Year in review** | An annual "wrapped" recap: top contacts, message counts, busiest day, top emoji/tapback | L | ✅ | Seasonal delight; reuses the stats primitives. |
| **Response-time insights** | How fast you reply to whom, and who leaves you on read | M | ✅ | Sensitive framing; keep it private/local and non-judgy. |

## Organization & triage

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Command palette (⌘K)** | Fuzzy jump to any conversation, action, or setting; the keyboard spine of the app | M | ✅ 🚢 | Shipped (`0474b5c`). ⌘K opens it; full-text message search moved to ⇧⌘F. Subsumes the Quick switcher. |
| **Snooze a thread** | Hide a conversation until a chosen time, then resurface it | M | ✅ | Local scheduler + overlay flag. PRD-aligned. |
| **Folders / tags** | User-defined labels and folders for conversations, local-only | M–L | ✅ 🚢 | Shipped. `folders` + `folder_members` overlay tables (many-to-many, so folders double as tags); each folder carries a name + Rice accent color. A sidebar scope list ("All Messages" + folders + New Folder) narrows `visibleConversations` *before* the unread/needs-reply filter, so the two axes compose. Assign via a conversation's Folders context submenu; manage via folder-row context menu + a reusable `FolderEditorView`. Also reachable from ⌘K. **⚠️ Merge note:** this uses `AppDatabase` migrations 5 & 6 — the in-flight *Canned responses / snippets* branch also claims migration 5. Both are correct against `master` (1–4) in isolation, but whichever merges **second** must renumber its migrations (in both the `migrations` array and `currentSchemaVersion`) so they don't collide. |
| **Archive** | Remove a thread from the main list without losing it | S | ✅ | Overlay flag; filter in `visibleConversations`. |
| **Mute a conversation** | Suppress that thread's notifications locally | S | ✅ | Overlay flag checked in `maybeNotify`. |
| **VIP contacts** | Always-notify + always-pin a chosen set, in their own section | S–M | ✅ 🚢 | Shipped. `vip_conversations` overlay table (migration 8) → `vipIDs` set on `InboxModel`, mirroring pins. VIP forms a sort tier *above* pinned (always-pin), gets its own titled "VIP" section atop the unscoped list (`showsVIPSection` / `visibleVIPConversations`), and threads an `isVIP` flag into `maybeNotify` → `NotificationCoordinator.post` for a ⭐-marked banner (the always-notify seam a future Mute/Focus feature must exempt). Toggle via row/thread context menu, the ⭐ toolbar button, ⌘K, or ⌃⌘V. **⚠️ Merge note:** claims `AppDatabase` migration 8 — the next overlay-table branch to merge after this must renumber if it also grabbed 8. |
| **Filter by service** | Toggle iMessage / SMS / RCS visibility | S | ✅ | Service is already on every conversation. |

## Power-user velocity

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Vim-ish list nav** | `j`/`k` move threads, `Enter` opens, `g`/`G` ends, all without the mouse | S–M | ✅ | Focus/selection model already exists. |
| **Quick switcher** | ⌘K-style recent-conversation switcher (editor tab-switch feel) | S–M | ✅ | Subset of the command palette; could ship first. |
| **Canned responses / snippets** | Reusable text with a picker or `/`-trigger in the composer | M | ✅ 🚢 | Shipped. `snippets` overlay table (migration 7, renumbered from 5 to clear the Folders collision) + `SnippetStore` shared by composer and Settings. A trailing `/keyword` opens a floating picker (`SnippetTrigger` parse → `SnippetRanking` over `FuzzyMatch`); ↑↓ pick · ↵/⇥ insert · esc dismiss, routed through `GrowingTextView`. Manage in Settings; seeds a starter set on first launch. |
| **Slash commands** | `/shrug`, `/unflip`, `/date`, insert-snippet in the composer | S | ✅ | Text transforms before send. |
| **Shortcut cheat-sheet (⌘/)** | Overlay listing every keybinding | S | ✅ | Discoverability for a keyboard-first app. |

## Composition & sending (deliberately modest — see Constraint reality)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Scheduled send** | Queue a message to dispatch at a chosen time via the existing AppleScript path | M | ⛔ | **Deferred until we have a server.** Technically buildable, but the send path drives Messages.app locally over Apple Events — there is no server anywhere. So a scheduled message can only fire while this Mac is awake (or wakeable from sleep); if the laptop is off/closed at the chosen time it silently can't send. The only true fix is a cloud relay that sends on our behalf, which would mean uploading message text off-device — a hard no against the local-first/privacy premise. Revisit if the app ever gains a server component. |
| **Undo send window** | Buffer the dispatch a few seconds so an accidental send can be cancelled | S | ✅ | Delay the AppleScript call; cancel before it fires. |
| **Tapback handoff** | Since we can't send tapbacks, one click focuses the target message in Messages.app so the user reacts there | S | ⚠️ | AppleScript can reveal/activate; the react itself is manual. Honest bridge over a hard limit. |
| **Message templates** | Structured, fill-in-the-blank outgoing messages | S–M | ✅ | Composer-side only. |
| **Multi-send / broadcast** | Send one message to several chats | M | ⚠️ | Feasible but needs careful, non-spammy UX and clear confirmation. |

## Ambient presence

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Menu-bar mini-inbox** | `NSStatusItem` with unread count + a dropdown of recent threads; click opens the window on that thread. Optional launch-at-login | M | ✅ 🚢 | Shipped. `MenuBarExtra` (window style) shows an unread count + recent threads reusing `InboxModel`; clicking a thread reveals the main window on it. Toggle in Settings (`showMenuBarItem`). Launch-at-login left for later. |
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
| **Privacy blur** | Blur message previews until hover/focus — screen-share and shoulder-surf safe | S–M | ✅ 🚢 | Shipped. `privacyBlur` setting toggle; a `privacyBlurred(revealed:)` modifier gates sidebar row previews (reveal on row hover) and conversation bubble content (reveal on bubble hover). |
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

1. ~~**Command palette (⌘K)**~~ — ✅ shipped (`0474b5c`). The keyboard spine;
   every other feature becomes reachable through it. PRD-central.
2. ~~**Needs-reply detector**~~ — ✅ shipped (`999debf`). Turned the app into a
   triage tool, not just a viewer. ⇧⌘R filters to threads awaiting your reply.
3. ~~**Advanced search operators**~~ — ✅ shipped. `from:`, `in:group`,
   `has:link`/`has:image`, `before:`/`after:` and `is:unread` narrow the global
   search box via a pure, tested `SearchQueryParser`.
4. ~~**Scheduled send**~~ — ⛔ deferred until we have a server. Would only fire
   while this Mac is awake; off/closed = silent miss, and the only true fix
   (a cloud relay) breaks local-first. See the row above.
5. ~~**Menu-bar mini-inbox**~~ — ✅ shipped. Ambient presence; glance at the
   unread count and recent threads without keeping the window up.
6. ~~**Privacy blur**~~ — ✅ shipped. Small, trust-building, and demoable.

Delight pairing when a lighter turn is wanted: **send/receive sounds** +
**delivery timeline detail** — both `S`, both charming.

## Current in-flight slate (2026-07-16)

A second wave chosen for **parallel-safety** — four distinct subsystems that
share no view or query surface, so they can be built at once without collisions:

1. **Universal Library (⌘⇧L)** — 🔨 in progress. Retrieval lane (media query +
   new browser). The loudest "we beat Messages" surface.
2. ~~**Conversation stats panel**~~ — ✅ shipped (`b28906a`). Analytics lane.
3. **Folders / tags** — 🔨 in progress. Organization lane (`AppDatabase`
   overlay + sidebar `visibleConversations`). PRD-core.
4. **Canned responses / snippets** — 🔨 in progress. Composition lane
   (composer-only).

Coordination note: 3 and 4 both add tables to `AppDatabase`; give their
migrations distinct, ordered version numbers so they merge cleanly. Second
wave once these land: Snooze / Archive / VIP (sidebar lane) and Link inbox /
Attachment search (media lane).
