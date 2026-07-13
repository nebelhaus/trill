import XCTest
@testable import NativeMessages

final class FixtureProviderTests: XCTestCase {
    func testConversationOrderingAndPaginationAreDeterministic() async throws {
        let provider = FixtureProvider()
        let first = try await provider.conversations(page: ConversationPageRequest(limit: 2))
        let second = try await provider.conversations(
            page: ConversationPageRequest(limit: 2, cursor: first.nextCursor)
        )

        XCTAssertEqual(first.conversations.map(\.displayName), ["Weekend Plans", "Riley Park"])
        XCTAssertEqual(second.conversations.map(\.displayName), ["Avery Chen"])
        XCTAssertNil(second.nextCursor)
    }

    func testMessagePaginationLoadsAllHistoryWithoutDuplicates() async throws {
        let provider = FixtureProvider()
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "fixture"),
            externalGUID: "fixture-direct-imessage"
        )

        var before: String?
        var loaded: [Message] = []
        repeat {
            let page = try await provider.messages(
                in: conversation,
                page: MessagePageRequest(limit: 36, before: before)
            )
            loaded.append(contentsOf: page.messages)
            before = page.nextBefore
        } while before != nil

        XCTAssertEqual(loaded.count, 96)
        XCTAssertEqual(Set(loaded.map(\.id)).count, 96)
        XCTAssertEqual(Set(loaded.map(\.text)).count, 96)
    }

    func testSearchIsCaseInsensitiveAndDeterministic() async throws {
        let provider = FixtureProvider()
        let first = try await provider.search(MessageSearchQuery(text: "SYNTHETIC", limit: 3))
        let repeated = try await provider.search(MessageSearchQuery(text: "synthetic", limit: 3))

        XCTAssertEqual(first.messages.map(\.id), repeated.messages.map(\.id))
        XCTAssertEqual(first.messages.count, 3)
        XCTAssertNotNil(first.nextCursor)
    }

    func testEventStreamCanBeDrivenByTheFixture() async throws {
        let provider = FixtureProvider()
        let stream = await provider.events(after: nil)
        let pendingEvent = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        await Task.yield()

        await provider.emit(.healthChanged(.fixture))
        guard let event = try await pendingEvent.value else {
            return XCTFail("Fixture event stream ended before yielding")
        }
        await provider.finishEvents()

        if case .healthChanged(let health) = event {
            XCTAssertEqual(health, .fixture)
        } else {
            XCTFail("Expected a health event")
        }
    }

    func testEventDeduplicatorAcceptsAMessageOnlyOnce() async {
        let message = FixtureData.standard.messages.values.flatMap { $0 }.first!
        let event = ProviderEvent.messageAdded(message, cursor: EventCursor(rawValue: "1"))
        let deduplicator = ProviderEventDeduplicator()

        let first = await deduplicator.shouldAccept(event)
        let duplicate = await deduplicator.shouldAccept(event)
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
    }
}
