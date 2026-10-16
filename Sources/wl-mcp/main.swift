import Foundation
import PlumeCore

// wl-mcp — serveur MCP local (stdio, JSON-RPC 2.0, un message JSON par ligne) exposant à Claude Code
// les dictées, réunions, todos et le dictionnaire de Plume. Lecture seule, sauf l'outil `add_todo`.
//
// Usage :
//   wl-mcp [--db <chemin.sqlite>]          serveur stdio (défaut : ~/Library/Application Support/Plume/plume.sqlite,
//                                          ou variable d'environnement WL_DB)
//   wl-mcp --seed <chemin.sqlite>          DEV UNIQUEMENT : crée une base de démonstration (refuse un fichier existant)
//   wl-mcp --help

let usage = """
wl-mcp — serveur MCP local (stdio) pour Plume

  wl-mcp [--db <chemin.sqlite>]   lance le serveur (défaut : $WL_DB, sinon
                                  ~/Library/Application Support/Plume/plume.sqlite)
  wl-mcp --seed <chemin.sqlite>   DEV : crée une base de démonstration (fichier inexistant uniquement)
  wl-mcp --help

"""

var dbPath: String? = nil
var seedPath: String? = nil
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--db":
        guard !argv.isEmpty else { Log.fatal("--db attend un chemin") }
        dbPath = argv.removeFirst()
    case "--seed":
        guard !argv.isEmpty else { Log.fatal("--seed attend un chemin") }
        seedPath = argv.removeFirst()
    case "-h", "--help":
        FileHandle.standardError.write(Data(usage.utf8))
        exit(0)
    default:
        Log.fatal("argument inconnu : \(a)\n\(usage)")
    }
}

if let seedPath {
    do {
        try DevSeed.run(path: (seedPath as NSString).expandingTildeInPath)
        Log.info("base de démonstration créée : \(seedPath)")
        exit(0)
    } catch {
        Log.fatal("seed : \(error)")
    }
}

let resolvedDB: String = {
    if let dbPath { return (dbPath as NSString).expandingTildeInPath }
    if let env = ProcessInfo.processInfo.environment["WL_DB"], !env.isEmpty { return (env as NSString).expandingTildeInPath }
    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Plume/plume.sqlite")
}()

Log.info("wl-mcp 0.1.0, base : \(resolvedDB)")
let server = MCPServer(tools: PlumeTools(dbPath: resolvedDB))
server.run()
