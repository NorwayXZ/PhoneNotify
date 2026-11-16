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

    static func wakeDisplay() { run("/usr/bin/caffeinate", ["-u", "-t", "2"]) }

    /// Send the system-wide "pause" (not toggle) to whatever app owns Now Playing:
    /// browsers (YouTube, Bilibili, live streams), Music, QuickTime, IINA…  Does nothing if nothing plays.
    static func pauseMedia() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return }
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        _ = unsafeBitCast(sym, to: Send.self)(1 /* kMRPause */, nil)
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
