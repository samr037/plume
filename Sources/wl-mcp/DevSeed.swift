import Foundation
import PlumeCore

/// DEV UNIQUEMENT (`wl-mcp --seed <chemin>`) : crée une base de démonstration via `Store(path:)` (donc le vrai
/// schéma, migrations comprises) pour tester le serveur sans toucher à la base de l'app. Refuse un fichier existant.
/// `WL_SEED_LANG=en` remplit la base en anglais (captures du README).
enum DevSeed {
    struct Refused: Error, CustomStringConvertible { let description: String }

    /// Contenu fictif d'une langue : dictées (app, bundle, texte), réunion, tâches, dictionnaire.
    private struct Content {
        let lang: String
        let dictations: [(String, String, String)]
        let meeting: (title: String, summary: String, notes: String, email: String)
        let segments: [(String, Double, Double, String)]
        let meetingTodos: [(String, Bool)]
        let todo: String
        let snippet: (String, String)
        let preference: String
    }

    private static let fr = Content(
        lang: "fr",
        dictations: [
            ("Mail", "com.apple.mail", "Bonjour Julie, merci pour votre retour. Je vous envoie le devis signé d'ici ce soir."),
            ("Messages", "com.apple.MobileSMS", "Je pars de l'école dans dix minutes, tu veux que je prenne du pain ?"),
            ("Notes", "com.apple.Notes", "Idées pour le week-end : marché du samedi, balade au bord de l'eau, crêpes chez Mamie."),
            ("Slack", "com.tinyspeck.slackmacgap", "Top, je relis ta proposition après le déjeuner"),
            ("Notion", "notion.id", "Objectif du trimestre : réduire de moitié le temps de traitement des demandes clients."),
            ("Mail", "com.apple.mail", "Bonjour Thomas, je confirme notre rendez-vous de jeudi à 15 h."),
            ("Messages", "com.apple.MobileSMS", "Rendez-vous chez le pédiatre décalé à 17 h 30, je m'en occupe."),
            ("Pages", "com.apple.iWork.Pages", "Le projet s'articule autour de trois axes : l'accueil, la formation et le suivi des familles."),
            ("Slack", "com.tinyspeck.slackmacgap", "Je pousse le correctif, je te préviens quand c'est en ligne"),
            ("Notes", "com.apple.Notes", "Liste de courses : tomates, feta, citrons, basilic, pâtes fraîches."),
        ],
        meeting: ("Point projet cuisine",
                  "Plan de travail validé en quartz. Pose prévue la semaine du 3 novembre ; le devis électricité reste à recevoir.",
                  "- Plan de travail : quartz, finition mate\n- Pose : semaine du 3 novembre\n- En attente : devis électricité",
                  "Bonjour Julien,\nMerci pour cet échange. Voici le récapitulatif…"),
        segments: [("me", 0, 5.5, "On part sur le quartz pour le plan de travail ?"),
                   ("them", 6, 14, "Oui, et je peux caler la pose la semaine du 3 novembre."),
                   ("me", 75, 80, "Parfait, je relance l'électricien pour son devis.")],
        meetingTodos: [("Relancer l'électricien pour le devis", false), ("Envoyer les cotes de la cuisine", true)],
        todo: "Réserver la benne pour l'ancienne cuisine",
        snippet: ("ma signature", "Camille Martin\nhttps://example.com"),
        preference: "Ton décontracté, pas de point final.")

    private static let en = Content(
        lang: "en",
        dictations: [
            ("Mail", "com.apple.mail", "Hi Julia, thanks for getting back to me. I'll send the signed quote over by tonight."),
            ("Messages", "com.apple.MobileSMS", "Leaving school in ten minutes, want me to grab some bread?"),
            ("Notes", "com.apple.Notes", "Weekend ideas: Saturday market, a walk by the river, pancakes at Grandma's."),
            ("Slack", "com.tinyspeck.slackmacgap", "Nice, I'll review your proposal after lunch"),
            ("Notion", "notion.id", "Quarterly goal: cut customer request handling time in half."),
            ("Mail", "com.apple.mail", "Hi Tom, confirming our meeting on Thursday at 3 pm."),
            ("Messages", "com.apple.MobileSMS", "Pediatrician moved to 5:30, I'll take care of it."),
            ("Pages", "com.apple.iWork.Pages", "The project rests on three pillars: outreach, training and family follow-up."),
            ("Slack", "com.tinyspeck.slackmacgap", "Shipping the fix now, will ping you when it's live"),
            ("Notes", "com.apple.Notes", "Groceries: tomatoes, feta, lemons, basil, fresh pasta."),
        ],
        meeting: ("Kitchen project sync",
                  "Quartz countertop approved. Installation planned for the week of November 3; still waiting on the electrician's quote.",
                  "- Countertop: quartz, matte finish\n- Installation: week of November 3\n- Pending: electrician's quote",
                  "Hi Julian,\nThanks for the call. Here's a quick recap…"),
        segments: [("me", 0, 5.5, "Shall we go with quartz for the countertop?"),
                   ("them", 6, 14, "Yes, and I can schedule the install for the week of November 3."),
                   ("me", 75, 80, "Great, I'll chase the electrician for his quote.")],
        meetingTodos: [("Chase the electrician for the quote", false), ("Send the kitchen measurements", true)],
        todo: "Book a dumpster for the old kitchen",
        snippet: ("my signature", "Camille Martin\nhttps://example.com"),
        preference: "Casual tone, no final period.")

    static func run(path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Refused(description: "\(path) existe déjà ; --seed ne crée qu'une base neuve")
        }
        let c = ProcessInfo.processInfo.environment["WL_SEED_LANG"] == "en" ? en : fr
        let store = try Store(path: path)
        let now = Date()

        // Une semaine de dictées plausibles, pour que l'accueil et l'historique aient l'air habités.
        for i in 0 ..< 46 {
            let (app, bid, text) = c.dictations[i % c.dictations.count]
            let words = text.split(separator: " ").count
            let asr = 180 + (i * 37) % 160, llm = 220 + (i * 53) % 260
            var r = TranscriptRecord(createdAt: now.addingTimeInterval(-Double(i) * 13_000 - 600), appName: app, bundleID: bid,
                                     rawText: text, formattedText: text, finalText: text, language: c.lang,
                                     audioSeconds: Double(words) * 0.42, asrMs: asr, llmMs: llm, totalMs: asr + llm + 40)
            if app == "Slack" { r.voice = "casual" }
            try store.insert(r)
        }

        let start = now.addingTimeInterval(-7200)
        let mid = try store.insert(Meeting(
            title: c.meeting.title, startedAt: start, endedAt: start.addingTimeInterval(1860), platform: "meet",
            url: "https://meet.google.com/abc-defg-hij", attendees: "Camille, Julien", status: "complete", endReason: "mic_released",
            summary: c.meeting.summary, notes: c.meeting.notes, followUpEmail: c.meeting.email))
        for (speaker, s, e, text) in c.segments {
            try store.insert(MeetingSegment(meetingID: mid, speaker: speaker, start: s, end: e, text: text))
        }
        for (text, done) in c.meetingTodos {
            try store.insert(Todo(meetingID: mid, text: text, done: done, createdAt: start.addingTimeInterval(1900), doneAt: done ? now : nil))
        }
        try store.insert(Todo(text: c.todo))

        try store.upsert(LexiconEntry(kind: .word, phrase: "Kubernetes", starred: true))
        try store.upsert(LexiconEntry(kind: .replacement, phrase: "cube cuttle", replacement: "kubectl"))
        try store.upsert(LexiconEntry(kind: .snippet, phrase: c.snippet.0, replacement: c.snippet.1))
        try store.upsert(VoicePreference(filter: "app:slack", preference: c.preference))
    }
}
