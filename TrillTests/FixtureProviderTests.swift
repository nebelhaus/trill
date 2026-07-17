import XCTest
@testable import Trill

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

    func testExportMessagesGathersFullHistoryChronologically() async throws {
        let provider = FixtureProvider()
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "fixture"),
            externalGUID: "fixture-direct-imessage"
        )

        let exported = try await provider.exportMessages(in: conversation)

        // Same 96-message history the paging test sees, deduped and sorted
        // oldest → newest by the default `exportMessages` implementation.
        XCTAssertEqual(exported.count, 96)
        XCTAssertEqual(Set(exported.map(\.id)).count, 96)
        let dates = exported.map(\.createdAt)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testJumpToDateAnchorsOnFirstMessageOnOrAfterAndPagesOlder() async throws {
        let provider = FixtureProvider()
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "fixture"),
            externalGUID: "fixture-direct-imessage"
        )
        // Fixture direct messages are dated base + index * 180s, indices 0..<96.
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        let target = base.addingTimeInterval(50 * 180)

        let result = try await provider.messages(in: conversation, around: target, limit: 36)

        // Anchor is the first message dated on or after the target.
        XCTAssertEqual(result.anchor?.externalGUID, "fixture-direct-50")
        // The window contains the anchor, plus a slice of newer context above it.
        let ids = result.page.messages.map(\.id.externalGUID)
        XCTAssertTrue(ids.contains("fixture-direct-50"))
        XCTAssertTrue(ids.contains("fixture-direct-62")) // newest in the window
        XCTAssertFalse(ids.contains("fixture-direct-63"))
        // Older history remains, reachable through the returned cursor.
        XCTAssertNotNil(result.page.nextBefore)
        let older = try await provider.messages(
            in: conversation,
            page: MessagePageRequest(limit: 36, before: result.page.nextBefore)
        )
        let overlap = Set(ids).intersection(older.messages.map(\.id.externalGUID))
        XCTAssertTrue(overlap.isEmpty)
    }

    func testJumpToDatePastNewestFallsBackToNewestPage() async throws {
        let provider = FixtureProvider()
        let conversation = ConversationID(
            provider: ProviderID(rawValue: "fixture"),
            externalGUID: "fixture-direct-imessage"
        )
        let result = try await provider.messages(in: conversation, around: .distantFuture, limit: 36)

        XCTAssertNil(result.anchor)
        // Same as a plain first page: the newest 36 messages.
        XCTAssertTrue(result.page.messages.map(\.id.externalGUID).contains("fixture-direct-95"))
        XCTAssertEqual(result.page.messages.count, 36)
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
