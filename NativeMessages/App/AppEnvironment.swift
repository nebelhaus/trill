import Foundation

enum AppEnvironment {
    @MainActor
    static func makeInboxModel() -> InboxModel {
        do {
            let database = try AppDatabase(url: AppDatabase.applicationSupportURL())
            return InboxModel(database: database)
        } catch {
            AppLog.database.fault("Application Support database failed; using isolated temporary store error=\(String(describing: type(of: error)), privacy: .public)")
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("NativeMessages-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("app.sqlite3")
            guard let database = try? AppDatabase(url: fallback) else {
                fatalError("Unable to initialize the app-owned database")
            }
            return InboxModel(database: database)
        }
    }
}
