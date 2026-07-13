import XCTest
@testable import NativeMessages

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
}
