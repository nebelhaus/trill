import Foundation

/// Pure ranking logic for the command palette, kept out of the view so it can
/// be unit-tested directly. An empty query shows recent conversations followed
/// by the full action catalog; a non-empty query fuzzy-ranks conversations and
/// actions together and always ends with a hand-off to full message search.
enum PaletteRanking {
    static let recentLimit = 7

    static func items(
        query rawQuery: String,
        conversations: [Conversation],
        actions: [PaletteAction]
    ) -> [PaletteItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let recents = conversations.prefix(recentLimit).map(PaletteItem.conversation)
            return recents + actions.map(PaletteItem.action)
        }

        var scored: [(item: PaletteItem, score: Int, isConversation: Bool)] = []
        for conversation in conversations {
            if let score = FuzzyMatch.bestScore(query, conversation.searchableStrings) {
                scored.append((.conversation(conversation), score, true))
            }
        }
        for action in actions {
            if let score = FuzzyMatch.score(query, action.title) {
                scored.append((.action(action), score, false))
            }
        }
        // Higher score first; conversations win ties so jumping stays snappy.
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : (lhs.isConversation && !rhs.isConversation)
        }
        return scored.map(\.item) + [.searchMessages(query)]
    }
}

extension Conversation {
    /// Names and handles a fuzzy palette query can match against.
    var searchableStrings: [String] {
        var strings = [displayName]
        if let systemName { strings.append(systemName) }
        for participant in participants {
            if let name = participant.displayName { strings.append(name) }
            strings.append(participant.handle)
        }
        return strings
    }
}
