import Cocoa
import CoreAudio

// "Pause everything" when the user leaves:
//  1. MediaRemote pause (whatever owns Now Playing)
//  2. AppleScript pause for scriptable players (Music, Spotify, QuickTime, VLC, TV, Podcasts)
//  3. JavaScript pause of every <video>/<audio> in every browser tab
//  4. Core Audio: any other app still producing sound gets a Space key (play/pause in almost every player)
//  5. Still sound after that → mute the Mac (optional)

enum Pauser {
    struct AudioProc { let pid: pid_t; let bundle: String }

    /// Processes currently sending audio to an output device (macOS 14+).
    static func audioOutputProcesses() -> [AudioProc] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [AudioProc] = []
        for id in ids {
            var running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            AudioObjectGetPropertyData(id, &a, 0, nil, &ps, &pid)
            var cf: Unmanaged<CFString>?, cs = UInt32(MemoryLayout<CFString?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            AudioObjectGetPropertyData(id, &a, 0, nil, &cs, &cf)
            out.append(AudioProc(pid: pid, bundle: (cf?.takeRetainedValue() as String?) ?? ""))
        }
        return out
    }

    /// Map an audio process (often a helper, e.g. "com.foo.app.helper") to its visible app.
    static func owningApp(_ p: AudioProc) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let a = apps.first(where: { $0.processIdentifier == p.pid }) { return a }
        // helper processes live inside the app bundle (…/X.app/Contents/Frameworks/…)
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(p.pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let a = apps.filter({ $0.bundleURL.map { path.hasPrefix($0.path + "/") } ?? false })
                           .max(by: { ($0.bundleURL?.path.count ?? 0) < ($1.bundleURL?.path.count ?? 0) }) { return a }
        }
        return apps.filter { id in id.bundleIdentifier.map { !p.bundle.isEmpty && p.bundle.hasPrefix($0) } ?? false }
                   .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    /// Players with a real "pause" AppleScript command (never toggles something that's stopped).
    static let scriptable: [String: String] = [
        "com.apple.Music": "tell application id \"com.apple.Music\" to pause",
        "com.spotify.client": "tell application id \"com.spotify.client\" to pause",
        "com.apple.QuickTimePlayerX": "tell application id \"com.apple.QuickTimePlayerX\" to pause every document",
        "org.videolan.vlc": "tell application id \"org.videolan.vlc\" to if playing then play",
        "com.apple.TV": "tell application id \"com.apple.TV\" to pause",
        "com.apple.podcasts": "tell application id \"com.apple.podcasts\" to pause",
    ]
    /// Apps that may make sound but must never get a Space key (calls, chat, terminals, ourselves).
    static let neverKey: Set<String> = [
        "com.tencent.xinWeChat", "ru.keepcoder.Telegram", "com.apple.FaceTime", "us.zoom.xos", "com.tencent.meeting",
        "com.microsoft.teams2", "com.apple.Terminal", "com.googlecode.iterm2", "com.norway.phonenotify",
        "com.apple.ScreenContinuity", "com.apple.mobilephone", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.alibaba.DingTalkMac", "com.electron.lark", "com.bytedance.lark",
        // remote desktops / VMs: a Space would be typed into the remote machine
        "com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.teamviewer.TeamViewer", "com.philandro.anydesk",
        "com.youqu.todesk.mac", "com.oray.sunlogin.macclient", "com.parallels.desktop.console", "com.vmware.fusion",
        "com.utmapp.UTM", "com.realvnc.vncviewer", "com.citrix.receiver.icaviewer.mac"
    ]

    static var keyFallback: Bool { AppModel.shared.pauseByKey }

    /// Pause everything. `done` gets a human-readable report and whether sound is still playing.
    static func pauseAll(done: @escaping (_ report: [String], _ stillSound: Bool) -> Void) {
        var report: [String] = []
        // 1. Now Playing
        if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let sym = dlsym(h, "MRMediaRemoteSendCommand") {
            typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
            _ = unsafeBitCast(sym, to: Send.self)(1 /* kMRPause */, nil)
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        DispatchQueue.global(qos: .userInitiated).async {
            // 2. scriptable players
            for (id, script) in scriptable where running.contains(id) {
                let r = osascript(script)
                report.append("\(appName(id)): " + (r.ok ? "已暂停" : r.denied ? "需要允许 PhoneNotify 控制它" : "未能暂停"))
            }
            // 3. browsers
            let sem = DispatchSemaphore(value: 0)
            SystemControl.pauseBrowsers { report += $0; sem.signal() }
            sem.wait()
            // 4. whoever is still making sound
            Thread.sleep(forTimeInterval: 1.0)
            var keyed = Set<pid_t>()
            for p in audioOutputProcesses() {
                guard let app = owningApp(p), let id = app.bundleIdentifier, !keyed.contains(app.processIdentifier) else { continue }
                if SystemControl.chromiumBrowsers.contains(id) || id == "com.apple.Safari" || scriptable[id] != nil || neverKey.contains(id) { continue }
                guard keyFallback else { report.append("\(app.localizedName ?? id): 仍在出声"); continue }
                keyed.insert(app.processIdentifier)
                sendSpace(to: app.processIdentifier)
                report.append("\(app.localizedName ?? id): 已发送空格键暂停")
            }
            // 5. check again
            Thread.sleep(forTimeInterval: keyed.isEmpty ? 0.3 : 1.0)
            let still = audioOutputProcesses().compactMap { owningApp($0) }
                .filter { !neverKey.contains($0.bundleIdentifier ?? "") }
            let names = Array(Set(still.compactMap(\.localizedName)))
            if !names.isEmpty { report.append("仍有声音：\(names.joined(separator: "、"))") }
            log("pauseAll: \(report.joined(separator: " | "))")
            DispatchQueue.main.async { done(report, !names.isEmpty) }
        }
    }

    static func sendSpace(to pid: pid_t) {
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: down)?.postToPid(pid)
        }
    }

    static func appName(_ id: String) -> String {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName ?? id
    }

    static func osascript(_ s: String, timeout: Double = 6) -> (ok: Bool, denied: Bool, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", s]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        guard (try? p.run()) != nil else { return (false, false, "") }
        if sem.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (false, true, "timeout") }
        let o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, o.contains("-1743"), o)
    }
}
