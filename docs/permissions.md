# trill permissions

Trill asks for as little as it can, and degrades honestly when it doesn't get it.

| permission | required? | what it buys |
|---|---|---|
| **Full Disk Access** | yes | reading `~/Library/Messages/chat.db`. Grant it to the built app bundle — *not* Terminal — in System Settings → Privacy & Security. |
| **Automation ("control Messages")** | for sending | prompted on first send. Trill drives Messages.app over Apple Events; Messages.app does the actual sending. |
| **Contacts** | optional | names *and* contact photos via the Contacts framework. Without it, names still resolve by reading the local AddressBook store directly (covered by Full Disk Access) — only photos are missing. |
| **Notifications** | optional | prompted on first launch with the live provider. Banners for incoming messages, with inline reply. |

Trill never asks for Accessibility, Input Monitoring, or Screen Recording.

## What Trill cannot do

**Mark conversations as read upstream.** That would require writing to
`chat.db`, which Trill never does. Opening a thread clears its badge locally, and
the mark persists in Trill's own database — so your unread state in Trill is
independent of Messages.app.

**Send tapbacks or threaded replies.** Messages.app exposes no automation surface
for either. Trill displays both — tapbacks grouped by emoji with counts and
own-reaction tinting, quoted reply bubbles with jump-to-original — but the
composer cannot originate them.

## Fixture mode

Synthetic Fixture mode needs no permissions at all: no Full Disk Access, no
Contacts, no Automation, no signed-in Messages account. It's the mode the app
opens in by default from a fresh Xcode build.

## SIP

System Integrity Protection must stay **enabled**. Nothing in Trill requires
disabling it, and nothing about the project ever will.
