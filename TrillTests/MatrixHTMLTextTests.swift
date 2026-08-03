import XCTest
@testable import Trill

/// `Message.text` arrives as Matrix HTML and the domain field is a plain
/// `String`. Getting this wrong either shows tags in the timeline or hands
/// unsanitized markup to something that renders it.
final class MatrixHTMLTextTests: XCTestCase {
    func testStripsTagsAndKeepsText() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "<p>hello</p>"), "hello")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "<em>a</em> <strong>b</strong>"), "a b")
    }

    func testBlockBoundariesBecomeSingleNewlines() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "<p>one</p><p>two</p>"), "one\ntwo")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "one<br/>two"), "one\ntwo")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "<ul><li>a</li><li>b</li></ul>"), "a\nb")
    }

    func testInlineTagsDoNotBreakLines() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "a<span>b</span>c"), "abc")
    }

    func testUnescapesEntities() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "a &amp; b"), "a & b")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "&lt;script&gt;"), "<script>")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "&#65;&#x42;"), "AB")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "a&nbsp;b"), "a b")
    }

    /// Script and style content is never message text. It must not survive as
    /// visible characters in a bubble.
    func testScriptAndStyleContentIsDropped() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "a<script>alert(1)</script>b"), "ab")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "<style>p{}</style>text"), "text")
    }

    func testMarkupNeverSurvivesIntoTheResult() {
        let hostile = "<img src=x onerror=alert(1)><a href='javascript:alert(1)'>click</a>"
        let result = MatrixHTMLText.plainText(from: hostile)

        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains("onerror"))
        XCTAssertEqual(result, "click")
    }

    func testMalformedInputDegradesRatherThanLoops() {
        XCTAssertEqual(MatrixHTMLText.plainText(from: "unclosed <b"), "unclosed <b")
        XCTAssertEqual(MatrixHTMLText.plainText(from: "&notanentity"), "&notanentity")
        XCTAssertEqual(MatrixHTMLText.plainText(from: ""), "")
    }

    func testInteriorNewlinesSurviveButRunsCollapse() {
        XCTAssertEqual(
            MatrixHTMLText.plainText(from: "<p>a</p><p></p><p></p><p>b</p>"),
            "a\nb",
            "empty blocks don't multiply into blank lines"
        )
        XCTAssertEqual(MatrixHTMLText.plainText(from: "  <p>a</p>  "), "a")
    }
}
