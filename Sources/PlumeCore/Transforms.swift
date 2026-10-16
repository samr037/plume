import Foundation

/// Réécriture rapide : une consigne fixe appliquée à la sélection, sans dicter.
/// Les neuf premières sont liées à ⌃⌥1 … ⌃⌥9.
public struct RewriteTransform: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instruction: String

    public init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }

    public static let defaults: [RewriteTransform] = [
        RewriteTransform(name: "Plus formel", instruction: "Rends le texte plus formel et professionnel, sans l'allonger."),
        RewriteTransform(name: "Plus court", instruction: "Raccourcis le texte d'environ moitié en gardant toutes les informations utiles."),
        RewriteTransform(name: "Corriger", instruction: "Corrige uniquement l'orthographe, la grammaire et la ponctuation. Ne change ni le ton ni les mots."),
        RewriteTransform(name: "Plus chaleureux", instruction: "Rends le ton plus chaleureux et amical, sans en faire trop."),
        RewriteTransform(name: "En liste", instruction: "Mets le texte sous forme de liste concise, une idée par ligne, chaque ligne commençant par « - »."),
        RewriteTransform(name: "En anglais", instruction: "Traduis le texte en anglais naturel."),
        RewriteTransform(name: "En français", instruction: "Traduis le texte en français naturel."),
    ]

    /// Messages pour un endpoint `/v1/chat/completions`.
    public func messages(for text: String) -> [[String: Any]] {
        [
            ["role": "system", "content": """
            Tu réécris le texte de l'utilisateur selon une consigne. Réponds uniquement par le texte réécrit : \
            pas de guillemets, pas de préambule, pas d'explication. Garde la langue du texte sauf si la consigne demande \
            une traduction. Conserve les noms propres, les chiffres, les liens et la mise en forme utile (retours à la ligne).
            """],
            ["role": "user", "content": "<consigne>\(instruction)</consigne>\n<texte>\n\(text)\n</texte>"],
        ]
    }

    /// Retire ce que les petits modèles ajoutent parfois autour de la réponse.
    /// `source` : texte d'origine ; s'il est lui-même un bloc de code délimité, ses ``` sont conservées.
    public static func clean(_ output: String, source: String? = nil) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<texte>", "</texte>"] { s = s.replacingOccurrences(of: tag, with: "") }
        let sourceIsFenced = source?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true
        if s.hasPrefix("```"), !sourceIsFenced {
            s = s.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if s.hasSuffix("```") { s.removeLast(3) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”")]
        for (open, close) in quotes where s.count > 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
