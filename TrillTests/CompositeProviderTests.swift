import XCTest
@testable import Trill

/// A synthetic child for the composite: deterministic, paginated by integer
/// offset, and — deliberately — as unforgiving about a foreign cursor as
/// `FixtureProvider` is, so a mis-routed cursor shows up as the hard error it
/// really is rather than silently returning page one.
private actor StubProvider: MessagesProvider {
    nonisolated let id: ProviderID

    private let conversations: [Conversation]
    private let messages: [Message]
    /// When set, every paged read throws it instead of answering.
    private let failure: Error?
    private let sendCapable: Bool
    /// Conversation IDs this provider was asked about — the routing assertion.
    private(set) var seenConversationRequests: [ConversationID] = []
    private var continuations: [UUID: AsyncThrowingStream<ProviderEvent, Error>.Continuation] = [:]
    private(set) var resumedFrom: EventCursor?

    init(
        id: String,
        conversations: [Conversation] = [],
        messages: [Message] = [],
        failure: Error? = nil,
        sendCapable: Bool = false
    ) {
        self.id = ProviderID(rawValue: id)
        self.conversations = conversations
        self.messages = messages
        self.failure = failure
        self.sendCapable = sendCapable
    }

    func health() async -> ProviderHealth {
        failure == nil
            ? .fixture
            : ProviderHealth(
                messagesDatabase: .fixture,
                liveEvents: .fixture,
                sending: .disabled,
                contacts: .notRequested,
                notifications: .notRequested,
                remoteRelay: HealthState(
                    availability: .unavailable,
                    reason: .providerFailure,
                    recoverySuggestion: nil
                )
            )
    }

    func capabilities() async -> ProviderCapabilities {
        var values: Set<ProviderCapability> = [.readConversations, .readMessages, .search, .watchLiveEvents]
        if sendCapable { values.insert(.sendText) }
        return ProviderCapabilities(values)
    }

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        if let failure { throw failure }
        let offset = try Self.offset(page.cursor)
        let ordered = conversations.sorted { $0.lastActivity > $1.lastActivity }
        let end = min(offset + page.limit, ordered.count)
        guard offset <= ordered.count else { throw MessagesProviderError.invalidCursor }
        return ConversationPage(
            conversations: Array(ordered[offset..<end]),
            nextCursor: end < ordered.count ? String(end) : nil
        )
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        seenConversationRequests.append(conversation)
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        return MessagePage(messages: messages, nextBefore: nil)
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        if let failure { throw failure }
        let offset = try Self.offset(query.cursor)
        let ordered = messages.sorted { $0.createdAt > $1.createdAt }
        guard offset <= ordered.count else { throw MessagesProviderError.invalidCursor }
        let end = min(offset + query.limit, ordered.count)
        return MessageSearchPage(
            messages: Array(ordered[offset..<end]),
            nextCursor: end < ordered.count ? String(end) : nil
        )
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        resumedFrom = cursor
        let token = UUID()
        return AsyncThrowingStream { continuation in
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.drop(token) }
            }
        }
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        seenConversationRequests.append(request.conversationID)
        return .accepted(operationID: request.operationID)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func emit(_ event: ProviderEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    private func drop(_ token: UUID) { continuations.removeValue(forKey: token) }

    private static func offset(_ cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value >= 0 else { throw MessagesProviderError.invalidCursor }
        return value
    }
}

// MARK: - Builders

private let epoch = Date(timeIntervalSince1970: 1_735_689_600)

private func conversation(
    _ provider: String,
    _ guid: String,
    minutes: Double,
    service: ServiceIdentity = .iMessage
) -> Conversation {
    Conversation(
        id: ConversationID(provider: ProviderID(rawValue: provider), externalGUID: guid),
        displayName: "\(provider)/\(guid)",
        systemName: nil,
        participants: [],
        kind: .direct,
        service: service,
        lastActivity: epoch.addingTimeInterval(minutes * 60),
        lastMessagePreview: "",
        unreadCount: nil,
        lastMessageFromMe: true,
        reactedToLatestInbound: false
    )
}

private func message(_ provider: String, _ guid: String, minutes: Double) -> Message {
    let providerID = ProviderID(rawValue: provider)
    return Message(
        id: MessageID(provider: providerID, externalGUID: guid),
        conversationID: ConversationID(provider: providerID, externalGUID: "c"),
        providerSequence: guid,
        sender: nil,
        isOutgoing: false,
        text: "\(provider)/\(guid)",
        createdAt: epoch.addingTimeInterval(minutes * 60),
        sentAt: nil,
        deliveredAt: nil,
        attachments: [],
        reactions: [],
        replyTo: nil,
        threadOrigin: nil,
        service: .iMessage,
        deliveryState: .unknown
    )
}

private actor Collector {
    private(set) var values: [String] = []

    @discardableResult
    func append(_ value: String) -> Int {
        values.append(value)
        return values.count
    }
}

final class CompositeProviderTests: XCTestCase {
    // MARK: - Merged paging

    /// Interleaved timestamps across two children with very different activity
    /// rates: A owns the newest and oldest, B everything between. Taking half a
    /// page from each and zipping would drop items; over-fetching and cutting at
    /// the earliest still-paging child's last timestamp doesn't.
    func testMergedPagingInterleavesByRecencyWithoutLoss() async throws {
        let a = StubProvider(id: "a", conversations: (0..<6).map {
            conversation("a", "a\($0)", minutes: Double($0) * 20)
        })
        let b = StubProvider(id: "b", conversations: (0..<6).map {
            conversation("b", "b\($0)", minutes: Double($0) * 20 + 10)
        })
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        var gathered: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await composite.conversations(
                page: ConversationPageRequest(limit: 3, cursor: cursor)
            )
            XCTAssertTrue(page.failures.isEmpty)
            gathered.append(contentsOf: page.conversations.map(\.id.externalGUID))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 20

        XCTAssertEqual(gathered.count, 12, "no conversation may be lost across the merge")
        XCTAssertEqual(Set(gathered).count, 12, "and none may be emitted twice")
        XCTAssertEqual(
            gathered,
            ["b5", "a5", "b4", "a4", "b3", "a3", "b2", "a2", "b1", "a1", "b0", "a0"],
            "strict newest-first interleave"
        )
    }

    /// A child that never paginates at all (`LiveIMessageProvider.conversations`
    /// always returns `nextCursor: nil`) must still merge correctly — it simply
    /// contributes no cut boundary, because it can't surprise us later.
    func testChildThatNeverPaginatesStillMergesFully() async throws {
        let paging = StubProvider(id: "paging", conversations: (0..<5).map {
            conversation("paging", "p\($0)", minutes: Double($0) * 10)
        })
        let oneShot = OneShotProvider(id: "oneshot", conversations: (0..<3).map {
            conversation("oneshot", "o\($0)", minutes: Double($0) * 10 + 5)
        })
        let composite = CompositeMessagesProvider(children: [paging, oneShot], primary: paging.id)

        var gathered: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await composite.conversations(
                page: ConversationPageRequest(limit: 2, cursor: cursor)
            )
            gathered.append(contentsOf: page.conversations.map(\.id.externalGUID))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 20

        XCTAssertEqual(Set(gathered).count, 8)
        XCTAssertEqual(gathered.first, "p4")
    }

    /// A single-child composite is behaviorally the child. This is what lets live
    /// mode become the composite before there is a second provider to aggregate.
    func testSingleChildCompositeIsTransparent() async throws {
        let fixture = FixtureProvider()
        let composite = CompositeMessagesProvider(children: [fixture], primary: fixture.id)

        let direct = try await fixture.conversations(page: ConversationPageRequest(limit: 10))
        let merged = try await composite.conversations(page: ConversationPageRequest(limit: 10))

        XCTAssertEqual(merged.conversations.map(\.id), direct.conversations.map(\.id))
        XCTAssertTrue(merged.failures.isEmpty)
    }

    // MARK: - Routing

    func testPerConversationCallsNeverReachTheWrongChild() async throws {
        let a = StubProvider(id: "a", messages: [message("a", "m1", minutes: 1)])
        let b = StubProvider(id: "b", messages: [message("b", "m1", minutes: 2)])
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let target = ConversationID(provider: ProviderID(rawValue: "b"), externalGUID: "chat")
        let page = try await composite.messages(in: target, page: MessagePageRequest(limit: 10))

        XCTAssertEqual(page.messages.map(\.id.provider.rawValue), ["b"])
        let seenByA = await a.seenConversationRequests
        let seenByB = await b.seenConversationRequests
        XCTAssertTrue(seenByA.isEmpty, "provider A must never be asked about B's conversation")
        XCTAssertEqual(seenByB, [target])
    }

    func testUnknownProviderRoutesToWrongProviderRatherThanAGuess() async {
        let a = StubProvider(id: "a")
        let composite = CompositeMessagesProvider(children: [a], primary: a.id)
        let orphan = ConversationID(provider: ProviderID(rawValue: "gone"), externalGUID: "chat")

        do {
            _ = try await composite.messages(in: orphan, page: MessagePageRequest(limit: 10))
            XCTFail("expected a routing failure")
        } catch let error as MessagesProviderError {
            guard case .wrongProvider = error else {
                return XCTFail("expected .wrongProvider, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The composite's own `ProviderID` must never end up inside an identifier —
    /// that would re-key every overlay row (pins, drafts, folders, saved
    /// messages, read marks, restored tabs) for the thread.
    func testCompositeNeverRequalifiesIdentifiers() async throws {
        let a = StubProvider(id: "a", conversations: [conversation("a", "a0", minutes: 1)])
        let b = StubProvider(id: "b", conversations: [conversation("b", "b0", minutes: 2)])
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let page = try await composite.conversations(page: ConversationPageRequest(limit: 10))
        let providers = Set(page.conversations.map(\.id.provider.rawValue))

        XCTAssertEqual(providers, ["a", "b"])
        XCTAssertFalse(providers.contains(composite.id.rawValue))
    }

    // MARK: - Search

    func testMergedSearchOrdersByRecencyAcrossChildren() async throws {
        let a = StubProvider(id: "a", messages: [
            message("a", "a-old", minutes: 1),
            message("a", "a-new", minutes: 30),
        ])
        let b = StubProvider(id: "b", messages: [
            message("b", "b-mid", minutes: 15),
            message("b", "b-newest", minutes: 45),
        ])
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let page = try await composite.search(MessageSearchQuery(text: "provider", limit: 10))

        XCTAssertEqual(
            page.messages.map(\.id.externalGUID),
            ["b-newest", "a-new", "b-mid", "a-old"]
        )
    }

    func testConversationScopedSearchGoesStraightToTheOwner() async throws {
        let a = StubProvider(id: "a", messages: [message("a", "a1", minutes: 1)])
        let b = StubProvider(id: "b", messages: [message("b", "b1", minutes: 2)])
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let scope = ConversationID(provider: ProviderID(rawValue: "b"), externalGUID: "c")
        let page = try await composite.search(
            MessageSearchQuery(text: "provider", conversationID: scope, limit: 10)
        )

        XCTAssertEqual(page.messages.map(\.id.provider.rawValue), ["b"])
    }

    // MARK: - Partial failure

    func testOneChildFailingStillDeliversTheOther() async throws {
        let good = StubProvider(id: "good", conversations: [
            conversation("good", "g0", minutes: 5),
            conversation("good", "g1", minutes: 10),
        ])
        let bad = StubProvider(id: "bad", failure: MessagesProviderError.unavailable("offline"))
        let composite = CompositeMessagesProvider(children: [good, bad], primary: good.id)

        let page = try await composite.conversations(page: ConversationPageRequest(limit: 10))

        XCTAssertEqual(page.conversations.map(\.id.externalGUID), ["g1", "g0"])
        XCTAssertEqual(page.failures.map(\.providerID.rawValue), ["bad"])
        XCTAssertFalse(
            page.failures.contains { $0.category.contains("offline") },
            "the failure sidecar carries a type name, never the error's message"
        )
    }

    func testSearchFailureIsReportedRatherThanThrown() async throws {
        let good = StubProvider(id: "good", messages: [message("good", "m", minutes: 3)])
        let bad = StubProvider(id: "bad", failure: MessagesProviderError.unavailable("offline"))
        let composite = CompositeMessagesProvider(children: [good, bad], primary: good.id)

        let page = try await composite.search(MessageSearchQuery(text: "provider", limit: 10))

        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.failures.map(\.providerID.rawValue), ["bad"])
    }

    // MARK: - Cursor

    func testCursorRoundTripsThroughEncoding() throws {
        let original = CompositeCursor<Conversation>(
            childCursors: ["a": "12", "b": "7"],
            exhausted: ["c"],
            pending: [conversation("a", "a9", minutes: 4)]
        )
        let decoded = try XCTUnwrap(CompositeCursor<Conversation>.decode(original.encoded()))

        XCTAssertEqual(decoded.version, CompositeCursor<Conversation>.currentVersion)
        XCTAssertEqual(decoded.childCursors, original.childCursors)
        XCTAssertEqual(decoded.exhausted, original.exhausted)
        XCTAssertEqual(decoded.pending.map(\.id), original.pending.map(\.id))
    }

    func testMalformedCursorRestartsRatherThanThrowing() async throws {
        let a = StubProvider(id: "a", conversations: [conversation("a", "a0", minutes: 1)])
        let composite = CompositeMessagesProvider(children: [a], primary: a.id)

        let page = try await composite.conversations(
            page: ConversationPageRequest(limit: 5, cursor: "not-a-cursor")
        )

        XCTAssertEqual(page.conversations.count, 1)
        XCTAssertTrue(page.failures.isEmpty)
    }

    /// A cursor minted when a child existed, replayed after it's gone. The
    /// vanished child's entry is ignored and the surviving children still page.
    func testCursorNamingAVanishedChildStillPages() async throws {
        let a = StubProvider(id: "a", conversations: (0..<4).map {
            conversation("a", "a\($0)", minutes: Double($0))
        })
        let b = StubProvider(id: "b", conversations: (0..<4).map {
            conversation("b", "b\($0)", minutes: Double($0) + 0.5)
        })
        let both = CompositeMessagesProvider(children: [a, b], primary: a.id)
        let first = try await both.conversations(page: ConversationPageRequest(limit: 2))
        let cursor = try XCTUnwrap(first.nextCursor)

        // B is gone by the time the cursor comes back.
        let onlyA = CompositeMessagesProvider(children: [a], primary: a.id)
        let second = try await onlyA.conversations(
            page: ConversationPageRequest(limit: 4, cursor: cursor)
        )

        XCTAssertTrue(second.failures.isEmpty, "a departed child is not a failure")
        XCTAssertTrue(
            second.conversations.allSatisfy { $0.id.provider.rawValue == "a" },
            "and the surviving child keeps paging"
        )
    }

    /// The reason `exhausted` is recorded explicitly rather than inferred: a
    /// child added *after* a cursor was minted appears in neither list, and must
    /// restart from its own first page rather than be treated as finished.
    func testChildAddedAfterTheCursorRestartsRatherThanBeingSkipped() async throws {
        let a = StubProvider(id: "a", conversations: (0..<4).map {
            conversation("a", "a\($0)", minutes: Double($0))
        })
        let onlyA = CompositeMessagesProvider(children: [a], primary: a.id)
        let first = try await onlyA.conversations(page: ConversationPageRequest(limit: 2))
        let cursor = try XCTUnwrap(first.nextCursor)

        let b = StubProvider(id: "b", conversations: [conversation("b", "b0", minutes: 99)])
        let both = CompositeMessagesProvider(children: [a, b], primary: a.id)
        let second = try await both.conversations(
            page: ConversationPageRequest(limit: 10, cursor: cursor)
        )

        XCTAssertTrue(
            second.conversations.contains { $0.id.externalGUID == "b0" },
            "the newly-added child must contribute, not be assumed exhausted"
        )
    }

    /// A child cursor handed to the wrong child is a *hard* error, not a shrug —
    /// so the composite must never let one leak sideways. Feeding a cursor whose
    /// only entry names a child that rejects it proves the failure is contained.
    func testAChildRejectingItsCursorFailsOnlyThatChild() async throws {
        let strict = StubProvider(id: "strict", conversations: [conversation("strict", "s0", minutes: 1)])
        let fine = StubProvider(id: "fine", conversations: [conversation("fine", "f0", minutes: 2)])
        let composite = CompositeMessagesProvider(children: [strict, fine], primary: fine.id)

        let poisoned = CompositeCursor<Conversation>(
            childCursors: ["strict": "definitely-not-an-integer"],
            exhausted: [],
            pending: []
        )
        let page = try await composite.conversations(
            page: ConversationPageRequest(limit: 5, cursor: poisoned.encoded())
        )

        XCTAssertEqual(page.failures.map(\.providerID.rawValue), ["strict"])
        XCTAssertEqual(page.conversations.map(\.id.externalGUID), ["f0"])
    }

    // MARK: - Events

    func testMergedEventsCarryBothChildrenAndDedupe() async throws {
        let a = StubProvider(id: "a")
        let b = StubProvider(id: "b")
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let stream = await composite.events(resumingFrom: [:])
        let collected = Collector()
        let collector = Task {
            for try await event in stream {
                guard case let .messageAdded(message, _) = event else { continue }
                if await collected.append(message.id.externalGUID) == 3 { break }
            }
        }
        // Let both children register their continuations before emitting.
        try await Task.sleep(for: .milliseconds(50))
        await a.emit(.messageAdded(message("a", "a1", minutes: 1), cursor: EventCursor(rawValue: "a1")))
        await b.emit(.messageAdded(message("b", "b1", minutes: 2), cursor: EventCursor(rawValue: "b1")))
        await b.emit(.messageAdded(message("b", "b2", minutes: 3), cursor: EventCursor(rawValue: "b2")))
        try await collector.value

        let received = await collected.values
        XCTAssertEqual(Set(received), ["a1", "b1", "b2"])
        XCTAssertEqual(received.count, 3, "the repository dedupes by id; the merge must not duplicate either")
    }

    func testEachChildResumesFromItsOwnCursor() async throws {
        let a = StubProvider(id: "a")
        let b = StubProvider(id: "b")
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        let stream = await composite.events(resumingFrom: [
            ProviderID(rawValue: "a"): EventCursor(rawValue: "cursor-a"),
            ProviderID(rawValue: "b"): EventCursor(rawValue: "cursor-b"),
        ])
        let drain = Task { for try await _ in stream {} }
        try await Task.sleep(for: .milliseconds(50))

        let resumedA = await a.resumedFrom
        let resumedB = await b.resumedFrom
        XCTAssertEqual(resumedA?.rawValue, "cursor-a")
        XCTAssertEqual(resumedB?.rawValue, "cursor-b")
        drain.cancel()
    }

    func testEventCursorProvidersListsTheChildrenNotTheComposite() async {
        let a = StubProvider(id: "a")
        let b = StubProvider(id: "b")
        let composite = CompositeMessagesProvider(children: [a, b], primary: a.id)

        XCTAssertEqual(composite.eventCursorProviders.map(\.rawValue), ["a", "b"])
    }

    // MARK: - Health & capabilities

    /// The whole point of the primary/degraded split: a remote child being down
    /// must not reach the health dimensions `InboxModel.load` turns into a
    /// full-screen recovery view.
    func testARemoteChildFailingDegradesRatherThanBlocks() async {
        let native = StubProvider(id: "native")
        let remote = StubProvider(id: "remote", failure: MessagesProviderError.unavailable("offline"))
        let composite = CompositeMessagesProvider(children: [native, remote], primary: native.id)

        let health = await composite.health()

        XCTAssertEqual(health.messagesDatabase.availability, .available)
        XCTAssertNotEqual(health.messagesDatabase.reason, .providerFailure)
        XCTAssertEqual(health.degraded.map(\.providerID.rawValue), ["remote"])
        XCTAssertEqual(health.degraded.first?.state.availability, .unavailable)
    }

    func testCapabilitiesAreUnionedGloballyButRoutedPerConversation() async {
        let reader = StubProvider(id: "reader")
        let sender = StubProvider(id: "sender", sendCapable: true)
        let composite = CompositeMessagesProvider(children: [reader, sender], primary: sender.id)

        let global = await composite.capabilities()
        XCTAssertTrue(global.supports(.sendText))

        let readOnlyThread = ConversationID(provider: ProviderID(rawValue: "reader"), externalGUID: "c")
        let scoped = await composite.capabilities(for: readOnlyThread)
        XCTAssertFalse(
            scoped.supports(.sendText),
            "a read-only thread must not inherit a sibling provider's send capability"
        )
    }
}

/// A child that hands back everything it has in one shot and never paginates —
/// exactly `LiveIMessageProvider.conversations`' shape.
private actor OneShotProvider: MessagesProvider {
    nonisolated let id: ProviderID
    private let conversations: [Conversation]

    init(id: String, conversations: [Conversation]) {
        self.id = ProviderID(rawValue: id)
        self.conversations = conversations
    }

    func health() async -> ProviderHealth { .fixture }
    func capabilities() async -> ProviderCapabilities { ProviderCapabilities([.readConversations]) }

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        ConversationPage(
            conversations: conversations.sorted { $0.lastActivity > $1.lastActivity },
            nextCursor: nil
        )
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        MessagePage(messages: [], nextBefore: nil)
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        MessageSearchPage(messages: [], nextCursor: nil)
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }
}
