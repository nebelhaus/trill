import Foundation

// Beeper Desktop API v1 wire types. `internal` to this folder by construction:
// nothing outside `Providers/Beeper/` may reference them (ARCHITECTURE.md §20).
// Mirrors the shapes the official `@beeper/desktop-api` TypeScript SDK (5.0.0)
// generates from the same OpenAPI document the Server serves at
// `endpoints.spec`. Note "v5" is the *SDK package* version; the URL paths are
// `/v1`.
//
// Every field the API marks optional is optional here. Decoding is deliberately
// tolerant: an unknown enum case degrades to a known-safe value rather than
// failing the page, because a Server newer than us must not blank the inbox.

/// `{items, hasMore, oldestCursor, newestCursor}` — uniform across every list
/// and search endpoint.
struct BeeperPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let hasMore: Bool
    let oldestCursor: String?
    let newestCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items, hasMore, oldestCursor, newestCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        oldestCursor = try container.decodeIfPresent(String.self, forKey: .oldestCursor)
        newestCursor = try container.decodeIfPresent(String.self, forKey: .newestCursor)
    }

    init(items: [Item], hasMore: Bool, oldestCursor: String?, newestCursor: String?) {
        self.items = items
        self.hasMore = hasMore
        self.oldestCursor = oldestCursor
        self.newestCursor = newestCursor
    }
}

struct BeeperUser: Decodable, Sendable {
    let id: String
    let fullName: String?
    let username: String?
    let phoneNumber: String?
    let email: String?
    let imgURL: String?
    let isSelf: Bool?
    let cannotMessage: Bool?
}

struct BeeperAccount: Decodable, Sendable {
    struct Bridge: Decodable, Sendable {
        let id: String
        /// `cloud` | `self-hosted` | `local` | `platform-sdk`. Kept as a string:
        /// an unknown provider is not a decoding failure.
        let provider: String?
        /// `whatsapp`, `telegram`, `slackgo`, … — the stable network key.
        let type: String
    }

    let accountID: String
    let bridge: Bridge
    let user: BeeperUser?
    /// Human-friendly network name; omitted when the network is unknown.
    let network: String?
}

struct BeeperParticipants: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String
        let fullName: String?
        let username: String?
        let phoneNumber: String?
        let email: String?
        let imgURL: String?
        let isSelf: Bool?
        let isAdmin: Bool?
        let isNetworkBot: Bool?
        let isPending: Bool?
    }

    let items: [Item]
    let total: Int?
    let hasMore: Bool?
}

struct BeeperChat: Decodable, Sendable {
    /// Per-chat capabilities. Beeper reports these per *chat*, not per account —
    /// which is why `MessagesProvider.capabilities(for:)` exists.
    struct Capabilities: Decodable, Sendable {
        /// `-2` rejected, `-1` dropped, `0` unsupported, `1` partial, `2` full.
        let edit: Int?
        let reaction: Int?
        let reply: Int?
        let delete: Int?
        let readReceipts: Bool?
        let markAsUnread: Bool?
        let archive: Bool?
        let customEmojiReactions: Bool?
        let allowedReactions: [String]?
        let maxTextLength: Int?
    }

    let id: String
    let accountID: String
    let network: String?
    let title: String?
    /// `single` | `group`.
    let type: String?
    let unreadCount: Int?
    let participants: BeeperParticipants?
    let lastActivity: String?
    let isArchived: Bool?
    let isMuted: Bool?
    let isPinned: Bool?
    let isReadOnly: Bool?
    let isMarkedUnread: Bool?
    let unreadMentionsCount: Int?
    let lastReadMessageSortKey: String?
    let imgURL: String?
    let description: String?
    let capabilities: Capabilities?
    /// **Never** used as an identifier — it is specific to one Beeper Desktop
    /// installation. See `BeeperMapper`.
    let localChatID: String?
    /// Present on `chats.list` only: the chat's most recent message.
    let preview: BeeperMessage?
}

struct BeeperAttachment: Decodable, Sendable {
    struct Size: Decodable, Sendable {
        let width: Int?
        let height: Int?
    }

    /// `unknown` | `img` | `video` | `audio`.
    let type: String?
    /// Typically an `mxc://` URL — the durable handle. `srcURL` is not.
    let id: String?
    let srcURL: String?
    let mimeType: String?
    let fileName: String?
    let fileSize: Int64?
    let size: Size?
    let isGif: Bool?
    let isSticker: Bool?
    let isVoiceNote: Bool?
    let posterImg: String?
    let duration: Double?
}

struct BeeperReaction: Decodable, Sendable {
    let id: String
    let participantID: String?
    /// An emoji, a network-specific key, or a shortcode like `smiling-face`.
    let reactionKey: String
    let emoji: Bool?
    let imgURL: String?
}

struct BeeperSendStatus: Decodable, Sendable {
    /// `SUCCESS` | `PENDING` | `FAIL_RETRIABLE` | `FAIL_PERMANENT`.
    let status: String?
    let timestamp: String?
    let deliveredToUsers: [String]?
    let reason: String?
    let message: String?
}

/// `seen` is `bool | string | map<string, bool|string>`. Modelled explicitly so
/// the one shape that carries a *timestamp* can reach `Message.readAt` and the
/// others degrade quietly.
enum BeeperSeen: Decodable, Sendable {
    case flag(Bool)
    case timestamp(String)
    case perUser([String: String])
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let stamp = try? container.decode(String.self) {
            self = .timestamp(stamp)
        } else if let map = try? container.decode([String: String].self) {
            self = .perUser(map)
        } else {
            self = .unknown
        }
    }
}

struct BeeperMessage: Decodable, Sendable {
    let id: String
    let accountID: String?
    let chatID: String?
    let senderID: String?
    /// **The** sort key — this is the cursor/sequence, not `timestamp`.
    let sortKey: String?
    let timestamp: String?
    /// Matrix **HTML**, not plain text.
    let text: String?
    /// `TEXT` | `NOTICE` | `IMAGE` | … | `REACTION`.
    let type: String?
    let senderName: String?
    let isSender: Bool?
    let isUnread: Bool?
    let isDeleted: Bool?
    let isHidden: Bool?
    let editedTimestamp: String?
    /// The message this replies to.
    let linkedMessageID: String?
    let attachments: [BeeperAttachment]?
    let reactions: [BeeperReaction]?
    let seen: BeeperSeen?
    let sendStatus: BeeperSendStatus?
}

struct BeeperInfo: Decodable, Sendable {
    struct App: Decodable, Sendable {
        let name: String?
        let version: String?
        let bundle_id: String?
    }

    struct Endpoints: Decodable, Sendable {
        let spec: String?
        let ws_events: String?
    }

    struct Server: Decodable, Sendable {
        let base_url: String?
        let port: Int?
        let status: String?
        let remote_access: Bool?
    }

    let app: App?
    let endpoints: Endpoints?
    let server: Server?
}

struct BeeperAssetDownload: Decodable, Sendable {
    /// Local file URL **on the machine running Beeper** — never handed to the
    /// domain model as `localURL`. See `BeeperAssetCache`.
    let srcURL: String?
    let error: String?
}
