import AppKit
import Foundation
import SwiftUI

/// Open Graph metadata for a link, as shown in the Universal Library's Links tab.
/// Every field is optional: a page may expose none of them, in which case the row
/// falls back to its plain host/subtitle form. `isEmpty` distinguishes "fetched,
/// nothing useful" from "not fetched yet" so we never refetch a barren page.
struct LinkPreview: Sendable, Hashable {
    var title: String?
    var summary: String?
    var imageURL: URL?
    var siteName: String?

    var isEmpty: Bool { title == nil && summary == nil && imageURL == nil }

    static let empty = LinkPreview(title: nil, summary: nil, imageURL: nil, siteName: nil)
}

/// Fetches and caches Open Graph previews for links. Networked and therefore
/// opt-in (the `linkPreviews` setting): each `load` reaches out to the link's host,
/// so it only runs when the Links tab is showing and previews are enabled.
///
/// Three cache tiers keep scrolling cheap and offline-friendly: an in-memory map
/// (instant on revisit), an `AppDatabase` table (survives relaunch, avoids the
/// network entirely once a URL is known), and per-URL in-flight coalescing so a
/// list that shows the same link twice fetches it once.
actor LinkPreviewLoader {
    private let database: AppDatabase
    private var memory: [URL: LinkPreview] = [:]
    private var inFlight: [URL: Task<LinkPreview, Never>] = [:]

    /// Only pages up to this size are scanned — OG tags live in `<head>`, so the
    /// first chunk is plenty and we avoid pulling multi-megabyte bodies.
    private static let maxBytes = 512 * 1024

    init(database: AppDatabase) {
        self.database = database
    }

    /// The preview for `url`, fetching over the network only when neither cache
    /// tier has it. Returns `.empty` (not nil) for pages with no usable metadata,
    /// so the row shows its plain form without the loader retrying every appearance.
    func load(_ url: URL) async -> LinkPreview {
        if let hit = memory[url] { return hit }
        if let task = inFlight[url] { return await task.value }

        let task = Task<LinkPreview, Never> { [database] in
            if let stored = try? await database.linkPreview(forURL: url.absoluteString) {
                return stored
            }
            let fetched = await Self.fetch(url)
            try? await database.saveLinkPreview(fetched, forURL: url.absoluteString)
            return fetched
        }
        inFlight[url] = task
        let preview = await task.value
        inFlight[url] = nil
        memory[url] = preview
        return preview
    }

    // MARK: - Network

    private static func fetch(_ url: URL) async -> LinkPreview {
        // Bare domains (`nebelhaus.com`) arrive as `http://` from NSDataDetector,
        // and App Transport Security blocks plain HTTP outright — before the host's
        // own http→https redirect can fire. Nearly every such site serves HTTPS, so
        // promote the scheme; the original URL is still what we open and cache under.
        var request = URLRequest(url: httpsPromoted(url), timeoutInterval: 10)
        // A browser-ish UA — some hosts return bare pages (or 403) to unknown agents.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.mimeType ?? "text/html").contains("html")
        else { return .empty }

        let slice = data.prefix(maxBytes)
        let html = String(data: slice, encoding: .utf8)
            ?? String(decoding: slice, as: UTF8.self)
        return parse(html: html, baseURL: response.url ?? url)
    }

    /// Pulls OG tags out of an HTML head, falling back to `<title>` and the
    /// standard `<meta name="description">` when the Open Graph ones are absent.
    /// Tolerant of attribute order and quote style; relative `og:image` URLs are
    /// resolved against the (post-redirect) page URL.
    static func parse(html: String, baseURL: URL) -> LinkPreview {
        var tags: [String: String] = [:]
        let range = NSRange(html.startIndex..., in: html)
        for match in Self.metaTag.matches(in: html, range: range) {
            guard let tagRange = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[tagRange])
            guard let key = attributeValue("property", in: attributes)
                    ?? attributeValue("name", in: attributes),
                  let content = attributeValue("content", in: attributes)
            else { continue }
            let normalized = key.lowercased()
            // First wins — pages sometimes repeat a property; the first is canonical.
            if tags[normalized] == nil { tags[normalized] = decodeEntities(content) }
        }

        let title = tags["og:title"] ?? htmlTitle(in: html)
        let summary = tags["og:description"] ?? tags["description"]
        let image = tags["og:image"] ?? tags["twitter:image"]
        let imageURL = image.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }

        return LinkPreview(
            title: title?.trimmed.nonEmpty,
            summary: summary?.trimmed.nonEmpty,
            imageURL: imageURL,
            siteName: (tags["og:site_name"]?.trimmed.nonEmpty) ?? baseURL.host()
        )
    }

    // MARK: - HTML scraping helpers

    private static let metaTag = try! NSRegularExpression(
        pattern: "<meta\\s+([^>]*?)/?>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let titleTag = try! NSRegularExpression(
        pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func attributeValue(_ name: String, in attributes: String) -> String? {
        // name="value" | name='value' | name=value
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
        else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: attributes) {
                return String(attributes[range])
            }
        }
        return nil
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let match = titleTag.firstMatch(
                in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return decodeEntities(String(html[range]))
    }

    /// Minimal HTML entity decode — enough for the named/numeric entities that
    /// show up in real titles and descriptions without pulling in a full parser.
    private static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var text = raw
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
                     "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                     "&ldquo;": "“", "&rdquo;": "”"]
        for (entity, character) in named {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

/// Networked image loader for OG preview thumbnails. Mirrors `ThumbnailLoader`'s
/// in-memory `NSCache`, but pulls bytes over HTTP instead of from disk.
enum RemoteImageLoader {
    private struct ImageBox: @unchecked Sendable { let image: NSImage? }

    nonisolated(unsafe) private static let cache = NSCache<NSURL, NSImage>()

    static func load(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let target = httpsPromoted(url)
        guard let (data, response) = try? await URLSession.shared.data(from: target),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        let box = ImageBox(image: NSImage(data: data))
        if let image = box.image { cache.setObject(image, forKey: url as NSURL) }
        return box.image
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Environment

private struct LinkPreviewLoaderKey: EnvironmentKey {
    static let defaultValue: LinkPreviewLoader? = nil
}

extension EnvironmentValues {
    /// The shared OG fetcher, injected once where the `InboxModel` is in scope so
    /// deeply-nested views (message rows) can render previews without plumbing.
    var linkPreviewLoader: LinkPreviewLoader? {
        get { self[LinkPreviewLoaderKey.self] }
        set { self[LinkPreviewLoaderKey.self] = newValue }
    }
}

/// Rewrites an `http://` URL to `https://` so App Transport Security doesn't reject
/// it. Leaves already-secure (or non-HTTP) URLs untouched.
private func httpsPromoted(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = "https"
    return components.url ?? url
}
