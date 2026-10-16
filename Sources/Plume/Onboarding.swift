import AppKit
import ApplicationServices
import SwiftUI
import PlumeCore

/// Guide de bienvenue : 4 étapes, la 3ᵉ est une vraie dictée (le « déclic » : voir son texte apparaître).
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    private let state: AppState
    private let levels: StatusModel
    private let store: Store
    var onFinish: (() -> Void)?

    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingDone") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingDone") }
    }

    init(state: AppState, levels: StatusModel, store: Store) {
        self.state = state
        self.levels = levels
        self.store = store
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Bienvenue dans Plume"
            w.contentView = NSHostingView(rootView: OnboardingView(state: state, levels: levels, store: store) { [weak self] in self?.finish() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Self.isDone = true
        window?.close()
        onFinish?()
    }
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @ObservedObject var levels: StatusModel
    let store: Store
    var finish: () -> Void

    @StateObject private var step: ViewState<Int>
    @StateObject private var forward = ViewState(true)

    init(state: AppState, levels: StatusModel, store: Store, initialStep: Int = 0, finish: @escaping () -> Void) {
        self.state = state
        self.levels = levels
        self.store = store
        self.finish = finish
        _step = StateObject(wrappedValue: ViewState(initialStep))
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch step.value {
                    case 0: WelcomeStep(state: state)
                    case 1: PermissionsStep(state: state)
                    case 2: TryStep(state: state, levels: levels, store: store)
                    default: GesturesStep()
                    }
                }
                .id(step.value)
                .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44).padding(.top, 40)

            HStack {
                ProgressDots(count: 4, current: step.value)
                Spacer()
                if step.value > 0 { Button("Retour") { go(step.value - 1) }.keyboardShortcut(.cancelAction) }
                if step.value < 3 {
                    Button("Passer le guide", action: finish).buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                    Button("Continuer") { go(step.value + 1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Commencer à dicter", action: finish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28).padding(.vertical, 18)
            .background(Theme.card)
        }
        .background(Theme.ground)
        .tint(Theme.accent)
        .frame(width: 760, height: 540)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward.value ? 40 : -40)),
                           removal: .opacity.combined(with: .offset(x: forward.value ? -40 : 40)))
    }

    private func go(_ n: Int) {
        forward.value = n > step.value
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4)) { step.value = n }
    }
}

private struct ProgressDots: View {
    var count: Int
    var current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(i == current ? Theme.accent : Theme.cardStroke)
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: current)
        .accessibilityElement().accessibilityLabel("Étape \(current + 1) sur \(count)")
    }
}

private struct StepHeader: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 1. Bienvenue

private struct WelcomeStep: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                PlumeMark().frame(width: 54, height: 54)
                StepHeader(title: "Plume écrit ce que vous dites.",
                           subtitle: "Vous parlez, Plume transcrit, met au propre et colle le texte là où vous écrivez. Tout se passe sur ce Mac : aucun compte, aucun serveur.")
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "Préparation des moteurs")
                    LoadingRow(name: "Transcription (Parakeet)", ready: state.asrReady, detail: state.asrReady ? nil : state.asrStatus,
                               progress: state.asrProgress)
                    LoadingRow(name: "Mise au propre (LLM local)", ready: state.llmReady, detail: state.llmReady ? nil : state.llmStatus,
                               progress: state.llmProgress)
                    LoadingRow(name: "Détection de la voix (Silero)", ready: state.vadReady, detail: nil)
                    Text("Au premier lancement, Plume télécharge ses modèles (environ 4 Go) puis les prépare pour ce Mac. Vous pouvez continuer le guide en attendant ; un téléchargement interrompu reprend où il s'était arrêté.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Monogramme : une onde qui devient un trait d'écriture.
private struct PlumeMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink)
            Canvas { ctx, size in
                var p = Path()
                let mid = size.height / 2
                let bars: [CGFloat] = [0.18, 0.42, 0.7, 0.36, 0.55]
                for (i, h) in bars.enumerated() {
                    let x = size.width * (0.2 + CGFloat(i) * 0.1)
                    p.move(to: CGPoint(x: x, y: mid - size.height * h / 2))
                    p.addLine(to: CGPoint(x: x, y: mid + size.height * h / 2))
                }
                ctx.stroke(p, with: .color(Color(nsColor: Theme.hex(0x3FB5A4))), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                var line = Path()
                line.move(to: CGPoint(x: size.width * 0.66, y: mid))
                line.addLine(to: CGPoint(x: size.width * 0.82, y: mid))
                ctx.stroke(line, with: .color(Color(nsColor: Theme.hex(0xF3F5F1))), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LoadingRow: View {
    var name: LocalizedStringKey
    var ready: Bool
    var detail: String?
    var progress: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            if let progress, !ready {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .padding(.leading, 28)
                    .animation(.easeOut(duration: 0.25), value: progress)
                    .accessibilityLabel(Text(name))
                    .accessibilityValue(Text("\(Int(progress * 100)) %"))
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            ZStack {
                if ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: ready)
            Text(name).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(maxWidth: 260, alignment: .trailing) }
        }
    }
}

// MARK: 2. Autorisations

private struct PermissionsStep: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Deux autorisations, une seule fois.",
                       subtitle: "macOS demande votre accord pour que Plume entende votre voix et puisse coller du texte dans les autres apps.")
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionCard(icon: "mic", title: "Micro", detail: "Plume n'écoute que pendant que vous maintenez fn.",
                                   granted: state.microphoneGranted,
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                                   onMicrophone: { state.microphoneGranted = $0 })
                    Divider()
                    PermissionCard(icon: "keyboard", title: "Accessibilité", detail: "Pour la touche fn, le collage et la lecture du texte autour du curseur.",
                                   granted: state.accessibilityGranted,
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: "globe").frame(width: 22).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Conseil : touche \(Image(systemName: "globe"))").font(.system(size: 14, weight: .semibold))
                            Text("Dans Clavier, réglez « Appuyer sur \(Image(systemName: "globe")) pour » sur « Ne rien faire » : fn sera entièrement à Plume.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Réglages Clavier") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionCard: View {
    var icon: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var granted: Bool
    var url: String
    /// Résultat de la demande d'accès au micro (sinon l'état affiché ne bouge qu'au prochain retour dans l'app).
    var onMicrophone: (@MainActor (Bool) -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            ZStack {
                if granted {
                    Label("Accordé", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 13, weight: .medium))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Button("Autoriser…") {
                        // L'app n'apparaît dans la liste Accessibilité qu'après une première demande.
                        if url.hasSuffix("Accessibility") {
                            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        } else {
                            Task { @MainActor in
                                let ok = await AudioRecorder.requestPermission()
                                onMicrophone?(ok)
                            }
                        }
                        NSWorkspace.shared.open(URL(string: url)!)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: granted)
        }
    }
}

// MARK: 3. Essai réel

private struct TryStep: View {
    @ObservedObject var state: AppState
    @ObservedObject var levels: StatusModel
    let store: Store
    @StateObject private var text = ViewState("")
    @StateObject private var startVersion = ViewState(-1)
    @StateObject private var result = ViewState<TranscriptRecord?>(nil)
    @StateObject private var missed = ViewState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Essayez :").font(.system(size: 30, weight: .semibold))
                Text("maintenez").font(.system(size: 30, weight: .semibold))
                Keycap(label: "fn").alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                Text("et parlez.").font(.system(size: 30, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            Text("Cliquez dans le cadre, maintenez fn, dites par exemple « Euh, demain on se voit à dix heures, non pardon, à onze heures. », puis relâchez.")
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text.value)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(state.recording ? Theme.accent : Theme.cardStroke, lineWidth: state.recording ? 2 : 1))
                    .animation(.easeOut(duration: 0.15), value: state.recording)
                    .accessibilityLabel("Zone d'essai")
                if text.value.isEmpty && !state.recording {
                    Text("Votre texte apparaîtra ici…").font(.system(size: 16)).foregroundStyle(Theme.textSecondary).padding(17).allowsHitTesting(false)
                }
            }
            .frame(height: 150)

            ZStack(alignment: .leading) {
                if state.recording {
                    HStack(spacing: 10) {
                        LiveBars(levels: levels.levels)
                        Text("Je vous écoute… relâchez fn pour coller.").font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    .transition(.opacity)
                } else if missed.value {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.warn)
                        Text("Plume a bien entendu, mais le texte n'est pas arrivé ici. Cliquez dans le cadre puis réessayez.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    .transition(.opacity)
                } else if let r = result.value {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Theme.ok)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("C'est collé, en \(String(format: "%.2f", Double(r.totalMs) / 1000)) s.").font(.system(size: 14, weight: .semibold))
                            if r.rawText != r.finalText, !r.rawText.isEmpty {
                                Text("Vous avez dit : « \(r.rawText) »").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text(state.asrReady ? "Prêt. Maintenez fn quand vous voulez." : "Les moteurs finissent de charger…")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 40)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: result.value?.id)
            .animation(.easeOut(duration: 0.15), value: state.recording)
            Spacer(minLength: 0)
        }
        .onAppear { startVersion.value = state.historyVersion }
        .onChange(of: state.historyVersion) { v in
            guard v > startVersion.value, let last = try? store.lastTranscript(), last.mode == "dictation", last.status != "dropped" else { return }
            // Succès seulement si le texte est vraiment arrivé dans la zone d'essai (pas sur la foi du presse-papier).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let arrived = !text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                missed.value = !arrived
                result.value = arrived ? last : nil
            }
        }
    }
}

/// Barres de niveau en direct (même source que la barre de dictée).
struct LiveBars: View {
    var levels: [Float]
    var color: Color = Theme.accent
    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: 3, height: 4 + CGFloat(levels[i]) * 18)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

// MARK: 4. Gestes

private struct GesturesStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Quatre gestes, c'est tout.",
                       subtitle: "Le reste se règle dans la fenêtre Plume, accessible depuis l'icône de la barre des menus.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 14) {
                GestureCard(keys: ["fn"], title: "Dicter", detail: "Maintenez, parlez, relâchez. Une autre touche pendant fn annule.")
                GestureCard(keys: ["fn", "fn"], title: "Mains libres", detail: "Deux appuis rapides ; fn pour terminer, Échap pour annuler.")
                GestureCard(keys: ["⌃", "fn"], title: "Instruct", detail: "⌃ puis fn : « réécris plus poliment », « traduis en anglais »…")
                GestureCard(keys: ["⌃", "⌘", "V"], title: "Recoller", detail: "La dernière dictée, là où est le curseur.")
            }
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2").foregroundStyle(Theme.accent)
                Text("Pendant un appel Zoom, Meet ou Teams, Plume propose de prendre des notes ; le compte rendu arrive à la fin.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GestureCard: View {
    var keys: [String]
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) { ForEach(keys.indices, id: \.self) { Keycap(label: keys[$0]) } }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 92, alignment: .topLeading)
        }
    }
}
