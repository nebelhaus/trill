import Foundation

/// Lightweight subsequence fuzzy matcher for the command palette. Returns a
/// score (higher is better) when every query character appears in order within
/// the candidate, or `nil` when it doesn't match at all. Rewards contiguous
/// runs and word-boundary hits so "ac" ranks "Alice Chen" above "Marcia".
enum FuzzyMatch {
    /// Best score across several candidate strings (e.g. a conversation's name
    /// plus each participant handle).
    static func bestScore(_ query: String, _ candidates: [String]) -> Int? {
        candidates.compactMap { score(query, $0) }.max()
    }

    static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var total = 0
        var qi = 0
        var previousMatch = -2

        for (hi, character) in haystack.enumerated() where qi < needle.count {
            guard character == needle[qi] else { continue }

            var bonus = 1
            if hi == previousMatch + 1 { bonus += 5 }          // contiguous run
            if hi == 0 { bonus += 4 }                           // matches the very start
            else if isBoundary(haystack[hi - 1]) { bonus += 3 } // start of a word
            total += bonus
            previousMatch = hi
            qi += 1
        }

        guard qi == needle.count else { return nil }
        // A tighter span (match packed near the front) is a better hit.
        total -= previousMatch
        return total
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "_" || character == "." || character == "@"
    }
}
