import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet that scans how *you* write in the open thread and exports a Markdown
/// "style profile" — a document built to be pasted into an AI model so it can
/// recreate your voice. Reads the full history on appear (read-only, never
/// touching chat.db), builds the profile entirely on-device by counting your own
/// messages, previews it, and writes it out via the save panel or the clipboard.
/// No message content ever leaves the Mac.
struct StyleProfileView: View {
    @ObservedObject var model: ConversationModel
    let onClose: () -> Void

    @Environment(\.riceAccent) private var accent

    @State private var messages: [Message]?
    @State private var confirmation: String?
    @State private var elapsed = 0

    private static let previewLimit = 20_000

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()
            content
        }
        .frame(width: 480, height: 560)
        .background(Rice.mantle)
        .task { await load() }
        .task { await tick() }
    }

    private var header: some View {
        HStack {
            Text("Writing Style — \(model.conversation?.displayName ?? "Conversation")")
                .riceSectionHeader()
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(RiceSubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let profile {
            if profile.messageCount == 0 {
                EmptyStateView(
                    icon: "signature",
                    title: "Nothing to Analyze",
                    message: "You haven't sent any messages in this conversation yet."
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    caption(profile)
                    previewPane
                    actions
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(loadingLabel)
                    .riceFont(12)
                    .foregroundStyle(Rice.subtext0)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var loadingLabel: String {
        elapsed < 2 ? "Reading your messages…" : "Reading full history… \(elapsed)s"
    }

    private func caption(_ profile: StyleProfile) -> some View {
        Text("Built on-device from \(profile.messageCount) of your messages. Nothing leaves this Mac — you paste the result into a model yourself.")
            .riceFont(11)
            .foregroundStyle(Rice.subtext0)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .riceSectionHeader()
            ScrollView {
                Text(previewText)
                    .riceFont(11, design: .monospaced)
                    .foregroundStyle(Rice.subtext1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Rice.base, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .riceFont(11)
                    .foregroundStyle(accent)
                    .transition(.opacity)
            }
            Spacer()
            Button("Copy", action: copy)
                .buttonStyle(RiceSubtleButtonStyle())
                .disabled(profile?.messageCount ?? 0 == 0)
            Button("Save…", action: save)
                .buttonStyle(RiceProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(profile?.messageCount ?? 0 == 0)
        }
    }

    // MARK: - Derived state

    private var profile: StyleProfile? {
        guard let messages else { return nil }
        return StyleProfileBuilder.build(from: messages, subjectName: subjectName)
    }

    private var subjectName: String {
        model.conversation?.displayName ?? "Conversation"
    }

    private var output: String {
        guard let profile else { return "" }
        return StyleProfileExporter.export(profile)
    }

    private var previewText: String {
        let full = output
        guard full.count > Self.previewLimit else { return full }
        return String(full.prefix(Self.previewLimit)) + "\n…"
    }

    // MARK: - Actions

    private func load() async {
        messages = await model.loadAllForExport()
    }

    private func tick() async {
        while messages == nil {
            try? await Task.sleep(for: .seconds(1))
            if messages == nil { elapsed += 1 }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        flash("Copied to clipboard")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(sanitizedStem) writing style.md"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.data(using: .utf8)?.write(to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Couldn't save file")
            AppLog.ui.error("Style profile export write failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Filesystem-safe stem from the thread name (same illegal-character rule the
    /// conversation exporter uses).
    private var sanitizedStem: String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = String(subjectName.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Conversation" : cleaned
    }

    private func flash(_ message: String) {
        withAnimation { confirmation = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if confirmation == message { confirmation = nil } }
        }
    }
}
