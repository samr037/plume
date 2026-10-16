import AppKit
import ApplicationServices
import Foundation

/// Lecture AX de l'onglet actif d'un navigateur (URL + titre), sans AppleScript. Exige la permission Accessibilité.
/// Appels bloquants (timeout AX 0,2 s par requête) : à faire hors du main thread.
public enum BrowserTabReader {
    static let timeout: Float = 0.2
    static let maxNodes = 600

    /// URL et titre de l'onglet actif de la fenêtre au premier plan de `pid`.
    public static func activeTab(pid: pid_t) -> (url: String?, title: String?) {
        guard AXIsProcessTrusted() else { return (nil, nil) }
        let app = application(pid)
        guard let window = focusedWindow(app) else { return (nil, nil) }
        let title: String? = attr(window, kAXTitleAttribute)
        var url: String?
        if let web = find(in: window, where: { role($0) == "AXWebArea" }) { url = urlAttr(web) }
        if url == nil, let field = find(in: window, where: isAddressField) { url = attr(field, kAXValueAttribute) }
        return (url.flatMap { $0.isEmpty ? nil : $0 }, title)
    }

    /// Titres d'onglets (toutes fenêtres) qui ressemblent à une réunion ou portent le marqueur Chromium d'enregistrement.
    public static func meetingTabTitles(pid: pid_t) -> [String] {
        tabTitles(pid: pid).filter(MeetingCatalog.isMeetingTitle)
    }

    /// Tous les titres d'onglets visibles en AX (`AXTabGroup` → `AXRadioButton`).
    public static func tabTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        var out: [String] = []
        for window in windows(application(pid)) {
            guard let group = find(in: window, where: { role($0) == "AXTabGroup" }) else { continue }
            let tabs: [AXUIElement] = attr(group, kAXTabsAttribute) ?? attr(group, kAXChildrenAttribute) ?? []
            for tab in tabs where role(tab) == "AXRadioButton" {
                if let t: String = attr(tab, kAXTitleAttribute) ?? attr(tab, kAXDescriptionAttribute), !t.isEmpty { out.append(t) }
            }
        }
        return out
    }

    /// Titres des fenêtres de l'app (huddle Slack, fenêtre de réunion Zoom/Teams).
    public static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        return windows(application(pid)).compactMap { attr($0, kAXTitleAttribute) }
    }

    // MARK: AX

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        // Chromium/Electron n'expose l'arbre web qu'à la demande d'une techno d'assistance.
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, MeetingCatalog.isChromium(bundleID: bid) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return app
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] { attr(app, kAXWindowsAttribute) ?? [] }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) ?? windows(app).first
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func role(_ el: AXUIElement) -> String? { attr(el, kAXRoleAttribute) }

    static func urlAttr(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &v) == .success, let v else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return v as? String
    }

    static func isAddressField(_ el: AXUIElement) -> Bool {
        guard role(el) == "AXTextField" else { return false }
        let label = [attr(el, kAXDescriptionAttribute) as String?, attr(el, kAXTitleAttribute) as String?, attr(el, "AXIdentifier") as String?]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        return ["address", "adresse", "url", "location", "omnibox", "search or enter"].contains { label.contains($0) }
    }

    /// Parcours en largeur borné (l'arbre web complet est énorme ; on s'arrête au premier nœud qui convient).
    static func find(in root: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var i = 0
        while i < queue.count, i < maxNodes {
            let el = queue[i]; i += 1
            if i > 1, match(el) { return el }
            // On ne descend pas dans le contenu web : l'URL est sur l'AXWebArea elle-même.
            if role(el) == "AXWebArea" { continue }
            queue.append(contentsOf: attr(el, kAXChildrenAttribute) as [AXUIElement]? ?? [])
        }
        return nil
    }
}
