import AppKit
import Foundation
import MuesliCore

/// Opt-in watcher that learns dictionary corrections from the user's own edits.
///
/// After Muesli pastes a dictation, the user may fix a misspelled word, re-copy
/// the corrected text, and paste it elsewhere. When that corrected text lands on
/// the clipboard we diff it against what we pasted and extract word-level
/// corrections as high-confidence suggestions.
///
/// This is **default-off** (`AppConfig.enableClipboardCorrectionTracking`):
/// repeatedly reading `NSPasteboard` triggers a macOS "used the clipboard" notice
/// and timer polling is unreliable under App Nap in an LSUIElement app. The
/// watcher only samples for a bounded window immediately after our own paste, and
/// it starts after `PasteController`'s clipboard-restore window so it never races
/// or mis-reads the restore write as a user correction.
@MainActor
final class ClipboardCorrectionWatcher {
    /// Begin sampling only after PasteController's 0.5s restore has happened.
    private static let startDelay: TimeInterval = 0.8
    private static let pollInterval: TimeInterval = 0.7
    private static let maxPolls = 6
    /// Corrected text must be this similar to the pasted text overall — a real
    /// edit, not a different copy entirely.
    nonisolated private static let minOverallSimilarity = 0.7

    private let pasteboard: NSPasteboard
    private var pollTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Watch for an edited version of `pastedText` and report corrections.
    func watch(pastedText: String, onCorrections: @escaping ([SuggestedWordUpsert]) -> Void) {
        pollTask?.cancel()
        let baselineChangeCount = pasteboard.changeCount
        pollTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.startDelay * 1_000_000_000))
            for _ in 0..<Self.maxPolls {
                if Task.isCancelled { return }
                if self.pasteboard.changeCount != baselineChangeCount,
                   let current = self.pasteboard.string(forType: .string) {
                    let corrections = Self.corrections(from: pastedText, to: current)
                    if !corrections.isEmpty {
                        onCorrections(corrections)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Pure diff (testable)

    /// Diff pasted text against the (presumably edited) clipboard text and return
    /// the words that changed in place as corrections. Returns empty if the two
    /// texts are identical, too dissimilar to be an edit, or differ in length
    /// (insertions/deletions are ignored — only same-position substitutions are
    /// treated as corrections).
    nonisolated static func corrections(from pasted: String, to edited: String) -> [SuggestedWordUpsert] {
        let pastedTokens = tokenize(pasted)
        let editedTokens = tokenize(edited)
        guard !pastedTokens.isEmpty,
              pastedTokens.count == editedTokens.count,
              pastedTokens != editedTokens else {
            return []
        }

        // Guard against unrelated clipboard copies: only a small minority of
        // tokens may differ (always allowing at least one change, so a short
        // sentence with a single fix still counts as an edit).
        let differing = zip(pastedTokens, editedTokens).filter { $0 != $1 }.count
        let maxDiffering = max(1, Int((1.0 - minOverallSimilarity) * Double(pastedTokens.count)))
        guard differing <= maxDiffering else { return [] }

        var corrections: [SuggestedWordUpsert] = []
        for (original, corrected) in zip(pastedTokens, editedTokens) where original != corrected {
            // Only treat single-word substitutions of similar words as
            // corrections (filters out unrelated rewrites).
            guard corrected.contains(where: { $0.isLetter }),
                  CustomWordMatcher.jaroWinklerSimilarity(original.lowercased(), corrected.lowercased()) > 0.6 else {
                continue
            }
            corrections.append(SuggestedWordUpsert(
                word: original.lowercased(),
                replacement: corrected,
                occurrenceCount: WordSuggestionAnalyzer.minOccurrences,
                phoneticVariants: [],
                backends: []
            ))
        }
        return corrections
    }

    nonisolated private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    nonisolated private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { raw in
                let core = raw.trimmingCharacters(in: boundaryPunctuation)
                return core.isEmpty ? nil : core
            }
    }
}
