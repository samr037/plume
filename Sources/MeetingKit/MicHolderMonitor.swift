import AppKit
import CoreAudio
import Foundation

/// Process audio vu par CoreAudio (`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+), rattaché à son app.
public struct AudioProcessInfo: Equatable, Hashable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    /// Bundle ID du process (ou chemin de l'exécutable s'il n'en a pas).
    public var bundleID: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
    /// App parente : un helper Chrome ou `com.apple.WebKit.GPU` est rattaché au navigateur.
    public var appPID: pid_t
    public var appBundleID: String
    public var appName: String
}

/// Process qui tient le micro.
public struct MicHolder: Equatable, Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var appPID: pid_t
    public var appBundleID: String
    public var appName: String
    public var processObjectID: AudioObjectID

    public init(pid: pid_t, bundleID: String, appPID: pid_t, appBundleID: String, appName: String, processObjectID: AudioObjectID = 0) {
        self.pid = pid; self.bundleID = bundleID; self.appPID = appPID
        self.appBundleID = appBundleID; self.appName = appName; self.processObjectID = processObjectID
    }
}

/// Surveille les détenteurs du micro.
/// Listeners CoreAudio sur la liste des process et sur chaque `IsRunningInput`, plus un sondage de sécurité à 500 ms.
public final class MicHolderMonitor {
    /// Appelé sur le main thread quand la liste change.
    public var onChange: (([MicHolder]) -> Void)?
    /// Dernière liste connue (main thread).
    public private(set) var holders: [MicHolder] = []

    private let queue = DispatchQueue(label: "wl.mic-holders")
    private var timer: DispatchSourceTimer?
    private var listened: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenedIDs: Set<AudioObjectID> = []
    private var last: [MicHolder] = []
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 0.5) { self.pollInterval = pollInterval }

    deinit { stop() }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            addListener(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyProcessObjectList))
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.refresh() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            for (id, addr, block) in listened {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
            }
            listened.removeAll(); listenedIDs.removeAll(); last.removeAll()
        }
    }

    private func addListener(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr {
            listened.append((id, address, block))
            listenedIDs.insert(id)
        }
    }

    /// Sur `queue`.
    private func refresh() {
        guard timer != nil else { return }
        let procs = Self.audioProcesses()
        for p in procs where !listenedIDs.contains(p.objectID) {
            addListener(p.objectID, Self.address(kAudioProcessPropertyIsRunningInput))
        }
        // Process disparus : on retire leurs listeners (sinon fuite sur des jours d'exécution).
        let alive = Set(procs.map(\.objectID)).union([AudioObjectID(kAudioObjectSystemObject)])
        if listenedIDs.contains(where: { !alive.contains($0) }) {
            listened.removeAll { entry in
                let (id, addr, block) = entry
                guard !alive.contains(id) else { return false }
                var a = addr
                AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
                return true
            }
            listenedIDs.formIntersection(alive)
        }
        let now = Self.holders(from: procs)
        guard now != last else { return }
        last = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.holders = now
            self.onChange?(now)
        }
    }

    // MARK: Lecture CoreAudio (sans état, utilisable partout)

    /// Détenteurs du micro à l'instant, notre propre process exclu. Tri stable par app.
    public static func snapshot() -> [MicHolder] { holders(from: audioProcesses()) }

    static func holders(from procs: [AudioProcessInfo]) -> [MicHolder] {
        let me = getpid()
        return procs.filter { $0.isRunningInput && $0.pid != me && $0.appPID != me }
            .map { MicHolder(pid: $0.pid, bundleID: $0.bundleID, appPID: $0.appPID, appBundleID: $0.appBundleID,
                             appName: $0.appName, processObjectID: $0.objectID) }
            .sorted { ($0.appBundleID, $0.pid) < ($1.appBundleID, $1.pid) }
    }

    /// Tous les process audio connus du HAL (vide avant macOS 14.2).
    public static func audioProcesses() -> [AudioProcessInfo] {
        let ids: [AudioObjectID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.compactMap { id in
            guard let pid: pid_t = read(id, kAudioProcessPropertyPID), pid > 0 else { return nil }
            let bid = readString(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 } ?? executablePath(pid) ?? "pid:\(pid)"
            let input: UInt32 = read(id, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = read(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            let app = parentApp(of: pid)
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bid, isRunningInput: input != 0, isRunningOutput: output != 0,
                                    appPID: app?.pid ?? pid, appBundleID: app?.bundleID ?? bid, appName: app?.name ?? displayName(bid))
        }
    }

    /// Objet process CoreAudio d'un PID (0 s'il n'a encore jamais fait d'audio).
    public static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var out = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &out)
        return st == noErr ? out : 0
    }

    // MARK: Rattachement helper → app

    /// App « visible » responsable d'un process : responsabilité TCC, puis `.app` le plus externe du chemin, puis le process lui-même.
    static func parentApp(of pid: pid_t) -> (pid: pid_t, bundleID: String, name: String)? {
        if let rp = responsiblePID(pid), rp != pid, let app = NSRunningApplication(processIdentifier: rp), let bid = app.bundleIdentifier {
            return (rp, bid, app.localizedName ?? displayName(bid))
        }
        if let path = executablePath(pid), let appURL = outermostApp(path) {
            let bundle = Bundle(url: appURL)
            if let bid = bundle?.bundleIdentifier {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
                let name = running?.localizedName ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? appURL.deletingPathExtension().lastPathComponent
                return (running?.processIdentifier ?? pid, bid, name)
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
            return (pid, bid, app.localizedName ?? displayName(bid))
        }
        return nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// SPI `responsibility_get_pid_responsible_for_pid` (libsystem) : process « responsable » au sens TCC.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// `/Applications/Google Chrome.app/…/Google Chrome Helper.app/Contents/MacOS/x` → `/Applications/Google Chrome.app`.
    static func outermostApp(_ path: String) -> URL? {
        guard let r = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
    }

    static func displayName(_ bundleIDOrPath: String) -> String {
        if bundleIDOrPath.hasPrefix("/") { return (bundleIDOrPath as NSString).lastPathComponent }
        return bundleIDOrPath.split(separator: ".").last.map(String.init) ?? bundleIDOrPath
    }

    // MARK: Helpers HAL

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.load(as: T.self)
    }

    static func readArray<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buf, n in
            n = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!) == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
