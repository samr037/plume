import Foundation
import SQLite3

public struct TranscriptRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var createdAt: Date
    public var appName: String?
    public var bundleID: String?
    public var rawText: String
    public var formattedText: String
    public var finalText: String
    public var language: String?
    public var audioSeconds: Double
    public var asrMs: Int
    public var llmMs: Int
    public var totalMs: Int
    /// pasted | clipboard | dropped | error
    public var status: String
    public var audioPath: String?
    /// dictation | instruct
    public var mode: String = "dictation"
    /// Raison d'écart ou de repli : phantom, echo, divergence, llm_error, empty.
    public var skipReason: String?
    /// Texte observé dans le champ après édition par l'utilisateur (apprentissage des corrections).
    public var editedText: String?
    /// Style « My Voice » appliqué.
    public var voice: String?

    public init(id: Int64 = 0, createdAt: Date = Date(), appName: String? = nil, bundleID: String? = nil,
                rawText: String, formattedText: String, finalText: String, language: String? = nil,
                audioSeconds: Double = 0, asrMs: Int = 0, llmMs: Int = 0, totalMs: Int = 0,
                status: String = "pasted", audioPath: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.appName = appName; self.bundleID = bundleID
        self.rawText = rawText; self.formattedText = formattedText; self.finalText = finalText
        self.language = language; self.audioSeconds = audioSeconds; self.asrMs = asrMs; self.llmMs = llmMs
        self.totalMs = totalMs; self.status = status; self.audioPath = audioPath
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { switch self { case .sqlite(let m): "SQLite : \(m)" } }
}

/// Stockage SQLite (WAL) de l'historique et du lexique. Toutes les méthodes sont sérialisées par `queue`.
public final class Store: @unchecked Sendable {
    var db: OpaquePointer?
    let queue = DispatchQueue(label: "wl.store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 2000)
        if readOnly { return }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        var version: Int32 = 0
        try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        if version < 1 {
            try migration("""
            CREATE TABLE transcript (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL,
              app_name TEXT, bundle_id TEXT,
              raw_text TEXT NOT NULL, formatted_text TEXT NOT NULL, final_text TEXT NOT NULL,
              language TEXT, audio_seconds REAL NOT NULL DEFAULT 0,
              asr_ms INTEGER NOT NULL DEFAULT 0, llm_ms INTEGER NOT NULL DEFAULT 0, total_ms INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL, audio_path TEXT
            );
            CREATE INDEX transcript_created ON transcript(created_at DESC);
            CREATE TABLE lexicon (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL CHECK (kind IN ('word','replacement','snippet')),
              phrase TEXT NOT NULL, replacement TEXT NOT NULL DEFAULT '',
              starred INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
              UNIQUE(kind, phrase)
            );
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            // M2 : édition observée, raison d'écart, mode ; préférences apprises ; historique Instruct.
            // M3 : réunions, segments de transcription, todos.
            try migration("""
            ALTER TABLE transcript ADD COLUMN mode TEXT NOT NULL DEFAULT 'dictation';
            ALTER TABLE transcript ADD COLUMN skip_reason TEXT;
            ALTER TABLE transcript ADD COLUMN edited_text TEXT;
            ALTER TABLE transcript ADD COLUMN voice TEXT;
            CREATE TABLE preference (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              filter TEXT, preference TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL
            );
            CREATE TABLE instruct_turn (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL, app_name TEXT,
              request TEXT NOT NULL, response TEXT NOT NULL DEFAULT '', tools TEXT NOT NULL DEFAULT '[]'
            );
            CREATE TABLE meeting (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL DEFAULT '',
              started_at REAL NOT NULL, ended_at REAL,
              platform TEXT, app_bundle_id TEXT, url TEXT,
              calendar_event_id TEXT, calendar_title TEXT, attendees TEXT,
              status TEXT NOT NULL DEFAULT 'recording',
              end_reason TEXT,
              summary TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '', follow_up_email TEXT NOT NULL DEFAULT '',
              audio_dir TEXT
            );
            CREATE INDEX meeting_started ON meeting(started_at DESC);
            CREATE TABLE meeting_segment (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id INTEGER NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
              speaker TEXT NOT NULL, start_s REAL NOT NULL, end_s REAL NOT NULL, text TEXT NOT NULL
            );
            CREATE INDEX segment_meeting ON meeting_segment(meeting_id, start_s);
            CREATE TABLE todo (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id INTEGER REFERENCES meeting(id) ON DELETE SET NULL,
              text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL, done_at REAL
            );
            PRAGMA user_version = 2;
            """)
        }
        if version < 3 {
            // Scratchpad : notes et leurs versions (dictée, frappe, réécriture).
            try migration("""
            CREATE TABLE note (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at REAL NOT NULL, updated_at REAL NOT NULL,
              body TEXT NOT NULL DEFAULT '', pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE note_version (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              note_id INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
              created_at REAL NOT NULL, body TEXT NOT NULL, source TEXT NOT NULL
            );
            CREATE INDEX note_version_note ON note_version(note_id, created_at);
            PRAGMA user_version = 3;
            """)
        }
    }

    /// Une version de schéma = une transaction (DDL et user_version compris) : une migration interrompue
    /// ou en échec est annulée en bloc, et sera rejouée entière au prochain lancement.
    func migration(_ sql: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec(sql)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Motif LIKE « contient `term` » : \, % et _ sont échappés (à utiliser avec `ESCAPE '\'`).
    static func likePattern(_ term: String) -> String {
        var out = "%"
        for c in term {
            if c == "\\" || c == "%" || c == "_" { out.append("\\") }
            out.append(c)
        }
        return out + "%"
    }

    // MARK: Transcripts

    @discardableResult
    public func insert(_ r: TranscriptRecord) throws -> Int64 {
        try queue.sync {
            try run("""
            INSERT INTO transcript (created_at, app_name, bundle_id, raw_text, formatted_text, final_text, language,
              audio_seconds, asr_ms, llm_ms, total_ms, status, audio_path, mode, skip_reason, edited_text, voice)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [r.createdAt.timeIntervalSince1970, r.appName, r.bundleID, r.rawText, r.formattedText, r.finalText,
                  r.language, r.audioSeconds, r.asrMs, r.llmMs, r.totalMs, r.status, r.audioPath,
                  r.mode, r.skipReason, r.editedText, r.voice])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func transcripts(search: String = "", limit: Int = 500) throws -> [TranscriptRecord] {
        try queue.sync {
            var out: [TranscriptRecord] = []
            let sql = search.isEmpty
                ? "SELECT * FROM transcript ORDER BY created_at DESC LIMIT ?"
                : "SELECT * FROM transcript WHERE final_text LIKE ? ESCAPE '\\' OR raw_text LIKE ? ESCAPE '\\' ORDER BY created_at DESC LIMIT ?"
            let like = Self.likePattern(search)
            let args: [Any?] = search.isEmpty ? [limit] : [like, like, limit]
            try query(sql, args) { s in
                var r = TranscriptRecord(
                    id: sqlite3_column_int64(s, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                    appName: Self.text(s, 2), bundleID: Self.text(s, 3), rawText: Self.text(s, 4) ?? "",
                    formattedText: Self.text(s, 5) ?? "", finalText: Self.text(s, 6) ?? "", language: Self.text(s, 7),
                    audioSeconds: sqlite3_column_double(s, 8), asrMs: Int(sqlite3_column_int(s, 9)),
                    llmMs: Int(sqlite3_column_int(s, 10)), totalMs: Int(sqlite3_column_int(s, 11)),
                    status: Self.text(s, 12) ?? "", audioPath: Self.text(s, 13))
                r.mode = Self.text(s, 14) ?? "dictation"
                r.skipReason = Self.text(s, 15)
                r.editedText = Self.text(s, 16)
                r.voice = Self.text(s, 17)
                out.append(r)
            }
            return out
        }
    }

    public func setEditedText(transcriptID: Int64, text: String) throws {
        try queue.sync { try run("UPDATE transcript SET edited_text = ? WHERE id = ?", [text, transcriptID]) }
    }

    public func lastTranscript() throws -> TranscriptRecord? { try transcripts(limit: 1).first }

    public func deleteTranscript(id: Int64) throws {
        try queue.sync { try run("DELETE FROM transcript WHERE id = ?", [id]) }
    }

    /// Supprime l'historique plus ancien que `date` ; renvoie les chemins audio à effacer.
    public func purgeTranscripts(olderThan date: Date) throws -> [String] {
        try queue.sync {
            var paths: [String] = []
            try query("SELECT audio_path FROM transcript WHERE created_at < ? AND audio_path IS NOT NULL", [date.timeIntervalSince1970]) {
                if let p = Self.text($0, 0) { paths.append(p) }
            }
            try run("DELETE FROM transcript WHERE created_at < ?", [date.timeIntervalSince1970])
            return paths
        }
    }

    // MARK: Lexique

    public func lexicon() throws -> [LexiconEntry] {
        try queue.sync {
            var out: [LexiconEntry] = []
            try query("SELECT id, kind, phrase, replacement, starred, created_at FROM lexicon ORDER BY starred DESC, created_at DESC") { s in
                out.append(LexiconEntry(id: sqlite3_column_int64(s, 0), kind: LexiconEntry.Kind(rawValue: Self.text(s, 1) ?? "") ?? .word,
                                        phrase: Self.text(s, 2) ?? "", replacement: Self.text(s, 3) ?? "",
                                        starred: sqlite3_column_int(s, 4) != 0,
                                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
            }
            return out
        }
    }

    public func upsert(_ e: LexiconEntry) throws {
        try queue.sync {
            if e.id != 0 {
                try run("UPDATE lexicon SET kind=?, phrase=?, replacement=?, starred=? WHERE id=?",
                        [e.kind.rawValue, e.phrase, e.replacement, e.starred ? 1 : 0, e.id])
            } else {
                try run("""
                INSERT INTO lexicon (kind, phrase, replacement, starred, created_at) VALUES (?,?,?,?,?)
                ON CONFLICT(kind, phrase) DO UPDATE SET replacement=excluded.replacement, starred=excluded.starred
                """, [e.kind.rawValue, e.phrase, e.replacement, e.starred ? 1 : 0, e.createdAt.timeIntervalSince1970])
            }
        }
    }

    public func deleteLexicon(id: Int64) throws {
        try queue.sync { try run("DELETE FROM lexicon WHERE id = ?", [id]) }
    }

    // MARK: SQLite helpers (appelés sous `queue`, sauf pendant init)

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.sqlite(m)
        }
    }

    func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(s, idx)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            case let v as Double: sqlite3_bind_double(s, idx, v)
            case let v as String: sqlite3_bind_text(s, idx, v, -1, Self.transient)
            default: sqlite3_bind_text(s, idx, String(describing: a!), -1, Self.transient)
            }
        }
        return s
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    func query(_ sql: String, _ args: [Any?] = [], row: (OpaquePointer?) -> Void) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { row(s); continue }
            if rc == SQLITE_DONE { break }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}
