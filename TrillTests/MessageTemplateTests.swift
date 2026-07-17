import Foundation
import XCTest
@testable import Trill

final class MessageTemplateTests: XCTestCase {
    private func labels(_ body: String) -> [String] {
        let ns = body as NSString
        return MessageTemplate.placeholderRanges(in: body).map { ns.substring(with: $0) }
    }

    func testFindsBlanksInOrder() {
        XCTAssertEqual(
            labels("Hi {name}, see you at {time}."),
            ["{name}", "{time}"]
        )
    }

    func testHasPlaceholders() {
        XCTAssertTrue(MessageTemplate.hasPlaceholders("On my way, {who}!"))
        XCTAssertFalse(MessageTemplate.hasPlaceholders("On my way!"))
    }

    func testIgnoresEmptyBracesAndLiteralBraces() {
        XCTAssertTrue(labels("nothing here {}").isEmpty)
        XCTAssertTrue(labels("code: func x() {}").isEmpty)
        XCTAssertTrue(labels("open { without close").isEmpty)
    }

    func testIgnoresBraceRunAcrossNewline() {
        XCTAssertTrue(labels("start {\n} end").isEmpty)
    }

    func testNextPlaceholderFromLocation() {
        let text = "Hi {name}, see you at {time}."
        // From the start we land on the first blank.
        XCTAssertEqual(text.nsSubstring(MessageTemplate.nextPlaceholder(in: text, from: 0)), "{name}")
        // Past the end of the first blank we skip to the second.
        let afterFirst = MessageTemplate.nextPlaceholder(in: text, from: 9)
        XCTAssertEqual(text.nsSubstring(afterFirst), "{time}")
        // Past the last blank there's nothing left.
        XCTAssertNil(MessageTemplate.nextPlaceholder(in: text, from: 28))
    }

    func testPreviousPlaceholderBeforeLocation() {
        let text = "Hi {name}, see you at {time}."
        // Before the second blank's start we get the first.
        XCTAssertEqual(text.nsSubstring(MessageTemplate.previousPlaceholder(in: text, before: 22)), "{name}")
        // Before the first blank's start there's nothing earlier.
        XCTAssertNil(MessageTemplate.previousPlaceholder(in: text, before: 3))
    }
}

private extension String {
    func nsSubstring(_ range: NSRange?) -> String? {
        guard let range else { return nil }
        return (self as NSString).substring(with: range)
    }
}
