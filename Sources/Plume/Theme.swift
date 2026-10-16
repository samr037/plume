import AppKit
import SwiftUI

/// Palette de Plume (direction « tableau de bord ») : fond sauge, cartes claires, bandeau d'encre, accent vert pétrole.
/// Chaque couleur a sa variante sombre, l'apparence suit le réglage du système.
enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let ground = dynamic(hex(0xE9ECE8), hex(0x111614))
    static let card = dynamic(hex(0xF7F8F5), hex(0x1A211E))
    static let cardStroke = dynamic(hex(0xD7DCD6), hex(0x2A332F))
    static let ink = dynamic(hex(0x17201D), hex(0x13241F))
    static let inkRaised = dynamic(hex(0x2B3632), hex(0x22362F))
    static let onInk = Color(nsColor: hex(0xF3F5F1))
    static let onInkSecondary = Color(nsColor: hex(0xB6C1BB))
    static let text = dynamic(hex(0x17201D), hex(0xE8ECE9))
    static let textSecondary = dynamic(hex(0x4E5A55), hex(0xA3AFA9))
    static let accent = dynamic(hex(0x0F6B62), hex(0x3FB5A4))
    static let chip = dynamic(hex(0xD8EBE6), hex(0x1F3A35))
    static let chipText = dynamic(hex(0x0A4A44), hex(0x9FE0D5))
    static let ok = dynamic(hex(0x1F8F4E), hex(0x4CC27F))
    static let warn = dynamic(hex(0xB4531F), hex(0xF0A35E))
    /// Segments du parcours de la voix.
    static let segAudio = dynamic(hex(0x9AA8A2), hex(0x55635D))
    // Whisper clair, LLM profond : distincts par la luminosité, pas seulement la teinte.
    static let segASR = dynamic(hex(0x8DC4B7), hex(0x9FD8CB))
    static let segLLM = dynamic(hex(0x2E9C8C), hex(0x2E8A7C))
    static let segPaste = dynamic(hex(0xC9A227), hex(0xD9B54A))

    static let radius: CGFloat = 16
    static let ease = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)
}

/// Carte de base : surface claire, bord fin, ombre douce et décalée.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.cardStroke.opacity(0.7)))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// Touche de clavier dessinée (fn, ⌃, ⌘…).
struct Keycap: View {
    var label: String
    var onInk = false
    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(onInk ? Theme.onInk : Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(onInk ? Theme.inkRaised : Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(onInk ? Color.white.opacity(0.18) : Theme.cardStroke))
            // Bord inférieur plus sombre, dans la touche : la touche reste un seul objet.
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(onInk ? 0.35 : 0.12)).frame(height: 1).padding(.horizontal, 4).padding(.bottom, 1)
            }
            .shadow(color: .black.opacity(onInk ? 0.3 : 0.15), radius: 1, y: 1)
            .accessibilityLabel(label)
    }
}

/// Titre de section : poids et taille, pas d'étiquette au-dessus.
struct SectionTitle: View {
    var text: LocalizedStringKey
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
    }
}

/// Puce de choix intégrée à une phrase : un menu natif posé sur un mot surligné.
/// (Sur macOS, un Menu ne garde ni fond ni ordre d'icônes dans son label : l'habillage est donc à l'extérieur.)
struct InlineChoice<T: Hashable>: View {
    @Binding var selection: T
    var options: [(T, String)]
    var body: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(options, id: \.0) { value, label in
                    Button { selection = value } label: {
                        if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                    }
                }
            } label: {
                Text(options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.chipText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.chipText.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Réglage on/off : libellé à gauche, interrupteur aligné à droite (convention macOS).
struct SettingToggle: View {
    var label: LocalizedStringKey
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// Pastille d'état (vert = prêt, orange = attention).
struct StatusDot: View {
    var ok: Bool
    var body: some View {
        Circle().fill(ok ? Theme.ok : Theme.warn).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
