// The checklist «Перед звонком»: the sheet's state model (Checklist.items) maps the facts to rows, marks and
// texts; the call's red banner (ListenerWarning) follows the listener row; the listener check groups the
// readers as the live HAL showed them on 2026-10-13.
import Foundation
import PonteCore
import Testing
@testable import PonteApp
@testable import PonteAudio

@Suite("Checklist «Перед звонком»") struct ChecklistTests {
    private func facts(_ status: Int32, app: String? = "BrowserOS (Meet)", device: String? = "BlackHole 2ch",
                       kind: Int = AudioRules.kindBlackHole, headphones: Bool = false, mic: Int32 = AppRules.MICSRC_AUTO) -> ChecklistFacts {
        ChecklistFacts(listenStatus: status, listenAppName: app, listenDeviceName: device, listenDeviceKind: kind,
                       listeningName: headphones ? "AirPods Pro" : "MacBook Pro Speakers", headphonesLike: headphones,
                       micName: "MacBook Pro Microphone", micSource: mic, pttKeyShort: PTTKey.rightOption.short)
    }

    @Test func rowsInOrderWithReminders() {
        let items = Checklist.items(facts(AppRules.LISTEN_OK))
        #expect(items.map(\.id) == Array(0..<AppRules.CKI_COUNT))
        #expect(items.map(\.title) == ["Meet слушает BlackHole", "Микрофон в Meet включён", "Наушники", "Ваш микрофон для Ponte",
                                       "Переводчики в браузере выключены", "Как говорить"])
        for id in [AppRules.CKI_CALL_MIC, AppRules.CKI_EXTENSIONS, AppRules.CKI_HOW_TO_TALK] {
            #expect(items[Int(id)].mark == .info)
        }
        #expect(items[Int(AppRules.CKI_CALL_MIC)].detail.hasPrefix("Не выключайте микрофон в Meet"))
        #expect(items[Int(AppRules.CKI_EXTENSIONS)].detail.contains("MeetVoice"))
        #expect(items[Int(AppRules.CKI_HOW_TO_TALK)].detail
            == "Зажмите зелёную полосу или правый ⌥, скажите фразу по-русски, отпустите — Meet услышит португальский.")
    }

    @Test func listenerRowFollowsTheStatus() {
        let ok = Checklist.items(facts(AppRules.LISTEN_OK))[0]
        #expect(ok.mark == .ok)
        #expect(ok.detail == "BrowserOS (Meet) берёт звук из BlackHole.")

        let nobody = Checklist.items(facts(AppRules.LISTEN_NOBODY, app: nil, device: nil))[0]
        #expect(nobody.mark == .bad)
        #expect(nobody.detail == "Звонилка не слушает BlackHole: в Meet откройте ⋮ → Настройки → Аудио → Микрофон и выберите «BlackHole 2ch».")

        let realMic = Checklist.items(facts(AppRules.LISTEN_REAL_MIC, device: "MacBook Pro Microphone", kind: AudioRules.kindBuiltInMic))[0]
        #expect(realMic.mark == .bad)
        #expect(realMic.detail == "BrowserOS (Meet) слушает микрофон MacBook — собеседники слышат ваш русский голос. Выберите «BlackHole 2ch».")

        let usb = Checklist.items(facts(AppRules.LISTEN_REAL_MIC, device: "USB Audio", kind: AudioRules.kindUSB))[0]
        #expect(usb.detail.contains("микрофон «USB Audio»"))

        let both = Checklist.items(facts(AppRules.LISTEN_BOTH, device: "MacBook Pro Microphone", kind: AudioRules.kindBuiltInMic))[0]
        #expect(both.mark == .warn)
        #expect(both.detail.contains("и BlackHole, и микрофон MacBook"))

        let missing = Checklist.items(facts(AppRules.LISTEN_NO_BLACKHOLE, app: nil, device: nil))[0]
        #expect(missing.mark == .bad)
        #expect(missing.detail.contains(BlackHoleCheck.installCommand))

        #expect(Checklist.items(facts(AppRules.LISTEN_UNKNOWN))[0].mark == .unknown)
        // The banner during a call says what the row says.
        #expect(Checklist.listenerText(facts(AppRules.LISTEN_NOBODY)) == nobody.detail)
    }

    @Test func headphonesAndMicrophoneRows() {
        let with = Checklist.items(facts(AppRules.LISTEN_OK, headphones: true))
        #expect(with[Int(AppRules.CKI_HEADPHONES)].mark == .ok)
        #expect(with[Int(AppRules.CKI_HEADPHONES)].detail == "Наушники: AirPods Pro. В Meet выберите их как «Динамик».")
        let without = Checklist.items(facts(AppRules.LISTEN_OK, headphones: false))
        #expect(without[Int(AppRules.CKI_HEADPHONES)].mark == .warn)
        #expect(without[Int(AppRules.CKI_HEADPHONES)].detail
            == "Наушников нет — собеседники звучат из динамиков. Говорите только с зажатой кнопкой. Ponte слушает микрофон ноутбука.")

        let auto = Checklist.items(facts(AppRules.LISTEN_OK, mic: AppRules.MICSRC_AUTO))[Int(AppRules.CKI_MY_MIC)]
        #expect(auto.mark == .ok)
        #expect(auto.detail.hasPrefix("MacBook Pro Microphone — выбран автоматически."))
        let saved = Checklist.items(facts(AppRules.LISTEN_OK, mic: AppRules.MICSRC_SAVED))[Int(AppRules.CKI_MY_MIC)]
        #expect(saved.mark == .ok)
        #expect(saved.detail == "MacBook Pro Microphone — выбран в настройках.")
        let system = Checklist.items(facts(AppRules.LISTEN_OK, mic: AppRules.MICSRC_SYSTEM))[Int(AppRules.CKI_MY_MIC)]
        #expect(system.mark == .warn)
    }

    @Test func everyStatusMapsToOneMark() {
        let expected: [Int32: ChecklistItem.Mark] = [
            AppRules.LISTEN_UNKNOWN: .unknown, AppRules.LISTEN_OK: .ok, AppRules.LISTEN_NOBODY: .bad,
            AppRules.LISTEN_REAL_MIC: .bad, AppRules.LISTEN_BOTH: .warn, AppRules.LISTEN_NO_BLACKHOLE: .bad,
        ]
        for (status, mark) in expected {
            #expect(Checklist.items(facts(status))[0].mark == mark, "status \(status)")
            #expect(!Checklist.listenerText(facts(status)).isEmpty)
        }
    }

    @Test func listenerBannerDuringACall() {
        var warning = ListenerWarning()
        let start = Date(timeIntervalSince1970: 1_000)
        let running = AppRules.RUN_RUNNING
        let red = AppRules.CK_BAD
        let text = "Звонилка не слушает BlackHole"
        // Red for less than the grace time: nothing yet.
        #expect(warning.banner(after: nil, runState: running, mark: red, now: start) { text } == nil)
        #expect(warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(2.9)) { text } == nil)
        // Past it: a red banner that opens the checklist.
        let shown = warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(3)) { text }
        #expect(shown?.kind == .error)
        #expect(shown?.text == text)
        #expect(shown?.action == .openChecklist)
        // Kept while red; it takes a translation warning's place again.
        #expect(warning.banner(after: shown, runState: running, mark: red, now: start.addingTimeInterval(4)) { text } == shown)
        let other = Banner(kind: .warning, text: "Перевод: …")
        let back = warning.banner(after: other, runState: running, mark: red, now: start.addingTimeInterval(5)) { text }
        #expect(back?.text == text)
        // Closed by the owner: stays down while red, comes back after the row was fine once.
        #expect(warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(6)) { text } == nil)
        #expect(warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(20)) { text } == nil)
        #expect(warning.banner(after: nil, runState: running, mark: AppRules.CK_OK, now: start.addingTimeInterval(21)) { text } == nil)
        #expect(warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(22)) { text } == nil)
        let again = warning.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(25)) { text }
        #expect(again?.text == text)
        // Fixed, or the call stopped: taken down.
        #expect(warning.banner(after: again, runState: running, mark: AppRules.CK_OK, now: start.addingTimeInterval(26)) { text } == nil)
        var stopped = ListenerWarning()
        _ = stopped.banner(after: nil, runState: running, mark: red, now: start) { text }
        let up = stopped.banner(after: nil, runState: running, mark: red, now: start.addingTimeInterval(4)) { text }
        #expect(up != nil)
        #expect(stopped.banner(after: up, runState: AppRules.RUN_IDLE, mark: red, now: start.addingTimeInterval(5)) { text } == nil)
        // Never while Ponte is idle.
        var idle = ListenerWarning()
        _ = idle.banner(after: nil, runState: AppRules.RUN_IDLE, mark: red, now: start) { text }
        #expect(idle.banner(after: nil, runState: AppRules.RUN_IDLE, mark: red, now: start.addingTimeInterval(60)) { text } == nil)
    }

    /// The readers AudioProbe `inputs` showed on 2026-10-13: the installed Ponte reads the MacBook microphone and
    /// BlackHole, BrowserOS's audio helper reads BlackHole.
    @Test func listenerCheckOfTheLiveReaders() {
        func device(_ id: UInt32, _ name: String) -> AudioDevice {
            AudioDevice(id: id, uid: name, name: name, inputChannels: 2, outputChannels: 2)
        }
        let blackHole = device(72, "BlackHole 2ch"), mic = device(97, "MacBook Pro Microphone")
        let ponteBH = AudioInputReader(pid: 41247, bundleID: "app.ponte.translator", ownerBundleID: "app.ponte.translator",
                                       appName: "Ponte", device: blackHole, deviceKind: AudioRules.kindBlackHole, isRunningInput: true)
        let ponteMic = AudioInputReader(pid: 41247, bundleID: "app.ponte.translator", ownerBundleID: "app.ponte.translator",
                                        appName: "Ponte", device: mic, deviceKind: AudioRules.kindBuiltInMic, isRunningInput: true)
        let meet = AudioInputReader(pid: 42603, bundleID: "com.browseros.BrowserClaw.helper", ownerBundleID: "com.browseros.BrowserClaw",
                                    appName: "BrowserOS (Meet)", device: blackHole, deviceKind: AudioRules.kindBlackHole, isRunningInput: true)
        let target = "com.browseros.BrowserClaw"
        let live = AudioInputReaders.check([ponteBH, ponteMic, meet], targetBundleID: target, blackHolePresent: true, selfPID: 1)
        #expect(live.status == AudioRules.listenOK)
        #expect(live.reader == meet)
        // Only Ponte reads BlackHole: nobody listens.
        #expect(AudioInputReaders.check([ponteBH, ponteMic], targetBundleID: target, blackHolePresent: true, selfPID: 1).status
            == AudioRules.listenNobody)
        // Meet fell back to the MacBook microphone (live failure 2026-10-13).
        let fallback = AudioInputReader(pid: 42603, bundleID: "com.browseros.BrowserClaw.helper", ownerBundleID: target,
                                        appName: "BrowserOS (Meet)", device: mic, deviceKind: AudioRules.kindBuiltInMic, isRunningInput: true)
        let bad = AudioInputReaders.check([ponteBH, fallback], targetBundleID: target, blackHolePresent: true, selfPID: 1)
        #expect(bad.status == AudioRules.listenRealMic)
        #expect(bad.reader == fallback)
        #expect(AudioInputReaders.check([fallback, meet], targetBundleID: target, blackHolePresent: true, selfPID: 1).status
            == AudioRules.listenBoth)
        #expect(AudioInputReaders.check(nil, targetBundleID: target, blackHolePresent: true, selfPID: 1).status == AudioRules.listenUnknown)
        #expect(AudioInputReaders.check([meet], targetBundleID: target, blackHolePresent: false, selfPID: 1).status
            == AudioRules.listenNoBlackHole)
    }

    /// The HAL process list is readable on this Mac (no permission is needed to list who reads which input).
    @Test func liveSnapshotIsReadable() {
        #expect(AudioInputReaders.snapshot() != nil)
    }
}
