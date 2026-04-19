import Foundation

enum FuzzyMatcher {
    static func score(query: String, candidate: String) -> Int? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return 0 }

        let needle = trimmedQuery.lowercased()
        let haystack = candidate.lowercased()
        guard !haystack.isEmpty else { return nil }

        if haystack == needle {
            return 1_000
        }

        if haystack.hasPrefix(needle) {
            return 800 - max(0, haystack.count - needle.count)
        }

        if let range = haystack.range(of: needle) {
            let distance = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return 600 - distance
        }

        var score = 0
        var searchStart = haystack.startIndex

        for char in needle {
            guard let index = haystack[searchStart...].firstIndex(of: char) else {
                return nil
            }
            let distance = haystack.distance(from: searchStart, to: index)
            score += max(1, 40 - distance)
            searchStart = haystack.index(after: index)
        }

        return 300 + score
    }
}
