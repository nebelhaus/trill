import Foundation

/// The long-lived models the app scenes share, built over one `AppDatabase`.
@MainActor
struct AppServices {
    let inbox: InboxModel
    let snippets: SnippetStore
}

enum AppEnvironment {
    @MainActor
    static func makeServices() -> AppServices {
        let database = openDatabase()
        let snippets = SnippetStore(database: database)
        snippets.load()
        let inbox = InboxModel(database: database, snippets: snippets)
        return AppServices(inbox: inbox, snippets: snippets)
    }

    /// Application Support store, or an isolated temporary one if that can't be
    /// opened — the app stays usable, it just won't persist across launches.
    @MainActor
    private static func openDatabase() -> AppDatabase {
        do {
            return try AppDatabase(url: AppDatabase.applicationSupportURL())
        } catch {
            AppLog.database.fault("Application Support database failed; using isolated temporary store error=\(String(describing: type(of: error)), privacy: .public)")
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("Trill-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("app.sqlite3")
            guard let database = try? AppDatabase(url: fallback) else {
                fatalError("Unable to initialize the app-owned database")
            }
            return database
        }
    }
}
