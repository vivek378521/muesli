import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

@Suite("Suggested Word Store", .serialized)
struct SuggestedWordStoreTests {

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-sugg-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    /// A dictations table without the asr_backend column, to exercise the ALTER migration.
    private func makeLegacyDictationStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-legacy-dict-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            duration_seconds REAL,
            raw_text TEXT,
            app_context TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'dictation',
            started_at TEXT,
            ended_at TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return DictationStore(databaseURL: url)
    }

    private func upsert(_ word: String, count: Int = 3, replacement: String? = nil, variants: [String] = [], backends: [String] = []) -> SuggestedWordUpsert {
        SuggestedWordUpsert(
            word: word,
            replacement: replacement,
            occurrenceCount: count,
            phoneticVariants: variants,
            backends: backends
        )
    }

    @Test("migration is idempotent and creates suggested_words")
    func migrationIdempotent() throws {
        let store = try makeStore()
        try store.migrateIfNeeded()
        #expect(try store.listSuggestedWords(status: .pending).isEmpty)
    }

    @Test("migration upgrades a legacy dictations table with asr_backend")
    func legacyDictationUpgrade() throws {
        let store = try makeLegacyDictationStore()
        try store.migrateIfNeeded()
        let now = Date()
        let id = try store.insertDictation(
            text: "hello kubectl",
            durationSeconds: 1.0,
            startedAt: now,
            endedAt: now,
            asrBackend: "whisper:small"
        )
        #expect(id > 0)
        let rows = try store.dictationTextsForAnalysis()
        #expect(rows.first?.backend == "whisper:small")
    }

    @Test("insertDictation round-trips asr_backend")
    func asrBackendRoundTrip() throws {
        let store = try makeStore()
        let now = Date()
        _ = try store.insertDictation(text: "with backend", durationSeconds: 1, startedAt: now, endedAt: now, asrBackend: "fluidaudio:parakeet")
        _ = try store.insertDictation(text: "no backend", durationSeconds: 1, startedAt: now, endedAt: now)
        let rows = try store.dictationTextsForAnalysis()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.backend == "fluidaudio:parakeet" })
        #expect(rows.contains { $0.backend == nil })
    }

    @Test("upsert inserts then updates count by word")
    func upsertUpdatesCount() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("kubectl", count: 3)])
        try store.upsertSuggestedWords([upsert("kubectl", count: 7, backends: ["whisper:small"])])
        let pending = try store.listSuggestedWords(status: .pending)
        #expect(pending.count == 1)
        #expect(pending.first?.occurrenceCount == 7)
        #expect(pending.first?.backends == ["whisper:small"])
    }

    @Test("upsert does not resurrect a dismissed word to pending")
    func upsertDoesNotResurrectDismissed() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("graphql")])
        let id = try #require(try store.listSuggestedWords(status: .pending).first?.id)
        try store.setSuggestedWordStatus(id: id, status: .dismissed)

        // Re-mined later — must stay dismissed.
        try store.upsertSuggestedWords([upsert("graphql", count: 9)])
        #expect(try store.listSuggestedWords(status: .pending).isEmpty)
        let dismissed = try store.listSuggestedWords(status: .dismissed)
        #expect(dismissed.count == 1)
        #expect(dismissed.first?.occurrenceCount == 9) // count still refreshed
    }

    @Test("listSuggestedWords filters by status and orders by count")
    func listFilteringAndOrdering() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([
            upsert("low", count: 3),
            upsert("high", count: 10),
        ])
        let pending = try store.listSuggestedWords(status: .pending)
        #expect(pending.map(\.word) == ["high", "low"])
        #expect(try store.listSuggestedWords(status: .accepted).isEmpty)
    }

    /// Force a row's last_seen_at into the past so aging can be tested.
    private func backdateLastSeen(_ store: DictationStore, word: String, days: Int) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "UPDATE suggested_words SET last_seen_at = datetime('now', '-\(days) days') WHERE word = '\(word)'"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test("prune removes pending suggestions not seen recently")
    func pruneStalePending() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("stale"), upsert("fresh")])
        try backdateLastSeen(store, word: "stale", days: 45)

        let pruned = try store.pruneStalePendingSuggestions(olderThanDays: 30)
        #expect(pruned == 1)
        let pending = try store.listSuggestedWords(status: .pending)
        #expect(pending.map(\.word) == ["fresh"])
    }

    @Test("prune leaves recently-seen pending suggestions")
    func pruneKeepsFresh() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("recent")])
        try backdateLastSeen(store, word: "recent", days: 10)
        let pruned = try store.pruneStalePendingSuggestions(olderThanDays: 30)
        #expect(pruned == 0)
        #expect(try store.listSuggestedWords(status: .pending).count == 1)
    }

    @Test("prune never ages out accepted or dismissed suggestions")
    func pruneSparesDecidedWords() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("accepted"), upsert("dismissed")])
        let words = try store.listSuggestedWords(status: .pending)
        let acceptedID = try #require(words.first { $0.word == "accepted" }?.id)
        let dismissedID = try #require(words.first { $0.word == "dismissed" }?.id)
        try store.setSuggestedWordStatus(id: acceptedID, status: .accepted)
        try store.setSuggestedWordStatus(id: dismissedID, status: .dismissed)
        try backdateLastSeen(store, word: "accepted", days: 365)
        try backdateLastSeen(store, word: "dismissed", days: 365)

        let pruned = try store.pruneStalePendingSuggestions(olderThanDays: 30)
        #expect(pruned == 0)
        #expect(try store.listSuggestedWords(status: .accepted).count == 1)
        #expect(try store.listSuggestedWords(status: .dismissed).count == 1)
    }

    @Test("re-upserting a stale word refreshes last_seen and saves it from pruning")
    func upsertRefreshesLastSeen() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("revived")])
        try backdateLastSeen(store, word: "revived", days: 60)
        // Seen again in a new analysis run -> last_seen_at bumped to now.
        try store.upsertSuggestedWords([upsert("revived", count: 5)])
        let pruned = try store.pruneStalePendingSuggestions(olderThanDays: 30)
        #expect(pruned == 0)
        #expect(try store.listSuggestedWords(status: .pending).first?.occurrenceCount == 5)
    }

    @Test("setSuggestedWordStatus moves a word between buckets")
    func setStatus() throws {
        let store = try makeStore()
        try store.upsertSuggestedWords([upsert("muesli", replacement: "muesli", variants: ["museli"])])
        let id = try #require(try store.listSuggestedWords(status: .pending).first?.id)
        try store.setSuggestedWordStatus(id: id, status: .accepted)
        #expect(try store.listSuggestedWords(status: .pending).isEmpty)
        let accepted = try store.listSuggestedWords(status: .accepted)
        #expect(accepted.first?.phoneticVariants == ["museli"])
        #expect(accepted.first?.replacement == "muesli")
    }
}
