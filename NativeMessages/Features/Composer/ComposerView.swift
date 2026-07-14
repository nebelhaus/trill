import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !model.pendingAttachments.isEmpty {
                attachmentChips
            }

            HStack(alignment: .bottom, spacing: 9) {
                Button(action: presentAttachmentPanel) {
                    Image(systemName: "paperclip")
                        .riceFont(13)
                }
                .buttonStyle(RiceIconButtonStyle())
                .disabled(!model.canSendAttachments)
                .help("Attach files")
                .padding(.bottom, 3)

                TextEditor(text: $model.text)
                    .riceFont(13)
                    .foregroundStyle(Rice.text)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 40 * scale, maxHeight: 110 * scale)
                    .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? accent : Rice.surface1,
                                lineWidth: isDropTargeted ? 1.5 : 1
                            )
                    )
                    .disabled(model.conversationID == nil)
                    .onChange(of: model.text) { _, _ in model.textDidChange() }
                    .onPasteCommand(of: [.fileURL, .png, .tiff]) { _ in
                        stagePasteboardContents()
                    }
                    .accessibilityLabel("Message draft")

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
                    .frame(width: 28 * scale, height: 28 * scale)
                    .background(canSend ? accent : Rice.surface0, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || model.isSending)
                .help(model.isSendEnabled ? "Send (⌘↩)" : model.disabledExplanation)
                .accessibilityLabel("Send message")
            }

            if let feedback = model.sendFeedback {
                Text(feedback)
                    .riceFont(10)
                    .foregroundStyle(Rice.red)
                    .lineLimit(2)
            } else if !model.disabledExplanation.isEmpty {
                Text(model.disabledExplanation)
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
                    .lineLimit(2)
            } else if model.canSendAttachments, model.pendingAttachments.isEmpty {
                Text("Drop files here to attach")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0.opacity(isDropTargeted ? 1 : 0.6))
            }
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
