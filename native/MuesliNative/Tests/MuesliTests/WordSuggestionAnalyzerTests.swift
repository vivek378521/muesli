import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Word Suggestion Analyzer")
struct WordSuggestionAnalyzerTests {

    /// Convenience: everything spelled correctly = false (treat all as unknown),
    /// no corrections offered. Lets tests focus on frequency/clustering.
    private func analyze(
        _ dictations: [(text: String, backend: String?)],
        customWords: [CustomWord] = [],
        dismissedOrAccepted: Set<String> = [],
        isSpelledCorrectly: @escaping (String) -> Bool = { _ in false },
        suggestCorrection: @escaping (String) -> String? = { _ in nil }
    ) -> [SuggestedWordUpsert] {
        WordSuggestionAnalyzer.analyze(
            dictations: dictations,
            customWords: customWords,
            dismissedOrAccepted: dismissedOrAccepted,
            isSpelledCorrectly: isSpelledCorrectly,
            suggestCorrection: suggestCorrection
        )
    }

    private func dictations(_ texts: [String], backend: String? = "whisper:small") -> [(text: String, backend: String?)] {
        texts.map { (text: $0, backend: backend) }
    }

    @Test("requires the minimum number of occurrences")
    func frequencyThreshold() {
        let twice = analyze(dictations(["kubectl deploy", "kubectl logs"]))
        #expect(!twice.contains { $0.word == "kubectl" })

        let thrice = analyze(dictations(["kubectl deploy", "kubectl logs", "run kubectl"]))
        #expect(thrice.contains { $0.word == "kubectl" })
    }

    @Test("filters numeric and very short tokens")
    func filtersNoise() {
        let result = analyze(dictations([
            "go go go", "42 42 42", "a a a", "go to 42"
        ]))
        #expect(!result.contains { $0.word == "42" })
        #expect(!result.contains { $0.word == "a" })
        // "go" is 2 chars and alphabetic -> allowed
        #expect(result.contains { $0.word == "go" })
    }

    @Test("excludes words already in the dictionary")
    func excludesCustomWords() {
        let custom = [CustomWord(word: "kubectl", replacement: nil)]
        let result = analyze(
            dictations(["kubectl one", "kubectl two", "kubectl three"]),
            customWords: custom
        )
        #expect(!result.contains { $0.word == "kubectl" })
    }

    @Test("excludes words matching a custom replacement")
    func excludesCustomReplacement() {
        let custom = [CustomWord(word: "k8s", replacement: "kubernetes")]
        let result = analyze(
            dictations(["kubernetes one", "kubernetes two", "kubernetes three"]),
            customWords: custom
        )
        #expect(!result.contains { $0.word == "kubernetes" })
    }

    @Test("excludes dismissed or accepted words")
    func excludesDismissed() {
        let result = analyze(
            dictations(["graphql a", "graphql b", "graphql c"]),
            dismissedOrAccepted: ["graphql"]
        )
        #expect(!result.contains { $0.word == "graphql" })
    }

    @Test("drops correctly spelled words")
    func dropsCorrectlySpelled() {
        let result = analyze(
            dictations(["hello there", "hello world", "hello again"]),
            isSpelledCorrectly: { $0 == "hello" }
        )
        #expect(!result.contains { $0.word == "hello" })
    }

    @Test("clusters phonetic variants under the most frequent canonical")
    func clustersVariants() {
        // muesli x3, museli x2, musli x1 -> one cluster, canonical "muesli"
        let result = analyze(dictations([
            "muesli bowl", "muesli oats", "fresh muesli",
            "museli bowl", "museli oats",
            "musli please"
        ]))
        let muesli = result.first { $0.word == "muesli" }
        #expect(muesli != nil)
        #expect(muesli?.occurrenceCount == 6)
        #expect(muesli?.phoneticVariants.contains("museli") == true)
        #expect(muesli?.phoneticVariants.contains("musli") == true)
        // Variants should not appear as their own suggestions.
        #expect(!result.contains { $0.word == "museli" })
    }

    @Test("smart canonical uses spell-checker correction when offered")
    func smartCanonicalUsesCorrection() {
        let result = analyze(
            dictations(["kubernetez a", "kubernetez b", "kubernetez c"]),
            suggestCorrection: { $0 == "kubernetez" ? "kubernetes" : nil }
        )
        let suggestion = result.first { $0.word == "kubernetez" }
        #expect(suggestion?.replacement == "kubernetes")
    }

    @Test("smart canonical falls back to the most frequent variant when no correction")
    func smartCanonicalFallsBack() {
        let result = analyze(dictations([
            "caivex a", "caivex b", "caivex c", "caveex d"
        ]))
        let suggestion = result.first { $0.word == "caivex" }
        // No correction offered -> replacement is the canonical itself.
        #expect(suggestion?.replacement == "caivex")
    }

    @Test("cross-model words rank ahead of single-model words")
    func crossModelBoost() {
        // "alpha" appears under two backends; "betaword" under one but more often.
        let mixed: [(text: String, backend: String?)] = [
            ("alpha one", "whisper:small"),
            ("alpha two", "fluidaudio:parakeet"),
            ("alpha three", "whisper:small"),
            ("betaword x", "whisper:small"),
            ("betaword y", "whisper:small"),
            ("betaword z", "whisper:small"),
            ("betaword w", "whisper:small"),
        ]
        let result = analyze(mixed)
        #expect(result.first?.word == "alpha")
        let alpha = result.first { $0.word == "alpha" }
        #expect(alpha?.backends.count == 2)
    }

    @Test("empty corpus yields no suggestions and no crash")
    func emptyCorpus() {
        #expect(analyze([]).isEmpty)
        #expect(WordSuggestionAnalyzer.candidateTokens(dictations: [], customWords: [], dismissedOrAccepted: []).isEmpty)
    }

    @Test("blank and whitespace-only text is ignored")
    func blankText() {
        let result = analyze(dictations(["", "   ", "\n\t", "kubectl", "kubectl", "kubectl"]))
        #expect(result.count == 1)
        #expect(result.first?.word == "kubectl")
    }

    @Test("occurrences are counted case-insensitively")
    func caseInsensitiveCounting() {
        // KUBECTL + Kubectl + kubectl == 3 occurrences of one token.
        let result = analyze(dictations(["KUBECTL run", "Kubectl run", "kubectl run"]))
        let kubectl = result.first { $0.word == "kubectl" }
        #expect(kubectl != nil)
        #expect(kubectl?.occurrenceCount == 3)
    }

    @Test("custom word exclusion is case-insensitive")
    func caseInsensitiveCustomExclusion() {
        let custom = [CustomWord(word: "Kubectl", replacement: nil)]
        let result = analyze(
            dictations(["kubectl a", "kubectl b", "kubectl c"]),
            customWords: custom
        )
        #expect(!result.contains { $0.word == "kubectl" })
    }

    @Test("spell-checker capitalization-only fix is preserved as the replacement")
    func capitalizationOnlyCorrection() {
        // Regression: a correction differing only in case must not be discarded.
        let result = analyze(
            dictations(["graphql a", "graphql b", "graphql c"]),
            suggestCorrection: { $0 == "graphql" ? "GraphQL" : nil }
        )
        let suggestion = result.first { $0.word == "graphql" }
        #expect(suggestion?.replacement == "GraphQL")
    }

    @Test("an empty-string correction falls back to the canonical")
    func emptyCorrectionFallsBack() {
        let result = analyze(
            dictations(["zoiks a", "zoiks b", "zoiks c"]),
            suggestCorrection: { _ in "" }
        )
        #expect(result.first { $0.word == "zoiks" }?.replacement == "zoiks")
    }

    @Test("a correction identical to the canonical falls back to the no-op rule")
    func identicalCorrectionFallsBack() {
        let result = analyze(
            dictations(["zoiks a", "zoiks b", "zoiks c"]),
            suggestCorrection: { $0 }
        )
        #expect(result.first { $0.word == "zoiks" }?.replacement == "zoiks")
    }

    @Test("a correctly-spelled canonical suppresses the whole cluster")
    func correctCanonicalSuppressesCluster() {
        // muesli (correct) is canonical with the highest count; the misspelled
        // variant must not leak out as its own suggestion.
        let result = analyze(
            dictations(["muesli a", "muesli b", "muesli c", "museli d"]),
            isSpelledCorrectly: { $0 == "muesli" }
        )
        #expect(result.isEmpty)
    }

    @Test("threshold is met by summing counts across a cluster")
    func thresholdViaClusterSum() {
        // Each variant appears twice (< 3 alone) but the cluster sums to 4.
        let result = analyze(dictations([
            "musli a", "musli b", "museli c", "museli d"
        ]))
        let suggestion = result.first { $0.word == "musli" || $0.word == "museli" }
        #expect(suggestion != nil)
        #expect(suggestion?.occurrenceCount == 4)
    }

    @Test("ties in count are broken alphabetically for the canonical")
    func tieBreakAlphabetical() {
        // "musli" and "museli" each appear 3x and cluster together; the
        // alphabetically-first ("museli") wins the canonical.
        let result = analyze(dictations([
            "musli a", "musli b", "musli c",
            "museli d", "museli e", "museli f"
        ]))
        let suggestion = result.first { $0.phoneticVariants.contains("musli") || $0.phoneticVariants.contains("museli") }
        #expect(suggestion?.word == "museli")
        #expect(suggestion?.phoneticVariants == ["musli"])
    }

    @Test("backends are de-duplicated and sorted across a cluster")
    func backendsDedupedAndSorted() {
        let mixed: [(text: String, backend: String?)] = [
            ("musli x", "whisper:small"),
            ("musli y", "whisper:small"),
            ("museli z", "fluidaudio:parakeet"),
        ]
        let result = WordSuggestionAnalyzer.analyze(
            dictations: mixed,
            customWords: [],
            dismissedOrAccepted: [],
            isSpelledCorrectly: { _ in false },
            suggestCorrection: { _ in nil }
        )
        let suggestion = result.first
        #expect(suggestion?.backends == ["fluidaudio:parakeet", "whisper:small"])
    }

    @Test("nil backends do not produce phantom cross-model boosts")
    func nilBackendsNoBoost() {
        let result = analyze(dictations(["ztoken a", "ztoken b", "ztoken c"], backend: nil))
        #expect(result.first?.backends.isEmpty == true)
    }

    @Test("analysis does not depend on NSSpellChecker")
    func noSpellCheckerDependency() {
        // Both predicates stubbed; a result is still produced purely from inputs.
        var spellCalls = 0
        let result = analyze(
            dictations(["zzqx a", "zzqx b", "zzqx c"]),
            isSpelledCorrectly: { _ in spellCalls += 1; return false }
        )
        #expect(result.contains { $0.word == "zzqx" })
        #expect(spellCalls > 0) // the injected closure is what's consulted
    }
}
