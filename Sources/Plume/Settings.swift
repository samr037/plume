import Foundation
import PlumeCore

/// Réglages persistés dans UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// Langues parlées (codes Whisper). Vide = détection libre parmi les 99 langues.
    @Published var languages: [String] { didSet { d.set(languages, forKey: "languages") } }
    @Published var cleanupLevel: CleanupLevel { didSet { d.set(cleanupLevel.rawValue, forKey: "cleanupLevel") } }
    @Published var whisperModel: String { didSet { d.set(whisperModel, forKey: "whisperModel") } }
    /// Moteur de dictée : parakeet | whisper. WL_ASR dans l'environnement l'emporte (banc de test).
    @Published var asrEngine: String { didSet { d.set(asrEngine, forKey: "asrEngine") } }
    @Published var llmEndpoint: String { didSet { d.set(llmEndpoint, forKey: "llmEndpoint") } }
    @Published var llmModelName: String { didSet { d.set(llmModelName, forKey: "llmModelName") } }
    @Published var autoStartLLM: Bool { didSet { d.set(autoStartLLM, forKey: "autoStartLLM") } }
    @Published var llmModelPath: String { didSet { d.set(llmModelPath, forKey: "llmModelPath") } }
    /// forever | 24h | never
    @Published var retention: String { didSet { d.set(retention, forKey: "retention") } }
    @Published var keepAudio: Bool { didSet { d.set(keepAudio, forKey: "keepAudio") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var useContext: Bool { didSet { d.set(useContext, forKey: "useContext") } }
    /// Réécritures rapides (⌃⌥1 … ⌃⌥9).
    @Published var transforms: [RewriteTransform] { didSet { d.set(try? JSONEncoder().encode(transforms), forKey: "transforms") } }
    /// Styles « My Voice » par app.
    @Published var voices: [UserVoice] { didSet { d.set(try? JSONEncoder().encode(voices), forKey: "voices") } }
    @Published var learnFromEdits: Bool { didSet { d.set(learnFromEdits, forKey: "learnFromEdits") } }
    /// Endpoint/modèle pour Instruct (vide = même que le formatteur).
    @Published var instructEndpoint: String { didSet { d.set(instructEndpoint, forKey: "instructEndpoint") } }
    @Published var muteWhileDictating: Bool { didSet { d.set(muteWhileDictating, forKey: "muteWhileDictating") } }
    @Published var autoDetectMeetings: Bool { didSet { d.set(autoDetectMeetings, forKey: "autoDetectMeetings") } }
    @Published var autoStartMeetings: Bool { didSet { d.set(autoStartMeetings, forKey: "autoStartMeetings") } }
    @Published var autoEndMeetings: Bool { didSet { d.set(autoEndMeetings, forKey: "autoEndMeetings") } }
    @Published var meetingMaxHours: Double { didSet { d.set(meetingMaxHours, forKey: "meetingMaxHours") } }
    /// Barre flottante visible même au repos (« Show Flow Bar at all times »).
    @Published var showFlowBar: Bool { didSet { d.set(showFlowBar, forKey: "showFlowBar") } }
    /// Bord d'écran où la barre est aimantée : bottom | top | left | right.
    @Published var flowBarEdge: String { didSet { d.set(flowBarEdge, forKey: "flowBarEdge") } }
    /// Position le long du bord, de 0 (gauche ou bas) à 1 (droite ou haut).
    @Published var flowBarPosition: Double { didSet { d.set(flowBarPosition, forKey: "flowBarPosition") } }

    private init() {
        d.register(defaults: [
            "language": "auto",
            "cleanupLevel": CleanupLevel.light.rawValue,
            "whisperModel": "large-v3-v20240930_turbo",
            "asrEngine": "parakeet",
            "llmEndpoint": "http://127.0.0.1:8081",
            "llmModelName": "local",
            "autoStartLLM": true,
            "llmModelPath": ModelFiles.defaultLLMPath,
            "retention": "forever",
            "keepAudio": false,
            "playSounds": true,
            "useContext": true,
            "learnFromEdits": true,
            "instructEndpoint": "",
            "muteWhileDictating": false,
            "autoDetectMeetings": true,
            "autoStartMeetings": false,
            "autoEndMeetings": true,
            "meetingMaxHours": 2.0,
            "showFlowBar": true,
            "flowBarEdge": "bottom",
            "flowBarPosition": 0.5,
        ])
        if let l = d.stringArray(forKey: "languages") {
            languages = l
        } else {
            // Migration de l'ancien réglage à une langue.
            let old = d.string(forKey: "language") ?? "auto"
            languages = old == "auto" ? ["fr", "en"] : [old]
        }
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: "cleanupLevel")!) ?? .medium
        whisperModel = d.string(forKey: "whisperModel")!
        asrEngine = ProcessInfo.processInfo.environment["WL_ASR"] ?? d.string(forKey: "asrEngine")!
        llmEndpoint = d.string(forKey: "llmEndpoint")!
        llmModelName = d.string(forKey: "llmModelName")!
        autoStartLLM = d.bool(forKey: "autoStartLLM")
        llmModelPath = d.string(forKey: "llmModelPath")!
        retention = d.string(forKey: "retention")!
        keepAudio = d.bool(forKey: "keepAudio")
        playSounds = d.bool(forKey: "playSounds")
        useContext = d.bool(forKey: "useContext")
        learnFromEdits = d.bool(forKey: "learnFromEdits")
        instructEndpoint = d.string(forKey: "instructEndpoint")!
        muteWhileDictating = d.bool(forKey: "muteWhileDictating")
        autoDetectMeetings = d.bool(forKey: "autoDetectMeetings")
        autoStartMeetings = d.bool(forKey: "autoStartMeetings")
        autoEndMeetings = d.bool(forKey: "autoEndMeetings")
        meetingMaxHours = d.double(forKey: "meetingMaxHours")
        showFlowBar = d.bool(forKey: "showFlowBar")
        flowBarEdge = d.string(forKey: "flowBarEdge")!
        flowBarPosition = d.double(forKey: "flowBarPosition")
        if let data = d.data(forKey: "transforms"), let t = try? JSONDecoder().decode([RewriteTransform].self, from: data) {
            transforms = t
        } else {
            transforms = RewriteTransform.defaults
        }
        if let data = d.data(forKey: "voices"), let v = try? JSONDecoder().decode([UserVoice].self, from: data), !v.isEmpty {
            voices = v
        } else {
            // Migration : le niveau global devient celui de chaque voix intégrée.
            let level = CleanupLevel(rawValue: d.string(forKey: "cleanupLevel")!) ?? .light
            voices = VoiceResolver.defaults.map { var v = $0; v.cleanupLevel = level; return v }
        }
    }

    /// Langues proposées dans les réglages (codes Whisper), dans l'ordre d'affichage.
    static let languageChoices: [(code: String, name: String)] = [
        ("fr", "Français"), ("en", "Anglais"), ("de", "Allemand"), ("es", "Espagnol"), ("it", "Italien"), ("pt", "Portugais"),
        ("nl", "Néerlandais"), ("pl", "Polonais"), ("ar", "Arabe"), ("zh", "Chinois"), ("ja", "Japonais"), ("ru", "Russe"),
    ]

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plume", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

