import AppKit
import Carbon
import CoreGraphics
import PlumeCore

/// Marqueur posé sur les événements synthétisés par l'app (Cmd+V) pour que le tap les ignore.
let syntheticEventMarker: Int64 = 0x574C_4F43 // "WLOC"

/// CGEventTap actif sur un thread dédié.
/// La machine d'états tourne sur le thread du tap pour décider immédiatement d'avaler ou non l'événement ;
/// les actions sont renvoyées sur le main thread.
final class HotkeyService {
    var onActions: (([DictationMachine.Action]) -> Void)?
    var onPasteLast: (() -> Void)?
    /// ⌃⌥1 … ⌃⌥9 : réécriture rapide n° 0 … 8.
    var onTransform: ((Int) -> Void)?
    /// ⌃⌥N : bloc-notes.
    var onScratchpad: (() -> Void)?
    /// Saisie sécurisée active (Terminal « Secure Keyboard Entry », 1Password…) : le tap ne reçoit plus le clavier.
    var onSecureInputChanged: ((Bool) -> Void)?
    /// Keycode de la touche « v » dans la disposition courante (mis à jour depuis le main thread).
    var pasteKeyCode: Int64 = 9

    private var machine = DictationMachine()
    private let lock = NSLock()
    private var fnHeld = false
    private var lastModifierFlags: CGEventFlags = []
    private let modifierMask: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
    /// ⌃ maintenu au moment de l'appui sur fn : la prise est une commande Instruct.
    private(set) var startedAsInstruct = false
    var onReturnKey: (() -> Void)?
    private var swallowedKeyUps = Set<Int64>()
    private var tap: CFMachPort?
    /// Run loop du thread du tap (protégé par `lock`) : la réconciliation de fn y est exécutée, là où vit `fnHeld`.
    private var tapRunLoop: CFRunLoop?
    private var watchdog: Timer?
    private var secureInput = false

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return machine.isRecording }

    func start() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            self?.lock.lock(); self?.tapRunLoop = rl; self?.lock.unlock()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "wl.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        startWatchdog()
        return true
    }

    /// Toutes les 2 s : réactive le tap si macOS l'a coupé, et signale la saisie sécurisée.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            var reconcile = false
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                reconcile = true
            }
            let secure = IsSecureEventInputEnabled()
            if secure != self.secureInput {
                self.secureInput = secure
                self.onSecureInputChanged?(secure)
                if !secure { reconcile = true }
            }
            if reconcile { self.scheduleFnReconciliation() }
        }
    }

    /// Exécute `reconcileFn` sur le thread du tap (seul propriétaire de `fnHeld`).
    private func scheduleFnReconciliation() {
        lock.lock(); let rl = tapRunLoop; lock.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in self?.reconcileFn() }
        CFRunLoopWakeUp(rl)
    }

    /// Thread du tap. Un relâchement de fn perdu pendant que le tap était coupé (timeout, saisie sécurisée…)
    /// laisserait la prise tourner : on relit l'état matériel et on rejoue le fnUp manquant.
    private func reconcileFn() {
        guard fnHeld, !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) else { return }
        fnHeld = false
        _ = feed(.fnUp(ProcessInfo.processInfo.systemUptime))
    }

    /// Clic sur la barre flottante : dictée mains libres, jamais en mode Instruct.
    func startFromBar() {
        startedAsInstruct = false
        send(.barClick(ProcessInfo.processInfo.systemUptime))
    }

    /// Événements non clavier (timeouts, fin de traitement, boutons du panneau), depuis le main thread.
    func send(_ event: DictationMachine.Event) {
        _ = feed(event)
    }

    private func feed(_ event: DictationMachine.Event) -> Bool {
        // Les actions sont mises en file *sous le verrou* : leur ordre sur le main thread est celui des
        // transitions de la machine, même quand le main thread et le thread du tap l'alimentent en même temps.
        lock.lock()
        defer { lock.unlock() }
        let r = machine.handle(event)
        if !r.actions.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onActions?(r.actions) }
        }
        return r.swallow
    }

    /// Appelé sur le thread du tap. Renvoie true pour avaler l'événement.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reconcileFn()
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged:
            let mods = event.flags.intersection(modifierMask)
            defer { lastModifierFlags = mods }
            if code == 63 || code == 179 { // fn / Globe
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != fnHeld else { return true }
                fnHeld = down
                if down { startedAsInstruct = mods == .maskControl }
                return feed(down ? .fnDown(now) : .fnUp(now))
            }
            // Un modificateur *pressé* pendant que fn est maintenu annule ; un relâchement (⌃ de fn+⌃) est ignoré.
            if fnHeld, !mods.subtracting(lastModifierFlags).isEmpty { _ = feed(.otherKeyWhileFn(now)) }
            return false

        case .keyDown:
            // Réconciliation : fn relâché sans flagsChanged reçu (tap désactivé un instant, sécurité clavier…).
            if fnHeld && !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) {
                fnHeld = false
                _ = feed(.fnUp(now))
            }
            if swallowedKeyUps.contains(code), event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            if code == 36 || code == 76 { DispatchQueue.main.async { [weak self] in self?.onReturnKey?() } }
            if code == 53 { // Échap
                if feed(.escape) { swallowedKeyUps.insert(code); return true }
                return false
            }
            if fnHeld {
                if code == 49, feed(.spaceWhileFn) { swallowedKeyUps.insert(code); return true }
                _ = feed(.otherKeyWhileFn(now))
                return false
            }
            let f = event.flags
            if code == 45, f.contains(.maskControl), f.contains(.maskAlternate), !f.contains(.maskCommand), !f.contains(.maskShift) {
                swallowedKeyUps.insert(code)
                DispatchQueue.main.async { [weak self] in self?.onScratchpad?() }
                return true
            }
            // Codes physiques des touches 1 … 9 de la rangée du haut (identiques en AZERTY et QWERTY).
            let digitKeys: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
            if let n = digitKeys.firstIndex(of: code), f.contains(.maskControl), f.contains(.maskAlternate),
               !f.contains(.maskCommand), !f.contains(.maskShift) {
                swallowedKeyUps.insert(code)
                DispatchQueue.main.async { [weak self] in self?.onTransform?(n) }
                return true
            }
            if code == pasteKeyCode, f.contains(.maskCommand), f.contains(.maskControl), !f.contains(.maskAlternate) {
                swallowedKeyUps.insert(code)
                DispatchQueue.main.async { [weak self] in self?.onPasteLast?() }
                return true
            }
            return false

        case .keyUp:
            return swallowedKeyUps.remove(code) != nil

        default:
            return false
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
    return service.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
