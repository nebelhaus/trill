import Foundation
import SQLite3

/// Read-only SQL access to Apple's Messages database.
///
/// Every connection is opened with SQLITE_OPEN_READONLY and closed after the
/// call. No write-capable pragma, migration, vacuum, or index statement is
/// ever issued — the risk the old safety gate guarded against does not exist
/// on this path.
struct ChatDatabaseReader: Sendable {
    struct ChatRow: Sendable {
        let rowID: Int64
        let guid: String
        let identifier: String
        let displayName: String?
        let serviceName: String?
        let isGroup: Bool
        let lastMessageDate: Int64
    }

    struct MessageRow: Sendable {
        let rowID: Int64
        let guid: String
        let text: String?
        let attributedBody: Data?
        let isFromMe: Bool
        let date: Int64
        let dateDelivered: Int64
        let isDelivered: Bool
        let isSent: Bool
        let error: Int
        let handleID: Int64
        let hasAttachments: Bool
        let threadOriginatorGUID: String?
        let chatRowID: Int64
    }

    struct ReactionRow: Sendable {
        let guid: String
        let kind: Int
        let emoji: String?
        let targetGUID: String
        let isFromMe: Bool
        let handleID: Int64
    }

    struct AttachmentRow: Sendable {
        let messageRowID: Int64
        let guid: String
        let filename: String?
        let mimeType: String?
        let uti: String?
        let transferName: String?
        let totalBytes: Int64
    }

    struct HandleRow: Sendable {
        let rowID: Int64
        let id: String
        let service: String?
    }

    let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")) {
        self.databaseURL = databaseURL
    }

    // MARK: - Queries

    func recentChats(limit: Int) throws -> [ChatRow] {
        try withConnection { db in
            try query(db, """
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
                       MAX(m.date) AS last_date
                FROM chat c
                JOIN chat_message_join j ON j.chat_id = c.ROWID
                JOIN message m ON m.ROWID = j.message_id
                GROUP BY c.ROWID
                ORDER BY last_date DESC
                LIMIT ?
                """, bind: [.int(Int64(limit))]) { stmt in
                ChatRow(
                    rowID: sqlite3_column_int64(stmt, 0),
                    guid: text(stmt, 1) ?? "",
                    identifier: text(stmt, 2) ?? "",
                    displayName: text(stmt, 3)?.nonEmpty,
                    serviceName: text(stmt, 4),
                    isGroup: sqlite3_column_int(stmt, 5) == 43,
                    lastMessageDate: sqlite3_column_int64(stmt, 6)
                )
            }
        }
    }

    func chat(guid: String) throws -> ChatRow? {
        try withConnection { db in
            try query(db, """
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
                       IFNULL((SELECT MAX(m.date) FROM message m
                               JOIN chat_message_join j ON j.message_id = m.ROWID
                               WHERE j.chat_id = c.ROWID), 0)
                FROM chat c WHERE c.guid = ?
                """, bind: [.text(guid)]) { stmt in
                ChatRow(
                    rowID: sqlite3_column_int64(stmt, 0),
                    guid: text(stmt, 1) ?? "",
                    identifier: text(stmt, 2) ?? "",
                    displayName: text(stmt, 3)?.nonEmpty,
                    serviceName: text(stmt, 4),
                    isGroup: sqlite3_column_int(stmt, 5) == 43,
                    lastMessageDate: sqlite3_column_int64(stmt, 6)
                )
            }.first
        }
    }

    func lastMessagePreview(chatRowID: Int64) throws -> (text: String?, body: Data?, hasAttachments: Bool)? {
        try withConnection { db in
            try query(db, """
                SELECT m.text, m.attributedBody, m.cache_has_attachments
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                ORDER BY m.date DESC
                LIMIT 1
                """, bind: [.int(chatRowID)]) { stmt in
                (text(stmt, 0), blob(stmt, 1), sqlite3_column_int(stmt, 2) == 1)
            }.first
        }
    }

    func unreadCount(chatRowID: Int64) throws -> Int {
        try withConnection { db in
            try query(db, """
                SELECT COUNT(*)
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.is_from_me = 0 AND m.is_read = 0
                  AND m.associated_message_type = 0 AND m.item_type = 0
                """, bind: [.int(chatRowID)]) { stmt in
                Int(sqlite3_column_int(stmt, 0))
            }.first ?? 0
        }
    }

    func participants(chatRowID: Int64) throws -> [HandleRow] {
        try withConnection { db in
            try query(db, """
                SELECT h.ROWID, h.id, h.service
                FROM handle h
                JOIN chat_handle_join j ON j.handle_id = h.ROWID
                WHERE j.chat_id = ?
                """, bind: [.int(chatRowID)]) { stmt in
                HandleRow(rowID: sqlite3_column_int64(stmt, 0), id: text(stmt, 1) ?? "", service: text(stmt, 2))
            }
        }
    }

    func handles(rowIDs: [Int64]) throws -> [Int64: HandleRow] {
        guard !rowIDs.isEmpty else { return [:] }
        return try withConnection { db in
            let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
            let rows = try query(db, "SELECT ROWID, id, service FROM handle WHERE ROWID IN (\(placeholders))",
                                 bind: rowIDs.map { .int($0) }) { stmt in
                HandleRow(rowID: sqlite3_column_int64(stmt, 0), id: text(stmt, 1) ?? "", service: text(stmt, 2))
            }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.rowID, $0) })
        }
    }

    /// Messages in a chat, newest-first, paged by ROWID cursor.
    func messages(chatRowID: Int64, beforeRowID: Int64?, limit: Int) throws -> [MessageRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND (? IS NULL OR m.ROWID < ?)
                ORDER BY m.ROWID DESC
                LIMIT ?
                """, bind: [.int(chatRowID), .optionalInt(beforeRowID), .optionalInt(beforeRowID), .int(Int64(limit))],
                map: messageRow)
        }
    }

    /// All messages newer than a ROWID across every chat (event polling).
    func messagesAfter(rowID: Int64, limit: Int) throws -> [MessageRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE m.ROWID > ? AND m.associated_message_type = 0 AND m.item_type = 0
                ORDER BY m.ROWID ASC
                LIMIT ?
                """, bind: [.int(rowID), .int(Int64(limit))], map: messageRow)
        }
    }

    func maxMessageRowID() throws -> Int64 {
        try withConnection { db in
            try query(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message", bind: []) { stmt in
                sqlite3_column_int64(stmt, 0)
            }.first ?? 0
        }
    }

    func reactions(chatRowID: Int64) throws -> [ReactionRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.guid, m.associated_message_type, m.associated_message_emoji,
                       m.associated_message_guid, m.is_from_me, m.handle_id
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type BETWEEN 2000 AND 2006
                """, bind: [.int(chatRowID)]) { stmt in
                ReactionRow(
                    guid: text(stmt, 0) ?? "",
                    kind: Int(sqlite3_column_int(stmt, 1)),
                    emoji: text(stmt, 2),
                    targetGUID: Self.reactionTarget(text(stmt, 3) ?? ""),
                    isFromMe: sqlite3_column_int(stmt, 4) == 1,
                    handleID: sqlite3_column_int64(stmt, 5)
                )
            }
        }
    }

    func attachments(messageRowIDs: [Int64]) throws -> [AttachmentRow] {
        guard !messageRowIDs.isEmpty else { return [] }
        return try withConnection { db in
            let placeholders = Array(repeating: "?", count: messageRowIDs.count).joined(separator: ",")
            return try query(db, """
                SELECT j.message_id, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name, IFNULL(a.total_bytes, 0)
                FROM attachment a
                JOIN message_attachment_join j ON j.attachment_id = a.ROWID
                WHERE j.message_id IN (\(placeholders))
                """, bind: messageRowIDs.map { .int($0) }) { stmt in
                AttachmentRow(
                    messageRowID: sqlite3_column_int64(stmt, 0),
                    guid: text(stmt, 1) ?? "",
                    filename: text(stmt, 2),
                    mimeType: text(stmt, 3),
                    uti: text(stmt, 4),
                    transferName: text(stmt, 5),
                    totalBytes: sqlite3_column_int64(stmt, 6)
                )
            }
        }
    }

    /// Case-insensitive-ish text search. `instr` covers attributedBody blobs
    /// byte-wise (case-sensitive); results are re-filtered after decoding.
    func searchMessages(term: String, limit: Int) throws -> [MessageRow] {
        try withConnection { db in
            let like = "%\(escapeLike(term))%"
            return try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE m.associated_message_type = 0 AND m.item_type = 0
                  AND (m.text LIKE ? ESCAPE '\\' OR instr(m.attributedBody, CAST(? AS BLOB)) > 0)
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.text(like), .text(term), .int(Int64(limit))], map: messageRow)
        }
    }

    func chats(rowIDs: [Int64]) throws -> [Int64: ChatRow] {
        guard !rowIDs.isEmpty else { return [:] }
        return try withConnection { db in
            let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
            let rows = try query(db, """
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style, 0
                FROM chat c WHERE c.ROWID IN (\(placeholders))
                """, bind: rowIDs.map { .int($0) }) { stmt in
                ChatRow(
                    rowID: sqlite3_column_int64(stmt, 0),
                    guid: text(stmt, 1) ?? "",
                    identifier: text(stmt, 2) ?? "",
                    displayName: text(stmt, 3)?.nonEmpty,
                    serviceName: text(stmt, 4),
                    isGroup: sqlite3_column_int(stmt, 5) == 43,
                    lastMessageDate: sqlite3_column_int64(stmt, 6)
                )
            }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.rowID, $0) })
        }
    }

    // MARK: - Row mapping

    private func messageRow(_ stmt: OpaquePointer) -> MessageRow {
        MessageRow(
            rowID: sqlite3_column_int64(stmt, 0),
            guid: text(stmt, 1) ?? "",
            text: text(stmt, 2),
            attributedBody: blob(stmt, 3),
            isFromMe: sqlite3_column_int(stmt, 4) == 1,
            date: sqlite3_column_int64(stmt, 5),
            dateDelivered: sqlite3_column_int64(stmt, 6),
            isDelivered: sqlite3_column_int(stmt, 7) == 1,
            isSent: sqlite3_column_int(stmt, 8) == 1,
            error: Int(sqlite3_column_int(stmt, 9)),
            handleID: sqlite3_column_int64(stmt, 10),
            hasAttachments: sqlite3_column_int(stmt, 11) == 1,
            threadOriginatorGUID: text(stmt, 12),
            chatRowID: sqlite3_column_int64(stmt, 13)
        )
    }

    /// "p:0/GUID" and "bp:GUID" both reference the target message GUID.
    static func reactionTarget(_ associated: String) -> String {
        if let slash = associated.firstIndex(of: "/") {
            return String(associated[associated.index(after: slash)...])
        }
        if associated.hasPrefix("bp:") {
            return String(associated.dropFirst(3))
        }
        return associated
    }

    // MARK: - SQLite plumbing

    enum Binding {
        case int(Int64)
        case optionalInt(Int64?)
        case text(String)
    }

    struct ReadError: Error {
        let message: String
    }

    private func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ReadError(message: "chat.db open failed (status \(status))")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, bind: [Binding], map: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReadError(message: "prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .int(number):
                sqlite3_bind_int64(stmt, position, number)
            case let .optionalInt(number):
                if let number {
                    sqlite3_bind_int64(stmt, position, number)
                } else {
                    sqlite3_bind_null(stmt, position)
                }
            case let .text(string):
                sqlite3_bind_text(stmt, position, string, -1, transient)
            }
        }

        var rows: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                rows.append(map(stmt))
            case SQLITE_DONE:
                return rows
            case let status:
                throw ReadError(message: "step failed (status \(status))")
            }
        }
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private func escapeLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
