import Foundation

/// On speakers, the mic also hears the other people. This drops "Me" text that matches
/// what "Them" said in the last few seconds.
struct EchoFilter {
    private var recent: [(time: Date, words: [String])] = []
    private static let window: TimeInterval = 15
    private static let threshold = 0.6
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "do", "for", "i", "if", "in", "is", "it",
        "its", "it's", "me", "my", "of", "on", "or", "so", "that", "the", "this", "to", "uh", "um",
        "we", "you", "yeah", "yes", "no", "oh", "ok", "okay",
    ]

    mutating func addThem(_ text: String) {
        recent.append((Date(), Self.words(text)))
        prune()
    }

    /// `themPartial` is what "Them" is saying right now (not final yet).
    mutating func isEcho(_ text: String, themPartial: String?) -> Bool {
        prune()
        let mine = Self.words(text).filter { !Self.stopWords.contains($0) }
        guard mine.count >= 2 else { return false } // short replies ("yes", "sounds good") pass through
        var theirs = Set(recent.flatMap { $0.words })
        if let themPartial { theirs.formUnion(Self.words(themPartial)) }
        guard !theirs.isEmpty else { return false }
        let matched = mine.filter(theirs.contains).count
        return Double(matched) / Double(mine.count) >= Self.threshold
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-Self.window)
        recent.removeAll { $0.time < cutoff }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
