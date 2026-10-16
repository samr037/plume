import Foundation
import PlumeCore

/// Mode Instruct local : le LLM enchaîne des outils exécutés sur le Mac.
/// Pas de computer use, pas de shell, pas d'envoi de messages : écrire, coller, afficher, mémoriser une préférence,
/// chercher dans les données locales.
@MainActor
final class InstructAgent {
    struct Outcome {
        var pasted: String?
        var shown: String?
        var message: String?
        var toolLog: [[String: Any]] = []
    }

    let client: LLMClient
    let store: Store
    let paste: (String) async -> Bool

    init(client: LLMClient, store: Store, paste: @escaping (String) async -> Bool) {
        self.client = client
        self.store = store
        self.paste = paste
    }

    // Prompt et outils propres à Plume : un petit modèle local doit enchaîner des appels d'outils sans bavarder.
    static let system = """
    You turn a spoken request into actions on the user's Mac by calling tools. Output tool calls only; plain text is \
    allowed for a single short sentence when an action failed. Use as many calls as the request needs, in order.
    Typical flow: write_text produces text and gives it back to you; then insert_text puts it in the document, or \
    show_text displays it in a bubble. Choose insert_text when a text field is focused or the user asked to rewrite \
    their selection; otherwise choose show_text. Finish every session with exactly one call to done.
    Give write_text the user's own wording as its instruction, in the user's language.
    For questions about past dictations, meetings, todos or preferences, call search_history first. When the user \
    states a lasting rule ("from now on", "always", "never", "à partir de maintenant", "toujours", "jamais"), call \
    save_preference.
    Out of scope (use cannot_do): opening apps, browsing, running commands, web search, sending messages or emails, \
    creating calendar events. Try to fulfil the request before giving up.
    """

    static let tools: [[String: Any]] = [
        tool("write_text", "Produce text with the local language model: write, rewrite the selection, summarize, translate or answer. Returns the text; it does not insert it.",
             ["instruction": ["type": "string", "description": "The user's request for the text, in their own words."]], required: ["instruction"]),
        tool("insert_text", "Insert the latest write_text result at the cursor, replacing the selection if there is one.", [:]),
        tool("show_text", "Display the latest write_text result (or the given text) in a floating bubble, leaving the document untouched.",
             ["text": ["type": "string", "description": "Optional text to display instead of the latest result."]]),
        tool("save_preference", "Remember a lasting writing rule for this user, optionally limited to an app or a language.",
             ["summary": ["type": "string", "description": "The rule, as the user stated it."]], required: ["summary"]),
        tool("search_history", "Search the user's local dictations, meeting notes and transcripts, todos and saved preferences.",
             ["request": ["type": "string", "description": "Search keywords."]], required: ["request"]),
        tool("cannot_do", "The request is out of scope for this local assistant.",
             ["reason": ["type": "string"]], required: ["reason"]),
        tool("done", "Close the session. Call it once, as the very last call.", [:]),
    ]

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": props, "required": required]]]
    }

    func run(request: String, context: ContextReader.Result, preferencesFor: (String) -> String?) async -> Outcome {
        var outcome = Outcome()
        var lastText: String?
        let ctx = context.context
        var userMsg = "User request (spoken): \(request)\n"
        if let app = ctx.appName { userMsg += "Frontmost app: \(app)\n" }
        userMsg += context.readable ? "A text field is focused.\n" : "No editable text field is focused.\n"
        if let sel = ctx.selection, !sel.isEmpty { userMsg += "Selected text:\n<selection>\(sel.prefix(4000))</selection>\n" }
        var messages: [[String: Any]] = [["role": "system", "content": Self.system], ["role": "user", "content": userMsg]]

        for _ in 0 ..< 12 {
            let reply: LLMClient.Reply
            do {
                reply = try await client.chat(messages: messages, tools: Self.tools, maxTokens: 512, timeout: 30)
            } catch {
                outcome.message = "Instruct indisponible : \(error.localizedDescription)"
                return outcome
            }
            if reply.toolCalls.isEmpty {
                // Le modèle a répondu en prose : on l'affiche plutôt que de perdre la réponse.
                if !reply.content.isEmpty, outcome.pasted == nil { outcome.shown = reply.content }
                return outcome
            }
            var assistant = reply.rawMessage
            assistant["content"] = assistant["content"] ?? ""
            messages.append(assistant)
            var ended = false
            for call in reply.toolCalls {
                let result = await execute(call, context: context, request: request, lastText: &lastText, outcome: &outcome,
                                           preferencesFor: preferencesFor)
                outcome.toolLog.append(["name": call.name, "arguments": call.arguments, "result": String(result.prefix(500))])
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                if call.name == "done" || call.name == "cannot_do" { ended = true }
            }
            if ended { break }
        }
        // Le modèle a produit du texte sans dire quoi en faire : on l'affiche.
        if outcome.pasted == nil, outcome.shown == nil, outcome.message == nil, let lastText { outcome.shown = lastText }
        return outcome
    }

    private func execute(_ call: LLMClient.ToolCall, context: ContextReader.Result, request: String, lastText: inout String?,
                         outcome: inout Outcome, preferencesFor: (String) -> String?) async -> String {
        let ctx = context.context
        switch call.name {
        case "write_text":
            let instruction = call.arguments["instruction"] as? String ?? request
            var user = "Instruction : \(instruction)\n"
            if let sel = ctx.selection, !sel.isEmpty { user += "Texte sélectionné :\n<selection>\(sel.prefix(8000))</selection>\n" }
            else {
                if let b = ctx.before, !b.isEmpty { user += "Texte avant le curseur :\n<before>\(b.suffix(1500))</before>\n" }
                if let a = ctx.after, !a.isEmpty { user += "Texte après le curseur :\n<after>\(a.prefix(500))</after>\n" }
            }
            if let prefs = preferencesFor("generation") { user += prefs + "\n" }
            let system = """
            Tu rédiges pour l'utilisateur à partir de sa consigne : nouveau texte, réécriture de la sélection, résumé, \
            traduction ou réponse. Ta sortie est collée telle quelle : donne seulement le texte, sans introduction, \
            sans guillemets autour et sans mise en forme superflue. Écris dans la langue de l'utilisateur, sauf consigne contraire.
            """
            do {
                let r = try await client.chat(messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                                              maxTokens: 1500, temperature: 0.3, timeout: 60)
                // chat() renvoie la sortie brute : on retire seulement guillemets/fences ajoutés autour de la réponse.
                let text = RewriteTransform.clean(r.content, source: ctx.selection)
                lastText = text
                return text
            } catch {
                return "error: \(error.localizedDescription)"
            }

        case "insert_text":
            guard let text = lastText, !text.isEmpty else { return "error: nothing to paste, call write_text first" }
            if await paste(text) { outcome.pasted = text; return "pasted" }
            outcome.shown = text
            return "no editable field: shown in bubble instead"

        case "show_text":
            let text = (call.arguments["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lastText ?? ""
            outcome.shown = text
            return "shown"

        case "save_preference":
            let summary = call.arguments["summary"] as? String ?? request
            do {
                let pref = try await PreferenceExtractor.extract(summary, context: context, client: client)
                try store.upsert(pref)
                outcome.message = "Préférence enregistrée : \(pref.preference)" + (pref.filter.map { " [\($0)]" } ?? "")
                return "saved"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        case "search_history":
            return LocalDataSearch.run(call.arguments["request"] as? String ?? request, store: store)

        case "cannot_do":
            outcome.message = "Je ne sais pas faire ça en local : \(call.arguments["reason"] as? String ?? "demande non prise en charge")"
            return "ok"

        case "done":
            return "ended"

        default:
            return "error: unknown tool"
        }
    }
}

/// Préférence dictée (« à partir de maintenant… ») → {portée, règle} via sortie JSON contrainte.
enum PreferenceExtractor {
    static let system = """
    The user stated a writing rule. Return its scope as "filter" and the rule itself as "preference".
    filter: dimensions joined with "-", each written key:value, or null when the rule applies everywhere. Keys:
    - app: lowercase app or website name (mail, slack, notion…)
    - appCategory: email, messaging, code or terminal
    - language: two-letter code (fr, en…)
    - mode: dictation (how speech becomes text: punctuation, capitals, fillers, spelling) or generation (tone, \
    formality and length of written or rewritten text)
    Samples: "app:mail", "language:en", "appCategory:messaging-mode:generation", null. Who the message is for is not a scope.
    preference: the rule as one brief imperative sentence in the user's language, 200 characters at most.
    """

    static func extract(_ statement: String, context: ContextReader.Result, client: LLMClient) async throws -> VoicePreference {
        let ctx = context.context
        let user = """
        Statement: \(statement)
        <context>appName: \(ctx.appName ?? "?") / appBundleID: \(ctx.bundleID ?? "?") / appURL: \(context.url ?? "-")</context>
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["filter": ["type": ["string", "null"]], "preference": ["type": "string"]],
            "required": ["filter", "preference"], "additionalProperties": false,
        ]
        let o = try await client.json(system: system, user: user, schema: schema)
        let pref = (o["preference"] as? String ?? statement).trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = (o["filter"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        return VoicePreference(filter: filter, preference: String(pref.prefix(500)))
    }
}

/// Recherche plein texte simple dans la base locale, pour l'outil search_history.
enum LocalDataSearch {
    static func run(_ request: String, store: Store) -> String {
        let stop: Set = ["les", "des", "une", "dans", "pour", "avec", "mes", "mon", "the", "and", "what", "quoi", "qu", "est", "que"]
        let words = request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
        var out = ""
        var seenT = Set<Int64>(), seenM = Set<Int64>()
        for w in words.prefix(5) {
            for t in (try? store.transcripts(search: w, limit: 5)) ?? [] where seenT.insert(t.id).inserted && seenT.count <= 8 {
                out += "- Dictée \(t.createdAt.formatted(date: .abbreviated, time: .shortened)) (\(t.appName ?? "?")) : \(t.finalText.prefix(400))\n"
            }
            for m in (try? store.meetings(search: w, limit: 3)) ?? [] where seenM.insert(m.id).inserted && seenM.count <= 4 {
                out += "- Réunion « \(m.title) » du \(m.startedAt.formatted(date: .abbreviated, time: .shortened)) : \(m.summary.prefix(1500))\n"
            }
        }
        let todos = ((try? store.todos(openOnly: true)) ?? []).prefix(10)
        if !todos.isEmpty, request.lowercased().contains("todo") || request.lowercased().contains("tâche") || request.lowercased().contains("task") {
            out += "Todos ouverts :\n" + todos.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return out.isEmpty ? "No matching local data." : String(out.prefix(20_000))
    }
}
