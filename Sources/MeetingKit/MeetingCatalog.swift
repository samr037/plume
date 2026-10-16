import Foundation

/// Plateforme de visio reconnue (catalogue des apps et sites de visio courants).
public enum MeetingPlatform: String, CaseIterable, Sendable {
    case zoom, meet, teams, facetime, webex, slack, discord, whatsapp, browser, other

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .facetime: "FaceTime"
        case .webex: "Webex"
        case .slack: "Slack"
        case .discord: "Discord"
        case .whatsapp: "WhatsApp"
        case .browser: "Navigateur"
        case .other: "Visio"
        }
    }

    /// Une prise de micro par cette app suffit à parler de réunion (pas de preuve URL/titre exigée).
    /// Discord et WhatsApp ne prennent le micro qu'en appel, on les accepte.
    public var isConferenceApp: Bool {
        switch self {
        case .zoom, .teams, .facetime, .webex, .discord, .whatsapp, .other: true
        case .meet, .slack, .browser: false
        }
    }
}

public enum MeetingCatalog {
    // Bundle IDs en minuscules ; un ID couvre aussi ses helpers (`id.helper`, `id.helper.renderer`…).
    static let apps: [(String, MeetingPlatform)] = [
        ("com.apple.facetime", .facetime), ("com.apple.avconferenced", .facetime),
        ("us.zoom.xos", .zoom), ("us.zoom.cpthost", .zoom),
        ("com.microsoft.teams", .teams), ("com.microsoft.teams2", .teams),
        ("com.cisco.webexmeetingsapp", .webex), ("cisco-systems.spark", .webex), ("com.webex.meetingmanager", .webex),
        ("com.tinyspeck.slackmacgap", .slack),
        ("com.hnc.discord", .discord),
        ("net.whatsapp.whatsapp", .whatsapp), ("desktop.whatsapp", .whatsapp),
        ("com.electron.uberconference", .other), ("com.gather.gather", .other),
        ("com.larksuite.larkapp", .other), ("com.tencent.tencentmeeting", .other),
    ]

    /// Navigateurs (helpers inclus par préfixe). `com.apple.webkit.gpu` = process qui tient le micro pour Safari.
    public static let browserBundleIDs: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary", "com.google.chrome.dev",
        "org.chromium.chromium", "com.apple.safari", "com.apple.safaritechnologypreview", "com.apple.webkit.gpu",
        "company.thebrowser.browser", "company.thebrowser.dia", "com.brave.browser", "com.brave.browser.beta",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.operasoftware.opera", "com.vivaldi.vivaldi", "app.zen-browser.zen", "ai.perplexity.comet", "com.openai.atlas",
    ]

    /// Navigateurs Chromium : il faut `AXManualAccessibility` pour exposer l'arbre web.
    static let chromiumPrefixes = ["com.google.chrome", "org.chromium", "company.thebrowser", "com.brave.browser",
                                   "com.microsoft.edgemac", "com.operasoftware", "com.vivaldi", "ai.perplexity", "com.openai.atlas"]

    static func matches(_ id: String, _ base: String) -> Bool { id == base || id.hasPrefix(base + ".") }

    public static func isBrowser(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return browserBundleIDs.contains { matches(id, $0) }
    }

    static func isChromium(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return chromiumPrefixes.contains { id.hasPrefix($0) }
    }

    /// Plateforme d'une app d'après son bundle ID (ou celui d'un de ses helpers). `.browser` pour un navigateur.
    public static func platform(forBundleID bundleID: String) -> MeetingPlatform? {
        let id = bundleID.lowercased()
        // L'ID le plus long gagne (com.microsoft.teams2 avant com.microsoft.teams).
        if let hit = apps.filter({ matches(id, $0.0) }).max(by: { $0.0.count < $1.0.count }) { return hit.1 }
        return isBrowser(bundleID: id) ? .browser : nil
    }

    // MARK: URL

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    /// Ancre l'hôte : début de chaîne, schéma optionnel, sous-domaines optionnels (`https://us02web.zoom.us/…`).
    private static func host(_ p: String) -> NSRegularExpression { regex(#"^\s*(?:[a-z][a-z0-9+.-]*://)?(?:[^/?#\s]*\.)?"# + p) }
    // Regex ancrées sur l'hôte pour accepter une URL complète sans faux positif dans le chemin.
    static let meetRe = host(#"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#]|$)"#)
    static let zoomRe = host(#"(?:zoom\.us|zoomgov\.com)/(?:(?:j|s|wc/join)/(\d+)|wc/(\d+)/(?:join|start))"#)
    static let teamsRe = host(#"teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet|v2/\?meetingjoin)"#)
    static let webexRe = host(#"webex\.com/(?:meet/|join/|wbxmjs/|webappng/|[^/?#]+/j\.php|[^/?#]+/meet/)"#)
    static let otherRes: [(NSRegularExpression, MeetingPlatform)] = [
        (host(#"whereby\.com/[^/?#\s]+"#), .other),
        (host(#"(?:app\.)?gotomeeting\.com/(?:join/)?\d+"#), .other),
        (host(#"bluejeans\.com/\d+"#), .other),
        (host(#"chime\.aws/\d+"#), .other),
        (host(#"meetings\.dialpad\.com/"#), .other),
        (host(#"app\.slack\.com/huddle/"#), .slack),
    ]

    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// Plateforme d'une URL d'onglet (avec ou sans schéma) si c'est une réunion en cours, pas une simple page d'accueil.
    public static func platform(forURL url: String) -> MeetingPlatform? {
        if firstMatch(meetRe, url) != nil { return .meet }
        if firstMatch(zoomRe, url) != nil { return .zoom }
        if firstMatch(teamsRe, url) != nil { return .teams }
        if firstMatch(webexRe, url) != nil { return .webex }
        return otherRes.first { firstMatch($0.0, url) != nil }?.1
    }

    /// Code de réunion Meet (`abc-defg-hij`) ou ID Zoom, pour corréler avec le calendrier.
    public static func meetingCode(forURL url: String) -> String? {
        for re in [meetRe, zoomRe] {
            guard let m = firstMatch(re, url) else { continue }
            for i in 1 ..< m.numberOfRanges {
                if let r = Range(m.range(at: i), in: url) { return url[r].lowercased() }
            }
        }
        return nil
    }

    // MARK: Titres

    /// Suffixe que Chromium ajoute aux titres d'onglets en AX.
    static let recordingRe = regex(#"\s+[-–]\s+(?:camera and microphone recording|microphone recording|camera recording)\b"#)
    static let meetTitleRe = regex(#"^\s*(?:google\s+)?meet\s*[-–:]\s*(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|\S)"#)
    static let teamsTitleRe = regex(#"\|\s*microsoft teams\b"#)
    static let huddleRes = [regex(#"^\s*huddle\s*:"#), regex(#"slack\s*🎤"#), regex(#"\[main\]"#)]
    static let zoomTitleRe = regex(#"^\s*zoom(?: workplace)?\s*(?:meeting|webinar)\b"#)

    /// Vrai si le titre porte le marqueur Chromium « - Camera and microphone recording ».
    public static func hasRecordingMarker(_ title: String) -> Bool { firstMatch(recordingRe, title) != nil }

    /// Titre de fenêtre Slack au premier plan pendant un huddle (`main#94039`).
    public static func isSlackHuddleTitle(_ title: String) -> Bool { huddleRes.contains { firstMatch($0, title) != nil } }

    /// Plateforme déduite d'un titre de fenêtre ou d'onglet (« Meet - abc-defg-hij », « … | Microsoft Teams », huddle Slack).
    public static func platform(forTitle title: String) -> MeetingPlatform? {
        if firstMatch(meetTitleRe, title) != nil { return .meet }
        if firstMatch(teamsTitleRe, title) != nil { return .teams }
        if firstMatch(zoomTitleRe, title) != nil { return .zoom }
        if isSlackHuddleTitle(title) { return .slack }
        return nil
    }

    /// Titre d'onglet ou de fenêtre qui désigne une réunion : plateforme reconnue, ou onglet qui enregistre le micro.
    public static func isMeetingTitle(_ windowOrTabTitle: String) -> Bool {
        platform(forTitle: windowOrTabTitle) != nil || hasRecordingMarker(windowOrTabTitle)
    }
}
