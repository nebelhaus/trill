# Ideas & feature backlog

A living idea pool for Trill, regenerated 2026-07-15. This is a
brainstorm, not a commitment — it exists so good ideas don't evaporate between
sessions. It extends the [PRD](../PRD.md) vision (local-first, keyboard-first,
user-owned organization) with concrete, prioritized, feasibility-tagged items.

## How to read this

- **Effort** — `S` ≈ hours · `M` ≈ a day · `L` ≈ multi-day.
- **Feasibility** — `✅` clean within our constraints · `⚠️` possible but
  constrained/tricky · `⛔` blocked by a hard constraint (kept here so it isn't
  re-proposed).
- **Status** — `🚢` shipped · `🚫` declined (deliberately not pursuing) · blank = open.

The single biggest asset this app has that Apple's Messages does not: **direct,
read-only access to the entire local `chat.db`.** The retrieval, analytics, and
organization sections lean on that superpower hardest — that's where we can beat
Messages outright. Sending is the weak axis (AppleScript-only), so send-side
ideas are deliberately modest and clearly bounded.

## Constraint reality (read before proposing send-side features)

These are out of reach on the **current native send path** (AppleScript to
Messages.app). Listed so we stop rediscovering them. The send-backed ones
marked 🔓 are not permanent dead ends: a future vetted `platform-imessage`
layer could unlock them (see [ARCHITECTURE §6.3](../ARCHITECTURE.md#63-advanced-provider-candidate-platform-imessage))
— that's a separate, gated milestone, not something to assume in a near-term idea.

| Wish | Why it's blocked on the native path |
|------|------------------|
| Send a tapback / react to a message | ⛔ 🔓 Messages.app exposes no automation surface for tapbacks; unlockable via `platform-imessage`. |
| Send a threaded/inline reply | ⛔ 🔓 AppleScript `send` has no reply-target parameter; unlockable via `platform-imessage`. |
| Edit or unsend a sent message | ⛔ 🔓 Read-only DB + no automation verb; unlockable via `platform-imessage`. |
| Mark a conversation read upstream | ⛔ 🔓 Needs a `chat.db` write; unlockable via `platform-imessage` (we keep a local read-mark overlay meanwhile). |
| Typing indicators (send or receive) | ⛔ Not durably recorded in `chat.db`; no automation to emit. |
| Message effects, polls, group admin | ⛔ Out of scope per PRD non-goals. |
| Trill's own SQL writing `chat.db` | ⛔ Hard rule — *our* code never hand-writes that database. (A vetted third-party library managing its own schema-correct writes is now policy-permitted; see [security.md](security.md).) User-owned state (stars, tags, snoozes, notes, read marks) lives in our `AppDatabase` overlay regardless — a pattern already proven by pins and read marks. |

Everything below respects these.

## Retrieval & memory — the superpower axis

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Universal Library (⌘⇧L)** | One browser for every image, link, and doc across *all* conversations, with type tabs and jump-to-source | M | ✅ 🚢 | Shipped. ⌘⇧L opens a centered overlay (palette/search pattern) with Images/Links/Files tabs. New `libraryItems(kind:limit:)` provider method over all-chats `ChatDatabaseReader.allAttachments` (media vs. file split by UTI/MIME) + `linkCandidates` (http/www-prefiltered scan → `LinkExtractor` URL detection, deduped per thread). Jump-to-source reuses `select(_:focus:)`; only reaches threads in the loaded list. |
| **Advanced search operators** | `from:`, `in:group`, `has:link`, `has:image`, `before:`/`after:`, `is:unread` in the global search box | M | ✅ 🚢 | Shipped. Pure `SearchQueryParser` (raw string → `SearchFilters` + residual text) feeds one `MessageSearchQuery.matches` predicate both the fixture and live search paths apply. |
| **Scoped in-thread find (⌘F)** | Find-in-conversation with match highlight and next/prev, without leaving the thread | S–M | ✅ 🚢 | Shipped. ⌘F opens a docked find bar over the open thread; ⌘G / ⇧⌘G (or ⏎ / the chevrons) step matches. Scoped to loaded messages; reuses the reveal/highlight machinery. |
| **Link inbox** | Every URL ever received, deduped, newest-first, with sender + timestamp + optional OG preview | M | ✅ 🚢 | Shipped (`c9fb4f1`). The Universal Library's Links tab is the inbox (all URLs, deduped per thread, newest-first, sender + timestamp). OG preview landed as the opt-in `linkPreviews` setting: a `LinkPreviewLoader` actor (3-tier cache — memory / `AppDatabase` `link_previews` table / in-flight coalescing; tolerant OG/`<title>`/meta parser; promotes `http→https` so ATS doesn't drop bare-domain links). Rich cards render both in the Links tab and under linked message bubbles (`InlineLinkPreview`, wired via a `linkPreviewLoader` environment value). |
| **Saved / starred messages** | Local bookmarks on any message, browsable in one place | M | ✅ 🚢 | Shipped. `saved_messages` overlay table keyed by `MessageID.persistenceKey` (no chat.db write) → `savedMessageIDs` set on `InboxModel`, loaded alongside pins/VIP and toggled optimistically. A bubble's context menu gains **Save Message** / **Remove from Saved**; saved bubbles wear a bookmark star on the corner opposite their reactions. The Universal Library grows a **Saved** tab (`LibraryKind.saved`): the repository assembles it from `savedMessageIDs` + a new `messages(ids:)` provider query (Live resolves via `reader.messages(guids:)` grouped per chat, like `search`; Fixture filters its set), newest-first; rows show sender · body · thread · date and jump-to-source via `openLibraryItem`. **⚠️ Merge note:** this branch was cut from schema v9 and numbers its migration **13**, deliberately skipping 10–12 (which `master` already claimed for archived/muted/snoozed). 13 both merges into master without a renumber *and* actually applies against the shared app-support overlay DB other branches have advanced to v12 (a migration ≤ 12 would be silently skipped there); `IF NOT EXISTS` keeps it idempotent. |
| **Jump to date** | Date scrubber / "go to date" to leap anywhere in a long thread instantly | M | ✅ 🚢 | Shipped. ⌘J / a header calendar button opens a popover (quick 1w/1m/1y presets + a hand-drawn Rice `DayCell` month grid — the stock graphical `DatePicker` fought the dark palette). Picking a day resolves the date to a paging position *server-side* — a new `messages(in:around:limit:)` on the provider (`DatedMessagePage` = window + anchor) so one query lands the reader deep in history instead of dozens of backward pages. Live provider resolves via two ROWID reader queries (`anchorRowID(onOrAfterAppleDate:)` + `messageRowID(newerThan:offset:)` for a slice of newer context); fixture mirrors it with index math; the protocol default falls back to the newest page. `ConversationModel.jump(to:)` replaces the timeline, then reuses the reveal/flash machinery on the anchor; `nextBefore` continues older paging. |
| **On this day** | Surface messages from today's date in prior years | M | ✅ 🚫 | Declined — not something I want to build for now. |
| **Attachment search** | Find attachments by filename, type, or size across chats | S–M | ✅ 🚫 | Declined — the shipped Universal Library + advanced search operators (`has:image`, `from:`) cover this need well enough. |
| **Conversation export** | Export a thread (or date range) to Markdown / plain text / HTML | M | ✅ 🚢 | Shipped. A pure, tested `ConversationExporter` (mirrors `ConversationStatsBuilder`) turns `Message` values into a Markdown / plain-text / HTML document — chronological, day-grouped, with sender labels, attachment/reaction lines, HTML escaping, and an optional inclusive date-range clip. `ConversationModel.loadAllForExport` pages the whole thread off the shared timeline state so exporting a long history never disturbs what's scrolled into view. The `square.and.arrow.up` header button opens `ConversationExportView`: format picker + date-range toggle + live preview, then Copy or Save… (`NSSavePanel`, format-typed with a sanitized filename stem). Read-only throughout; chat.db is never touched. |
| **Writing-style export ("voice profile")** | A Markdown profile that characterizes *how you write* — cadence, greetings, emoji/tapback habits, sign-offs — to hand to an LLM so it can draft in your voice | M | ✅ ⚠️ | Backlog (from notes). The corpus already ships: `BulkExport` (per-thread Markdown → zip + `index.md`) and `ConversationExport` produce exactly the LLM-ready Markdown — `ExportSettingsView` literally frames the bulk export as "ready to hand to an LLM." Net-new is the *analysis* pass that distills that corpus into one compact style profile: one long "creation" task, the profile then reused anywhere. Read-only throughout; chat.db is never touched. **Gate:** any on-device/LLM analysis is subject to the separate privacy/design review the PRD (§8) and `ARCHITECTURE.md §22` require for AI features — nothing sent off-device without an explicit decision. |

## Insight & analytics — impossible in Apple Messages

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Conversation stats panel** | Per-thread: total messages, you-vs-them ratio, median response time, most-active hours, current streak | M | ✅ 🚢 | Shipped (`b28906a`). Chart button in the header opens a sheet; a pure `ConversationStatsBuilder` over lightweight `MessageStatSample`s (`date` + `is_from_me`) feeds it, with a narrow `statSamples` provider query so whole-thread aggregation stays cheap. |
| **Relationship timeline** | Per contact: first message ever, total volume, media count, longest silence, cadence over time | M–L | ✅ 🚫 | Declined — not something I want to build. |
| **Needs-reply detector** | Smart filter/section: threads whose last message is *from them* and unanswered for N hours | S–M | ✅ 🚢 | Shipped (`999debf`). ⇧⌘R toggles the triage filter; `lastMessageFromMe` + `reactedToLatestInbound` (both from chat.db — a tapback I left counts as a reply) feed a pure `NeedsReply` helper (3h default). |
| **Year in review** | An annual "wrapped" recap: top contacts, message counts, busiest day, top emoji/tapback | L | ✅ 🚫 | Declined — feasible but not worth the L-sized effort for a seasonal gimmick. |
| **Response-time insights** | How fast you reply to whom, and who leaves you on read | M | ✅ ⚠️ | **Partially shipped.** The core metric exists per-thread in the stats panel (`ConversationStatsBuilder` → "You reply in" / "They reply in", turn-switch-aware medians). Still missing the *cross-contact* surface the idea is really about: an all-conversations ranking of who you answer fastest and "who leaves you on read." That aggregate (run the median-reply builder over every thread, sort, present) is the net-new work. Sensitive framing; keep it private/local and non-judgy. |

## AI & style — local-first, BYOK

The one place AI fits the app's local-first, reads-everything-so-earn-it promise
without breaking it. The rule: **anything that ships message content to a cloud
model is the off-device export we already refused once** (see *Scheduled send*),
so it's opt-in, BYOK, and loud — or it doesn't run a model at all. The
already-shipped item does the latter: it produces a *document* the user feeds to
a model themselves; trill never makes a call and nothing leaves the Mac.

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Writing-style profile** | Scan how *you* text and export a Markdown "style profile" built to paste into an AI so it recreates your voice | M | ✅ 🚢 | Shipped. Zero AI in-app, zero network, zero key — the "scan" is pure counting over your own messages (`StyleProfileBuilder`, mirroring `ConversationStatsBuilder`): length, burst rhythm, casing, terminal punctuation, emoji, characteristic words/phrases, openers/closers, reply cadence, plus a deduped time-spread set of verbatim samples for few-shot grounding. `StyleProfileExporter` (mirroring `ConversationExporter`) renders a ready-to-use prompt + metrics sheet + samples; `StyleProfileView` is the sheet (full-history read → preview → Copy / Save…). Two scopes share one type via `StyleScope`: **per-thread** (`signature` button in the conversation header, reuses `loadAllForExport`) and **global** ("Writing Style Profile…" in the Messages menu → `InboxModel.loadMyMessages` → new `myMessages(limit:)` provider query: my outgoing text across every chat, live via a narrow `is_from_me = 1` scan, no per-thread hydration). The global scan is mine-only, so bursts/reply-latency are suppressed there (no turn boundaries). The AI happens downstream, on the user's side. |
| **Style-aware tab completion** | Ghost-text completions in the composer, written in your voice to *this* person (BYOK, opt-in) | L | ⚠️ | **Next slate.** The send-side counterpart, and the one feature that must send message content off-device — so it's a loud, off-by-default BYOK setting (user's own Anthropic/OpenAI key), with an on-device model (Apple Foundation Models / local MLX) as the promise-consistent fallback. Latency discipline is the hard part: steal pounce's QuickAnswer contract — never block a keystroke on I/O; completions come from a debounced background call rendered as ghost-text alongside the existing `/`-trigger picker, never inside it. Cost is a non-issue at the right tier: with prompt-caching + debounce, a fast model (Haiku/Sonnet) runs ~$0.60–1.50/mo at ~100 completions/day; SOTA (Opus) is the wrong tool here — too slow for inline, not worth the tokens. **The shipped style profile is this feature's cached system prompt** — build order compounds. Surface the exact data flow in the Data-transparency panel. |
| **BYOK settings + data-transparency panel** | One place to enable AI features, paste a key, and see exactly what would leave the device | S–M | ✅ | Precondition for the completion feature — pairs with the *Data transparency panel* idea in Privacy & trust. Off by default; nothing networks until the user opts in and pastes a key. |

## Organization & triage

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Command palette (⌘K)** | Fuzzy jump to any conversation, action, or setting; the keyboard spine of the app | M | ✅ 🚢 | Shipped (`0474b5c`). ⌘K opens it; full-text message search moved to ⇧⌘F. Subsumes the Quick switcher. |
| **Snooze a thread** | Hide a conversation until a chosen time, then resurface it | M | ✅ 🚢 | Shipped. `snoozed_conversations` overlay table (migration 12, renumbered from 10) maps a thread → wake time; `snoozedUntil` hides it from every normal scope while `wake > now`. A pure, tested `SnoozeOption` (1h/3h/this-evening/tomorrow/next-week, all guaranteed future) computes the wake date; an InboxModel timer (`rescheduleSnoozeWake`) fires exactly when the next thread is due and prunes it, so resurfacing is event-driven, not polled. Snooze/Unsnooze via the row context menu. |
| **Folders / tags** | User-defined labels and folders for conversations, local-only | M–L | ✅ 🚢 | Shipped. `folders` + `folder_members` overlay tables (many-to-many, so folders double as tags); each folder carries a name + Rice accent color. A sidebar scope list ("All Messages" + folders + New Folder) narrows `visibleConversations` *before* the unread/needs-reply filter, so the two axes compose. Assign via a conversation's Folders context submenu; manage via folder-row context menu + a reusable `FolderEditorView`. Also reachable from ⌘K. **⚠️ Merge note:** this uses `AppDatabase` migrations 5 & 6 — the in-flight *Canned responses / snippets* branch also claims migration 5. Both are correct against `master` (1–4) in isolation, but whichever merges **second** must renumber its migrations (in both the `migrations` array and `currentSchemaVersion`) so they don't collide. |
| **Archive** | Remove a thread from the main list without losing it | S | ✅ 🚢 | Shipped. `archived_conversations` overlay set (migration 10, renumbered from 8 to clear the VIP collision); archived threads drop out of every normal scope in `visibleConversations` and are reachable via a sidebar **Archived** scope chip (shown only once non-empty, mutually exclusive with folder scope). Archive/Unarchive via the row context menu or ⌘K. |
| **Mute a conversation** | Suppress that thread's notifications locally | S | ✅ 🚢 | Shipped. `muted_conversations` overlay set (migration 11, renumbered from 9), checked in `maybeNotify`. Muted threads stay in the list with a `bell.slash` glyph; toggle via the row context menu or ⌘K. Mute is the strongest gate — it silences even a VIP (muting is a deliberate override that wins over VIP always-notify). |
| **VIP contacts** | Always-notify + always-pin a chosen set, in their own section | S–M | ✅ 🚢 | Shipped. `vip_conversations` overlay table (migration 8) → `vipIDs` set on `InboxModel`, mirroring pins. VIP forms a sort tier *above* pinned (always-pin), gets its own titled "VIP" section atop the unscoped list (`showsVIPSection` / `visibleVIPConversations`), and threads an `isVIP` flag into `maybeNotify` → `NotificationCoordinator.post` for a ⭐-marked banner. (An unmuted VIP always-notifies; an explicitly muted VIP stays silent — Mute wins.) Toggle via row/thread context menu, the ⭐ toolbar button, ⌘K, or ⌃⌘V. |
| **Filter by service** | Toggle iMessage / SMS / RCS visibility | S | ✅ 🚢 | Shipped. A composable axis (not the mutually-exclusive `filter`): `hiddenServices: Set<MessageServiceKind>` in `InboxModel`, persisted to UserDefaults, applied in `visibleConversations` *after* folder scope and *before* the unread/needs-reply filter, so all three compose. `.unknown` is never hidden (`MessageServiceKind.togglable` = iMessage/SMS/RCS). UI is a `Toggle`-row menu in the sidebar header driven through the shared `RiceIconButtonStyle` (`.menuStyle(.button)`) so it matches its neighbours and tints only when a service is hidden; a "Show All Services" reset doubles as the off switch. Mirrored into the overflow menu; the open thread always stays visible. |

## Power-user velocity

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Vim-ish list nav** | `j`/`k` move threads, `Enter` opens, `g`/`G` ends, all without the mouse | S–M | ✅ 🚫 | Declined — not a fit for the intended interaction model. |
| **Quick switcher** | ⌘K-style recent-conversation switcher (editor tab-switch feel) | S–M | ✅ 🚫 | Declined — subsumed by the shipped command palette (⌘K). Distinct from **Conversation tabs** below: the palette is find-then-jump (one thread), tabs hold several threads open in parallel. |
| **Conversation tabs** | Browser-style strip of open threads across the top of the detail pane, flip between them instantly | M | ✅ 🚢 | Shipped. Fulfils PRD P1 "Conversation tabs". `InboxModel.openTabs` + a `tabModels` dict give each open tab its own *warm* `ConversationModel` (invariant `Set(openTabs) == Set(tabModels.keys)`), so switching is instant and background tabs keep taking live messages (`.messageAdded`/`.databaseChanged` fan out to all). `conversationModel` is computed off the active tab, so `ConversationView` re-binds automatically. Browser model: a sidebar click navigates the active tab in place; ⌘T / ⌘-click / the row's "Open in New Tab" opens a new one. Progressive — the strip (`TabStripView`) only appears at 2+ tabs, chips size to their label, reorder by drag & drop, and persist/restore across launches. Shortcuts ⌘T · ⌘⇧] / ⌘⇧[ · ⌘W (close-tab, disabled at <2 so ⌘W still closes the window), mirrored into `ShortcutCatalog`. Chips sit below a slim titlebar-drag clearance so a press-drag reorders instead of moving the window. No chat.db write. Not yet done: double-click-to-open (SwiftUI's single-click-fires-first made it unreliable) and the separate PRD P1 "Multiple conversation windows". |
| **Canned responses / snippets** | Reusable text with a picker or `/`-trigger in the composer | M | ✅ 🚢 | Shipped. `snippets` overlay table (migration 7, renumbered from 5 to clear the Folders collision) + `SnippetStore` shared by composer and Settings. A trailing `/keyword` opens a floating picker (`SnippetTrigger` parse → `SnippetRanking` over `FuzzyMatch`); ↑↓ pick · ↵/⇥ insert · esc dismiss, routed through `GrowingTextView`. Manage in Settings; seeds a starter set on first launch. |
| **Slash commands** | `/shrug`, `/unflip`, `/date`, insert-snippet in the composer | S | ✅ 🚢 | Shipped. Built-in commands live in the *same* `/`-trigger picker as snippets, so one popover, one key-routing path, one ranking. A pure `SlashCommand` (keyword + `Expansion` — `.literal` kaomoji or dynamic `.date`/`.time`, resolved at insert time so `/date` reads the clock on pick, not on trigger) plus a `CompletionItem` union (`.command`/`.snippet`) that `CompletionRanking` blends and fuzzy-scores together. Commands never open a fill session and wear a `slash.circle` badge; snippets keep their template badge + ⇥ fill. Ships `/shrug`, `/flip`, `/unflip`, `/lenny`, `/date`, `/time` — no table, no migration. |
| **Shortcut cheat-sheet (⌘/)** | Overlay listing every keybinding | S | ✅ 🚢 | Shipped. ⌘/ toggles a floating `ShortcutCheatSheetView` over a dimmed backdrop (palette-sibling presentation); Esc / click-outside / ⌘/ again dismiss. A pure, tested `ShortcutCatalog` (four sections — Navigation & Search, Conversations, View, Composer) is the single source of truth, hand-kept in lockstep with `AppCommands` since SwiftUI `Commands` can't be reflected; rows render label + individual keycaps, greedily bin-packed into two balanced columns. Reachable via ⌘/, the Messages menu, and ⌘K. No table, no migration. |

## Composition & sending (deliberately modest — see Constraint reality)

| Idea | What | Effort | Feas. | Notes |
|------|------|--------|-------|-------|
| **Scheduled send** | Queue a message to dispatch at a chosen time via the existing AppleScript path | M | ⛔ | **Deferred until we have a server.** Technically buildable, but the send path drives Messages.app locally over Apple Events — there is no server anywhere. So a scheduled message can only fire while this Mac is awake (or wakeable from sleep); if the laptop is off/closed at the chosen time it silently can't send. The only true fix is a cloud relay that sends on our behalf, which would mean uploading message text off-device — a hard no against the local-first/privacy premise. Revisit if the app ever gains a server component. |
| **Undo send window** | Buffer the dispatch a few seconds so an accidental send can be cancelled | S | ✅ 🚢 | Shipped. `ComposerModel.send()` holds the message for a 5s window (opt-out via the `undoSend` setting, default on) instead of dispatching straight away: the box locks with the draft intact and the round send button becomes an Undo arrow (Esc / `.cancelAction`) that cancels and hands the text back. The window fires the real `sendAction` when it elapses; switching conversations mid-window flushes the held send in the background (draft restored on failure) so a send is never dropped. Setting lives in Settings → Undo send. |
| **Tapback handoff** | Since we can't send tapbacks, one click focuses the target message in Messages.app so the user reacts there | S | ⚠️ 🚫 | Declined — the payoff isn't there. Messages' scripting can activate the app and open a *conversation* (via `imessage://` / `send … to chat id`), but there's no public way to reveal a *specific message* — that would need brittle System Events AX scripting plus a new Accessibility permission. What's left (bounce the user into the thread, react manually) is too thin to earn its place. |
| **Message templates** | Structured, fill-in-the-blank outgoing messages | S–M | ✅ 🚢 | Shipped. Folded straight into snippets — a *template* is just a snippet whose body carries `{blank}` markers, so no new store, table, or migration. Picking one (`/`-trigger or click) inserts the body and enters a **fill session**: the first blank is selected, ⇥ / ⇧⇥ step between the rest, typing over each replaces the whole `{…}` marker. Pure `MessageTemplate` (brace scan → `NSRange`s, live-searched each ⇥ so edits never invalidate later offsets) drives a `ComposerModel` session that publishes a `PendingSelection` the `GrowingTextView` applies after its text sync. Template rows badge in the picker; Settings gained a hint; a starter `meet` template seeds on first launch. |
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

1. ~~**Universal Library (⌘⇧L)**~~ — ✅ shipped. Retrieval lane (media query +
   new browser). The loudest "we beat Messages" surface.
2. ~~**Conversation stats panel**~~ — ✅ shipped (`b28906a`). Analytics lane.
3. ~~**Folders / tags**~~ — ✅ shipped. Organization lane (`AppDatabase`
   overlay + sidebar `visibleConversations`). PRD-core.
4. ~~**Canned responses / snippets**~~ — ✅ shipped. Composition lane
   (composer-only).

All four of this wave have since landed (see the feature tables above for
per-feature detail); kept here as the historical slate.

Coordination note: 3 and 4 both add tables to `AppDatabase`; give their
migrations distinct, ordered version numbers so they merge cleanly. Second
wave once these land: Snooze / Archive / VIP (sidebar lane) and Link inbox /
Attachment search (media lane).

## Triage overlays landed (2026-07-16)

**Snooze + Archive + Mute** shipped together as one sidebar-lane branch — they
share the per-conversation overlay + `visibleConversations` + `maybeNotify`
machinery, so building them apart would have meant three-way conflicts on the
same functions. Three new `AppDatabase` tables, **migrations 10 (archive), 11
(mute), 12 (snooze)**, bumping `currentSchemaVersion` to 12.

**Merge resolution:** this branch was authored against migrations 8–10 but merged
*after* VIP contacts (migration 8) and Open Graph link previews (migration 9)
landed on `master`, so — per the second-to-merge-renumbers rule — its migrations
were renumbered to 10/11/12 (in the `migrations` array, `currentSchemaVersion`,
and the `AppDatabaseTests` assertion). The merge also reconciled Mute with the VIP
`maybeNotify` seam: **Mute wins** — an explicitly muted thread stays silent even
if it's a VIP (muting is a deliberate override; VIP "always-notify" only outranks
the default). All migrations are now `CREATE TABLE IF NOT EXISTS` so a shared
overlay DB collided across worktrees can still advance instead of failing `init`
and silently dropping to a throwaway temp store.

## Writing-style profile landed (2026-07-19)

The first **AI & style** item shipped — and notably it ships *no* AI in the app:
the "scan your writing style" feature is pure on-device counting that produces a
Markdown document you paste into a model yourself, so it stays inside the
local-first, zero-network promise with no key and no egress. Per-thread
(`signature` header button) and global (Messages menu → new `myMessages(limit:)`
provider query) scopes share one `StyleScope`-parameterized type. New files:
`StyleProfile.swift` (builder), `StyleProfileExport.swift` (Markdown exporter),
`StyleProfileView.swift` (sheet). No `AppDatabase` migration — read-only
throughout. Next on this lane is **style-aware tab completion** (BYOK, opt-in),
which reuses this profile as its cached system prompt; it needs the BYOK
settings + data-transparency panel first.
