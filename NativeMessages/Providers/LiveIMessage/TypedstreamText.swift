import Foundation

/// Extracts the plain-text body from a `message.attributedBody` blob.
///
/// Modern macOS leaves `message.text` NULL and stores the body as a legacy
/// NeXT "typedstream" archive of an NSAttributedString. Full decoding needs a
/// typedstream parser, but the body string always follows the NSString class
/// record and a `0x01 0x2B` ('+') marker, then a length, then UTF-8 bytes.
/// Validated against real chat.db rows before adoption.
enum TypedstreamText {
    static func extract(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard var i = payloadStart(in: bytes) else { return nil }
        guard i < bytes.count else { return nil }

        let length: Int
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8) | (Int(bytes[i + 3]) << 16) | (Int(bytes[i + 4]) << 24)
            i += 5
        case let byte:
            length = Int(byte)
            i += 1
        }

        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i ..< i + length], encoding: .utf8)
    }

    /// Strips attachment placeholders (U+FFFC) and trims whitespace, leaving
    /// the human-visible text.
    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func payloadStart(in bytes: [UInt8]) -> Int? {
        let needle = [UInt8]("NSString".utf8)
        var afterClassName: Int?
        outer: for i in 0 ..< max(0, bytes.count - needle.count) {
            for j in 0 ..< needle.count where bytes[i + j] != needle[j] { continue outer }
            afterClassName = i + needle.count
            break
        }
        guard var i = afterClassName else { return nil }
        while i + 1 < bytes.count {
            if bytes[i] == 0x01, bytes[i + 1] == 0x2B { return i + 2 }
            i += 1
        }
        return nil
    }
}
