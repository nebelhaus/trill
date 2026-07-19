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
        let dateRead: Int64
        let dateEdited: Int64
    }

    struct ReactionRow: Sendable {
        let guid: String
        let kind: Int
        let emoji: String?
        let targetGUID: String
        let isFromMe: Bool
        let handleID: Int64
        let date: Int64
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

    func lastMessagePreview(chatRowID: Int64) throws -> (text: String?, body: Data?, hasAttachments: Bool, isFromMe: Bool)? {
        try withConnection { db in
            try query(db, """
                SELECT m.text, m.attributedBody, m.cache_has_attachments, m.is_from_me
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                ORDER BY m.date DESC
                LIMIT 1
                """, bind: [.int(chatRowID)]) { stmt in
                (text(stmt, 0), blob(stmt, 1), sqlite3_column_int(stmt, 2) == 1, sqlite3_column_int(stmt, 3) == 1)
            }.first
        }
    }

    /// GUIDs of the trailing run of inbound messages — the most recent real
    /// messages from them, i.e. those newer than my last sent message. Empty
    /// when the last message is mine. Bounded so a long unanswered burst is
    /// still cheap to scan.
    func trailingInboundGUIDs(chatRowID: Int64, limit: Int = 40) throws -> [String] {
        try withConnection { db in
            try query(db, """
                SELECT m.guid, m.is_from_me
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.int(chatRowID), .int(Int64(limit))]) { stmt in
                (guid: text(stmt, 0) ?? "", isFromMe: sqlite3_column_int(stmt, 1) == 1)
            }
            .prefix { !$0.isFromMe }
            .map(\.guid)
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
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id,
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                  AND (? IS NULL OR m.ROWID < ?)
                ORDER BY m.ROWID DESC
                LIMIT ?
                """, bind: [.int(chatRowID), .optionalInt(beforeRowID), .optionalInt(beforeRowID), .int(Int64(limit))],
                map: messageRow)
        }
    }

    /// Every message in a chat, oldest → newest and unbounded — the one-shot
    /// read behind conversation export. Same columns and filters as the paged
    /// `messages(...)`, minus the cursor/limit, so a 5-year thread comes back in
    /// a single scan instead of dozens of round-trips.
    func allMessages(chatRowID: Int64) throws -> [MessageRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id,
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.ROWID ASC
                """, bind: [.int(chatRowID)], map: messageRow)
        }
    }

    /// ROWID of the earliest non-retracted message in this chat dated on or after
    /// `appleDate` (Apple-epoch nanoseconds) — the "jump to date" anchor. Nil when
    /// the date is past the newest message, i.e. nothing is that recent.
    func anchorRowID(chatRowID: Int64, onOrAfterAppleDate appleDate: Int64) throws -> Int64? {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                  AND m.date >= ?
                ORDER BY m.date ASC, m.ROWID ASC
                LIMIT 1
                """, bind: [.int(chatRowID), .int(appleDate)]) { stmt in
                sqlite3_column_int64(stmt, 0)
            }.first
        }
    }

    /// ROWID of the message exactly `offset` positions newer than `rowID` in this
    /// chat — the top of a jump-to-date window, giving a little context after the
    /// anchor. Nil when fewer than `offset` newer messages exist (the caller then
    /// anchors at the newest page instead).
    func messageRowID(chatRowID: Int64, newerThan rowID: Int64, offset: Int) throws -> Int64? {
        guard offset > 0 else { return nil }
        let rows = try withConnection { db in
            try query(db, """
                SELECT m.ROWID
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                  AND m.ROWID > ?
                ORDER BY m.ROWID ASC
                LIMIT ?
                """, bind: [.int(chatRowID), .int(rowID), .int(Int64(offset))]) { stmt in
                sqlite3_column_int64(stmt, 0)
            }
        }
        return rows.count == offset ? rows.last : nil
    }

    /// All messages newer than a ROWID across every chat (event polling).
    func messagesAfter(rowID: Int64, limit: Int) throws -> [MessageRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id,
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE m.ROWID > ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.ROWID ASC
                LIMIT ?
                """, bind: [.int(rowID), .int(Int64(limit))], map: messageRow)
        }
    }

    /// Messages by GUID (reply originators may fall outside the loaded page).
    func messages(guids: [String]) throws -> [MessageRow] {
        guard !guids.isEmpty else { return [] }
        return try withConnection { db in
            let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
            return try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid,
                       IFNULL((SELECT j.chat_id FROM chat_message_join j WHERE j.message_id = m.ROWID), 0),
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                WHERE m.guid IN (\(placeholders))
                """, bind: guids.map { .text($0) }, map: messageRow)
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
                       m.associated_message_guid, m.is_from_me, m.handle_id, m.date
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ?
                  AND (m.associated_message_type BETWEEN 2000 AND 2006
                       OR m.associated_message_type BETWEEN 3000 AND 3006)
                """, bind: [.int(chatRowID)]) { stmt in
                ReactionRow(
                    guid: text(stmt, 0) ?? "",
                    kind: Int(sqlite3_column_int(stmt, 1)),
                    emoji: text(stmt, 2),
                    targetGUID: Self.reactionTarget(text(stmt, 3) ?? ""),
                    isFromMe: sqlite3_column_int(stmt, 4) == 1,
                    handleID: sqlite3_column_int64(stmt, 5),
                    date: sqlite3_column_int64(stmt, 6)
                )
            }
        }
    }

    func attachments(messageRowIDs: [Int64]) throws -> [AttachmentRow] {
        guard !messageRowIDs.isEmpty else { return [] }
        // SQLite caps bound variables per statement (SQLITE_MAX_VARIABLE_NUMBER,
        // historically 999). A full-thread export can pass tens of thousands of
        // message IDs, so batch the IN-list to stay under the ceiling.
        var result: [AttachmentRow] = []
        let batchSize = 900
        for start in stride(from: 0, to: messageRowIDs.count, by: batchSize) {
            let batch = Array(messageRowIDs[start..<min(start + batchSize, messageRowIDs.count)])
            try withConnection { db in
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                result += try query(db, """
                    SELECT j.message_id, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name, IFNULL(a.total_bytes, 0)
                    FROM attachment a
                    JOIN message_attachment_join j ON j.attachment_id = a.ROWID
                    WHERE j.message_id IN (\(placeholders))
                    """, bind: batch.map { .int($0) }) { stmt in
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
        return result
    }

    /// Every attachment in a chat, newest-first, with the owning message's
    /// GUID and date so gallery items can link back to the timeline.
    func media(chatRowID: Int64, limit: Int) throws -> [(row: AttachmentRow, messageGUID: String, date: Int64)] {
        try withConnection { db in
            try query(db, """
                SELECT maj.message_id, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name,
                       IFNULL(a.total_bytes, 0), m.guid, m.date
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                JOIN message m ON m.ROWID = maj.message_id
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE cmj.chat_id = ? AND IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.int(chatRowID), .int(Int64(limit))]) { stmt in
                (
                    row: AttachmentRow(
                        messageRowID: sqlite3_column_int64(stmt, 0),
                        guid: text(stmt, 1) ?? "",
                        filename: text(stmt, 2),
                        mimeType: text(stmt, 3),
                        uti: text(stmt, 4),
                        transferName: text(stmt, 5),
                        totalBytes: sqlite3_column_int64(stmt, 6)
                    ),
                    messageGUID: text(stmt, 7) ?? "",
                    date: sqlite3_column_int64(stmt, 8)
                )
            }
        }
    }

    /// Every attachment across *all* chats, newest-first, with the owning
    /// message's GUID, the chat GUID, and date — the all-conversations
    /// generalization of `media`. Powers the Universal Library's Images and
    /// Files tabs (the caller splits media vs. other by UTI/MIME).
    func allAttachments(limit: Int) throws -> [(row: AttachmentRow, messageGUID: String, chatGUID: String, date: Int64)] {
        try withConnection { db in
            try query(db, """
                SELECT maj.message_id, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name,
                       IFNULL(a.total_bytes, 0), m.guid, c.guid, m.date
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                JOIN message m ON m.ROWID = maj.message_id
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.int(Int64(limit))]) { stmt in
                (
                    row: AttachmentRow(
                        messageRowID: sqlite3_column_int64(stmt, 0),
                        guid: text(stmt, 1) ?? "",
                        filename: text(stmt, 2),
                        mimeType: text(stmt, 3),
                        uti: text(stmt, 4),
                        transferName: text(stmt, 5),
                        totalBytes: sqlite3_column_int64(stmt, 6)
                    ),
                    messageGUID: text(stmt, 7) ?? "",
                    chatGUID: text(stmt, 8) ?? "",
                    date: sqlite3_column_int64(stmt, 9)
                )
            }
        }
    }

    /// Recent messages that look like they carry a URL, across every chat, for
    /// the link library. The `http`/`www` prefilter bounds the decode + detect
    /// pass to a small candidate set instead of scanning the whole message
    /// table; bare-domain-only mentions (rare) are the accepted miss.
    func linkCandidates(limit: Int) throws -> [(guid: String, text: String?, body: Data?, chatGUID: String, date: Int64)] {
        try withConnection { db in
            try query(db, """
                SELECT m.guid, m.text, m.attributedBody, c.guid, m.date
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                  AND (m.text LIKE '%http%' OR m.text LIKE '%www.%'
                       OR instr(m.attributedBody, CAST('http' AS BLOB)) > 0
                       OR instr(m.attributedBody, CAST('www.' AS BLOB)) > 0)
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.int(Int64(limit))]) { stmt in
                (
                    guid: text(stmt, 0) ?? "",
                    text: text(stmt, 1),
                    body: blob(stmt, 2),
                    chatGUID: text(stmt, 3) ?? "",
                    date: sqlite3_column_int64(stmt, 4)
                )
            }
        }
    }

    /// Direction + timestamp for every real message in a chat, oldest-first.
    /// Deliberately narrow — no bodies, blobs, or joins beyond the chat link —
    /// so aggregating a whole thread's history for the stats panel stays cheap.
    func statSamples(chatRowID: Int64) throws -> [(isFromMe: Bool, date: Int64)] {
        try withConnection { db in
            try query(db, """
                SELECT m.is_from_me, m.date
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE j.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.date ASC
                """, bind: [.int(chatRowID)]) { stmt in
                (isFromMe: sqlite3_column_int(stmt, 0) == 1, date: sqlite3_column_int64(stmt, 1))
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
                       m.cache_has_attachments, m.thread_originator_guid, j.chat_id,
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                JOIN chat_message_join j ON j.message_id = m.ROWID
                WHERE m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                  AND (m.text LIKE ? ESCAPE '\\' OR instr(m.attributedBody, CAST(? AS BLOB)) > 0)
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.text(like), .text(term), .int(Int64(limit))], map: messageRow)
        }
    }

    /// My own messages across every chat, newest-first, bounded by `limit`. Backs
    /// the global writing-style profile. No `chat_message_join` — direction alone
    /// selects the rows, and the caller wants text/date only, so `chat_id` is a
    /// constant placeholder to keep the column layout identical to `messageRow`.
    func myMessageRows(limit: Int) throws -> [MessageRow] {
        try withConnection { db in
            try query(db, """
                SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date,
                       m.date_delivered, m.is_delivered, m.is_sent, m.error, m.handle_id,
                       m.cache_has_attachments, m.thread_originator_guid, 0 AS chat_id,
                       IFNULL(m.date_read, 0), IFNULL(m.date_edited, 0)
                FROM message m
                WHERE m.is_from_me = 1 AND m.associated_message_type = 0 AND m.item_type = 0
                  AND IFNULL(m.date_retracted, 0) = 0
                ORDER BY m.date DESC
                LIMIT ?
                """, bind: [.int(Int64(limit))], map: messageRow)
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
            chatRowID: sqlite3_column_int64(stmt, 13),
            dateRead: sqlite3_column_int64(stmt, 14),
            dateEdited: sqlite3_column_int64(stmt, 15)
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
