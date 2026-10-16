import AppKit
import ApplicationServices
import Carbon
import PlumeCore

// MARK: - Contexte AX (AXValue + AXSelectedTextRange de l'élément focalisé)

enum ContextReader {
    struct Result {
        var context: DictationContext
        var isSecure: Bool
        /// Champ focalisé (pour la vérification après collage et l'observation des corrections).
        var element: AXUIElement? = nil
        var pid: pid_t? = nil
        /// URL de la page web active (navigateurs), pour résoudre Gmail, Slack web…
        var url: String? = nil
        /// Le champ expose sa valeur texte via AX.
        var readable: Bool { element != nil && context.before != nil }
    }

    /// Lecture bornée : timeout AX de 150 ms par appel, 500 caractères de part et d'autre du curseur.
    static func capture(readText: Bool) -> Result {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = DictationContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
        guard readText, AXIsProcessTrusted(), let pid = app?.processIdentifier else { return Result(context: ctx, isSecure: false) }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        // Apps Electron/Chromium : l'arbre AX n'est exposé qu'après ce flag.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return Result(context: ctx, isSecure: false) }
        let el = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        let url = webURL(from: el)

        if let subrole = copyString(el, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) {
            return Result(context: ctx, isSecure: true, pid: pid, url: url)
        }
        guard let value = copyString(el, kAXValueAttribute) else { return Result(context: ctx, isSecure: false, element: el, pid: pid, url: url) }
        let ns = value as NSString
        var range = CFRange(location: ns.length, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success, let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        }
        let loc = max(0, min(range.location, ns.length))
        let len = max(0, min(range.length, ns.length - loc))
        let beforeStart = max(0, loc - 500)
        ctx.before = ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
        if len > 0 { ctx.selection = ns.substring(with: NSRange(location: loc, length: len)) }
        let afterStart = loc + len
        ctx.after = ns.substring(with: NSRange(location: afterStart, length: min(500, ns.length - afterStart)))
        return Result(context: ctx, isSecure: false, element: el, pid: pid, url: url)
    }

    /// Valeur texte complète d'un élément (relecture après collage).
    static func value(of el: AXUIElement) -> String? { copyString(el, kAXValueAttribute) }

    /// Élément focalisé courant, pour détecter un changement de champ.
    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Remonte les parents jusqu'à l'AXWebArea pour lire son AXURL (Chrome, Safari, Arc, Edge…).
    private static func webURL(from el: AXUIElement) -> String? {
        var current: AXUIElement? = el
        for _ in 0 ..< 40 {
            guard let c = current else { return nil }
            if copyString(c, kAXRoleAttribute) == "AXWebArea" {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(c, kAXURLAttribute as CFString, &ref) == .success {
                    if let u = ref as? URL { return u.absoluteString }
                    if let s = ref as? String { return s }
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

// MARK: - Insertion par presse-papier paresseux + Cmd+V

final class Paster: NSObject, NSPasteboardItemDataProvider {
    enum Outcome { case pasted, leftInClipboard }

    /// État d'un collage en cours : chaque attente de lecture a sa propre continuation et son propre timeout.
    private final class PendingRead {
        var wasRead = false
        var continuation: CheckedContinuation<Bool, Never>?
    }

    // Tout l'état ci-dessous n'est lu/écrit que sur le main thread (méthodes @MainActor + callback AppKit).
    private var pendingText = ""
    private var current: PendingRead?
    /// Dernier collage lancé : le suivant l'attend, les collages sont donc strictement sérialisés.
    private var lastPaste: Task<Outcome, Never>?
    /// Restauration programmée mais pas encore faite : un collage suivant reprend ce contenu d'origine
    /// au lieu de capturer le texte dicté précédent (sinon le presse-papier de l'utilisateur serait perdu).
    private var pendingRestore: (saved: [NSPasteboardItem], change: Int)?

    /// Colle `text` dans l'app au premier plan. Succès = l'app cible a réellement lu le presse-papier ;
    /// on restaure alors le contenu précédent 500 ms plus tard. Sinon le texte reste dans le presse-papier.
    /// Les appels concurrents sont mis en file : chacun attend la fin du précédent.
    @MainActor
    func paste(_ text: String) async -> Outcome {
        let previous = lastPaste
        let task = Task { @MainActor () -> Outcome in
            _ = await previous?.value
            return await self.performPaste(text)
        }
        lastPaste = task
        return await task.value
    }

    @MainActor
    private func performPaste(_ text: String) async -> Outcome {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem]?
        if let r = pendingRestore, pb.changeCount == r.change {
            saved = r.saved
        } else {
            saved = Self.snapshot(pb)
        }
        pendingRestore = nil

        pendingText = text
        let pending = PendingRead()
        current = pending
        defer { if current === pending { current = nil } }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        // Les gestionnaires de presse-papier respectant nspasteboard.org n'enregistrent pas ces éléments.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        postCommandV()

        let read = await waitForRead(pending, timeout: 1.0)
        guard read else { return .leftInClipboard }
        // Restauration 500 ms plus tard, en arrière-plan : le collage est déjà fait, la latence s'arrête ici.
        if let saved {
            pendingRestore = (saved, ourChange)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let r = self.pendingRestore, r.change == ourChange else { return }
                self.pendingRestore = nil
                guard pb.changeCount == ourChange else { return }
                pb.clearContents()
                pb.writeObjects(r.saved)
            }
        }
        return .pasted
    }

    /// Recopie le presse-papier dans un nouvel objet sans lazy-provider.
    @MainActor
    func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        return items.map { old in
            let copy = NSPasteboardItem()
            for t in old.types { if let d = old.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    /// Attend que l'app cible lise `pending`. Le timeout ne touche que la continuation de ce collage-ci.
    @MainActor
    private func waitForRead(_ pending: PendingRead, timeout: TimeInterval) async -> Bool {
        if pending.wasRead { return true }
        return await withCheckedContinuation { cont in
            pending.continuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard let c = pending.continuation else { return }
                pending.continuation = nil
                c.resume(returning: pending.wasRead)
            }
        }
    }

    // NSPasteboardItemDataProvider : appelé quand l'app cible lit réellement les données.
    // AppKit l'appelle sur le main thread ; par sécurité on y revient si ce n'est pas le cas.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.pasteboard(pasteboard, item: item, provideDataForType: type) }
            return
        }
        item.setString(pendingText, forType: type)
        guard let pending = current else { return }
        pending.wasRead = true
        if let c = pending.continuation {
            pending.continuation = nil
            c.resume(returning: true)
        }
    }

    private func postCommandV() {
        let src = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? 9)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            e.post(tap: .cghidEventTap)
            if down { usleep(5_000) } // 5 ms entre down et up
        }
    }
}

enum KeyboardLayout {
    /// Keycode produisant `char` dans la disposition clavier courante (AZERTY, QWERTY, Dvorak…). Main thread.
    static func keyCode(for char: Character) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> Int? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0 ..< 128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1) == String(char) { return code }
            }
            return nil
        }
    }
}
