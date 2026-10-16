import AppKit
import SwiftUI
import PlumeCore

/// État du bloc-notes : liste des notes, note ouverte, brouillon en cours d'édition.
@MainActor
final class ScratchpadModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var selectedID: Int64?
    @Published var draft = "" { didSet { if draft != savedBody { scheduleSave() } } }
    @Published var versions: [NoteVersion] = []
    @Published var busy: String?
    /// App au premier plan avant l'ouverture : cible de « Envoyer dans… ».
    @Published var targetApp: NSRunningApplication?
    /// Message ponctuel affiché dans la barre d'outils (échec d'envoi, réécriture rangée dans une autre note…).
    @Published var notice: String?

    let store: Store
    private var savedBody = ""
    private var saveWork: DispatchWorkItem?

    init(store: Store) { self.store = store }

    /// Aperçu (captures) : affiche des notes sans rien enregistrer.
    func preview(_ list: [Note], selected: Int64) {
        notes = list
        selectedID = selected
        savedBody = list.first { $0.id == selected }?.body ?? ""
        draft = savedBody
    }

    func reload(select id: Int64? = nil) {
        notes = (try? store.notes()) ?? []
        if let id { open(id) } else if selectedID == nil || !notes.contains(where: { $0.id == selectedID }) {
            if let first = notes.first { open(first.id) } else { newNote() }
        }
    }

    func open(_ id: Int64) {
        flush()
        selectedID = id
        savedBody = notes.first { $0.id == id }?.body ?? ""
        draft = savedBody
        versions = (try? store.noteVersions(noteID: id)) ?? []
    }

    func newNote() {
        flush()
        guard let id = try? store.insert(Note()) else { return }
        notes = (try? store.notes()) ?? []
        open(id)
    }

    func delete(_ id: Int64) {
        try? store.deleteNote(id: id)
        if selectedID == id { selectedID = nil }
        reload()
    }

    func togglePin(_ note: Note) {
        try? store.setPinned(noteID: note.id, !note.pinned)
        notes = (try? store.notes()) ?? []
    }

    /// Remplace le texte (réécriture, restauration) en gardant une version.
    func replace(with body: String, source: String) {
        guard let id = selectedID else { return }
        saveWork?.cancel()
        savedBody = body
        draft = body
        try? store.saveNote(id: id, body: body, source: source)
        refreshAfterSave(id)
    }

    /// Résultat d'une réécriture lancée sur `noteID` à partir de `source`. Appliqué dans l'éditeur seulement si
    /// cette note est toujours ouverte et que le texte n'a pas bougé ; sinon il est rangé comme version de la note
    /// d'origine (onglet Versions), sans toucher au brouillon en cours.
    func applyRewrite(_ body: String, noteID: Int64, source: String, transform: String) {
        let tag = "transform:\(transform)"
        if selectedID == noteID, draft == source {
            replace(with: body, source: tag)
            return
        }
        // Le texte courant de la note d'origine (brouillon non enregistré compris) est conservé : la réécriture
        // est ajoutée comme version, restaurable depuis Versions.
        guard notes.contains(where: { $0.id == noteID }) else { return }  // note supprimée entre-temps
        if selectedID == noteID { flush() }
        try? store.addNoteVersion(noteID: noteID, body: body, source: tag)
        if let id = selectedID { versions = (try? store.noteVersions(noteID: id)) ?? [] }
        notice = String(localized: "Réécriture enregistrée dans les versions de la note")
    }

    /// Enregistrement 0,8 s après la dernière frappe ; les versions tapées fusionnent par minute.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        guard let id = selectedID, draft != savedBody else { return }
        savedBody = draft
        try? store.saveNote(id: id, body: draft, source: "typed")
        refreshAfterSave(id)
    }

    private func refreshAfterSave(_ id: Int64) {
        notes = (try? store.notes()) ?? []
        versions = (try? store.noteVersions(noteID: id)) ?? []
    }
}

struct ScratchpadView: View {
    @ObservedObject var model: ScratchpadModel
    @ObservedObject var settings: AppSettings
    var rewrite: (RewriteTransform, String) async -> String?
    var send: (String) -> Void
    @StateObject private var showVersions = ViewState(false)

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 210)
                .background(Theme.ground)
            Divider()
            editor
        }
        .frame(minWidth: 640, minHeight: 380)
        .background(Theme.card)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { model.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help(Text("Nouvelle note (⌘N)"))
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel(Text("Nouvelle note"))
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.notes) { n in
                        Button { model.open(n.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if n.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                                    Text(n.title.isEmpty ? String(localized: "Note vide") : n.title)
                                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        .foregroundStyle(n.title.isEmpty ? Theme.textSecondary : Theme.text)
                                }
                                Text(n.updatedAt, format: .dateTime.day().month().hour().minute())
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(model.selectedID == n.id ? Theme.chip : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(n.pinned ? "Désépingler" : "Épingler") { model.togglePin(n) }
                            Button("Supprimer", role: .destructive) { model.delete(n.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(settings.transforms) { t in
                        Button(t.name) { apply(t) }
                    }
                } label: { Label("Réécrire", systemImage: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy != nil)

                Button { showVersions.value.toggle() } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showVersions.value, arrowEdge: .bottom) { versions }
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if let notice = model.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.draft, forType: .string)
                } label: { Label("Copier", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(model.draft.isEmpty)
                Button {
                    model.flush()
                    send(model.draft)
                } label: {
                    Text(model.targetApp?.localizedName.map { String(localized: "Envoyer dans \($0)") } ?? String(localized: "Envoyer"))
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.draft.isEmpty || model.targetApp == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            TextEditor(text: $model.draft)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(12)
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("Tapez ou maintenez fn pour dicter…")
                            .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 17).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var versions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.versions.isEmpty {
                    Text("Aucune version").foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.versions) { v in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(v.createdAt, format: .dateTime.hour().minute().second()).font(.system(size: 11, weight: .medium))
                            Text(label(v.source)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("Restaurer") { model.replace(with: v.body, source: "restore"); showVersions.value = false }
                                .controlSize(.small)
                        }
                        Text(v.body).font(.system(size: 12)).lineLimit(3).foregroundStyle(Theme.textSecondary)
                    }
                    Divider()
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: 320)
    }

    private func label(_ source: String) -> String {
        if source.hasPrefix("transform:") { return String(localized: "Réécriture · \(source.dropFirst(10))") }
        return source == "restore" ? String(localized: "Restauration") : String(localized: "Saisie")
    }

    private func apply(_ t: RewriteTransform) {
        guard let noteID = model.selectedID else { return }
        let text = model.draft
        model.busy = String(localized: "\(t.name)…")
        model.notice = nil
        Task {
            let out = await rewrite(t, text)
            model.busy = nil
            if let out, !out.isEmpty { model.applyRewrite(out, noteID: noteID, source: text, transform: t.name) }
        }
    }
}

/// Fenêtre du bloc-notes : flottante, ouverte par ⌃⌥N, le menu de la barre ou le menu Plume.
@MainActor
final class ScratchpadController {
    let model: ScratchpadModel
    private var window: NSPanel?
    private let rewrite: (RewriteTransform, String) async -> String?
    private let paste: (String) async -> Void

    init(store: Store, rewrite: @escaping (RewriteTransform, String) async -> String?, paste: @escaping (String) async -> Void) {
        model = ScratchpadModel(store: store)
        self.rewrite = rewrite
        self.paste = paste
        // Cible de « Envoyer dans… » oubliée dès que l'app quitte.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, self.model.targetApp?.processIdentifier == pid else { return }
                self.model.targetApp = nil
            }
        }
    }

    var isVisible: Bool { window?.isVisible == true && NSApp.isActive }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { model.targetApp = front }
        if model.targetApp?.isTerminated == true { model.targetApp = nil }
        model.notice = nil
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            w.title = String(localized: "Bloc-notes")
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.level = .floating
            w.isFloatingPanel = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: ScratchpadView(
                model: model, settings: AppSettings.shared, rewrite: rewrite,
                send: { [weak self] text in self?.send(text) }))
            w.center()
            w.setFrameAutosaveName("scratchpad")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.flush() }
            }
            window = w
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        model.flush()
        window?.orderOut(nil)
        model.targetApp?.activate()
    }

    /// « Envoyer dans <app> » : rend la main à l'app d'origine et y colle la note.
    private func send(_ text: String) {
        guard let app = model.targetApp, !app.isTerminated else { return sendFailed() }
        window?.orderOut(nil)
        guard app.activate() else { return sendFailed() }
        Task {
            // Jusqu'à ~1 s pour que l'app cible passe réellement au premier plan ; sinon ⌘V tomberait dans Plume.
            for _ in 0 ..< 10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            }
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return sendFailed()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await paste(text)
        }
    }

    private func sendFailed() {
        model.targetApp = nil
        model.notice = String(localized: "App cible introuvable : rien n'a été collé")
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
