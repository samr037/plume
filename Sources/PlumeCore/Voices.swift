import Foundation

// MARK: - « My Voice » : styles par application

public enum StylePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case formal, casual, veryCasual, excited
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .formal: "Formel"
        case .casual: "Décontracté"
        case .veryCasual: "Très décontracté"
        case .excited: "Enthousiaste"
        }
    }

    /// Consigne ajoutée au message du formatteur.
    var instruction: String {
        switch self {
        case .formal: "Style : soigné et professionnel, phrases complètes, ponctuation complète."
        case .casual: "Style : naturel et détendu, ton oral léger conservé, ponctuation simple."
        case .veryCasual: "Style : très décontracté, comme un message entre amis ; pas de formules, ponctuation minimale."
        case .excited: "Style : enthousiaste et chaleureux ; points d'exclamation bienvenus quand c'est naturel."
        }
    }
}

public struct UserVoice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Noms d'apps ou hôtes web (« Slack », « Gmail », « mail.google.com »…).
    public var appNames: [String]
    public var cleanupLevel: CleanupLevel
    public var style: StylePreference
    public var builtIn: Bool

    public init(id: String, name: String, appNames: [String], cleanupLevel: CleanupLevel = .light, style: StylePreference = .formal, builtIn: Bool = false) {
        self.id = id; self.name = name; self.appNames = appNames; self.cleanupLevel = cleanupLevel; self.style = style; self.builtIn = builtIn
    }
}

extension CleanupLevel: Codable {}

public enum VoiceResolver {
    /// Voix intégrées.
    public static let defaults: [UserVoice] = [
        UserVoice(id: "work", name: "Messages pro", appNames: ["Slack", "Microsoft Teams", "Mattermost", "Google Chat"], style: .casual, builtIn: true),
        UserVoice(id: "email", name: "Email", appNames: ["Gmail", "Microsoft Outlook", "Superhuman", "Mail", "Spark", "Proton Mail"], style: .formal, builtIn: true),
        UserVoice(id: "personal", name: "Messages perso", appNames: ["Messages", "WhatsApp", "Telegram", "Signal", "Messenger", "Discord", "WeChat"],
                  style: .veryCasual, builtIn: true),
        UserVoice(id: "other", name: "Autres", appNames: [], style: .formal, builtIn: true),
    ]

    /// Alias bundle id / hôte → nom d'app.
    static let aliases: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack", "app.slack.com": "Slack",
        "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams", "teams.microsoft.com": "Microsoft Teams",
        "teams.live.com": "Microsoft Teams", "chat.google.com": "Google Chat", "com.mattermost.desktop": "Mattermost",
        "mail.google.com": "Gmail", "com.microsoft.outlook": "Microsoft Outlook", "outlook.office.com": "Microsoft Outlook",
        "outlook.live.com": "Microsoft Outlook", "com.superhuman.electron": "Superhuman", "mail.superhuman.com": "Superhuman",
        "com.apple.mail": "Mail", "com.readdle.smartemail-mac": "Spark", "mail.proton.me": "Proton Mail",
        "com.apple.mobilesms": "Messages", "net.whatsapp.whatsapp": "WhatsApp", "web.whatsapp.com": "WhatsApp",
        "ru.keepcoder.telegram": "Telegram", "org.telegram.desktop": "Telegram", "web.telegram.org": "Telegram",
        "org.whispersystems.signal-desktop": "Signal", "com.facebook.archon": "Messenger", "www.messenger.com": "Messenger",
        "com.hnc.discord": "Discord", "discord.com": "Discord", "com.tencent.xinwechat": "WeChat",
    ]

    /// Catégorie d'app pour les filtres de préférences (`appCategory:`).
    public static func category(appName: String?, bundleID: String?, url: String?) -> String? {
        let names = identities(appName: appName, bundleID: bundleID, url: url)
        let email: Set = ["gmail", "microsoft outlook", "superhuman", "mail", "spark", "proton mail"]
        let messaging: Set = ["slack", "microsoft teams", "messages", "whatsapp", "telegram", "signal", "messenger", "discord", "wechat", "google chat", "mattermost"]
        let terminal: Set = ["terminal", "iterm2", "warp", "ghostty", "kitty", "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
        let code: Set = ["xcode", "visual studio code", "code", "cursor", "zed", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed.zed"]
        if !names.isDisjoint(with: email) { return "email" }
        if !names.isDisjoint(with: messaging) { return "messaging" }
        if !names.isDisjoint(with: terminal) { return "terminal" }
        if !names.isDisjoint(with: code) { return "code" }
        return nil
    }

    /// Toutes les identités connues de l'app courante, en minuscules (nom, bundle id, hôte, alias).
    public static func identities(appName: String?, bundleID: String?, url: String?) -> Set<String> {
        var out = Set<String>()
        if let appName { out.insert(appName.lowercased()) }
        if let b = bundleID?.lowercased() {
            out.insert(b)
            if let a = aliases[b] { out.insert(a.lowercased()) }
        }
        if let url, let host = URL(string: url)?.host?.lowercased() ?? (url.contains("/") ? nil : url.lowercased()) {
            out.insert(host)
            if let a = aliases[host] { out.insert(a.lowercased()) }
        }
        return out
    }

    /// Première voix (ordre work, email, personal, puis voix perso) dont une app correspond, sinon « other ».
    public static func resolve(_ voices: [UserVoice], appName: String?, bundleID: String?, url: String?) -> UserVoice {
        let ids = identities(appName: appName, bundleID: bundleID, url: url)
        let order = ["work", "email", "personal"]
        let sorted = voices.filter { $0.id != "other" }.sorted {
            (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name)
        }
        for v in sorted where v.appNames.contains(where: { ids.contains($0.lowercased()) }) { return v }
        return voices.first { $0.id == "other" } ?? defaults[3]
    }

    /// Retrait du point final selon le style.
    public static func stripTrailingPeriod(_ text: String, style: StylePreference, isMessaging: Bool,
                                           beforeLine: String, afterLine: String, hasSelection: Bool) -> String {
        guard !hasSelection, !(beforeLine + afterLine).contains(where: { ".!?".contains($0) }) else { return text }
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let strip: Bool
        switch style {
        case .formal: strip = false
        case .casual: strip = sentences <= 10 && isMessaging
        case .veryCasual: strip = true
        case .excited: strip = false
        }
        guard strip || (isMessaging && style != .formal && sentences <= 2) else { return text }
        var t = text
        let trailing = t.reversed().prefix(while: { $0 == " " })
        t.removeLast(trailing.count)
        while t.last == "." && !t.hasSuffix("...") { t.removeLast() }
        return t + String(trailing)
    }
}

// MARK: - Préférences apprises

public struct PreferenceContext: Sendable {
    public var appIdentities: Set<String>
    public var appCategory: String?
    public var language: String?
    /// dictation | generation
    public var mode: String

    public init(appIdentities: Set<String>, appCategory: String?, language: String?, mode: String) {
        self.appIdentities = appIdentities; self.appCategory = appCategory; self.language = language; self.mode = mode
    }
}

public enum PreferenceFilter {
    /// `filter` = "app:slack-mode:generation" ; chaque dimension présente doit correspondre ; nil = règle globale.
    public static func matches(_ filter: String?, _ ctx: PreferenceContext) -> Bool {
        guard let filter = filter?.trimmingCharacters(in: .whitespaces), !filter.isEmpty, filter.lowercased() != "null" else { return true }
        for part in filter.split(separator: "-") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2 else { continue }
            let (k, v) = (kv[0], kv[1])
            switch k {
            case "app":
                let compact = ctx.appIdentities.map { $0.replacingOccurrences(of: " ", with: "") }
                guard ctx.appIdentities.contains(v) || compact.contains(v.replacingOccurrences(of: " ", with: "")) else { return false }
            case "appcategory": guard ctx.appCategory?.lowercased() == v else { return false }
            case "language": guard let l = ctx.language?.lowercased(), l.hasPrefix(v) else { return false }
            case "mode": guard ctx.mode == v else { return false }
            default: continue
            }
        }
        return true
    }

    /// Bloc injecté dans le prompt.
    public static func block(_ prefs: [VoicePreference], _ ctx: PreferenceContext) -> String? {
        let lines = prefs.filter { $0.enabled && matches($0.filter, ctx) }.map { "- \($0.preference)" }
        guard !lines.isEmpty else { return nil }
        return "Préférences de l'utilisateur (à respecter quand elles s'appliquent) :\n" + lines.joined(separator: "\n")
    }
}
