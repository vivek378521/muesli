import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Clipboard Correction Watcher")
struct ClipboardCorrectionWatcherTests {

    @Test("identical text yields no corrections")
    func identical() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetes", to: "deploy to kubernetes")
        #expect(result.isEmpty)
    }

    @Test("a single in-place word fix is captured")
    func singleFix() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetez now", to: "deploy to kubernetes now")
        #expect(result.count == 1)
        #expect(result.first?.word == "kubernetez")
        #expect(result.first?.replacement == "kubernetes")
    }

    @Test("unrelated text (too dissimilar) yields no corrections")
    func unrelated() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetes", to: "buy milk and eggs")
        #expect(result.isEmpty)
    }

    @Test("length changes (insert/delete) are ignored")
    func lengthChange() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy kubernetes", to: "deploy to kubernetes")
        #expect(result.isEmpty)
    }

    @Test("a substitution of an unrelated word is not treated as a correction")
    func dissimilarSubstitution() {
        // Same length, mostly matching, but the changed word is nothing like the original.
        let result = ClipboardCorrectionWatcher.corrections(from: "send the report today", to: "send the banana today")
        #expect(result.isEmpty)
    }

    @Test("punctuation around the corrected word is tolerated")
    func punctuationTolerated() {
        let result = ClipboardCorrectionWatcher.corrections(from: "I love muesli.", to: "I love müsli.")
        #expect(result.first?.word == "muesli")
        #expect(result.first?.replacement == "müsli")
    }
}
