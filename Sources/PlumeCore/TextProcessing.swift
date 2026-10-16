import Foundation

// MARK: - Lexique (dictionnaire, remplacements, snippets)

public struct LexiconEntry: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case word, replacement, snippet }
    public var id: Int64
    public var kind: Kind
    /// Mot à reconnaître (word), forme fautive (replacement) ou déclencheur vocal (snippet).
    public var phrase: String
    /// Forme correcte (replacement) ou texte développé (snippet). Vide pour `word`.
    public var replacement: String
    public var starred: Bool
    public var createdAt: Date

    public init(id: Int64 = 0, kind: Kind, phrase: String, replacement: String = "", starred: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.phrase = phrase; self.replacement = replacement
        self.starred = starred; self.createdAt = createdAt
    }
}

/// Normalisation pour comparer un énoncé à un déclencheur : minuscules, sans accents ni ponctuation.
public func normalizeForMatch(_ s: String) -> String {
    let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
}

// MARK: - Prompt Whisper (biais de vocabulaire)

public enum WhisperPrompt {
    /// Construit un prompt en phrase naturelle (une liste brute dégrade le WER, Jogi 2025),
    /// termes prioritaires en fin (Whisper pondère la fin), borné à `maxChars` (~223 tokens max côté modèle).
    public static func build(terms: [String], maxChars: Int = 550) -> String? {
        var seen = Set<String>()
        let unique = terms.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !unique.isEmpty else { return nil }
        // `terms` arrive par priorité décroissante : on garde les plus prioritaires, puis on les place à la fin.
        var picked: [String] = []
        var len = 0
        for t in unique {
            if len + t.count + 2 > maxChars - 20 { break }
            picked.append(t); len += t.count + 2
        }
        // Sans préambule : un « Vocabulaire : » en français biaiserait la détection de langue vers le français.
        return picked.reversed().joined(separator: ", ") + "."
    }

    /// Vrai si la sortie ASR n'est qu'un écho du prompt (hallucination classique sur audio pauvre).
    public static func isEcho(output: String, prompt: String?) -> Bool {
        guard let prompt else { return false }
        let o = normalizeForMatch(output), p = normalizeForMatch(prompt)
        guard !o.isEmpty else { return false }
        return p.contains(o) && o.split(separator: " ").count >= 2
    }
}

// MARK: - Filtre d'hallucinations Whisper

public enum HallucinationFilter {
    /// Sorties fantômes connues de Whisper sur silence/bruit (Careless Whisper, Barański 2025, observations FR).
    static let phantoms: [String] = [
        "merci", "merci beaucoup", "merci d avoir regarde", "merci de votre attention", "merci a tous",
        "sous titres realises par la communaute d amara org", "sous titrage st 501", "sous titrage societe radio canada",
        "abonnez vous", "n oubliez pas de vous abonner", "a bientot", "au revoir",
        "thank you", "thanks for watching", "thank you for watching", "thank you very much", "you", "bye",
        "please subscribe", "subtitles by the amara org community", "so", "okay",
    ]

    /// Vrai si le texte doit être jeté. `speechSeconds` = durée de parole après rognage :
    /// une formule fantôme sur un enregistrement long est probablement réellement dite.
    public static func isPhantom(_ text: String, speechSeconds: Double) -> Bool {
        let n = normalizeForMatch(text)
        if n.isEmpty { return true }
        if n.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
        // Bracketed tags du type "[Musique]", "(applaudissements)".
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = t.first, let l = t.last, (f == "[" && l == "]") || (f == "(" && l == ")") || (f == "*" && l == "*") { return true }
        return speechSeconds < 2.5 && phantoms.contains(n)
    }
}

// MARK: - Garde de divergence LLM

public enum DivergenceGuard {
    /// Vrai si la sortie du formatteur s'écarte trop du texte ASR (réponse à la question dictée,
    /// troncature, hallucination) : on revient alors au texte brut.
    public static func isSuspicious(input: String, output: String) -> Bool {
        let a = normalizeForMatch(input).split(separator: " ").map(String.init)
        let b = normalizeForMatch(output).split(separator: " ").map(String.init)
        guard !a.isEmpty else { return false }
        if b.isEmpty { return true }
        let ratio = Double(b.count) / Double(a.count)
        // Le nettoyage retire des fillers et des passages corrigés, mais ne divise pas le texte par 3 ni ne le double.
        if ratio < 0.35 || ratio > 1.6 { return true }
        // Part des mots de la sortie absents de l'entrée (nombres réécrits en chiffres tolérés).
        let inputSet = Set(a)
        let novel = b.filter { !inputSet.contains($0) && !$0.allSatisfy(\.isNumber) }
        return Double(novel.count) / Double(b.count) > 0.45
    }
}

// MARK: - Post-traitement déterministe

public struct PostProcessor {
    public var replacements: [LexiconEntry]
    public var snippets: [LexiconEntry]

    public init(lexicon: [LexiconEntry]) {
        replacements = lexicon.filter { $0.kind == .replacement && !$0.replacement.isEmpty }
        snippets = lexicon.filter { $0.kind == .snippet && !$0.replacement.isEmpty }
    }

    /// Si tout l'énoncé est un déclencheur de snippet, renvoie l'expansion verbatim (le LLM est sauté).
    public func exactSnippet(for utterance: String) -> String? {
        let n = normalizeForMatch(utterance)
        return snippets.first { normalizeForMatch($0.phrase) == n }?.replacement
    }

    /// Remplacements du dictionnaire puis snippets en ligne, mots entiers, insensibles à la casse/accents.
    public func apply(_ text: String) -> String {
        var out = text
        for e in replacements + snippets {
            out = Self.replaceWholeWords(in: out, phrase: e.phrase, with: e.replacement)
        }
        return out
    }

    /// Mots du déclencheur échappés, séparables par espaces/ponctuation légère dans la transcription.
    static func wordsPattern(_ phrase: String) -> String? {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        return words.isEmpty ? nil : words.joined(separator: "[\\s,]+")
    }

    static func replaceWholeWords(in text: String, phrase: String, with replacement: String) -> String {
        guard var body = wordsPattern(phrase) else { return text }
        // Folding des accents : la forme sans accents est une alternative de la même regex, appliquée en une seule
        // passe sur le texte d'origine (une 2e passe re-matcherait dans le remplacement : « Helene Dupont Dupont »).
        let foldedPhrase = phrase.folding(options: .diacriticInsensitive, locale: nil)
        if foldedPhrase != phrase, let folded = wordsPattern(foldedPhrase) { body = "(?:" + body + "|" + folded + ")" }
        let pattern = "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Ajuste casse, espaces et ponctuation au texte autour du curseur (voir `ContextFitter`).
    public static func fitToContext(_ text: String, before: String?, after: String? = nil, selection: String? = nil,
                                    properNouns: Set<String> = []) -> String {
        ContextFitter.apply(text, before: before, after: after, selection: selection, properNouns: properNouns)
    }
}

// MARK: - Casse / espaces / ponctuation selon le contexte

/// Raccord casse/espaces/ponctuation : ligne courante avant et après
/// le curseur, emojis, guillemets fermants, CJK, sélection.
public enum ContextFitter {
    static let skip = Set("—`,-/:;()[]{} ")
    static let close = Set("!%),.:;>?]}")
    static let ops = Set("\\/|-&*+=~")
    static let cjkPunct = Set("。、，．！？；：…‥「」『』（）〔〕【】《》〈〉〝〞〟・")
    static let strongPunct = Set("‼⁉❗❕❓❔")

    static func isEmoji(_ c: Character) -> Bool {
        if c == "\u{FFFC}" { return true }
        if c.isLetter || (c.isNumber && !c.unicodeScalars.contains { $0.value == 0x20E3 }) { return false }
        return c.unicodeScalars.contains { (s: Unicode.Scalar) -> Bool in
            (s.properties.isEmoji && s.value > 0x7F) || s.properties.isEmojiModifier
                || (0x1F1E6 ... 0x1F1FF).contains(s.value) || s.value == 0x20E3 || (0xE0020 ... 0xE007F).contains(s.value)
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            let v = $0.value
            return (0x4E00 ... 0x9FFF).contains(v) || (0x3400 ... 0x4DBF).contains(v) || (0xF900 ... 0xFAFF).contains(v)
                || (0x3040 ... 0x309F).contains(v) || (0x30A0 ... 0x30FF).contains(v)
        }
    }

    static func isClosingQuote(_ chars: [Character], _ i: Int) -> Bool {
        guard "\"'”’".contains(chars[i]), i > 0 else { return false }
        let p = chars[i - 1]
        return !p.isWhitespace && !"([{<—–-/:".contains(p)
    }

    static func isBlank(_ c: Character) -> Bool { c.isWhitespace || c == "\u{00A0}" }

    /// Le texte avant le curseur est une phrase en cours (pas de majuscule à forcer).
    public static func isContinuingBefore(_ line: String) -> Bool {
        var chars = Array(line)
        while let l = chars.last, isBlank(l) { chars.removeLast() }
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if isEmoji(c) || skip.contains(c) || isClosingQuote(chars, i) { i -= 1; continue }
            if strongPunct.contains(c) { return false }
            return c.isLetter || c.isNumber
        }
        return false
    }

    /// Le texte après le curseur continue la phrase (pas de ponctuation finale à garder).
    public static func isContinuingAfter(_ line: String) -> Bool {
        for c in line.drop(while: isBlank) {
            if c.isLowercase || "!%,.:;>?".contains(c) { return true }
            if skip.contains(c) { continue }
            return false
        }
        return false
    }

    public static func shouldAddLeadingSpace(_ line: String) -> Bool {
        let chars = Array(line)
        guard let last = chars.last else { return false }
        if isCJK(last) { return false }
        if last.isLetter || last.isNumber { return true }
        var i = chars.count - 1
        var skipped = false
        while i >= 0, isEmoji(chars[i]) || isClosingQuote(chars, i) { i -= 1; skipped = true }
        if skipped { return i < 0 || !(isCJK(chars[i]) || cjkPunct.contains(chars[i])) }
        if close.contains(last) { return true }
        if ops.contains(last), chars.count >= 2, chars[chars.count - 2] == " " { return true }
        return false
    }

    static func lowercaseFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    static func stripFinalPunctuation(_ s: String) -> String {
        var t = s
        while let l = t.last, "!.?".contains(l) { t.removeLast() }
        return t
    }

    /// Le premier mot est un nom propre (ne pas le passer en minuscule).
    static func startsWithProperNoun(_ text: String, properNouns: Set<String>) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return false }
        let word = first.trimmingCharacters(in: .punctuationCharacters)
        if properNouns.contains(word.lowercased()) { return true }
        // Acronymes (USB, NAS, OK) et « I » anglais, y compris quand ils sont seuls (sinon « OK » → « oK »).
        if word == "I" || word.hasPrefix("I'") { return true }
        if word.count >= 2 && word.allSatisfy({ $0.isUppercase || $0.isNumber }) && word.contains(where: \.isLetter) { return true }
        return false
    }

    public static func apply(_ text: String, before: String?, after: String?, selection: String?, properNouns: Set<String>) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let before else { return t } // contexte inconnu : on ne touche à rien

        if let sel = selection, !sel.isEmpty {
            if sel.first(where: { !isBlank($0) })?.isLowercase == true { t = lowercaseFirst(t) }
            if let l = sel.last(where: { !isBlank($0) }), !close.contains(l) { t = stripFinalPunctuation(t) }
            let lead = String(sel.prefix(while: isBlank)), trail = String(sel.reversed().prefix(while: isBlank).reversed())
            return lead + t + trail
        }

        let beforeLine = before.components(separatedBy: "\n").last ?? ""
        let afterLine = after?.components(separatedBy: "\n").first ?? ""
        // Mots capitalisés visibles autour du curseur = noms propres probables.
        var nouns = properNouns
        for w in (before + " " + (after ?? "")).split(whereSeparator: { !$0.isLetter }) where w.first?.isUppercase == true {
            nouns.insert(w.lowercased())
        }
        if isContinuingBefore(beforeLine) && !startsWithProperNoun(t, properNouns: nouns) { t = lowercaseFirst(t) }
        if isContinuingAfter(afterLine) { t = stripFinalPunctuation(t) }
        if shouldAddLeadingSpace(beforeLine) { t = " " + t }
        let a = Array(afterLine)
        let trailingSpace = afterLine.isEmpty || a[0].isLetter || a[0].isNumber || (ops.contains(a[0]) && a.count > 1 && a[1] == " ")
        if trailingSpace, let l = t.last, !cjkPunct.contains(l), !isCJK(l), after != nil { t += " " }
        return t
    }
}
