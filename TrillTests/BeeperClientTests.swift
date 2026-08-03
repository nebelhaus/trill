import Foundation
import XCTest
@testable import Trill

/// A `URLProtocol` that answers from a canned table. Nothing here reaches the
/// network: the suite is fixture-only by policy (`docs/testing.md`), and a real
/// Beeper Server holds the user's actual messages.
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    nonisolated(unsafe) static var responses: [String: Response] = [:]
    nonisolated(unsafe) static var observedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = [:]
        observedRequests = []
    }

    static func stub(path: String, status: Int = 200, json: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[path] = Response(status: status, body: Data(json.utf8))
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return observedRequests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.observedRequests.append(request)
        let match = request.url?.path.flatMap { Self.responses[$0] }
        Self.lock.unlock()

        guard let url = request.url, let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: match.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension String {
    func flatMap<T>(_ transform: (String) -> T?) -> T? { transform(self) }
}

final class BeeperClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> BeeperClient {
        let configuration = try BeeperConfiguration(
            endpoint: BeeperConfiguration.defaultEndpoint,
            accessToken: "fixture-token"
        )
        return BeeperClient(configuration: configuration, session: StubURLProtocol.session())
    }

    // MARK: - Endpoint policy

    /// Loopback may be plain HTTP — the traffic never leaves the machine, and
    /// that's what the headless Server serves. Anything else is a network
    /// boundary and must be HTTPS with normal certificate validation.
    func testLoopbackMayBeHTTPButRemoteMayNot() throws {
        XCTAssertNoThrow(try BeeperConfiguration(
            endpoint: URL(string: "http://127.0.0.1:23373")!,
            accessToken: "t"
        ))
        XCTAssertNoThrow(try BeeperConfiguration(
            endpoint: URL(string: "http://localhost:23373")!,
            accessToken: "t"
        ))
        XCTAssertNoThrow(try BeeperConfiguration(
            endpoint: URL(string: "https://beeper.example.invalid")!,
            accessToken: "t"
        ))
        XCTAssertThrowsError(try BeeperConfiguration(
            endpoint: URL(string: "http://beeper.example.invalid")!,
            accessToken: "t"
        ))
    }

    // MARK: - Transport

    func testBearerTokenIsSentAndNeverPlacedInTheURL() async throws {
        StubURLProtocol.stub(path: "/v1/info", json: BeeperFixtures.infoJSON)
        let client = try makeClient()

        _ = try await client.info()

        let request = try XCTUnwrap(StubURLProtocol.requests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertFalse(
            request.url?.absoluteString.contains("fixture-token") ?? true,
            "a token in a URL lands in logs and proxies"
        )
    }

    func testAccountsAndChatsDecodeFromTheWire() async throws {
        StubURLProtocol.stub(path: "/v1/accounts", json: BeeperFixtures.accountsJSON)
        StubURLProtocol.stub(path: "/v1/chats", json: BeeperFixtures.chatsPageJSON)
        let client = try makeClient()

        let accounts = try await client.accounts()
        let chats = try await client.chats(cursor: nil, accountIDs: ["local-whatsappaaa"])

        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(chats.items.count, 3)
        XCTAssertEqual(chats.oldestCursor, "cursor-older")
    }

    /// The allowlist has to ride on the *request*: fetching Beeper's iMessage
    /// chats and discarding them afterwards would corrupt page sizes as well as
    /// duplicating threads.
    func testAccountAllowlistIsSentAsRepeatedQueryItems() async throws {
        StubURLProtocol.stub(path: "/v1/chats", json: BeeperFixtures.chatsPageJSON)
        let client = try makeClient()

        _ = try await client.chats(cursor: nil, accountIDs: ["a1", "a2"])

        let url = try XCTUnwrap(StubURLProtocol.requests().first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "accountIDs" }.map(\.value), ["a1", "a2"])
    }

    /// The SDK advances by resending `oldestCursor` and never sets `direction`,
    /// so neither do we — sending the wrong one pages into the future.
    func testMessagePagingSendsOnlyTheCursor() async throws {
        StubURLProtocol.stub(
            path: "/v1/chats/!fixtureDirect:example.invalid/messages",
            json: BeeperFixtures.messagesPageJSON
        )
        let client = try makeClient()

        _ = try await client.messages(chatID: "!fixtureDirect:example.invalid", cursor: "abc")

        let url = try XCTUnwrap(StubURLProtocol.requests().first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "abc")
        XCTAssertNil(items.first { $0.name == "direction" })
    }

    func testUnauthorizedIsItsOwnCategory() async throws {
        StubURLProtocol.stub(path: "/v1/accounts", status: 401, json: "{}")
        let client = try makeClient()

        do {
            _ = try await client.accounts()
            XCTFail("expected a failure")
        } catch let failure as BeeperClient.Failure {
            XCTAssertEqual(failure.category, "unauthorized")
        }
    }

    func testMalformedBodyIsAFailureNotACrash() async throws {
        StubURLProtocol.stub(path: "/v1/accounts", json: "not json at all")
        let client = try makeClient()

        do {
            _ = try await client.accounts()
            XCTFail("expected a failure")
        } catch let failure as BeeperClient.Failure {
            XCTAssertEqual(failure.category, "malformedResponse")
        }
    }

    /// Error categories reach `OSLog`, so they must be non-content: a status
    /// code, never a server message or a body.
    func testFailureCategoriesCarryNoServerContent() {
        XCTAssertEqual(BeeperClient.Failure.http(status: 503).category, "http503")
        XCTAssertEqual(BeeperClient.Failure.unreachable.category, "unreachable")
        XCTAssertEqual(BeeperClient.Failure.notConfigured.category, "notConfigured")
    }
}
