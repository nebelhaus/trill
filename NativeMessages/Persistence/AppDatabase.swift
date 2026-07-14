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
    static let currentSchemaVersion = 4

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
        let migrations: [(Int, String)] = [
            (1, "CREATE TABLE pinned_conversations (conversation_key TEXT PRIMARY KEY NOT NULL, pinned_at REAL NOT NULL)"),
            (2, "CREATE TABLE drafts (conversation_key TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL, updated_at REAL NOT NULL)"),
            (3, "CREATE TABLE provider_cursors (provider_id TEXT PRIMARY KEY NOT NULL, cursor TEXT NOT NULL, updated_at REAL NOT NULL)"),
            (4, "CREATE TABLE read_marks (conversation_key TEXT PRIMARY KEY NOT NULL, marked_at REAL NOT NULL)"),
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
