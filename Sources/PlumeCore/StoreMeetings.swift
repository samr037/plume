import Foundation
import SQLite3

// MARK: - Modèles M2/M3

public struct VoicePreference: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// Filtre : "app:slack-mode:generation", "language:fr", nil = global.
    public var filter: String?
    public var preference: String
    public var enabled: Bool
    public var createdAt: Date
    public init(id: Int64 = 0, filter: String?, preference: String, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.filter = filter; self.preference = preference; self.enabled = enabled; self.createdAt = createdAt
    }
}

public struct InstructTurn: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var createdAt: Date
    public var appName: String?
    public var request: String
    public var response: String
    /// JSON des appels d'outils [{name, arguments, result}].
    public var tools: String
    public init(id: Int64 = 0, createdAt: Date = Date(), appName: String?, request: String, response: String, tools: String = "[]") {
        self.id = id; self.createdAt = createdAt; self.appName = appName; self.request = request; self.response = response; self.tools = tools
    }
}

public struct Meeting: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// zoom | meet | teams | facetime | webex | slack | other
    public var platform: String?
    public var appBundleID: String?
    public var url: String?
    public var calendarEventID: String?
    public var calendarTitle: String?
    /// Noms des participants (calendrier), séparés par des virgules.
    public var attendees: String?
    /// recording | processing | complete | error
    public var status: String
    /// user | mic_released | silence | max_duration | calendar_end | sleep | crash
    public var endReason: String?
    public var summary: String
    public var notes: String
    public var followUpEmail: String
    public var audioDir: String?

    public init(id: Int64 = 0, title: String = "", startedAt: Date = Date(), endedAt: Date? = nil, platform: String? = nil,
                appBundleID: String? = nil, url: String? = nil, calendarEventID: String? = nil, calendarTitle: String? = nil,
                attendees: String? = nil, status: String = "recording", endReason: String? = nil, summary: String = "",
                notes: String = "", followUpEmail: String = "", audioDir: String? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt; self.platform = platform
        self.appBundleID = appBundleID; self.url = url; self.calendarEventID = calendarEventID; self.calendarTitle = calendarTitle
        self.attendees = attendees; self.status = status; self.endReason = endReason; self.summary = summary
        self.notes = notes; self.followUpEmail = followUpEmail; self.audioDir = audioDir
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

public struct MeetingSegment: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var meetingID: Int64
    /// "me" (micro) | "them" (son système) | nom d'orateur
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public init(id: Int64 = 0, meetingID: Int64, speaker: String, start: Double, end: Double, text: String) {
        self.id = id; self.meetingID = meetingID; self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

public struct Todo: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var meetingID: Int64?
    public var text: String
    public var done: Bool
    public var createdAt: Date
    public var doneAt: Date?
    public init(id: Int64 = 0, meetingID: Int64? = nil, text: String, done: Bool = false, createdAt: Date = Date(), doneAt: Date? = nil) {
        self.id = id; self.meetingID = meetingID; self.text = text; self.done = done; self.createdAt = createdAt; self.doneAt = doneAt
    }
}

// MARK: - Requêtes

extension Store {
    /// Ouverture en lecture seule (serveur MCP) : ne lance pas les migrations.
    public static func openReadOnly(path: String) throws -> Store { try Store(path: path, readOnly: true) }

    // Préférences apprises

    public func preferences() throws -> [VoicePreference] {
        try queue.sync {
            var out: [VoicePreference] = []
            try query("SELECT id, filter, preference, enabled, created_at FROM preference ORDER BY created_at DESC") { s in
                out.append(VoicePreference(id: sqlite3_column_int64(s, 0), filter: Self.text(s, 1), preference: Self.text(s, 2) ?? "",
                                           enabled: sqlite3_column_int(s, 3) != 0, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4))))
            }
            return out
        }
    }

    @discardableResult
    public func upsert(_ p: VoicePreference) throws -> Int64 {
        try queue.sync {
            if p.id != 0 {
                try run("UPDATE preference SET filter=?, preference=?, enabled=? WHERE id=?", [p.filter, p.preference, p.enabled ? 1 : 0, p.id])
                return p.id
            }
            try run("INSERT INTO preference (filter, preference, enabled, created_at) VALUES (?,?,?,?)",
                    [p.filter, p.preference, p.enabled ? 1 : 0, p.createdAt.timeIntervalSince1970])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func deletePreference(id: Int64) throws { try queue.sync { try run("DELETE FROM preference WHERE id=?", [id]) } }

    public func setSpeakers(_ map: [Int64: String]) throws {
        try queue.sync {
            for (id, spk) in map { try run("UPDATE meeting_segment SET speaker = ? WHERE id = ?", [spk, id]) }
        }
    }

    // Instruct

    @discardableResult
    public func insert(_ t: InstructTurn) throws -> Int64 {
        try queue.sync {
            try run("INSERT INTO instruct_turn (created_at, app_name, request, response, tools) VALUES (?,?,?,?,?)",
                    [t.createdAt.timeIntervalSince1970, t.appName, t.request, t.response, t.tools])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func instructTurns(limit: Int = 50) throws -> [InstructTurn] {
        try queue.sync {
            var out: [InstructTurn] = []
            try query("SELECT id, created_at, app_name, request, response, tools FROM instruct_turn ORDER BY created_at DESC LIMIT ?", [limit]) { s in
                out.append(InstructTurn(id: sqlite3_column_int64(s, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                        appName: Self.text(s, 2), request: Self.text(s, 3) ?? "", response: Self.text(s, 4) ?? "",
                                        tools: Self.text(s, 5) ?? "[]"))
            }
            return out
        }
    }

    // Réunions

    static let meetingColumns = """
    id, title, started_at, ended_at, platform, app_bundle_id, url, calendar_event_id, calendar_title, attendees,
    status, end_reason, summary, notes, follow_up_email, audio_dir
    """

    static func meeting(_ s: OpaquePointer?) -> Meeting {
        Meeting(id: sqlite3_column_int64(s, 0), title: text(s, 1) ?? "", startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                endedAt: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                platform: text(s, 4), appBundleID: text(s, 5), url: text(s, 6), calendarEventID: text(s, 7),
                calendarTitle: text(s, 8), attendees: text(s, 9), status: text(s, 10) ?? "", endReason: text(s, 11),
                summary: text(s, 12) ?? "", notes: text(s, 13) ?? "", followUpEmail: text(s, 14) ?? "", audioDir: text(s, 15))
    }

    @discardableResult
    public func insert(_ m: Meeting) throws -> Int64 {
        try queue.sync {
            try run("""
            INSERT INTO meeting (title, started_at, ended_at, platform, app_bundle_id, url, calendar_event_id, calendar_title,
              attendees, status, end_reason, summary, notes, follow_up_email, audio_dir) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [m.title, m.startedAt.timeIntervalSince1970, m.endedAt?.timeIntervalSince1970, m.platform, m.appBundleID, m.url,
                  m.calendarEventID, m.calendarTitle, m.attendees, m.status, m.endReason, m.summary, m.notes, m.followUpEmail, m.audioDir])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func update(_ m: Meeting) throws {
        try queue.sync {
            try run("""
            UPDATE meeting SET title=?, started_at=?, ended_at=?, platform=?, app_bundle_id=?, url=?, calendar_event_id=?,
              calendar_title=?, attendees=?, status=?, end_reason=?, summary=?, notes=?, follow_up_email=?, audio_dir=? WHERE id=?
            """, [m.title, m.startedAt.timeIntervalSince1970, m.endedAt?.timeIntervalSince1970, m.platform, m.appBundleID, m.url,
                  m.calendarEventID, m.calendarTitle, m.attendees, m.status, m.endReason, m.summary, m.notes, m.followUpEmail,
                  m.audioDir, m.id])
        }
    }

    public func meetings(search: String = "", limit: Int = 200) throws -> [Meeting] {
        try queue.sync {
            var out: [Meeting] = []
            if search.isEmpty {
                try query("SELECT \(Self.meetingColumns) FROM meeting ORDER BY started_at DESC LIMIT ?", [limit]) { out.append(Self.meeting($0)) }
            } else {
                let like = Self.likePattern(search)
                try query("""
                SELECT \(Self.meetingColumns) FROM meeting WHERE title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\'
                  OR id IN (SELECT meeting_id FROM meeting_segment WHERE text LIKE ? ESCAPE '\\') ORDER BY started_at DESC LIMIT ?
                """, [like, like, like, like, limit]) { out.append(Self.meeting($0)) }
            }
            return out
        }
    }

    public func meeting(id: Int64) throws -> Meeting? {
        try queue.sync {
            var out: Meeting?
            try query("SELECT \(Self.meetingColumns) FROM meeting WHERE id = ?", [id]) { out = Self.meeting($0) }
            return out
        }
    }

    public func deleteMeeting(id: Int64) throws { try queue.sync { try run("DELETE FROM meeting WHERE id=?", [id]) } }

    /// Réunions restées « recording » après un crash.
    public func orphanMeetings() throws -> [Meeting] {
        try queue.sync {
            var out: [Meeting] = []
            try query("SELECT \(Self.meetingColumns) FROM meeting WHERE status IN ('recording','processing')") { out.append(Self.meeting($0)) }
            return out
        }
    }

    @discardableResult
    public func insert(_ seg: MeetingSegment) throws -> Int64 {
        try queue.sync {
            try run("INSERT INTO meeting_segment (meeting_id, speaker, start_s, end_s, text) VALUES (?,?,?,?,?)",
                    [seg.meetingID, seg.speaker, seg.start, seg.end, seg.text])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func segments(meetingID: Int64) throws -> [MeetingSegment] {
        try queue.sync {
            var out: [MeetingSegment] = []
            try query("SELECT id, meeting_id, speaker, start_s, end_s, text FROM meeting_segment WHERE meeting_id=? ORDER BY start_s", [meetingID]) { s in
                out.append(MeetingSegment(id: sqlite3_column_int64(s, 0), meetingID: sqlite3_column_int64(s, 1), speaker: Self.text(s, 2) ?? "",
                                          start: sqlite3_column_double(s, 3), end: sqlite3_column_double(s, 4), text: Self.text(s, 5) ?? ""))
            }
            return out
        }
    }

    // Todos

    @discardableResult
    public func insert(_ t: Todo) throws -> Int64 {
        try queue.sync {
            try run("INSERT INTO todo (meeting_id, text, done, created_at, done_at) VALUES (?,?,?,?,?)",
                    [t.meetingID, t.text, t.done ? 1 : 0, t.createdAt.timeIntervalSince1970, t.doneAt?.timeIntervalSince1970])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func update(_ t: Todo) throws {
        try queue.sync {
            try run("UPDATE todo SET text=?, done=?, done_at=?, meeting_id=? WHERE id=?",
                    [t.text, t.done ? 1 : 0, t.doneAt?.timeIntervalSince1970, t.meetingID, t.id])
        }
    }

    public func deleteTodo(id: Int64) throws { try queue.sync { try run("DELETE FROM todo WHERE id=?", [id]) } }

    public func todos(openOnly: Bool = false, meetingID: Int64? = nil) throws -> [Todo] {
        try queue.sync {
            var out: [Todo] = []
            var sql = "SELECT id, meeting_id, text, done, created_at, done_at FROM todo WHERE 1=1"
            var args: [Any?] = []
            if openOnly { sql += " AND done = 0" }
            if let meetingID { sql += " AND meeting_id = ?"; args.append(meetingID) }
            sql += " ORDER BY done, created_at DESC"
            try query(sql, args) { s in
                out.append(Todo(id: sqlite3_column_int64(s, 0),
                                meetingID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1),
                                text: Self.text(s, 2) ?? "", done: sqlite3_column_int(s, 3) != 0,
                                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                                doneAt: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
            }
            return out
        }
    }
}
