import AppKit
import SwiftUI
import PlumeCore

/// État local d'une vue. Remplace `@State`, qui est une macro SwiftUI dont le plugin n'est pas livré
/// avec les Command Line Tools (pas de Xcode sur la machine de build).
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Actions du contrôleur de réunions accessibles depuis la fenêtre.
struct MeetingActions {
    var summarize: (Int64) -> Void
    var setDetection: (Bool) -> Void
    var openOnboarding: () -> Void = {}
}

/// État partagé entre le contrôleur et la fenêtre principale.
final class AppState: ObservableObject {
    @Published var asrStatus = "Chargement…"
    @Published var llmStatus = "Vérification…"
    @Published var asrReady = false
    @Published var llmReady = false
    @Published var vadReady = false
    /// Progression du téléchargement au premier lancement (nil = rien en cours).
    @Published var asrProgress: Double?
    @Published var llmProgress: Double?
    @Published var accessibilityGranted = false
    @Published var microphoneGranted = false
    @Published var secureInputActive = false
    /// Une dictée est en cours (pour l'essai du guide de bienvenue).
    @Published var recording = false
    @Published var historyVersion = 0
    @Published var lexiconVersion = 0
    @Published var instructVersion = 0
    @Published var meetingsVersion = 0
}

struct HubView: View {
    enum Page: String, CaseIterable, Identifiable {
        case home, history, meetings, tasks, voice, instruct, dictionary, snippets, settings
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .home: "Accueil"
            case .history: "Historique"
            case .meetings: "Réunions"
            case .tasks: "Tâches"
            case .voice: "Ma voix"
            case .instruct: "Instruct"
            case .dictionary: "Dictionnaire"
            case .snippets: "Snippets"
            case .settings: "Réglages"
            }
        }
        var icon: String {
            switch self {
            case .home: "house"
            case .history: "clock.arrow.circlepath"
            case .voice: "waveform"
            case .meetings: "person.2"
            case .tasks: "checklist"
            case .instruct: "sparkles"
            case .dictionary: "character.book.closed"
            case .snippets: "text.badge.plus"
            case .settings: "gearshape"
            }
        }
    }

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let store: Store
    var meetingActions: MeetingActions
    @StateObject private var page: ViewState<Page>

    init(state: AppState, settings: AppSettings, store: Store, meetingActions: MeetingActions, initialPage: Page = .home) {
        self.state = state
        self.settings = settings
        self.store = store
        self.meetingActions = meetingActions
        _page = StateObject(wrappedValue: ViewState(initialPage))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page.value) {
                Section {
                    ForEach([Page.home, .history, .meetings, .tasks]) { row($0) }
                }
                Section("Configurer") {
                    ForEach([Page.voice, .instruct, .dictionary, .snippets, .settings]) { row($0) }
                }
            }
            .tint(Theme.accent)
            .navigationSplitViewColumnWidth(min: 180, ideal: 196)
            .safeAreaInset(edge: .bottom) { LocalBadge(state: state).padding(12) }
        } detail: {
            Group {
                switch page.value {
                case .home: HomePage(state: state, settings: settings, store: store, actions: meetingActions)
                case .history: HistoryPage(state: state, store: store)
                case .voice: VoicePage(settings: settings, state: state, store: store)
                case .meetings: MeetingsPage(state: state, store: store, actions: meetingActions)
                case .tasks: TasksPage(state: state, store: store)
                case .instruct: InstructPage(state: state, store: store)
                case .dictionary: LexiconPage(state: state, store: store, kinds: [.word, .replacement])
                case .snippets: LexiconPage(state: state, store: store, kinds: [.snippet])
                case .settings: SettingsPage(settings: settings, state: state, meetingActions: meetingActions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
            .id(page.value)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.18), value: page.value)
        .frame(minWidth: 900, minHeight: 600)
        .tint(Theme.accent)
    }

    private func row(_ p: Page) -> some View {
        Label(p.title, systemImage: p.icon).tag(p)
    }
}

/// Pied de la barre latérale : tout tourne en local, et si quelque chose bloque, on le dit.
private struct LocalBadge: View {
    @ObservedObject var state: AppState
    var body: some View {
        let ready = state.asrReady && state.accessibilityGranted && state.microphoneGranted
        HStack(spacing: 8) {
            StatusDot(ok: ready)
            Text(ready ? LocalizedStringKey("100 % local · prêt") : (state.asrReady ? "Autorisations à accorder" : "Chargement des modèles…"))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// Gabarit de page : titre, sous-titre, contenu défilant sur le fond sauge.
private struct PageScaffold<Content: View, Trailing: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    trailing
                }
                .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.trailing = EmptyView(); self.content = content()
    }
}

// MARK: - Statistiques réelles

struct DictationStats {
    var wordsToday = 0
    var dictationsToday = 0
    var wpm = 0
    var count = 0
    /// Médianes en ms (sur les 100 dernières dictées collées).
    var asr = 0, llm = 0, total = 0
    /// Médiane, dictée par dictée, de ce qui n'est ni Whisper ni le LLM (queue d'enregistrement, VAD, collage).
    var other = 0

    init() {}

    init(store: Store) {
        let all = ((try? store.transcripts(limit: 500)) ?? []).filter { $0.mode == "dictation" && ["pasted", "bubble", "clipboard"].contains($0.status) }
        let cal = Calendar.current
        let today = all.filter { cal.isDateInToday($0.createdAt) }
        wordsToday = today.reduce(0) { $0 + $1.finalText.split(separator: " ").count }
        dictationsToday = today.count
        let recent = Array(all.prefix(100))
        count = recent.count
        let words = recent.reduce(0) { $0 + $1.finalText.split(separator: " ").count }
        let secs = recent.reduce(0.0) { $0 + $1.audioSeconds }
        wpm = secs > 1 ? Int(Double(words) / (secs / 60)) : 0
        // Détail d'une vraie dictée, celle dont la durée totale est la médiane : les trois étapes
        // sont des mesures réelles et leur somme est exactement le total affiché.
        let sorted = recent.sorted { $0.totalMs < $1.totalMs }
        if !sorted.isEmpty {
            let m = sorted[sorted.count / 2]
            asr = m.asrMs
            llm = m.llmMs
            total = m.totalMs
            other = max(m.totalMs - m.asrMs - m.llmMs, 0)
        }
    }
}

// MARK: - Accueil

private struct HomePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    let store: Store
    let actions: MeetingActions
    @StateObject private var stats = ViewState(DictationStats())
    @StateObject private var prefs = ViewState<[VoicePreference]>([])
    @StateObject private var learned = ViewState<[LexiconEntry]>([])

    var body: some View {
        PageScaffold(title: "Accueil") {
            if !state.accessibilityGranted || !state.microphoneGranted || state.secureInputActive { attention }
            HeroBand(stats: stats.value)
            HStack(alignment: .top, spacing: 16) {
                enginesCard
                statsCard
                behaviourCard
            }
            .fixedSize(horizontal: false, vertical: true)
            SectionTitle(text: "Ma voix, application par application").padding(.top, 6)
            VoiceSentences(settings: settings)
            rememberedCard
        }
        .onAppear(perform: load)
        .onChange(of: state.historyVersion) { _ in load() }
        .onChange(of: state.lexiconVersion) { _ in load() }
    }

    private var attention: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if state.secureInputActive {
                    Label("La saisie sécurisée est active (Terminal, gestionnaire de mots de passe) : fn ne peut pas être capté.",
                          systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(Theme.warn)
                }
                if !state.accessibilityGranted {
                    PermissionLine(title: "Accessibilité", detail: "pour la touche fn, le collage et le contexte",
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
                if !state.microphoneGranted {
                    PermissionLine(title: "Micro", detail: "pour vous entendre",
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
            }
        }
    }

    private var enginesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(text: "Moteurs locaux")
                EngineRow(name: "Whisper large-v3 turbo", detail: stats.value.asr > 0 ? "\(stats.value.asr) ms" : nil, ok: state.asrReady,
                          status: state.asrReady ? nil : state.asrStatus)
                EngineRow(name: "LLM · \(URL(fileURLWithPath: settings.llmModelPath).deletingPathExtension().lastPathComponent)",
                          detail: stats.value.llm > 0 ? "\(stats.value.llm) ms" : nil, ok: state.llmReady, status: state.llmReady ? nil : state.llmStatus)
                EngineRow(name: "Silero VAD", detail: nil, ok: state.vadReady, status: state.vadReady ? nil : "chargement")
            }
        }
    }

    private var statsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Aujourd'hui")
                if stats.value.dictationsToday == 0 {
                    Text("Pas encore de dictée aujourd'hui.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                } else {
                    BigNumber(value: "\(stats.value.wordsToday)", label: "mots dictés")
                    BigNumber(value: "\(stats.value.dictationsToday)", label: "dictées")
                }
                if stats.value.wpm > 0 { BigNumber(value: "\(stats.value.wpm)", label: "mots par minute (100 dernières)") }
            }
        }
    }

    private var behaviourCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(text: "Comportement")
                SettingToggle(label: "Lire le texte autour du curseur", isOn: $settings.useContext)
                SettingToggle(label: "Apprendre de mes corrections", isOn: $settings.learnFromEdits)
                SettingToggle(label: "Détecter les réunions", isOn: $settings.autoDetectMeetings)
                    .onChange(of: settings.autoDetectMeetings) { on in actions.setDetection(on) }
                LanguagesPicker(settings: settings)
            }
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
        }
    }

    private var rememberedCard: some View {
        Card(padding: 16) {
            HStack(alignment: .center, spacing: 10) {
                SectionTitle(text: "Ce que Plume a retenu")
                if prefs.value.isEmpty && learned.value.isEmpty {
                    Text("Rien encore. Corrigez un mot après une dictée, ou dites « à partir de maintenant… » en mode Instruct.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(prefs.value.prefix(4)) { p in Chip(text: p.preference, detail: p.filter.map(PreferenceLabel.describe)) }
                            ForEach(learned.value.prefix(6)) { e in Chip(text: e.phrase, detail: "dictionnaire") }
                        }
                    }
                }
            }
        }
    }

    private func load() {
        stats.value = DictationStats(store: store)
        prefs.value = ((try? store.preferences()) ?? []).filter(\.enabled)
        learned.value = ((try? store.lexicon()) ?? []).filter { $0.kind == .word }
    }
}

/// Bandeau d'encre : le geste, puis le parcours de la voix en millisecondes réelles.
private struct HeroBand: View {
    var stats: DictationStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Maintenez").font(.system(size: 28, weight: .semibold))
                Keycap(label: "fn", onInk: true).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                Text("et parlez.").font(.system(size: 28, weight: .semibold))
            }
            .foregroundStyle(Theme.onInk)
            HStack(spacing: 18) {
                Gesture(keys: ["fn", "fn"], label: "mains libres")
                Gesture(keys: ["⌃", "fn"], label: "Instruct")
                Gesture(keys: ["⌃", "⌘", "V"], label: "recoller")
                Gesture(keys: ["esc"], label: "annuler")
            }
            VoicePipeline(stats: stats)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }

    private struct Gesture: View {
        var keys: [String]
        var label: LocalizedStringKey
        var body: some View {
            HStack(spacing: 5) {
                ForEach(keys.indices, id: \.self) { Keycap(label: keys[$0], onInk: true) }
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.onInkSecondary).padding(.leading, 2)
            }
        }
    }
}

/// Mouvement signature : le parcours de la voix se dessine de gauche à droite à l'ouverture.
private struct VoicePipeline: View {
    var stats: DictationStats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var drawn = ViewState(false)

    var body: some View {
        let other = stats.other
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parcours de la voix").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onInk)
                Spacer()
                if stats.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.2f", Double(stats.total) / 1000)).font(.system(size: 22, weight: .semibold, design: .monospaced))
                        Text("s").font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Theme.onInk)
                    Text("dictée médiane, fin de parole → texte collé").font(.system(size: 12)).foregroundStyle(Theme.onInkSecondary)
                }
            }
            if stats.total == 0 {
                Text("Faites une première dictée : le temps passé dans chaque moteur s'affichera ici.")
                    .font(.system(size: 13)).foregroundStyle(Theme.onInkSecondary)
            } else {
                GeometryReader { g in
                    HStack(spacing: 3) {
                        segment(stats.asr, color: Theme.segASR, width: g.size.width)
                        segment(stats.llm, color: Theme.segLLM, width: g.size.width)
                        segment(other, color: Theme.segPaste, width: g.size.width)
                    }
                    .frame(width: drawn.value ? g.size.width : 0, alignment: .leading)
                    .clipped()
                }
                .frame(height: 12)
                HStack(spacing: 16) {
                    legend("Whisper", stats.asr, Theme.segASR)
                    legend("LLM", stats.llm, Theme.segLLM)
                    legend("Autres étapes (VAD, collage)", other, Theme.segPaste)
                    Spacer()
                    Text("\(stats.count) dictées").font(.system(size: 11)).foregroundStyle(Theme.onInkSecondary)
                }
            }
        }
        .padding(14)
        .background(Theme.inkRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if reduceMotion { drawn.value = true } else { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7).delay(0.1)) { drawn.value = true } }
        }
        .accessibilityElement(children: .combine)
    }

    private func segment(_ ms: Int, color: Color, width: CGFloat) -> some View {
        let total = max(stats.total, 1)
        return RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: max(4, (width - 6) * CGFloat(ms) / CGFloat(total)))
    }

    private func legend(_ name: LocalizedStringKey, _ ms: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(name).foregroundStyle(Theme.onInkSecondary)
            Text("\(ms) ms").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.onInk)
        }
        .font(.system(size: 12))
    }
}

private struct EngineRow: View {
    var name: String
    var detail: String?
    var ok: Bool
    var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StatusDot(ok: ok)
                Text(name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
            }
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2).padding(.leading, 16) }
        }
    }
}

private struct BigNumber: View {
    var value: String
    var label: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct PermissionLine: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var url: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn)
            Text(title).fontWeight(.semibold)
            Text(detail).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Ouvrir les réglages") { NSWorkspace.shared.open(URL(string: url)!) }
        }
        .font(.system(size: 13))
    }
}

private struct Chip: View {
    var text: String
    var detail: String?
    var body: some View {
        HStack(spacing: 5) {
            Text(text).foregroundStyle(Theme.text)
            if let detail { Text("· \(detail)").foregroundStyle(Theme.textSecondary) }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Theme.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
    }
}

/// Filtre technique « app:slack-mode:generation » → « Slack · génération ».
enum PreferenceLabel {
    static func describe(_ filter: String) -> String {
        filter.split(separator: "-").compactMap { part -> String? in
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            switch kv[0].lowercased() {
            case "app": return kv[1].capitalized
            case "appcategory": return ["email": "emails", "messaging": "messageries", "code": "éditeurs de code", "terminal": "terminaux"][kv[1]] ?? kv[1]
            case "language": return kv[1].uppercased()
            case "mode": return kv[1] == "generation" ? "Instruct" : "dictée"
            default: return nil
            }
        }.joined(separator: " · ")
    }
}

// MARK: - Ma voix en phrases (mouvement signature)

private struct VoiceSentences: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
            ForEach($settings.voices) { $voice in VoiceSentence(voice: $voice) }
        }
    }
}

private struct VoiceSentence: View {
    @Binding var voice: UserVoice
    @StateObject private var editing = ViewState(false)

    static let styles: [(StylePreference, String)] = [(.formal, String(localized: "formelle")), (.casual, String(localized: "décontractée")),
                                                       (.veryCasual, String(localized: "très décontractée")), (.excited, String(localized: "enthousiaste"))]
    static let levels: [(CleanupLevel, String)] = [(.none, String(localized: "aucun")), (.light, String(localized: "léger")),
                                                   (.medium, String(localized: "moyen")), (.high, String(localized: "fort"))]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                FlowSentence(spacing: 5) {
                    Text(prefix).font(.system(size: 15)).foregroundStyle(Theme.text)
                    Button { editing.value.toggle() } label: {
                        Text(appsLabel).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).underline(true, color: Theme.cardStroke)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $editing.value) { appsEditor }
                    Text("j'écris de façon").font(.system(size: 15)).foregroundStyle(Theme.text)
                    InlineChoice(selection: $voice.style, options: Self.styles)
                    Text("avec un nettoyage").font(.system(size: 15)).foregroundStyle(Theme.text)
                    InlineChoice(selection: $voice.cleanupLevel, options: Self.levels)
                }
                Text(displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var prefix: LocalizedStringKey { voice.id == "other" ? "Partout" : "Dans" }
    /// Noms des voix intégrées traduits ; une voix créée par l'utilisateur garde son nom.
    private var displayName: String {
        guard voice.builtIn else { return voice.name }
        switch voice.id {
        case "work": return String(localized: "Messages pro")
        case "email": return String(localized: "Email")
        case "personal": return String(localized: "Messages perso")
        default: return String(localized: "Autres")
        }
    }
    private var appsLabel: String {
        if voice.id == "other" { return String(localized: "ailleurs,") }
        let apps = voice.appNames.prefix(2).joined(separator: ", ")
        return (voice.appNames.count > 2 ? apps + "…" : apps) + ","
    }

    private var appsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(voice.id == "other" ? "S'applique à toutes les applications non listées ailleurs." : "Applications ou sites, séparés par des virgules")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if voice.id != "other" {
                TextField("Slack, mail.google.com…", text: Binding(
                    get: { voice.appNames.joined(separator: ", ") },
                    set: { voice.appNames = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
        }
        .padding(14)
    }
}

/// Mise en page « phrase » : les mots et les menus passent à la ligne comme du texte.
private struct FlowSentence: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += line + 6; x = 0; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height); widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += line + 6; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }
}

// MARK: - Ma voix (page complète : phrases + préférences apprises)

private struct VoicePage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let store: Store
    @StateObject private var prefs = ViewState<[VoicePreference]>([])
    @StateObject private var newPref = ViewState("")
    @StateObject private var newFilter = ViewState("")

    var body: some View {
        PageScaffold(title: "Ma voix", subtitle: "Comment Plume écrit, selon l'application") {
            VoiceSentences(settings: settings)
            HStack {
                Spacer()
                Button("Rétablir les styles par défaut") { settings.voices = VoiceResolver.defaults }.controlSize(.small)
            }
            SectionTitle(text: "Préférences apprises").padding(.top, 8)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Dites-les en mode Instruct (« à partir de maintenant, jamais de point d'exclamation sur Slack ») ou ajoutez-les ici.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    HStack {
                        TextField("Préférence, ex. signer mes mails « Samy »", text: $newPref.value).textFieldStyle(.roundedBorder)
                        TextField("Portée (facultatif) : app:gmail", text: $newFilter.value).textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("Ajouter") {
                            let f = newFilter.value.trimmingCharacters(in: .whitespaces)
                            try? store.upsert(VoicePreference(filter: f.isEmpty ? nil : f, preference: newPref.value))
                            newPref.value = ""; newFilter.value = ""
                            state.lexiconVersion += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPref.value.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if prefs.value.isEmpty {
                        Text("Aucune préférence pour l'instant.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(prefs.value) { p in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { p.enabled }, set: { var q = p; q.enabled = $0; try? store.upsert(q); state.lexiconVersion += 1 }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Text(p.preference).font(.system(size: 13)).foregroundStyle(p.enabled ? Theme.text : Theme.textSecondary)
                            Spacer()
                            Text(p.filter.map(PreferenceLabel.describe) ?? "partout").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Button { try? store.deletePreference(id: p.id); state.lexiconVersion += 1 } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).accessibilityLabel("Supprimer")
                        }
                        .padding(.vertical, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(Theme.ease, value: prefs.value.map(\.id))
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.lexiconVersion) { _ in load() }
    }

    private func load() { prefs.value = (try? store.preferences()) ?? [] }
}

// MARK: - Historique

private struct HistoryPage: View {
    @ObservedObject var state: AppState
    let store: Store
    @StateObject private var search = ViewState("")
    @StateObject private var items = ViewState<[TranscriptRecord]>([])
    @StateObject private var expanded = ViewState<Int64?>(nil)

    var body: some View {
        PageScaffold(title: "Historique", subtitle: "Tout reste sur ce Mac") {
            TextField("Rechercher dans vos dictées", text: $search.value).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            if items.value.isEmpty {
                Card { EmptyLine(icon: "waveform", text: search.value.isEmpty ? "Vos dictées apparaîtront ici." : "Aucun résultat.") }
            }
            ForEach(items.value) { r in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(r.createdAt, format: .dateTime.day().month().hour().minute())
                            if let app = r.appName { Text("· \(app)") }
                            if r.mode == "instruct" { Text("· Instruct").foregroundStyle(Theme.accent) }
                            Spacer()
                            if r.status != "pasted" { Text(statusLabel(r.status)).padding(.horizontal, 7).padding(.vertical, 1).background(Theme.chip, in: Capsule()).foregroundStyle(Theme.chipText) }
                            Text(String(format: "%.2f s", Double(r.totalMs) / 1000)).font(.system(size: 11, design: .monospaced))
                        }
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        Text(r.finalText.isEmpty ? r.rawText : r.finalText).font(.system(size: 14)).foregroundStyle(Theme.text).textSelection(.enabled)
                        if expanded.value == r.id {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Transcription brute : \(r.rawText)").textSelection(.enabled)
                                if let e = r.editedText { Text("Après vos corrections : \(e)").textSelection(.enabled) }
                                Text("Whisper \(r.asrMs) ms · LLM \(r.llmMs) ms · audio \(String(format: "%.1f", r.audioSeconds)) s · \(r.language ?? "?")")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .transition(.opacity)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Theme.ease) { expanded.value = expanded.value == r.id ? nil : r.id } }
                .contextMenu {
                    Button("Copier") { copy(r.finalText) }
                    Button("Copier la transcription brute") { copy(r.rawText) }
                    if let p = r.audioPath { Button("Afficher l'audio") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
                    Divider()
                    Button("Supprimer", role: .destructive) {
                        try? store.deleteTranscript(id: r.id)
                        if let p = r.audioPath { try? FileManager.default.removeItem(atPath: p) }
                        load()
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: search.value) { _ in load() }
        .onChange(of: state.historyVersion) { _ in load() }
    }

    private func statusLabel(_ s: String) -> LocalizedStringKey {
        switch s {
        case "bubble", "clipboard": "non collé"
        case "dropped": "écarté"
        case "error": "erreur"
        case "instruct": "affiché"
        default: LocalizedStringKey(s)
        }
    }

    private func load() { items.value = (try? store.transcripts(search: search.value, limit: 300)) ?? [] }
}

private struct EmptyLine: View {
    var icon: String
    var text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(text).foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 13))
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Dictionnaire et snippets

private struct LexiconPage: View {
    @ObservedObject var state: AppState
    let store: Store
    let kinds: [LexiconEntry.Kind]
    @StateObject private var items = ViewState<[LexiconEntry]>([])
    @StateObject private var phrase = ViewState("")
    @StateObject private var replacement = ViewState("")
    @StateObject private var isReplacement = ViewState(false)

    private var isSnippets: Bool { kinds == [.snippet] }

    var body: some View {
        PageScaffold(title: isSnippets ? "Snippets" : "Dictionnaire",
                     subtitle: isSnippets ? "Dites le déclencheur, Plume insère le texte" : "Noms et termes que Whisper doit reconnaître") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField(isSnippets ? "Déclencheur, ex. « mon adresse »" : "Mot ou nom, ex. Proxmox", text: $phrase.value)
                            .textFieldStyle(.roundedBorder)
                        if isSnippets || isReplacement.value {
                            Image(systemName: "arrow.right").foregroundStyle(Theme.textSecondary)
                            TextField(isSnippets ? "Texte inséré" : "Forme correcte", text: $replacement.value).textFieldStyle(.roundedBorder)
                        }
                        Button("Ajouter", action: add).buttonStyle(.borderedProminent)
                            .disabled(phrase.value.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    if !isSnippets {
                        Toggle("Remplacer une forme mal reconnue (ex. « prox mox » → Proxmox)", isOn: $isReplacement.value)
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
            }
            if items.value.isEmpty {
                Card { EmptyLine(icon: isSnippets ? "text.badge.plus" : "character.book.closed",
                                 text: isSnippets ? "Aucun snippet. Exemple : « mon adresse » → votre adresse postale." : "Le dictionnaire est vide. Plume y ajoutera aussi les mots que vous corrigez.") }
            } else {
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(items.value) { e in
                            HStack(spacing: 10) {
                                Button { toggleStar(e) } label: { Image(systemName: e.starred ? "star.fill" : "star") }
                                    .buttonStyle(.borderless).foregroundStyle(e.starred ? Theme.segPaste : Theme.textSecondary)
                                    .accessibilityLabel(e.starred ? "Retirer des favoris" : "Mettre en favori")
                                Text(e.phrase).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                                if !e.replacement.isEmpty {
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                    Text(e.replacement).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
                                }
                                Spacer()
                                Button { try? store.deleteLexicon(id: e.id); changed() } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).accessibilityLabel("Supprimer")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            if e.id != items.value.last?.id { Divider().padding(.leading, 40) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.lexiconVersion) { _ in load() }
    }

    private func add() {
        let kind: LexiconEntry.Kind = isSnippets ? .snippet : (isReplacement.value ? .replacement : .word)
        try? store.upsert(LexiconEntry(kind: kind, phrase: phrase.value.trimmingCharacters(in: .whitespaces),
                                       replacement: kind == .word ? "" : replacement.value))
        phrase.value = ""; replacement.value = ""
        changed()
    }

    private func toggleStar(_ e: LexiconEntry) {
        var e = e; e.starred.toggle()
        try? store.upsert(e)
        changed()
    }

    private func changed() { withAnimation(Theme.ease) { state.lexiconVersion += 1 } }
    private func load() { items.value = ((try? store.lexicon()) ?? []).filter { kinds.contains($0.kind) } }
}

// MARK: - Réglages

private struct SettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    var meetingActions: MeetingActions

    var body: some View {
        PageScaffold(title: "Réglages") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    group("Dictée") {
                        LanguagesPicker(settings: settings)
                        HStack {
                            Text("Transcription").foregroundStyle(Theme.text)
                            Spacer(minLength: 12)
                            InlineChoice(selection: $settings.asrEngine, options: [
                                ("parakeet", String(localized: "Parakeet (rapide)")),
                                ("whisper", String(localized: "Whisper (suit le vocabulaire)")),
                            ])
                        }
                        SettingToggle(label: "Lire le texte autour du curseur", isOn: $settings.useContext)
                        SettingToggle(label: "Apprendre de mes corrections", isOn: $settings.learnFromEdits)
                        SettingToggle(label: "Couper le son de l'ordinateur pendant la dictée", isOn: $settings.muteWhileDictating)
                        SettingToggle(label: "Son au début de la dictée", isOn: $settings.playSounds)
                        SettingToggle(label: "Afficher la barre Plume en permanence", isOn: $settings.showFlowBar)
                        HStack {
                            Text("Bord de l'écran").foregroundStyle(Theme.text)
                            Spacer(minLength: 12)
                            InlineChoice(selection: $settings.flowBarEdge, options: [
                                ("bottom", String(localized: "En bas")), ("top", String(localized: "En haut")),
                                ("left", String(localized: "À gauche")), ("right", String(localized: "À droite")),
                            ])
                        }
                    }
                    group("Réunions") {
                        SettingToggle(label: "Détecter les appels (Zoom, Meet, Teams, FaceTime…)", isOn: $settings.autoDetectMeetings)
                            .onChange(of: settings.autoDetectMeetings) { on in meetingActions.setDetection(on) }
                        SettingToggle(label: "Démarrer l'enregistrement après 10 s sans réponse", isOn: $settings.autoStartMeetings)
                        SettingToggle(label: "Arrêter seul (micro libéré, silence, fin du créneau)", isOn: $settings.autoEndMeetings)
                        Stepper("Durée maximale : \(Int(settings.meetingMaxHours)) h", value: $settings.meetingMaxHours, in: 1 ... 6, step: 1)
                    }
                    group("Confidentialité") {
                        Picker("Historique", selection: $settings.retention) {
                            Text("Conserver").tag("forever"); Text("24 heures").tag("24h"); Text("Ne pas conserver").tag("never")
                        }
                        SettingToggle(label: "Conserver l'audio des dictées", isOn: $settings.keepAudio)
                        Button("Ouvrir le dossier de données") { NSWorkspace.shared.open(AppSettings.supportDirectory) }
                    }
                }
                VStack(spacing: 16) {
                    group("Modèles") {
                        LabeledField(label: "Modèle Whisper", text: $settings.whisperModel, note: "Pris en compte au prochain lancement.")
                        LabeledField(label: "Serveur LLM", text: $settings.llmEndpoint)
                        LabeledField(label: "Nom du modèle", text: $settings.llmModelName)
                        LabeledField(label: "Fichier GGUF", text: $settings.llmModelPath)
                        SettingToggle(label: "Lancer llama-server automatiquement", isOn: $settings.autoStartLLM)
                        LabeledField(label: "Serveur Instruct", text: $settings.instructEndpoint, note: "Vide : même serveur que la dictée.")
                    }
                    group("Aide") {
                        Button("Revoir le guide de bienvenue") { meetingActions.openOnboarding() }
                    }
                    group("À propos") {
                        Text("Plume \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · licence MIT")
                            .foregroundStyle(Theme.text)
                        Text("Transcription : Parakeet (NVIDIA, CC-BY-4.0, via Fluid Inference). Mise au propre : Qwen3.5 (Apache-2.0) avec llama.cpp. Réunions : pyannote et WeSpeaker (CC-BY-4.0).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Button("Licences des composants tiers") {
                            if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
    }

    private func group<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(text: title)
                content()
            }
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
        }
    }
}

private struct LabeledField: View {
    var label: LocalizedStringKey
    @Binding var text: String
    var note: LocalizedStringKey?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
        }
    }
}

// MARK: - Instruct

/// Réécritures rapides : une ligne par consigne, raccourci ⌃⌥N à gauche.
private struct TransformsCard: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(text: "Réécritures rapides")
                    Spacer()
                    if settings.transforms.count < 9 {
                        Button("Ajouter") {
                            settings.transforms.append(RewriteTransform(name: String(localized: "Nouvelle"), instruction: ""))
                        }
                        .controlSize(.small)
                    }
                }
                Text("Sélectionnez du texte n'importe où, puis appuyez sur le raccourci. Sans sélection, la dernière dictée est réécrite dans une bulle à copier. Aussi au clic droit sur la barre Plume.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                ForEach(Array(settings.transforms.enumerated()), id: \.element.id) { i, t in
                    HStack(alignment: .top, spacing: 10) {
                        HStack(spacing: 3) { Keycap(label: "⌃"); Keycap(label: "⌥"); Keycap(label: "\(i + 1)") }
                            .frame(width: 104, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Nom", text: binding(t.id, \.name)).textFieldStyle(.plain)
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                            TextField("Consigne", text: binding(t.id, \.instruction), axis: .vertical).textFieldStyle(.plain)
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1 ... 3)
                        }
                        Button {
                            settings.transforms.removeAll { $0.id == t.id }
                        } label: { Image(systemName: "trash").foregroundStyle(Theme.textSecondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Supprimer"))
                    }
                    if i < settings.transforms.count - 1 { Divider() }
                }
            }
        }
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<RewriteTransform, String>) -> Binding<String> {
        Binding(
            get: { settings.transforms.first { $0.id == id }?[keyPath: key] ?? "" },
            set: { v in if let i = settings.transforms.firstIndex(where: { $0.id == id }) { settings.transforms[i][keyPath: key] = v } })
    }
}

private struct InstructPage: View {
    @ObservedObject var state: AppState
    let store: Store
    @StateObject private var turns = ViewState<[InstructTurn]>([])

    var body: some View {
        PageScaffold(title: "Instruct", subtitle: "Donnez une consigne au lieu de dicter") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Maintenez").font(.system(size: 15))
                        Keycap(label: "⌃"); Text("puis").font(.system(size: 15)); Keycap(label: "fn")
                        Text(", parlez, relâchez.").font(.system(size: 15))
                    }
                    .foregroundStyle(Theme.text)
                    Text("« Réécris la sélection plus poliment » · « Traduis en anglais » · « Résume ma dernière réunion » · « À partir de maintenant, signe mes mails Samy »")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            TransformsCard(settings: AppSettings.shared)
            if turns.value.isEmpty { Card { EmptyLine(icon: "sparkles", text: "Vos consignes et leurs résultats apparaîtront ici.") } }
            ForEach(turns.value) { t in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(t.createdAt, format: .dateTime.day().month().hour().minute())
                            if let a = t.appName { Text("· \(a)") }
                        }
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        Text(t.request).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        if !t.response.isEmpty { Text(t.response).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).textSelection(.enabled) }
                    }
                }
                .contextMenu { Button("Copier la réponse") { copy(t.response) } }
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.instructVersion) { _ in load() }
    }

    private func load() { turns.value = (try? store.instructTurns()) ?? [] }
}

// MARK: - Réunions

private struct MeetingsPage: View {
    @ObservedObject var state: AppState
    let store: Store
    let actions: MeetingActions
    @StateObject private var items = ViewState<[Meeting]>([])
    @StateObject private var selected = ViewState<Int64?>(nil)
    @StateObject private var search = ViewState("")

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Réunions").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
                TextField("Rechercher", text: $search.value).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(items.value) { m in
                            Button { withAnimation(Theme.ease) { selected.value = m.id } } label: { MeetingRow(meeting: m, selected: selected.value == m.id) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
            .frame(width: 290)
            Divider()
            Group {
                if let id = selected.value, let m = items.value.first(where: { $0.id == id }) {
                    MeetingDetail(meeting: m, store: store, state: state, actions: actions).id(m.id).transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2").font(.system(size: 30)).foregroundStyle(Theme.accent)
                        if items.value.isEmpty {
                            Text("Aucune réunion pour l'instant").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Plume vous proposera de prendre des notes dès qu'un appel commence, ou via le menu de la barre des menus.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                        } else {
                            Text("Sélectionnez une réunion").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.meetingsVersion) { _ in load() }
        .onChange(of: search.value) { _ in load() }
    }

    private func load() {
        items.value = (try? store.meetings(search: search.value)) ?? []
        if selected.value == nil { selected.value = items.value.first?.id }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if meeting.status == "recording" { Circle().fill(.red).frame(width: 7, height: 7) }
                Text(meeting.title.isEmpty ? "Réunion" : meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Int(meeting.duration / 60)) min")
                .font(.system(size: 11.5)).foregroundStyle(selected ? Theme.chipText : Theme.textSecondary)
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? Theme.chip : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    let store: Store
    @ObservedObject var state: AppState
    let actions: MeetingActions
    @StateObject private var tab = ViewState(0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title.isEmpty ? "Réunion" : meeting.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text(meeting.startedAt.formatted(date: .complete, time: .shortened))
                        Text("· \(Int(meeting.duration / 60)) min")
                        if meeting.status != "complete" { Text("· \(statusLabel)").foregroundStyle(Theme.warn) }
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    if let a = meeting.attendees, !a.isEmpty { Text("Participants : \(a)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2) }
                }
                Spacer()
                Menu {
                    Button("Régénérer le compte rendu") { actions.summarize(meeting.id) }
                    Button("Copier le transcript") { copy(MeetingTranscript.render(segments)) }
                    Button("Copier le compte rendu") { copy(meeting.summary) }
                    if let dir = meeting.audioDir { Button("Afficher l'audio") { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) } }
                    Divider()
                    Button("Supprimer", role: .destructive) {
                        try? store.deleteMeeting(id: meeting.id)
                        if let dir = meeting.audioDir { try? FileManager.default.removeItem(atPath: dir) }
                        state.meetingsVersion += 1
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions")
            }
            Picker("", selection: $tab.value) {
                Text("Notes").tag(0); Text("Transcript").tag(1); Text("Actions").tag(2); Text("Email de suivi").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
            ScrollView {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        switch tab.value {
                        case 0:
                            if meeting.summary.isEmpty {
                                EmptyLine(icon: "hourglass", text: meeting.status == "recording" ? "Le compte rendu sera rédigé à la fin de la réunion." : "Rédaction en cours…")
                            } else {
                                Text((try? AttributedString(markdown: meeting.summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(meeting.summary))
                                    .font(.system(size: 14)).textSelection(.enabled)
                            }
                        case 1:
                            ForEach(segments) { s in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(String(format: "%02d:%02d", Int(s.start) / 60, Int(s.start) % 60))
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                    Text(SpeakerLabels.display(s.speaker, me: String(localized: "Moi"), them: String(localized: "Eux"),
                                                               remote: String(localized: "Interlocuteur")))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(s.speaker == "me" ? Theme.accent : Theme.warn)
                                        .frame(width: s.speaker.hasPrefix("them:") ? 96 : 34, alignment: .leading)
                                    Text(s.text).font(.system(size: 13.5)).textSelection(.enabled)
                                }
                            }
                            if segments.isEmpty { EmptyLine(icon: "text.bubble", text: "Pas encore de transcription.") }
                        case 2:
                            ForEach(todos) { t in
                                Toggle(isOn: Binding(get: { t.done }, set: { var u = t; u.done = $0; u.doneAt = $0 ? Date() : nil; try? store.update(u); state.meetingsVersion += 1 })) {
                                    Text(t.text).strikethrough(t.done).font(.system(size: 13.5))
                                }
                                .toggleStyle(.checkbox)
                            }
                            if todos.isEmpty { EmptyLine(icon: "checklist", text: "Aucune action relevée.") }
                        default:
                            Text(meeting.followUpEmail).font(.system(size: 13.5)).textSelection(.enabled)
                            if !meeting.followUpEmail.isEmpty { Button("Copier l'email") { copy(meeting.followUpEmail) }.buttonStyle(.borderedProminent) }
                        }
                    }
                }
            }
        }
        .padding(22)
        .animation(.easeOut(duration: 0.15), value: tab.value)
    }

    private var segments: [MeetingSegment] { (try? store.segments(meetingID: meeting.id)) ?? [] }
    private var todos: [Todo] { (try? store.todos(meetingID: meeting.id)) ?? [] }
    private var statusLabel: LocalizedStringKey {
        switch meeting.status { case "recording": "en cours"; case "processing": "rédaction des notes"; case "error": "erreur"; default: "terminée" }
    }
}

// MARK: - Tâches

private struct TasksPage: View {
    @ObservedObject var state: AppState
    let store: Store
    @StateObject private var items = ViewState<[Todo]>([])
    @StateObject private var newText = ViewState("")
    @StateObject private var showDone = ViewState(false)

    var body: some View {
        PageScaffold(title: "Tâches", subtitle: "Relevées dans vos réunions ou ajoutées à la main") {
            Card(padding: 14) {
                HStack {
                    TextField("Nouvelle tâche", text: $newText.value).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Ajouter", action: add).buttonStyle(.borderedProminent).disabled(newText.value.trimmingCharacters(in: .whitespaces).isEmpty)
                    Toggle("Afficher les terminées", isOn: $showDone.value).toggleStyle(.switch).controlSize(.small)
                }
            }
            if items.value.isEmpty {
                Card { EmptyLine(icon: "checklist", text: "Rien à faire. Les actions décidées en réunion arrivent ici automatiquement.") }
            } else {
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(items.value) { t in
                            HStack(spacing: 10) {
                                Toggle(isOn: Binding(get: { t.done }, set: { done in
                                    var u = t; u.done = done; u.doneAt = done ? Date() : nil; try? store.update(u)
                                    withAnimation(Theme.ease) { load() }
                                })) {
                                    Text(t.text).strikethrough(t.done).foregroundStyle(t.done ? Theme.textSecondary : Theme.text).font(.system(size: 13.5))
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                if let mid = t.meetingID, let m = try? store.meeting(id: mid) {
                                    Text(m.title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                Button { try? store.deleteTodo(id: t.id); withAnimation(Theme.ease) { load() } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).accessibilityLabel("Supprimer")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                            if t.id != items.value.last?.id { Divider().padding(.leading, 36) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.meetingsVersion) { _ in load() }
        .onChange(of: showDone.value) { _ in load() }
    }

    private func add() {
        let t = newText.value.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        try? store.insert(Todo(text: t))
        newText.value = ""
        withAnimation(Theme.ease) { load() }
    }

    private func load() { items.value = (try? store.todos(openOnly: !showDone.value)) ?? [] }
}

// MARK: - Langues parlées

/// Choix multiple des langues : Whisper ne choisira qu'entre elles (aucune cochée = détection libre).
struct LanguagesPicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack {
            Text("Langues parlées").foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Menu {
                ForEach(AppSettings.languageChoices, id: \.code) { choice in
                    Toggle(isOn: Binding(
                        get: { settings.languages.contains(choice.code) },
                        set: { on in
                            if on { settings.languages.append(choice.code) } else { settings.languages.removeAll { $0 == choice.code } }
                        })) {
                        Text(LocalizedStringKey(choice.name))
                    }
                }
                Divider()
                Button("Toutes (détection libre)") { settings.languages = [] }
            } label: {
                Text(summary).foregroundStyle(Theme.chipText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var summary: String {
        if settings.languages.isEmpty { return String(localized: "Toutes") }
        return settings.languages.compactMap { code in
            AppSettings.languageChoices.first { $0.code == code }.map { String(localized: String.LocalizationValue($0.name)) } ?? code
        }.joined(separator: ", ")
    }
}
