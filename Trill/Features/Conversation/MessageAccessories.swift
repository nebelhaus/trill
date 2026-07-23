import AppKit
import QuickLook
import SwiftUI

/// Downscaled attachment thumbnails via ImageIO, cached in-memory.
enum ThumbnailLoader {
    private struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    nonisolated(unsafe) private static let cache = NSCache<NSURL, NSImage>()

    static func load(_ url: URL, maxPixel: CGFloat = 640) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let box = await Task.detached(priority: .utility) { () -> ImageBox in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return ImageBox(image: nil)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return ImageBox(image: nil)
            }
            return ImageBox(image: NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            ))
        }.value
        if let image = box.image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return box.image
    }
}

/// Image attachments render as clickable thumbnails; other files as a
/// clickable row. Clicking opens an in-place Quick Look preview.
struct AttachmentView: View {
    let attachment: MessageAttachment
    @State private var thumbnail: NSImage?
    @State private var quickLookURL: URL?
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale

    var body: some View {
        if attachment.isImage, let url = attachment.localURL {
            Button {
                quickLookURL = url
            } label: {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ZStack {
                            Rice.crust.opacity(0.4)
                            ProgressView()
                                .controlSize(.small)
                        }
                        .frame(width: 200 * scale, height: 140 * scale)
                    }
                }
                .frame(maxWidth: 260 * scale, maxHeight: 260 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .task(id: url) {
                thumbnail = await ThumbnailLoader.load(url)
            }
            .quickLookPreview($quickLookURL)
            .contextMenu { fileActions(url) }
            .help(attachment.displayName)
            .accessibilityLabel("Image attachment \(attachment.displayName)")
        } else {
            fileRow
        }
    }

    @ViewBuilder
    private func fileActions(_ url: URL) -> some View {
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .riceFont(12)
                .foregroundStyle(accent)
                .frame(width: 20 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .riceFont(12, .medium)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                Text(status)
                    .riceFont(10)
                    .foregroundStyle(attachment.availability == .missing ? Rice.red : Rice.subtext0)
            }
        }
        .padding(7)
        .background(Rice.crust.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture {
            if let url = attachment.localURL {
                quickLookURL = url
            }
        }
        .quickLookPreview($quickLookURL)
        .contextMenu {
            if let url = attachment.localURL {
                fileActions(url)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch attachment.availability {
        case .available:
            if let byteCount = attachment.byteCount {
                return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            }
            return "Available"
        case .missing: return "Attachment unavailable"
        case .downloadRequired:
            if let byteCount = attachment.byteCount {
                let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                return "In iCloud · \(size) — open in Messages to download"
            }
            return "In iCloud — open in Messages to download"
        }
    }
}

/// Message text with URLs made clickable, tinted with the rice accent.
/// Reports the widest natural (unwrapped) line width of a measuring twin so the
/// selectable bubble text can hug its content instead of filling the row.
private struct RichTextIdealWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RichMessageText: View {
    let text: String
    @Environment(\.riceAccent) private var accent
    @State private var idealWidth: CGFloat = 0

    /// A bubble never grows wider than this; longer content wraps. On narrower
    /// windows the parent's own width wins, so this is only an upper bound.
    private let maxContentWidth: CGFloat = 560

    var body: some View {
        Text(attributed)
            .tint(accent)
            .foregroundStyle(Rice.text)
            .textSelection(.enabled)
            // A selectable *multi-line* Text greedily fills the whole row on
            // macOS, which is what leaves the big unclickable dead zone beside
            // short lines. Clamp it to the text's own natural width so the
            // bubble hugs its content — selection stays fully enabled.
            .frame(
                maxWidth: idealWidth > 0 ? min(idealWidth, maxContentWidth) : nil,
                alignment: .leading
            )
            .background(alignment: .topLeading) {
                // Hidden, non-wrapping twin: reports the widest line's width via
                // preference. `fixedSize` makes it ignore the (clamped) primary
                // width, so the measurement can't feed back on itself.
                Text(attributed)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: RichTextIdealWidthKey.self,
                                value: geo.size.width
                            )
                        }
                    )
            }
            .onPreferenceChange(RichTextIdealWidthKey.self) { idealWidth = $0 }
    }

    private var attributed: AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: mutable.length)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url else { continue }
                mutable.addAttributes([
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: match.range)
            }
        }
        return AttributedString(mutable)
    }
}

/// 16pt sender avatar for group timelines: photo or tinted initial.
struct SenderBadge: View {
    let participant: Participant
    @Environment(\.uiScale) private var scale

    var body: some View {
        Group {
            if let data = participant.avatarData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    seed.opacity(0.2)
                    Text(initial)
                        .riceFont(8, .semibold)
                        .foregroundStyle(seed)
                }
            }
        }
        .frame(width: 16 * scale, height: 16 * scale)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var seed: Color {
        Rice.accent(seededBy: participant.id)
    }

    private var initial: String {
        let name = participant.displayName ?? participant.handle
        return name.first(where: \.isLetter).map { String($0).uppercased() } ?? "#"
    }
}

/// A Messages-style Open Graph card rendered under a message that contains a link.
/// Gated on the `linkPreviews` setting and the injected loader; renders nothing
/// while loading, when disabled, or when the page exposed no usable metadata —
/// so a plain bubble is never displaced by an empty box.
struct InlineLinkPreview: View {
    let url: URL

    @AppStorage("linkPreviews") private var linkPreviews = false
    @Environment(\.linkPreviewLoader) private var loader
    @State private var preview: LinkPreview?
    @State private var image: NSImage?

    private static let maxWidth: CGFloat = 268

    var body: some View {
        // The empty state is a zero-size anchor, not nothing: SwiftUI won't run a
        // `.task` attached to a view whose content is conditionally empty, so the
        // fetch would never fire. The clear anchor keeps the task alive while the
        // preview is loading (or absent) without occupying layout space.
        Group {
            if linkPreviews, let preview, !preview.isEmpty {
                card(preview)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: taskID) { await load() }
    }

    private func card(_ preview: LinkPreview) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.maxWidth, height: 132)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = preview.title {
                        Text(title)
                            .riceFont(12, .semibold)
                            .foregroundStyle(Rice.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let summary = preview.summary {
                        Text(summary)
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext1)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(preview.siteName ?? url.host() ?? url.absoluteString)
                        .riceFont(9)
                        .foregroundStyle(Rice.overlay0)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: Self.maxWidth, alignment: .leading)
            }
            .background(Rice.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Rice.surface2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }

    private var taskID: String { "\(linkPreviews)|\(url.absoluteString)" }

    private func load() async {
        guard linkPreviews, let loader else { return }
        let fetched = await loader.load(url)
        preview = fetched
        if let imageURL = fetched.imageURL {
            image = await RemoteImageLoader.load(imageURL)
        }
    }
}
