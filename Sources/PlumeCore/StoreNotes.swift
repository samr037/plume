import Foundation
import SQLite3

/// Note du Scratchpad. Le titre est la première ligne non vide du texte.
public struct Note: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var body: String
    public var pinned: Bool

    public init(id: Int64 = 0, createdAt: Date = Date(), updatedAt: Date = Date(), body: String = "", pinned: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt; self.body = body; self.pinned = pinned
    }

    public var title: String {
        body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }.map { String($0.prefix(80)) } ?? ""
    }
}

public struct NoteVersion: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var createdAt: Date
    public var body: String
    /// typed | transform:<nom> | restore
    public var source: String
}

extension Store {
    @discardableResult
    public func insert(_ n: Note) throws -> Int64 {
        try queue.sync {
            try run("INSERT INTO note (created_at, updated_at, body, pinned) VALUES (?,?,?,?)",
                    [n.createdAt.timeIntervalSince1970, n.updatedAt.timeIntervalSince1970, n.body, n.pinned ? 1 : 0])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func notes() throws -> [Note] {
        try queue.sync {
            var out: [Note] = []
            try query("SELECT id, created_at, updated_at, body, pinned FROM note ORDER BY pinned DESC, updated_at DESC") { s in
                out.append(Note(id: sqlite3_column_int64(s, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), body: Self.text(s, 3) ?? "",
                                pinned: sqlite3_column_int(s, 4) != 0))
            }
            return out
        }
    }

    /// Enregistre le texte et une version. Les versions tapées à moins de `coalesce` secondes d'intervalle fusionnent.
    public func saveNote(id: Int64, body: String, source: String, coalesce: TimeInterval = 60) throws {
        try queue.sync {
            let now = Date().timeIntervalSince1970
            try run("UPDATE note SET body = ?, updated_at = ? WHERE id = ?", [body, now, id])
            var last: (id: Int64, at: Double, source: String)?
            try query("SELECT id, created_at, source FROM note_version WHERE note_id = ? ORDER BY created_at DESC LIMIT 1", [id]) { s in
                last = (sqlite3_column_int64(s, 0), sqlite3_column_double(s, 1), Self.text(s, 2) ?? "")
            }
            if let last, source == "typed", last.source == "typed", now - last.at < coalesce {
                try run("UPDATE note_version SET body = ?, created_at = ? WHERE id = ?", [body, now, last.id])
            } else {
                try run("INSERT INTO note_version (note_id, created_at, body, source) VALUES (?,?,?,?)", [id, now, body, source])
            }
        }
    }

    /// Ajoute une version à une note sans changer son texte courant (ex. réécriture terminée après un changement de note).
    public func addNoteVersion(noteID: Int64, body: String, source: String) throws {
        try queue.sync {
            try run("INSERT INTO note_version (note_id, created_at, body, source) VALUES (?,?,?,?)",
                    [noteID, Date().timeIntervalSince1970, body, source])
        }
    }

    public func setPinned(noteID: Int64, _ pinned: Bool) throws {
        try queue.sync { try run("UPDATE note SET pinned = ? WHERE id = ?", [pinned ? 1 : 0, noteID]) }
    }

    public func deleteNote(id: Int64) throws {
        try queue.sync {
            try run("DELETE FROM note_version WHERE note_id = ?", [id])
            try run("DELETE FROM note WHERE id = ?", [id])
        }
    }

    public func noteVersions(noteID: Int64, limit: Int = 50) throws -> [NoteVersion] {
        try queue.sync {
            var out: [NoteVersion] = []
            try query("SELECT id, created_at, body, source FROM note_version WHERE note_id = ? ORDER BY created_at DESC LIMIT ?", [noteID, limit]) { s in
                out.append(NoteVersion(id: sqlite3_column_int64(s, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                       body: Self.text(s, 2) ?? "", source: Self.text(s, 3) ?? ""))
            }
            return out
        }
    }
}
