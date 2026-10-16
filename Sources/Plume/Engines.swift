import Foundation
import CoreML
import WhisperKit
import FluidAudio
import NaturalLanguage
import PlumeCore

/// Journal texte dans ~/Library/Application Support/Plume/plume.log (pas de contenu dicté).
enum Log {
    private static let queue = DispatchQueue(label: "wl.log")
    private static let url = AppSettings.supportDirectory.appendingPathComponent("plume.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

// MARK: - ASR (WhisperKit, CoreML/ANE)

actor Transcriber {
    enum Status: Equatable { case idle, loading, ready, failed(String) }

    private var whisper: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    private(set) var status: Status = .idle
    /// Moteur de dictée : Parakeet (FluidAudio, ~10× plus rapide) ou Whisper (prompt de vocabulaire).
    private var parakeet: AsrManager?
    private var parakeetTask: Task<AsrManager, Error>?

    /// Charge Parakeet Ultra (25 langues européennes, encodeur int8 sur l'ANE), puis une passe de chauffe.
    func loadParakeet(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if parakeet != nil { return }
        if let parakeetTask { parakeet = try await parakeetTask.value; return }
        let task = Task<AsrManager, Error> {
            let dir = AppSettings.supportDirectory.appendingPathComponent("parakeet", isDirectory: true)
            // Sans GPU : llama.cpp l'utilise juste après, et un GPU déjà sollicité divise sa vitesse par deux pendant ~1 s.
            let config = MLModelConfiguration()
            switch ProcessInfo.processInfo.environment["WL_PK_UNITS"] {
            case "gpu": config.computeUnits = .cpuAndGPU
            case "ane": config.computeUnits = .cpuAndNeuralEngine
            case "cpu": config.computeUnits = .cpuOnly
            default: config.computeUnits = .all
            }
            let version: AsrModelVersion = ProcessInfo.processInfo.environment["WL_PK_VER"] == "v3" ? .v3 : .ultra
            let models = try await AsrModels.downloadAndLoad(to: dir, configuration: config, version: version,
                                                             encoderComputeUnits: .cpuAndNeuralEngine,
                                                             progressHandler: { p in progress?(p.fractionCompleted) })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var state = TdtDecoderState.make()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            return manager
        }
        parakeetTask = task
        do { parakeet = try await task.value } catch { parakeetTask = nil; throw error }
    }

    var parakeetReady: Bool { parakeet != nil }

    /// Transcription Parakeet. Pas de prompt : le vocabulaire passe par le dictionnaire et le LLM.
    func transcribeParakeet(_ audio: [Float], languages: [String]) async throws -> (text: String, language: String?) {
        if parakeet == nil { try await loadParakeet() }
        guard let parakeet else { throw NSError(domain: "wl.asr", code: 2, userInfo: [NSLocalizedDescriptionKey: "Parakeet non chargé"]) }
        var state = TdtDecoderState.make()
        // Le filtre d'alphabet n'a d'effet que latin/cyrillique : la 1re langue suffit à l'activer.
        let hint = languages.first.flatMap { Language(rawValue: $0) }
        let r = try await parakeet.transcribe(audio, decoderState: &state, language: hint)
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ProcessInfo.processInfo.environment["WL_ASR_TIMINGS"] != nil {
            print(String(format: "   [parakeet] %.0f ms · confiance %.2f", r.processingTime * 1000, r.confidence))
        }
        return (text, Self.detectLanguage(text, among: languages))
    }

    /// Langue du texte, limitée aux langues de l'utilisateur (Parakeet ne la renvoie pas).
    static func detectLanguage(_ text: String, among languages: [String]) -> String? {
        if languages.count == 1 { return languages[0] }
        let r = NLLanguageRecognizer()
        if !languages.isEmpty { r.languageConstraints = languages.map { NLLanguage(rawValue: $0) } }
        r.processString(text)
        return r.dominantLanguage?.rawValue
    }

    /// Charge le modèle puis fait une transcription de chauffe (1er appel ANE ~2× plus lent, mesuré en M0).
    func load(model: String) async throws {
        if whisper != nil { return }
        if let loadTask { _ = try await loadTask.value; return }
        status = .loading
        let task = Task<WhisperKit, Error> {
            // Cache des modèles dans Application Support : ~/Documents déclencherait une demande d'accès TCC.
            let base = AppSettings.supportDirectory.appendingPathComponent("huggingface", isDirectory: true)
            let env = ProcessInfo.processInfo.environment
            func units(_ v: String?, _ d: MLComputeUnits) -> MLComputeUnits {
                switch v { case "gpu": .cpuAndGPU; case "ane": .cpuAndNeuralEngine; case "all": .all; default: d }
            }
            let compute = ModelComputeOptions(audioEncoderCompute: units(env["WL_ENC"], .cpuAndNeuralEngine),
                                              textDecoderCompute: units(env["WL_DEC"], .cpuAndNeuralEngine))
            let w = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, computeOptions: compute,
                                                          verbose: false, logLevel: .error, prewarm: true))
            _ = try? await w.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                        decodeOptions: DecodingOptions(task: .transcribe, language: "fr", temperature: 0, withoutTimestamps: true))
            return w
        }
        loadTask = task
        do {
            whisper = try await task.value
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            loadTask = nil
            throw error
        }
    }

    static func loadAudio(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }

    /// Transcrit en se limitant aux langues de l'utilisateur.
    /// - aucune langue : détection libre ; une seule : langue imposée ;
    /// - plusieurs : détection en un passage ; si Whisper choisit une langue hors liste (portugais pour du français
    ///   accentué…), on retranscrit dans chaque langue autorisée et on garde la plus sûre (log-probabilité moyenne).
    func transcribe(_ audio: [Float], languages: [String], prompt: String?) async throws -> (text: String, language: String?) {
        if languages.count == 1 { return try await pass(audio, language: languages[0], prompt: prompt).result }
        let first = try await pass(audio, language: nil, prompt: prompt)
        guard languages.count > 1, let detected = first.result.language, !languages.contains(detected) else { return first.result }
        var best = first
        var bestScore = -Float.infinity
        for lang in languages {
            let r = try await pass(audio, language: lang, prompt: prompt)
            if r.score > bestScore { best = r; bestScore = r.score }
        }
        return best.result
    }

    private func pass(_ audio: [Float], language: String?, prompt: String?) async throws -> (result: (text: String, language: String?), score: Float) {
        if whisper == nil, let loadTask { whisper = try await loadTask.value }
        guard let whisper else { throw NSError(domain: "wl.asr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Modèle Whisper non chargé"]) }
        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                      detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true)
        if let prompt, let tok = whisper.tokenizer {
            options.promptTokens = tok.encode(text: " " + prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
        }
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        if ProcessInfo.processInfo.environment["WL_ASR_TIMINGS"] != nil, let t = results.first?.timings {
            print(String(format: "   [asr] lang=%@ mel %.0f · enc %.0f · decInit %.0f · decLoop %.0f (pred %.0f, %d tok) · full %.0f ms",
                         language ?? "auto", t.logmels * 1000, t.encoding * 1000, t.decodingInit * 1000, t.decodingLoop * 1000,
                         t.decodingPredictions * 1000, Int(t.totalDecodingLoops), t.fullPipeline * 1000))
        }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = results.flatMap(\.segments)
        let score = segs.isEmpty ? -Float.infinity : segs.map(\.avgLogprob).reduce(0, +) / Float(segs.count)
        return ((text, language ?? results.first?.language), score)
    }
}

// MARK: - Formatteur LLM (endpoint OpenAI-compatible)

struct LLMClient {
    var endpoint: String
    var model: String

    struct ToolCall { var id: String; var name: String; var arguments: [String: Any] }
    struct Reply {
        var content: String; var toolCalls: [ToolCall]; var rawMessage: [String: Any]
        /// `finish_reason` du choix : "length" = réponse tronquée par max_tokens.
        var finishReason: String? = nil
    }

    /// Endpoint sans espaces ni « / » final (sinon `//v1/chat/completions` → 404 côté llama-server).
    static func normalizedEndpoint(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var base: String { Self.normalizedEndpoint(endpoint) }

    /// Appel générique `/v1/chat/completions` (llama-server, Ollama, LM Studio…), avec outils et schéma JSON optionnels.
    func chat(messages: [[String: Any]], tools: [[String: Any]]? = nil, maxTokens: Int = 1024, temperature: Double = 0,
              jsonSchema: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> Reply {
        guard let url = URL(string: base + "/v1/chat/completions") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": model, "temperature": temperature, "max_tokens": maxTokens, "cache_prompt": true,
            "chat_template_kwargs": ["enable_thinking": false], "messages": messages,
        ]
        if let tools { body["tools"] = tools; body["tool_choice"] = "auto" }
        if let jsonSchema { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "out", "schema": jsonSchema, "strict": true]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw NSError(domain: "wl.llm", code: 2, userInfo: [NSLocalizedDescriptionKey: String(data: data.prefix(300), encoding: .utf8) ?? "réponse invalide"])
        }
        if ProcessInfo.processInfo.environment["WL_LLM_TIMINGS"] != nil, let t = json["timings"] as? [String: Any] {
            print("   [llm] prompt \(t["prompt_n"] ?? "?") tok/\(t["prompt_ms"].map { "\(Int(($0 as? Double) ?? 0))" } ?? "?") ms · gen \(t["predicted_n"] ?? "?") tok/\(t["predicted_ms"].map { "\(Int(($0 as? Double) ?? 0))" } ?? "?") ms · draft \(t["draft_n"] ?? "-")/\(t["draft_n_accepted"] ?? "-")")
        }
        let calls: [ToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { c in
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            var args: [String: Any] = [:]
            if let s = f["arguments"] as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { args = o }
            else if let o = f["arguments"] as? [String: Any] { args = o }
            return ToolCall(id: c["id"] as? String ?? UUID().uuidString, name: name, arguments: args)
        }
        // Sortie brute (hors bloc de raisonnement) : le nettoyage propre à la dictée est fait par `format()` seulement,
        // pour ne pas retirer le markdown ou les guillemets des réécritures, d'Instruct ou du JSON.
        var content = message["content"] as? String ?? ""
        if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(content: content, toolCalls: calls, rawMessage: message, finishReason: choice["finish_reason"] as? String)
    }

    /// Sortie JSON contrainte par schéma, décodée en dictionnaire.
    func json(system: String, user: String, schema: [String: Any], maxTokens: Int = 400) async throws -> [String: Any] {
        let r = try await chat(messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                               maxTokens: maxTokens, jsonSchema: schema, timeout: 15)
        guard let d = r.content.data(using: .utf8), let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw NSError(domain: "wl.llm", code: 3, userInfo: [NSLocalizedDescriptionKey: "JSON invalide : \(r.content.prefix(200))"])
        }
        return o
    }

    func format(_ transcript: String, level: CleanupLevel, context: DictationContext, vocabulary: [String],
                style: StylePreference? = nil, preferences: String? = nil) async throws -> String {
        let words = transcript.split(separator: " ").count
        let user = FormatterPrompt.userMessage(transcript: transcript, level: level, context: context, vocabulary: vocabulary,
                                               style: style, preferences: preferences)
        // Réponse non streamée : le délai couvre toute la génération, il croît donc avec la longueur dictée.
        let timeout = min(30, max(6, Double(words) * 0.05))
        let r = try await chat(messages: [["role": "system", "content": FormatterPrompt.system], ["role": "user", "content": user]],
                               maxTokens: min(2048, words * 3 + 64), timeout: timeout)
        // Réponse tronquée : on échoue pour que l'appelant colle le texte brut plutôt qu'une moitié de dictée.
        if r.finishReason == "length" {
            throw NSError(domain: "wl.llm", code: 4, userInfo: [NSLocalizedDescriptionKey: "réponse LLM tronquée (max_tokens)"])
        }
        return FormatterPrompt.stripContextEcho(FormatterPrompt.cleanOutput(r.content),
                                                before: context.before?.suffix(300).description, transcript: transcript)
    }

    func isHealthy() async -> Bool {
        guard let url = URL(string: base + "/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

/// Lance llama-server en sous-processus si l'endpoint local ne répond pas (même réglages que scripts/llm-server.sh).
final class LLMServerManager {
    private var process: Process?

    /// llama-server livré dans l'app (Contents/MacOS, avec ses dylibs), sinon celui de Homebrew.
    static func findBinary() -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/llama-server").path
        return [bundled, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Renvoie nil si le serveur répond, sinon un message d'erreur.
    func ensureRunning(settings: AppSettings) async -> String? {
        let client = LLMClient(endpoint: settings.llmEndpoint, model: settings.llmModelName)
        if await client.isHealthy() { return nil }
        guard settings.autoStartLLM else { return "Serveur LLM injoignable (\(settings.llmEndpoint))" }
        guard let url = URL(string: LLMClient.normalizedEndpoint(settings.llmEndpoint)),
              ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            return "Serveur LLM distant injoignable"
        }
        // Sans port explicite, le client viserait le port 80 alors que le serveur lancé écouterait ailleurs.
        guard let port = url.port else { return "Port manquant dans l'endpoint LLM (ex. http://127.0.0.1:8081)" }
        guard let bin = Self.findBinary() else { return "llama-server introuvable" }
        guard FileManager.default.fileExists(atPath: settings.llmModelPath) else { return "Modèle LLM introuvable : \(settings.llmModelPath)" }
        if process?.isRunning != true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-m", settings.llmModelPath, "--host", "127.0.0.1", "--port", String(port),
                           "-ngl", "99", "-c", "16384", "--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#,
                           "--spec-type", "ngram-simple", "--spec-ngram-simple-size-n", "3", "--spec-ngram-simple-size-m", "16"]
            let log = AppSettings.supportDirectory.appendingPathComponent("llm-server.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
            do { try p.run() } catch { return "Lancement de llama-server impossible : \(error.localizedDescription)" }
            process = p
        }
        for _ in 0 ..< 120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await client.isHealthy() { return nil }
            if process?.isRunning != true { return "llama-server s'est arrêté (voir llm-server.log)" }
        }
        return "llama-server ne répond pas après 60 s"
    }

    /// Arrête le serveur lancé par l'app et attend sa sortie (3 s max, puis SIGKILL), pour qu'un contrôle /health
    /// juste après ne tombe pas sur l'ancien processus encore en train de s'arrêter.
    func stop() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
    }
}

extension Transcriber {
    /// Le modèle Whisper est-il déjà dans le cache (pas de téléchargement à prévoir) ?
    static func whisperIsDownloaded(_ model: String) -> Bool {
        let dir = AppSettings.supportDirectory.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.hasSuffix(model) }
    }
}
