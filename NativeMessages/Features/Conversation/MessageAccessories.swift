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
        case .downloadRequired: return "Download required"
        }
    }
}

/// Message text with URLs made clickable, tinted with the rice accent.
struct RichMessageText: View {
    let text: String
    @Environment(\.riceAccent) private var accent

    var body: some View {
        Text(attributed)
            .tint(accent)
            .foregroundStyle(Rice.text)
            .textSelection(.enabled)
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
