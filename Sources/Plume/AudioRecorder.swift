import AVFoundation
import Foundation

/// Capture micro → 16 kHz mono float32 (sans AEC/NS/AGC).
final class AudioRecorder {
    /// Niveau RMS normalisé 0…1, appelé sur le main thread ~20×/s.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    /// Observateur AVAudioEngineConfigurationChange du moteur courant.
    private var configObserver: NSObjectProtocol?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevelAt: TimeInterval = 0

    /// Main thread (comme `stop` et `tail`).
    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        try startEngine()
    }

    /// Démarre un moteur neuf sans toucher aux échantillons déjà capturés.
    private func startEngine() throws {
        // Moteur neuf à chaque prise : suit les changements de périphérique d'entrée (AirPods, USB).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "wl.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aucun micro utilisable (\(inFormat))"])
        }
        let target = self.target
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let chunk = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
            self.publishLevel(chunk)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // Changement de périphérique d'entrée en cours de prise (AirPods, défaut système) : le moteur s'arrête
        // tout seul. On relance la capture sur le nouveau périphérique en conservant l'audio déjà enregistré.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self, weak engine] _ in
            guard let self, let engine, self.engine === engine else { return }
            self.restartAfterConfigurationChange()
        }
    }

    private func restartAfterConfigurationChange() {
        tearDownEngine()
        do {
            try startEngine()
        } catch {
            // Plus de micro utilisable : la prise se termine avec l'audio déjà capturé (rendu par `stop`).
            NSLog("wl.audio: relance après changement de périphérique impossible : \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
        }
    }

    private func tearDownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Les `seconds` dernières secondes enregistrées, sans arrêter la capture.
    func tail(seconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples.suffix(Int(seconds * 16_000)))
    }

    /// Arrête la capture et renvoie l'audio enregistré.
    @discardableResult
    func stop() -> [Float] {
        tearDownEngine()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll()
        return out
    }

    private func publishLevel(_ chunk: UnsafeBufferPointer<Float>) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelAt >= 0.05 else { return }
        lastLevelAt = now
        var sum: Float = 0
        for x in chunk { sum += x * x }
        let rms = sqrt(sum / Float(max(chunk.count, 1)))
        // -55 dB → 0, -10 dB → 1
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 55) / 45, 0), 1)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var hasPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
}

enum AudioUtils {
    /// Rognage début/fin par énergie (trames de 30 ms). Renvoie l'audio rogné et la durée de parole estimée.
    static func trimSilence(_ x: [Float], frame: Int = 480, thresholdDb: Float = -45, padFrames: Int = 6) -> (audio: [Float], speechSeconds: Double) {
        guard x.count > frame else { return ([], 0) }
        let n = x.count / frame
        var voiced = 0
        var first: Int?
        var last: Int?
        for i in 0 ..< n {
            var s: Float = 0
            for j in i * frame ..< (i + 1) * frame { s += x[j] * x[j] }
            if 10 * log10(max(s / Float(frame), 1e-12)) > thresholdDb {
                voiced += 1
                if first == nil { first = i }
                last = i
            }
        }
        guard let first, let last else { return ([], 0) }
        let a = max(0, first - padFrames) * frame
        let b = min(n, last + 1 + padFrames) * frame
        return (Array(x[a ..< b]), Double(voiced * frame) / 16_000)
    }

    /// Écrit un WAV 16 kHz mono 16 bits.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }
}
