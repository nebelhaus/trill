import XCTest
@testable import NativeMessages

/// Covers the Universal Library: the pure `LinkExtractor` and the all-chats
/// `FixtureProvider.libraryItems` classification, mirroring the
/// `AdvancedSearchTests` template (assertions over the standard fixtures).
final class UniversalLibraryTests: XCTestCase {
    // MARK: - LinkExtractor

    func testExtractsHTTPAndBareDomain() {
        let urls = LinkExtractor.urls(in: "see https://example.com/a and example.org too")
        XCTAssertEqual(urls.map(\.absoluteString).sorted(),
                       ["https://example.com/a", "http://example.org"].sorted())
    }

    func testNoLinksInPlainText() {
        XCTAssertTrue(LinkExtractor.urls(in: "just a normal sentence, nothing here").isEmpty)
        XCTAssertTrue(LinkExtractor.urls(in: "").isEmpty)
    }

    func testPreservesAppearanceOrder() {
        let urls = LinkExtractor.urls(in: "first https://a.com then https://b.com")
        XCTAssertEqual(urls.map { $0.host() }, ["a.com", "b.com"])
    }

    // MARK: - FixtureProvider classification

    // `LibraryItem` collides with `DeveloperToolsSupport.LibraryItem` (pulled in
    // via SwiftUI); qualify it here where both are visible under @testable import.
    private func items(_ kind: LibraryKind, limit: Int = 500) async throws -> [NativeMessages.LibraryItem] {
        try await FixtureProvider().libraryItems(kind: kind, limit: limit)
    }

    func testImagesTabHoldsOnlyImageAttachments() async throws {
        let images = try await items(.image)
        XCTAssertFalse(images.isEmpty, "Fixtures include an image attachment")
        XCTAssertTrue(images.allSatisfy { $0.kind == .image })
        XCTAssertTrue(images.allSatisfy { $0.attachment?.isImage == true })
        XCTAssertTrue(images.allSatisfy { $0.url == nil })
    }

    func testFilesTabExcludesImagesAndCarriesAttachments() async throws {
        let files = try await items(.file)
        XCTAssertFalse(files.isEmpty, "Fixtures include a PDF and a text file")
        XCTAssertTrue(files.allSatisfy { $0.kind == .file })
        XCTAssertTrue(files.allSatisfy { $0.attachment?.isImage == false })
    }

    func testLinksTabExtractsURLsAndDedupesPerThread() async throws {
        let links = try await items(.link)
        XCTAssertFalse(links.isEmpty, "Fixtures include a shared https link")
        XCTAssertTrue(links.allSatisfy { $0.kind == .link && $0.url != nil })
        // One row per (conversation, URL): no duplicates within a thread.
        let keys = links.map { "\($0.conversationID.id)|\($0.url!.absoluteString)" }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testNewestFirstOrdering() async throws {
        let images = try await items(.image)
        XCTAssertEqual(images, images.sorted { $0.createdAt > $1.createdAt })
    }

    func testLimitIsRespected() async throws {
        let capped = try await items(.image, limit: 1)
        XCTAssertLessThanOrEqual(capped.count, 1)
    }

    // MARK: - LinkPreview OG parsing

    private let base = URL(string: "https://example.com/article")!

    func testParsesOpenGraphTags() {
        let html = """
        <html><head>
        <meta property="og:title" content="The Headline">
        <meta property="og:description" content="A short summary.">
        <meta property="og:image" content="https://cdn.example.com/a.jpg">
        <meta property="og:site_name" content="Example">
        </head><body>ignored</body></html>
        """
        let preview = LinkPreviewLoader.parse(html: html, baseURL: base)
        XCTAssertEqual(preview.title, "The Headline")
        XCTAssertEqual(preview.summary, "A short summary.")
        XCTAssertEqual(preview.imageURL?.absoluteString, "https://cdn.example.com/a.jpg")
        XCTAssertEqual(preview.siteName, "Example")
        XCTAssertFalse(preview.isEmpty)
    }

    func testAttributeOrderAndSingleQuotesAreTolerated() {
        let html = "<meta content='Backwards' property='og:title'>"
        XCTAssertEqual(LinkPreviewLoader.parse(html: html, baseURL: base).title, "Backwards")
    }

    func testResolvesRelativeImageAndDecodesEntities() {
        let html = """
        <meta property="og:title" content="Tom &amp; Jerry &#39;24">
        <meta property="og:image" content="/img/hero.png">
        """
        let preview = LinkPreviewLoader.parse(html: html, baseURL: base)
        XCTAssertEqual(preview.title, "Tom & Jerry '24")
        XCTAssertEqual(preview.imageURL?.absoluteString, "https://example.com/img/hero.png")
    }

    func testFallsBackToTitleAndMetaDescription() {
        let html = """
        <html><head><title>Plain Title</title>
        <meta name="description" content="Meta desc.">
        </head></html>
        """
        let preview = LinkPreviewLoader.parse(html: html, baseURL: base)
        XCTAssertEqual(preview.title, "Plain Title")
        XCTAssertEqual(preview.summary, "Meta desc.")
        // No og:image → image stays nil, but the host seeds a site name.
        XCTAssertNil(preview.imageURL)
        XCTAssertEqual(preview.siteName, "example.com")
    }

    func testPageWithoutMetadataIsEmpty() {
        let preview = LinkPreviewLoader.parse(html: "<html><body>nothing</body></html>", baseURL: base)
        XCTAssertNil(preview.title)
        XCTAssertNil(preview.summary)
        XCTAssertNil(preview.imageURL)
        XCTAssertTrue(preview.isEmpty)
    }
}
