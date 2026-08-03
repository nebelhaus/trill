import Foundation
@testable import Trill

/// Contract fixtures for the Beeper Desktop API v1.
///
/// **Real shapes, invented content.** These were hand-written from the field
/// definitions the official `@beeper/desktop-api` SDK generates from the
/// Server's OpenAPI document — never from a capture of a real Server. No real
/// name, handle, phone number, message body, avatar or `mxc://` URL appears
/// here, and none may be added (`docs/security.md`). A raw capture must never be
/// committed; when a shape needs updating, hand-write the change.
enum BeeperFixtures {
    static let accountsJSON = """
    [
      {
        "accountID": "local-whatsappaaa",
        "bridge": { "id": "local-whatsapp", "provider": "local", "type": "whatsapp" },
        "network": "WhatsApp",
        "user": { "id": "@wa_0000:example.invalid", "fullName": "Fixture Self", "isSelf": true }
      },
      {
        "accountID": "slackgo.T000-U111",
        "bridge": { "id": "slackgo", "provider": "cloud", "type": "slackgo" },
        "network": "Slack",
        "user": { "id": "@slack_u111:example.invalid", "isSelf": true }
      },
      {
        "accountID": "slackgo.T000-U222",
        "bridge": { "id": "slackgo", "provider": "cloud", "type": "slackgo" },
        "network": "Slack",
        "user": { "id": "@slack_u222:example.invalid", "isSelf": true }
      },
      {
        "accountID": "local-imessage",
        "bridge": { "id": "local-imessage", "provider": "local", "type": "imessage" },
        "network": "iMessage",
        "user": { "id": "@im_0000:example.invalid", "isSelf": true }
      }
    ]
    """

    /// A `chats.list` page: one direct chat carrying a preview, one group.
    static let chatsPageJSON = """
    {
      "items": [
        {
          "id": "!fixtureDirect:example.invalid",
          "accountID": "local-whatsappaaa",
          "network": "WhatsApp",
          "title": "Fixture Contact",
          "type": "single",
          "unreadCount": 2,
          "lastActivity": "2026-02-01T10:15:00.000Z",
          "isArchived": false,
          "isMuted": false,
          "localChatID": "installation-local-1",
          "participants": {
            "hasMore": false,
            "total": 1,
            "items": [
              {
                "id": "@wa_1111:example.invalid",
                "fullName": "Fixture Contact",
                "phoneNumber": "+15550000000"
              }
            ]
          },
          "capabilities": { "edit": 2, "reaction": 2, "reply": 2, "readReceipts": true },
          "preview": {
            "id": "msg-preview-1",
            "accountID": "local-whatsappaaa",
            "chatID": "!fixtureDirect:example.invalid",
            "senderID": "@wa_1111:example.invalid",
            "sortKey": "0000000200",
            "timestamp": "2026-02-01T10:15:00.000Z",
            "text": "<p>Second fixture line</p>",
            "type": "TEXT",
            "isSender": false
          }
        },
        {
          "id": "!fixtureGroup:example.invalid",
          "accountID": "slackgo.T000-U111",
          "network": "Slack",
          "title": "Fixture Channel",
          "type": "group",
          "unreadCount": 0,
          "lastActivity": "2026-02-01T09:00:00Z",
          "participants": { "hasMore": true, "total": 12, "items": [] }
        },
        {
          "id": "!fixtureIMessage:example.invalid",
          "accountID": "local-imessage",
          "network": "iMessage",
          "title": "Should Never Appear",
          "type": "single",
          "unreadCount": 9,
          "lastActivity": "2026-02-01T11:00:00Z",
          "participants": { "hasMore": false, "total": 1, "items": [] }
        }
      ],
      "hasMore": true,
      "oldestCursor": "cursor-older",
      "newestCursor": "cursor-newer"
    }
    """

    /// A messages page exercising every shape the mapper has to survive: HTML
    /// text, a reply, a reaction-as-message, a NOTICE, a deleted row, a hidden
    /// row, an attachment, a send status, and a read receipt.
    static let messagesPageJSON = """
    {
      "items": [
        {
          "id": "msg-1",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "senderName": "Fixture Contact",
          "sortKey": "0000000100",
          "timestamp": "2026-02-01T10:00:00.000Z",
          "text": "<p>Hello &amp; welcome</p><p>Second paragraph</p>",
          "type": "TEXT",
          "isSender": false
        },
        {
          "id": "msg-2",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_0000:example.invalid",
          "sortKey": "0000000200",
          "timestamp": "2026-02-01T10:05:00.000Z",
          "text": "<blockquote>quoted</blockquote>Reply body",
          "type": "TEXT",
          "isSender": true,
          "linkedMessageID": "msg-1",
          "editedTimestamp": "2026-02-01T10:06:00.000Z",
          "seen": "2026-02-01T10:07:00.000Z",
          "sendStatus": {
            "status": "SUCCESS",
            "timestamp": "2026-02-01T10:05:01.000Z",
            "deliveredToUsers": ["@wa_1111:example.invalid"]
          },
          "reactions": [
            { "id": "@wa_1111:example.invalid", "participantID": "@wa_1111:example.invalid", "reactionKey": "🎉", "emoji": true },
            { "id": "r2", "participantID": "@wa_1111:example.invalid", "reactionKey": "smiling-face", "emoji": false }
          ]
        },
        {
          "id": "msg-3",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "sortKey": "0000000300",
          "timestamp": "2026-02-01T10:10:00.000Z",
          "type": "IMAGE",
          "attachments": [
            {
              "type": "img",
              "id": "mxc://example.invalid/fixtureAsset",
              "srcURL": "file:///not/ours/tmp/fixture.jpg",
              "mimeType": "image/jpeg",
              "fileName": "fixture.jpg",
              "fileSize": 2048,
              "size": { "width": 100, "height": 80 }
            }
          ]
        },
        {
          "id": "msg-reaction",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "sortKey": "0000000400",
          "timestamp": "2026-02-01T10:11:00.000Z",
          "type": "REACTION",
          "text": "<p>👍</p>"
        },
        {
          "id": "msg-notice",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "sortKey": "0000000500",
          "timestamp": "2026-02-01T10:12:00.000Z",
          "type": "NOTICE",
          "text": "<p>joined the chat</p>"
        },
        {
          "id": "msg-deleted",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "sortKey": "0000000600",
          "timestamp": "2026-02-01T10:13:00.000Z",
          "type": "TEXT",
          "text": "<p>gone</p>",
          "isDeleted": true
        },
        {
          "id": "msg-hidden",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_1111:example.invalid",
          "sortKey": "0000000700",
          "timestamp": "2026-02-01T10:14:00.000Z",
          "type": "TEXT",
          "text": "<p>invisible</p>",
          "isHidden": true
        },
        {
          "id": "msg-failed",
          "accountID": "local-whatsappaaa",
          "chatID": "!fixtureDirect:example.invalid",
          "senderID": "@wa_0000:example.invalid",
          "sortKey": "0000000800",
          "timestamp": "2026-02-01T10:16:00.000Z",
          "type": "TEXT",
          "text": "did not send",
          "isSender": true,
          "sendStatus": { "status": "FAIL_PERMANENT", "timestamp": "2026-02-01T10:16:01Z" }
        }
      ],
      "hasMore": false,
      "oldestCursor": null,
      "newestCursor": "0000000800"
    }
    """

    static let infoJSON = """
    {
      "app": { "name": "Beeper Desktop", "version": "0.0.0-fixture", "bundle_id": "com.example.invalid" },
      "endpoints": {
        "mcp": "http://127.0.0.1:23373/v0/mcp",
        "spec": "http://127.0.0.1:23373/v1/openapi.json",
        "ws_events": "ws://127.0.0.1:23373/v1/ws",
        "oauth": {
          "authorization_endpoint": "http://127.0.0.1:23373/oauth/authorize",
          "introspection_endpoint": "http://127.0.0.1:23373/oauth/introspect",
          "registration_endpoint": "http://127.0.0.1:23373/oauth/register",
          "revocation_endpoint": "http://127.0.0.1:23373/oauth/revoke",
          "token_endpoint": "http://127.0.0.1:23373/oauth/token",
          "userinfo_endpoint": "http://127.0.0.1:23373/oauth/userinfo"
        }
      },
      "platform": { "arch": "arm64", "os": "darwin" },
      "server": {
        "base_url": "http://127.0.0.1:23373",
        "hostname": "127.0.0.1",
        "mcp_enabled": true,
        "port": 23373,
        "remote_access": false,
        "status": "running"
      }
    }
    """

    static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
