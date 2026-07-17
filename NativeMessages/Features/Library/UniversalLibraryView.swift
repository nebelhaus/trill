import AppKit
import QuickLook
import SwiftUI

/// The Universal Library (⌘⇧L): one browser for every image, link, and file
/// across *all* conversations. Generalizes the per-conversation media gallery
/// via the all-chats `libraryItems` query, with type tabs and jump-to-source.
/// Presented as a centered overlay panel, mirroring the command palette / search.
struct UniversalLibraryView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.riceAccent) private var accent

    @State private var kind: LibraryKind = .image
    /// Loaded lazily per tab and cached so switching tabs is instant after the
    /// first visit. `nil` for a kind means "not loaded yet" → show the spinner.
    @State private var itemsByKind: [LibraryKind: [LibraryItem]] = [:]
    @State private var quickLookURL: URL?

    private var items: [LibraryItem]? { itemsByKind[kind] }

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 6)]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            panel
                .frame(width: 760, height: 580)
                .padding(.top, 64)
        }
        .transition(.opacity)
        .onExitCommand(perform: dismiss)
        .task(id: kind) { await loadIfNeeded(kind) }
    }

    private func dismiss() { model.isLibraryPresented = false }

    private func loadIfNeeded(_ kind: LibraryKind) async {
        guard itemsByKind[kind] == nil else { return }
        itemsByKind[kind] = await model.loadLibrary(kind: kind)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            tabBar
            RiceDivider()
            content
        }
        .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Rice.surface1, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("Library")
                .riceSectionHeader()
            Spacer()
            if let items, !items.isEmpty {
                Text("\(items.count) \(kind.title.lowercased())")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }
            Button("Done", action: dismiss)
                .buttonStyle(RiceSubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(LibraryKind.allCases) { tab in
                tabChip(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func tabChip(_ tab: LibraryKind) -> some View {
        let isSelected = kind == tab
        return Button {
            kind = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .riceFont(10)
                Text(tab.title)
                    .riceFont(11, .medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? accent : Rice.surface0.opacity(0.45),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Rice.crust : Rice.subtext1)
        }
        .buttonStyle(.plain)
        .help("Show \(tab.title.lowercased())")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let items {
            if items.isEmpty {
                EmptyStateView(icon: kind.systemImage, title: "No \(kind.title)", message: emptyMessage)
            } else {
                switch kind {
                case .image: imageGrid(items)
                case .link: linkList(items)
                case .file: fileList(items)
                case .saved: savedList(items)
                }
            }
        } else {
            LoadingStateView(label: "Loading \(kind.title.lowercased())…")
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .image: "No photos or videos across your conversations yet."
        case .link: "No links have been shared in your conversations yet."
        case .file: "No files have been shared in your conversations yet."
        case .saved: "Bookmark a message from its right-click menu to keep it here."
        }
    }

    private func imageGrid(_ items: [LibraryItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { item in
                    LibraryImageTile(item: item) {
                        if let url = item.attachment?.localURL { quickLookURL = url }
                    }
                    .contextMenu { itemMenu(item) }
                }
            }
            .padding(12)
        }
        .quickLookPreview($quickLookURL, in: items.compactMap { $0.attachment?.localURL })
    }

    private func linkList(_ items: [LibraryItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    LibraryLinkRow(
                        item: item,
                        conversationName: model.conversationName(for: item.conversationID),
                        loader: model.linkPreviewLoader
                    ) {
                        if let url = item.url { NSWorkspace.shared.open(url) }
                    }
                    .contextMenu { itemMenu(item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func fileList(_ items: [LibraryItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    LibraryFileRow(item: item, conversationName: model.conversationName(for: item.conversationID)) {
                        if let url = item.attachment?.localURL { quickLookURL = url }
                    }
                    .contextMenu { itemMenu(item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .quickLookPreview($quickLookURL, in: items.compactMap { $0.attachment?.localURL })
    }

    private func savedList(_ items: [LibraryItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    LibrarySavedRow(item: item, conversationName: model.conversationName(for: item.conversationID)) {
                        model.openLibraryItem(item)
                    }
                    .contextMenu { itemMenu(item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// Drops a just-unsaved bookmark from the loaded Saved tab so the row
    /// disappears immediately, without a full reload.
    private func removeSaved(_ item: LibraryItem) {
        model.toggleSaved(item.messageID)
        itemsByKind[.saved]?.removeAll { $0.messageID == item.messageID }
    }

    @ViewBuilder
    private func itemMenu(_ item: LibraryItem) -> some View {
        Button("Show in Conversation") { model.openLibraryItem(item) }
        if item.kind == .saved {
            if !(item.messageText ?? "").isEmpty {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.messageText ?? "", forType: .string)
                }
            }
            Button("Remove from Saved") { removeSaved(item) }
        }
        if let url = item.url {
            Button("Open Link") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if let fileURL = item.attachment?.localURL {
            Button("Open") { NSWorkspace.shared.open(fileURL) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }
}

// MARK: - Rows & tiles

private struct LibraryImageTile: View {
    let item: LibraryItem
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
                    Image(systemName: isVideo ? "video" : "photo")
                        .riceFont(18)
                        .foregroundStyle(Rice.overlay1)
                }
            }
            .frame(minWidth: 108, minHeight: 108)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: item.attachment?.localURL) {
            guard let attachment = item.attachment, attachment.isImage,
                  let url = attachment.localURL else { return }
            thumbnail = await ThumbnailLoader.load(url, maxPixel: 320)
        }
        .help(helpText)
        .accessibilityLabel("Image \(item.attachment?.displayName ?? "")")
    }

    private var isVideo: Bool {
        guard let attachment = item.attachment else { return false }
        return !attachment.isImage
    }

    private var helpText: String {
        let name = item.attachment?.displayName ?? "Media"
        return "\(name) — \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct LibraryLinkRow: View {
    let item: LibraryItem
    let conversationName: String?
    let loader: LinkPreviewLoader
    let action: () -> Void

    @AppStorage("linkPreviews") private var linkPreviews = false
    @State private var isHovering = false
    @State private var preview: LinkPreview?
    @State private var thumbnail: NSImage?

    /// A non-empty OG preview to render — only when previews are enabled *and*
    /// the fetch turned up at least a title, summary, or image.
    private var richPreview: LinkPreview? {
        guard linkPreviews, let preview, !preview.isEmpty else { return nil }
        return preview
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let richPreview {
                    richContent(richPreview)
                } else {
                    plainContent
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, richPreview == nil ? 7 : 9)
            .background(isHovering ? Rice.surface0.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.url?.absoluteString ?? "")
        .task(id: previewTaskID) { await loadPreview() }
    }

    // MARK: - Layouts

    private var plainContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .riceFont(12)
                .foregroundStyle(Rice.overlay1)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayURL)
                    .riceFont(12, .medium)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                Text(subtitle)
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.square")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
                .opacity(isHovering ? 1 : 0)
        }
    }

    private func richContent(_ preview: LinkPreview) -> some View {
        HStack(spacing: 11) {
            thumbnailView
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.title ?? displayURL)
                    .riceFont(12, .semibold)
                    .foregroundStyle(Rice.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let summary = preview.summary {
                    Text(summary)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext1)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .riceFont(8)
                    Text(footer(preview))
                        .lineLimit(1)
                }
                .riceFont(10)
                .foregroundStyle(Rice.subtext0)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.square")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
                .opacity(isHovering ? 1 : 0)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rice.crust.opacity(0.6)
                Image(systemName: "link")
                    .riceFont(14)
                    .foregroundStyle(Rice.overlay1)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Loading

    /// Re-run the fetch when the URL changes or previews get toggled on.
    private var previewTaskID: String {
        "\(linkPreviews)|\(item.url?.absoluteString ?? "")"
    }

    private func loadPreview() async {
        guard linkPreviews, let url = item.url else { return }
        let fetched = await loader.load(url)
        preview = fetched
        if let imageURL = fetched.imageURL {
            thumbnail = await RemoteImageLoader.load(imageURL)
        }
    }

    private func footer(_ preview: LinkPreview) -> String {
        let host = preview.siteName ?? item.url?.host()?.replacingOccurrences(of: "www.", with: "")
        if let host { return "\(host) · \(subtitle)" }
        return subtitle
    }

    private var displayURL: String {
        guard let url = item.url else { return item.messageText ?? "Link" }
        guard let host = url.host()?.replacingOccurrences(of: "www.", with: "") else {
            return url.absoluteString
        }
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }

    private var subtitle: String {
        let date = item.createdAt.formatted(date: .abbreviated, time: .omitted)
        if let conversationName { return "\(conversationName) · \(date)" }
        return date
    }
}

private struct LibraryFileRow: View {
    let item: LibraryItem
    let conversationName: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .riceFont(13)
                    .foregroundStyle(Rice.overlay1)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.attachment?.displayName ?? "File")
                        .riceFont(12, .medium)
                        .foregroundStyle(Rice.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if item.attachment?.availability != .available {
                    Text("Unavailable")
                        .riceFont(9)
                        .foregroundStyle(Rice.overlay0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovering ? Rice.surface0.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.attachment?.displayName ?? "File")
    }

    private var iconName: String {
        let uti = item.attachment?.uniformTypeIdentifier ?? ""
        let mime = item.attachment?.mimeType ?? ""
        if uti.contains("pdf") || mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if uti.contains("zip") || uti.contains("archive") { return "doc.zipper" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let conversationName { parts.append(conversationName) }
        if let bytes = item.attachment?.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

/// A bookmarked message in the Saved tab: sender + body preview, with the source
/// thread and date beneath. Tapping jumps back to the message in its thread.
private struct LibrarySavedRow: View {
    let item: LibraryItem
    let conversationName: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .riceFont(11)
                    .foregroundStyle(Rice.overlay1)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sender)
                        .riceFont(11, .semibold)
                        .foregroundStyle(Rice.subtext1)
                        .lineLimit(1)
                    Text(messageBody)
                        .riceFont(12)
                        .foregroundStyle(Rice.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.square")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovering ? Rice.surface0.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show in conversation")
    }

    private var sender: String { item.senderName ?? "You" }

    /// The message body, or a stand-in when a bookmarked message is attachment-only.
    private var messageBody: String {
        if let text = item.messageText, !text.isEmpty { return text }
        if let name = item.attachment?.displayName { return name }
        return "Attachment"
    }

    private var subtitle: String {
        let date = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let conversationName { return "\(conversationName) · \(date)" }
        return date
    }
}
