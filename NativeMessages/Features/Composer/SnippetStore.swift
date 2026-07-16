import Foundation

/// Loads and edits the user's canned responses, backed by `AppDatabase`. Shared
/// between the composer (which reads `snippets` to answer a `/`-trigger) and
/// Settings (which adds/edits/deletes them). Writes go to SQLite off the main
/// actor; the published array is the UI's source of truth and updates in place
/// so an editing row never loses focus or reorders under the cursor.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let database: AppDatabase
    private static let seedKey = "didSeedSnippets"

    init(database: AppDatabase) {
        self.database = database
    }

    /// Kick the initial load; seeds a starter set on first ever launch so the
    /// feature is discoverable, but never re-seeds once the user has curated
    /// (even down to an empty list).
    func load() {
        Task { await reload(seedIfNeeded: true) }
    }

    private func reload(seedIfNeeded: Bool = false) async {
        do {
            var loaded = try await database.snippets()
            if seedIfNeeded, loaded.isEmpty, !UserDefaults.standard.bool(forKey: Self.seedKey) {
                for snippet in Self.defaults {
                    try await database.upsertSnippet(snippet)
                }
                UserDefaults.standard.set(true, forKey: Self.seedKey)
                loaded = try await database.snippets()
            }
            snippets = loaded
        } catch {
            AppLog.database.error("Snippet load failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Add a blank snippet at the top, ready to edit in Settings. Returned so the
    /// caller can focus it immediately.
    @discardableResult
    func addBlank() -> Snippet {
        let snippet = Snippet(title: "", body: "")
        snippets.insert(snippet, at: 0)
        persist(snippet)
        return snippet
    }

    func update(_ snippet: Snippet) {
        var updated = snippet
        updated.updatedAt = Date()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = updated
        } else {
            snippets.insert(updated, at: 0)
        }
        persist(updated)
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        Task {
            do {
                try await database.deleteSnippet(id: snippet.id)
            } catch {
                AppLog.database.error("Snippet delete failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func persist(_ snippet: Snippet) {
        Task {
            do {
                try await database.upsertSnippet(snippet)
            } catch {
                AppLog.database.error("Snippet persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// First-launch starter kit — a few of the most universally useful replies.
    static let defaults: [Snippet] = [
        Snippet(title: "omw", body: "On my way!"),
        Snippet(title: "brb", body: "Be right back."),
        Snippet(title: "ty", body: "Thank you!"),
        Snippet(title: "callback", body: "Can I call you back in a bit?"),
    ]
}
