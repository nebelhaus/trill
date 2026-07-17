import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    /// Half the conversation pane, handed down so the box can't grow past 50% vh.
    var maxHeight: CGFloat = 320

    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale
    @AppStorage("sendOnReturn") private var sendOnReturn = true
    @State private var isDropTargeted = false
    @State private var measuredHeight: CGFloat = 0
    /// Measured height of the snippet popover, so it can be offset fully above
    /// the box regardless of how many rows it has.
    @State private var snippetPickerHeight: CGFloat = 0

    /// Floor used only until the first real measurement lands, kept below a
    /// true single line so it never forces the box taller than one row.
    private var minEditorHeight: CGFloat { 22 * scale }

    /// Never let the ceiling collapse below a few lines on a short window.
    private var ceiling: CGFloat { max(maxHeight, minEditorHeight * 3) }

    private var editorHeight: CGFloat {
        min(max(measuredHeight, minEditorHeight), ceiling)
    }

    /// Height of one text line, from the same font AppKit lays out with.
    private var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 13 * scale)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private var insetsHeight: CGFloat { GrowingTextView.insets.height * 2 }

    /// Diameter of the round send button, tied to a single text line so it never
    /// outgrows the editor and forces the one-line box taller than the text.
    private var controlDiameter: CGFloat { lineHeight + insetsHeight - 2 }

    /// Three or more lines: stack the controls on the right so the tall box
    /// keeps its full width. One or two lines: keep them inline.
    private var stacksControls: Bool {
        editorHeight > lineHeight * 2 + insetsHeight + 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Raised above the footnote so the floating snippet popover isn't
            // painted over by the sibling that follows it in the stack.
            box
                .zIndex(1)
            footnote
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Rice.base)
        .dropDestination(for: URL.self) { urls, _ in
            model.stageAttachments(urls)
            return model.canSendAttachments
        } isTargeted: { targeted in
            isDropTargeted = targeted && model.canSendAttachments
        }
    }

    // MARK: Box

    private var box: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !model.pendingAttachments.isEmpty {
                attachmentChips
            }

            HStack(alignment: .bottom, spacing: 8) {
                editor
                // Sized to the line height, the controls bottom-align to sit
                // centered on the last text line without any extra nudging.
                controls
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? accent : Rice.surface1,
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
        )
        // Float the snippet picker just above the box, leading-aligned. Anchored
        // to the box's top edge, then offset up by its own measured height (plus
        // a gap) so it grows upward into the timeline instead of over the box.
        .overlay(alignment: .topLeading) {
            if model.isSnippetPickerActive {
                SnippetPickerView(
                    matches: model.snippetMatches,
                    selection: model.snippetSelection,
                    onSelect: { index in
                        model.snippetSelection = index
                        model.commitSelectedSnippet()
                    }
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SnippetPickerHeightKey.self, value: proxy.size.height)
                    }
                )
                .offset(y: -(snippetPickerHeight + 6))
                .onPreferenceChange(SnippetPickerHeightKey.self) { snippetPickerHeight = $0 }
                .transition(.opacity)
            }
        }
    }

    private var editor: some View {
        GrowingTextView(
            text: $model.text,
            measuredHeight: $measuredHeight,
            fontSize: 13 * scale,
            isEnabled: model.conversationID != nil && model.undoSecondsRemaining == nil,
            sendOnReturn: sendOnReturn,
            isScrollable: measuredHeight >= ceiling - 0.5,
            isSnippetPickerActive: model.isSnippetPickerActive,
            onSnippetMove: { model.moveSnippetSelection($0) },
            onSnippetCommit: { model.commitSelectedSnippet() },
            onSnippetCancel: { model.clearSnippetPicker() },
            onSend: { Task { await model.send() } }
        )
        .frame(height: editorHeight)
        .overlay(alignment: .topLeading) {
            if model.text.isEmpty {
                Text(placeholder)
                    .riceFont(13)
                    .foregroundStyle(Rice.overlay0)
                    // Match the NSTextView's container insets so the placeholder
                    // sits exactly where the typed text begins.
                    .padding(.leading, GrowingTextView.insets.width)
                    .padding(.top, GrowingTextView.insets.height)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.text) { _, _ in model.textDidChange() }
        .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in
            stagePasteboardContents()
        }
        .accessibilityLabel("Message draft")
    }

    private var attachButton: some View {
        Button(action: presentAttachmentPanel) {
            Image(systemName: "paperclip")
                .riceFont(14)
        }
        .buttonStyle(RiceIconButtonStyle())
        .disabled(!model.canSendAttachments || model.undoSecondsRemaining != nil)
        .help("Attach files")
    }

    private var undoButton: some View {
        Button {
            model.undoPendingSend()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .riceFont(13, .bold)
                .foregroundStyle(Rice.crust)
                .frame(width: controlDiameter, height: controlDiameter)
                .background(accent, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Undo send")
        .accessibilityLabel("Undo send")
    }

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            Group {
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .riceFont(13, .bold)
                        .foregroundStyle(canSend ? Rice.crust : Rice.overlay0)
                }
            }
            .frame(width: controlDiameter, height: controlDiameter)
            .background(canSend ? accent : Rice.surface0, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: sendOnReturn ? [] : .command)
        .disabled(!canSend || model.isSending)
        .help(model.isSendEnabled ? sendHint : model.disabledExplanation)
        .accessibilityLabel("Send message")
    }

    /// Attach + send. Inline while the box is short; once it passes two lines
    /// they stack (paperclip over send) so the text keeps the full width.
    @ViewBuilder private var controls: some View {
        if stacksControls {
            VStack(spacing: 7) {
                attachButton
                primaryControl
            }
        } else {
            HStack(spacing: 8) {
                attachButton
                primaryControl
            }
        }
    }

    /// The round button below the editor: a send arrow normally, an undo arrow
    /// while a just-sent message is held in its cancel window.
    @ViewBuilder private var primaryControl: some View {
        if model.undoSecondsRemaining != nil {
            undoButton
        } else {
            sendButton
        }
    }

    private var footnote: some View {
        Group {
            if let remaining = model.undoSecondsRemaining {
                Text("Sending in \(remaining)s — press Esc to undo")
                    .foregroundStyle(accent)
            } else if let feedback = model.sendFeedback {
                Text(feedback)
                    .foregroundStyle(Rice.red)
            } else if !model.disabledExplanation.isEmpty {
                Text(model.disabledExplanation)
                    .foregroundStyle(Rice.overlay0)
            } else if isDropTargeted {
                Text("Release to attach")
                    .foregroundStyle(accent)
            }
        }
        .riceFont(10)
        .lineLimit(2)
        .padding(.horizontal, 4)
    }

    // MARK: Bits

    private var placeholder: String {
        model.conversationID == nil ? "Select a conversation" : "Message"
    }

    private var sendHint: String {
        sendOnReturn ? "Send (↩)" : "Send (⌘↩)"
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: iconName(for: url))
                            .riceFont(10)
                            .foregroundStyle(accent)
                        Text(url.lastPathComponent)
                            .riceFont(11, .medium)
                            .foregroundStyle(Rice.text)
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                        Button {
                            model.removeAttachment(url)
                        } label: {
                            Image(systemName: "xmark")
                                .riceFont(8, .bold)
                                .foregroundStyle(Rice.subtext0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .accessibilityLabel("Staged attachments")
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": "photo"
        case "mov", "mp4", "m4v": "video"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }

    private var canSend: Bool {
        model.isSendEnabled && (
            !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.pendingAttachments.isEmpty
        )
    }

    private func presentAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            model.stageAttachments(panel.urls)
        }
    }

    /// ⌘V with files or an image on the clipboard stages an attachment;
    /// plain-text pastes never reach this (the types don't match).
    private func stagePasteboardContents() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            model.stageAttachments(urls)
            return
        }
        let png: Data?
        if let direct = pasteboard.data(forType: .png) {
            png = direct
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let converted = NSBitmapImageRep(data: tiff)?
                      .representation(using: .png, properties: [:]) {
            png = converted
        } else {
            png = nil
        }
        guard let png else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            model.stageAttachments([url])
        } catch {
            AppLog.ui.error("Pasted image staging failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

private struct SnippetPickerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
