import AppKit
import ApplicationServices
import PlumeCore

/// Observe le champ après un collage : relecture AX toutes les secondes pendant 60 s,
/// arrêt anticipé au changement de champ ou à la touche Entrée. Renvoie la portion éditée de la dictée.
@MainActor
final class EditObserver {
    struct Observation {
        var transcriptID: Int64
        var pasted: String
        var edited: String
    }

    private var timer: Timer?
    private var element: AXUIElement?
    private var pasted = ""
    private var valueAfterPaste = ""
    private var lastValue = ""
    private var transcriptID: Int64 = 0
    private var startedAt = Date()
    private var onFinish: ((Observation?) -> Void)?

    /// Vérifie que le texte collé apparaît dans le champ. nil = champ illisible.
    static func verify(element: AXUIElement, pasted: String) -> Bool? {
        guard let value = ContextReader.value(of: element) else { return nil }
        let needle = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains(needle) || value.replacingOccurrences(of: "\u{00A0}", with: " ").contains(needle)
    }

    func start(element: AXUIElement, pasted: String, transcriptID: Int64, onFinish: @escaping (Observation?) -> Void) {
        finish(reason: "replaced") // une nouvelle dictée clôt la précédente
        guard let value = ContextReader.value(of: element) else { return }
        self.element = element
        self.pasted = pasted
        self.valueAfterPaste = value
        self.lastValue = value
        self.transcriptID = transcriptID
        self.startedAt = Date()
        self.onFinish = onFinish
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Entrée = message envoyé : la dernière valeur lue est la version finale.
    func returnPressed() { if timer != nil { finish(reason: "enter") } }

    private func tick() {
        guard let element else { return }
        if Date().timeIntervalSince(startedAt) >= 60 { finish(reason: "window_elapsed"); return }
        if let focused = ContextReader.focusedElement(), !CFEqual(focused, element) { finish(reason: "focus_changed"); return }
        if let v = ContextReader.value(of: element) { lastValue = v }
    }

    private func finish(reason: String) {
        timer?.invalidate()
        timer = nil
        guard let cb = onFinish else { return }
        onFinish = nil
        element = nil
        guard lastValue != valueAfterPaste,
              let edited = EditLearning.editedRegion(pasted: pasted, before: valueAfterPaste, after: lastValue) else {
            cb(nil)
            return
        }
        Log.write("Observation d'édition terminée (\(reason))")
        cb(Observation(transcriptID: transcriptID, pasted: pasted, edited: edited))
    }
}
