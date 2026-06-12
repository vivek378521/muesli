import Foundation
import MuesliCore

/// Mines historical dictation text for words that are candidates for the
/// personal dictionary — frequently transcribed terms that aren't already known
/// and that a standard lexicon doesn't recognize.
///
/// This type is deliberately **pure**: it takes the corpus and two predicates as
/// inputs and returns suggestions, with no I/O and no `NSSpellChecker` dependency
/// (which is main-thread-only). The caller injects `isSpelledCorrectly` and
/// `suggestCorrection`, runs the heavy clustering off the main thread, and runs
/// the cheap spell pass on the main thread.
enum WordSuggestionAnalyzer {

    /// Minimum number of occurrences (summed across a phonetic cluster) before a
    /// word is surfaced as a suggestion.
    static let minOccurrences = 3

    /// Jaro-Winkler similarity above which two candidate words are treated as
    /// spellings of the same word and merged into one cluster.
    static let clusterSimilarityThreshold = 0.85

    /// Cap on the number of unique candidate tokens fed into the O(k²) clustering
    /// step, keeping analysis bounded on large corpora.
    static let maxUniqueTokens = 1000

    /// Analyze a corpus of dictations and return suggestions to persist.
    ///
    /// - Parameters:
    ///   - dictations: raw text + the ASR backend identifier that produced it.
    ///   - customWords: the user's existing dictionary; matching tokens are skipped.
    ///   - dismissedOrAccepted: lowercased words the user has already ruled on.
    ///   - isSpelledCorrectly: returns true if a standard lexicon knows the word
    ///     (such words are dropped — they aren't misspellings worth suggesting).
    ///   - suggestCorrection: returns a confident corrected spelling for a word,
    ///     or nil when none is available (e.g. an unknown proper noun).
    /// The unique candidate tokens that survive filtering — a superset of the
    /// canonicals `analyze` will produce. Exposed so the caller can run the
    /// main-thread-only spell checker over just these tokens once.
    static func candidateTokens(
        dictations: [(text: String, backend: String?)],
        customWords: [CustomWord],
        dismissedOrAccepted: Set<String>
    ) -> [String] {
        let (counts, _) = tally(
            dictations: dictations,
            customWords: customWords,
            dismissedOrAccepted: dismissedOrAccepted
        )
        return Array(counts.keys)
    }

    /// Words already in the dictionary or ruled on, plus per-word counts and the
    /// set of backends that produced each.
    private static func tally(
        dictations: [(text: String, backend: String?)],
        customWords: [CustomWord],
        dismissedOrAccepted: Set<String>
    ) -> (counts: [String: Int], backends: [String: Set<String>]) {
        var known = dismissedOrAccepted
        for custom in customWords {
            known.insert(custom.word.lowercased())
            known.insert(custom.targetWord.lowercased())
        }

        var counts: [String: Int] = [:]
        var backends: [String: Set<String>] = [:]
        for dictation in dictations {
            let backend = dictation.backend
            for token in tokenize(dictation.text) {
                guard isCandidateToken(token), !known.contains(token) else { continue }
                counts[token, default: 0] += 1
                if let backend {
                    backends[token, default: []].insert(backend)
                }
            }
        }
        return (counts, backends)
    }

    static func analyze(
        dictations: [(text: String, backend: String?)],
        customWords: [CustomWord],
        dismissedOrAccepted: Set<String>,
        isSpelledCorrectly: (String) -> Bool,
        suggestCorrection: (String) -> String?
    ) -> [SuggestedWordUpsert] {
        let (counts, backends) = tally(
            dictations: dictations,
            customWords: customWords,
            dismissedOrAccepted: dismissedOrAccepted
        )

        guard !counts.isEmpty else { return [] }

        // Keep the most frequent unique tokens before the O(k²) clustering pass.
        let cappedTokens = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        .prefix(maxUniqueTokens)
        .map { $0.key }

        let clusters = cluster(tokens: cappedTokens, counts: counts)

        var suggestions: [SuggestedWordUpsert] = []
        for cluster in clusters {
            let totalCount = cluster.reduce(0) { $0 + (counts[$1] ?? 0) }
            guard totalCount >= minOccurrences else { continue }

            // Canonical = highest-count variant; ties broken alphabetically.
            let canonical = cluster.sorted { lhs, rhs in
                let lc = counts[lhs] ?? 0
                let rc = counts[rhs] ?? 0
                return lc != rc ? lc > rc : lhs < rhs
            }.first!

            // A correctly-spelled canonical isn't a misspelling — skip the cluster.
            guard !isSpelledCorrectly(canonical) else { continue }

            // Smart canonical: prefer a confident spell-checker correction that
            // actually differs from the word; otherwise the replacement is the
            // most-frequent variant itself (a no-op rule the user can edit).
            let correction = suggestCorrection(canonical)
            let replacement: String?
            if let correction, !correction.isEmpty, correction.lowercased() != canonical.lowercased() {
                replacement = correction
            } else {
                replacement = canonical
            }

            let variants = cluster.filter { $0 != canonical }.sorted()
            let clusterBackends = cluster
                .flatMap { backends[$0] ?? [] }
                .reduce(into: Set<String>()) { $0.insert($1) }
                .sorted()

            suggestions.append(SuggestedWordUpsert(
                word: canonical,
                replacement: replacement,
                occurrenceCount: totalCount,
                phoneticVariants: variants,
                backends: clusterBackends
            ))
        }

        // Rank: cross-model (seen under 2+ backends) first, then by count.
        return suggestions.sorted { lhs, rhs in
            let lhsCross = lhs.backends.count >= 2
            let rhsCross = rhs.backends.count >= 2
            if lhsCross != rhsCross { return lhsCross }
            if lhs.occurrenceCount != rhs.occurrenceCount { return lhs.occurrenceCount > rhs.occurrenceCount }
            return lhs.word < rhs.word
        }
    }

    // MARK: - Tokenization

    private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    /// Split text into lowercased word cores, stripping boundary punctuation.
    static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { raw in
                let core = raw.trimmingCharacters(in: boundaryPunctuation).lowercased()
                return core.isEmpty ? nil : core
            }
    }

    /// A candidate must be at least 2 chars and contain a letter (drops pure
    /// numbers and stray punctuation tokens).
    private static func isCandidateToken(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        return token.contains { $0.isLetter }
    }

    // MARK: - Clustering

    /// Greedily group tokens whose Jaro-Winkler similarity exceeds the threshold.
    /// Each returned array is one cluster of near-duplicate spellings.
    private static func cluster(tokens: [String], counts: [String: Int]) -> [[String]] {
        // Process highest-count tokens first so they seed clusters.
        let ordered = tokens.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        var clusters: [[String]] = []
        var assigned = Set<String>()

        for token in ordered {
            guard !assigned.contains(token) else { continue }
            var group = [token]
            assigned.insert(token)
            for other in ordered where !assigned.contains(other) {
                if CustomWordMatcher.jaroWinklerSimilarity(token, other) > clusterSimilarityThreshold {
                    group.append(other)
                    assigned.insert(other)
                }
            }
            clusters.append(group)
        }
        return clusters
    }
}
