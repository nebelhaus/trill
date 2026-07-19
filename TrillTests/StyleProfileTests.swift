import XCTest
@testable import Trill

final class StyleProfileTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_784_073_600)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private let provider = ProviderID(rawValue: "fixture")
    private var conversationID: ConversationID {
        ConversationID(provider: provider, externalGUID: "style-thread")
    }

    private func msg(_ id: String, _ text: String, at offset: TimeInterval, fromMe: Bool) -> Message {
        Message(
            id: MessageID(provider: provider, externalGUID: id),
            conversationID: conversationID,
            providerSequence: id,
            sender: fromMe ? nil : Participant(id: "p1", displayName: "Alice", handle: "+15551234567"),
            isOutgoing: fromMe,
            text: text,
            createdAt: at(offset),
            sentAt: nil,
            deliveredAt: nil,
            attachments: [],
            reactions: [],
            replyTo: nil,
            threadOrigin: nil,
            service: .iMessage,
            deliveryState: .sent
        )
    }

    private func build(_ messages: [Message]) -> StyleProfile {
        StyleProfileBuilder.build(from: messages, scope: .conversation("Alice"), now: at(0))
    }

    // MARK: - Scope

    /// The profile describes *my* voice: only outgoing, non-empty texts count;
    /// incoming ones and my attachment-only (empty-text) messages don't.
    func testProfileMeasuresOnlyMyTextMessages() {
        let profile = build([
            msg("1", "hey there", at: 0, fromMe: false),   // theirs
            msg("2", "yo", at: 10, fromMe: true),          // mine
            msg("3", "", at: 20, fromMe: true),            // mine, no text
            msg("4", "sup", at: 30, fromMe: true),         // mine
        ])
        XCTAssertEqual(profile.messageCount, 2)
    }

    func testEmptyWhenNoOutgoingText() {
        let profile = build([msg("1", "hi", at: 0, fromMe: false)])
        XCTAssertEqual(profile.messageCount, 0)
        XCTAssertEqual(profile, .empty(scope: .conversation("Alice")))
    }

    // MARK: - Length

    func testLengthMetrics() {
        let profile = build([
            msg("1", "hey man", at: 0, fromMe: true),   // 2 words
            msg("2", "hey you", at: 10, fromMe: true),  // 2 words
            msg("3", "ok", at: 20, fromMe: true),       // 1 word
        ])
        XCTAssertEqual(profile.medianWordCount, 2)
        XCTAssertEqual(profile.shortShare, 1.0, accuracy: 0.0001) // all ≤ 3 words
        XCTAssertEqual(profile.longShare, 0.0, accuracy: 0.0001)
    }

    // MARK: - Mechanics

    func testLowercaseShare() {
        let profile = build([
            msg("1", "hey there", at: 0, fromMe: true), // lowercase
            msg("2", "Hello", at: 10, fromMe: true),    // has uppercase
            msg("3", "ok", at: 20, fromMe: true),       // lowercase
        ])
        XCTAssertEqual(profile.lowercaseShare, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testTerminalPunctuation() {
        let profile = build([
            msg("1", "yes.", at: 0, fromMe: true),
            msg("2", "what?", at: 10, fromMe: true),
            msg("3", "no!", at: 20, fromMe: true),
            msg("4", "maybe", at: 30, fromMe: true),
        ])
        XCTAssertEqual(profile.endsWithPeriodShare, 0.25, accuracy: 0.0001)
        XCTAssertEqual(profile.endsWithQuestionShare, 0.25, accuracy: 0.0001)
        XCTAssertEqual(profile.endsWithExclamationShare, 0.25, accuracy: 0.0001)
        XCTAssertEqual(profile.noTerminalPunctuationShare, 0.25, accuracy: 0.0001)
    }

    func testEmojiTally() {
        let profile = build([
            msg("1", "lol 😂😂", at: 0, fromMe: true),
            msg("2", "😅 ok", at: 10, fromMe: true),
            msg("3", "plain text", at: 20, fromMe: true),
        ])
        XCTAssertEqual(profile.emojiShare, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(profile.topEmoji.first?.value, "😂")
        XCTAssertEqual(profile.topEmoji.first?.count, 2)
    }

    /// ASCII digits are Unicode `isEmoji` but must not be tallied as emoji.
    func testDigitsAreNotEmoji() {
        let profile = build([msg("1", "call me at 5", at: 0, fromMe: true)])
        XCTAssertEqual(profile.emojiShare, 0.0, accuracy: 0.0001)
        XCTAssertTrue(profile.topEmoji.isEmpty)
    }

    // MARK: - Vocabulary

    func testOpenersClosersAndWords() {
        let profile = build([
            msg("1", "hey man", at: 0, fromMe: true),
            msg("2", "hey dude", at: 10, fromMe: true),
        ])
        XCTAssertEqual(profile.topOpeners.first?.value, "hey")
        XCTAssertEqual(profile.topOpeners.first?.count, 2)
        // "hey" clears the min-length and stop-word filters and leads word freq.
        XCTAssertEqual(profile.topWords.first?.value, "hey")
        XCTAssertEqual(Set(profile.topClosers.map(\.value)), ["man", "dude"])
    }

    // MARK: - Bursts & cadence

    /// Two of my texts within the burst window count; a reply between resets the
    /// run, so the message after it isn't a burst.
    func testBurstShare() {
        let profile = build([
            msg("1", "a", at: 0, fromMe: true),
            msg("2", "b", at: 60, fromMe: true),     // within window of #1
            msg("3", "x", at: 400, fromMe: false),   // their reply resets
            msg("4", "c", at: 500, fromMe: true),    // stands alone
        ])
        XCTAssertEqual(profile.burstShare, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testReplyMinutes() {
        let profile = build([
            msg("1", "you around?", at: 0, fromMe: false),
            msg("2", "yeah whats up", at: 300, fromMe: true), // 5 min later
        ])
        XCTAssertEqual(try XCTUnwrap(profile.medianReplyMinutes), 5.0, accuracy: 0.0001)
    }

    // MARK: - Samples

    /// Samples dedupe case-insensitively and preserve chronological order.
    func testSamplesDedupeAndOrder() {
        let profile = build([
            msg("1", "lol", at: 0, fromMe: true),
            msg("2", "LOL", at: 10, fromMe: true),  // dupe of #1
            msg("3", "hey", at: 20, fromMe: true),
            msg("4", "lol", at: 30, fromMe: true),  // dupe of #1
        ])
        XCTAssertEqual(profile.sampleMessages, ["lol", "hey"])
    }

    // MARK: - Global scope

    /// The global scan pulls only my messages (no incoming). Without turn
    /// boundaries, bursts and reply latency are meaningless and get suppressed.
    func testGlobalScopeSuppressesBurstAndReply() {
        let messages = [
            msg("1", "a", at: 0, fromMe: true),
            msg("2", "b", at: 30, fromMe: true),
            msg("3", "c", at: 60, fromMe: true),
        ]
        let profile = StyleProfileBuilder.build(from: messages, scope: .everyone, now: at(0))
        XCTAssertEqual(profile.messageCount, 3)
        XCTAssertEqual(profile.burstShare, 0, accuracy: 0.0001)
        XCTAssertNil(profile.medianReplyMinutes)
    }

    func testExporterOmitsBurstRowForGlobalScope() {
        let profile = StyleProfileBuilder.build(
            from: [msg("1", "hey there", at: 0, fromMe: true)],
            scope: .everyone,
            now: at(0)
        )
        let doc = StyleProfileExporter.export(profile, generatedAt: at(0))
        XCTAssertTrue(doc.contains("all your conversations"))
        XCTAssertFalse(doc.contains("**Bursts:**"))
    }

    /// Fixture provider gathers my outgoing texts from every thread for the
    /// global scan, and they build into a coherent profile.
    func testFixtureMyMessagesAcrossAllChats() async throws {
        let provider = FixtureProvider()
        let mine = try await provider.myMessages(limit: 4_000)
        XCTAssertFalse(mine.isEmpty)
        XCTAssertTrue(mine.allSatisfy(\.isOutgoing))

        let profile = StyleProfileBuilder.build(from: mine, scope: .everyone)
        XCTAssertEqual(profile.messageCount, mine.count)
        XCTAssertFalse(profile.sampleMessages.isEmpty)
    }

    // MARK: - Exporter

    func testExporterHasAllSections() {
        let profile = build([
            msg("1", "hey there", at: 0, fromMe: true),
            msg("2", "how's it going", at: 10, fromMe: true),
        ])
        let doc = StyleProfileExporter.export(profile, generatedAt: at(0))
        XCTAssertTrue(doc.hasPrefix("# How you text"))
        XCTAssertTrue(doc.contains("## Ready-to-use prompt"))
        XCTAssertTrue(doc.contains("You are writing text messages as me"))
        XCTAssertTrue(doc.contains("## Style at a glance"))
        XCTAssertTrue(doc.contains("## Sample messages"))
        XCTAssertTrue(doc.contains("> hey there"))
    }

    func testExporterEmptyProfile() {
        let doc = StyleProfileExporter.export(.empty(scope: .conversation("Alice")))
        XCTAssertTrue(doc.contains("No messages of yours"))
        XCTAssertFalse(doc.contains("## Sample messages"))
    }

    // MARK: - End to end

    /// Through the fixture provider: a real thread yields a coherent, non-empty
    /// profile with samples drawn from my own messages.
    func testFixtureProviderProducesProfile() async throws {
        let provider = FixtureProvider()
        let conversations = try await provider.conversations(page: ConversationPageRequest(limit: 100)).conversations
        let avery = try XCTUnwrap(conversations.first { $0.displayName == "Avery Chen" })
        let messages = try await provider.exportMessages(in: avery.id)

        let profile = StyleProfileBuilder.build(from: messages, scope: .conversation(avery.displayName))
        XCTAssertGreaterThan(profile.messageCount, 0)
        XCTAssertFalse(profile.sampleMessages.isEmpty)

        let doc = StyleProfileExporter.export(profile)
        XCTAssertTrue(doc.contains("How you text"))
    }
}
