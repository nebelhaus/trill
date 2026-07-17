import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet that serializes the open thread to Markdown, plain text, or HTML —
/// something Apple's Messages can't do at all. Reads the full history on
/// appear (read-only, never touching chat.db), lets the reader pick a format
/// and optional date window, previews the result, and writes it out via the
/// save panel or the clipboard.
struct ConversationExportView: View {
    @ObservedObject var model: ConversationModel
    let onClose: () -> Void

    @Environment(\.riceAccent) private var accent

    @State private var allMessages: [Message]?
    @State private var format: ExportFormat = .markdown
    @State private var useRange = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var confirmation: String?

    /// Cap the on-screen preview so a huge thread doesn't stall the sheet; the
    /// actual export (save / copy) always uses the full document.
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
    }

    private var header: some View {
        HStack {
            Text("Export — \(model.conversation?.displayName ?? "Conversation")")
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
        if let allMessages {
            if allMessages.isEmpty {
                EmptyStateView(
                    icon: "square.and.arrow.up",
                    title: "Nothing to Export",
                    message: "This conversation has no messages."
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    formatPicker
                    rangeControls
                    previewPane
                    actions
                }
                .padding(16)
            }
        } else {
            LoadingStateView(label: "Gathering messages…")
        }
    }

    // MARK: - Controls

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Format")
                .riceSectionHeader()
            HStack(spacing: 8) {
                ForEach(ExportFormat.allCases) { option in
                    Button(option.label) { format = option }
                        .buttonStyle(SegmentButtonStyle(isActive: format == option))
                }
            }
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $useRange) {
                Text("Limit to a date range")
                    .riceFont(12)
                    .foregroundStyle(Rice.text)
            }
            .toggleStyle(.checkbox)

            if useRange {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                    DatePicker("To", selection: $endDate, displayedComponents: .date)
                }
                .riceFont(11)
                .datePickerStyle(.field)
                .labelsHidden()
                .foregroundStyle(Rice.subtext0)
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preview")
                    .riceSectionHeader()
                Spacer()
                Text(countLabel)
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
            }
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
                .disabled(selectedMessages.isEmpty)
            Button("Save…", action: save)
                .buttonStyle(RiceProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMessages.isEmpty)
        }
    }

    // MARK: - Derived state

    private var selectedMessages: [Message] {
        ConversationExporter.filter(allMessages ?? [], range: activeRange)
    }

    /// The inclusive window fed to the exporter — nil unless the range toggle is
    /// on. Normalizes so an inverted from/to still selects the span between them,
    /// and stretches the upper bound to the end of its day.
    private var activeRange: ClosedRange<Date>? {
        guard useRange else { return nil }
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: min(startDate, endDate))
        let upperDay = calendar.startOfDay(for: max(startDate, endDate))
        let upper = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: upperDay) ?? upperDay
        return lower...upper
    }

    private var output: String {
        guard let conversation = model.conversation else { return "" }
        return ConversationExporter.export(
            conversation: conversation,
            messages: allMessages ?? [],
            format: format,
            range: activeRange
        )
    }

    private var previewText: String {
        let full = output
        guard full.count > Self.previewLimit else { return full }
        return String(full.prefix(Self.previewLimit)) + "\n…"
    }

    private var countLabel: String {
        let count = selectedMessages.count
        return "\(count) message\(count == 1 ? "" : "s")"
    }

    private var contentType: UTType {
        switch format {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .plainText: .plainText
        case .html: .html
        }
    }

    // MARK: - Actions

    private func load() async {
        let messages = await model.loadAllForExport()
        allMessages = messages
        if let first = messages.first?.createdAt, let last = messages.last?.createdAt {
            startDate = first
            endDate = last
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        flash("Copied to clipboard")
    }

    private func save() {
        guard let conversation = model.conversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(ConversationExporter.filenameStem(for: conversation, range: activeRange)).\(format.fileExtension)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.data(using: .utf8)?.write(to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Couldn't save file")
            AppLog.ui.error("Conversation export write failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func flash(_ message: String) {
        withAnimation { confirmation = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if confirmation == message { confirmation = nil } }
        }
    }
}

/// A segmented-picker button: prominent when it's the active format, subtle
/// otherwise. Matches the app's other pill controls rather than the stock
/// segmented `Picker`.
private struct SegmentButtonStyle: ButtonStyle {
    let isActive: Bool

    @Environment(\.riceAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .riceFont(12, isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? Rice.base : Rice.subtext1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                isActive ? accent : Rice.surface0,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
