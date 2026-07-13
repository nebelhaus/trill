import Foundation
import SQLite3

/// Fallback contact-name source: reads macOS's AddressBook SQLite stores
/// directly (read-only), which Full Disk Access already covers. Used when
/// Contacts framework authorization hasn't been granted — names only, since
/// photo blobs live behind the framework.
enum AddressBookReader {
    static func nameByHandle() -> [String: String] {
        var map: [String: String] = [:]
        for database in databaseURLs() {
            merge(database, into: &map)
        }
        return map
    }

    private static func databaseURLs() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AddressBook")
        var urls = [root.appendingPathComponent("AddressBook-v22.abcddb")]
        let sources = root.appendingPathComponent("Sources")
        if let children = try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
            urls += children.map { $0.appendingPathComponent("AddressBook-v22.abcddb") }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func merge(_ databaseURL: URL, into map: inout [String: String]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT p.ZFULLNUMBER, r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION
            FROM ZABCDPHONENUMBER p JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
            UNION ALL
            SELECT e.ZADDRESS, r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION
            FROM ZABCDEMAILADDRESS e JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let handle = column(stmt, 0) else { continue }
            let nickname = column(stmt, 3)
            let fullName = [column(stmt, 1), column(stmt, 2)]
                .compactMap(\.self)
                .joined(separator: " ")
                .nonEmpty
            guard let name = nickname ?? fullName ?? column(stmt, 4) else { continue }
            let key = ContactsNameResolver.normalize(handle)
            if map[key] == nil {
                map[key] = name
            }
        }
    }

    private static func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0).trimmingCharacters(in: .whitespaces) }?.nonEmpty
    }
}
