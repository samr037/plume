import Foundation
import SQLite3

// ⚠️ SEUL CHEMIN D'ÉCRITURE DE wl-mcp ⚠️
// Connexion SQLite lecture-écriture dédiée, ouverte uniquement le temps d'un INSERT dans `todo`,
// puis refermée. Pas de SQLITE_OPEN_CREATE (jamais de création de base) ni de migration :
// le schéma appartient à l'app (PlumeCore.Store). Tout le reste du serveur passe par Store.openReadOnly.
enum TodoWriter {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func insert(dbPath: String, text: String, meetingID: Int64?) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(db)
            throw Failure(description: "ouverture RW : \(m)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)   // l'app peut écrire en même temps (WAL)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)

        var s: OpaquePointer?
        let sql = "INSERT INTO todo (meeting_id, text, done, created_at) VALUES (?, ?, 0, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        if let meetingID { sqlite3_bind_int64(s, 1, meetingID) } else { sqlite3_bind_null(s, 1) }
        sqlite3_bind_text(s, 2, text, -1, transient)
        sqlite3_bind_double(s, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
        let id = sqlite3_last_insert_rowid(db)
        Log.info("add_todo : todo #\(id) insérée")
        return id
    }
}
