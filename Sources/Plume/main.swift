import AppKit
import FluidAudio
import SwiftUI
import PlumeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var meetings: MeetingController!
    private var meetingItem: NSMenuItem?
    private var onboarding: OnboardingController!
    private var scratchpad: ScratchpadController!
    private var hubWindow: NSWindow?
    private let state = AppState()
    private var store: Store!
    private var permissionTimer: Timer?
    private var hotkeysInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store(path: AppSettings.supportDirectory.appendingPathComponent("plume.sqlite").path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Base de données inaccessible"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        controller = DictationController(state: state, store: store)
        Log.write("Lancement")
        meetings = MeetingController(state: state, store: store, transcriber: controller.transcriber, vad: controller.vad) { [weak self] in
            self?.controller.llmClient ?? LLMClient(endpoint: AppSettings.shared.llmEndpoint, model: AppSettings.shared.llmModelName)
        }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // Rend chaque page (clair + sombre) en PNG, sans fenêtre visible ni autorisation de capture d'écran.
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Task {
                controller.startEngines()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                state.accessibilityGranted = AXIsProcessTrusted()
                state.microphoneGranted = AudioRecorder.hasPermission
                let actions = MeetingActions(summarize: { _ in }, setDetection: { _ in })
                for dark in [false, true] {
                    let suffix = dark ? "dark" : "light"
                    for p in HubView.Page.allCases {
                        await Snapshot.render(HubView(state: state, settings: AppSettings.shared, store: store, meetingActions: actions, initialPage: p),
                                              size: NSSize(width: 1180, height: 760), dark: dark, to: dir.appendingPathComponent("hub-\(p.rawValue)-\(suffix).png"))
                    }
                    let bars: [(String, StatusModel.Phase, Bool, BarEdge)] = [
                        ("idle", .hidden, false, .bottom), ("hover", .hidden, true, .bottom), ("recording", .recording(handsFree: true), false, .bottom),
                        ("right-idle", .hidden, false, .right), ("right-hover", .hidden, true, .right),
                        ("right-recording", .recording(handsFree: true), false, .right), ("right-processing", .processing, false, .right),
                    ]
                    for (name, phase, hovering, edge) in bars {
                        let m = StatusModel()
                        m.phase = phase; m.hovering = hovering; m.visible = true; m.edge = edge
                        m.levels = [0.1, 0.3, 0.6, 0.4, 0.8, 0.5, 0.3, 0.6, 0.2, 0.1]
                        await Snapshot.render(StatusPillView(model: m, onCancel: {}, onStop: {}, onCopy: { _ in }, onDismiss: {}, onStart: {},
                                                             onDragChanged: {}, onDragEnded: { _ in }),
                                              size: NSSize(width: 320, height: 200), dark: dark, to: dir.appendingPathComponent("bar-\(name)-\(suffix).png"))
                    }
                    // Base temporaire : le brouillon d'exemple ne doit jamais atteindre la vraie base.
                    let tmpStore = try! Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("wl-snap-\(UUID()).sqlite").path)
                    let pad = ScratchpadModel(store: tmpStore)
                    pad.preview([Note(id: 1, body: "Courses chantier\n- 4 sacs de ciment\n- 2 rouleaux de câble 2,5 mm²\n- boîtes d'encastrement", pinned: true),
                                 Note(id: 2, body: "Mail à Marc pour jeudi"), Note(id: 3)], selected: 1)
                    pad.targetApp = NSRunningApplication.current
                    await Snapshot.render(ScratchpadView(model: pad, settings: AppSettings.shared, rewrite: { _, _ in nil }, send: { _ in }),
                                          size: NSSize(width: 720, height: 460), dark: dark, to: dir.appendingPathComponent("scratchpad-\(suffix).png"))
                    for st in 0 ..< 4 {
                        await Snapshot.render(OnboardingView(state: state, levels: controller.panel.model, store: store, initialStep: st) {},
                                              size: NSSize(width: 760, height: 540), dark: dark, to: dir.appendingPathComponent("onboarding-\(st + 1)-\(suffix).png"))
                    }
                }
                controller.llmServer.stop()
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--diarize-test"), i + 1 < args.count {
            Task {
                do {
                    let audio = try Transcriber.loadAudio(path: args[i + 1])
                    var config = OfflineDiarizerConfig()
                    let env = ProcessInfo.processInfo.environment
                    if let t = env["WL_DIAR_T"].flatMap(Double.init) { config.clustering.threshold = t }
                    if let n = env["WL_DIAR_N"].flatMap(Int.init) { config.clustering.numSpeakers = n }
                    let d = OfflineDiarizerManager(config: config)
                    try await d.prepareModels()
                    let t0 = Date()
                    let r = try await d.process(audio: audio)
                    for seg in r.segments { print(String(format: "%@  %6.1f → %6.1f s", seg.speakerId, Double(seg.startTimeSeconds), Double(seg.endTimeSeconds))) }
                    print("\(Set(r.segments.map(\.speakerId)).count) interlocuteurs, \(Int(Date().timeIntervalSince(t0) * 1000)) ms pour \(audio.count / 16_000) s")
                    exit(0)
                } catch { print("ÉCHEC : \(error)"); exit(1) }
            }
            return
        }
        if args.contains("--bar-demo") {
            // Fait défiler les états de la barre (repos, survol, dictée, traitement, message) pour vérifier les transitions.
            let panel = controller.panel
            Task { @MainActor in
                let steps: [(StatusModel.Phase, Bool)] = [(.hidden, true), (.recording(handsFree: true), false), (.processing, false),
                                                          (.message("Ajouté au dictionnaire : Claude", isError: false), false), (.hidden, false)]
                for _ in 0 ..< 2 {
                    for (phase, hover) in steps {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        panel.show(phase)
                        panel.model.hovering = hover
                    }
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--meeting-test"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            // Réunion manuelle de `secs` secondes (tap système global + micro), puis compte rendu ; résultat sur stdout.
            Task {
                try? await controller.transcriber.load(model: AppSettings.shared.whisperModel)
                await controller.vad.load()
                await controller.refreshLLM()
                meetings.start(candidate: nil)
                print("ENREGISTREMENT \(Int(secs)) s…"); fflush(stdout)
                try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
                let id = meetings.current?.id ?? 0
                meetings.stop(reason: "user")
                for _ in 0 ..< 240 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let m = try? store.meeting(id: id), m.status != "processing" { break }
                }
                if let m = try? store.meeting(id: id) {
                    print("STATUT : \(m.status) · \(m.title)")
                    print("TRANSCRIPT :\n" + MeetingTranscript.render((try? store.segments(meetingID: id)) ?? []))
                    print("COMPTE RENDU :\n\(m.summary)")
                    print("TODOS : " + ((try? store.todos(meetingID: id)) ?? []).map(\.text).joined(separator: " | "))
                    print("EMAIL :\n\(m.followUpEmail)")
                }
                controller.llmServer.stop()
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--instruct"), i + 1 < args.count {
            let sel = i + 2 < args.count ? args[i + 2] : nil
            Task {
                let code = await controller.instructTest(request: args[i + 1], selection: sel)
                controller.llmServer.stop()
                exit(code)
            }
            return
        }
        if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
            Task {
                let code = await controller.bench(paths: Array(args[(i + 1)...]))
                controller.llmServer.stop()
                exit(code)
            }
            return
        }
        if let i = args.firstIndex(of: "--download-test"), i + 2 < args.count {
            // Vérifie le téléchargeur (progression, reprise) : --download-test <url> <fichier>
            let d = FileDownloader(url: URL(string: args[i + 1])!, to: URL(fileURLWithPath: args[i + 2])) { p in
                print("progress \(p.received) / \(p.total ?? -1)")
            }
            Task {
                do { try await d.run(); print("OK"); exit(0) } catch { print("ERREUR \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let before = i + 2 < args.count ? args[i + 2] : nil
            Task {
                let code = await controller.selfTest(path: args[i + 1], before: before)
                controller.llmServer.stop()
                exit(code)
            }
            return
        }
        controller.onRecordingChanged = { [weak self] recording in
            self?.state.recording = recording
            self?.updateIcon(recording: recording)
        }
        onboarding = OnboardingController(state: state, levels: controller.panel.model, store: store)
        meetings.onRecordingChanged = { [weak self] rec in
            self?.meetingItem?.title = rec ? String(localized: "Arrêter la réunion") : String(localized: "Démarrer une réunion")
            self?.updateIcon(recording: rec)
        }
        setupStatusItem()
        setupMainMenu()
        controller.applyRetention()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.applyRetention() }
        }

        controller.panel.onPasteLast = { [weak self] in self?.controller.pasteLast() }
        controller.panel.onOpenHub = { [weak self] in self?.showHub() }
        controller.panel.onTransform = { [weak self] n in self?.controller.applyTransform(index: n) }
        let ctl = controller!
        scratchpad = ScratchpadController(store: store,
                                          rewrite: { t, text in await ctl.rewrite(t, text) },
                                          paste: { @MainActor text in
                                              if await ctl.paster.paste(text) == .leftInClipboard {
                                                  ctl.panel.show(.message(String(localized: "Note copiée dans le presse-papier (⌘V pour coller)"), isError: false), autoHideAfter: 3)
                                              }
                                          })
        controller.onScratchpad = { [weak self] in self?.scratchpad.toggle() }
        controller.panel.onScratchpad = { [weak self] in self?.scratchpad.show() }
        controller.startEngines()
        meetings.startDetection()
        // L'invite micro n'apparaît qu'une fois le guide terminé : au 1er lancement, c'est l'étape Autorisations qui la déclenche.
        if OnboardingController.isDone {
            Task { state.microphoneGranted = await AudioRecorder.requestPermission() }
        } else {
            state.microphoneGranted = AudioRecorder.hasPermission
        }
        // L'autorisation micro peut changer dans Réglages Système pendant que Plume tourne.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state.microphoneGranted = AudioRecorder.hasPermission }
        }
        if OnboardingController.isDone {
            checkAccessibility(prompt: true)
            if !hotkeysInstalled { showHub() }
        } else {
            // 1er lancement : le guide explique les autorisations avant que macOS ne les demande.
            checkAccessibility(prompt: false)
            onboarding.show()
        }
    }

    /// Quitter proprement : réunion arrêtée et finalisée, son rétabli, dictée coupée, bloc-notes enregistré.
    /// Réponse différée, avec un filet de 3 s pour ne jamais bloquer la fermeture.
    private var terminating = false
    private var terminateReplied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let meetings, let controller else { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true
        scratchpad?.model.flush()
        _ = controller.recorder.stop()
        OutputMute.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.replyTerminate() }
        }
        Task { @MainActor [weak self] in
            await meetings.shutdown()
            self?.replyTerminate()
        }
        return .terminateLater
    }

    private func replyTerminate() {
        guard !terminateReplied else { return }
        terminateReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Filets de sécurité si la fermeture n'est pas passée par applicationShouldTerminate.
        scratchpad?.model.flush()
        OutputMute.release()
        controller?.llmServer.stop()
    }

    // MARK: Permissions

    private func checkAccessibility(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        state.accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
        if state.accessibilityGranted, !hotkeysInstalled { hotkeysInstalled = controller.installHotkeys() }
        if state.accessibilityGranted, hotkeysInstalled {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            // L'autorisation peut être accordée pendant que l'app tourne : on re-vérifie toutes les 2 s.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkAccessibility(prompt: false) }
            }
        }
        state.microphoneGranted = AudioRecorder.hasPermission
    }

    // MARK: Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(recording: false)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: String(localized: "Ouvrir Plume…"), action: #selector(openHub), keyEquivalent: ","))
        let pasteLast = NSMenuItem(title: String(localized: "Coller la dernière dictée"), action: #selector(pasteLastAction), keyEquivalent: "v")
        pasteLast.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(pasteLast)
        let notes = NSMenuItem(title: String(localized: "Bloc-notes"), action: #selector(openScratchpad), keyEquivalent: "n")
        notes.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(notes)
        let mi = NSMenuItem(title: String(localized: "Démarrer une réunion"), action: #selector(toggleMeeting), keyEquivalent: "")
        meetingItem = mi
        menu.addItem(mi)
        menu.addItem(NSMenuItem(title: String(localized: "Relancer le serveur LLM"), action: #selector(restartLLM), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Guide de bienvenue…"), action: #selector(openOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Afficher la barre Plume"), action: #selector(toggleFlowBar), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quitter Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    /// Menu principal minimal : sans menu Édition, ⌘V/⌘C/⌘A ne marchent pas dans les champs de Plume
    /// (app de barre des menus), y compris pour le collage de Plume dans son propre guide.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: String(localized: "Quitter Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Édition"))
        edit.addItem(NSMenuItem(title: String(localized: "Annuler"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "Rétablir"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: String(localized: "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: String(localized: "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: String(localized: "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: String(localized: "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func updateIcon(recording: Bool) {
        let name = (recording || (meetings?.isRecording ?? false)) ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Plume")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func openHub() { showHub() }
    @objc private func openOnboarding() { onboarding.show() }
    @objc private func openScratchpad() { scratchpad.show() }
    @objc private func toggleFlowBar() { AppSettings.shared.showFlowBar.toggle() }
    @objc private func toggleMeeting() {
        if meetings.isRecording { meetings.stop(reason: "user") } else { meetings.start(candidate: nil) }
    }
    @objc private func pasteLastAction() { controller.pasteLast() }
    @objc private func restartLLM() {
        controller.llmServer.stop()
        Task { await controller.refreshLLM() }
    }

    private func showHub() {
        if hubWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Plume"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HubView(state: state, settings: AppSettings.shared, store: store,
                                                            meetingActions: MeetingActions(
                                                                summarize: { [weak self] id in Task { await self?.meetings.summarize(meetingID: id) } },
                                                                setDetection: { [weak self] on in self?.meetings.setDetection(on) },
                                                                openOnboarding: { [weak self] in self?.onboarding.show() })))
            w.center()
            w.setFrameAutosaveName("hub")
            hubWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum Snapshot {
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000) // laisse passer les animations d'entrée
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFlowBar) { menuItem.state = AppSettings.shared.showFlowBar ? .on : .off }
        return true
    }
}
