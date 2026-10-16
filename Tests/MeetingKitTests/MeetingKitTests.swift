import Foundation
import Testing
@testable import MeetingKit

@Suite struct CatalogTests {
    @Test func bundleIDs() {
        #expect(MeetingCatalog.platform(forBundleID: "us.zoom.xos") == .zoom)
        #expect(MeetingCatalog.platform(forBundleID: "com.microsoft.teams2") == .teams)
        #expect(MeetingCatalog.platform(forBundleID: "com.microsoft.teams2.modulehost") == .teams)
        #expect(MeetingCatalog.platform(forBundleID: "com.apple.FaceTime") == .facetime)
        #expect(MeetingCatalog.platform(forBundleID: "com.apple.avconferenced") == .facetime)
        #expect(MeetingCatalog.platform(forBundleID: "com.hnc.Discord.helper.Renderer") == .discord)
        #expect(MeetingCatalog.platform(forBundleID: "com.tinyspeck.slackmacgap.helper") == .slack)
        #expect(MeetingCatalog.platform(forBundleID: "com.google.Chrome.helper") == .browser)
        #expect(MeetingCatalog.platform(forBundleID: "com.apple.WebKit.GPU") == .browser)
        #expect(MeetingCatalog.platform(forBundleID: "company.thebrowser.Browser") == .browser)
        #expect(MeetingCatalog.platform(forBundleID: "com.googlecode.iterm2") == nil)
        #expect(MeetingCatalog.platform(forBundleID: "us.zoomed.app") == nil) // pas de faux préfixe
        #expect(MeetingCatalog.isChromium(bundleID: "com.google.Chrome"))
        #expect(!MeetingCatalog.isChromium(bundleID: "com.apple.Safari"))
    }

    @Test func urls() {
        #expect(MeetingCatalog.platform(forURL: "https://meet.google.com/abc-defg-hij?authuser=0") == .meet)
        #expect(MeetingCatalog.platform(forURL: "meet.google.com/abc-defg-hij") == .meet)
        #expect(MeetingCatalog.platform(forURL: "https://meet.google.com/landing") == nil)
        #expect(MeetingCatalog.platform(forURL: "https://us02web.zoom.us/j/81234567890?pwd=x") == .zoom)
        #expect(MeetingCatalog.platform(forURL: "https://app.zoom.us/wc/81234567890/join") == .zoom)
        #expect(MeetingCatalog.platform(forURL: "https://zoom.us/pricing") == nil)
        #expect(MeetingCatalog.platform(forURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x") == .teams)
        #expect(MeetingCatalog.platform(forURL: "https://teams.live.com/meet/9381234") == .teams)
        #expect(MeetingCatalog.platform(forURL: "https://acme.webex.com/meet/jdoe") == .webex)
        #expect(MeetingCatalog.platform(forURL: "https://acme.webex.com/acme/j.php?MTID=m1") == .webex)
        #expect(MeetingCatalog.platform(forURL: "https://whereby.com/team-standup") == .other)
        #expect(MeetingCatalog.platform(forURL: "https://app.slack.com/huddle/T123/C456") == .slack)
        #expect(MeetingCatalog.platform(forURL: "https://github.com/meet.google.com/abc-defg-hij") == nil)
        #expect(MeetingCatalog.meetingCode(forURL: "https://meet.google.com/ABC-defg-hij") == "abc-defg-hij")
        #expect(MeetingCatalog.meetingCode(forURL: "https://zoom.us/j/81234567890") == "81234567890")
    }

    @Test func titles() {
        #expect(MeetingCatalog.platform(forTitle: "Meet - abc-defg-hij") == .meet)
        #expect(MeetingCatalog.platform(forTitle: "Meet – Point hebdo") == .meet)
        #expect(MeetingCatalog.platform(forTitle: "Meeting notes - Google Docs") == nil)
        #expect(MeetingCatalog.platform(forTitle: "Weekly sync | Microsoft Teams") == .teams)
        #expect(MeetingCatalog.platform(forTitle: "Zoom Meeting") == .zoom)
        #expect(MeetingCatalog.platform(forTitle: "Huddle: #general") == .slack)
        #expect(MeetingCatalog.isSlackHuddleTitle("Slack 🎤 general"))
        #expect(MeetingCatalog.hasRecordingMarker("Daily - Camera and microphone recording"))
        #expect(MeetingCatalog.isMeetingTitle("Jitsi daily - Microphone recording"))
        #expect(!MeetingCatalog.isMeetingTitle("YouTube - Audio playing"))
    }
}

@Suite struct DetectionMachineTests {
    let zoom = MeetingCandidate(platform: .zoom, appBundleID: "us.zoom.xos", pid: 100, appName: "Zoom")
    let meet = MeetingCandidate(platform: .meet, appBundleID: "com.google.Chrome", pid: 200, appName: "Chrome",
                                url: "https://meet.google.com/abc-defg-hij")

    @Test func startsAfterTwoSecondsOfContinuousHold() {
        var m = MeetingDetectionMachine()
        #expect(m.update([zoom], now: 0).isEmpty)
        #expect(m.tick(now: 1.5).isEmpty)
        #expect(m.tick(now: 2.0) == [.started(zoom)])
        #expect(m.current == zoom)
        #expect(m.tick(now: 3).isEmpty) // une seule fois
    }

    @Test func interruptedHoldRestartsTheClock() {
        var m = MeetingDetectionMachine()
        _ = m.update([zoom], now: 0)
        _ = m.update([], now: 1.5)
        #expect(m.update([zoom], now: 1.6).isEmpty)
        #expect(m.tick(now: 3.5).isEmpty)
        #expect(m.tick(now: 3.6) == [.started(zoom)])
    }

    @Test func endsAfterGraceAndTwoConfirmations() {
        var m = MeetingDetectionMachine()
        _ = m.update([zoom], now: 0); _ = m.tick(now: 2)
        #expect(m.update([], now: 10).isEmpty) // relâché
        #expect(m.tick(now: 14.9).isEmpty) // grâce
        #expect(m.tick(now: 15.0).isEmpty) // 1ʳᵉ confirmation
        #expect(m.tick(now: 15.5).isEmpty) // trop tôt pour la 2ᵉ
        #expect(m.tick(now: 16.0) == [.ended(zoom, reason: "mic_released")])
        #expect(m.current == nil)
    }

    @Test func reacquireDuringGraceKeepsMeeting() {
        var m = MeetingDetectionMachine()
        _ = m.update([zoom], now: 0); _ = m.tick(now: 2)
        _ = m.update([], now: 10)
        _ = m.tick(now: 15) // 1 confirmation
        #expect(m.update([zoom], now: 15.4).isEmpty) // le micro revient
        _ = m.update([], now: 20)
        #expect(m.tick(now: 25.5).isEmpty)
        #expect(m.tick(now: 26.5) == [.ended(zoom, reason: "mic_released")])
    }

    @Test func otherAppHoldingDoesNotKeepTrackedMeetingAlive() {
        var m = MeetingDetectionMachine()
        _ = m.update([zoom], now: 0); _ = m.tick(now: 2)
        _ = m.update([meet], now: 5) // Zoom relâche, Meet prend le micro
        _ = m.tick(now: 10)
        #expect(m.tick(now: 11) == [.ended(zoom, reason: "mic_released")])
        #expect(m.tick(now: 11.5).isEmpty) // Meet repart de zéro
        #expect(m.tick(now: 13.5) == [.started(meet)])
    }

    @Test func nativeAppWinsTieOverBrowser() {
        var m = MeetingDetectionMachine()
        _ = m.update([meet, zoom], now: 0)
        #expect(m.tick(now: 2) == [.started(zoom)])
    }

    @Test func refreshesURLWhileHeld() {
        var m = MeetingDetectionMachine()
        var noURL = meet; noURL.url = nil
        _ = m.update([noURL], now: 0); _ = m.tick(now: 2)
        _ = m.update([meet], now: 3)
        #expect(m.current?.url == meet.url)
    }

    @Test func suppressionBlocksRedetectionAndDropsCurrent() {
        var m = MeetingDetectionMachine()
        _ = m.update([zoom], now: 0); _ = m.tick(now: 2)
        m.suppress(bundleID: zoom.appBundleID, until: 62)
        #expect(m.current == nil)
        #expect(m.tick(now: 30).isEmpty)
        #expect(m.update([], now: 31).isEmpty) // pas de `ended` pour une réunion refusée
        _ = m.update([zoom], now: 40)
        #expect(m.tick(now: 61).isEmpty)
        _ = m.tick(now: 62) // fin de suppression : l'horloge repart
        #expect(m.tick(now: 63.9).isEmpty)
        #expect(m.tick(now: 64) == [.started(zoom)])
    }
}

@Suite struct PCMTests {
    @Test func readPCMRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: url) }
        let x: [Float] = [0, 0.5, -0.25, 1]
        var data = x.withUnsafeBufferPointer { Data(buffer: $0) }
        data.append(0x7F) // octet tronqué (crash en cours d'écriture)
        try data.write(to: url)
        #expect(MeetingAudioCapture.readPCM(url: url) == x)
    }

    @Test func outermostApp() {
        let p = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(MicHolderMonitor.outermostApp(p)?.path == "/Applications/Google Chrome.app")
        #expect(MicHolderMonitor.outermostApp("/usr/libexec/avconferenced") == nil)
    }
}
