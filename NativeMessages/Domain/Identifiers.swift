import Foundation

struct ProviderID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

private protocol ProviderQualifiedIdentifier {
    var provider: ProviderID { get }
    var externalGUID: String { get }
}

private extension ProviderQualifiedIdentifier {
    var encodedKey: String {
        [provider.rawValue, externalGUID]
            .map { Data($0.utf8).base64URLEncodedString() }
            .joined(separator: ".")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}

struct ConversationID: Hashable, Codable, Sendable, ProviderQualifiedIdentifier, Identifiable {
    let provider: ProviderID
    let externalGUID: String

    var id: String { encodedKey }
    var persistenceKey: String { encodedKey }

    init(provider: ProviderID, externalGUID: String) {
        self.provider = provider
        self.externalGUID = externalGUID
    }

    init?(persistenceKey: String) {
        guard let values = Self.decode(persistenceKey) else { return nil }
        self.init(provider: ProviderID(rawValue: values.0), externalGUID: values.1)
    }

    private static func decode(_ key: String) -> (String, String)? {
        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let providerData = Data(base64URL: String(components[0])),
              let guidData = Data(base64URL: String(components[1])),
              let provider = String(data: providerData, encoding: .utf8),
              let guid = String(data: guidData, encoding: .utf8)
        else { return nil }
        return (provider, guid)
    }
}

struct MessageID: Hashable, Codable, Sendable, ProviderQualifiedIdentifier, Identifiable {
    let provider: ProviderID
    let externalGUID: String

    var id: String { encodedKey }
    var persistenceKey: String { encodedKey }

    init(provider: ProviderID, externalGUID: String) {
        self.provider = provider
        self.externalGUID = externalGUID
    }

    init?(persistenceKey: String) {
        let components = persistenceKey.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let providerData = Data(base64URL: String(components[0])),
              let guidData = Data(base64URL: String(components[1])),
              let provider = String(data: providerData, encoding: .utf8),
              let guid = String(data: guidData, encoding: .utf8)
        else { return nil }
        self.init(provider: ProviderID(rawValue: provider), externalGUID: guid)
    }
}

