import AppKit
import Foundation
import MeetingKit

// Sonde de MeetingKit : détenteurs du micro, détection de réunion, capture micro + son système.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: wl-meeting-probe --holders [--seconds N]        détenteurs du micro chaque seconde
       wl-meeting-probe --processes                    tous les process audio CoreAudio
       wl-meeting-probe --detect [--seconds N]         détection de réunion (début/fin)
       wl-meeting-probe --tab <pid>                    onglet actif + onglets de réunion (AX)
       wl-meeting-probe --record <dir> --seconds N [--pid P]   enregistre micro + système
"""

let args = CommandLine.arguments
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let seconds = Double(value("--seconds") ?? "") ?? 10

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func describe(_ h: MicHolder) -> String {
    let plat = MeetingCatalog.platform(forBundleID: h.appBundleID)?.rawValue ?? "-"
    return "pid=\(h.pid) \(h.bundleID) → app=\(h.appName) [\(h.appBundleID) pid=\(h.appPID)] platform=\(plat)"
}

func run(for duration: Double) {
    if duration > 0 { RunLoop.main.run(until: Date().addingTimeInterval(duration)) } else { RunLoop.main.run() }
}

_ = NSApplication.shared // NSRunningApplication/AX fonctionnent mieux avec une connexion au WindowServer

if args.contains("--processes") {
    for p in MicHolderMonitor.audioProcesses() {
        print("obj=\(p.objectID) pid=\(p.pid) in=\(p.isRunningInput ? 1 : 0) out=\(p.isRunningOutput ? 1 : 0) \(p.bundleID) → \(p.appName) [\(p.appBundleID)]")
    }
} else if args.contains("--holders") {
    let monitor = MicHolderMonitor()
    monitor.onChange = { print("[\(stamp())] change: \($0.count) holder(s)") }
    monitor.start()
    var tick = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        tick += 1
        let hs = monitor.holders
        print("[\(stamp())] t=\(tick)s holders=\(hs.count)")
        for h in hs { print("    " + describe(h)) }
    }
    run(for: seconds + 0.2)
    timer.invalidate()
    monitor.stop()
} else if args.contains("--detect") {
    let detector = MeetingDetector()
    var lastHolders: [MicHolder] = []
    detector.onHoldersObserved = { hs, _ in
        guard hs != lastHolders else { return }
        lastHolders = hs
        print("[\(stamp())] holders: " + (hs.isEmpty ? "(aucun)" : hs.map { "\($0.appName)/\($0.pid)" }.joined(separator: ", ")))
    }
    detector.onMeetingStarted = { c in
        print("[\(stamp())] MEETING STARTED \(c.platform.displayName) app=\(c.appName) [\(c.appBundleID)] pid=\(c.pid) url=\(c.url ?? "-") title=\(c.title ?? "-")")
    }
    detector.onMeetingEnded = { c, reason in print("[\(stamp())] MEETING ENDED \(c.appName) reason=\(reason)") }
    print("AX trusted: \(AXIsProcessTrusted())  (onglets navigateur illisibles sans Accessibilité)")
    detector.start()
    run(for: value("--seconds") == nil ? 0 : seconds)
    detector.stop()
} else if let pidStr = value("--tab"), let pid = pid_t(pidStr) {
    print("AX trusted: \(AXIsProcessTrusted())")
    let tab = BrowserTabReader.activeTab(pid: pid)
    print("active url=\(tab.url ?? "-") title=\(tab.title ?? "-")")
    print("platform(url)=\(tab.url.flatMap(MeetingCatalog.platform(forURL:))?.rawValue ?? "-")")
    print("tabs=\(BrowserTabReader.tabTitles(pid: pid))")
    print("meeting tabs=\(BrowserTabReader.meetingTabTitles(pid: pid))")
} else if let dir = value("--record") {
    let url = URL(fileURLWithPath: dir)
    let capture = MeetingAudioCapture(directory: url)
    let lock = NSLock()
    var mic: [Float] = [], sys: [Float] = []
    capture.onMicSamples = { s in lock.lock(); mic += s; lock.unlock() }
    capture.onSystemSamples = { s in lock.lock(); sys += s; lock.unlock() }
    func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
    print("permission audio système (TCC preflight): \(MeetingAudioCapture.systemAudioPermission())")
    let pids = value("--pid").flatMap { pid_t($0) }.map { [$0] } ?? []
    do {
        try capture.start(targetPIDs: pids)
    } catch {
        print("ÉCHEC start: \(error.localizedDescription)")
        exit(1)
    }
    print("tap: \(capture.isPerProcessTap ? "par process \(pids)" : "global (sauf nous)")")
    var second = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        second += 1
        lock.lock(); let m = mic, s = sys; mic.removeAll(); sys.removeAll(); lock.unlock()
        print(String(format: "t=%2ds  mic: %5d éch. rms=%.5f   system: %5d éch. rms=%.5f", second, m.count, rms(m), s.count, rms(s)))
    }
    run(for: seconds + 0.05)
    timer.invalidate()
    capture.stop()
    print("signal système non nul vu: \(capture.systemHasSignal)")
    for f in [capture.micURL, capture.systemURL] {
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let pcm = MeetingAudioCapture.readPCM(url: f)
        print(String(format: "%@: %d octets = %.2f s, rms global=%.5f", f.lastPathComponent, size, Double(pcm.count) / 16_000, rms(pcm)))
    }
} else {
    print(usage)
    exit(2)
}
