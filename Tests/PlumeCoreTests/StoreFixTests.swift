import Foundation
import SQLite3
import Testing
@testable import PlumeCore

@Suite struct StoreFixTests {
    private func tempStore() throws -> (Store, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID()).sqlite").path
        return (try Store(path: path), path)
    }

    // #33 : une migration en échec est annulée en bloc (pas de schéma à moitié migré).
    @Test func failedMigrationRollsBack() throws {
        let (s, path) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var version: Int32 = 0
        try s.query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        #expect(version == 3)
        #expect(throws: (any Error).self) {
            try s.migration("""
            CREATE TABLE migr_probe (a TEXT);
            PRAGMA user_version = 99;
            CREATE TABLE migr_probe (a TEXT);
            """)
        }
        var tables = 0
        try s.query("SELECT count(*) FROM sqlite_master WHERE name = 'migr_probe'") { tables = Int(sqlite3_column_int($0, 0)) }
        #expect(tables == 0)
        try s.query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        #expect(version == 3)
        // La base reste utilisable après le ROLLBACK.
        #expect(try s.insert(TranscriptRecord(rawText: "a", formattedText: "a", finalText: "a")) > 0)
    }

    // #34 : % et _ sont cherchés littéralement.
    @Test func likeSearchEscapesWildcards() throws {
        let (s, path) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try s.insert(TranscriptRecord(rawText: "x", formattedText: "x", finalText: "remise de 100% sur my_var"))
        try s.insert(TranscriptRecord(rawText: "y", formattedText: "y", finalText: "remise de 1000 sur myXvar"))
        try s.insert(TranscriptRecord(rawText: "z", formattedText: "z", finalText: "chemin C:\\temp"))
        #expect(try s.transcripts(search: "100%").count == 1)
        #expect(try s.transcripts(search: "my_var").count == 1)
        #expect(try s.transcripts(search: "_").count == 1)
        #expect(try s.transcripts(search: "C:\\t").count == 1)
        #expect(try s.transcripts(search: "remise").count == 2)

        let id = try s.insert(Meeting(title: "Point 50% budget"))
        _ = id
        try s.insert(Meeting(title: "Point 500 budget"))
        #expect(try s.meetings(search: "50%").count == 1)
        #expect(try s.meetings(search: "Point").count == 2)
        #expect(Store.likePattern("a%b_c\\") == "%a\\%b\\_c\\\\%")
    }
}
