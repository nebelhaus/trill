# Product Requirements Document: Native iMessage Client for macOS

## 1. Executive summary

Build a fast, compact and highly controllable native macOS messaging client for a user's existing iMessage and SMS conversations. The product should feel like a serious desktop communication tool rather than a stretched mobile interface: keyboard-first, information-dense, searchable and customizable.

The app uses the Messages account already signed in on the Mac. It does not create a new messaging network. It reads the local Messages database without modifying it and performs outbound actions through a dedicated Messages provider.

The first release is completely local. A later release may use BlueBubbles as an optional self-hosted relay for REST access, webhooks and push notifications. The future notification system must allow custom immediate notifications, summaries and scheduled digests.

Working title: **Native Messages Client**. The shipping name and visual identity are intentionally undecided.

## 2. Problem

Apple's Messages app is functional but offers limited control over information density, conversation organization, keyboard workflows, notification behavior and historical exploration. Power users cannot easily:

- Organize conversations using local-only folders, tags, pins or snoozes.
- Move quickly between active conversations with tabs or a command palette.
- Define granular per-person or per-group notification rules.
- Receive scheduled digests instead of one alert per message.
- Search history with strong context and useful filters.
- Customize density, layout, theme and message presentation.
- Build automations against a stable application-level domain model.

The opportunity is a private, local-first desktop client whose interface and organization belong to the user while Apple's Messages service remains the transport.

## 3. Product vision

The app should be the messaging equivalent of a well-designed email client or IDE:

- Fast enough to leave open all day.
- Dense without feeling cluttered.
- Fully operable from the keyboard.
- Flexible without requiring configuration before it is useful.
- Local-first and transparent about permissions.
- Extensible through clean provider and notification boundaries.

## 4. Target user

### Primary persona

A technical macOS power user who handles many personal and professional iMessage conversations, dislikes the default Messages interface and values speed, keyboard access, privacy and customization.

### Secondary personas

- A user who wants better search and attachment browsing.
- A user who wants fewer interruptions through digest-based notifications.
- A user who later wants secure access to their Messages data from another device through a self-hosted relay.

## 5. Product principles

1. **Local-first by default.** Core messaging must not depend on a cloud account or relay.
2. **Never mutate `chat.db`.** Read Apple's database; send actions through supported automation or an isolated provider.
3. **Respect macOS security.** Keep SIP enabled. Explain permissions before requesting them.
4. **Desktop-native interaction.** Menus, keyboard shortcuts, drag-and-drop, Quick Look, Services and multiple windows should behave like a Mac app.
5. **Progressive capability.** Missing permissions or unsupported provider features must degrade clearly and safely.
6. **User-owned organization.** Pins, tags, folders, drafts, notes, snoozes and notification policies live in the app's own database.
7. **Transport independence.** UI and product logic consume normalized domain models rather than `imsg`, BlueBubbles or Apple database rows directly.
8. **Privacy-preserving notifications.** The user controls whether previews show sender, body, attachment metadata or nothing.

## 6. Goals and non-goals

### Goals for the first usable release

- Display conversations and message history from the signed-in Mac.
- Receive live updates while the application is running.
- Send text and attachments.
- Resolve contact names when permission is granted.
- Provide strong keyboard navigation and global search.
- Provide local pins, favorites, tags, drafts and snoozes.
- Deliver customizable local notifications.
- Handle missing permissions and backend failures gracefully.
- Establish provider and notification abstractions suitable for future BlueBubbles integration.

### Explicit non-goals for the first release

- Reimplementing or reverse-engineering Apple's network-level iMessage protocol.
- iOS, iPadOS, Android, Windows or web clients.
- Multi-user or team accounts.
- Mac App Store distribution.
- Disabling SIP or injecting code into Messages.app.
- Writing to, repairing or migrating Apple's Messages database.
- Replacing FaceTime.
- Implementing a public internet relay.
- BlueBubbles, Firebase, APNs or UnifiedPush integration.
- Guaranteed support for edits, unsend, typing indicators, read receipts, effects, polls or group administration.

## 7. Scope and priorities

Priority meanings:

- **P0:** required for the first usable release.
- **P1:** expected shortly after the foundation is stable.
- **P2:** future expansion; design for it, do not implement it during MVP.

### 7.1 Onboarding and permissions

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Explain why Messages Data / Full Disk Access is required | P0 | Explanation appears before directing the user to System Settings. |
| Detect unreadable or missing `chat.db` | P0 | Show a specific recovery screen, never an empty inbox that looks successful. |
| Request or guide Automation permission for Messages.app | P0 | Sending remains disabled until authorized. |
| Request Contacts permission separately | P0 | Raw handles remain usable if denied. |
| Show a permission and provider health dashboard | P0 | Includes database, sending, live watch and contacts status. |
| Never require Accessibility for baseline operation | P0 | Accessibility-backed features remain optional experiments. |

### 7.2 Conversation navigation

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| List direct and group conversations | P0 | Name, participants, latest preview, timestamp, service and unread indication. |
| Sort by recent activity | P0 | Stable ordering during live updates. |
| Search/jump command palette | P0 | Keyboard shortcut, fuzzy matches contacts and chats. |
| Pin/favorite conversations locally | P0 | Does not modify Messages.app state. |
| Filter unread, direct, group and service | P1 | Filters are composable. |
| Local tags and folders | P1 | A chat may belong to multiple tags/folders. |
| Snooze a conversation | P1 | Hides or quiets it until a selected time. |
| Conversation tabs | P1 | Restore tabs between launches. |
| Multiple conversation windows | P1 | Uses standard macOS window restoration. |

### 7.3 Message timeline

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Render chronological history | P0 | Handles large chats incrementally without loading everything. |
| Distinguish outgoing/incoming and sender identity | P0 | Group sender labels remain clear. |
| Render text, images and generic attachments | P0 | Missing files show an explicit unavailable state. |
| Show tapbacks and basic reply relationships when present in data | P0 | Display-only support does not imply the ability to create replies. |
| Load older history on demand | P0 | Preserve visible scroll position. |
| Copy message text and identifiers | P0 | Context menu and keyboard support. |
| Quick Look and reveal attachment in Finder | P0 | Uses native macOS facilities. |
| Date separators and unread marker | P1 | Unread marker is based on best available source/provider state. |
| Attachment gallery | P1 | Filter by image, video, audio, link and file. |
| Message details inspector | P1 | Timestamp, sender, GUID, service, delivery metadata where available. |

### 7.4 Composer and outbound actions

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Send text to an existing chat | P0 | Prevent accidental duplicate sends during uncertain outcomes. |
| Send one or more files | P0 | Drag/drop, paste and file picker. |
| Preserve drafts per conversation | P0 | Drafts are stored only in the app's database. |
| Configurable Return/Command-Return send behavior | P0 | Setting is immediately reflected in the composer. |
| Standard tapback reactions if baseline provider supports them safely | P1 | Capability-gated; unsupported actions are hidden or explained. |
| Start a new direct chat | P1 | Validate phone/email and confirm routing. |
| Scheduled sending | P2 | Do not emulate silently unless reliability can be guaranteed. |
| Advanced replies, edits and unsend | P2 | Provider capability; never require SIP disablement. |

### 7.5 Search

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Search message text | P0 | Results include conversation, sender, date and surrounding context. |
| Search conversations and contacts | P0 | Available from command palette. |
| Filter by chat, sender and date | P1 | Query state is visible and removable. |
| Filter by attachment type | P1 | Does not scan attachment contents in MVP. |
| Saved searches | P2 | Stored locally. |

### 7.6 Notifications and digests

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Local notification for an eligible incoming message | P0 | Deduplicated and suppressed for the currently focused conversation. |
| Global preview privacy setting | P0 | Full body, sender only or generic notification. |
| Per-chat mute policy | P1 | Local policy; independent of Messages.app mute state. |
| Per-person/group overrides | P1 | Override sound, preview, priority and quiet hours. |
| Quiet hours | P1 | Time zone aware. |
| Batch bursts from the same chat | P1 | Avoid one notification per line during rapid messages. |
| Scheduled digest | P2 | Summarize queued events at user-selected times. |
| Smart digest rules | P2 | Examples: work chats hourly, family immediately, muted groups daily. |
| Custom digest presentation | P2 | Compact list, grouped by chat, unread counts and optional excerpts. |
| Remote push | P2 | Optional BlueBubbles/self-hosted relay path described in architecture. |

### 7.7 Customization

| Requirement | Priority | Acceptance notes |
| --- | --- | --- |
| Compact, comfortable and spacious density presets | P0 | Affects sidebar, timeline and composer coherently. |
| Light, dark and system appearance | P0 | Native system appearance first. |
| Sidebar and inspector visibility shortcuts | P0 | Persisted per window where appropriate. |
| Configurable keyboard shortcuts | P1 | Detect conflicts and offer reset. |
| Theme tokens | P1 | Semantic tokens, not arbitrary view-level color overrides. |
| Custom CSS | Not planned | Native views should not grow a parallel CSS rendering system. |

## 8. Primary user flows

### 8.1 First launch

1. Welcome screen explains local-first behavior.
2. App checks whether the Messages database is accessible.
3. If unavailable, app explains Full Disk Access and opens the correct System Settings pane.
4. User returns; app rechecks automatically and offers a manual retry.
5. App requests Contacts only when name resolution is about to be enabled.
6. Sending permission is requested from a deliberate “Test sending capability” action, not opportunistically during launch.
7. App imports the initial chat list and opens the inbox.

### 8.2 Read and reply

1. User chooses a chat by mouse or keyboard.
2. Recent messages appear immediately; older pages load when requested.
3. Live incoming events merge into the timeline without jumping the scroll position.
4. User types or adds attachments.
5. UI creates a pending outbound item with a client operation ID.
6. Provider sends once.
7. Pending item reconciles against the resulting database message GUID or transitions to an explicit uncertain/failed state.

### 8.3 Search

1. User opens global search.
2. Recent searches and filters appear.
3. Results stream or page in without blocking typing.
4. Selecting a result opens the conversation near the matched message and highlights it temporarily.

### 8.4 Notification policy

1. User opens notification settings globally or from a chat.
2. User chooses immediate, batched, digest or muted behavior.
3. Preview privacy and sound are configured independently.
4. The policy engine applies the most specific matching rule.
5. Notification center shows why a message was delivered, batched or suppressed when diagnostics are enabled.

## 9. Information architecture and UX

### Default window

Use a native three-region desktop layout:

1. **Sidebar:** inbox sections, filters, tags and conversations.
2. **Content:** selected message timeline and composer.
3. **Optional inspector:** participants, shared attachments, notification rules and metadata.

The app must remain functional in a narrow two-region window. The inspector is hidden by default.

### Keyboard baseline

- `⌘K`: command palette / jump to conversation.
- `⌘F`: search within current conversation.
- `⌥⌘F`: global message search.
- `⌘N`: new conversation.
- `⌘T`: open selected conversation in a tab.
- `⌘⇧]` / `⌘⇧[`: next/previous tab.
- `⌘1`…`⌘9`: switch pinned conversation or tab, configurable.
- `Esc`: dismiss transient UI or return focus to timeline.
- Up/down with an appropriate modifier: move through conversations without reaching for the mouse.

Final shortcuts should follow macOS conventions and be centrally registered so menus and command handling agree.

### Visual direction

- Native materials and typography with restrained use of translucency.
- Information-dense sidebar with clear unread and selection states.
- Message shapes should be compact and readable, not oversized replicas of iOS bubbles.
- Color conveys service and state but is never the only signal.
- All layouts meet Reduce Motion, Increase Contrast and VoiceOver requirements.

## 10. Data ownership and privacy behavior

- Apple's Messages database and attachments remain the source of truth for messages.
- The application stores only its own metadata, preferences, drafts, event cursors and optional normalized cache.
- The user can delete all app-owned data without affecting Messages.app.
- Logs must redact message bodies, recipient handles, attachment paths, authentication values and notification payloads by default.
- Analytics are off by default. If ever added, analytics must be opt-in and must never include message content or stable contact identifiers.
- Future remote push should default to opaque event notifications that cause an authenticated fetch; do not include message text in third-party push payloads unless the user explicitly chooses it.

## 11. Reliability and performance requirements

- Cold launch to visible recent conversation list: target under 1.5 seconds on a contemporary Apple Silicon Mac after the first index/load.
- Selecting a recent conversation: target visible content under 200 ms when cached or under 500 ms for a normal local query.
- Scrolling should remain responsive with conversations containing tens of thousands of messages.
- Database reads must be cancellable and never run synchronously on the main actor.
- Live-event processing must be idempotent.
- Sending must not automatically retry after an uncertain result unless the provider can prove idempotency.
- An app restart should resume from a durable event cursor and reconcile a bounded history window.
- All destructive local actions require clear scope language: “Remove local tag” must never look like “Delete conversation.”

## 12. Success measures

For the personal alpha:

- The app can replace Messages.app for routine reading and basic sending for one week.
- No duplicate outbound messages attributable to the app.
- No missed live events after recovery reconciliation in normal use.
- Permission failures are understandable without consulting Terminal.
- Global search is faster to operate than Messages.app for common queries.
- At least 90% of navigation, reading and sending workflows are possible without a mouse.

For a broader beta:

- Crash-free sessions above 99.5%.
- Median cold launch and chat-open targets are met.
- No confirmed mutation or corruption of Apple's database.
- Notification deduplication exceeds 99.9% in automated replay tests.

## 13. Roadmap

### Phase 0 — technical feasibility spike

- Prove read-only access to a copied fixture database.
- Prove access to the live database with clear permission detection.
- Evaluate `IMsgCore`'s public library API.
- Prove send and live watch through the least-privileged provider route.
- Document dependency pinning and macOS-version behavior.

### Phase 1 — local reader and sender MVP

- Native shell, onboarding and health dashboard.
- Conversation list, message timeline and pagination.
- Text/attachment sending with uncertain-outcome handling.
- Live updates and reconciliation.
- Contacts resolution.
- Global search.
- Local notifications.
- Pins and drafts.

### Phase 2 — power-user organization

- Tags, folders, snooze and tabs.
- Attachment browser.
- Search filters and saved views.
- Rich notification rules and quiet hours.
- Performance tuning and accessibility audit.

### Phase 3 — notification intelligence

- Durable notification event inbox.
- Burst coalescing.
- Scheduled and rule-based digests.
- Custom digest UI and notification actions.
- Optional on-device summarization only after a separate privacy/design review.

### Phase 4 — optional remote relay and push

- BlueBubbles REST/webhook provider spike.
- Secure relay connectivity and Keychain credentials.
- APNs and/or UnifiedPush delivery adapter.
- Remote event fetch, cursor recovery and deduplication.
- Explicit network threat model and operational health UI.

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Apple changes `chat.db` schema | Reads fail or fields become incorrect | Repository owns schema adapters, fixture tests cover multiple macOS versions, fail closed on unknown critical schema. |
| Automation changes across macOS releases | Sending or advanced actions fail | Capability probes, provider isolation, no silent fallback to risky private APIs. |
| Permission UX is confusing | User sees an empty or broken app | Dedicated health model, actionable onboarding and recheck on activation. |
| Duplicate sends after timeout | Socially damaging | Client operation IDs, send-once policy and explicit uncertain state. |
| Live watcher misses events | Missed notifications/UI updates | Durable cursor plus bounded database reconciliation on launch/wake/reconnect. |
| Loading huge chats causes UI stalls | App becomes unusable | Pagination, background actors, cancellation, lazy rendering and instrumentation. |
| BlueBubbles relay exposed publicly | Message/credential compromise | Deferred threat model, TLS, private network preferred, Keychain secrets, redacted URLs and least-content push payloads. |
| Third-party library becomes unmaintained | Build or runtime breakage | Provider boundary, pinned versions, conformance tests and CLI fallback. |

## 15. Open product questions

These do not block the feasibility spike:

- Shipping name and icon.
- Whether conversation tabs are a first-class default or an optional mode.
- Whether local folders behave like labels or mutually exclusive mailboxes.
- Whether the app should mirror Messages.app unread state when safe, or maintain a separate local read state.
- Whether on-device AI summaries are desirable for digests; this requires an explicit privacy decision.
- Which remote clients, if any, justify BlueBubbles relay work.
- Whether future push uses APNs, UnifiedPush or both.

## 16. MVP release gate

Phase 1 is releasable to the owner only when:

- SIP remains enabled throughout development and use.
- `chat.db` is opened read-only and no code path writes to it.
- Text and attachment sends are covered by end-to-end manual tests.
- Duplicate-send recovery behavior has been exercised.
- Permission-denied, Messages-signed-out and missing-attachment states have UI.
- Live watch survives sleep/wake and app relaunch reconciliation.
- Logs contain no message content under the default configuration.
- A clean uninstall/data-reset path removes only app-owned data.
