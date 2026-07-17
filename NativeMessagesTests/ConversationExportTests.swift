import XCTest
@testable import NativeMessages

final class ConversationExportTests: XCTestCase {
    /// UTC so day grouping and range boundaries are independent of the test
    /// machine's locale.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-07-15 00:00:00 UTC.
    private let epoch = Date(timeIntervalSince1970: 1_784_073_600)
    private let day: TimeInterval = 86_400

    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private let provider = ProviderID(rawValue: "fixture")
    private var conversationID: ConversationID {
        ConversationID(provider: provider, externalGUID: "export-thread")
    }

    private func conversation(name: String = "Alice") -> Conversation {
        Conversation(
            id: conversationID,
            displayName: name,
            systemName: nil,
            participants: [Participant(id: "p1", displayName: "Alice", handle: "+15551234567")],
            kind: .direct,
            service: .iMessage,
            lastActivity: at(0),
            lastMessagePreview: "",
            unreadCount: nil,
            lastMessageFromMe: false,
            reactedToLatestInbound: false
        )
    }

    private func message(
        _ id: String,
        text: String,
        at offset: TimeInterval,
        fromMe: Bool = false,
        senderName: String? = "Alice",
        attachments: [MessageAttachment] = [],
        reactions: [MessageReaction] = [],
        edited: Bool = false
    ) -> Message {
        Message(
            id: MessageID(provider: provider, externalGUID: id),
            conversationID: conversationID,
            providerSequence: id,
            sender: fromMe ? nil : senderName.map { Participant(id: "p1", displayName: $0, handle: "+15551234567") },
            isOutgoing: fromMe,
            text: text,
            createdAt: at(offset),
            sentAt: nil,
            deliveredAt: nil,
            attachments: attachments,
            reactions: reactions,
            replyTo: nil,
            threadOrigin: nil,
            service: .iMessage,
            deliveryState: .delivered,
            isEdited: edited
        )
    }

    private func thread() -> [Message] {
        [
            message("m2", text: "Coffee at the usual place?", at: 40),
            message("m0", text: "Let's grab coffee tomorrow", at: 0),
            message("m1", text: "Sounds good, morning works", at: 20, fromMe: true),
        ]
    }

    // MARK: - Ordering & sender labels

    func testFilterSortsChronologicallyRegardlessOfInputOrder() {
        let ordered = ConversationExporter.filter(thread(), range: nil)
        XCTAssertEqual(ordered.map(\.id.externalGUID), ["m0", "m1", "m2"])
    }

    func testPlainTextLabelsOutgoingAsYouAndIncomingBySender() {
        let text = ConversationExporter.export(
            conversation: conversation(),
            messages: thread(),
            format: .plainText,
            generatedAt: at(0),
            calendar: calendar
        )
        // Chronological: Alice's first line precedes the "You" reply.
        let aliceIndex = try! XCTUnwrap(text.range(of: "Alice: Let's grab coffee")).lowerBound
        let youIndex = try! XCTUnwrap(text.range(of: "You: Sounds good")).lowerBound
        XCTAssertLessThan(aliceIndex, youIndex)
        XCTAssertTrue(text.contains("Conversation with Alice"))
        XCTAssertTrue(text.contains("3 messages"))
    }

    // MARK: - Date-range filtering

    func testDateRangeClipsToWindow() {
        let messages = [
            message("d0", text: "day 0", at: 0),
            message("d1", text: "day 1", at: day),
            message("d2", text: "day 2", at: 2 * day),
        ]
        // Inclusive window covering only day 1.
        let range = at(day)...at(day + 3600)
        let selected = ConversationExporter.filter(messages, range: range)
        XCTAssertEqual(selected.map(\.id.externalGUID), ["d1"])
    }

    func testEmptyRangeRendersPlaceholderNotMessages() {
        let text = ConversationExporter.export(
            conversation: conversation(),
            messages: thread(),
            format: .plainText,
            range: at(10 * day)...at(11 * day),
            generatedAt: at(0),
            calendar: calendar
        )
        XCTAssertTrue(text.contains("No messages in this range."))
        XCTAssertFalse(text.contains("Coffee at the usual place"))
        XCTAssertTrue(text.contains("0 messages"))
    }

    // MARK: - Attachments & reactions

    func testPlainTextRendersAttachmentsAndReactions() {
        let attachment = MessageAttachment(
            id: "a1",
            displayName: "photo.jpg",
            mimeType: "image/jpeg",
            uniformTypeIdentifier: "public.jpeg",
            byteCount: 1024,
            localURL: nil,
            availability: .available,
            isImage: true
        )
        let reaction = MessageReaction(id: "r1", kind: .love, senderDisplayName: "Alice", glyph: "❤️")
        let messages = [
            message("m0", text: "check this out", at: 0, fromMe: true, attachments: [attachment], reactions: [reaction]),
        ]
        let text = ConversationExporter.export(
            conversation: conversation(),
            messages: messages,
            format: .plainText,
            generatedAt: at(0),
            calendar: calendar
        )
        XCTAssertTrue(text.contains("Image: photo.jpg"))
        XCTAssertTrue(text.contains("❤️ Alice"))
    }

    // MARK: - HTML

    func testHtmlEscapesUnsafeCharacters() {
        let messages = [message("m0", text: "<b>hi</b> & \"q\"", at: 0)]
        let html = ConversationExporter.export(
            conversation: conversation(),
            messages: messages,
            format: .html,
            generatedAt: at(0),
            calendar: calendar
        )
        XCTAssertTrue(html.contains("&lt;b&gt;hi&lt;/b&gt; &amp; &quot;q&quot;"))
        // The raw, unescaped body must never appear as literal markup.
        XCTAssertFalse(html.contains("<b>hi</b>"))
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
    }

    // MARK: - Markdown

    func testMarkdownHasTitleAndBlockquotedBody() {
        let md = ConversationExporter.export(
            conversation: conversation(),
            messages: thread(),
            format: .markdown,
            generatedAt: at(0),
            calendar: calendar
        )
        XCTAssertTrue(md.contains("# Conversation with Alice"))
        XCTAssertTrue(md.contains("**You** ·"))
        XCTAssertTrue(md.contains("> Sounds good, morning works"))
    }

    // MARK: - Filenames

    func testFilenameStemSanitizesAndAppendsRange() {
        let convo = conversation(name: "Team: iOS/UX")
        let plain = ConversationExporter.filenameStem(for: convo, calendar: calendar)
        XCTAssertFalse(plain.contains("/"))
        XCTAssertFalse(plain.contains(":"))

        let ranged = ConversationExporter.filenameStem(
            for: convo,
            range: at(0)...at(2 * day),
            calendar: calendar
        )
        XCTAssertTrue(ranged.contains("2026-07-15"))
        XCTAssertTrue(ranged.contains("2026-07-17"))
    }
}
