import Foundation
import PlumeCore

/// Mise en forme texte (Markdown léger) des résultats d'outils.
enum Fmt {
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "fr_FR"); d.timeZone = .current; d.dateFormat = f
        return d
    }
    private static let dtF = formatter("yyyy-MM-dd HH:mm")
    private static let dF = formatter("yyyy-MM-dd")
    private static let tF = formatter("HH:mm")

    static func dateTime(_ d: Date) -> String { dtF.string(from: d) }
    static func date(_ d: Date) -> String { dF.string(from: d) }
    static func time(_ d: Date) -> String { tF.string(from: d) }

    /// Minutes totales : « 75:12 » pour 1 h 15 min 12 s.
    static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func duration(_ m: Meeting) -> String {
        guard m.endedAt != nil else { return "en cours" }
        let mins = Int((m.duration / 60).rounded())
        if mins < 1 { return "< 1 min" }
        return mins < 60 ? "\(mins) min" : String(format: "%d h %02d", mins / 60, mins % 60)
    }

    static func title(_ m: Meeting) -> String {
        if !m.title.isEmpty { return m.title }
        if let c = m.calendarTitle, !c.isEmpty { return c }
        return "Sans titre"
    }

    static func speaker(_ s: String) -> String {
        switch s.lowercased() {
        case "me": "Moi"
        case "them": "Eux"
        default: s.isEmpty ? "?" : SpeakerLabels.display(s)
        }
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + " … [tronqué, \(s.count) caractères]"
    }
}

/// Accumulateur de lignes avec plafond de caractères (évite d'inonder le contexte du modèle).
struct TextBudget {
    let max: Int
    private(set) var text = ""
    private var full = false
    /// Nombre de caractères de `text`, tenu à jour : `text.count` est O(n) à chaque appel (quadratique sinon).
    private var count = 0
    init(max: Int) { self.max = max }

    /// Ajoute `l` + saut de ligne si le plafond le permet ; sinon (une fois) une mention de troncature.
    @discardableResult
    mutating func line(_ l: String, noteOnOverflow: Bool = true) -> Bool {
        if full { return false }
        let n = l.count + 1
        if count + n > max {
            full = true
            if noteOnOverflow { text += "\n… résultats tronqués (limite de \(max) caractères) ; affinez la recherche ou réduisez limit.\n" }
            return false
        }
        text += l + "\n"
        count += n
        return true
    }
}
