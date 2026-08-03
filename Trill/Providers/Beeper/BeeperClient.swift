import Foundation

/// Typed REST client for the Beeper Desktop API v1.
///
/// `URLSession` only — no third-party HTTP dependency. Bounded timeouts,
/// cooperative cancellation, and errors that are *categories* rather than
/// transcripts: nothing here logs a body, a header, a URL query, or a token.
/// The `Authorization` header exists in exactly one place (`request(_:)`) and is
/// never echoed anywhere.
struct BeeperClient: Sendable {
    enum Failure: LocalizedError, Sendable {
        case notConfigured
        case unreachable
        case unauthorized
        case http(status: Int)
        case malformedResponse
        case payloadTooLarge

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Beeper is not connected."
            case .unreachable: "The Beeper Server could not be reached."
            case .unauthorized: "The Beeper access token was rejected."
            case .http: "The Beeper Server returned an error."
            case .malformedResponse: "The Beeper Server returned an unexpected response."
            case .payloadTooLarge: "The Beeper Server returned more data than expected."
            }
        }

        /// Non-content category for `OSLog`. Never includes a server message.
        var category: String {
            switch self {
            case .notConfigured: "notConfigured"
            case .unreachable: "unreachable"
            case .unauthorized: "unauthorized"
            case let .http(status): "http\(status)"
            case .malformedResponse: "malformedResponse"
            case .payloadTooLarge: "payloadTooLarge"
            }
        }
    }

    private let configuration: BeeperConfiguration
    private let session: URLSession

    /// A cap on any single JSON response. The API is paginated, so a body past
    /// this is a bug or a hostile endpoint, not a big inbox.
    private static let maximumResponseBytes = 32 * 1024 * 1024

    init(configuration: BeeperConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - Endpoints

    func info() async throws -> BeeperInfo {
        try await get("/v1/info")
    }

    func accounts() async throws -> [BeeperAccount] {
        try await get("/v1/accounts")
    }

    /// `chats.list` takes no `limit` — the page size is the Server's.
    func chats(cursor: String?, accountIDs: [String]) async throws -> BeeperPage<BeeperChat> {
        try await get("/v1/chats", query: [
            .init(name: "cursor", value: cursor),
        ] + accountIDs.map { URLQueryItem(name: "accountIDs", value: $0) })
    }

    func searchChats(
        query: String,
        cursor: String?,
        limit: Int,
        accountIDs: [String]
    ) async throws -> BeeperPage<BeeperChat> {
        try await get("/v1/chats/search", query: [
            .init(name: "query", value: query.isEmpty ? nil : query),
            .init(name: "cursor", value: cursor),
            .init(name: "limit", value: String(limit)),
        ] + accountIDs.map { URLQueryItem(name: "accountIDs", value: $0) })
    }

    /// Paging here is *backward into history*, which is what Trill's `before`
    /// paging wants. The official SDK advances by resending `oldestCursor` and
    /// never sets `direction`, so neither do we — setting it wrong pages into
    /// the future and silently returns nothing useful.
    func messages(chatID: String, cursor: String?) async throws -> BeeperPage<BeeperMessage> {
        try await get("/v1/chats/\(escaped(chatID))/messages", query: [
            .init(name: "cursor", value: cursor),
        ])
    }

    func searchMessages(
        _ parameters: BeeperMessageSearchParameters
    ) async throws -> BeeperPage<BeeperMessage> {
        try await get("/v1/messages/search", query: parameters.queryItems)
    }

    func contacts(accountID: String, query: String, limit: Int) async throws -> BeeperPage<BeeperUser> {
        try await get("/v1/accounts/\(escaped(accountID))/contacts", query: [
            .init(name: "query", value: query.isEmpty ? nil : query),
            .init(name: "limit", value: String(limit)),
        ])
    }

    /// Asks the Server to materialize an `mxc://` asset locally. The returned
    /// path is on *its* filesystem, so it is only ever used as a liveness check —
    /// bytes come back through `serve` into our own cache.
    func downloadAsset(url: String) async throws -> BeeperAssetDownload {
        try await send(request(method: "POST", path: "/v1/assets/download", body: ["url": url]))
    }

    /// Streams an asset's bytes. Bounded by `maximumBytes` so a hostile or
    /// broken endpoint can't fill the disk.
    func assetBytes(url: String, maximumBytes: Int) async throws -> (Data, String?) {
        var request = try request(method: "GET", path: "/v1/assets/serve", query: [
            .init(name: "url", value: url),
        ])
        request.timeoutInterval = 60
        let (data, response) = try await perform(request)
        guard data.count <= maximumBytes else { throw Failure.payloadTooLarge }
        return (data, response.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Transport

    private func get<Value: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Value {
        try await send(request(method: "GET", path: path, query: query))
    }

    private func send<Value: Decodable & Sendable>(_ request: URLRequest) async throws -> Value {
        let (data, _) = try await perform(request)
        guard data.count <= Self.maximumResponseBytes else { throw Failure.payloadTooLarge }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw Failure.malformedResponse
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401, 403:
            throw Failure.unauthorized
        default:
            throw Failure.http(status: http.statusCode)
        }
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: String]? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.endpoint.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw Failure.malformedResponse }
        // `appendingPathComponent` percent-encodes the whole path; rebuild it so
        // an already-escaped chat id (Matrix ids contain `!` and `:`) survives.
        components.percentEncodedPath = path
        let items = query.filter { $0.value != nil }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw Failure.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The one place the token appears. It is never logged, never placed in a
        // URL, and never included in an error.
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
            ?? component
    }
}

/// The server-side half of `SearchFilters`. Trill parses `from:`/`in:`/`has:`/
/// `before:`/`after:` locally already; pushing them down means the Server
/// narrows before the wire instead of us discarding after it.
struct BeeperMessageSearchParameters: Sendable {
    var query: String?
    var cursor: String?
    var limit: Int
    var accountIDs: [String]
    var chatIDs: [String]
    /// `group` | `single`.
    var chatType: String?
    /// `me` | `others` | a `User.id`.
    var sender: String?
    var dateAfter: String?
    var dateBefore: String?
    /// `any` | `video` | `image` | `link` | `file`.
    var mediaTypes: [String]

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "query", value: query),
            .init(name: "cursor", value: cursor),
            .init(name: "limit", value: String(limit)),
            .init(name: "chatType", value: chatType),
            .init(name: "sender", value: sender),
            .init(name: "dateAfter", value: dateAfter),
            .init(name: "dateBefore", value: dateBefore),
        ]
        items += accountIDs.map { URLQueryItem(name: "accountIDs", value: $0) }
        items += chatIDs.map { URLQueryItem(name: "chatIDs", value: $0) }
        items += mediaTypes.map { URLQueryItem(name: "mediaTypes", value: $0) }
        return items
    }
}
