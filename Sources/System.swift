import Cocoa

// MARK: - Logging
let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("PhoneNotify.log")
}()
let tsFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    let line = "[\(tsFmt.string(from: Date()))] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.data(using: .utf8)!.write(to: logURL) }
}

enum SystemControl {
    /// Lock the screen immediately (same as Ctrl-Cmd-Q).
    static func lockScreen() {
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias F = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: F.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static func sleepDisplay() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    static func wakeDisplay() { run("/usr/bin/caffeinate", ["-u", "-t", "2"]) }

    /// Send the system-wide "pause" (not toggle) to whatever app owns Now Playing:
    /// browsers (YouTube, Bilibili, live streams), Music, QuickTime, IINA…  Does nothing if nothing plays.
    static func pauseMedia() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return }
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        _ = unsafeBitCast(sym, to: Send.self)(1 /* kMRPause */, nil)
    }

    /// Browsers often don't own "Now Playing" (several tabs, live streams, Chromium forks), so
    /// also pause every playing <video>/<audio> in every tab of every running browser via AppleScript.
    /// Chromium browsers need "View > Developer > Allow JavaScript from Apple Events"; Safari needs
    /// "Develop > Allow JavaScript from Apple Events".
    static let chromiumBrowsers = ["com.citrolabs.ego.lite", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                                   "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.chromium.Chromium", "com.google.Chrome.canary"]
    /// Pauses every playing <video>/<audio>, then keeps them paused + muted (live players auto-resume)
    /// until the user clicks/presses a key in the page or PhoneNotify sees them come back.
    static let pauseJS = "(()=>{const W=window;let n=0;const f=d=>{try{d.querySelectorAll('video,audio').forEach(m=>{if(!m.paused||m.__pn){if(!m.__pn)m.__pn={muted:m.muted};if(!m.paused){m.pause();n++}m.muted=true}});d.querySelectorAll('iframe').forEach(i=>{try{f(i.contentDocument)}catch(e){}})}catch(e){}};f(document);if(n&&!W.__pnClear){const c=()=>{clearInterval(W.__pnT);const g=d=>{try{d.querySelectorAll('video,audio').forEach(m=>{if(m.__pn){m.muted=m.__pn.muted;delete m.__pn}});d.querySelectorAll('iframe').forEach(i=>{try{g(i.contentDocument)}catch(e){}})}catch(e){}};g(document);['pointerdown','keydown'].forEach(t=>W.removeEventListener(t,c,true));W.__pnClear=null};W.__pnClear=c;W.__pnT=setInterval(()=>f(document),1000);['pointerdown','keydown'].forEach(t=>W.addEventListener(t,c,true))}return n})()"
    static let releaseJS = "(()=>{if(window.__pnClear){window.__pnClear();return 1}return 0})()"

    /// Returns per-browser results like "ego lite: 2" or "ego lite: 需要开启「允许 Apple 事件中的 JavaScript」".
    static func pauseBrowsers(js: String = pauseJS, _ done: (([String]) -> Void)? = nil) {
        let running = NSWorkspace.shared.runningApplications
        var jobs: [(name: String, script: String)] = []
        for app in running {
            guard let id = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? id
            if chromiumBrowsers.contains(id) {
                jobs.append((name, """
                set n to 0
                set errs to ""
                tell application id "\(id)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                set n to n + (execute t javascript "\(js)")
                            on error e
                                set errs to e
                            end try
                        end repeat
                    end repeat
                end tell
                if n = 0 and errs is not "" then return "ERR:" & errs
                return n as text
                """))
            } else if id == "com.apple.Safari" {
                jobs.append((name, """
                set n to 0
                set errs to ""
                tell application id "com.apple.Safari"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                set n to n + (do JavaScript "\(js)" in t)
                            on error e
                                set errs to e
                            end try
                        end repeat
                    end repeat
                end tell
                if n = 0 and errs is not "" then return "ERR:" & errs
                return n as text
                """))
            }
        }
        guard !jobs.isEmpty else { done?([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String] = []
            for j in jobs {
                let res = Pauser.osascript(j.script)
                let r = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if r == "timeout" { out.append("\(j.name): 等待授权超时（请在弹窗里允许 PhoneNotify 控制它）"); continue }
                if r.contains("JavaScript") && (r.contains("ERR") || r.contains("error") || r.contains("错误")) { out.append("\(j.name): 需要开启「允许 Apple 事件中的 JavaScript」") }
                else if r.contains("-1743") || r.contains("不允许") || r.contains("Not authorized") { out.append("\(j.name): 需要允许 PhoneNotify 控制此浏览器") }
                else if let n = Int(r) { out.append("\(j.name): 暂停 \(n) 个") }
                else { out.append("\(j.name): \(r.prefix(80))") }
            }
            log("pause browsers: \(out.joined(separator: " | "))")
            DispatchQueue.main.async { done?(out) }
        }
    }

    static var isMuted: Bool {
        var err: NSDictionary?
        return NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(&err).booleanValue ?? false
    }
    static func setMuted(_ m: Bool) {
        var err: NSDictionary?
        NSAppleScript(source: "set volume output muted \(m)")?.executeAndReturnError(&err)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Bool {
        let t = Process(); t.executableURL = URL(fileURLWithPath: path); t.arguments = args
        return (try? t.run()) != nil
    }
}

// MARK: - Launch at login (LaunchAgent; "--login" keeps the dashboard closed on boot)
enum LoginItem {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.norway.phonenotify.plist") }
    static var enabled: Bool {
        get { FileManager.default.fileExists(atPath: url.path) }
        set {
            if newValue {
                let plist: [String: Any] = ["Label": "com.norway.phonenotify",
                                            "ProgramArguments": ["/usr/bin/open", "-a", "/Applications/PhoneNotify.app", "--args", "--login"],
                                            "RunAtLoad": true]
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                (plist as NSDictionary).write(to: url, atomically: true)
            } else { try? FileManager.default.removeItem(at: url) }
        }
    }
}
