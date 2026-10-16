import Foundation

// MARK: - Journal (stderr uniquement : stdout est réservé au protocole)

enum Log {
    static func info(_ m: String) { FileHandle.standardError.write(Data("[wl-mcp] \(m)\n".utf8)) }
    static func fatal(_ m: String) -> Never { info("erreur : \(m)"); exit(2) }
}

// MARK: - Erreurs JSON-RPC

struct RPCError: Error {
    var code: Int
    var message: String
    static let parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    static func params(_ m: String) -> RPCError { RPCError(code: invalidParams, message: m) }
}

/// Résultat d'un outil : texte lisible ; `isError` = erreur d'exécution (visible par le modèle), pas erreur de protocole.
struct ToolOutput {
    var text: String
    var isError = false
}

/// Fournisseur d'outils MCP.
protocol ToolProvider {
    var definitions: [[String: Any]] { get }
    /// Lève `RPCError` (-32602) pour un outil inconnu ou des arguments invalides.
    func call(name: String, arguments: [String: Any]) throws -> ToolOutput
}

// MARK: - Serveur MCP stdio (JSON-RPC 2.0, messages délimités par des retours à la ligne)

final class MCPServer {
    /// Révisions « à initialize » supportées. Les clients 2026-07-28 sondent d'abord `server/discover` :
    /// on répond -32601 (erreur non « moderne »), ce qui les fait retomber sur `initialize`.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let fallbackVersion = "2025-06-18"

    let tools: ToolProvider
    private var initialized = false

    init(tools: ToolProvider) { self.tools = tools }

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let reply = handle(line: trimmed) { send(reply) }
        }
        Log.info("stdin fermé, arrêt")
    }

    func handle(line: String) -> [String: Any]? {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        catch { return errorReply(id: NSNull(), RPCError(code: RPCError.parse, message: "Parse error")) }

        guard let msg = obj as? [String: Any] else {
            // Le batching JSON-RPC a été retiré de MCP (2025-06-18).
            return errorReply(id: NSNull(), RPCError(code: RPCError.invalidRequest, message: "Invalid Request (batch non supporté)"))
        }
        let id = msg["id"]
        let isNotification = (id == nil)
        guard msg["jsonrpc"] as? String == "2.0", let method = msg["method"] as? String else {
            // Réponse d'un client (ex. à une requête serveur) ou message invalide.
            if msg["result"] != nil || msg["error"] != nil { return nil }
            return isNotification ? nil : errorReply(id: id!, RPCError(code: RPCError.invalidRequest, message: "Invalid Request"))
        }
        let params = msg["params"] as? [String: Any] ?? [:]

        if isNotification {
            switch method {
            case "notifications/initialized": initialized = true
            case "notifications/cancelled": break   // requêtes synchrones : rien à annuler
            default: Log.info("notification ignorée : \(method)")
            }
            return nil
        }

        do {
            let result = try dispatch(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id!, "result": result]
        } catch let e as RPCError {
            return errorReply(id: id!, e)
        } catch {
            return errorReply(id: id!, RPCError(code: RPCError.internalError, message: "\(error)"))
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.fallbackVersion
            if let ci = params["clientInfo"] as? [String: Any] {
                Log.info("initialize : client \(ci["name"] ?? "?") \(ci["version"] ?? "?"), protocole demandé \(requested) → \(version)")
            }
            return [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "plume", "version": "0.1.0"],
                "instructions": """
                Données locales de Plume (dictée vocale macOS) : historique des dictées, réunions transcrites \
                (résumé, notes, transcription horodatée Moi/Eux), todos et dictionnaire. Tout est en lecture seule, \
                sauf add_todo. Local dictation history, meeting transcripts, todos and dictionary.
                """,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools.definitions]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.params("params.name (string) requis") }
            let rawArgs = params["arguments"] ?? [String: Any]()
            guard let args = rawArgs as? [String: Any] else { throw RPCError.params("params.arguments doit être un objet") }
            let out = try tools.call(name: name, arguments: args)
            var result: [String: Any] = ["content": [["type": "text", "text": out.text]]]
            if out.isError { result["isError"] = true }
            return result
        default:
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func errorReply(id: Any, _ e: RPCError) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]]
    }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            Log.info("sérialisation JSON impossible")
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
