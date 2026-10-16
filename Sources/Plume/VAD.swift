import FluidAudio
import Foundation

/// Rognage par Silero VAD (FluidAudio, CoreML) : coupe silences de début et de fin, mesure la parole réelle.
/// Repli sur le rognage par énergie si le modèle n'est pas disponible (1er lancement hors ligne…).
actor VoiceActivity {
    private var manager: VadManager?
    private var loading: Task<VadManager, Error>?

    func load() async {
        guard manager == nil, loading == nil else { return }
        let task = Task { try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
        loading = task
        do {
            manager = try await task.value
            Log.write("Silero VAD prêt")
        } catch {
            Log.write("Silero VAD indisponible, rognage par énergie : \(error.localizedDescription)")
        }
        loading = nil
    }

    /// Renvoie l'audio rogné (du début du 1er segment de parole à la fin du dernier) et la durée de parole.
    func trim(_ samples: [Float]) async -> (audio: [Float], speechSeconds: Double) {
        guard let manager, samples.count > 1600 else { return AudioUtils.trimSilence(samples) }
        var config = VadSegmentationConfig.default
        config.minSpeechDuration = 0.15
        config.minSilenceDuration = 0.6
        config.speechPadding = 0.2
        guard let segments = try? await manager.segmentSpeech(samples, config: config) else { return AudioUtils.trimSilence(samples) }
        guard let first = segments.first, let last = segments.last else { return ([], 0) }
        let a = max(0, Int(first.startTime * 16_000))
        let b = min(samples.count, Int(last.endTime * 16_000))
        guard b > a else { return ([], 0) }
        return (Array(samples[a ..< b]), segments.reduce(0) { $0 + $1.duration })
    }

    /// Segments de parole (secondes) pour découper un long flux (réunions).
    func segments(_ samples: [Float], maxSpeech: TimeInterval = 20) async -> [(start: Double, end: Double)] {
        guard let manager else { return [] }
        var config = VadSegmentationConfig.default
        config.maxSpeechDuration = maxSpeech
        config.minSilenceDuration = 0.5
        config.speechPadding = 0.15
        guard let segs = try? await manager.segmentSpeech(samples, config: config) else { return [] }
        return segs.map { ($0.startTime, $0.endTime) }
    }

    /// Fin de la dernière parole dans `samples` (secondes depuis leur début), nil s'il n'y a pas de parole.
    func lastSpeechEnd(_ samples: [Float]) async -> Double? {
        guard let manager, samples.count > 1600 else { return nil }
        var config = VadSegmentationConfig.default
        config.minSpeechDuration = 0.1
        config.minSilenceDuration = 0.1
        config.speechPadding = 0
        guard let segs = try? await manager.segmentSpeech(samples, config: config) else { return nil }
        return segs.last?.endTime
    }

    var isReady: Bool { manager != nil }
}
