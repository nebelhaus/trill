import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Trill"

    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let repository = Logger(subsystem: subsystem, category: "repository")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}

