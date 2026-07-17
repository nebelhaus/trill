import Foundation
import SQLite3

enum AppDatabaseError: LocalizedError, Sendable {
    case openFailed(String)
    case operationFailed(String)
    case invalidStoredIdentifier

    var errorDescription: String? {
        switch self {
        case .openFailed: "The app-owned database could not be opened."
        case .operationFailed: "The app-owned database operation failed."
        case .invalidStoredIdentifier: "A stored conversation identifier is invalid."
        }
    }
}

actor AppDatabase {
    static let currentSchemaVersion = 10

    private final class Connection: @unchecked Sendable {
        let raw: OpaquePointer

        init(_ raw: OpaquePointer) {
            self.raw = raw
        }

        deinit {
            sqlite3_close(raw)
        }
    }

    private let connection: Connection

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(database)
            throw AppDatabaseError.openFailed(message)
        }
        let connection = Connection(database)
        self.connection = connection
        do {
            try Self.migrate(database)
        } catch {
            throw error
        }
    }

    static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("NativeMessages", isDirectory: true)
            .appendingPathComponent("app.sqlite3", isDirectory: false)
    }

    func schemaVersion() throws -> Int {
        try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
    }

    func setPinned(_ pinned: Bool, conversationID: ConversationID) throws {
        if pinned {
            try execute(
                "INSERT OR REPLACE INTO pinned_conversations (conversation_key, pinned_at) VALUES (?, ?)",
                bindings: [.text(conversationID.persistenceKey), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try execute(
                "DELETE FROM pinned_conversations WHERE conversation_key = ?",
                bindings: [.text(conversationID.persistenceKey)]
            )
        }
    }

    func pinnedConversationIDs() throws -> Set<ConversationID> {
        let keys = try textRows("SELECT conversation_key FROM pinned_conversations ORDER BY pinned_at DESC")
        var result = Set<ConversationID>()
        for key in keys {
            guard let id = ConversationID(persistenceKey: key) else { throw AppDatabaseError.invalidStoredIdentifier }
            result.insert(id)
        }
        return result
    }

    func saveDraft(_ text: String, conversationID: ConversationID) throws {
        if text.isEmpty {
            try execute("DELETE FROM drafts WHERE conversation_key = ?", bindings: [.text(conversationID.persistenceKey)])
        } else {
            try execute(
                "INSERT OR REPLACE INTO drafts (conversation_key, body, updated_at) VALUES (?, ?, ?)",
                bindings: [
                    .text(conversationID.persistenceKey),
                    .text(text),
                    .double(Date().timeIntervalSince1970),
                ]
            )
        }
    }

    func draft(conversationID: ConversationID) throws -> String {
        try scalarText(
            "SELECT body FROM drafts WHERE conversation_key = ?",
            bindings: [.text(conversationID.persistenceKey)]
        ) ?? ""
    }

    func setReadMark(_ date: Date, conversationID: ConversationID) throws {
        try execute(
            "INSERT OR REPLACE INTO read_marks (conversation_key, marked_at) VALUES (?, ?)",
            bindings: [.text(conversationID.persistenceKey), .double(date.timeIntervalSince1970)]
        )
    }

    func readMarks() throws -> [ConversationID: Date] {
        let handle = connection.raw
        var statement: OpaquePointer?
        let sql = "SELECT conversation_key, marked_at FROM read_marks"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [ConversationID: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0) else { continue }
            guard let id = ConversationID(persistenceKey: String(cString: key)) else {
                throw AppDatabaseError.invalidStoredIdentifier
            }
            result[id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
        return result
    }

    // MARK: - Folders

    func folders() throws -> [Folder] {
        let handle = connection.raw
        var statement: OpaquePointer?
        let sql = "SELECT id, name, color, sort_order FROM folders ORDER BY sort_order ASC"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [Folder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0),
                  let name = sqlite3_column_text(statement, 1),
                  let color = sqlite3_column_text(statement, 2)
            else { continue }
            result.append(Folder(
                id: String(cString: id),
                name: String(cString: name),
                colorName: String(cString: color),
                sortOrder: sqlite3_column_double(statement, 3)
            ))
        }
        return result
    }

    /// Persists a fully-formed folder. The caller (InboxModel) generates the id
    /// and sort order so it can insert the folder optimistically and keep the
    /// local and stored rows in lockstep.
    func insertFolder(_ folder: Folder, createdAt: Date) throws {
        try execute(
            "INSERT INTO folders (id, name, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [
                .text(folder.id),
                .text(folder.name),
                .text(folder.colorName),
                .double(folder.sortOrder),
                .double(createdAt.timeIntervalSince1970),
            ]
        )
    }

    func updateFolder(id: String, name: String, colorName: String) throws {
        try execute(
            "UPDATE folders SET name = ?, color = ? WHERE id = ?",
            bindings: [.text(name), .text(colorName), .text(id)]
        )
    }

    func deleteFolder(id: String) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM folder_members WHERE folder_id = ?", bindings: [.text(id)])
            try execute("DELETE FROM folders WHERE id = ?", bindings: [.text(id)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func setFolderMembership(folderID: String, conversationID: ConversationID, member: Bool) throws {
        if member {
            try execute(
                "INSERT OR REPLACE INTO folder_members (folder_id, conversation_key, added_at) VALUES (?, ?, ?)",
                bindings: [.text(folderID), .text(conversationID.persistenceKey), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try execute(
                "DELETE FROM folder_members WHERE folder_id = ? AND conversation_key = ?",
                bindings: [.text(folderID), .text(conversationID.persistenceKey)]
            )
        }
    }

    func folderMembers() throws -> [String: Set<ConversationID>] {
        let handle = connection.raw
        var statement: OpaquePointer?
        let sql = "SELECT folder_id, conversation_key FROM folder_members"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [String: Set<ConversationID>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let folderID = sqlite3_column_text(statement, 0),
                  let key = sqlite3_column_text(statement, 1)
            else { continue }
            guard let id = ConversationID(persistenceKey: String(cString: key)) else {
                throw AppDatabaseError.invalidStoredIdentifier
            }
            result[String(cString: folderID), default: []].insert(id)
        }
        return result
    }

    // MARK: - Archive / Mute / Snooze
    //
    // Three per-conversation triage overlays, each a thin table keyed on the
    // conversation. Archive and mute are membership sets (a row's presence *is*
    // the flag); snooze also stores the wake time so a thread can resurface on
    // its own. All local-only — chat.db is never touched.

    func setArchived(_ archived: Bool, conversationID: ConversationID) throws {
        if archived {
            try execute(
                "INSERT OR REPLACE INTO archived_conversations (conversation_key, archived_at) VALUES (?, ?)",
                bindings: [.text(conversationID.persistenceKey), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try execute(
                "DELETE FROM archived_conversations WHERE conversation_key = ?",
                bindings: [.text(conversationID.persistenceKey)]
            )
        }
    }

    func archivedConversationIDs() throws -> Set<ConversationID> {
        try conversationIDSet("SELECT conversation_key FROM archived_conversations")
    }

    func setMuted(_ muted: Bool, conversationID: ConversationID) throws {
        if muted {
            try execute(
                "INSERT OR REPLACE INTO muted_conversations (conversation_key, muted_at) VALUES (?, ?)",
                bindings: [.text(conversationID.persistenceKey), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try execute(
                "DELETE FROM muted_conversations WHERE conversation_key = ?",
                bindings: [.text(conversationID.persistenceKey)]
            )
        }
    }

    func mutedConversationIDs() throws -> Set<ConversationID> {
        try conversationIDSet("SELECT conversation_key FROM muted_conversations")
    }

    /// `until == nil` clears the snooze (the thread returns to the list now).
    func setSnooze(until wake: Date?, conversationID: ConversationID) throws {
        if let wake {
            try execute(
                "INSERT OR REPLACE INTO snoozed_conversations (conversation_key, wake_at) VALUES (?, ?)",
                bindings: [.text(conversationID.persistenceKey), .double(wake.timeIntervalSince1970)]
            )
        } else {
            try execute(
                "DELETE FROM snoozed_conversations WHERE conversation_key = ?",
                bindings: [.text(conversationID.persistenceKey)]
            )
        }
    }

    func snoozedConversations() throws -> [ConversationID: Date] {
        let handle = connection.raw
        var statement: OpaquePointer?
        let sql = "SELECT conversation_key, wake_at FROM snoozed_conversations"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [ConversationID: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0) else { continue }
            guard let id = ConversationID(persistenceKey: String(cString: key)) else {
                throw AppDatabaseError.invalidStoredIdentifier
            }
            result[id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
        return result
    }

    /// Reads a single-column conversation-key query into a typed ID set —
    /// shared by the archive and mute membership tables.
    private func conversationIDSet(_ sql: String) throws -> Set<ConversationID> {
        let keys = try textRows(sql)
        var result = Set<ConversationID>()
        for key in keys {
            guard let id = ConversationID(persistenceKey: key) else { throw AppDatabaseError.invalidStoredIdentifier }
            result.insert(id)
        }
        return result
    }

    func saveCursor(_ cursor: EventCursor, providerID: ProviderID) throws {
        try execute(
            "INSERT OR REPLACE INTO provider_cursors (provider_id, cursor, updated_at) VALUES (?, ?, ?)",
            bindings: [.text(providerID.rawValue), .text(cursor.rawValue), .double(Date().timeIntervalSince1970)]
        )
    }

    func cursor(providerID: ProviderID) throws -> EventCursor? {
        try scalarText(
            "SELECT cursor FROM provider_cursors WHERE provider_id = ?",
            bindings: [.text(providerID.rawValue)]
        ).map { EventCursor(rawValue: $0) }
    }

    func snippets() throws -> [Snippet] {
        let handle = connection.raw
        var statement: OpaquePointer?
        let sql = "SELECT id, title, body, updated_at FROM snippets ORDER BY title COLLATE NOCASE ASC"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [Snippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idColumn = sqlite3_column_text(statement, 0),
                  let titleColumn = sqlite3_column_text(statement, 1),
                  let bodyColumn = sqlite3_column_text(statement, 2) else { continue }
            result.append(Snippet(
                id: String(cString: idColumn),
                title: String(cString: titleColumn),
                body: String(cString: bodyColumn),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return result
    }

    func upsertSnippet(_ snippet: Snippet) throws {
        try execute(
            "INSERT OR REPLACE INTO snippets (id, title, body, updated_at) VALUES (?, ?, ?, ?)",
            bindings: [
                .text(snippet.id),
                .text(snippet.title),
                .text(snippet.body),
                .double(snippet.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    func deleteSnippet(id: String) throws {
        try execute("DELETE FROM snippets WHERE id = ?", bindings: [.text(id)])
    }

    private enum Binding {
        case text(String)
        case double(Double)
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let handle = connection.raw
        try Self.execute(handle, sql: sql, bindings: bindings)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let handle = connection.raw
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.error(handle)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.error(handle) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarText(_ sql: String, bindings: [Binding] = []) throws -> String? {
        let handle = connection.raw
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement, database: handle)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Self.error(handle) }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func textRows(_ sql: String) throws -> [String] {
        let handle = connection.raw
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(handle) }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { result.append(String(cString: value)) }
        }
        return result
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(
            database,
            sql: "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY NOT NULL, applied_at REAL NOT NULL)"
        )
        let version = try currentVersion(database)
        // `IF NOT EXISTS` on every table: my worktree sessions share one overlay
        // DB under Application Support, so two branches can claim the same
        // migration number with different SQL. Without this, whichever build runs
        // second throws "table already exists" mid-migration, `init` fails, and the
        // app silently drops to a throwaway temp store (losing all overlay state).
        // Idempotent creates let a collided DB still advance to the current version.
        let migrations: [(Int, String)] = [
            (1, "CREATE TABLE IF NOT EXISTS pinned_conversations (conversation_key TEXT PRIMARY KEY NOT NULL, pinned_at REAL NOT NULL)"),
            (2, "CREATE TABLE IF NOT EXISTS drafts (conversation_key TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL, updated_at REAL NOT NULL)"),
            (3, "CREATE TABLE IF NOT EXISTS provider_cursors (provider_id TEXT PRIMARY KEY NOT NULL, cursor TEXT NOT NULL, updated_at REAL NOT NULL)"),
            (4, "CREATE TABLE IF NOT EXISTS read_marks (conversation_key TEXT PRIMARY KEY NOT NULL, marked_at REAL NOT NULL)"),
            (5, "CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, sort_order REAL NOT NULL, created_at REAL NOT NULL)"),
            (6, "CREATE TABLE IF NOT EXISTS folder_members (folder_id TEXT NOT NULL, conversation_key TEXT NOT NULL, added_at REAL NOT NULL, PRIMARY KEY (folder_id, conversation_key))"),
            (7, "CREATE TABLE IF NOT EXISTS snippets (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, updated_at REAL NOT NULL)"),
            (8, "CREATE TABLE IF NOT EXISTS archived_conversations (conversation_key TEXT PRIMARY KEY NOT NULL, archived_at REAL NOT NULL)"),
            (9, "CREATE TABLE IF NOT EXISTS muted_conversations (conversation_key TEXT PRIMARY KEY NOT NULL, muted_at REAL NOT NULL)"),
            (10, "CREATE TABLE IF NOT EXISTS snoozed_conversations (conversation_key TEXT PRIMARY KEY NOT NULL, wake_at REAL NOT NULL)"),
        ]
        for (nextVersion, sql) in migrations where nextVersion > version {
            try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute(database, sql: sql)
                try execute(
                    database,
                    sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    bindings: [.double(Double(nextVersion)), .double(Date().timeIntervalSince1970)]
                )
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    private static func currentVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let sql = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error(database) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error(database) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer, sql: String, bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error(database) }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
    }

    private static func bind(_ bindings: [Binding], to statement: OpaquePointer?, database: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case let .text(value):
                status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case let .double(value):
                status = sqlite3_bind_double(statement, index, value)
            }
            guard status == SQLITE_OK else { throw error(database) }
        }
    }

    private static func error(_ database: OpaquePointer) -> AppDatabaseError {
        AppDatabaseError.operationFailed(String(cString: sqlite3_errmsg(database)))
    }
}
