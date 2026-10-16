import AVFoundation
import CoreAudio
import Foundation

public enum MeetingAudioError: Error, LocalizedError {
    case microphoneDenied
    case noMicrophone(String)
    case systemAudioUnsupported
    case systemAudioDenied
    case coreAudio(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Accès au micro refusé (Réglages Système › Confidentialité et sécurité › Micro)."
        case .noMicrophone(let f):
            "Aucun micro utilisable (\(f))."
        case .systemAudioUnsupported:
            "La capture du son système exige macOS 14.2 ou plus récent."
        case .systemAudioDenied:
            "Capture du son système refusée (Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système › Audio système uniquement). Relancer l'app après l'autorisation."
        case .coreAudio(let what, let st):
            "\(what) a échoué (OSStatus \(st) '\(fourCC(st))'). Si la permission « Audio système » vient d'être accordée, relancer l'app."
        }
    }
}

private func fourCC(_ st: OSStatus) -> String {
    let u = UInt32(bitPattern: st)
    let bytes = [24, 16, 8, 0].map { UInt8((u >> $0) & 0xFF) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : "\(st)"
}

/// Enregistre deux flux 16 kHz mono Float32 : micro (AVAudioEngine) et son système (process tap CoreAudio).
/// Le PCM brut est ajouté au fil de l'eau dans `mic.f32` / `system.f32` (récupérable après un crash).
public final class MeetingAudioCapture {
    public enum SystemAudioPermission: Sendable { case granted, denied, undetermined, unknown }

    /// Échantillons micro, ~200 ms par appel, sur une file d'arrière-plan.
    public var onMicSamples: (([Float]) -> Void)?
    /// Échantillons son système, ~200 ms par appel, sur une file d'arrière-plan.
    public var onSystemSamples: (([Float]) -> Void)?
    /// Niveaux normalisés 0…1 (micro, système), main thread, ~10×/s.
    public var onLevels: ((Float, Float) -> Void)?
    /// Événements notables (changement de périphérique, relance), main thread, pour le journal.
    public var onEvent: ((String) -> Void)?

    public let directory: URL
    public var micURL: URL { directory.appendingPathComponent("mic.f32") }
    public var systemURL: URL { directory.appendingPathComponent("system.f32") }
    /// Vrai dès qu'un échantillon système non nul est arrivé (un flux tout à zéro = permission refusée en silence).
    public private(set) var systemHasSignal = false
    /// `true` si le tap vise des process précis, `false` pour un tap global (tout sauf nous).
    public private(set) var isPerProcessTap = false

    static let sampleRate: Double = 16_000
    static let chunkSamples = 3_200 // 200 ms
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private var micStream: Stream?
    private var sysStream: Stream?
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "wl.meeting-tap", qos: .userInitiated)
    private let levelLock = NSLock()
    private var levels: (Float, Float) = (0, 0)
    private var levelTimer: Timer?
    /// Début de la capture : sert à combler par du silence les trous laissés par une relance (horloges micro/système alignées).
    private var startedAt = Date()
    private var micObserver: NSObjectProtocol?
    private var micRetries = 0
    private var micRestartPending = false
    private var tapUUID: UUID?
    /// Liste de tampons réduite aux flux du tap (l'agrégat peut aussi exposer les entrées de la sortie, ex. AirPods en HFP).
    private var tapScratch: UnsafeMutableAudioBufferListPointer?
    private var clockDevice = AudioObjectID(0)
    private var clockUID: String?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var sysRetries = 0
    private var sysRebuildPending = false

    public init(directory: URL) { self.directory = directory }

    deinit { stop() }

    // MARK: Cycle de vie

    /// Démarre les deux flux. `targetPIDs` : process de l'app de réunion (ses helpers audio sont ajoutés) ; vide = tap global.
    public func start(targetPIDs: [pid_t]) throws {
        stop()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mic = try Stream(url: micURL, target: target) { [weak self] in self?.onMicSamples?($0) } level: { [weak self] l in self?.setLevel(mic: l) }
        let sys = try Stream(url: systemURL, target: target) { [weak self] in self?.onSystemSamples?($0) } level: { [weak self] l in self?.setLevel(system: l) }
        micStream = mic; sysStream = sys
        startedAt = Date()
        micRetries = 0; sysRetries = 0
        do {
            try startSystem(targetPIDs: targetPIDs, stream: sys)
            try startMic(stream: mic)
        } catch {
            stop()
            throw error
        }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.levelLock.lock(); let l = self.levels; self.levelLock.unlock()
            self.onLevels?(l.0, l.1)
        }
    }

    /// Arrête et libère tout (IOProc, agrégat, tap, moteur), vide les tampons sur disque.
    public func stop() {
        levelTimer?.invalidate(); levelTimer = nil
        micRestartPending = false; sysRebuildPending = false
        stopMicEngine()
        if let block = defaultOutputListener {
            var addr = MicHolderMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
        defaultOutputListener = nil
        teardownAggregate()
        if tapID != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0; tapUUID = nil
        micStream?.close(); sysStream?.close()
        micStream = nil; sysStream = nil
    }

    private func stopMicEngine() {
        if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
        micObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Arrête l'IOProc, détruit l'agrégat (le tap est conservé) et attend la fin du dernier bloc IO.
    private func teardownAggregate() {
        if let block = aliveListener, clockDevice != 0 {
            var addr = MicHolderMonitor.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(clockDevice, &addr, .main, block)
        }
        aliveListener = nil; clockDevice = 0; clockUID = nil
        if aggregateID != 0 {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil; aggregateID = 0
        ioQueue.sync {} // dernier bloc IO terminé
        if let tapScratch { free(tapScratch.unsafeMutablePointer) }
        tapScratch = nil
    }

    /// Secondes écoulées depuis le début de la capture (pour combler un trou par du silence).
    private var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    // MARK: Micro

    private func startMic(stream: Stream) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw MeetingAudioError.microphoneDenied
        default: break
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingAudioError.noMicrophone("\(format)") }
        try stream.prepare(input: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in stream.push(buf) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // Branchement/débranchement d'un casque, AirPods… : AVAudioEngine s'arrête de lui-même, on le relance.
        micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleMicRestart(after: 0.3)
        }
    }

    /// Main thread. Relance le moteur micro avec le nouveau format d'entrée (le convertisseur du flux est refait).
    private func scheduleMicRestart(after delay: TimeInterval) {
        guard micStream != nil, !micRestartPending else { return }
        micRestartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.micRestartPending else { return }
            self.micRestartPending = false
            self.restartMic()
        }
    }

    private func restartMic() {
        guard let mic = micStream else { return }
        stopMicEngine()
        mic.pad(toSeconds: elapsed)
        do {
            try startMic(stream: mic)
            micRetries = 0
            onEvent?("Micro : changement de périphérique audio, capture relancée")
        } catch {
            micRetries += 1
            if micRetries <= 10 {
                onEvent?("Micro indisponible après changement de périphérique (\(error.localizedDescription)), nouvel essai")
                scheduleMicRestart(after: 1)
            } else {
                onEvent?("Micro perdu après changement de périphérique : \(error.localizedDescription)")
            }
        }
    }

    // MARK: Son système (process tap)

    private func startSystem(targetPIDs: [pid_t], stream: Stream) throws {
        guard #available(macOS 14.2, *) else { throw MeetingAudioError.systemAudioUnsupported }
        if Self.systemAudioPermission() == .denied { throw MeetingAudioError.systemAudioDenied }

        // Tap ciblé sur l'app de réunion et ses helpers (évite Spotify & co), sinon global moins nous-mêmes.
        let wanted = Set(targetPIDs)
        let objects = wanted.isEmpty ? [] : MicHolderMonitor.audioProcesses()
            .filter { wanted.contains($0.pid) || wanted.contains($0.appPID) }.map(\.objectID)
        let desc: CATapDescription
        if objects.isEmpty {
            let me = MicHolderMonitor.processObject(for: getpid())
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == 0 ? [] : [me])
            isPerProcessTap = false
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: objects)
            isPerProcessTap = true
        }
        desc.name = "Plume meeting tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(0)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != 0 else { throw MeetingAudioError.coreAudio("AudioHardwareCreateProcessTap", st) }
        tapID = tap
        tapUUID = desc.uuid

        try buildAggregate(stream: stream)

        // Sortie par défaut changée (AirPods, casque, écran…) : l'agrégat est recréé sur la nouvelle horloge.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSystemRebuild(after: 0.3) }
        var addr = MicHolderMonitor.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            defaultOutputListener = block
        }
    }

    /// Agrégat privé autour du tap existant : horloge = sortie par défaut, entrée = le tap. Relit le format du tap.
    @available(macOS 14.2, *)
    private func buildAggregate(stream: Stream) throws {
        guard tapID != 0, let tapUUID else { throw MeetingAudioError.systemAudioUnsupported }
        var asbd = AudioStreamBasicDescription()
        var addr = MicHolderMonitor.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard st == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else { throw MeetingAudioError.coreAudio("Lecture du format du tap", st) }
        try stream.prepare(input: tapFormat)

        let outputDevice = Self.defaultOutputDevice()
        let outputUID = outputDevice.flatMap { MicHolderMonitor.readString($0, kAudioDevicePropertyDeviceUID) }
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Plume-Tap",
            kAudioAggregateDeviceUIDKey: "wl.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let outputUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr, agg != 0 else { throw MeetingAudioError.coreAudio("AudioHardwareCreateAggregateDevice", st) }
        aggregateID = agg

        // Les flux d'entrée des sous-périphériques (micro d'un casque USB, AirPods en HFP) précèdent ceux du tap
        // dans la liste de l'agrégat : on ne garde que les derniers tampons, ceux du tap.
        let tapBuffers = tapFormat.isInterleaved ? 1 : Int(tapFormat.channelCount)
        let scratch = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        tapScratch = scratch
        let channelsPerBuffer: UInt32 = tapFormat.isInterleaved ? tapFormat.channelCount : 1
        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let n = all.count
            guard n >= tapBuffers else { return }
            let list: UnsafePointer<AudioBufferList>
            if n == tapBuffers {
                list = input
            } else {
                for i in 0 ..< tapBuffers { scratch[i] = all[n - tapBuffers + i] }
                list = UnsafePointer(scratch.unsafeMutablePointer)
            }
            // Garde-fou : un tampon dont le nombre de canaux ne correspond pas au tap n'est pas le tap.
            if let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)).first,
               first.mNumberChannels != 0, first.mNumberChannels != channelsPerBuffer { return }
            guard let buf = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: list, deallocator: nil) else { return }
            if let self, !self.systemHasSignal, Self.hasSignal(buf) { self.systemHasSignal = true }
            stream.push(buf)
        }
        guard st == noErr, let proc else { throw MeetingAudioError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", st) }
        ioProcID = proc
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else { throw MeetingAudioError.coreAudio("AudioDeviceStart (tap)", st) }

        // Sortie qui disparaît sans changement de sortie par défaut : même traitement.
        if let outputDevice {
            clockDevice = outputDevice; clockUID = outputUID
            let alive: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.clockDevice != 0 else { return }
                let isAlive: UInt32 = MicHolderMonitor.read(self.clockDevice, kAudioDevicePropertyDeviceIsAlive) ?? 0
                if isAlive == 0 { self.scheduleSystemRebuild(after: 0.3) }
            }
            var a = MicHolderMonitor.address(kAudioDevicePropertyDeviceIsAlive)
            if AudioObjectAddPropertyListenerBlock(outputDevice, &a, .main, alive) == noErr { aliveListener = alive }
        }
    }

    /// Main thread. Recrée l'agrégat (même tap) quand la sortie d'horloge change ou disparaît.
    private func scheduleSystemRebuild(after delay: TimeInterval) {
        guard sysStream != nil, tapID != 0, !sysRebuildPending else { return }
        sysRebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sysRebuildPending else { return }
            self.sysRebuildPending = false
            self.rebuildSystem()
        }
    }

    private func rebuildSystem() {
        guard #available(macOS 14.2, *) else { return }
        guard let sys = sysStream, tapID != 0 else { return }
        let newUID = Self.defaultOutputUID()
        let alive: UInt32 = clockDevice == 0 ? 0 : (MicHolderMonitor.read(clockDevice, kAudioDevicePropertyDeviceIsAlive) ?? 0)
        if aggregateID != 0, newUID == clockUID, alive != 0 { return } // rien n'a changé pour notre horloge
        teardownAggregate()
        sys.pad(toSeconds: elapsed)
        do {
            try buildAggregate(stream: sys)
            sysRetries = 0
            onEvent?("Son système : sortie audio changée (\(newUID ?? "aucune")), capture relancée")
        } catch {
            teardownAggregate()
            sysRetries += 1
            if sysRetries <= 10 {
                onEvent?("Son système indisponible après changement de sortie (\(error.localizedDescription)), nouvel essai")
                scheduleSystemRebuild(after: 1)
            } else {
                onEvent?("Son système perdu après changement de sortie : \(error.localizedDescription)")
            }
        }
    }

    static func hasSignal(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let ch = buf.floatChannelData else { return false }
        for c in 0 ..< Int(buf.format.channelCount) {
            for i in 0 ..< Int(buf.frameLength) where ch[c][i] != 0 { return true }
        }
        return false
    }

    /// Sortie par défaut (celle où joue l'app de réunion), pas la sortie des alertes (`DefaultSystemOutputDevice`).
    static func defaultOutputDevice() -> AudioObjectID? {
        guard let dev: AudioObjectID = MicHolderMonitor.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              dev != 0 else { return nil }
        return dev
    }

    static func defaultOutputUID() -> String? {
        defaultOutputDevice().flatMap { MicHolderMonitor.readString($0, kAudioDevicePropertyDeviceUID) }
    }

    // MARK: Permission TCC « audio système »

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32

    /// État de `kTCCServiceAudioCapture` via la SPI `TCCAccessPreflight` (best effort ; `.unknown` si indisponible).
    /// Il n'existe pas d'API publique : la demande se fait implicitement au premier démarrage du tap.
    public static func systemAudioPermission() -> SystemAudioPermission {
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .undetermined
        default: return .unknown
        }
    }

    // MARK: Niveaux

    private func setLevel(mic: Float? = nil, system: Float? = nil) {
        levelLock.lock()
        if let mic { levels.0 = mic }
        if let system { levels.1 = system }
        levelLock.unlock()
    }

    static func normalizedLevel(_ x: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for v in x { sum += v * v }
        let rms = sqrt(sum / Float(max(x.count, 1)))
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 45, 0), 1) // -55 dB → 0, -10 dB → 1
    }

    // MARK: Relecture

    /// Relit un fichier `.f32` (float32 natif, 16 kHz mono). Un dernier échantillon tronqué est ignoré.
    public static func readPCM(url: URL) -> [Float] {
        // Lecture mappée : une seule copie en mémoire (le fichier système d'une longue réunion dépasse le Go).
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        let n = data.count / MemoryLayout<Float>.size
        return [Float](unsafeUninitializedCapacity: n) { buf, count in
            _ = data.copyBytes(to: buf, count: n * MemoryLayout<Float>.size)
            count = n
        }
    }

    // MARK: Flux (conversion, découpage, fichier)

    /// Un flux : conversion vers 16 kHz mono, tampon de 200 ms, append disque et callback.
    final class Stream {
        private let file: FileHandle
        private let target: AVAudioFormat
        private let onChunk: ([Float]) -> Void
        private let onLevel: (Float) -> Void
        private var converter: AVAudioConverter?
        private var pending: [Float] = []
        /// Échantillons écrits (fichier + callback), pour combler un trou après une relance.
        private var written = 0
        private let lock = NSLock()

        init(url: URL, target: AVAudioFormat, onChunk: @escaping ([Float]) -> Void, level: @escaping (Float) -> Void) throws {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            self.target = target
            self.onChunk = onChunk
            self.onLevel = level
        }

        func prepare(input: AVAudioFormat) throws {
            guard let c = AVAudioConverter(from: input, to: target) else { throw MeetingAudioError.noMicrophone("conversion \(input) impossible") }
            c.downmix = true
            lock.lock(); converter = c; lock.unlock()
        }

        /// Comble par du silence jusqu'à `seconds` depuis le début (au-delà d'une tolérance de 0,5 s),
        /// pour que les horloges micro et système restent alignées après une relance. Flux à l'arrêt uniquement.
        func pad(toSeconds seconds: Double) {
            lock.lock()
            let have = written + pending.count
            let want = Int(seconds * MeetingAudioCapture.sampleRate)
            lock.unlock()
            let missing = want - have
            guard missing > Int(MeetingAudioCapture.sampleRate / 2) else { return }
            lock.lock()
            pending.append(contentsOf: [Float](repeating: 0, count: missing))
            let ready = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            // Par blocs de 200 ms, comme le flux normal.
            var i = 0
            while i < ready.count {
                let j = min(i + MeetingAudioCapture.chunkSamples, ready.count)
                emit(Array(ready[i ..< j]))
                i = j
            }
        }

        /// Appelé depuis le thread audio (tap AVAudioEngine ou IOProc).
        func push(_ buf: AVAudioPCMBuffer) {
            lock.lock(); let converter = self.converter; lock.unlock()
            guard let converter, buf.frameLength > 0 else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 32
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
            onLevel(MeetingAudioCapture.normalizedLevel(chunk))
            lock.lock()
            pending.append(contentsOf: chunk)
            var ready: [Float]?
            if pending.count >= MeetingAudioCapture.chunkSamples { ready = pending; pending.removeAll(keepingCapacity: true) }
            lock.unlock()
            if let ready { emit(ready) }
        }

        private func emit(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { try? file.write(contentsOf: Data(buffer: $0)) }
            lock.lock(); written += samples.count; lock.unlock()
            onChunk(samples)
        }

        func close() {
            lock.lock(); let rest = pending; pending.removeAll(); lock.unlock()
            if !rest.isEmpty { emit(rest) }
            try? file.synchronize()
            try? file.close()
        }
    }
}
