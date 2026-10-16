import AppKit
import PlumeCore

/// Orchestration d'une dictée : capture → rognage → ASR → filtres → LLM → post-traitement → collage → historique.
@MainActor
final class DictationController {
    let settings = AppSettings.shared
    let state: AppState
    let store: Store
    let hotkeys = HotkeyService()
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let llmServer = LLMServerManager()
    let paster = Paster()
    let vad = VoiceActivity()
    let editObserver = EditObserver()
    lazy var panel = StatusPanelController(onCancel: { [weak self] in self?.hotkeys.send(.escape) },
                                           onStop: { [weak self] in self?.stopFromPanel() },
                                           onStart: { [weak self] in self?.hotkeys.startFromBar() })

    var onRecordingChanged: ((Bool) -> Void)?
    var onScratchpad: (() -> Void)?

    private var contextTask: Task<ContextReader.Result, Never>?
    private var tapToken = 0
    private var maxDurationWork: DispatchWorkItem?
    private var lastText: String?
    /// La prise en cours est une commande Instruct (⌃ maintenu à l'appui sur fn).
    private var instructMode = false
    /// Minutage des étapes de la dernière dictée (journal).
    private var stages: [String] = []
    private var stageT = Date()
    private var pastedAt: Date?
    /// Une dictée est en cours (enregistrement ou traitement) : la barre lui appartient.
    private var dictationBusy = false
    /// Incrémenté à chaque prise : une tâche longue (réécriture) sait si une dictée a démarré entre-temps.
    private var dictationSerial = 0
    /// Le démarrage de la prise a échoué : le message d'erreur ne doit pas être effacé par l'annulation qui suit.
    private var startFailed = false

    private enum EngineLoad: Equatable { case idle, loading, ready, failed(String) }
    private var whisperLoad = EngineLoad.idle
    /// nil : Parakeet n'a pas été demandé.
    private var parakeetLoad: EngineLoad?
    private var engineT0 = Date()

    private func mark(_ name: String) {
        stages.append("\(name)=\(Self.ms(since: stageT))")
        stageT = Date()
    }

    init(state: AppState, store: Store) {
        self.state = state
        self.store = store
        hotkeys.onActions = { [weak self] actions in actions.forEach { self?.perform($0) } }
        hotkeys.onPasteLast = { [weak self] in self?.pasteLast() }
        hotkeys.onTransform = { [weak self] n in self?.applyTransform(index: n) }
        hotkeys.onScratchpad = { [weak self] in self?.onScratchpad?() }
        hotkeys.onSecureInputChanged = { [weak self] secure in
            self?.state.secureInputActive = secure
            Log.write(secure ? "Saisie sécurisée active : raccourci fn bloqué" : "Saisie sécurisée désactivée")
        }
        recorder.onLevel = { [weak self] level in self?.panel.model.push(level: level) }
        hotkeys.onReturnKey = { [weak self] in self?.editObserver.returnPressed() }
    }

    // MARK: Démarrage

    func startEngines() {
        if let code = KeyboardLayout.keyCode(for: "v") { hotkeys.pasteKeyCode = Int64(code) }
        // Whisper et Parakeet se chargent indépendamment : l'échec de l'un n'empêche pas l'autre de servir.
        state.asrStatus = String(localized: "Chargement… (1er lancement : téléchargement et compilation, quelques minutes)")
        engineT0 = Date()
        // Whisper (1,5 Go) ne se télécharge que s'il est choisi ; déjà présent sur le disque, il sert de secours.
        if settings.asrEngine != "parakeet" || Transcriber.whisperIsDownloaded(settings.whisperModel) { loadWhisperEngine() }
        if settings.asrEngine == "parakeet" { loadParakeetEngine() }
        Task { await refreshLLM() }
        Task {
            await vad.load()
            state.vadReady = await vad.isReady
        }
    }

    /// Lance le chargement de Whisper s'il n'est ni prêt ni en cours.
    private func loadWhisperEngine() {
        switch whisperLoad {
        case .loading, .ready: return
        default: break
        }
        whisperLoad = .loading
        let t = transcriber
        let model = settings.whisperModel
        Task {
            do {
                try await t.load(model: model)
                whisperLoad = .ready
                Log.write("Whisper prêt en \(Int(Date().timeIntervalSince(engineT0))) s")
            } catch {
                whisperLoad = .failed(error.localizedDescription)
                Log.write("Whisper indisponible : \(error.localizedDescription)")
                loadParakeetEngine() // moteur de secours
            }
            refreshASRStatus()
        }
    }

    /// Lance le chargement de Parakeet s'il n'est ni prêt ni en cours (un échec précédent est retenté).
    private func loadParakeetEngine() {
        switch parakeetLoad {
        case .loading?, .ready?: return
        default: break
        }
        parakeetLoad = .loading
        let t = transcriber
        Task {
            do {
                try await t.loadParakeet { [weak self] fraction in
                    Task { @MainActor in self?.showASRDownload(fraction) }
                }
                state.asrProgress = nil
                parakeetLoad = .ready
                Log.write("Parakeet prêt en \(Int(Date().timeIntervalSince(engineT0))) s")
            } catch {
                state.asrProgress = nil
                parakeetLoad = .failed(error.localizedDescription)
                Log.write("Parakeet indisponible : \(error.localizedDescription)")
                if whisperLoad == .idle { loadWhisperEngine() } // moteur de secours
            }
            refreshASRStatus()
        }
    }

    private func showASRDownload(_ fraction: Double) {
        guard parakeetLoad == .loading else { return }
        if fraction < 1 {
            state.asrProgress = fraction
            state.asrStatus = String(localized: "Téléchargement de Parakeet : \(Int(fraction * 100)) % (≈ 600 Mo)")
        } else {
            state.asrProgress = nil
            state.asrStatus = String(localized: "Compilation pour ce Mac… (1 à 2 min)")
        }
    }

    /// Prêt dès qu'un moteur peut transcrire (le moteur choisi, ou l'autre en secours).
    private func refreshASRStatus() {
        let whisperOK = whisperLoad == .ready
        let parakeetOK = parakeetLoad == .ready
        let wantParakeet = settings.asrEngine == "parakeet"
        var failures: [String] = []
        if case .failed(let e) = whisperLoad { failures.append("Whisper : \(e)") }
        if case .failed(let e)? = parakeetLoad { failures.append("Parakeet : \(e)") }
        state.asrReady = whisperOK || parakeetOK
        if (wantParakeet && parakeetOK) || (!wantParakeet && whisperOK) {
            state.asrStatus = String(localized: "Prêt")
        } else if state.asrReady {
            let fallback = whisperOK ? "Whisper" : "Parakeet"
            state.asrStatus = failures.isEmpty
                ? "Prêt (\(fallback) en attendant \(wantParakeet ? "Parakeet" : "Whisper")…)"
                : "Prêt avec \(fallback) en secours · " + failures.joined(separator: " · ")
        } else if whisperLoad != .loading, parakeetLoad != .loading {
            state.asrStatus = "Erreur : " + failures.joined(separator: " · ")
        }
    }

    var llmClient: LLMClient { LLMClient(endpoint: settings.llmEndpoint, model: settings.llmModelName) }
    var instructClient: LLMClient {
        settings.instructEndpoint.isEmpty ? llmClient : LLMClient(endpoint: settings.instructEndpoint, model: settings.llmModelName)
    }

    /// Télécharge le modèle LLM par défaut (3,1 Go), avec reprise : 5 tentatives espacées, puis abandon jusqu'au prochain lancement.
    private func downloadLLM() async -> Bool {
        let dest = URL(fileURLWithPath: ModelFiles.defaultLLMPath)
        for attempt in 1 ... 5 {
            state.llmProgress = 0
            state.llmStatus = String(localized: "Téléchargement du modèle de mise au propre…")
            let downloader = FileDownloader(url: ModelFiles.llmURL, to: dest) { [weak self] p in
                Task { @MainActor in
                    guard let self, let f = p.fraction else { return }
                    self.state.llmProgress = f
                    self.state.llmStatus = String(localized: "Téléchargement : \(Int(f * 100)) % (\(ByteFormat.string(p.received)) sur \(ByteFormat.string(p.total ?? 0)))")
                }
            }
            do {
                try await downloader.run()
                state.llmProgress = nil
                Log.write("Modèle LLM téléchargé")
                return true
            } catch {
                Log.write("Téléchargement du LLM (essai \(attempt)) : \(error.localizedDescription)")
                state.llmStatus = String(localized: "Connexion perdue, nouvel essai… (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 5_000_000_000)
            }
        }
        state.llmProgress = nil
        state.llmReady = false
        state.llmStatus = String(localized: "Modèle non téléchargé (pas de connexion ?). Texte brut utilisé ; nouvel essai au prochain lancement.")
        return false
    }

    func refreshLLM() async {
        guard settings.voices.contains(where: { $0.cleanupLevel != .none }) else { state.llmStatus = "Désactivé (toutes les voix en « Aucun »)"; return }
        if settings.llmModelPath == ModelFiles.defaultLLMPath, !FileManager.default.fileExists(atPath: settings.llmModelPath),
           !(await llmClient.isHealthy()) {
            guard await downloadLLM() else { return }
        }
        state.llmStatus = String(localized: "Démarrage…")
        if let err = await llmServer.ensureRunning(settings: settings) {
            state.llmReady = false
            state.llmStatus = String(localized: "Indisponible, texte brut utilisé : \(err)")
            Log.write("LLM indisponible : \(err)")
        } else {
            // Chauffe : charge le prompt système dans le cache KV de llama-server (1er appel ~1,3 s sinon).
            let client = LLMClient(endpoint: settings.llmEndpoint, model: settings.llmModelName)
            _ = try? await client.format("euh bonjour je teste la dictée", level: .light, context: DictationContext(), vocabulary: [])
            state.llmStatus = String(localized: "Prêt")
            state.llmReady = true
            Log.write("LLM prêt")
        }
    }

    func installHotkeys() -> Bool { hotkeys.start() }

    // MARK: Actions de la machine d'états

    private func perform(_ action: DictationMachine.Action) {
        switch action {
        case .startRecording: startRecording()
        case .enterHandsFree:
            // Prise refusée (micro) : garder le message d'erreur affiché.
            if !startFailed { panel.show(.recording(handsFree: true)) }
        case .scheduleTapTimeout(let delay):
            tapToken += 1
            let token = tapToken
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.tapToken == token else { return }
                self.hotkeys.send(.tapTimeout)
            }
        case .stopAndProcess:
            Task { await process() }
        case .cancel:
            cancelRecording()
        }
    }

    private func startRecording() {
        guard AudioRecorder.hasPermission else {
            panel.show(.message("Micro non autorisé (Réglages › Confidentialité › Micro)", isError: true), autoHideAfter: 3)
            startFailed = true
            hotkeys.send(.escape)
            return
        }
        do {
            try recorder.start()
        } catch {
            panel.show(.message(error.localizedDescription, isError: true), autoHideAfter: 3)
            startFailed = true
            hotkeys.send(.escape)
            return
        }
        startFailed = false
        dictationBusy = true
        dictationSerial += 1
        instructMode = hotkeys.startedAsInstruct
        let readText = settings.useContext || instructMode
        contextTask = Task.detached(priority: .userInitiated) { ContextReader.capture(readText: readText) }
        if settings.muteWhileDictating { OutputMute.engage() }
        panel.show(instructMode ? .instruct("Écoute…") : .recording(handsFree: false))
        if settings.playSounds { NSSound(named: "Tink")?.play() }
        onRecordingChanged?(true)

        // Limite de 20 min.
        let work = DispatchWorkItem { [weak self] in self?.hotkeys.send(.maxDurationReached) }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60, execute: work)
    }

    private func cancelRecording() {
        maxDurationWork?.cancel()
        recorder.stop()
        contextTask?.cancel()
        contextTask = nil
        OutputMute.release()
        dictationBusy = false
        if startFailed {
            // Annulation consécutive à un échec de démarrage : le message d'erreur reste jusqu'à son masquage auto.
            startFailed = false
        } else {
            panel.show(.hidden)
        }
        onRecordingChanged?(false)
    }

    private func stopFromPanel() {
        // Bouton ■ du mode mains-libres : équivaut à un appui sur fn.
        let now = ProcessInfo.processInfo.systemUptime
        hotkeys.send(.fnDown(now))
        hotkeys.send(.fnUp(now))
    }

    // MARK: Pipeline

    private func process() async {
        maxDurationWork?.cancel()
        let tStop = Date()
        defer {
            dictationBusy = false
            onRecordingChanged?(false)
            hotkeys.send(.processingFinished)
        }
        // Petite queue d'enregistrement : la fin du dernier mot arrive souvent après le relâchement de fn.
        stages = []
        stageT = Date()
        // La queue ne sert que si l'on parlait encore au relâchement : sinon elle coûte 120 ms pour rien.
        let window = recorder.tail(seconds: 1)
        let end = await vad.lastSpeechEnd(window)
        let stillSpeaking = end.map { Double(window.count) / 16_000 - $0 < 0.2 } ?? false
        if stillSpeaking { try? await Task.sleep(nanoseconds: 120_000_000) }
        let raw = recorder.stop()
        mark("queue")
        OutputMute.release()
        onRecordingChanged?(false)
        let audioSeconds = Double(raw.count) / 16_000
        let (audio, speechSeconds) = await vad.trim(raw)
        mark("vad")
        guard speechSeconds >= 0.3 else { panel.show(.hidden); return }

        panel.show(instructMode ? .instruct("Réflexion…") : .processing)
        let ctxResult = await contextTask?.value ?? ContextReader.capture(readText: false)
        contextTask = nil
        mark("ctx")
        let ctx = ctxResult.context
        var record = TranscriptRecord(appName: ctx.appName, bundleID: ctx.bundleID, rawText: "", formattedText: "", finalText: "",
                                      audioSeconds: audioSeconds, status: "pasted")
        if instructMode {
            await runInstruct(audio: audio, speechSeconds: speechSeconds, context: ctxResult, record: &record)
            finish(record, audio: raw, tStop: tStop)
            return
        }
        do {
            if let final = try await runPipeline(audio: audio, speechSeconds: speechSeconds, context: ctxResult, record: &record) {
                lastText = final
                if settings.useContext, ctxResult.element == nil, ctx.appName != nil, !Self.pastesWithoutAX(ctx.bundleID) {
                    // Aucun champ focalisé : bulle copiable plutôt qu'un Cmd+V dans le vide.
                    record.status = "bubble"
                    panel.show(.bubble(final), autoHideAfter: 20)
                } else {
                    mark("post")
                    let outcome = await paster.paste(final)
                    mark("collage")
                    pastedAt = Date()
                    switch outcome {
                    case .pasted:
                        panel.show(.hidden)
                        if let el = ctxResult.element, ctxResult.readable {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            if EditObserver.verify(element: el, pasted: final) == false {
                                record.skipReason = "paste_not_found"
                                Log.write("Collage non retrouvé dans le champ")
                            }
                        }
                    case .leftInClipboard:
                        record.status = "bubble"
                        panel.show(.bubble(final), autoHideAfter: 20)
                    }
                }
            } else {
                panel.show(.hidden)
            }
        } catch {
            record.status = "error"
            Log.write("Erreur de dictée : \(error)")
            panel.show(.message("Erreur : \(error.localizedDescription)", isError: true), autoHideAfter: 3)
        }
        let id = finish(record, audio: raw, tStop: tStop)
        if record.status == "pasted", settings.learnFromEdits, let el = ctxResult.element, ctxResult.readable, let id {
            editObserver.start(element: el, pasted: record.finalText, transcriptID: id) { [weak self] obs in
                guard let self, let obs else { return }
                Task { await self.learn(from: obs) }
            }
        }
    }

    /// Apps où le collage marche même sans champ AX lisible (terminaux, apps Electron mal exposées…).
    static func pastesWithoutAX(_ bundleID: String?) -> Bool {
        guard let b = bundleID?.lowercased() else { return true }
        let known = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                     "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.tinyspeck.slackmacgap",
                     "notion.id", "com.hnc.discord", "com.figma.desktop", "md.obsidian", "com.openai.chat", "com.anthropic.claudefordesktop"]
        return known.contains(b) || b.contains("electron") || b.hasPrefix("com.google.chrome") || b.contains("browser")
            || ["com.apple.safari", "company.thebrowser.browser", "org.mozilla.firefox", "com.brave.browser", "com.microsoft.edgemac"].contains(b)
    }

    // MARK: Instruct

    private func runInstruct(audio: [Float], speechSeconds: Double, context: ContextReader.Result, record: inout TranscriptRecord) async {
        record.mode = "instruct"
        do {
            let asr = try await recognize(audio, prompt: nil, preferParakeet: false)
            record.rawText = asr.text
            record.language = asr.language
            // Liste de fantômes propre à Whisper : sur Parakeet elle écarterait de vraies réponses courtes.
            guard !(asr.byWhisper && HallucinationFilter.isPhantom(asr.text, speechSeconds: speechSeconds)) else { record.status = "dropped"; panel.show(.hidden); return }
            panel.show(.instruct("« \(asr.text.prefix(60)) »"))
            let tLlm = Date()
            let agent = InstructAgent(client: instructClient, store: store) { [weak self] text in
                guard let self else { return false }
                return await self.paster.paste(text) == .pasted
            }
            let prefCtx = preferenceContext(context, language: asr.language)
            let outcome = await agent.run(request: asr.text, context: context) { mode in
                var c = prefCtx; c.mode = mode
                return PreferenceFilter.block((try? self.store.preferences()) ?? [], c)
            }
            record.llmMs = Self.ms(since: tLlm)
            record.finalText = outcome.pasted ?? outcome.shown ?? outcome.message ?? ""
            record.status = outcome.pasted != nil ? "pasted" : "instruct"
            if let p = outcome.pasted { lastText = p }
            let tools = (try? JSONSerialization.data(withJSONObject: outcome.toolLog)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            _ = try? store.insert(InstructTurn(appName: context.context.appName, request: asr.text, response: record.finalText, tools: tools))
            state.instructVersion += 1
            if let shown = outcome.shown, !shown.isEmpty {
                panel.show(.bubble(shown), autoHideAfter: 60)
            } else if let msg = outcome.message {
                panel.show(.message(msg, isError: false), autoHideAfter: 4)
                state.lexiconVersion += 1
            } else {
                panel.show(.hidden)
            }
        } catch {
            record.status = "error"
            panel.show(.message("Erreur : \(error.localizedDescription)", isError: true), autoHideAfter: 3)
        }
    }

    // MARK: Apprentissage des corrections

    private func learn(from obs: EditObserver.Observation) async {
        // Au-delà, la zone observée contient surtout la saisie qui a suivi : ce n'est pas une correction de la dictée.
        guard EditLearning.editRatio(obs.pasted, obs.edited) <= 0.5 else { return } // réécriture, pas une correction
        try? store.setEditedText(transcriptID: obs.transcriptID, text: obs.edited)
        let lexicon = (try? store.lexicon()) ?? []
        let known = Set(lexicon.map { $0.phrase.lowercased() })
        let candidates = EditLearning.candidates(original: obs.pasted, edited: obs.edited, dictionary: known)
        guard !candidates.isEmpty else { return }
        // Validation par le LLM (équivalent de /llm/extract_edited_words) : on ne garde que noms propres, termes, acronymes.
        let list = candidates.map { "- « \($0.observedSource) » corrigé en « \($0.word) »" }.joined(separator: "\n")
        let schema: [String: Any] = ["type": "object", "properties": ["words": ["type": "array", "items": ["type": "string"]]],
                                     "required": ["words"], "additionalProperties": false]
        let system = """
        Un utilisateur a corrigé à la main le texte produit par sa dictée vocale. Parmi ses corrections, garde uniquement \
        celles qui révèlent un mot que la reconnaissance vocale ne connaît pas : nom propre, nom de personne, marque, \
        terme technique, acronyme, mot étranger. Ignore les reformulations, les fautes de grammaire, les changements de sens. \
        Réponds avec la liste des formes corrigées à ajouter au dictionnaire (éventuellement vide).
        """
        guard let o = try? await llmClient.json(system: system, user: list, schema: schema, maxTokens: 200),
              let words = o["words"] as? [String] else { return }
        let valid = Set(candidates.map(\.word))
        var added: [String] = []
        for w in words where valid.contains(w) {
            try? store.upsert(LexiconEntry(kind: .word, phrase: w))
            added.append(w)
        }
        guard !added.isEmpty else { return }
        Log.write("Appris : \(added.count) mot(s) ajouté(s) au dictionnaire")
        state.lexiconVersion += 1
        if settings.playSounds { NSSound(named: "Purr")?.play() }
        // Une nouvelle dictée a peut-être démarré : ne pas remplacer sa pastille (ni la masquer 3 s plus tard).
        if !dictationBusy {
            panel.show(.message("Ajouté au dictionnaire : \(added.joined(separator: ", "))", isError: false), autoHideAfter: 3)
        }
    }

    /// ASR → filtres → snippet / LLM → post-traitement. Renvoie nil si la dictée est écartée (`record.status = "dropped"`).
    func runPipeline(audio: [Float], speechSeconds: Double, context ctxResult: ContextReader.Result,
                     record: inout TranscriptRecord) async throws -> String? {
        let ctx = ctxResult.context
        let lexicon = (try? store.lexicon()) ?? []
        let vocabulary = Self.vocabulary(from: lexicon)
        let prompt = WhisperPrompt.build(terms: vocabulary)

        mark("prep")
        let tAsr = Date()
        let asr = try await recognize(audio, prompt: prompt, preferParakeet: settings.asrEngine == "parakeet")
        record.asrMs = Self.ms(since: tAsr)
        mark("asr")
        record.rawText = asr.text
        record.language = asr.language

        // Fantômes et écho du prompt sont des artefacts de Whisper : Parakeet n'a pas de prompt et ces listes
        // écarteraient de vraies dictées (« Merci beaucoup », un terme du dictionnaire dicté seul).
        if asr.byWhisper, HallucinationFilter.isPhantom(asr.text, speechSeconds: speechSeconds) {
            record.status = "dropped"; record.skipReason = "phantom"
            return nil
        }
        if asr.byWhisper, WhisperPrompt.isEcho(output: asr.text, prompt: prompt) {
            record.status = "dropped"; record.skipReason = "echo"
            return nil
        }

        let voice = VoiceResolver.resolve(settings.voices, appName: ctx.appName, bundleID: ctx.bundleID, url: ctxResult.url)
        record.voice = voice.id
        let prefCtx = preferenceContext(ctxResult, language: asr.language)
        let prefs = PreferenceFilter.block((try? store.preferences()) ?? [], prefCtx)

        let post = PostProcessor(lexicon: lexicon)
        var text: String
        if let snippet = post.exactSnippet(for: asr.text) {
            text = snippet
            record.formattedText = snippet
        } else {
            text = asr.text
            if voice.cleanupLevel != .none, asr.text.split(separator: " ").count > 3 || prefs != nil {
                let tLlm = Date()
                do {
                    let out = try await llmClient.format(asr.text, level: voice.cleanupLevel,
                                                         context: ctxResult.isSecure ? DictationContext(appName: ctx.appName) : ctx,
                                                         vocabulary: vocabulary, style: voice.style, preferences: prefs)
                    if out.isEmpty {
                        record.skipReason = "empty"
                    } else if DivergenceGuard.isSuspicious(input: asr.text, output: out) {
                        record.skipReason = "divergence"
                        Log.write("Sortie LLM rejetée par la garde de divergence (\(out.count) caractères)")
                    } else {
                        text = out
                    }
                } catch {
                    record.skipReason = "llm_error"
                    Log.write("LLM indisponible, texte brut : \(error.localizedDescription)")
                }
                record.llmMs = Self.ms(since: tLlm)
                mark("llm")
            }
            record.formattedText = text
            text = post.apply(text)
        }
        guard !text.isEmpty else { record.status = "dropped"; return nil }
        let nouns = Set(lexicon.filter { $0.kind != .snippet }.map { ($0.kind == .word ? $0.phrase : $0.replacement).lowercased() })
        var final = PostProcessor.fitToContext(text, before: ctx.before, after: ctx.after, selection: ctx.selection, properNouns: nouns)
        let beforeLine = ctx.before?.components(separatedBy: "\n").last ?? ""
        let afterLine = ctx.after?.components(separatedBy: "\n").first ?? ""
        final = VoiceResolver.stripTrailingPeriod(final, style: voice.style, isMessaging: prefCtx.appCategory == "messaging",
                                                  beforeLine: beforeLine, afterLine: afterLine, hasSelection: !(ctx.selection ?? "").isEmpty)
        record.finalText = final
        return final
    }

    /// ASR avec secours croisé : Parakeet si choisi et prêt (ou si Whisper est indisponible), sinon Whisper ;
    /// en cas d'échec du moteur utilisé, nouvel essai sur l'autre s'il est chargé. `byWhisper` : texte produit par Whisper.
    private func recognize(_ audio: [Float], prompt: String?, preferParakeet: Bool) async throws
        -> (text: String, language: String?, byWhisper: Bool) {
        let whisperStatus = await transcriber.status
        let whisperReady = whisperStatus == .ready
        let whisperUsable = whisperReady || whisperStatus == .loading
        let parakeetReady = await transcriber.parakeetReady
        // Choisi en cours de route : Whisper le temps que Parakeet se charge.
        if preferParakeet, !parakeetReady { loadParakeetEngine() }
        if !preferParakeet, whisperLoad == .idle { loadWhisperEngine() }
        let useParakeet = (parakeetReady && (preferParakeet || !whisperReady)) || !whisperUsable
        do {
            if useParakeet {
                let r = try await transcriber.transcribeParakeet(audio, languages: settings.languages)
                return (r.text, r.language, false)
            }
            let r = try await transcriber.transcribe(audio, languages: settings.languages, prompt: prompt)
            return (r.text, r.language, true)
        } catch {
            let otherReady: Bool
            if useParakeet { otherReady = await transcriber.status == .ready } else { otherReady = await transcriber.parakeetReady }
            guard otherReady else { throw error }
            Log.write("\(useParakeet ? "Parakeet" : "Whisper") en échec (\(error.localizedDescription)), nouvel essai avec \(useParakeet ? "Whisper" : "Parakeet")")
        }
        if useParakeet {
            let r = try await transcriber.transcribe(audio, languages: settings.languages, prompt: prompt)
            return (r.text, r.language, true)
        }
        let r = try await transcriber.transcribeParakeet(audio, languages: settings.languages)
        return (r.text, r.language, false)
    }

    /// `--selftest fichier.wav [texte avant curseur]` : pipeline complet sans raccourci ni collage, résultat sur stdout.
    func selfTest(path: String, before: String?) async -> Int32 {
        do {
            try await transcriber.load(model: settings.whisperModel)
            await vad.load()
            await refreshLLM()
            let raw = try Transcriber.loadAudio(path: path)
            var t0 = Date()
            var record = TranscriptRecord(appName: "selftest", rawText: "", formattedText: "", finalText: "", audioSeconds: Double(raw.count) / 16_000)
            var final: String?
            for _ in 0 ..< 2 { // 2e passe = latence à chaud
                t0 = Date()
                let (audio, speech) = await vad.trim(raw)
                let ctx = ContextReader.Result(context: DictationContext(appName: "selftest", before: before), isSecure: false)
                final = try await runPipeline(audio: audio, speechSeconds: speech, context: ctx, record: &record)
            }
            print("LLM   : \(state.llmStatus)")
            print("BRUT  : \(record.rawText)")
            print("FINAL : \(final ?? "(écarté)")")
            print("ASR \(record.asrMs) ms · LLM \(record.llmMs) ms · total \(Self.ms(since: t0)) ms · langue \(record.language ?? "?")")
            return 0
        } catch {
            print("ÉCHEC : \(error)")
            return 1
        }
    }

    /// Banc de latence : chaque fichier 3 fois à chaud, étapes médianes (la 1re passe de chauffe est ignorée).
    func bench(paths: [String]) async -> Int32 {
        do {
            try await transcriber.load(model: settings.whisperModel)
            if settings.asrEngine == "parakeet" { try await transcriber.loadParakeet() }
            await vad.load()
            await refreshLLM()
            var totals: [Int] = []
            for path in paths {
                let raw = try Transcriber.loadAudio(path: path)
                var runs: [[String: Int]] = []
                var final: String?
                var record = TranscriptRecord(appName: "bench", rawText: "", formattedText: "", finalText: "", audioSeconds: Double(raw.count) / 16_000)
                for run in 0 ..< 4 {
                    // Espace les passes comme de vraies dictées (llama-server finit son travail ~1 s après chaque réponse).
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    stages = []
                    let t0 = Date()
                    stageT = t0
                    let (audio, speech) = await vad.trim(raw)
                    mark("vad")
                    let ctx = ContextReader.Result(context: DictationContext(appName: "bench"), isSecure: false)
                    record.llmMs = 0
                    final = try await runPipeline(audio: audio, speechSeconds: speech, context: ctx, record: &record)
                    mark("post")
                    var m = Dictionary(uniqueKeysWithValues: stages.compactMap { st -> (String, Int)? in
                        let kv = st.split(separator: "="); return kv.count == 2 ? (String(kv[0]), Int(kv[1]) ?? 0) : nil })
                    m["total"] = Self.ms(since: t0)
                    if run > 0 { runs.append(m) }
                }
                func med(_ k: String) -> Int { let v = runs.map { $0[k] ?? 0 }.sorted(); return v[v.count / 2] }
                totals.append(med("total"))
                let name = URL(fileURLWithPath: path).lastPathComponent
                print("\(name) \(String(format: "%4.1f", record.audioSeconds)) s · vad \(med("vad")) · asr \(med("asr")) · llm \(med("llm")) · post \(med("post")) · total \(med("total")) ms")
                print("   BRUT  : \(record.rawText)")
                print("   FINAL : \(final ?? "(écarté)")")
            }
            print("MÉDIANE TOTALE : \(totals.sorted()[totals.count / 2]) ms (+120 ms de queue et ~30 ms de collage en vrai)")
            return 0
        } catch {
            print("ÉCHEC : \(error)")
            return 1
        }
    }

    func preferenceContext(_ r: ContextReader.Result, language: String?) -> PreferenceContext {
        let c = r.context
        return PreferenceContext(appIdentities: VoiceResolver.identities(appName: c.appName, bundleID: c.bundleID, url: r.url),
                                 appCategory: VoiceResolver.category(appName: c.appName, bundleID: c.bundleID, url: r.url),
                                 language: language, mode: "dictation")
    }

    /// `--instruct "demande" ["sélection"]` : agent Instruct sans voix ni collage (paste → stdout).
    func instructTest(request: String, selection: String?) async -> Int32 {
        await refreshLLM()
        let ctx = ContextReader.Result(context: DictationContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", before: "", selection: selection, after: ""),
                                       isSecure: false)
        let agent = InstructAgent(client: instructClient, store: store) { text in print("PASTE : \(text)"); return true }
        let t0 = Date()
        let o = await agent.run(request: request, context: ctx) { mode in
            var c = self.preferenceContext(ctx, language: "fr"); c.mode = mode
            return PreferenceFilter.block((try? self.store.preferences()) ?? [], c)
        }
        for t in o.toolLog { print("OUTIL : \(t["name"] ?? "?") \(t["arguments"] ?? "")") }
        if let s = o.shown { print("BULLE : \(s)") }
        if let m = o.message { print("MESSAGE : \(m)") }
        print("\(Self.ms(since: t0)) ms")
        return 0
    }

    @discardableResult
    private func finish(_ record: TranscriptRecord, audio: [Float], tStop: Date) -> Int64? {
        var record = record
        // Latence = du relâchement de fn au collage (la vérification qui suit n'en fait pas partie).
        record.totalMs = Int(((pastedAt ?? Date()).timeIntervalSince(tStop)) * 1000)
        pastedAt = nil
        Log.write("Dictée \(record.status) · \(record.appName ?? "?") · audio \(String(format: "%.1f", record.audioSeconds)) s · ASR \(record.asrMs) ms · LLM \(record.llmMs) ms · total \(record.totalMs) ms · étapes \(stages.joined(separator: " "))")
        guard settings.retention != "never" else { return nil }
        if settings.keepAudio, record.status != "dropped" {
            let dir = AppSettings.supportDirectory.appendingPathComponent("audio", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
            if (try? AudioUtils.writeWAV(audio, to: url)) != nil { record.audioPath = url.path }
        }
        let id = try? store.insert(record)
        state.historyVersion += 1
        return id
    }

    // MARK: Réécritures rapides

    /// Réécrit `text` avec la consigne `t` (nil si le LLM échoue).
    func rewrite(_ t: RewriteTransform, _ text: String) async -> String? {
        do {
            let reply = try await instructClient.chat(messages: t.messages(for: text), maxTokens: 2048, temperature: 0.2,
                                                        timeout: min(90, max(30, Double(text.split(separator: " ").count) * 0.1)))
            // Réponse tronquée : mieux vaut ne rien remplacer qu'un texte coupé.
            if reply.finishReason == "length" {
                Log.write("Réécriture tronquée (finish_reason=length)")
                return nil
            }
            let out = RewriteTransform.clean(reply.content, source: text)
            return out.isEmpty ? nil : out
        } catch {
            Log.write("Réécriture impossible : \(error.localizedDescription)")
            return nil
        }
    }

    /// Applique la réécriture n° `index` à la sélection (remplacée), sinon à la dernière dictée (bulle à copier).
    func applyTransform(index: Int) {
        guard index < settings.transforms.count, !hotkeys.isRecording, !dictationBusy else { return }
        let transform = settings.transforms[index]
        let ctx = ContextReader.capture(readText: true)
        let selection = ctx.context.selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = selection.isEmpty ? (lastText ?? (try? store.lastTranscript())?.finalText ?? "") : selection
        guard !source.isEmpty else {
            panel.show(.message(String(localized: "Sélectionnez du texte à réécrire"), isError: true), autoHideAfter: 3)
            return
        }
        guard !ctx.isSecure else { return }
        panel.show(.instruct(String(localized: "Réécriture : \(transform.name)…")))
        let serial = dictationSerial
        Task {
            let t0 = Date()
            do {
                guard let out = await rewrite(transform, source) else { throw NSError(domain: "wl.transform", code: 1) }
                if dictationBusy || dictationSerial != serial {
                    // Une dictée a démarré pendant la réécriture : ni ⌘V ni changement de la barre, qui lui appartient.
                    // Le résultat reste dans l'historique Instruct.
                    Log.write("Réécriture « \(transform.name) » terminée pendant une dictée : ni collage ni bulle")
                } else if !selection.isEmpty, await paster.paste(out) == .pasted {
                    if !dictationBusy { panel.show(.hidden) }
                } else if !dictationBusy {
                    panel.show(.bubble(out), autoHideAfter: 60)
                }
                if dictationSerial == serial { lastText = out }
                _ = try? store.insert(InstructTurn(appName: ctx.context.appName, request: "⌃⌥\(index + 1) · \(transform.name)", response: out, tools: "[]"))
                state.instructVersion += 1
                Log.write("Réécriture « \(transform.name) » en \(Self.ms(since: t0)) ms")
            } catch {
                Log.write("Réécriture impossible : \(error.localizedDescription)")
                if !dictationBusy, dictationSerial == serial {
                    panel.show(.message(String(localized: "Réécriture impossible (LLM indisponible ?)"), isError: true), autoHideAfter: 3)
                }
            }
        }
    }

    func pasteLast() {
        guard let text = lastText ?? (try? store.lastTranscript())?.finalText, !text.isEmpty else { return }
        Task { _ = await paster.paste(text) }
    }

    func applyRetention() {
        let cutoff: Date
        switch settings.retention {
        case "24h": cutoff = Date().addingTimeInterval(-24 * 3600)
        case "never": cutoff = .distantFuture
        default: return
        }
        let paths = (try? store.purgeTranscripts(olderThan: cutoff)) ?? []
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        if !paths.isEmpty || settings.retention == "never" { state.historyVersion += 1 }
    }

    // MARK: Utilitaires

    /// Termes pour le biais Whisper et le LLM, par priorité : favoris, mots, formes correctes, snippets exclus.
    static func vocabulary(from lexicon: [LexiconEntry]) -> [String] {
        let words = lexicon.filter { $0.kind == .word }
        let starred = words.filter(\.starred).map(\.phrase)
        let others = words.filter { !$0.starred }.map(\.phrase)
        let fixes = lexicon.filter { $0.kind == .replacement }.map(\.replacement)
        return starred + others + fixes
    }

    static func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
}
