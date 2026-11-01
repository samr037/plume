import AppKit
import EventKit
import FluidAudio
import MeetingKit
import SwiftUI
import PlumeCore

/// Réunions : détection par détenteur du micro, carte « Réunion détectée »,
/// capture micro + son système, transcription live par segments VAD, fin automatique, compte rendu par le LLM local.
@MainActor
final class MeetingController {
    let settings = AppSettings.shared
    let state: AppState
    let store: Store
    let transcriber: Transcriber
    let vad: VoiceActivity
    let llm: () -> LLMClient

    private let detector = MeetingDetector()
    private let calendar = CalendarService()
    private lazy var card = MeetingCardController(
        onRecord: { [weak self] in self?.startFromCard() },
        onDismiss: { [weak self] in self?.dismissCard() },
        onStop: { [weak self] in self?.stop(reason: "user") })

    private var capture: MeetingAudioCapture?
    private var pending: MeetingCandidate?
    private var countdownTimer: Timer?
    private(set) var current: Meeting?
    private var tracked: MeetingCandidate?
    private var live: LiveMeetingTranscriber?
    private var tick: Timer?
    private var dismissals = 0
    /// Comptes rendus en cours, par réunion (régénération pendant la rédaction post-arrêt, reprise au lancement…).
    private var summarizing: Set<Int64> = []

    var isRecording: Bool { current != nil }
    var onRecordingChanged: ((Bool) -> Void)?

    init(state: AppState, store: Store, transcriber: Transcriber, vad: VoiceActivity, llm: @escaping () -> LLMClient) {
        self.state = state
        self.store = store
        self.transcriber = transcriber
        self.vad = vad
        self.llm = llm
        detector.onMeetingStarted = { [weak self] c in Task { @MainActor in self?.detected(c) } }
        detector.onMeetingEnded = { [weak self] c, reason in Task { @MainActor in self?.detectorEnded(c, reason: reason) } }
    }

    func startDetection() {
        recoverOrphans()
        guard settings.autoDetectMeetings else { return }
        detector.start()
        Log.write("Détection des réunions active")
    }

    func setDetection(_ on: Bool) {
        if on { detector.start(); return }
        detector.stop()
        // Carte « Réunion détectée » en attente : elle ne serait jamais close (plus de fin de détection).
        if pending != nil {
            pending = nil
            countdownTimer?.invalidate(); countdownTimer = nil
            card.hide()
        }
    }

    // MARK: Détection

    private func detected(_ c: MeetingCandidate) {
        guard current == nil, pending == nil else { return }
        Log.write("Réunion détectée : \(c.platform.displayName) (\(c.appName))")
        pending = c
        let event = calendar.currentEvent()
        let title = event?.title ?? c.platform.displayName
        if settings.autoStartMeetings {
            var remaining = 10
            card.showDetected(title: title, app: c.appName, countdown: remaining)
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    remaining -= 1
                    if remaining <= 0 { t.invalidate(); self.startFromCard() } else { self.card.showDetected(title: title, app: c.appName, countdown: remaining) }
                }
            }
        } else {
            card.showDetected(title: title, app: c.appName, countdown: nil)
            if settings.playSounds { NSSound(named: "Glass")?.play() }
        }
    }

    private func dismissCard() {
        countdownTimer?.invalidate()
        if let p = pending { detector.suppress(bundleID: p.appBundleID, for: 3 * 3600) }
        pending = nil
        card.hide()
        dismissals += 1
    }

    private func startFromCard() {
        countdownTimer?.invalidate()
        guard let c = pending else { return }
        pending = nil
        start(candidate: c)
    }

    private func detectorEnded(_ c: MeetingCandidate, reason: String) {
        // Même app (URL et titre se rafraîchissent pendant l'appel : pas d'égalité stricte).
        if let p = pending, p.appBundleID == c.appBundleID { pending = nil; countdownTimer?.invalidate(); card.hide(); return }
        guard settings.autoEndMeetings, let t = tracked, t.appBundleID == c.appBundleID else { return }
        stop(reason: reason)
    }

    // MARK: Enregistrement

    /// Démarre une réunion (détectée, ou manuelle si `candidate` est nil : capture système globale).
    func start(candidate: MeetingCandidate?) {
        guard current == nil else { return }
        let event = calendar.currentEvent()
        var m = Meeting(title: event?.title ?? candidate.map { "Réunion \($0.platform.displayName)" } ?? "Réunion",
                        platform: candidate?.platform.rawValue, appBundleID: candidate?.appBundleID, url: candidate?.url,
                        calendarEventID: event?.eventIdentifier, calendarTitle: event?.title,
                        attendees: event.map { CalendarService.attendeeNames($0) })
        guard let id = try? store.insert(m) else { return }
        m.id = id
        let dir = AppSettings.supportDirectory.appendingPathComponent("meetings/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        m.audioDir = dir.path
        try? store.update(m)

        let cap = MeetingAudioCapture(directory: dir)
        // Biais de vocabulaire : dictionnaire + titre et participants du calendrier.
        let lexicon = (try? store.lexicon()) ?? []
        var terms = DictationController.vocabulary(from: lexicon)
        if let a = m.attendees { terms.insert(contentsOf: a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, at: 0) }
        let live = LiveMeetingTranscriber(meetingID: id, store: store, transcriber: transcriber, vad: vad,
                                          languages: settings.languages, prompt: WhisperPrompt.build(terms: terms)) { [weak self] in
            self?.state.meetingsVersion += 1
        }
        cap.onMicSamples = { [weak live] s in live?.append(s, channel: .mic) }
        cap.onSystemSamples = { [weak live] s in live?.append(s, channel: .system) }
        cap.onLevels = { [weak self] mic, sys in self?.card.levels(mic: mic, system: sys) }
        cap.onEvent = { Log.write("Réunion #\(id) : \($0)") }
        do {
            try cap.start(targetPIDs: candidate.map { [$0.pid] } ?? [])
        } catch {
            Log.write("Capture réunion impossible : \(error.localizedDescription)")
            card.showMessage("Capture impossible : \(error.localizedDescription)")
            m.status = "error"; m.endReason = "capture_error"; m.endedAt = Date()
            try? store.update(m)
            return
        }
        capture = cap
        self.live = live
        current = m
        tracked = candidate
        live.start()
        card.showRecording(title: m.title, startedAt: m.startedAt)
        onRecordingChanged?(true)
        state.meetingsVersion += 1
        Log.write("Réunion #\(id) : enregistrement (\(cap.isPerProcessTap ? "tap ciblé" : "tap global"))")

        // Fin automatique : silence 10 min, durée max, fin du créneau calendrier + 10 min.
        let maxDuration = settings.meetingMaxHours * 3600
        let calendarEnd = event?.endDate
        tick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.current, let live = self.live else { return }
                let elapsed = Date().timeIntervalSince(m.startedAt)
                if elapsed >= maxDuration { self.stop(reason: "max_duration") }
                else if self.settings.autoEndMeetings, elapsed > 120, Date().timeIntervalSince(live.lastSpeechAt) > 600 { self.stop(reason: "silence") }
                else if self.settings.autoEndMeetings, let end = calendarEnd, Date() > end.addingTimeInterval(600),
                        Date().timeIntervalSince(live.lastSpeechAt) > 60 { self.stop(reason: "calendar_end") }
            }
        }
    }

    func stop(reason: String) {
        guard var m = current else { return }
        tick?.invalidate()
        capture?.stop()
        capture = nil
        current = nil
        tracked = nil
        onRecordingChanged?(false)
        m.endedAt = Date()
        m.endReason = reason
        m.status = "processing"
        try? store.update(m)
        card.showMessage("Réunion terminée — rédaction des notes…")
        Log.write("Réunion #\(m.id) terminée (\(reason)), \(Int(m.duration / 60)) min")
        let live = self.live
        self.live = nil
        Task {
            await live?.finish()
            await summarize(meetingID: m.id)
        }
    }

    /// Fermeture de l'app : clôt la réunion en cours (transcription des derniers segments, fichiers audio fermés)
    /// sans rédiger le compte rendu, qui sera produit au prochain lancement par `recoverOrphans`.
    func shutdown() async {
        countdownTimer?.invalidate(); countdownTimer = nil
        pending = nil
        guard var m = current else { return }
        tick?.invalidate()
        capture?.stop()
        capture = nil
        current = nil
        tracked = nil
        onRecordingChanged?(false)
        m.endedAt = Date()
        m.endReason = "quit"
        m.status = "processing"
        try? store.update(m)
        Log.write("Réunion #\(m.id) interrompue (fermeture de l'app), \(Int(m.duration / 60)) min ; notes au prochain lancement")
        let live = self.live
        self.live = nil
        await live?.finish()
    }

    // MARK: Compte rendu

    /// Sépare les interlocuteurs du son système : chaque segment « them » devient « them:N » s'il y en a plusieurs.
    func diarize(_ m: Meeting) async {
        guard let dir = m.audioDir else { return }
        let segments = (try? store.segments(meetingID: m.id)) ?? []
        guard segments.contains(where: { $0.speaker == "them" }) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("system.f32")
        // Lecture hors du main actor (jusqu'à ~1,4 Go pour 6 h).
        let audio = await Task.detached(priority: .utility) { MeetingAudioCapture.readPCM(url: url) }.value
        guard audio.count > 16_000 * 10 else { return }
        let t0 = Date()
        do {
            // Diarisation hors ligne : segmentation pyannote, empreintes WeSpeaker, regroupement VBx.
            // Pas de plafond tiré des invités : listes de diffusion, salles et invités en plus le rendent faux
            // (trop bas, il fusionne des voix distinctes) ; VBx estime le nombre d'interlocuteurs.
            let config = OfflineDiarizerConfig()
            let diarizer = OfflineDiarizerManager(config: config)
            try await diarizer.prepareModels()
            let result = try await diarizer.process(audio: audio)
            let turns = result.segments.map { (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            let map = SpeakerLabels.assign(segments: segments, turns: turns)
            try store.setSpeakers(map)
            let count = Set(map.values).count
            Log.write("Réunion #\(m.id) : \(count > 1 ? "\(count) interlocuteurs" : "un seul interlocuteur") (diarisation \(Int(Date().timeIntervalSince(t0))) s)")
        } catch {
            Log.write("Diarisation impossible : \(error.localizedDescription)")
        }
    }

    func summarize(meetingID: Int64) async {
        guard current?.id != meetingID, !summarizing.contains(meetingID) else { return }
        summarizing.insert(meetingID)
        defer { summarizing.remove(meetingID) }
        guard var m = try? store.meeting(id: meetingID) else { return }
        await diarize(m)
        let segments = (try? store.segments(meetingID: meetingID)) ?? []
        guard !segments.isEmpty else {
            m.status = "complete"; m.summary = "_Aucune parole transcrite._"
            try? store.update(m); state.meetingsVersion += 1; card.hide()
            return
        }
        let transcript = MeetingTranscript.render(segments)
        let client = llm()
        do {
            // Map-reduce au-delà de ~8 000 caractères (contexte de 16k tokens côté llama-server).
            var material = transcript
            let chunks = MeetingTranscript.chunks(transcript)
            if chunks.count > 1 {
                var notes: [String] = []
                for (i, c) in chunks.enumerated() {
                    let r = try await client.chat(messages: [["role": "system", "content": MeetingPrompts.notesSystem],
                                                             ["role": "user", "content": "Extrait \(i + 1)/\(chunks.count) :\n\(c)"]],
                                                  maxTokens: 900, timeout: 120)
                    notes.append(r.content)
                }
                material = "Notes intermédiaires de la réunion, dans l'ordre :\n\n" + notes.joined(separator: "\n\n")
            }
            var header = "Durée : \(Int(m.duration / 60)) min."
            if let t = m.calendarTitle { header += " Événement calendrier : \(t)." }
            if let a = m.attendees, !a.isEmpty { header += " Participants invités : \(a)." }
            let o = try await client.json(system: MeetingPrompts.summarySystem, user: header + "\n\n" + material,
                                          schema: MeetingPrompts.summarySchema, maxTokens: 2000)
            // Relecture : la réunion a pu être modifiée (notes, titre) pendant la rédaction.
            if let fresh = try? store.meeting(id: meetingID) { m = fresh }
            if m.calendarTitle == nil, let t = o["title"] as? String, !t.isEmpty { m.title = t }
            m.summary = o["summary"] as? String ?? ""
            m.followUpEmail = o["follow_up_email"] as? String ?? ""
            // Régénération : on remplace les tâches encore ouvertes et on ne recrée pas celles déjà faites.
            let previous = (try? store.todos(meetingID: m.id)) ?? []
            for t in previous where !t.done { try? store.deleteTodo(id: t.id) }
            let done = Set(previous.filter(\.done).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            var seen = Set<String>()
            for item in (o["action_items"] as? [String] ?? []) {
                let key = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, !done.contains(key), seen.insert(key).inserted else { continue }
                try? store.insert(Todo(meetingID: m.id, text: item))
            }
            m.status = "complete"
            card.showMessage("Notes prêtes : \(m.title)", autoHide: 6)
        } catch {
            if let fresh = try? store.meeting(id: meetingID) { m = fresh }
            m.status = "error"
            m.summary = "_Compte rendu impossible : \(error.localizedDescription)_"
            card.showMessage("Compte rendu impossible (LLM)", autoHide: 6)
        }
        try? store.update(m)
        state.meetingsVersion += 1
    }

    /// Réunions restées « recording » après un crash, ou « processing » après une fermeture en cours de réunion :
    /// on les clôt et on rédige les notes avec ce qui a été transcrit.
    private func recoverOrphans() {
        for var m in (try? store.orphanMeetings()) ?? [] {
            if m.status == "recording" {
                m.endedAt = m.endedAt ?? recoveredEnd(m)
                m.endReason = "crash"; m.status = "processing"; try? store.update(m)
            }
            let id = m.id
            Task { await summarize(meetingID: id) }
        }
    }

    /// Fin estimée d'une réunion interrompue : dernier segment transcrit ou durée de l'audio sur disque
    /// (16 kHz mono float32 = 64 000 octets/s), jamais l'heure de relance.
    private func recoveredEnd(_ m: Meeting) -> Date {
        var seconds = ((try? store.segments(meetingID: m.id)) ?? []).map(\.end).max() ?? 0
        if let dir = m.audioDir {
            for name in ["system.f32", "mic.f32"] {
                let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                    seconds = max(seconds, size.doubleValue / 64_000)
                }
            }
        }
        return m.startedAt.addingTimeInterval(seconds)
    }
}

// MARK: - Transcription live par canal

/// Bufferise chaque canal, découpe par Silero VAD toutes les 3 s, transcrit les segments terminés.
final class LiveMeetingTranscriber {
    enum Channel { case mic, system }

    private final class Buffer {
        var samples: [Float] = []
        var offset: Double = 0 // position (s) du 1er échantillon depuis le début de la réunion
    }

    let meetingID: Int64
    let store: Store
    let transcriber: Transcriber
    let vad: VoiceActivity
    let languages: [String]
    let prompt: String?
    let onUpdate: @MainActor () -> Void
    private let lock = NSLock()
    private let mic = Buffer(), system = Buffer()
    private var loop: Task<Void, Never>?
    private var recentSystem: [MeetingSegment] = []
    /// Historique du son système (120 s) pour l'anti-écho par corrélation d'enveloppes.
    private var systemHistory: [Float] = []
    private var systemHistoryStart = 0.0
    private var _lastSpeechAt = Date()
    /// Lu par le minuteur du main actor, écrit par `process` : protégé par le verrou.
    var lastSpeechAt: Date {
        get { lock.lock(); defer { lock.unlock() }; return _lastSpeechAt }
        set { lock.lock(); _lastSpeechAt = newValue; lock.unlock() }
    }

    init(meetingID: Int64, store: Store, transcriber: Transcriber, vad: VoiceActivity, languages: [String], prompt: String?,
         onUpdate: @escaping @MainActor () -> Void) {
        self.meetingID = meetingID; self.store = store; self.transcriber = transcriber; self.vad = vad
        self.languages = languages; self.prompt = prompt; self.onUpdate = onUpdate
    }

    func append(_ s: [Float], channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        (channel == .mic ? mic : system).samples.append(contentsOf: s)
        if channel == .system {
            systemHistory.append(contentsOf: s)
            let excess = systemHistory.count - 120 * 16_000
            if excess > 16_000 { systemHistory.removeFirst(excess); systemHistoryStart += Double(excess) / 16_000 }
        }
    }

    /// Son système sur [start-1,5 s, end+1,5 s] (horloge de la réunion), pour comparer à un segment micro.
    private func systemAudio(from start: Double, to end: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let a = max(0, Int((start - 1.5 - systemHistoryStart) * 16_000))
        let b = min(systemHistory.count, Int((end + 1.5 - systemHistoryStart) * 16_000))
        return b > a ? Array(systemHistory[a ..< b]) : []
    }

    func start() {
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                guard !Task.isCancelled, let self else { break }
                // Tâche non annulable : une passe commencée va au bout (segments transcrits puis consommés),
                // `finish()` l'attend avant la passe finale.
                await Task.detached(priority: .utility) { await self.process(final: false) }.value
            }
        }
    }

    /// Arrête la boucle, attend la passe en cours, puis transcrit tout ce qui reste. Les passes ne se chevauchent jamais.
    func finish() async {
        let l = loop
        loop = nil
        l?.cancel()
        await l?.value
        await process(final: true)
    }

    private func snapshot(_ b: Buffer) -> ([Float], Double) {
        lock.lock(); defer { lock.unlock() }
        return (b.samples, b.offset)
    }

    private func consume(_ b: Buffer, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let n = min(b.samples.count, Int(seconds * 16_000))
        b.samples.removeFirst(n)
        b.offset += Double(n) / 16_000
    }

    private func process(final: Bool) async {
        // Système d'abord : l'anti-écho du micro compare aux segments système récents.
        for (channel, buffer) in [(Channel.system, system), (.mic, mic)] {
            let (samples, offset) = snapshot(buffer)
            let duration = Double(samples.count) / 16_000
            guard duration >= (final ? 0.3 : 2) else { continue }
            let segments = await vad.segments(samples, maxSpeech: 25)
            if segments.isEmpty {
                // Pas de parole : on jette tout sauf la dernière seconde (début possible d'un mot).
                if duration > 5 || final { consume(buffer, seconds: final ? duration : duration - 1) }
                continue
            }
            lastSpeechAt = Date()
            var consumed = 0.0
            for seg in segments {
                let complete = final || seg.end < duration - 0.8 || seg.end - seg.start >= 24
                guard complete else { break }
                let a = max(0, Int(seg.start * 16_000)), z = min(samples.count, Int(seg.end * 16_000))
                consumed = seg.end
                guard z - a > 4_800 else { continue } // < 0,3 s
                if channel == .mic {
                    // Anti-écho acoustique : le micro ne fait que reprendre les haut-parleurs.
                    let sys = systemAudio(from: offset + seg.start, to: offset + seg.end)
                    let micAudio = Array(samples[a ..< z])
                    if sys.count > 16_000, EchoGate.envelopeCorrelation(mic: micAudio, system: sys, maxLag: 300) > 0.6 {
                        continue // sys couvre ±1,5 s autour du segment : on cherche le décalage sur ±3 s
                    }
                }
                guard let r = try? await transcriber.transcribe(Array(samples[a ..< z]), languages: languages, prompt: prompt),
                      !HallucinationFilter.isPhantom(r.text, speechSeconds: seg.end - seg.start),
                      !WhisperPrompt.isEcho(output: r.text, prompt: prompt) else { continue }
                var s = MeetingSegment(meetingID: meetingID, speaker: channel == .mic ? "me" : "them",
                                       start: offset + seg.start, end: offset + seg.end, text: r.text)
                if channel == .mic, EchoGate.isEcho(mic: s, system: recentSystem) { continue }
                if channel == .system {
                    recentSystem.append(s)
                    recentSystem.removeAll { $0.end < s.start - 60 }
                }
                s.id = (try? store.insert(s)) ?? 0
                await onUpdate()
            }
            if consumed > 0 { consume(buffer, seconds: min(consumed, duration)) }
            else if duration > 30 { consume(buffer, seconds: duration - 25) } // garde-fou
        }
    }
}

// MARK: - Calendrier (EventKit, comptes système : iCloud, Google, Exchange)

final class CalendarService {
    private let store = EKEventStore()
    private var authorized = false
    private var requested = false

    func requestAccess() {
        guard !requested else { return }
        requested = true
        store.requestFullAccessToEvents { [weak self] granted, _ in self?.authorized = granted }
    }

    /// Événement en cours (ou commençant dans 5 min), ignorant les journées entières.
    func currentEvent() -> EKEvent? {
        if !authorized {
            authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            if !authorized { requestAccess(); return nil }
        }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(300), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(300) && $0.endDate >= now }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    static func attendeeNames(_ e: EKEvent) -> String {
        // Personnes uniquement (pas de salles ni de groupes) ; « Nom, Prénom » d'Exchange : la virgule sert de séparateur.
        (e.attendees ?? []).filter { $0.participantType == .person || $0.participantType == .unknown }
            .compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
            .map { $0.replacingOccurrences(of: ",", with: " ").split(separator: " ").joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Carte flottante (détection, enregistrement en cours, messages)

final class MeetingCardModel: ObservableObject {
    enum Phase: Equatable { case hidden, detected(title: String, app: String, countdown: Int?), recording(title: String, startedAt: Date), message(String) }
    @Published var phase: Phase = .hidden
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var visible = false
}

/// Pendant l'enregistrement : une pastille compacte (point rouge, minuteur, niveaux, arrêt).
/// Détection et messages : une petite carte. Les deux se déplacent en les faisant glisser.
struct MeetingCardView: View {
    @ObservedObject var model: MeetingCardModel
    var onRecord: () -> Void
    var onDismiss: () -> Void
    var onStop: () -> Void
    var onDragChanged: () -> Void
    var onDragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .tint(Theme.accent)
            .foregroundStyle(Theme.text)
            .fixedSize()
            .contentShape(Rectangle())
            // Glisser n'importe où sur la carte la déplace ; les boutons gardent leurs clics (seuil de 3 points).
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() })
            .offset(y: model.visible || reduceMotion ? 0 : -12)
            .opacity(model.visible ? 1 : 0)
            .padding(10) // place pour l'ombre
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let title, let startedAt):
            HStack(spacing: 9) {
                RecDot()
                Text(startedAt, style: .timer)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52, alignment: .leading)
                HStack(spacing: 3) {
                    MiniMeter(level: model.micLevel)
                    MiniMeter(level: model.systemLevel)
                }
                .help("Micro · son de l'appel")
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.red.opacity(0.16)))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Arrêter l'enregistrement")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.cardStroke))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .help(title)
        case .detected(let title, let app, let countdown):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.wave.2").foregroundStyle(Theme.accent)
                    Text("Réunion détectée").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Ignorer")
                }
                Text("\(title) · \(app)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Button(action: onRecord) {
                    Label(countdown.map { String(localized: "Enregistrer (\($0) s)") } ?? String(localized: "Prendre des notes"),
                          systemImage: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        // Style plein dessiné à la main : un panneau non activant n'est jamais « clé »,
                        // et .borderedProminent y perd sa couleur.
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(width: 250, alignment: .leading)
            .modifier(CardBackground())
        case .message(let text):
            Label(text, systemImage: "doc.text").font(.system(size: 12)).lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: 280, alignment: .leading)
                .modifier(CardBackground())
        }
    }
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

/// Point rouge qui respire doucement (fixe si « Réduire les animations »).
/// TimelineView plutôt que @State : les Command Line Tools n'ont pas le plugin des macros SwiftUI.
private struct RecDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle().fill(.red).frame(width: 8, height: 8)
                .opacity(reduceMotion ? 1 : 0.65 + 0.35 * cos(t * 3.4))
        }
    }
}

private struct MiniMeter: View {
    var level: Float
    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(Theme.accent).frame(height: max(2, 16 * CGFloat(min(max(level, 0), 1))))
        }
        .frame(width: 3, height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

@MainActor
final class MeetingCardController {
    let model = MeetingCardModel()
    private let panel: NSPanel
    private let host: NSHostingView<MeetingCardView>
    private var hideWork: DispatchWorkItem?
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    /// Coin haut-droit de la carte, mémorisé après un glisser (sinon : en haut à droite de l'écran).
    private static let anchorKey = "meetingCardAnchor"

    init(onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void, onStop: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Invisible dans les partages d'écran.
        panel.sharingType = .none
        var dragChanged: () -> Void = {}
        var dragEnded: () -> Void = {}
        host = NSHostingView(rootView: MeetingCardView(model: model, onRecord: onRecord, onDismiss: onDismiss, onStop: onStop,
                                                       onDragChanged: { dragChanged() }, onDragEnded: { dragEnded() }))
        host.sizingOptions = []
        panel.contentView = host
        dragChanged = { [weak self] in self?.dragMoved() }
        dragEnded = { [weak self] in self?.dragFinished() }
    }

    func showDetected(title: String, app: String, countdown: Int?) { show(.detected(title: title, app: app, countdown: countdown)) }
    func showRecording(title: String, startedAt: Date) { show(.recording(title: title, startedAt: startedAt)) }
    func showMessage(_ text: String, autoHide: TimeInterval = 4) { show(.message(text), autoHide: autoHide) }
    func hide() { show(.hidden) }

    func levels(mic: Float, system: Float) {
        model.micLevel = mic
        model.systemLevel = system
    }

    private func show(_ phase: MeetingCardModel.Phase, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        let wasHidden = model.phase == .hidden || !panel.isVisible
        let changed = model.phase != phase
        model.phase = phase
        guard phase != .hidden else { panel.orderOut(nil); model.visible = false; return }
        // Le panneau épouse la carte : aucune zone transparente qui capterait les clics autour.
        if changed || wasHidden { fitToContent() }
        panel.orderFrontRegardless()
        if wasHidden {
            DispatchQueue.main.async { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)) { self.model.visible = true } }
        }
        if let autoHide {
            let w = DispatchWorkItem { [weak self] in
                // Ne masque pas une carte « enregistrement » affichée entre-temps.
                if case .message = self?.model.phase { self?.show(.hidden) }
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: w)
        }
    }

    // MARK: Taille et position

    private var screen: NSScreen? {
        if panel.isVisible, let s = panel.screen { return s }
        return NSScreen.main
    }

    /// Ajuste le panneau à la carte en gardant le coin haut-droit fixe.
    private func fitToContent() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, let vf = screen?.visibleFrame else { return }
        var anchor = NSPoint(x: vf.maxX, y: vf.maxY)
        if let s = UserDefaults.standard.string(forKey: Self.anchorKey) {
            let p = NSPointFromString(s)
            if p != .zero { anchor = p }
        }
        var frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        frame = clamped(frame)
        panel.setFrame(frame, display: true)
    }

    /// Garde la carte entière dans l'écran qui la porte (ou le plus proche).
    private func clamped(_ f: NSRect) -> NSRect {
        let center = NSPoint(x: f.midX, y: f.midY)
        let s = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screen
        guard let vf = s?.visibleFrame else { return f }
        var r = f
        r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r
    }

    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if drag == nil { drag = (mouse, panel.frame.origin) }
        guard let d = drag else { return }
        panel.setFrameOrigin(NSPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
    }

    private func dragFinished() {
        guard drag != nil else { return }
        drag = nil
        var f = clamped(panel.frame)
        // Aimantation : à moins de 24 points d'un bord, la carte s'y colle.
        if let vf = panel.screen?.visibleFrame ?? screen?.visibleFrame {
            let snap: CGFloat = 24
            if f.minX - vf.minX < snap { f.origin.x = vf.minX }
            if vf.maxX - f.maxX < snap { f.origin.x = vf.maxX - f.width }
            if f.minY - vf.minY < snap { f.origin.y = vf.minY }
            if vf.maxY - f.maxY < snap { f.origin.y = vf.maxY - f.height }
        }
        panel.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.maxX, y: f.maxY)), forKey: Self.anchorKey)
    }
}
