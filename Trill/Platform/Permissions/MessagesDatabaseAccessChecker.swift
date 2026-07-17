import Foundation
import SQLite3

enum MessagesDatabaseAccessFailure: Error, Equatable, Sendable {
    case permissionDenied
    case missingDatabase
    case unsupportedSchema
    case unreadable
}

struct MessagesDatabaseAccessChecker: Sendable {
    let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")) {
        self.databaseURL = databaseURL
    }

    func probe() -> Result<Void, MessagesDatabaseAccessFailure> {
        let parent = databaseURL.deletingLastPathComponent()
        guard FileManager.default.isReadableFile(atPath: parent.path) else {
            return .failure(.permissionDenied)
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .failure(.missingDatabase)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            sqlite3_close(database)
            return .failure(status == SQLITE_CANTOPEN || status == SQLITE_PERM || status == SQLITE_AUTH ? .permissionDenied : .unreadable)
        }
        defer { sqlite3_close(database) }

        // Deliberately read-only: no migrations, write-capable pragmas, vacuum,
        // repair, or index creation is ever issued against Apple's database.
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('chat', 'message')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.unreadable)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return .failure(.unreadable) }
        return sqlite3_column_int(statement, 0) == 2 ? .success(()) : .failure(.unsupportedSchema)
    }

    static func health(for result: Result<Void, MessagesDatabaseAccessFailure>) -> HealthState {
        switch result {
        case .success:
            return .ready
        case let .failure(failure):
            switch failure {
            case .permissionDenied:
                return HealthState(
                    availability: .unavailable,
                    reason: .permissionMissing,
                    recoverySuggestion: "Allow Full Disk Access for Native Messages, then recheck."
                )
            case .missingDatabase:
                return HealthState(
                    availability: .unavailable,
                    reason: .databaseMissing,
                    recoverySuggestion: "Open Messages and confirm that an account is signed in."
                )
            case .unsupportedSchema:
                return HealthState(
                    availability: .unavailable,
                    reason: .unsupportedSchema,
                    recoverySuggestion: "This Messages database version is not supported yet."
                )
            case .unreadable:
                return HealthState(
                    availability: .unavailable,
                    reason: .providerFailure,
                    recoverySuggestion: "The Messages database could not be validated safely."
                )
            }
        }
    }
}

