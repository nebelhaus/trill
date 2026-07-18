import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drives the "export all conversations" job: walks the chosen threads, writes
/// one Markdown file per thread plus an `index.md` into a temp folder, then zips
/// that folder to the destination the reader picked. All reads are read-only
/// (the provider's own chat.db reads); the only writes are into the temp folder
/// and the user's chosen `.zip`. Progress is published so the settings panel can
/// show a live bar and a current-thread label.
@MainActor
final class BulkExportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case done(url: URL, count: Int)
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// 0…1 for the progress bar. Guards against a zero total.
    var fraction: Double {
        total == 0 ? 0 : min(1, Double(completed) / Double(total))
    }

    func start(inbox: InboxModel, conversations: [Conversation], destination: URL) {
        guard !isRunning, !conversations.isEmpty else { return }
        phase = .running
        completed = 0
        total = conversations.count
        currentName = ""
        let filenames = BulkExportPlanner.filenames(for: conversations, fileExtension: "md")

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = try Self.makeWorkFolder()
                var counts: [Int] = []
                counts.reserveCapacity(conversations.count)

                for (index, conversation) in conversations.enumerated() {
                    if Task.isCancelled { break }
                    currentName = conversation.displayName
                    let messages = await inbox.exportMessages(in: conversation.id)
                    let document = ConversationExporter.export(
                        conversation: conversation,
                        messages: messages,
                        format: .markdown
                    )
                    let fileURL = folder.appendingPathComponent(filenames[index])
                    try document.data(using: .utf8)?.write(to: fileURL)
                    counts.append(messages.count)
                    completed = index + 1
                }

                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
                    phase = .cancelled
                    return
                }

                let indexDoc = BulkExportPlanner.indexMarkdown(
                    conversations: conversations, filenames: filenames, counts: counts
                )
                try indexDoc.data(using: .utf8)?.write(to: folder.appendingPathComponent("index.md"))

                try await Self.zip(folder: folder, to: destination)
                try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
                phase = .done(url: destination, count: conversations.count)
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                AppLog.ui.error("Bulk export failed error=\(String(describing: type(of: error)), privacy: .public)")
                phase = .failed("Couldn’t finish the export.")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Clears a finished/failed run so the panel returns to its ready state.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        completed = 0
        total = 0
        currentName = ""
    }

    // MARK: - File work

    /// A fresh temp folder named like the archive (`Trill Export <date>/`), so the
    /// zip's top-level entry reads nicely, wrapped in a unique container we can
    /// delete wholesale.
    private static func makeWorkFolder() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillBulkExport-\(UUID().uuidString)", isDirectory: true)
        let folder = container.appendingPathComponent(BulkExportPlanner.archiveStem(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Zips `folder` to `destination`. `NSFileCoordinator`'s `.forUploading` read
    /// produces a zip of the item in a managed temp location; we copy it out.
    /// Runs off the main actor — the coordination call blocks.
    private static func zip(folder: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var thrownError: Error?
            coordinator.coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zippedURL in
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: zippedURL, to: destination)
                } catch {
                    thrownError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let thrownError { throw thrownError }
        }.value
    }
}

/// Settings section that batch-exports conversations to a single `.zip` of
/// per-thread Markdown files. "All" grabs everything; "Pick" narrows to a ticked
/// subset. The whole-thread export lives on each conversation's own toolbar; this
/// is its all-at-once sibling, grouped here as the request asked.
struct ExportSettingsView: View {
    let inbox: InboxModel

    @StateObject private var job = BulkExportModel()
    @Environment(\.riceAccent) private var accent

    /// nil while the conversation list is still being gathered.
    @State private var conversations: [Conversation]?
    @State private var scope: Scope = .all
    @State private var picked: Set<ConversationID> = []

    private enum Scope: String { case all, pick }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export conversations")
                .riceSectionHeader()

            Text("Save every conversation as Markdown — one file per thread in a single .zip — ready to hand to an LLM. Reads only; nothing is sent or modified.")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)

            scopePicker

            if let conversations {
                if scope == .pick {
                    pickList(conversations)
                }
                summaryAndAction(conversations)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Gathering conversations…")
                        .riceFont(11)
                        .foregroundStyle(Rice.subtext0)
                }
                .padding(.vertical, 4)
            }
        }
        .task {
            if conversations == nil {
                conversations = await inbox.allConversationsForExport()
            }
        }
    }

    // MARK: - Scope

    private var scopePicker: some View {
        HStack(spacing: 6) {
            Button("All conversations") { scope = .all }
                .buttonStyle(ExportSegmentStyle(isSelected: scope == .all))
            Button("Pick") { scope = .pick }
                .buttonStyle(ExportSegmentStyle(isSelected: scope == .pick))
        }
    }

    private func pickList(_ conversations: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(picked.count == conversations.count ? "Select None" : "Select All") {
                    picked = picked.count == conversations.count ? [] : Set(conversations.map(\.id))
                }
                .buttonStyle(RiceSubtleButtonStyle())
                .disabled(conversations.isEmpty)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(conversations) { conversation in
                        Button {
                            toggle(conversation.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: picked.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                    .riceFont(13)
                                    .foregroundStyle(picked.contains(conversation.id) ? accent : Rice.overlay0)
                                Text(conversation.displayName)
                                    .riceFont(12)
                                    .foregroundStyle(Rice.text)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
            .background(Rice.base, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Summary + action

    private func summaryAndAction(_ conversations: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summaryLabel(conversations))
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
                .monospacedDigit()

            if job.isRunning {
                runningControls
            } else {
                HStack(spacing: 8) {
                    Button {
                        beginExport(conversations)
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RiceProminentButtonStyle())
                    .disabled(targets(conversations).isEmpty)

                    resultLabel
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: job.fraction)
                .tint(accent)
            HStack(spacing: 8) {
                Text(job.currentName.nonEmpty.map { "Exporting \($0)…" } ?? "Preparing…")
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(job.completed)/\(job.total)")
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
                    .monospacedDigit()
                Button("Cancel") { job.cancel() }
                    .buttonStyle(RiceSubtleButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var resultLabel: some View {
        switch job.phase {
        case let .done(url, count):
            HStack(spacing: 8) {
                Text("Exported \(count) conversation\(count == 1 ? "" : "s")")
                    .riceFont(11)
                    .foregroundStyle(accent)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(RiceSubtleButtonStyle())
            }
        case .cancelled:
            Text("Export cancelled")
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
        case let .failed(message):
            Text(message)
                .riceFont(11)
                .foregroundStyle(Rice.red)
        case .idle, .running:
            EmptyView()
        }
    }

    // MARK: - Derived

    private func targets(_ conversations: [Conversation]) -> [Conversation] {
        switch scope {
        case .all: return conversations
        case .pick: return conversations.filter { picked.contains($0.id) }
        }
    }

    private func summaryLabel(_ conversations: [Conversation]) -> String {
        let count = targets(conversations).count
        let noun = count == 1 ? "conversation" : "conversations"
        return "\(count) \(noun) · Markdown · .zip"
    }

    private func toggle(_ id: ConversationID) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func beginExport(_ conversations: [Conversation]) {
        let chosen = targets(conversations)
        guard !chosen.isEmpty else { return }
        job.reset()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(BulkExportPlanner.archiveStem()).zip"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.start(inbox: inbox, conversations: chosen, destination: url)
    }
}

/// The All / Pick segmented control, matching the settings panel's other pill
/// choices without reaching into `SettingsView`'s private style.
private struct ExportSegmentStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.riceAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .riceFont(12, .medium)
            .foregroundStyle(isSelected ? accent : Rice.subtext1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                isSelected ? accent.opacity(0.18) : Rice.surface0.opacity(configuration.isPressed ? 1 : 0.55),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}
