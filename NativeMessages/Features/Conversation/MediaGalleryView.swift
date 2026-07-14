import AppKit
import QuickLook
import SwiftUI

/// Sheet showing every image/video in the conversation, newest first.
/// Clicking previews with Quick Look; the context menu jumps back to the
/// message the item arrived with.
struct MediaGalleryView: View {
    @ObservedObject var model: ConversationModel
    let onReveal: (MessageID) -> Void
    let onClose: () -> Void

    @State private var items: [MediaItem]?
    @State private var quickLookURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()
            content
        }
        .frame(width: 560, height: 460)
        .background(Rice.mantle)
        .task { items = await model.loadMedia() }
    }

    private var header: some View {
        HStack {
            Text("Media — \(model.conversation?.displayName ?? "Conversation")")
                .riceSectionHeader()
            Spacer()
            if let items, !items.isEmpty {
                Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }
            Button("Done", action: onClose)
                .buttonStyle(RiceSubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let items {
            if items.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Media",
                    message: "This conversation has no photos or videos."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(items) { item in
                            MediaTile(item: item) {
                                if let url = item.attachment.localURL {
                                    quickLookURL = url
                                }
                            }
                            .contextMenu {
                                Button("Show in Conversation") { onReveal(item.messageID) }
                                if let url = item.attachment.localURL {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .quickLookPreview($quickLookURL, in: items.compactMap(\.attachment.localURL))
            }
        } else {
            LoadingStateView(label: "Loading media…")
        }
    }
}

private struct MediaTile: View {
    let item: MediaItem
    let action: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rice.crust.opacity(0.6)
                    VStack(spacing: 5) {
                        Image(systemName: iconName)
                            .riceFont(18)
                            .foregroundStyle(Rice.overlay1)
                        if item.attachment.availability != .available {
                            Text("Unavailable")
                                .riceFont(8)
                                .foregroundStyle(Rice.overlay0)
                        }
                    }
                }
            }
            .frame(minWidth: 108, minHeight: 108)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: item.attachment.localURL) {
            guard item.attachment.isImage, let url = item.attachment.localURL else { return }
            thumbnail = await ThumbnailLoader.load(url, maxPixel: 320)
        }
        .help("\(item.attachment.displayName) — \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityLabel("Media item \(item.attachment.displayName)")
    }

    private var iconName: String {
        if item.attachment.isImage { return "photo" }
        return "video"
    }
}
