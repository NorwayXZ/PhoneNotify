import Cocoa
import AVFoundation
import Network

// MARK: - Rules
struct Rule: Identifiable, Codable, Hashable {
    enum Field: String, Codable, CaseIterable, Identifiable { case app = "App", sender = "联系人/群", keyword = "内容含"; var id: String { rawValue } }
    enum Action: String, Codable, CaseIterable, Identifiable {
        case important = "重要", silent = "静默", hide = "忽略"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .important: return "弹窗不自动消失 · 特别提示音 · 语音播报"
            case .silent: return "只记录到通知记录，不弹窗不出声，不转发"
            case .hide: return "完全丢弃，不记录"
            }
        }
    }
    var id = UUID()
    var enabled = true
    var field: Field = .sender
    var pattern = ""
    var action: Action = .important

    func matches(app: String, title: String, msg: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard enabled, !p.isEmpty else { return false }
        switch field {
        case .app: return app.localizedCaseInsensitiveContains(p) || appDisplayName(app).localizedCaseInsensitiveContains(p)
        case .sender: return title.localizedCaseInsensitiveContains(p)
        case .keyword: return msg.localizedCaseInsensitiveContains(p) || title.localizedCaseInsensitiveContains(p)
        }
    }
}

enum Verdict: String, Codable { case normal, important, silent, hide }

// MARK: - Speech
final class Speaker {
    static let shared = Speaker()
    let synth = AVSpeechSynthesizer()
    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.52
        synth.speak(u)
    }
}

// MARK: - Button actions (board reports gestures; Mac decides; HID keys go out through the board)
enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none = "不做任何事"
    case clearLight = "熄灭提醒灯（含 Claude 提醒）"
    case callOrPhonePlay = "有来电时挂断，否则 iPhone 播放/暂停"
    case answerCall = "接听来电"
    case phonePlayPause = "iPhone 播放 / 暂停"
    case phoneNext = "iPhone 下一首"
    case phonePrev = "iPhone 上一首"
    case macPlayPause = "Mac 播放 / 暂停"
    case macMute = "Mac 静音 / 取消静音"
    case macNext = "Mac 下一首"
    case lockMac = "锁定 Mac 屏幕"
    case screenshot = "截图（⌘⇧4）"
    case missionControl = "调度中心（⌃↑）"
    case showDesktop = "显示桌面（F11）"
    case custom = "自定义快捷键"
    var id: String { rawValue }
}

/// Parse "cmd+shift+4", "ctrl+alt+space", "f5" → (mods, Arduino key code)
func parseShortcut(_ s: String) -> (Int, Int)? {
    var mods = 0, key = 0
    for raw in s.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+") {
        let t = String(raw)
        switch t {
        case "ctrl", "control", "⌃": mods |= 1
        case "shift", "⇧": mods |= 2
        case "alt", "opt", "option", "⌥": mods |= 4
        case "cmd", "command", "⌘": mods |= 8
        case "space": key = 32
        case "enter", "return": key = 0xB0
        case "esc", "escape": key = 0xB1
        case "tab": key = 0xB3
        case "up", "↑": key = 0xDA
        case "down", "↓": key = 0xD9
        case "left", "←": key = 0xD8
        case "right", "→": key = 0xD7
        default:
            if t.hasPrefix("f"), let n = Int(t.dropFirst()), (1...12).contains(n) { key = 0xC1 + n }
            else if t.count == 1, let a = t.unicodeScalars.first?.value { key = Int(a) }
            else { return nil }
        }
    }
    return (mods > 0 || key > 0) ? (mods, key) : nil
}

// MARK: - Claude Code hook listener (127.0.0.1:47800)
/// Hooks POST to /claude/<working|waiting|done|end> with the hook JSON as body.
final class ClaudeServer {
    var onEvent: ((String, [String: Any]) -> Void)?
    private var listener: NWListener?

    func start() {
        guard let l = try? NWListener(using: .tcp, on: 47800) else { log("claude server: port busy"); return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { s in log("claude server \(s)") }
        l.start(queue: .main)
        listener = l
    }

    private func serve(_ c: NWConnection) {
        // only accept local clients
        if case let .hostPort(host, _) = c.endpoint, !"\(host)".contains("127.0.0.1"), !"\(host)".contains("::1") { c.cancel(); return }
        c.start(queue: .main)
        var buf = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                if let d { buf.append(d) }
                if let req = String(data: buf, encoding: .utf8), let hdrEnd = req.range(of: "\r\n\r\n") {
                    let head = String(req[..<hdrEnd.lowerBound])
                    let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = Data(req[hdrEnd.upperBound...].utf8)
                    if body.count >= len || done || err != nil {
                        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                        if path.hasPrefix("/claude/") { self?.onEvent?(String(path.dropFirst(8)), json) }
                        if path == "/test/pause" { DispatchQueue.main.async { AppModel.shared.pauseEverything(test: true) } }
                        c.send(content: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".data(using: .utf8),
                               completion: .contentProcessed { _ in c.cancel() })
                        return
                    }
                }
                if done || err != nil { c.cancel() } else { readMore() }
            }
        }
        readMore()
    }
}
