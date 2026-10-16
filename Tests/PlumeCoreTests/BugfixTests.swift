import Foundation
import Testing
@testable import PlumeCore

@Suite struct BugfixTests {
    // #8 : un acronyme dicté seul en milieu de phrase garde sa casse.
    @Test func singleWordAcronymKeepsCase() {
        #expect(PostProcessor.fitToContext("OK", before: "Pour moi c'est", after: "") == " OK ")
        #expect(PostProcessor.fitToContext("USB", before: "branche le câble", after: "") == " USB ")
        #expect(PostProcessor.fitToContext("I", before: "and then", after: "") == " I ")
        // Un mot ordinaire seul est toujours passé en minuscule.
        #expect(PostProcessor.fitToContext("Paris.", before: "on part à", after: "") == " paris. ")
    }

    // #28 : les fences d'un bloc de code sélectionné sont conservées.
    @Test func rewriteCleanKeepsSourceFences() {
        let fenced = "```bash\necho hi\n```"
        #expect(RewriteTransform.clean(fenced, source: "```bash\necho  hi\n```") == fenced)
        #expect(RewriteTransform.clean("```\nHello\n```", source: "hello") == "Hello")
        #expect(RewriteTransform.clean("```\nHello\n```") == "Hello")
    }

    // #29 : pas de coupe sans frontière de mot, ni quand le curseur est en début de ligne, ni quand la dictée répète la ligne.
    @Test func contextEchoNeedsBoundaryAndMidLineCursor() {
        #expect(FormatterPrompt.stripContextEcho("Rappels à faire demain.", before: "Rappel\n") == "Rappels à faire demain.")
        #expect(FormatterPrompt.stripContextEcho("Rappels à faire demain.", before: "Rappel") == "Rappels à faire demain.")
        #expect(FormatterPrompt.stripContextEcho("Salut Marc, ça va ?", before: "Salut Marc,",
                                                 transcript: "salut marc ça va") == "Salut Marc, ça va ?")
        #expect(FormatterPrompt.stripContextEcho("Salut Marc,", before: "Salut Marc,") == "Salut Marc,")
        // L'écho réel reste retiré.
        #expect(FormatterPrompt.stripContextEcho("Salut Marc, ça va ?", before: "Salut Marc,", transcript: "ça va")
            == "ça va ?")
    }

    // #32 : la passe sans accents ne re-matche pas dans le remplacement.
    @Test func foldedReplacementDoesNotDuplicate() {
        #expect(PostProcessor.replaceWholeWords(in: "j'ai vu hélène hier", phrase: "Hélène", with: "Helene Dupont")
            == "j'ai vu Helene Dupont hier")
        #expect(PostProcessor.replaceWholeWords(in: "j'ai vu helene hier", phrase: "Hélène", with: "Helene Dupont")
            == "j'ai vu Helene Dupont hier")
        #expect(PostProcessor.replaceWholeWords(in: "Hélène et helene", phrase: "Hélène", with: "Hélène D.")
            == "Hélène D. et Hélène D.")
    }
}
