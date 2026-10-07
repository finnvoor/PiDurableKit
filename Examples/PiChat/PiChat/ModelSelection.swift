import Foundation
import PiDurableKit

/// Model search the way pi's model selector does it: `getModelSelectorSearchText` and `fuzzyFilter` (packages/tui).
nonisolated enum ModelSelection {
    /// The selector's text for a model, as pi's `getModelSelectorSearchText`.
    static func searchText(_ model: ModelInfo) -> String {
        let provider = model.provider.rawValue
        return "\(provider) \(provider)/\(model.modelId) \(provider) \(model.modelId) \(model.name)"
    }

    /// pi's `fuzzyFilter`: every whitespace- or slash-separated token must fuzzy-match; best matches first.
    static func search(_ models: [ModelInfo], for query: String) -> [ModelInfo] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).map(String.init)
        guard !tokens.isEmpty else { return models }
        var results: [(model: ModelInfo, score: Double)] = []
        for model in models {
            let text = searchText(model)
            var total = 0.0
            var matched = true
            for token in tokens {
                guard let score = fuzzyScore(token, in: text) else { matched = false; break }
                total += score
            }
            if matched { results.append((model, total)) }
        }
        return results.enumerated()
            .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score < $1.element.score }
            .map(\.element.model)
    }

    /// pi's `fuzzyMatch`: the query's characters in order, rewarding consecutive and word-boundary matches. Lower is
    /// better; nil when it doesn't match. Also tries letters and digits swapped ("4o" for "o4").
    static func fuzzyScore(_ query: String, in text: String) -> Double? {
        let query = query.lowercased()
        if let score = score(Array(query), in: Array(text.lowercased())) { return score }
        let letters = query.prefix(while: \.isLetter)
        let digits = query.prefix(while: \.isNumber)
        let swapped: String
        if !letters.isEmpty, query.dropFirst(letters.count).allSatisfy(\.isNumber), letters.count < query.count {
            swapped = String(query.dropFirst(letters.count) + letters)
        } else if !digits.isEmpty, query.dropFirst(digits.count).allSatisfy(\.isLetter), digits.count < query.count {
            swapped = String(query.dropFirst(digits.count) + digits)
        } else {
            return nil
        }
        return score(Array(swapped), in: Array(text.lowercased())).map { $0 + 5 }
    }

    private static func score(_ query: [Character], in text: [Character]) -> Double? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= text.count else { return nil }
        var score = 0.0
        var last = -1
        var consecutive = 0
        for character in query {
            guard let index = text[(last + 1)...].firstIndex(of: character) else { return nil }
            let boundary = index == 0 || " -_./:".contains(text[index - 1])
            if last == index - 1 {
                consecutive += 1
                score -= Double(consecutive * 5)
            } else {
                consecutive = 0
                if last >= 0 { score += Double((index - last - 1) * 2) }
            }
            if boundary { score -= 10 }
            score += Double(index) * 0.1
            last = index
        }
        if query == text { score -= 100 }
        return score
    }
}
