import Foundation
import PlumeCore

/// DEV UNIQUEMENT (`wl-mcp --seed <chemin>`) : crée une base de démonstration via `Store(path:)` (donc le vrai
/// schéma, migrations comprises) pour tester le serveur sans toucher à la base de l'app. Refuse un fichier existant.
enum DevSeed {
    struct Refused: Error, CustomStringConvertible { let description: String }

    static func run(path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Refused(description: "\(path) existe déjà ; --seed ne crée qu'une base neuve")
        }
        let store = try Store(path: path)
        let now = Date()

        var t1 = TranscriptRecord(createdAt: now.addingTimeInterval(-3600), appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                  rawText: "euh salut je regarde le deploiement kubernetes cet aprem",
                                  formattedText: "Salut, je regarde le déploiement Kubernetes cet après-midi.",
                                  finalText: "Salut, je regarde le déploiement Kubernetes cet après-midi.", language: "fr",
                                  audioSeconds: 4.2, asrMs: 310, llmMs: 420, totalMs: 800)
        t1.voice = "casual"
        try store.insert(t1)
        try store.insert(TranscriptRecord(createdAt: now.addingTimeInterval(-86400 * 10), appName: "Mail", rawText: "Bonjour Paul",
                                          formattedText: "Bonjour Paul,", finalText: "Bonjour Paul,", language: "fr"))
        try store.insert(TranscriptRecord(createdAt: now.addingTimeInterval(-120), appName: "Xcode",
                                          rawText: "add a guard for the empty buffer", formattedText: "Add a guard for the empty buffer.",
                                          finalText: "Add a guard for the empty buffer.", language: "en"))

        let start = now.addingTimeInterval(-7200)
        let mid = try store.insert(Meeting(
            title: "Point chantier PV", startedAt: start, endedAt: start.addingTimeInterval(1860), platform: "meet",
            url: "https://meet.google.com/abc-defg-hij", attendees: "Camille, Julien", status: "complete", endReason: "mic_released",
            summary: "Choix de l'onduleur hybride validé. Câblage DC à finaliser avant vendredi ; commande des rails de fixation.",
            notes: "- Onduleur : Victron MultiPlus-II\n- Batterie : 15 kWh", followUpEmail: "Bonjour Julien,\nVoici le récapitulatif…"))
        try store.insert(MeetingSegment(meetingID: mid, speaker: "me", start: 0, end: 5.5, text: "On part sur le MultiPlus-II ?"))
        try store.insert(MeetingSegment(meetingID: mid, speaker: "them", start: 6, end: 14, text: "Oui, et il faut commander les rails cette semaine."))
        try store.insert(MeetingSegment(meetingID: mid, speaker: "me", start: 75, end: 80, text: "Je finis le câblage DC avant vendredi."))
        try store.insert(Todo(meetingID: mid, text: "Commander les rails de fixation", createdAt: start.addingTimeInterval(1900)))
        try store.insert(Todo(meetingID: mid, text: "Envoyer le schéma unifilaire", done: true, createdAt: start.addingTimeInterval(1900), doneAt: now))
        try store.insert(Todo(text: "Relire la PR wl-mcp"))

        // Une semaine de dictées plausibles, pour que l'accueil et l'historique aient l'air habités (captures du README).
        let samples: [(String, String, String, String)] = [
            ("Mail", "com.apple.mail", "fr", "Bonjour Julie, merci pour votre retour. Je vous envoie le devis signé d'ici ce soir."),
            ("Messages", "com.apple.MobileSMS", "fr", "Je pars de l'école dans dix minutes, tu veux que je prenne du pain ?"),
            ("Notes", "com.apple.Notes", "fr", "Idées pour le week-end : marché de Talensac, balade sur l'Erdre, crêpes chez Mamie."),
            ("Slack", "com.tinyspeck.slackmacgap", "fr", "Top, je relis ta proposition après le déjeuner"),
            ("Notion", "notion.id", "fr", "Objectif du trimestre : réduire de moitié le temps de traitement des demandes clients."),
            ("Mail", "com.apple.mail", "en", "Hi Tom, thanks for the quick turnaround. Let's lock the date for Thursday at 3 pm."),
            ("Messages", "com.apple.MobileSMS", "fr", "Rendez-vous chez le pédiatre décalé à 17 h 30, je m'en occupe."),
            ("Pages", "com.apple.iWork.Pages", "fr", "Le projet s'articule autour de trois axes : l'accueil, la formation et le suivi des familles."),
            ("Slack", "com.tinyspeck.slackmacgap", "en", "Shipping the fix now, will ping you when it's live"),
            ("Notes", "com.apple.Notes", "fr", "Liste de courses : tomates, feta, citrons, basilic, pâtes fraîches."),
        ]
        for i in 0 ..< 46 {
            let (app, bid, lang, text) = samples[i % samples.count]
            let words = text.split(separator: " ").count
            let asr = 180 + (i * 37) % 160, llm = 220 + (i * 53) % 260
            try store.insert(TranscriptRecord(createdAt: now.addingTimeInterval(-Double(i) * 13_000 - 600), appName: app, bundleID: bid,
                                              rawText: text, formattedText: text, finalText: text, language: lang,
                                              audioSeconds: Double(words) * 0.42, asrMs: asr, llmMs: llm, totalMs: asr + llm + 40))
        }

        try store.upsert(LexiconEntry(kind: .word, phrase: "Kubernetes", starred: true))
        try store.upsert(LexiconEntry(kind: .replacement, phrase: "cube cuttle", replacement: "kubectl"))
        try store.upsert(LexiconEntry(kind: .snippet, phrase: "ma signature", replacement: "Camille Martin\nhttps://example.com"))
        try store.upsert(VoicePreference(filter: "app:slack", preference: "Ton décontracté, pas de point final."))
    }
}
