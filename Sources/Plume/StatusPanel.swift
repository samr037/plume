import AppKit
import SwiftUI

/// État affiché par la barre flottante.
final class StatusModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording(handsFree: Bool)
        case processing
        case message(String, isError: Bool)
        /// Texte non collé (aucun champ éditable) : affiché avec un bouton Copier.
        case bubble(String)
        /// Mode Instruct : enregistrement ou réflexion.
        case instruct(String)
    }

    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 10)
    /// Animation d'entrée : la pastille monte de quelques points et apparaît.
    @Published var visible = false
    /// Souris au-dessus de la pastille (suivi global, Plume n'est jamais l'app au premier plan).
    @Published var hovering = false
    @Published var edge: BarEdge = .bottom
    /// Décalage du centre de la pastille par rapport au centre de la toile, le long du bord (points SwiftUI).
    @Published var alongOffset: CGFloat = 0
    /// Cadre de la pastille dans la toile (origine en haut à gauche), pour laisser passer les clics ailleurs.
    var pillFrame: CGRect = .zero

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() { levels = Array(repeating: 0, count: 10) }
}

enum BarEdge: String {
    case bottom, top, left, right

    var isVertical: Bool { self == .left || self == .right }

    /// Alignement de la pastille dans la toile : collée au bord d'écran.
    var alignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    var unitPoint: UnitPoint {
        switch self {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// La barre : une seule forme qui change de taille d'un état à l'autre (repos, survol, dictée, message),
/// le contenu se fond à l'intérieur. La fenêtre ne bouge pas : rien n'est rogné pendant l'animation.
struct StatusPillView: View {
    @ObservedObject var model: StatusModel
    var onCancel: () -> Void
    var onStop: () -> Void
    var onCopy: (String) -> Void
    var onDismiss: () -> Void
    var onStart: () -> Void
    var onDragChanged: () -> Void
    var onDragEnded: (_ moved: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Kind: Hashable { case dots, hover, recording, processing, text }

    private var kind: Kind {
        switch model.phase {
        case .hidden: model.hovering ? .hover : .dots
        case .recording: .recording
        case .processing: .processing
        case .message, .bubble, .instruct: .text
        }
    }

    /// Sur les bords gauche et droit, les états sans texte se mettent à la verticale.
    private var vertical: Bool { model.edge.isVertical && kind != .text }
    private var isBubble: Bool { if case .bubble = model.phase { true } else { false } }
    private var isIdle: Bool { kind == .dots || kind == .hover }

    private static let morph = Animation.spring(response: 0.38, dampingFraction: 0.78)

    var body: some View {
        pill
            .padding(8)
            .scaleEffect(model.visible || reduceMotion ? 1 : 0.9, anchor: model.edge.unitPoint)
            .opacity(model.visible ? 1 : 0)
            .offset(x: model.edge.isVertical ? 0 : model.alongOffset, y: model.edge.isVertical ? model.alongOffset : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.edge.alignment)
            .animation(reduceMotion ? nil : Self.morph, value: kind)
            .animation(reduceMotion ? nil : Self.morph, value: model.phase)
    }

    private var pill: some View {
        ZStack {
            content
                .id(kind)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
        .foregroundStyle(Theme.onInk)
        .padding(vertical ? .vertical : .horizontal, padding)
        .frame(width: vertical ? cross : nil, height: vertical || kind == .text ? nil : cross)
        .frame(minHeight: kind == .text ? 36 : nil)
        .background(RoundedRectangle(cornerRadius: isBubble ? 16 : 40, style: .continuous)
            .fill(Self.ink.opacity(kind == .dots ? 0.72 : 0.94)))
        .overlay(RoundedRectangle(cornerRadius: isBubble ? 16 : 40, style: .continuous).strokeBorder(Color.white.opacity(0.13)))
        .shadow(color: .black.opacity(kind == .dots ? 0.18 : 0.28), radius: kind == .dots ? 3 : 10, y: kind == .dots ? 1 : 4)
        .contentShape(RoundedRectangle(cornerRadius: isBubble ? 16 : 40, style: .continuous))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.pillFrame = $0 }
        // Simultané : les boutons (✕, ■, Copier) gardent leurs clics.
        .simultaneousGesture(dragOrClick(onClick: isIdle ? onStart : {}))
        .help(isIdle ? Text("Cliquez pour dicter, glissez pour déplacer, clic droit pour le menu") : Text(verbatim: ""))
        .accessibilityElement(children: isIdle ? .ignore : .contain)
        .accessibilityLabel(Text("Barre Plume"))
        .accessibilityAction { if isIdle { onStart() } }
    }

    /// Épaisseur de la pastille (perpendiculaire au bord).
    private var cross: CGFloat {
        switch kind {
        case .dots: 14
        case .hover: 32
        default: 36
        }
    }

    /// Marge intérieure le long du bord.
    private var padding: CGFloat {
        switch kind {
        case .dots: 10
        case .hover: vertical ? 10 : 14
        case .recording: vertical ? 10 : 8
        case .processing: vertical ? 10 : 14
        case .text: 14
        }
    }

    private var stack: AnyLayout { vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8)) }

    @ViewBuilder private var content: some View {
        switch kind {
        case .dots:
            stack {
                ForEach(0..<5, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.55)).frame(width: 3, height: 3)
                }
            }
        case .hover:
            stack {
                Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.accent)
                // À la verticale, une phrase ne tient pas : on garde l'essentiel.
                if vertical {
                    Text(verbatim: "fn").font(.system(size: 11, weight: .semibold, design: .monospaced))
                } else {
                    Text("Cliquez ou maintenez fn").font(.system(size: 12, weight: .medium)).fixedSize()
                }
            }
        case .recording:
            let handsFree = model.phase == .recording(handsFree: true)
            stack {
                if handsFree { pillButton("xmark", label: "Annuler", action: onCancel) }
                Bars(levels: model.levels, vertical: vertical)
                if handsFree { pillButton("stop.fill", label: "Terminer", action: onStop) }
            }
        case .processing:
            stack {
                ProgressView().controlSize(.small).tint(Theme.onInk)
                if !vertical { Text("Mise au propre…").font(.system(size: 12, weight: .medium)).fixedSize() }
            }
            .accessibilityLabel(Text("Mise au propre…"))
        case .text:
            HStack(spacing: 10) {
                switch model.phase {
                case .bubble(let text):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text).font(.system(size: 12)).lineLimit(8).frame(maxWidth: 420, alignment: .leading).textSelection(.enabled)
                        HStack {
                            Button("Copier") { onCopy(text) }.buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Fermer", action: onDismiss).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 10)
                case .instruct(let label):
                    Image(systemName: "sparkles").foregroundStyle(Self.accent)
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 380)
                    if label.hasPrefix("Écoute") { Bars(levels: model.levels, vertical: false) }
                case .message(let text, let isError):
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? Color(nsColor: Theme.hex(0xF0A35E)) : Self.accent)
                        .symbolEffect(.bounce, value: text)
                    Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: 380, alignment: .leading)
                default:
                    EmptyView()
                }
            }
            .fixedSize()
        }
    }

    /// Un seul geste : sous 4 points de déplacement c'est un clic, au-delà on déplace la barre.
    private func dragOrClick(onClick: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if hypot(v.translation.width, v.translation.height) > 4 { onDragChanged() }
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height) > 4
                onDragEnded(moved)
                if !moved { onClick() }
            }
    }

    private func pillButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    // Le panneau reste sombre dans les deux apparences : il flotte sur n'importe quel contenu.
    static let ink = Color(nsColor: Theme.hex(0x17201D))
    static let accent = Color(nsColor: Theme.hex(0x3FB5A4))
}

private struct Bars: View {
    var levels: [Float]
    var vertical = false
    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        layout {
            ForEach(levels.indices, id: \.self) { i in
                let length = 4 + CGFloat(levels[i]) * 18
                Capsule().fill(Color(nsColor: Theme.hex(0x3FB5A4)))
                    .frame(width: vertical ? length : 3, height: vertical ? 3 : length)
            }
        }
        .frame(width: vertical ? 22 : nil, height: vertical ? nil : 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// Vue racine : accepte le premier clic (Plume n'est jamais active) et fournit le menu du clic droit.
private final class BarHostView<Content: View>: NSHostingView<Content> {
    var contextMenu: (() -> NSMenu)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

/// NSPanel non-activant : n'enlève jamais le focus à l'app où l'on dicte.
/// C'est une toile transparente de taille fixe, collée au bord choisi : la pastille s'y anime librement.
/// Hors de la pastille, le panneau laisse passer les clics.
final class StatusPanelController {
    let model = StatusModel()
    private let panel: NSPanel
    private let host: BarHostView<StatusPillView>
    private let settings = AppSettings.shared
    private var hideWork: DispatchWorkItem?
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    private var observers: [Any] = []
    private var mouseTimer: Timer?
    private var appliedPosition = -1.0

    var onPasteLast: (() -> Void)?
    var onOpenHub: (() -> Void)?
    var onTransform: ((Int) -> Void)?
    var onScratchpad: (() -> Void)?

    /// Taille de la toile : assez grande pour la bulle de texte, sur un bord horizontal ou vertical.
    private static func canvasSize(for edge: BarEdge) -> CGSize {
        edge.isVertical ? CGSize(width: 480, height: 320) : CGSize(width: 600, height: 240)
    }

    init(onCancel: @escaping () -> Void, onStop: @escaping () -> Void, onStart: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let model = self.model
        var hide: () -> Void = {}
        var dragChanged: () -> Void = {}
        var dragEnded: (Bool) -> Void = { _ in }
        host = BarHostView(rootView: StatusPillView(
            model: model, onCancel: onCancel, onStop: onStop,
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                hide()
            },
            onDismiss: { hide() },
            onStart: onStart,
            onDragChanged: { dragChanged() },
            onDragEnded: { dragEnded($0) }))
        host.sizingOptions = []
        panel.contentView = host
        hide = { [weak self] in self?.show(.hidden) }
        dragChanged = { [weak self] in self?.dragMoved() }
        dragEnded = { [weak self] moved in self?.dragFinished(moved) }
        host.contextMenu = { [weak self] in self?.buildMenu() ?? NSMenu() }
        model.edge = BarEdge(rawValue: settings.flowBarEdge) ?? .bottom

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placeCanvas()
        })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        })
        // Suivi de la souris partout : survol de la pastille et passage des clics hors de celle-ci.
        // Lecture de la position à 20 Hz : les moniteurs globaux ne reçoivent pas toujours mouseMoved.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackMouse() }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        DispatchQueue.main.async { [weak self] in self?.show(.hidden) }
    }

    func show(_ phase: StatusModel.Phase, autoHideAfter: TimeInterval? = nil) {
        hideWork?.cancel()
        if case .recording = phase, model.phase == .hidden || model.phase == .processing { model.resetLevels() }
        let wasHidden = !panel.isVisible
        model.phase = phase
        if phase != .hidden { model.hovering = false }
        if phase == .hidden && !settings.showFlowBar {
            panel.orderOut(nil)
            model.visible = false
            return
        }
        if wasHidden { placeCanvas() }
        panel.orderFrontRegardless()
        if wasHidden {
            model.visible = false
            DispatchQueue.main.async { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.28)) { self.model.visible = true } }
        }
        if let autoHideAfter {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: work)
        }
    }

    private func settingsChanged() {
        let edge = BarEdge(rawValue: settings.flowBarEdge) ?? .bottom
        if edge != model.edge || settings.flowBarPosition != appliedPosition { placeCanvas() }
        let shouldShow = settings.showFlowBar || model.phase != .hidden
        if shouldShow != panel.isVisible { show(model.phase) }
    }

    // MARK: Souris

    /// Cadre de la pastille en coordonnées écran.
    private var pillScreenRect: NSRect {
        let f = model.pillFrame
        guard f.width > 0 else { return .zero }
        return NSRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    private func trackMouse() {
        guard panel.isVisible, drag == nil else { return }
        let inside = pillScreenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let hover = inside && model.phase == .hidden
        if model.hovering != hover { model.hovering = hover }
    }

    // MARK: Placement

    private var screen: NSScreen? {
        if panel.isVisible, let s = panel.screen { return s }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// Colle la toile au bord choisi. Près d'un coin, la toile reste dans l'écran et la pastille se décale dedans.
    /// `target` : écran imposé (lâcher d'un glisser), sinon celui qui porte la toile.
    private func placeCanvas(on target: NSScreen? = nil) {
        guard drag == nil, let vf = (target ?? screen)?.visibleFrame else { return }
        let edge = BarEdge(rawValue: settings.flowBarEdge) ?? .bottom
        let size = Self.canvasSize(for: edge)
        let pos = CGFloat(min(max(settings.flowBarPosition, 0), 1))
        appliedPosition = settings.flowBarPosition
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        // La pastille a 8 points de marge dans la toile : la toile déborde de 4 points pour la poser à 4 points du bord.
        let inset: CGFloat = 4
        var origin = NSPoint.zero
        var offset: CGFloat = 0
        // Le centre visé reste à au moins 40 points du coin pour que la pastille ne colle pas au bord perpendiculaire.
        switch edge {
        case .bottom, .top:
            let center = clamp(vf.minX + pos * vf.width, vf.minX + 40, vf.maxX - 40)
            origin.x = clamp(center - size.width / 2, vf.minX, vf.maxX - size.width)
            origin.y = edge == .bottom ? vf.minY - inset : vf.maxY - size.height + inset
            offset = center - (origin.x + size.width / 2)
        case .left, .right:
            let center = clamp(vf.minY + pos * vf.height, vf.minY + 40, vf.maxY - 40)
            origin.y = clamp(center - size.height / 2, vf.minY, vf.maxY - size.height)
            origin.x = edge == .left ? vf.minX - inset : vf.maxX - size.width + inset
            // SwiftUI compte y vers le bas.
            offset = -(center - (origin.y + size.height / 2))
        }
        // La toile change d'un coup : la pastille suit sans glisser à l'intérieur.
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.edge = edge
            model.alongOffset = offset
        }
    }

    // MARK: Glisser-aimanter

    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if drag == nil {
            drag = (mouse, panel.frame.origin)
            panel.ignoresMouseEvents = false
        }
        guard let drag else { return }
        panel.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    /// Lâcher : la barre rejoint le bord le plus proche de son centre, à la position où on l'a posée.
    private func dragFinished(_ moved: Bool) {
        guard moved, drag != nil else { drag = nil; return }
        let rect = pillScreenRect
        drag = nil
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let target = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screen
        guard let vf = target?.visibleFrame else { return }
        let distances: [(BarEdge, CGFloat)] = [
            (.bottom, center.y - vf.minY), (.top, vf.maxY - center.y),
            (.left, center.x - vf.minX), (.right, vf.maxX - center.x),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        let along: CGFloat = edge.isVertical ? (center.y - vf.minY) / vf.height : (center.x - vf.minX) / vf.width
        // Aimantation au centre : à moins de 4 % du milieu, la barre se recentre.
        let pos = abs(along - 0.5) < 0.04 ? 0.5 : min(max(along, 0), 1)
        model.hovering = false
        settings.flowBarEdge = edge.rawValue
        settings.flowBarPosition = Double(pos)
        // Écran du lâcher, pas `screen` (celui qui porte la plus grande part de la toile, souvent l'autre moniteur).
        placeCanvas(on: target)
        trackMouse()
    }

    // MARK: Menu (clic droit)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Coller la dernière dictée")) { [weak self] in self?.onPasteLast?() })
        menu.addItem(ClosureMenuItem(String(localized: "Ouvrir Plume…")) { [weak self] in self?.onOpenHub?() })
        menu.addItem(ClosureMenuItem(String(localized: "Bloc-notes")) { [weak self] in self?.onScratchpad?() })
        let rewrite = NSMenuItem(title: String(localized: "Réécrire la sélection"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, t) in settings.transforms.prefix(9).enumerated() {
            let item = ClosureMenuItem(t.name) { [weak self] in self?.onTransform?(i) }
            item.keyEquivalent = "\(i + 1)"
            item.keyEquivalentModifierMask = [.control, .option]
            sub.addItem(item)
        }
        rewrite.submenu = sub
        menu.addItem(rewrite)
        menu.addItem(.separator())
        let edges: [(BarEdge, String)] = [
            (.bottom, String(localized: "En bas")), (.top, String(localized: "En haut")),
            (.left, String(localized: "À gauche")), (.right, String(localized: "À droite")),
        ]
        for (edge, title) in edges {
            let item = ClosureMenuItem(title) { [weak self] in
                self?.settings.flowBarPosition = 0.5
                self?.settings.flowBarEdge = edge.rawValue
            }
            item.state = model.edge == edge ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Masquer la barre")) { [weak self] in self?.settings.showFlowBar = false })
        return menu
    }
}

/// Élément de menu qui exécute une closure (évite un objet cible par action).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
