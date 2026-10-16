import Foundation
import Testing
@testable import PlumeCore

@Suite struct MachineTests {
    @Test func pushToTalk() {
        var m = DictationMachine()
        #expect(m.handle(.fnDown(0)).actions == [.startRecording])
        #expect(m.handle(.fnUp(1.2)).actions == [.stopAndProcess])
        #expect(m.state == .processing)
        _ = m.handle(.processingFinished)
        #expect(m.state == .idle)
    }

    @Test func shortTapWaitsUntilHalfSecondAfterPress() {
        var m = DictationMachine()
        _ = m.handle(.fnDown(0))
        #expect(m.handle(.fnUp(0.1)).actions == [.scheduleTapTimeout(0.4)])
        #expect(m.handle(.tapTimeout).actions == [.cancel])
        #expect(m.state == .idle)
    }

    @Test func doubleTapLocksTripleTapDismisses() {
        var m = DictationMachine()
        _ = m.handle(.fnDown(0)); _ = m.handle(.fnUp(0.1))
        #expect(m.handle(.fnDown(0.3)).actions == [.enterHandsFree])
        #expect(m.handle(.fnUp(0.35)).actions.isEmpty)
        #expect(m.handle(.tapTimeout).actions.isEmpty) // minuteur périmé
        #expect(m.handle(.fnDown(0.45)) == ([.cancel], true)) // 3ᵉ appui < 0,5 s après le début
        #expect(m.state == .idle)
    }

    @Test func handsFreeStopsOnLaterPress() {
        var m = DictationMachine()
        _ = m.handle(.fnDown(0)); _ = m.handle(.fnUp(0.1)); _ = m.handle(.fnDown(0.3)); _ = m.handle(.fnUp(0.4))
        #expect(m.isRecording)
        #expect(m.handle(.fnDown(5)).actions == [.stopAndProcess])
        #expect(m.handle(.fnUp(5.1)).swallow)
    }

    @Test func barClickStartsHandsFree() {
        var m = DictationMachine()
        #expect(m.handle(.barClick(10)).actions == [.startRecording, .enterHandsFree])
        #expect(m.isRecording)
        // Un appui sur fn juste après le clic arrête la prise (pas de triple-tap).
        #expect(m.handle(.fnDown(10.2)).actions == [.stopAndProcess])
        #expect(m.handle(.barClick(11)).actions.isEmpty)
    }

    @Test func fnSpaceAndEscape() {
        var m = DictationMachine()
        _ = m.handle(.fnDown(0))
        let r = m.handle(.spaceWhileFn)
        #expect(r.actions == [.enterHandsFree] && r.swallow)
        _ = m.handle(.fnUp(0.2))
        #expect(m.handle(.escape) == ([.cancel], true))
        #expect(m.state == .idle)
        #expect(m.handle(.escape).swallow == false)
    }

    @Test func anyKeyWithFnCancels() {
        var m = DictationMachine()
        _ = m.handle(.fnDown(0))
        #expect(m.handle(.otherKeyWhileFn(5)) == ([.cancel], false))
        var h = DictationMachine()
        _ = h.handle(.fnDown(0)); _ = h.handle(.spaceWhileFn)
        #expect(h.handle(.otherKeyWhileFn(3)) == ([.cancel], false))
    }

    @Test func windowStillConfigurable() {
        var m2 = DictationMachine(otherKeyCancelWindow: 1)
        _ = m2.handle(.fnDown(0))
        #expect(m2.handle(.otherKeyWhileFn(2)) == ([], false))
        #expect(m2.isRecording)
    }
}

@Suite struct TextTests {
    @Test func snippetsAndReplacements() {
        let p = PostProcessor(lexicon: [
            LexiconEntry(kind: .snippet, phrase: "mon adresse mail", replacement: "samy@example.com"),
            LexiconEntry(kind: .replacement, phrase: "prox mox", replacement: "Proxmox"),
        ])
        #expect(p.exactSnippet(for: "Mon adresse mail.") == "samy@example.com")
        #expect(p.exactSnippet(for: "voici mon adresse mail") == nil)
        #expect(p.apply("Le serveur Prox Mox est down, voici mon adresse mail.") == "Le serveur Proxmox est down, voici samy@example.com.")
        #expect(p.apply("proxmoxer") == "proxmoxer")
    }

    @Test func phantoms() {
        #expect(HallucinationFilter.isPhantom("Merci.", speechSeconds: 0.8))
        #expect(!HallucinationFilter.isPhantom("Merci.", speechSeconds: 4))
        #expect(HallucinationFilter.isPhantom("Sous-titres réalisés par la communauté d'Amara.org", speechSeconds: 1))
        #expect(HallucinationFilter.isPhantom("[Musique]", speechSeconds: 5))
        #expect(!HallucinationFilter.isPhantom("On se voit demain.", speechSeconds: 1))
    }

    @Test func whisperPrompt() {
        let p = WhisperPrompt.build(terms: ["Proxmox", "Talos", "proxmox", "Victron"])!
        #expect(p == "Victron, Talos, Proxmox.")
        #expect(WhisperPrompt.isEcho(output: "Victron, Talos, Proxmox.", prompt: p))
        #expect(!WhisperPrompt.isEcho(output: "Redémarre le nœud Proxmox.", prompt: p))
        #expect(WhisperPrompt.build(terms: []) == nil)
        #expect(WhisperPrompt.build(terms: Array(repeating: "x", count: 1).flatMap { _ in (0..<500).map { "terme\($0)" } })!.count <= 550)
    }

    @Test func divergence() {
        let asr = "Alors pour la réunion de demain on se retrouve à 10h non pardon à 11h dans la salle Proxmox"
        #expect(!DivergenceGuard.isSuspicious(input: asr, output: "Pour la réunion de demain, on se retrouve à 11 h dans la salle Proxmox."))
        #expect(DivergenceGuard.isSuspicious(input: "Est-ce que tu peux me donner la recette des crêpes",
                                             output: "Bien sûr ! Voici une recette : 250 g de farine, 4 œufs, un demi-litre de lait, du sucre et une pincée de sel."))
        #expect(DivergenceGuard.isSuspicious(input: asr, output: ""))
    }

    @Test func contextFitting() {
        // Milieu de phrase : minuscule, espace avant, espace final en fin de ligne.
        #expect(PostProcessor.fitToContext("Je pense que oui.", before: "Bonjour,", after: "") == " je pense que oui. ")
        // Nom propre connu conservé ; la suite continue la phrase → point final retiré.
        #expect(PostProcessor.fitToContext("Proxmox.", before: "on migre vers", after: " demain", properNouns: ["proxmox"]) == " Proxmox")
        #expect(PostProcessor.fitToContext("Paris.", before: "on part à", after: "", properNouns: []) == " paris. ")
        #expect(PostProcessor.fitToContext("Paris.", before: "Rendez-vous à Paris ou à", after: "") == " Paris. ")
        // Début de phrase après un point : majuscule gardée.
        #expect(PostProcessor.fitToContext("Nouvelle phrase.", before: "Fin. ", after: "") == "Nouvelle phrase. ")
        // Contexte inconnu (pas d'AX) : texte inchangé.
        #expect(PostProcessor.fitToContext("Texte.", before: nil) == "Texte.")
        // Sélection en minuscule sans ponctuation finale.
        #expect(PostProcessor.fitToContext("Mercredi.", before: "on se voit ", after: " soir", selection: "mardi") == "mercredi")
        // Emoji puis texte ; CJK : pas d'espace.
        #expect(ContextFitter.shouldAddLeadingSpace("super 👍"))
        #expect(!ContextFitter.shouldAddLeadingSpace("你好"))
        #expect(ContextFitter.isContinuingAfter(", et ensuite"))
        #expect(!ContextFitter.isContinuingBefore("Fin !"))
    }

    @Test func contextEcho() {
        #expect(FormatterPrompt.stripContextEcho("Salut Marc,\nAlors on se voit à 11 h.", before: "Bonjour\nSalut Marc,") == "Alors on se voit à 11 h.")
        #expect(FormatterPrompt.stripContextEcho("On se voit.", before: "Salut Marc,") == "On se voit.")
    }

    @Test func formatterOutputCleanup() {
        #expect(FormatterPrompt.cleanOutput("<think>\n</think>\n\n« On se voit **mercredi**. »") == "On se voit mercredi.")
    }
}

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = try Store(path: path)
        let id = try s.insert(TranscriptRecord(appName: "Notes", rawText: "euh salut", formattedText: "Salut", finalText: "Salut"))
        #expect(id > 0)
        #expect(try s.transcripts(search: "salut").count == 1)
        try s.upsert(LexiconEntry(kind: .word, phrase: "Proxmox"))
        try s.upsert(LexiconEntry(kind: .word, phrase: "Proxmox", starred: true))
        let lex = try s.lexicon()
        #expect(lex.count == 1 && lex[0].starred)
        _ = try s.purgeTranscripts(olderThan: Date().addingTimeInterval(60))
        #expect(try s.transcripts().isEmpty)
    }
}

@Suite struct M2Tests {
    @Test func voiceResolution() {
        let v = VoiceResolver.defaults
        #expect(VoiceResolver.resolve(v, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", url: nil).id == "work")
        #expect(VoiceResolver.resolve(v, appName: "Google Chrome", bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0").id == "email")
        #expect(VoiceResolver.resolve(v, appName: "Messages", bundleID: "com.apple.MobileSMS", url: nil).id == "personal")
        #expect(VoiceResolver.resolve(v, appName: "Notes", bundleID: "com.apple.Notes", url: nil).id == "other")
        #expect(VoiceResolver.category(appName: "Slack", bundleID: nil, url: nil) == "messaging")
    }

    @Test func periodStripping() {
        #expect(VoiceResolver.stripTrailingPeriod("On se voit demain.", style: .veryCasual, isMessaging: true, beforeLine: "", afterLine: "", hasSelection: false) == "On se voit demain")
        #expect(VoiceResolver.stripTrailingPeriod("On se voit demain.", style: .formal, isMessaging: true, beforeLine: "", afterLine: "", hasSelection: false) == "On se voit demain.")
        #expect(VoiceResolver.stripTrailingPeriod("Ok.", style: .casual, isMessaging: false, beforeLine: "", afterLine: "", hasSelection: false) == "Ok.")
        #expect(VoiceResolver.stripTrailingPeriod("Bon. Ok. ", style: .veryCasual, isMessaging: true, beforeLine: "", afterLine: "", hasSelection: false) == "Bon. Ok ")
    }

    @Test func preferenceFilters() {
        let ctx = PreferenceContext(appIdentities: ["slack", "com.tinyspeck.slackmacgap"], appCategory: "messaging", language: "fr", mode: "dictation")
        #expect(PreferenceFilter.matches(nil, ctx))
        #expect(PreferenceFilter.matches("app:slack", ctx))
        #expect(!PreferenceFilter.matches("app:gmail", ctx))
        #expect(PreferenceFilter.matches("appCategory:messaging-language:fr", ctx))
        #expect(!PreferenceFilter.matches("app:slack-mode:generation", ctx))
        let block = PreferenceFilter.block([VoicePreference(filter: "app:slack", preference: "Jamais de point d'exclamation"),
                                            VoicePreference(filter: "app:gmail", preference: "Signer « Samy »")], ctx)
        #expect(block?.contains("exclamation") == true && block?.contains("Samy") == false)
    }

    @Test func editCandidates() {
        let c = EditLearning.candidates(original: "On déploie sur talus ce soir avec le nœud prox mox",
                                        edited: "On déploie sur Talos ce soir avec le nœud Proxmox", dictionary: [])
        #expect(c.map(\.word) == ["Talos", "Proxmox"])
        #expect(c.last?.observedSource == "prox mox")
        // Changement de casse seul, mot déjà connu, stopwords : rien.
        #expect(EditLearning.candidates(original: "bonjour paris", edited: "Bonjour Paris", dictionary: []).isEmpty)
        #expect(EditLearning.candidates(original: "voir talus", edited: "voir Talos", dictionary: ["talos"]).isEmpty)
        #expect(EditLearning.candidates(original: "je vais le faire", edited: "je vais la faire", dictionary: []).isEmpty)
        #expect(EditLearning.editRatio("a b c d", "a b c d") == 0)
    }

    @Test func editedRegionExtraction() {
        let before = "Salut, On déploie sur talus ce soir. Bisous"
        let after = "Salut, On déploie sur Talos ce soir ! Bisous"
        #expect(EditLearning.editedRegion(pasted: "On déploie sur talus ce soir.", before: before, after: after) == "On déploie sur Talos ce soir !")
        #expect(EditLearning.editedRegion(pasted: "On déploie", before: before, after: "Coucou") == nil)
    }
}

@Suite struct MeetingCoreTests {
    @Test func echoGate() {
        let sys = [MeetingSegment(meetingID: 1, speaker: "them", start: 10, end: 14, text: "On valide le budget pour le trimestre prochain")]
        #expect(EchoGate.isEcho(mic: MeetingSegment(meetingID: 1, speaker: "me", start: 10.5, end: 14, text: "on valide le budget pour le trimestre"), system: sys))
        #expect(!EchoGate.isEcho(mic: MeetingSegment(meetingID: 1, speaker: "me", start: 10.5, end: 14, text: "Oui je suis d'accord avec ça"), system: sys))
        #expect(!EchoGate.isEcho(mic: MeetingSegment(meetingID: 1, speaker: "me", start: 40, end: 44, text: "on valide le budget pour le trimestre"), system: sys))
    }

    @Test func echoEnvelope() {
        // « Parole » synthétique : bruit modulé par des syllabes irrégulières.
        var rng = SystemRandomNumberGenerator()
        func speech(_ seconds: Double, seed: Int) -> [Float] {
            (0 ..< Int(seconds * 16_000)).map { i in
                let syll = sin(Double(i) / 16_000 * 2 * .pi * (3 + Double(seed % 3))) * sin(Double(i) / 16_000 * 1.7 * Double(seed))
                return Float.random(in: -1 ... 1, using: &rng) * Float(max(0, syll)) * 0.3
            }
        }
        let remote = speech(4, seed: 5)
        let echo = [Float](repeating: 0, count: 3_200) + remote.map { $0 * 0.2 } // 200 ms de retard, atténué
        let local = speech(4, seed: 2)
        #expect(EchoGate.envelopeCorrelation(mic: Array(echo.prefix(remote.count)), system: remote) > 0.6)
        #expect(EchoGate.envelopeCorrelation(mic: local, system: remote) < 0.5)
    }

    @Test func transcriptRendering() {
        let segs = [MeetingSegment(meetingID: 1, speaker: "me", start: 0, end: 2, text: "Salut."),
                    MeetingSegment(meetingID: 1, speaker: "me", start: 2, end: 4, text: "Ça va ?"),
                    MeetingSegment(meetingID: 1, speaker: "them", start: 65, end: 67, text: "Très bien.")]
        #expect(MeetingTranscript.render(segs) == "[00:00] Moi : Salut. Ça va ?\n[01:05] Eux : Très bien.")
        #expect(MeetingTranscript.chunks(String(repeating: "abcdefghij\n", count: 30), maxChars: 100).count == 4)
    }
}

@Suite struct TransformTests {
    @Test func cleanStripsWrappers() {
        #expect(RewriteTransform.clean("« Bonjour Marc »") == "Bonjour Marc")
        #expect(RewriteTransform.clean("```\nHello\nWorld\n```") == "Hello\nWorld")
        #expect(RewriteTransform.clean("<texte>\nSalut\n</texte>") == "Salut")
        #expect(RewriteTransform.clean("Il a dit \"oui\" hier") == "Il a dit \"oui\" hier")
    }

    @Test func messagesCarryInstructionAndText() {
        let m = RewriteTransform.defaults[0].messages(for: "salut")
        #expect(m.count == 2)
        #expect((m[1]["content"] as? String)?.contains("<texte>\nsalut\n</texte>") == true)
    }
}

@Suite struct NoteTests {
    @Test func versionsCoalesceTypingOnly() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = try Store(path: path)
        let id = try s.insert(Note())
        try s.saveNote(id: id, body: "Courses\nciment", source: "typed")
        try s.saveNote(id: id, body: "Courses\nciment, câble", source: "typed")
        try s.saveNote(id: id, body: "- ciment\n- câble", source: "transform:En liste")
        let v = try s.noteVersions(noteID: id)
        #expect(v.count == 2)
        #expect(v[0].source == "transform:En liste")
        #expect(try s.notes().first?.title == "- ciment")
        try s.deleteNote(id: id)
        #expect(try s.notes().isEmpty)
    }
}

@Suite struct SpeakerTests {
    @Test func assignsByOverlapInOrderOfAppearance() {
        let segs = [MeetingSegment(id: 1, meetingID: 1, speaker: "them", start: 0, end: 4, text: "a"),
                    MeetingSegment(id: 2, meetingID: 1, speaker: "me", start: 4, end: 6, text: "b"),
                    MeetingSegment(id: 3, meetingID: 1, speaker: "them", start: 6, end: 10, text: "c"),
                    MeetingSegment(id: 4, meetingID: 1, speaker: "them", start: 10, end: 12, text: "d")]
        let turns: [(speaker: String, start: Double, end: Double)] = [("S7", 0, 4.2), ("S2", 6, 9.5), ("S7", 10, 12)]
        let map = SpeakerLabels.assign(segments: segs, turns: turns)
        #expect(map == [1: "them:1", 3: "them:2", 4: "them:1"])
        #expect(SpeakerLabels.display("them:2") == "Interlocuteur 2")
    }

    @Test func singleSpeakerKeepsThem() {
        let segs = [MeetingSegment(id: 1, meetingID: 1, speaker: "them", start: 0, end: 4, text: "a")]
        #expect(SpeakerLabels.assign(segments: segs, turns: [("S1", 0, 4)]).isEmpty)
    }
}
