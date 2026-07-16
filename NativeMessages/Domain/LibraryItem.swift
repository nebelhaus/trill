import Foundation

/// One artifact in the Universal Library: a single image/video, link, or file
/// pulled from *any* conversation, carrying enough context to jump back to the
/// message it arrived with. Generalizes `MediaItem` — which is per-conversation
/// and images-only — across every chat and content kind.
struct LibraryItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: LibraryKind
    let messageID: MessageID
    let conversationID: ConversationID
    let createdAt: Date
    /// Set for `.image` and `.file` items; nil for links.
    let attachment: MessageAttachment?
    /// Set for `.link` items; nil otherwise.
    let url: URL?
    /// The message text a link was found in, for context. Nil for attachments.
    let messageText: String?
}

/// The Universal Library's type tabs. `image` covers photos *and* videos (both
/// render as visual thumbnails); `file` is every other attachment (PDFs, docs,
/// archives, audio…); `link` is URLs detected in message text.
enum LibraryKind: String, CaseIterable, Identifiable, Sendable {
    case image
    case link
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Images"
        case .link: "Links"
        case .file: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        }
    }
}

/// Extracts URLs from message text with the same `NSDataDetector` link logic the
/// search `has:link` filter uses. Kept here so the provider and library view can
/// share one immutable detector without depending on the search subsystem.
enum LinkExtractor {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// URLs found in `text`, in appearance order. Empty when the text has none.
    static func urls(in text: String) -> [URL] {
        guard !text.isEmpty, let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }
}
