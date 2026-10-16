import Foundation

// MARK: - Réunions : logique pure (anti-écho, transcript, prompts de compte rendu)

public enum EchoGate {
    /// Vrai si un segment micro n'est que l'écho du son système (haut-parleurs captés par le micro) :
    /// recouvrement temporel avec un segment système et ≥ 60 % des mots en commun.
    public static func isEcho(mic: MeetingSegment, system: [MeetingSegment]) -> Bool {
        let micWords = Set(normalizeForMatch(mic.text).split(separator: " "))
        guard micWords.count >= 2 else { return false }
        for s in system where s.end >= mic.start - 1 && s.start <= mic.end + 1 {
            let sysWords = Set(normalizeForMatch(s.text).split(separator: " "))
            let common = micWords.intersection(sysWords).count
            if Double(common) / Double(micWords.count) >= 0.6 { return true }
        }
        return false
    }
}

extension EchoGate {
    /// Enveloppe d'énergie log (trames de 10 ms), centrée-réduite.
    static func envelope(_ x: [Float], frame: Int = 160) -> [Float] {
        let n = x.count / frame
        guard n > 0 else { return [] }
        var e = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            var s: Float = 0
            for j in i * frame ..< (i + 1) * frame { s += x[j] * x[j] }
            e[i] = log10(s / Float(frame) + 1e-9)
        }
        let mean = e.reduce(0, +) / Float(n)
        let sd = sqrt(e.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(n))
        return e.map { ($0 - mean) / max(sd, 1e-6) }
    }

    /// Corrélation maximale (Pearson) entre les enveloppes micro et système, décalage ±`maxLag` trames.
    /// Un micro qui ne capte que les haut-parleurs donne > 0,6 ; une vraie voix locale reste basse.
    public static func envelopeCorrelation(mic: [Float], system: [Float], maxLag: Int = 150) -> Double {
        let a = envelope(mic), b = envelope(system)
        guard a.count >= 50, b.count >= 50 else { return 0 }
        var best = -1.0
        for lag in -maxLag ... maxLag {
            var sum = 0.0, n = 0
            for i in 0 ..< a.count {
                let j = i + lag
                guard j >= 0, j < b.count else { continue }
                sum += Double(a[i] * b[j]); n += 1
            }
            if n >= a.count / 2 { best = max(best, sum / Double(n)) }
        }
        return best
    }
}

public enum MeetingTranscript {
    /// "[mm:ss] Moi : …" ; fusionne les segments consécutifs d'un même orateur.
    public static func render(_ segments: [MeetingSegment], names: [String: String] = ["me": "Moi", "them": "Eux"]) -> String {
        var lines: [String] = []
        var lastSpeaker: String?
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let who = names[s.speaker] ?? SpeakerLabels.display(s.speaker)
            if who == lastSpeaker, let last = lines.popLast() {
                lines.append(last + " " + s.text)
            } else {
                let t = Int(s.start)
                lines.append(String(format: "[%02d:%02d] ", t / 60, t % 60) + who + " : " + s.text)
            }
            lastSpeaker = who
        }
        return lines.joined(separator: "\n")
    }

    /// Découpe un transcript en blocs ≤ `maxChars`, sur des fins de ligne.
    public static func chunks(_ text: String, maxChars: Int = 8000) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty { out.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

public enum MeetingPrompts {
    public static let notesSystem = """
    Tu prends des notes de réunion à partir d'un extrait de transcription automatique (orateurs « Moi » = l'utilisateur, \
    « Eux » = les autres participants ; la transcription peut contenir des erreurs). Produis des notes factuelles en \
    puces : sujets abordés, décisions, chiffres, dates, engagements (qui fait quoi). N'invente rien. Écris dans la langue \
    de la transcription.
    """

    public static let summarySystem = """
    Tu rédiges le compte rendu d'une réunion à partir de sa transcription ou de notes intermédiaires (« Moi » = \
    l'utilisateur). N'invente rien ; écris dans la langue de la réunion. Réponds en JSON :
    - title : titre court et précis (≤ 8 mots) ;
    - summary : compte rendu en Markdown avec les sections « ## Résumé » (3 à 5 phrases), « ## Points clés » (puces), \
    « ## Décisions » (puces, ou « Aucune ») ;
    - action_items : actions concrètes, une par élément, sous la forme « Action — personne concernée, échéance » \
    (omettre ce qui est inconnu ; l'utilisateur est « moi ») ; ne jamais écrire le mot « Responsable » ;
    - follow_up_email : court email de suivi aux participants (salutation, récapitulatif, actions, formule de fin), \
    sans objet, signé « [Votre prénom] » (ne jamais signer avec le nom d'un participant).
    """

    public static let summarySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "action_items": ["type": "array", "items": ["type": "string"]],
            "follow_up_email": ["type": "string"],
        ],
        "required": ["title", "summary", "action_items", "follow_up_email"],
        "additionalProperties": false,
    ]
}

/// Interlocuteurs distants : le son système est diarisé après la réunion, chaque segment « them » devient « them:N ».
public enum SpeakerLabels {
    /// « them:2 » → « Interlocuteur 2 » ; les autres valeurs (noms lus dans l'appli de visio) restent telles quelles.
    public static func display(_ speaker: String, me: String = "Moi", them: String = "Eux", remote: String = "Interlocuteur") -> String {
        switch speaker {
        case "me": return me
        case "them": return them
        default:
            if speaker.hasPrefix("them:"), let n = Int(speaker.dropFirst(5)) { return "\(remote) \(n)" }
            return speaker
        }
    }

    /// Attribue à chaque segment distant le tour de parole diarisé qui le recouvre le plus.
    /// Les numéros suivent l'ordre d'apparition ; avec un seul interlocuteur, rien ne change (« them » suffit).
    public static func assign(segments: [MeetingSegment], turns: [(speaker: String, start: Double, end: Double)],
                              minOverlap: Double = 0.3) -> [Int64: String] {
        let remote = segments.filter { $0.speaker == "them" }.sorted { $0.start < $1.start }
        var best: [(Int64, String)] = []
        for seg in remote {
            var scores: [String: Double] = [:]
            for t in turns {
                let o = min(seg.end, t.end) - max(seg.start, t.start)
                if o > 0 { scores[t.speaker, default: 0] += o }
            }
            guard let (spk, o) = scores.max(by: { $0.value < $1.value }), o >= minOverlap * (seg.end - seg.start) else { continue }
            best.append((seg.id, spk))
        }
        var order: [String: Int] = [:]
        for (_, spk) in best where order[spk] == nil { order[spk] = order.count + 1 }
        guard order.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: best.map { ($0.0, "them:\(order[$0.1]!)") })
    }
}
