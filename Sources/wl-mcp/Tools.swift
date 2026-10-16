import Foundation
import PlumeCore

/// Outils MCP de Plume. Tout passe par `Store.openReadOnly`, sauf `add_todo` (cf. TodoWriter.swift).
struct PlumeTools: ToolProvider {
    let dbPath: String

    // MARK: Définitions (tools/list)

    var definitions: [[String: Any]] {
        let ro: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
        return [
            [
                "name": "search_dictations",
                "title": "Rechercher les dictées / Search dictations",
                "description": """
                Recherche dans l'historique des dictées vocales (Plume), du plus récent au plus ancien. \
                Renvoie l'heure, l'application cible et le texte final (et le texte brut s'il diffère). \
                Search the user's voice dictation history (newest first): time, target app, final text, raw ASR text if different.
                """,
                "inputSchema": schema([
                    "query": ["type": "string", "description": "Texte à chercher (sous-chaîne, insensible à la casse ASCII) / substring to search. Vide = tout."],
                    "since": ["type": "string", "description": "Date ISO 8601 minimale, ex. 2026-10-01 ou 2026-10-01T09:00:00Z / only dictations on or after this date."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20, "description": "Nombre max de résultats / max results."],
                ]),
                "annotations": ro,
            ],
            [
                "name": "list_meetings",
                "title": "Lister les réunions / List meetings",
                "description": """
                Liste les réunions enregistrées (plus récentes d'abord) : id, titre, date, durée, plateforme, statut, \
                début du résumé. `query` cherche dans le titre, le résumé, les notes et la transcription. \
                List recorded meetings; use get_meeting with the id for details.
                """,
                "inputSchema": schema([
                    "query": ["type": "string", "description": "Texte à chercher (titre, résumé, notes, transcription) / search text."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20, "description": "Nombre max / max results."],
                ]),
                "annotations": ro,
            ],
            [
                "name": "get_meeting",
                "title": "Détail d'une réunion / Get meeting",
                "description": """
                Détail d'une réunion : métadonnées, résumé, notes, e-mail de suivi, todos et transcription \
                « [mm:ss] Orateur: texte » (Moi = micro de l'utilisateur, Eux = son des autres participants). \
                Full meeting: metadata, summary, notes, follow-up email, todos, timestamped transcript (Moi = user, Eux = others).
                """,
                "inputSchema": schema([
                    "id": ["type": "integer", "description": "Identifiant de la réunion (voir list_meetings) / meeting id."],
                    "include_transcript": ["type": "boolean", "default": true, "description": "Inclure la transcription / include transcript."],
                    "max_chars": ["type": "integer", "minimum": 500, "maximum": 200000, "default": 20000, "description": "Taille max de la transcription en caractères / transcript size cap."],
                ], required: ["id"]),
                "annotations": ro,
            ],
            [
                "name": "list_todos",
                "title": "Lister les todos / List todos",
                "description": """
                Liste les tâches (todos) extraites des réunions ou ajoutées à la main. Par défaut seulement celles ouvertes. \
                List todos (open ones by default), optionally for one meeting.
                """,
                "inputSchema": schema([
                    "open_only": ["type": "boolean", "default": true, "description": "Seulement les todos non faites / open todos only."],
                    "meeting_id": ["type": "integer", "description": "Filtrer par réunion / filter by meeting id."],
                ]),
                "annotations": ro,
            ],
            [
                "name": "add_todo",
                "title": "Ajouter un todo / Add todo",
                "description": """
                SEULE écriture possible : ajoute une tâche à la liste de Plume, éventuellement rattachée à une réunion. \
                The ONLY write operation: add a todo, optionally linked to a meeting.
                """,
                "inputSchema": schema([
                    "text": ["type": "string", "minLength": 1, "maxLength": 1000, "description": "Texte de la tâche / todo text."],
                    "meeting_id": ["type": "integer", "description": "Réunion associée (optionnel) / linked meeting id."],
                ], required: ["text"]),
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
            ],
            [
                "name": "get_dictionary",
                "title": "Dictionnaire / Dictionary",
                "description": """
                Dictionnaire personnel de Plume : mots à reconnaître, remplacements (forme fautive → correcte), \
                snippets (déclencheur vocal → texte), et préférences de style apprises. \
                Personal dictionary: vocabulary words, replacements, voice snippets, learned style preferences.
                """,
                "inputSchema": ["type": "object", "additionalProperties": false],
                "annotations": ro,
            ],
        ]
    }

    private func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { s["required"] = required }
        return s
    }

    // MARK: Appel (tools/call)

    func call(name: String, arguments a: [String: Any]) throws -> ToolOutput {
        let args = Args(a)
        // Validation des arguments d'abord (→ -32602), accès base ensuite (→ isError).
        switch name {
        case "search_dictations":
            let q = try args.string("query") ?? ""
            let since = try args.date("since")
            let limit = try args.int("limit", default: 20, range: 1...200)
            return try withStore { try searchDictations($0, query: q, since: since, limit: limit) }
        case "list_meetings":
            let q = try args.string("query") ?? ""
            let limit = try args.int("limit", default: 20, range: 1...200)
            return try withStore { try listMeetings($0, query: q, limit: limit) }
        case "get_meeting":
            guard let id = try args.int64("id") else { throw RPCError.params("argument requis : id (integer)") }
            let tr = try args.bool("include_transcript") ?? true
            let maxChars = try args.int("max_chars", default: 20000, range: 500...200_000)
            return try withStore { try getMeeting($0, id: id, includeTranscript: tr, maxChars: maxChars) }
        case "list_todos":
            let openOnly = try args.bool("open_only") ?? true
            let mid = try args.int64("meeting_id")
            return try withStore { try listTodos($0, openOnly: openOnly, meetingID: mid) }
        case "add_todo":
            let text = (try args.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw RPCError.params("argument requis : text (chaîne non vide)") }
            guard text.count <= 1000 else { throw RPCError.params("text trop long (max 1000 caractères)") }
            let mid = try args.int64("meeting_id")
            return try withStore { try addTodo($0, text: text, meetingID: mid) }
        case "get_dictionary":
            return try withStore { try dictionary($0) }
        default:
            throw RPCError.params("Outil inconnu : \(name)")
        }
    }

    /// Ouvre la base en lecture seule à chaque appel (l'app peut la créer/migrer entre deux appels).
    private func withStore(_ body: (Store) throws -> ToolOutput) throws -> ToolOutput {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ToolOutput(text: "Base Plume introuvable : \(dbPath). Lancez l'app au moins une fois, ou passez --db / WL_DB.", isError: true)
        }
        let store: Store
        do { store = try Store.openReadOnly(path: dbPath) }
        catch { return ToolOutput(text: "Ouverture de la base impossible (\(dbPath)) : \(error)", isError: true) }
        do { return try body(store) }
        catch let e as RPCError { throw e }
        catch {
            let hint = "\(error)".contains("no such table")
                ? " La base n'est pas encore migrée (réunions/todos) : lancez une version récente de l'app Plume une fois." : ""
            return ToolOutput(text: "Erreur de lecture : \(error).\(hint)", isError: true)
        }
    }

    // MARK: Implémentations

    private func searchDictations(_ s: Store, query: String, since: Date?, limit: Int) throws -> ToolOutput {
        // Tri décroissant : filtrer `since` sur les `limit` plus récents donne exactement le bon résultat.
        var rows = try s.transcripts(search: query, limit: limit)
        if let since { rows = rows.filter { $0.createdAt >= since } }
        guard !rows.isEmpty else {
            return ToolOutput(text: "Aucune dictée" + (query.isEmpty ? "" : " contenant « \(query) »") + (since.map { " depuis \(Fmt.date($0))" } ?? "") + ".")
        }
        var out = TextBudget(max: 60_000)
        out.line("# Dictées (\(rows.count)\(query.isEmpty ? "" : ", recherche « \(query) »"))\n")
        for r in rows {
            var head = "- **\(Fmt.dateTime(r.createdAt))** · \(r.appName ?? "app inconnue")"
            if r.mode != "dictation" { head += " · mode \(r.mode)" }
            if r.status != "pasted" { head += " · \(r.status)" }
            var block = head + "\n  " + Fmt.clip(Fmt.oneLine(r.finalText.isEmpty ? r.formattedText : r.finalText), 2000)
            let raw = Fmt.oneLine(r.rawText)
            if !raw.isEmpty, raw != Fmt.oneLine(r.finalText) {
                block += "\n  _brut :_ " + Fmt.clip(raw, 1000)
            }
            if let ed = r.editedText, !ed.isEmpty, ed != r.finalText {
                block += "\n  _édité ensuite :_ " + Fmt.clip(Fmt.oneLine(ed), 1000)
            }
            if !out.line(block) { break }
        }
        return ToolOutput(text: out.text)
    }

    private func listMeetings(_ s: Store, query: String, limit: Int) throws -> ToolOutput {
        let rows = try s.meetings(search: query, limit: limit)
        guard !rows.isEmpty else { return ToolOutput(text: "Aucune réunion" + (query.isEmpty ? "." : " correspondant à « \(query) ».")) }
        var out = TextBudget(max: 60_000)
        out.line("# Réunions (\(rows.count)\(query.isEmpty ? "" : ", recherche « \(query) »"))\n")
        for m in rows {
            var block = "- **#\(m.id) \(Fmt.title(m))** — \(Fmt.dateTime(m.startedAt)), \(Fmt.duration(m)), \(m.platform ?? "plateforme inconnue"), \(m.status)"
            let sum = Fmt.oneLine(m.summary)
            if !sum.isEmpty { block += "\n  " + Fmt.clip(sum, 300) }
            if !out.line(block) { break }
        }
        return ToolOutput(text: out.text)
    }

    private func getMeeting(_ s: Store, id: Int64, includeTranscript: Bool, maxChars: Int) throws -> ToolOutput {
        guard let m = try s.meeting(id: id) else { return ToolOutput(text: "Réunion #\(id) introuvable.", isError: true) }
        var t = "# Réunion #\(m.id) — \(Fmt.title(m))\n\n"
        t += "- Date : \(Fmt.dateTime(m.startedAt))" + (m.endedAt.map { " → \(Fmt.time($0))" } ?? " (en cours)") + "\n"
        t += "- Durée : \(Fmt.duration(m))\n"
        t += "- Plateforme : \(m.platform ?? "inconnue")" + (m.url.map { " (\($0))" } ?? "") + "\n"
        t += "- Statut : \(m.status)" + (m.endReason.map { ", fin : \($0)" } ?? "") + "\n"
        if let c = m.calendarTitle, !c.isEmpty, c != m.title { t += "- Événement calendrier : \(c)\n" }
        if let at = m.attendees, !at.isEmpty { t += "- Participants : \(at)\n" }
        if !m.summary.isEmpty { t += "\n## Résumé\n\n\(Fmt.clip(m.summary, 20_000))\n" }
        if !m.notes.isEmpty { t += "\n## Notes\n\n\(Fmt.clip(m.notes, 20_000))\n" }
        if !m.followUpEmail.isEmpty { t += "\n## E-mail de suivi\n\n\(Fmt.clip(m.followUpEmail, 10_000))\n" }
        let todos = try s.todos(openOnly: false, meetingID: m.id)
        if !todos.isEmpty {
            t += "\n## Todos\n\n" + todos.map { "- [\($0.done ? "x" : " ")] #\($0.id) \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if includeTranscript {
            let segs = try s.segments(meetingID: m.id)
            t += "\n## Transcription (\(segs.count) segments)\n\n"
            if segs.isEmpty {
                t += "_Aucune transcription._\n"
            } else {
                var budget = TextBudget(max: maxChars)
                var shown = 0
                for seg in segs {
                    let line = "[\(Fmt.mmss(seg.start))] \(Fmt.speaker(seg.speaker)): \(Fmt.oneLine(seg.text))"
                    if !budget.line(line, noteOnOverflow: false) { break }
                    shown += 1
                }
                t += budget.text
                if shown < segs.count {
                    t += "\n… transcription tronquée à \(maxChars) caractères (\(shown)/\(segs.count) segments, " +
                         "jusqu'à \(Fmt.mmss(shown > 0 ? segs[shown - 1].end : 0))). Augmentez max_chars pour la suite.\n"
                }
            }
        }
        return ToolOutput(text: t)
    }

    private func listTodos(_ s: Store, openOnly: Bool, meetingID: Int64?) throws -> ToolOutput {
        let rows = try s.todos(openOnly: openOnly, meetingID: meetingID)
        let scope = (openOnly ? "ouvertes" : "toutes") + (meetingID.map { ", réunion #\($0)" } ?? "")
        guard !rows.isEmpty else { return ToolOutput(text: "Aucune todo (\(scope)).") }
        var titles: [Int64: String] = [:]
        var out = TextBudget(max: 60_000)
        out.line("# Todos (\(rows.count), \(scope))\n")
        for td in rows {
            var line = "- [\(td.done ? "x" : " ")] #\(td.id) \(Fmt.oneLine(td.text))"
            var meta = ["créée le \(Fmt.date(td.createdAt))"]
            if let mid = td.meetingID {
                if titles[mid] == nil { titles[mid] = (try? s.meeting(id: mid)).flatMap { $0.map(Fmt.title) } ?? "?" }
                meta.insert("réunion #\(mid) « \(titles[mid]!) »", at: 0)
            }
            if let d = td.doneAt { meta.append("faite le \(Fmt.date(d))") }
            line += " _(\(meta.joined(separator: ", ")))_"
            if !out.line(line) { break }
        }
        return ToolOutput(text: out.text)
    }

    private func addTodo(_ s: Store, text: String, meetingID: Int64?) throws -> ToolOutput {
        var title: String?
        if let meetingID {
            guard let m = try s.meeting(id: meetingID) else { return ToolOutput(text: "Réunion #\(meetingID) introuvable : todo non ajoutée.", isError: true) }
            title = Fmt.title(m)
        }
        do {
            let id = try TodoWriter.insert(dbPath: dbPath, text: text, meetingID: meetingID)
            return ToolOutput(text: "Todo #\(id) ajoutée : « \(text) »" + (meetingID.map { " (réunion #\($0) « \(title ?? "") »)" } ?? "") + ".")
        } catch {
            return ToolOutput(text: "Écriture impossible : \(error)", isError: true)
        }
    }

    private func dictionary(_ s: Store) throws -> ToolOutput {
        let lex = try s.lexicon()
        let words = lex.filter { $0.kind == .word }
        let reps = lex.filter { $0.kind == .replacement }
        let snips = lex.filter { $0.kind == .snippet }
        let prefs = try s.preferences()
        let star: (LexiconEntry) -> String = { $0.starred ? " ★" : "" }
        var t = "# Dictionnaire Plume\n\n"
        t += "## Mots (\(words.count))\n\n" + (words.isEmpty ? "_aucun_" : words.map { "- \($0.phrase)\(star($0))" }.joined(separator: "\n")) + "\n\n"
        t += "## Remplacements (\(reps.count))\n\n" + (reps.isEmpty ? "_aucun_" : reps.map { "- \($0.phrase) → \($0.replacement)\(star($0))" }.joined(separator: "\n")) + "\n\n"
        t += "## Snippets (\(snips.count))\n\n" + (snips.isEmpty ? "_aucun_" : snips.map { "- « \($0.phrase) » → \(Fmt.clip(Fmt.oneLine($0.replacement), 500))\(star($0))" }.joined(separator: "\n")) + "\n"
        if !prefs.isEmpty {
            t += "\n## Préférences de style apprises (\(prefs.count))\n\n" + prefs.map {
                "- \($0.enabled ? "" : "(désactivée) ")\($0.filter.map { "[\($0)] " } ?? "")\(Fmt.oneLine($0.preference))"
            }.joined(separator: "\n") + "\n"
        }
        return ToolOutput(text: Fmt.clip(t, 60_000))
    }
}

// MARK: - Lecture typée des arguments (erreur -32602 si type invalide)

struct Args {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    private func present(_ k: String) -> Any? {
        guard let v = raw[k], !(v is NSNull) else { return nil }
        return v
    }

    func string(_ k: String) throws -> String? {
        guard let v = present(k) else { return nil }
        guard let s = v as? String else { throw RPCError.params("\(k) doit être une chaîne") }
        return s
    }

    func int64(_ k: String) throws -> Int64? {
        guard let v = present(k) else { return nil }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            guard d == d.rounded(), abs(d) < 9e15 else { throw RPCError.params("\(k) doit être un entier") }
            return n.int64Value
        }
        if let s = v as? String, let i = Int64(s.trimmingCharacters(in: .whitespaces)) { return i }
        throw RPCError.params("\(k) doit être un entier")
    }

    func int(_ k: String, default d: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = try int64(k) else { return d }
        return min(max(Int(v), range.lowerBound), range.upperBound)
    }

    func bool(_ k: String) throws -> Bool? {
        guard let v = present(k) else { return nil }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = v as? String { switch s.lowercased() { case "true": return true; case "false": return false; default: break } }
        throw RPCError.params("\(k) doit être un booléen")
    }

    /// ISO 8601 : « 2026-10-01 » (minuit local), « 2026-10-01T09:00 », avec ou sans fuseau / fractions.
    func date(_ k: String) throws -> Date? {
        guard let s = try string(k)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter(); f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        throw RPCError.params("\(k) : date ISO 8601 invalide (ex. 2026-10-01 ou 2026-10-01T09:00:00Z)")
    }
}
