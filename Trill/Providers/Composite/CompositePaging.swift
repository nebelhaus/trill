import Foundation

/// The one thing the composite needs of an item to merge two children's pages:
/// a sort date and a stable tiebreak. Conversations merge by recency, search
/// results by creation — same machinery, one implementation.
protocol CompositeMergeable: Codable, Sendable {
    var mergeDate: Date { get }
    var mergeTiebreak: String { get }
}

extension Conversation: CompositeMergeable {
    var mergeDate: Date { lastActivity }
    var mergeTiebreak: String { id.id }
}

extension Message: CompositeMergeable {
    var mergeDate: Date { createdAt }
    var mergeTiebreak: String { id.id }
}

/// The composite's opaque page cursor: where each child got to, plus the items
/// we fetched but couldn't safely emit yet.
///
/// Opaque, versioned, and forgiving by construction. Children can be added,
/// removed, or disabled between two calls, so:
///
/// - a key naming a child that's gone is ignored;
/// - a child that's *new* since the cursor was minted appears in neither
///   `childCursors` nor `exhausted`, and restarts from its own first page —
///   which is why `exhausted` is recorded explicitly rather than inferred from
///   "absent", the two being otherwise indistinguishable;
/// - a stored cursor a child now rejects (`FixtureProvider` throws
///   `.invalidCursor` on anything non-integer, so a mis-routed cursor is a *hard*
///   error, not a shrug) is reported as that child's failure and the rest of the
///   page still arrives.
///
/// `pending` carries whole items rather than a re-fetch offset: a child's page
/// isn't stably re-derivable (activity reorders it between calls), so the only
/// honest way to keep the remainder is to keep it. The cursor is caller-held for
/// the length of a paging loop and never persisted or logged.
struct CompositeCursor<Item: CompositeMergeable>: Codable, Sendable {
    static var currentVersion: Int { 1 }

    var version: Int
    /// child provider raw value → that child's own next cursor.
    var childCursors: [String: String]
    /// Children that reported no further pages. Distinguishes "done" from "new".
    var exhausted: [String]
    /// Fetched but not emitted, already in merge order.
    var pending: [Item]

    init(childCursors: [String: String], exhausted: [String], pending: [Item]) {
        version = Self.currentVersion
        self.childCursors = childCursors
        self.exhausted = exhausted
        self.pending = pending
    }

    /// Base64url-encoded JSON. Nil rather than throwing on any failure — an
    /// unencodable cursor should end the paging loop, never fail the page that
    /// produced it.
    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil for anything we can't read — malformed, or a version we don't know.
    /// The caller then starts over rather than throwing the page away.
    static func decode(_ value: String?) -> CompositeCursor<Item>? {
        guard let value else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64),
              let decoded = try? JSONDecoder().decode(CompositeCursor<Item>.self, from: data),
              decoded.version == currentVersion
        else { return nil }
        return decoded
    }
}

struct CompositePage<Item: CompositeMergeable>: Sendable {
    let items: [Item]
    let nextCursor: String?
    let failures: [ProviderFailure]
}

/// Merged, timestamp-ordered paging across an ordered set of children.
enum CompositePager {
    /// The provider an already-fetched item belongs to, so a page carried in a
    /// cursor can be re-checked against the children that still exist.
    private static func owner<Item: CompositeMergeable>(of item: Item) -> ProviderID? {
        switch item {
        case let conversation as Conversation: conversation.id.provider
        case let message as Message: message.id.provider
        default: nil
        }
    }

    /// One child's answer to a page request.
    struct ChildPage<Item: CompositeMergeable>: Sendable {
        let items: [Item]
        let nextCursor: String?

        init(items: [Item], nextCursor: String?) {
            self.items = items
            self.nextCursor = nextCursor
        }
    }

    /// Fetches `limit` from **every** active child, merges by date, and cuts the
    /// page at the earliest of the still-paging children's last-returned
    /// timestamps — past that boundary we cannot know whether an unfetched item
    /// from another child sorts first.
    ///
    /// Taking `limit / children.count` from each and interleaving would be
    /// cheaper and wrong: it silently loses conversations whenever the children's
    /// activity rates differ. A child that reported no next cursor is exhausted
    /// and contributes no boundary — which is also what makes a child that never
    /// paginates at all (`LiveIMessageProvider.conversations` always returns
    /// `nextCursor: nil`) work correctly here.
    ///
    /// The cut is inclusive of the boundary timestamp. Two items with the *same*
    /// timestamp across two children can therefore emit in tiebreak order rather
    /// than true order — the alternative, an exclusive cut, stalls forever on a
    /// page whose items all share one timestamp.
    static func page<Item: CompositeMergeable>(
        limit: Int,
        cursor: String?,
        children: [ProviderID],
        fetch: @Sendable (ProviderID, String?) async throws -> ChildPage<Item>
    ) async -> CompositePage<Item> {
        let decoded = CompositeCursor<Item>.decode(cursor)
        let exhausted = Set(decoded?.exhausted ?? [])
        // No readable cursor ⇒ first page: every child starts fresh.
        let active = children.filter { decoded == nil || !exhausted.contains($0.rawValue) }

        // Carried-over items from a child that's since been removed or disabled
        // are dropped rather than emitted: the user turned that provider off, and
        // a buffered page is not a reason for its threads to keep arriving.
        let known = Set(children.map(\.rawValue))
        var fetched: [Item] = (decoded?.pending ?? []).filter { item in
            owner(of: item).map { known.contains($0.rawValue) } ?? true
        }
        var nextChildCursors: [String: String] = [:]
        var nowExhausted: [String] = decoded?.exhausted.filter { raw in
            children.contains { $0.rawValue == raw }
        } ?? []
        var failures: [ProviderFailure] = []
        // Boundary contributions from children that may still have more.
        var boundaries: [Date] = []

        for child in active {
            let childCursor = decoded?.childCursors[child.rawValue]
            do {
                let page = try await fetch(child, childCursor)
                fetched.append(contentsOf: page.items)
                if let next = page.nextCursor {
                    nextChildCursors[child.rawValue] = next
                    // Only a child with more to give can surprise us below its
                    // last item; an exhausted one has already shown its hand.
                    if let oldest = page.items.map(\.mergeDate).min() {
                        boundaries.append(oldest)
                    }
                } else {
                    nowExhausted.append(child.rawValue)
                }
            } catch {
                failures.append(ProviderFailure(providerID: child, error: error))
                // Keep the child's position so a transient failure doesn't
                // silently restart it from the top on the next page.
                if let childCursor { nextChildCursors[child.rawValue] = childCursor }
            }
        }

        let merged = fetched.sorted { left, right in
            left.mergeDate == right.mergeDate
                ? left.mergeTiebreak < right.mergeTiebreak
                : left.mergeDate > right.mergeDate
        }

        let boundary = boundaries.min()
        let safe = boundary.map { limit in merged.prefix { $0.mergeDate >= limit } } ?? merged[...]
        let emitted = Array(safe.prefix(limit))
        let pending = Array(merged.dropFirst(emitted.count))

        let hasMore = !pending.isEmpty || !nextChildCursors.isEmpty
        let next = hasMore
            ? CompositeCursor(
                childCursors: nextChildCursors,
                exhausted: Array(Set(nowExhausted)),
                pending: pending
            ).encoded()
            : nil

        return CompositePage(items: emitted, nextCursor: next, failures: failures)
    }
}
