import Foundation

/// Apprentissage des corrections : alignement mot à mot entre le texte collé et
/// le texte édité par l'utilisateur, regroupement des éditions contiguës (≤ 4 mots), filtres, 4 candidats au plus.
public enum EditLearning {
    public enum Step: Equatable { case match(String), substitute(String, String), insert(String), delete(String) }

    public struct Candidate: Equatable, Sendable {
        /// Forme corrigée par l'utilisateur.
        public var word: String
        /// Ce que la dictée avait produit.
        public var observedSource: String
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?«»\"()[]")) }.filter { !$0.isEmpty }
    }

    /// Alignement de Levenshtein sur les mots (comparaison insensible à la casse pour les correspondances).
    public static func align(_ original: String, _ edited: String) -> [Step] {
        let a = tokens(original), b = tokens(edited)
        let n = a.count, m = b.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0 ... n { d[i][0] = i }
        for j in 0 ... m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    let same = a[i - 1] == b[j - 1]
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (same ? 0 : 1))
                }
            }
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                steps.append(a[i - 1] == b[j - 1] ? .match(a[i - 1]) : .substitute(a[i - 1], b[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                steps.append(.delete(a[i - 1])); i -= 1
            } else {
                steps.append(.insert(b[j - 1])); j -= 1
            }
        }
        return steps.reversed()
    }

    /// Part des mots modifiés (0 = identique).
    public static func editRatio(_ original: String, _ edited: String) -> Double {
        let steps = align(original, edited)
        guard !steps.isEmpty else { return 0 }
        let changed = steps.filter { if case .match = $0 { return false }; return true }.count
        return Double(changed) / Double(steps.count)
    }

    static let stopwords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "de", "du", "et", "ou", "à", "a", "en", "que", "qui", "je", "tu", "il", "elle", "on",
        "nous", "vous", "ils", "ce", "ça", "pas", "ne", "est", "sur", "pour", "par", "avec", "dans", "mais", "donc",
        "the", "an", "and", "or", "to", "of", "in", "on", "for", "is", "it", "i", "you", "we", "that", "this", "with", "not", "be",
    ]

    /// Candidats à ajouter au dictionnaire (au plus `limit`, ceux qui contiennent une majuscule en premier).
    public static func candidates(original: String, edited: String, dictionary: Set<String>, limit: Int = 4) -> [Candidate] {
        let steps = align(original, edited)
        var runs: [[Step]] = []
        var current: [Step] = []
        for s in steps {
            if case .match = s {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { runs.append(current) }

        var out: [Candidate] = []
        var seen = Set<String>()
        for run in runs {
            var edited: [String] = [], orig: [String] = []
            for s in run {
                switch s {
                case .substitute(let o, let e): orig.append(o); edited.append(e)
                case .insert(let e): edited.append(e)
                case .delete(let o): orig.append(o)
                case .match: break
                }
            }
            guard !edited.isEmpty, !orig.isEmpty, edited.count <= 4 else { continue }
            let word = edited.joined(separator: " ")
            let key = word.lowercased()
            guard !edited.allSatisfy({ stopwords.contains($0.lowercased()) }),
                  !dictionary.contains(key), !isContractionOrPossessive(word),
                  normalizeForMatch(word) != normalizeForMatch(orig.joined(separator: " ")), // simple changement de casse/accents
                  seen.insert(key).inserted else { continue }
            out.append(Candidate(word: word, observedSource: orig.joined(separator: " ")))
        }
        out.sort { ($0.word.contains(where: \.isUppercase) ? 0 : 1) < ($1.word.contains(where: \.isUppercase) ? 0 : 1) }
        return Array(out.prefix(limit))
    }

    /// Rejette « it's », « John's », « don't »… (mais pas « O'Neill »).
    static func isContractionOrPossessive(_ w: String) -> Bool {
        let startsLikeName = w.range(of: "^[A-Za-z]?['‘’][A-Z]", options: .regularExpression) != nil
        let endsLikeContraction = w.range(of: "['‘’](s|t|ll|ve|re|d|m)?$", options: [.regularExpression, .caseInsensitive]) != nil
        return !startsLikeName && endsLikeContraction
    }

    /// Isole, dans la valeur finale du champ, la portion correspondant au texte collé.
    /// `before` = valeur juste après le collage, `after` = valeur à la fin de l'observation.
    public static func editedRegion(pasted: String, before: String, after: String) -> String? {
        guard let r = before.range(of: pasted.trimmingCharacters(in: .whitespacesAndNewlines), options: .backwards) else { return nil }
        let prefixCount = before.distance(from: before.startIndex, to: r.lowerBound)
        let suffixCount = before.distance(from: r.upperBound, to: before.endIndex)
        // Le texte autour de la dictée doit être intact ; sinon on ne sait pas attribuer les modifications.
        guard after.count >= prefixCount + suffixCount,
              after.prefix(prefixCount) == before.prefix(prefixCount),
              after.suffix(suffixCount) == before.suffix(suffixCount) else { return nil }
        let start = after.index(after.startIndex, offsetBy: prefixCount)
        let end = after.index(after.endIndex, offsetBy: -suffixCount)
        return String(after[start ..< end])
    }
}
