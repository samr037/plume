import Foundation

/// Réunion détectée : une app de visio (ou un onglet de réunion) qui tient le micro.
public struct MeetingCandidate: Equatable, Hashable, Sendable {
    public var platform: MeetingPlatform
    public var appBundleID: String
    public var pid: pid_t
    public var appName: String
    public var url: String?
    public var title: String?

    public init(platform: MeetingPlatform, appBundleID: String, pid: pid_t, appName: String, url: String? = nil, title: String? = nil) {
        self.platform = platform; self.appBundleID = appBundleID; self.pid = pid
        self.appName = appName; self.url = url; self.title = title
    }
}

/// Décision pure (testable) : début après une prise continue du micro, fin après grâce + confirmations (rapport 10 §1.8).
public struct MeetingDetectionMachine: Equatable {
    public enum Output: Equatable {
        case started(MeetingCandidate)
        case ended(MeetingCandidate, reason: String)
    }

    /// Prise continue exigée avant de signaler la réunion.
    public var startHold: TimeInterval = 2
    /// Grâce après relâchement du micro, puis confirmations espacées (5 s et 2 sondages).
    public var endGrace: TimeInterval = 5
    public var endConfirmations = 2
    public var confirmInterval: TimeInterval = 1

    public private(set) var current: MeetingCandidate?
    private var pending: [String: TimeInterval] = [:]
    private var candidates: [MeetingCandidate] = []
    private var releasedAt: TimeInterval?
    private var confirmations = 0
    private var lastConfirmAt: TimeInterval = 0
    private var suppressed: [String: TimeInterval] = [:]

    public init() {}

    /// Nouvelle liste de candidats éligibles (déjà classés : apps de visio, onglets de réunion…).
    public mutating func update(_ candidates: [MeetingCandidate], now: TimeInterval) -> [Output] {
        self.candidates = candidates
        return tick(now: now)
    }

    /// À appeler régulièrement (~500 ms) : fait avancer les minuteries.
    public mutating func tick(now: TimeInterval) -> [Output] {
        suppressed = suppressed.filter { $0.value > now }
        if let cur = current { return trackEnd(cur, now: now) }
        return trackStart(now: now)
    }

    /// Ignore cette app pendant `duration` (carte refusée) ; une réunion en cours sur cette app est oubliée sans `ended`.
    public mutating func suppress(bundleID: String, until: TimeInterval) {
        suppressed[bundleID] = until
        pending[bundleID] = nil
        if current?.appBundleID == bundleID { current = nil; releasedAt = nil }
    }

    public mutating func reset() {
        current = nil; pending = [:]; candidates = []; releasedAt = nil; confirmations = 0
    }

    private mutating func trackStart(now: TimeInterval) -> [Output] {
        let eligible = candidates.filter { suppressed[$0.appBundleID] == nil }
        let keys = Set(eligible.map(\.appBundleID))
        pending = pending.filter { keys.contains($0.key) }
        for c in eligible where pending[c.appBundleID] == nil { pending[c.appBundleID] = now }
        // Le plus ancien gagne ; à égalité, une app de visio native passe devant un navigateur.
        let ready = eligible.filter { now - pending[$0.appBundleID]! >= startHold }
            .min { (pending[$0.appBundleID]!, $0.platform.isConferenceApp ? 0 : 1) < (pending[$1.appBundleID]!, $1.platform.isConferenceApp ? 0 : 1) }
        guard let start = ready else { return [] }
        current = start
        pending = [:]; releasedAt = nil; confirmations = 0
        return [.started(start)]
    }

    private mutating func trackEnd(_ cur: MeetingCandidate, now: TimeInterval) -> [Output] {
        if let same = candidates.first(where: { $0.appBundleID == cur.appBundleID }) {
            // Toujours tenu : on garde les infos les plus fraîches (URL, titre).
            current = MeetingCandidate(platform: cur.platform, appBundleID: cur.appBundleID, pid: same.pid, appName: same.appName,
                                       url: same.url ?? cur.url, title: same.title ?? cur.title)
            releasedAt = nil; confirmations = 0
            return []
        }
        guard let rel = releasedAt else {
            releasedAt = now; confirmations = 0
            return []
        }
        guard now - rel >= endGrace else { return [] }
        if confirmations == 0 || now - lastConfirmAt >= confirmInterval {
            confirmations += 1
            lastConfirmAt = now
        }
        guard confirmations >= endConfirmations else { return [] }
        current = nil; releasedAt = nil; confirmations = 0
        return [.ended(cur, reason: "mic_released")]
    }
}

/// Détection de réunion : détenteurs du micro + catalogue + onglet navigateur. Callbacks sur le main thread.
public final class MeetingDetector {
    public var onMeetingStarted: ((MeetingCandidate) -> Void)?
    public var onMeetingEnded: ((MeetingCandidate, String) -> Void)?
    /// Détenteurs bruts et classement, pour le debug (main thread).
    public var onHoldersObserved: (([MicHolder], [MeetingCandidate]) -> Void)?

    public var currentCandidate: MeetingCandidate? { machine.current }

    private let monitor: MicHolderMonitor
    private let clock: () -> TimeInterval
    private var machine = MeetingDetectionMachine()
    private var timer: Timer?
    private var holders: [MicHolder] = []
    private let axQueue = DispatchQueue(label: "wl.meeting-ax", qos: .utility)
    /// Classement AX des navigateurs/Slack par PID d'app : (candidat éventuel, date de lecture).
    private var axCache: [pid_t: (MeetingCandidate?, TimeInterval)] = [:]
    private var axInFlight: Set<pid_t> = []
    private let axRefresh: TimeInterval = 2

    public init(monitor: MicHolderMonitor = MicHolderMonitor(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.monitor = monitor
        self.clock = clock
    }

    public func start() {
        guard timer == nil else { return }
        monitor.onChange = { [weak self] in self?.holders = $0; self?.evaluate() }
        monitor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        monitor.stop()
        machine.reset(); axCache.removeAll()
        // Liste périmée : au redémarrage, le moniteur ne republie que sur changement.
        holders = []
    }

    /// Ne plus signaler cette app pendant `duration` (l'utilisateur a refusé la carte).
    public func suppress(bundleID: String, for duration: TimeInterval) {
        machine.suppress(bundleID: bundleID, until: clock() + duration)
    }

    private func evaluate() {
        let now = clock()
        let cands = classify(holders, now: now)
        onHoldersObserved?(holders, cands)
        for out in machine.update(cands, now: now) {
            switch out {
            case .started(let c): onMeetingStarted?(c)
            case .ended(let c, let reason): onMeetingEnded?(c, reason)
            }
        }
    }

    /// Une entrée par app : apps de visio directement, navigateurs et Slack seulement avec une preuve AX (URL/titre).
    private func classify(_ holders: [MicHolder], now: TimeInterval) -> [MeetingCandidate] {
        var seen = Set<String>()
        var out: [MeetingCandidate] = []
        for h in holders where seen.insert(h.appBundleID).inserted {
            guard let platform = MeetingCatalog.platform(forBundleID: h.appBundleID) ?? MeetingCatalog.platform(forBundleID: h.bundleID) else { continue }
            if platform.isConferenceApp {
                out.append(MeetingCandidate(platform: platform, appBundleID: h.appBundleID, pid: h.appPID, appName: h.appName))
                continue
            }
            let cached = axCache[h.appPID]
            if let cand = cached?.0 {
                out.append(cand)
            } else if let cur = machine.current, cur.appBundleID == h.appBundleID {
                // Réunion déjà suivie : seul le relâchement du micro la termine (changer d'onglet ne suffit pas).
                out.append(cur)
            }
            if let at = cached?.1, now - at < axRefresh { continue }
            refreshAX(h, platform: platform)
        }
        axCache = axCache.filter { pid, _ in holders.contains { $0.appPID == pid } }
        return out
    }

    private func refreshAX(_ h: MicHolder, platform: MeetingPlatform) {
        guard axInFlight.insert(h.appPID).inserted else { return }
        axQueue.async { [weak self] in
            let cand = Self.axCandidate(h, platform: platform)
            DispatchQueue.main.async {
                guard let self else { return }
                self.axInFlight.remove(h.appPID)
                self.axCache[h.appPID] = (cand, self.clock())
            }
        }
    }

    /// Hors main thread : lit l'onglet actif / les titres pour décider si le navigateur (ou Slack) est en réunion.
    static func axCandidate(_ h: MicHolder, platform: MeetingPlatform) -> MeetingCandidate? {
        let base = MeetingCandidate(platform: platform, appBundleID: h.appBundleID, pid: h.appPID, appName: h.appName)
        if platform == .slack {
            guard let t = BrowserTabReader.windowTitles(pid: h.appPID).first(where: MeetingCatalog.isSlackHuddleTitle) else { return nil }
            var c = base; c.title = t
            return c
        }
        let tab = BrowserTabReader.activeTab(pid: h.appPID)
        if let p = tab.url.flatMap(MeetingCatalog.platform(forURL:)) ?? tab.title.flatMap(MeetingCatalog.platform(forTitle:)) {
            var c = base; c.platform = p; c.url = tab.url; c.title = tab.title
            return c
        }
        // L'onglet de réunion n'est pas forcément l'onglet actif : on scanne la barre d'onglets.
        let titles = BrowserTabReader.meetingTabTitles(pid: h.appPID)
        if let t = titles.first(where: { MeetingCatalog.platform(forTitle: $0) != nil }) ?? titles.first {
            var c = base; c.platform = MeetingCatalog.platform(forTitle: t) ?? .browser; c.title = t
            return c
        }
        return nil
    }
}
