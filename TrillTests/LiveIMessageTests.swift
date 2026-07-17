import XCTest
@testable import Trill

final class LiveIMessageTests: XCTestCase {
    /// Builds a minimal typedstream-shaped blob: class name, the 0x01 0x2B
    /// marker, a length, then UTF-8 text — matching real chat.db blobs.
    private func blob(text: String, lengthEncoding: [UInt8]? = nil) -> Data {
        var bytes: [UInt8] = Array("streamtyped###NSString".utf8)
        bytes += [0x01, 0x2B]
        let utf8 = Array(text.utf8)
        bytes += lengthEncoding ?? [UInt8(utf8.count)]
        bytes += utf8
        bytes += [0x86, 0x84] // trailing typedstream noise
        return Data(bytes)
    }

    func testExtractsShortText() {
        XCTAssertEqual(TypedstreamText.extract(from: blob(text: "hello meow")), "hello meow")
    }

    func testExtractsTwoByteLengthText() {
        let text = String(repeating: "x", count: 300)
        let data = blob(text: text, lengthEncoding: [0x81, UInt8(300 & 0xFF), UInt8(300 >> 8)])
        XCTAssertEqual(TypedstreamText.extract(from: data), text)
    }

    func testDisplayTextStripsAttachmentPlaceholders() {
        XCTAssertEqual(TypedstreamText.displayText("\u{FFFC}Fixed now"), "Fixed now")
        XCTAssertEqual(TypedstreamText.displayText("\u{FFFC}"), "")
    }

    func testExtractReturnsNilForGarbage() {
        XCTAssertNil(TypedstreamText.extract(from: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(TypedstreamText.extract(from: Data()))
    }

    func testReactionTargetStripsKnownPrefixes() {
        XCTAssertEqual(ChatDatabaseReader.reactionTarget("p:0/ABC-123"), "ABC-123")
        XCTAssertEqual(ChatDatabaseReader.reactionTarget("bp:DEF-456"), "DEF-456")
        XCTAssertEqual(ChatDatabaseReader.reactionTarget("GHI-789"), "GHI-789")
    }

    func testContactNormalizationMatchesPhonesAndEmails() {
        XCTAssertEqual(ContactsNameResolver.normalize("+1 (204) 555-1234"), "2045551234")
        XCTAssertEqual(ContactsNameResolver.normalize("12045551234"), "2045551234")
        XCTAssertEqual(ContactsNameResolver.normalize("Meow@Example.COM"), "meow@example.com")
    }

    private func reactionRow(
        _ kind: Int,
        target: String = "MSG",
        handle: Int64 = 7,
        fromMe: Bool = false,
        emoji: String? = nil,
        date: Int64,
        guid: String = "r"
    ) -> ChatDatabaseReader.ReactionRow {
        ChatDatabaseReader.ReactionRow(
            guid: guid, kind: kind, emoji: emoji, targetGUID: target,
            isFromMe: fromMe, handleID: handle, date: date
        )
    }

    func testRemovedTapbackDisappears() {
        // Loved, then removed the love (2000 → 3000). Nothing should remain.
        let rows = [
            reactionRow(2000, date: 100, guid: "add"),
            reactionRow(3000, date: 200, guid: "remove"),
        ]
        XCTAssertTrue(LiveIMessageProvider.latestReactions(rows).isEmpty)
    }

    func testChangedTapbackKeepsOnlyLatest() {
        // Loved, then switched to liked: love add, love remove, like add.
        let rows = [
            reactionRow(2000, date: 100, guid: "love"),
            reactionRow(3000, date: 150, guid: "unlove"),
            reactionRow(2001, date: 160, guid: "like"),
        ]
        let winners = LiveIMessageProvider.latestReactions(rows)
        XCTAssertEqual(winners.map(\.kind), [2001])
    }

    func testDistinctSendersAndCustomEmojiCoexist() {
        // Two people love it, and one adds a custom 🎉 — three live reactions.
        let rows = [
            reactionRow(2000, handle: 1, date: 10, guid: "a"),
            reactionRow(2000, handle: 2, date: 20, guid: "b"),
            reactionRow(2006, handle: 1, emoji: "🎉", date: 30, guid: "c"),
        ]
        XCTAssertEqual(LiveIMessageProvider.latestReactions(rows).count, 3)
    }

    func testCustomEmojiRemovalDropsOnlyThatEmoji() {
        // Same person adds 🎉 and 🔥, then removes 🎉. Only 🔥 remains.
        let rows = [
            reactionRow(2006, emoji: "🎉", date: 10, guid: "party"),
            reactionRow(2006, emoji: "🔥", date: 20, guid: "fire"),
            reactionRow(3006, emoji: "🎉", date: 30, guid: "unparty"),
        ]
        let winners = LiveIMessageProvider.latestReactions(rows)
        XCTAssertEqual(winners.map(\.emoji), ["🔥"])
    }

    func testDatabaseWatcherFiresOnWalWrite() throws {
        // Stand in for chat.db-wal with a temp file and confirm the watcher's
        // DispatchSource fires when it's written — no real database involved.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("chat.db")
        let walURL = dir.appendingPathComponent("chat.db-wal")
        FileManager.default.createFile(atPath: walURL.path, contents: Data([0]))

        let fired = expectation(description: "watcher fires on WAL write")
        fired.assertForOverFulfill = false
        let watcher = ChatDatabaseWatcher(databaseURL: dbURL) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // Append repeatedly so a write lands after arm() finishes on its queue.
        let handle = try FileHandle(forWritingTo: walURL)
        defer { try? handle.close() }
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            handle.seekToEndOfFile()
            handle.write(Data([0x42]))
        }
        defer { ticker.invalidate() }

        wait(for: [fired], timeout: 3)
    }
}
