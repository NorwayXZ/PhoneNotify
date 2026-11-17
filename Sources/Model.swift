import Cocoa
import SwiftUI

struct NotifItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var app: String
    var title: String
    var msg: String
    var code: String?
    var isCall: Bool
    var level: String? = nil          // "important" / "silent"
    var appName: String { appDisplayName(app) }
}

private let ud = UserDefaults.standard
private func B(_ k: String, _ d: Bool) -> Bool { ud.object(forKey: k) as? Bool ?? d }
private func I(_ k: String, _ d: Int) -> Int { ud.object(forKey: k) as? Int ?? d }

/// Single source of truth for the menu bar item and the dashboard window.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Link { case noBoard, waiting, pairing, connected }

    // live state
    @Published var link: Link = .noBoard
    @Published var statusText = "启动中…"
    @Published var port: String?
    @Published var battery: Int?
    @Published var mTitle = ""
    @Published var mArtist = ""
    @Published var mPlayer = ""
    @Published var mPlaying = false
    @Published var rssi: Double = -60
    @Published var history: [NotifItem] = []
    @Published var lastLeave: Date?
    @Published var lastReturn: Date?
    @Published var awayCountdown: Int?
    @Published var requestedPane: String?          // seconds left before leave actions fire
    // presence radar (Mi Home, via gateway)
    @Published var radarConfig: RadarConfig? = MiRadar.loadConfig() { didSet { MiRadar.saveConfig(radarConfig); radar.config = radarConfig; radarReading = nil } }
    @Published var radarReading: RadarReading?
    @Published var radarStatus = "未配置"
    // simple leave setting: "not at the desk for N seconds"
    @Published var leaveSeconds = I("leaveSeconds", 5)               { didSet { ud.set(leaveSeconds, forKey: "leaveSeconds"); awayDelay = leaveSeconds; radarLeaveSeconds = 0; syncRadarDelay(force: true) } }
    @Published var sleepDisplayOnLeave = B("sleepDisplayOnLeave", true) { didSet { ud.set(sleepDisplayOnLeave, forKey: "sleepDisplayOnLeave") } }
    /// 0 radar only, 1 iPhone only, 2 both must say "away"
    var detectBy: Int {
        get { phoneEnabled && radarEnabled ? 2 : phoneEnabled ? 1 : 0 }
        set { combineMode = 0; phoneEnabled = newValue >= 1; radarEnabled = newValue != 1 }
    }
    // leave detection sources (each configured on its own)
    @Published var phoneEnabled = B("phoneEnabled", MiRadar.loadConfig() == nil) { didSet { ud.set(phoneEnabled, forKey: "phoneEnabled"); resetLeave() } }
    @Published var phoneReturnRSSI = I("phoneReturnRSSI", -72)        { didSet { ud.set(phoneReturnRSSI, forKey: "phoneReturnRSSI") } }
    @Published var phoneDisconnectIsAway = B("phoneDisconnectIsAway", true) { didSet { ud.set(phoneDisconnectIsAway, forKey: "phoneDisconnectIsAway") } }
    @Published var radarEnabled = B("radarEnabled", true)             { didSet { ud.set(radarEnabled, forKey: "radarEnabled"); resetLeave() } }
    @Published var radarLeaveSeconds = I("radarLeaveSeconds", 0)      { didSet { ud.set(radarLeaveSeconds, forKey: "radarLeaveSeconds") } }
    @Published var radarFarMeters = ud.object(forKey: "radarFarMeters") as? Double ?? 0 { didSet { ud.set(radarFarMeters, forKey: "radarFarMeters") } }   // 0 = off
    @Published var combineMode = I("combineMode", 0)                  { didSet { ud.set(combineMode, forKey: "combineMode") } }   // 0 all sources away, 1 any source away
    @Published var pauseDelay = I("pauseDelay", 0)                    { didSet { ud.set(pauseDelay, forKey: "pauseDelay") } }
    @Published var muteDelay = I("muteDelay", 0)                      { didSet { ud.set(muteDelay, forKey: "muteDelay") } }
    @Published var lockDelay = I("lockDelay", 0)                      { didSet { ud.set(lockDelay, forKey: "lockDelay") } }
    @Published var returnConfirmSeconds = I("returnConfirmSeconds", 0) { didSet { ud.set(returnConfirmSeconds, forKey: "returnConfirmSeconds") } }
    // live leave state for the dashboard
    @Published var phoneAwayFor: Int?         // seconds the phone has looked "away"
    @Published var radarAwayFor: Int?
    @Published var leaveStatus = ""
    @Published var browserPauseResult: [String] = []
    @Published var pauseByKey = B("pauseByKey", true)                 { didSet { ud.set(pauseByKey, forKey: "pauseByKey") } }
    @Published var muteIfStillPlaying = B("muteIfStillPlaying", true) { didSet { ud.set(muteIfStillPlaying, forKey: "muteIfStillPlaying") } }

    /// Pause every player (Now Playing, scriptable apps, browser tabs, anything still making sound).
    func pauseEverything(test: Bool = false) {
        browserPauseResult = ["正在暂停…"]
        Pauser.pauseAll { [weak self] report, still in
            guard let self else { return }
            self.browserPauseResult = report.isEmpty ? ["没有发现正在播放的内容"] : report
            if still && self.muteIfStillPlaying && !test && !SystemControl.isMuted {
                SystemControl.setMuted(true); self.mutedByUs = true
                self.browserPauseResult.append("已静音兜底")
                log("pauseAll: still sound -> muted")
            }
        }
    }

    // settings (persisted)
    @Published var leaveEnabled = B("leaveEnabled", true)             { didSet { ud.set(leaveEnabled, forKey: "leaveEnabled"); resetLeave() } }
    @Published var pauseMediaOnLeave = B("pauseMediaOnLeave", true)   { didSet { ud.set(pauseMediaOnLeave, forKey: "pauseMediaOnLeave") } }
    @Published var muteOnLeave = B("muteOnLeave", false)              { didSet { ud.set(muteOnLeave, forKey: "muteOnLeave") } }
    @Published var autoLock = B("autoLock", true)                     { didSet { ud.set(autoLock, forKey: "autoLock") } }
    @Published var unmuteOnReturn = B("unmuteOnReturn", true)         { didSet { ud.set(unmuteOnReturn, forKey: "unmuteOnReturn") } }
    @Published var wakeOnReturn = B("wakeOnReturn", false)            { didSet { ud.set(wakeOnReturn, forKey: "wakeOnReturn") } }
    @Published var lockThreshold = I("lockThreshold", -82)            { didSet { ud.set(lockThreshold, forKey: "lockThreshold") } }
    @Published var awayDelay = I("awayDelay", 8)                      { didSet { ud.set(awayDelay, forKey: "awayDelay") } }
    @Published var copyCodes = B("copyCodes", true)                   { didSet { ud.set(copyCodes, forKey: "copyCodes") } }
    @Published var playSound = B("playSound", true)                   { didSet { ud.set(playSound, forKey: "playSound") } }
    @Published var bannerSeconds = I("bannerSeconds", 8)              { didSet { ud.set(bannerSeconds, forKey: "bannerSeconds") } }
    @Published var launchAtLogin = LoginItem.enabled                  { didSet { LoginItem.enabled = launchAtLogin } }
    // rules / quiet hours / speech
    @Published var rules: [Rule] = (try? JSONDecoder().decode([Rule].self, from: ud.data(forKey: "rules") ?? Data())) ?? [] {
        didSet { ud.set(try? JSONEncoder().encode(rules), forKey: "rules"); syncMuteList() } }
    @Published var quietEnabled = B("quietEnabled", false)            { didSet { ud.set(quietEnabled, forKey: "quietEnabled") } }
    @Published var quietStart = I("quietStart", 23)                   { didSet { ud.set(quietStart, forKey: "quietStart") } }
    @Published var quietEnd = I("quietEnd", 8)                        { didSet { ud.set(quietEnd, forKey: "quietEnd") } }
    @Published var speakMode = I("speakMode", 1)                      { didSet { ud.set(speakMode, forKey: "speakMode") } }   // 0 off 1 calls 2 +important 3 all
    // buttons
    @Published var btnSingle = ButtonAction(rawValue: ud.string(forKey: "btnSingle") ?? "") ?? .clearLight      { didSet { ud.set(btnSingle.rawValue, forKey: "btnSingle") } }
    @Published var btnDouble = ButtonAction(rawValue: ud.string(forKey: "btnDouble") ?? "") ?? .phoneNext       { didSet { ud.set(btnDouble.rawValue, forKey: "btnDouble") } }
    @Published var btnTriple = ButtonAction(rawValue: ud.string(forKey: "btnTriple") ?? "") ?? .macPlayPause    { didSet { ud.set(btnTriple.rawValue, forKey: "btnTriple") } }
    @Published var btnLong = ButtonAction(rawValue: ud.string(forKey: "btnLong") ?? "") ?? .callOrPhonePlay     { didSet { ud.set(btnLong.rawValue, forKey: "btnLong") } }
    @Published var customKeys: [String: String] = (ud.dictionary(forKey: "customKeys") as? [String: String]) ?? [:] { didSet { ud.set(customKeys, forKey: "customKeys") } }
    @Published var lastButton: String?
    // Claude Code
    @Published var claudeEnabled = B("claudeEnabled", true)           { didSet { ud.set(claudeEnabled, forKey: "claudeEnabled"); pushClaudeLed() } }
    @Published var claudeBannerDone = B("claudeBannerDone", true)     { didSet { ud.set(claudeBannerDone, forKey: "claudeBannerDone") } }
    @Published var claudeSpeak = B("claudeSpeak", false)              { didSet { ud.set(claudeSpeak, forKey: "claudeSpeak") } }
    @Published var claudeState = "off"
    @Published var claudeDetail = ""
    private var claudeSessions: [String: (state: String, at: Date, project: String)] = [:]
    // Wi-Fi / Telegram (secrets live only on the board)
    @Published var wifiSSID = ud.string(forKey: "wifiSSID") ?? ""     { didSet { ud.set(wifiSSID, forKey: "wifiSSID") } }
    @Published var tgChat = ud.string(forKey: "tgChat") ?? ""         { didSet { ud.set(tgChat, forKey: "tgChat") } }
    @Published var wifiStatus = "未配置"
    @Published var boardHasTelegram = false
    @Published var lastForward = ""

    let bridge = SerialBridge()
    let claude = ClaudeServer()
    let radar = MiRadar()
    private var lastOccupied: Bool?
    var radarFresh: Bool { radarConfig != nil && radarReading.map { $0.occupied != nil && Date().timeIntervalSince($0.at) < 10 } == true }
    private var phoneLinked = false, everLinked = false, awaySince: Date?, mutedByUs = false
    var leftHandled = false
    private var rssiSamples = 0
    private var lowBatteryWarned = false

    var anyLeaveAction: Bool { leaveEnabled && (pauseMediaOnLeave || muteOnLeave || autoLock || sleepDisplayOnLeave) }

    private var historyURL: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhoneNotify")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("history.json")
    }

    func start() {
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode([NotifItem].self, from: d) { history = h }
        NotificationPoster.shared.onAction = { [weak self] uid, act in log("action uid=\(uid) act=\(act)"); self?.bridge.send("A \(uid) \(act)") }
        Banner.shared.onAction = NotificationPoster.shared.onAction
        bridge.onState = { [weak self] s in
            guard let self else { return }
            self.port = self.bridge.fd >= 0 ? self.bridge.port : nil
            if self.bridge.fd < 0 { self.link = .noBoard; self.phoneLinked = false }
            else if self.link == .noBoard { self.link = .waiting }
            self.statusText = s
        }
        bridge.onLine = { [weak self] l in self?.handle(l) }
        bridge.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.evaluateAway() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.bridge.send("HB") }
        radar.onReading = { [weak self] r in
            guard let self else { return }
            if r.occupied != self.lastOccupied { log("radar occupied=\(r.occupied.map { "\($0)" } ?? "?") dist=\(r.distance ?? -1)"); self.lastOccupied = r.occupied }
            self.radarReading = r
            PresenceLog.shared.update(occupied: r.occupied, noOneDelay: (r.noOneSeconds ?? 2) + MiRadar.sensorLag)
            self.syncRadarDelay()
            self.radarStatus = r.occupied == true ? "有人" : r.occupied == false ? "无人" : "未知"
        }
        radar.onError = { [weak self] e in if self?.radarStatus != e { log("radar error: \(e)") }; self?.radarStatus = e }
        radar.config = radarConfig
        radar.start()
        claude.onEvent = { [weak self] st, j in self?.claudeEvent(st, j) }
        claude.start()
    }

    // MARK: commands
    func media(_ cmd: Int) { bridge.send("M \(cmd)") }        // 2 toggle, 3 next, 4 prev, 5 vol+, 6 vol-
    func ledTest(_ r: Int, _ g: Int, _ b: Int) { bridge.send("L \(r) \(g) \(b)") }
    func unpair() { bridge.send("UNPAIR") }
    func clearHistory() { history.removeAll(); saveHistory() }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    private func saveHistory() { if let d = try? JSONEncoder().encode(history) { try? d.write(to: historyURL) } }

    // MARK: serial input
    func handle(_ line: String) {
        if !line.contains("\"t\":\"s\"") && !line.contains("\"t\":\"r\"") && !line.contains("\"t\":\"m\"") { log("raw \(line.prefix(300))") }
        guard let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = j["t"] as? String else { return }
        func num(_ k: String) -> NSNumber? { j[k] as? NSNumber }
        func str(_ k: String) -> String { j[k] as? String ?? "" }
        switch t {
        case "n":
            let uid = num("uid")?.uint32Value ?? 0, cat = num("cat")?.intValue ?? 0
            let app = str("app"), title = str("title"), sub = str("sub"), msg = str("msg")
            let isCall = cat == 1
            let verdict = classify(app: app, title: title, msg: sub + " " + msg, isCall: isCall)
            if verdict == .hide { bridge.send("R \(uid)"); log("hidden by rule"); return }
            if isCall { activeCalls.append(uid) }
            let code = (copyCodes && !isCall && verdict != .silent) ? extractCode(msg + " " + sub) : nil
            if let code { copy(code); log("code copied") }
            if verdict == .silent { bridge.send("R \(uid)") }
            else {
                NotificationPoster.shared.post(uid: uid, app: app, isCall: isCall, title: title, subtitle: sub, message: msg, code: code,
                                               important: verdict == .important)
                speakIfNeeded(app: app, title: title, msg: msg, isCall: isCall, important: verdict == .important)
            }
            history.insert(NotifItem(date: Date(), app: app, title: title, msg: [sub, msg].filter { !$0.isEmpty }.joined(separator: " — "),
                                     code: code, isCall: isCall, level: verdict == .normal ? nil : verdict.rawValue), at: 0)
            if history.count > 300 { history.removeLast(history.count - 300) }
            saveHistory()
        case "d":
            if let uid = num("uid")?.uint32Value { NotificationPoster.shared.remove(uid: uid); activeCalls.removeAll { $0 == uid } }
        case "bat":
            let v = num("v")?.intValue ?? 0
            battery = v
            if v <= 20 && !lowBatteryWarned {
                lowBatteryWarned = true
                Banner.shared.show(uid: 0xFFFFFFFE, title: "iPhone 电量低：\(v)%", body: "记得给手机充电", isCall: false,
                                   appName: "iPhone", symbol: "battery.25percent", tint: .orange)
            }
            if v >= 25 { lowBatteryWarned = false }
        case "m":
            let e = num("e")?.intValue ?? -1, a = num("a")?.intValue ?? -1, v = str("v")
            switch (e, a) {
            case (2, 0): mArtist = v
            case (2, 2): mTitle = v
            case (0, 0): mPlayer = v
            case (0, 1): mPlaying = v.split(separator: ",", omittingEmptySubsequences: false).first == "1"
            default: break
            }
        case "r":
            let raw = num("v")?.intValue ?? -100
            rssi = rssi * 0.7 + Double(raw) * 0.3
            rssiSamples += 1
            if rssiSamples % 15 == 0 { log("rssi raw=\(raw) avg=\(Int(rssi))") }
        case "btn":
            let k = str("k"); log("button \(k)"); lastButton = k
            switch k {
            case "single": runButton(btnSingle, gesture: k)
            case "double": runButton(btnDouble, gesture: k)
            case "triple": runButton(btnTriple, gesture: k)
            case "long": runButton(btnLong, gesture: k)
            default: break
            }
        case "wifi":
            let s = str("s")
            wifiStatus = s == "connected" ? "已连接（\(str("ip"))）" : s == "unset" ? "未配置" : "连接中…"
        case "fwd":
            let ok = (j["ok"] as? Bool) ?? false
            lastForward = (ok ? "✅ 转发成功 " : "❌ 转发失败 \(str("err")) \(num("http")?.intValue ?? 0) ") + Date().formatted(date: .omitted, time: .shortened)
            log("forward \(lastForward)")
        case "cfg":
            boardHasTelegram = (j["tg"] as? Bool) ?? false
            if !str("wifi").isEmpty { wifiSSID = str("wifi") }
        case "s":
            let s = str("s")
            log("esp: \(s)")
            switch s {
            case "ancs_ready":
                let fresh = !phoneLinked
                link = .connected; statusText = "已连接 iPhone，实时接收中"
                phoneLinked = true; everLinked = true
                if fresh { rssi = -60; syncBoard() }
            case "advertising", "disconnected":
                if s == "advertising" && !phoneLinked { everLinked = false }   // board rebooted
                link = .waiting; statusText = "等待 iPhone 连接（iPhone 需在附近）"; phoneLinked = false
            case "connected", "encrypted":
                link = .pairing; statusText = "iPhone 已连接，正在建立通知通道…"
            case "auth_failed", "retry_pairing":
                link = .pairing; statusText = "等待 iPhone 配对确认…"
            default: break
            }
        default: break
        }
    }

    // MARK: rules / speech
    var inQuietHours: Bool {
        guard quietEnabled else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return quietStart <= quietEnd ? (h >= quietStart && h < quietEnd) : (h >= quietStart || h < quietEnd)
    }
    func classify(app: String, title: String, msg: String, isCall: Bool) -> Verdict {
        let hits = rules.filter { $0.matches(app: app, title: title, msg: msg) }.map(\.action)
        if hits.contains(.hide) { return .hide }
        if hits.contains(.important) { return .important }
        if hits.contains(.silent) { return .silent }
        if inQuietHours && !isCall { return .silent }
        return .normal
    }
    func speakIfNeeded(app: String, title: String, msg: String, isCall: Bool, important: Bool) {
        guard speakMode > 0, !leftHandled, !SystemControl.isMuted else { return }
        if inQuietHours && !important && !isCall { return }
        let ok = isCall || (speakMode >= 2 && important) || speakMode >= 3
        guard ok else { return }
        if isCall { Speaker.shared.say("\(title)来电") }
        else { Speaker.shared.say("\(appDisplayName(app))，\(title)：\(String(msg.prefix(40)))") }
    }
    func addRule(_ field: Rule.Field, _ pattern: String, _ action: Rule.Action) {
        rules.append(Rule(field: field, pattern: pattern, action: action))
    }
    /// Apps that are silenced/ignored by an App rule are not forwarded to Telegram either.
    func syncMuteList() {
        let apps = rules.filter { $0.enabled && $0.field == .app && $0.action != .important }.flatMap { r -> [String] in
            let p = r.pattern.trimmingCharacters(in: .whitespaces)
            let byName = appNames.filter { $0.value.contains(p) }.map(\.key)
            return p.contains(".") ? [p] : byName
        }
        bridge.send("MUTE " + apps.joined(separator: ","))
    }
    func syncBoard() { bridge.send("HB"); syncMuteList(); pushClaudeLed(); bridge.send("PING") }

    // MARK: buttons
    func runButton(_ a: ButtonAction, gesture: String) {
        switch a {
        case .none: break
        case .clearLight:
            bridge.send("U")
            for (k, v) in claudeSessions where v.state == "done" || v.state == "waiting" { claudeSessions[k] = ("idle", Date(), v.project) }
            recomputeClaude()
        case .callOrPhonePlay:
            if let call = activeCallUid { bridge.send("A \(call) 1") } else { media(2) }
        case .answerCall: if let call = activeCallUid { bridge.send("A \(call) 0") }
        case .phonePlayPause: media(2)
        case .phoneNext: media(3)
        case .phonePrev: media(4)
        case .macPlayPause: bridge.send("CC CD")
        case .macMute: bridge.send("CC E2")
        case .macNext: bridge.send("CC B5")
        case .lockMac: bridge.send("K 9 113")
        case .screenshot: bridge.send("K 10 52")
        case .missionControl: bridge.send("K 1 218")
        case .showDesktop: bridge.send("K 0 204")
        case .custom:
            if let (m, k) = parseShortcut(customKeys[gesture] ?? "") { bridge.send("K \(m) \(k)") }
        }
    }
    var activeCallUid: UInt32? { activeCalls.last }
    var activeCalls: [UInt32] = []

    // MARK: Claude Code
    func claudeEvent(_ st: String, _ j: [String: Any]) {
        guard claudeEnabled else { return }
        let sid = j["session_id"] as? String ?? "default"
        let project = (j["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        log("claude \(st) \(project)")
        if st == "end" { claudeSessions.removeValue(forKey: sid) }
        else { claudeSessions[sid] = (st, Date(), project) }
        if st == "waiting" {
            let msg = j["message"] as? String ?? "需要你确认"
            Banner.shared.show(uid: 0xFFFFFF00, title: "需要你确认 · \(project)", body: msg, isCall: false, sticky: true,
                               appName: "Claude Code", symbol: "sparkles", tint: .purple)
            if playSound { NSSound(named: "Funk")?.play() }
            if claudeSpeak && !leftHandled { Speaker.shared.say("Claude 需要你确认") }
        } else if st == "done" {
            Banner.shared.remove(uid: 0xFFFFFF00)
            if claudeBannerDone { Banner.shared.show(uid: 0xFFFFFF01, title: "完成了", body: project, isCall: false,
                                                    appName: "Claude Code", symbol: "checkmark.seal.fill", tint: .purple) }
            if claudeSpeak && !leftHandled { Speaker.shared.say("Claude 完成了") }
        } else if st == "working" {
            Banner.shared.remove(uid: 0xFFFFFF00)
        }
        recomputeClaude()
    }
    func recomputeClaude() {
        let now = Date()
        claudeSessions = claudeSessions.filter { now.timeIntervalSince($0.value.at) < 6 * 3600 }
        let states = claudeSessions.values
        let st = states.contains { $0.state == "waiting" } ? "waiting"
               : states.contains { $0.state == "done" } ? "done"
               : states.contains { $0.state == "working" && now.timeIntervalSince($0.at) < 1800 } ? "working" : "off"
        claudeState = st
        let names = Set(states.filter { $0.state != "idle" }.map(\.project)).filter { !$0.isEmpty }
        claudeDetail = names.isEmpty ? "" : names.sorted().joined(separator: "、")
        pushClaudeLed()
    }
    func pushClaudeLed() {
        let code = !claudeEnabled ? 0 : ["off": 0, "working": 1, "waiting": 2, "done": 3][claudeState] ?? 0
        bridge.send("C \(code)")
    }

    // MARK: Wi-Fi / Telegram
    func saveWifi(ssid: String, pass: String) { wifiSSID = ssid; bridge.send("W \(ssid)\t\(pass)") }
    func saveTelegram(token: String, chat: String) { tgChat = chat; bridge.send("TG \(token)\t\(chat)"); boardHasTelegram = true }
    func testTelegram() { lastForward = "发送中…"; bridge.send("TGTEST") }

    // MARK: leave / return
    private var phoneAwaySince: Date?, radarAwaySince: Date?, backSince: Date?, leftAt: Date?
    private var doneActions = Set<String>()

    func resetLeave() {
        phoneAwaySince = nil; radarAwaySince = nil; backSince = nil; leftAt = nil
        phoneAwayFor = nil; radarAwayFor = nil; awayCountdown = nil; leftHandled = false; doneActions = []
        leaveStatus = ""
    }

    var phoneActive: Bool { phoneEnabled && bridge.fd >= 0 && everLinked }
    var radarActive: Bool { radarEnabled && radarFresh }

    func evaluateAway() {
        guard anyLeaveAction else { if leaveStatus != "" || leftHandled { resetLeave() }; return }
        let now = Date()
        // iPhone signal
        var phoneAway = false, phoneBack = false
        if phoneActive {
            let raw = (phoneDisconnectIsAway && !phoneLinked) || (phoneLinked && rssi < Double(lockThreshold))
            if raw { if phoneAwaySince == nil { phoneAwaySince = now } } else { phoneAwaySince = nil }
            phoneAwayFor = phoneAwaySince.map { Int(now.timeIntervalSince($0)) }
            phoneAway = (phoneAwayFor ?? -1) >= awayDelay
            phoneBack = phoneLinked && rssi > Double(phoneReturnRSSI)
        } else { phoneAwaySince = nil; phoneAwayFor = nil }
        // radar
        var radarAway = false, radarBack = false
        if radarActive, let r = radarReading {
            let raw = r.occupied == false
            if raw { if radarAwaySince == nil { radarAwaySince = now } } else { radarAwaySince = nil }
            radarAwayFor = radarAwaySince.map { Int(now.timeIntervalSince($0)) }
            radarAway = (radarAwayFor ?? -1) >= radarLeaveSeconds
            radarBack = r.occupied == true
        } else { radarAwaySince = nil; radarAwayFor = nil }

        var sources: [(away: Bool, back: Bool)] = []
        if phoneActive { sources.append((phoneAway, phoneBack)) }
        if radarActive { sources.append((radarAway, radarBack)) }
        guard !sources.isEmpty else {
            leaveStatus = (phoneEnabled || radarEnabled) ? "检测源暂时不可用（iPhone 未连接 / 雷达读不到）" : "没有启用任何检测方式"
            awayCountdown = nil; return
        }
        let all = combineMode == 0
        let left = all ? sources.allSatisfy { $0.away } : sources.contains { $0.away }
        let back = all ? sources.contains { $0.back } : sources.allSatisfy { $0.back }

        if !leftHandled {
            if left { leftHandled = true; leftAt = now; doneActions = []; backSince = nil; lastLeave = now
                      log("leave detected (phone=\(phoneActive ? "\(phoneAway) rssi=\(Int(rssi))" : "off") radar=\(radarActive ? "\(radarAway) \(radarStatus)" : "off"))") }
            else { leaveStatus = "在座"; awayCountdown = nil; return }
        }
        // left: run each action at its own delay, until the user is back
        if back && !left {
            if backSince == nil { backSince = now }
            if now.timeIntervalSince(backSince!) >= Double(returnConfirmSeconds) { performReturn(); return }
        } else { backSince = nil }
        let t = Int(now.timeIntervalSince(leftAt ?? now))
        var pending: [Int] = []
        func run(_ id: String, _ on: Bool, _ delay: Int, _ f: () -> Void) {
            guard on, !doneActions.contains(id) else { return }
            if t >= delay { doneActions.insert(id); log("leave action \(id) at +\(t)s"); f() } else { pending.append(delay - t) }
        }
        run("pause", pauseMediaOnLeave, 0) { pauseEverything() }
        run("mute", muteOnLeave, 0) { if !SystemControl.isMuted { SystemControl.setMuted(true); mutedByUs = true } }
        run("lock", autoLock, 0) { SystemControl.lockScreen() }
        run("sleep", sleepDisplayOnLeave, 0) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { SystemControl.sleepDisplay() } }
        awayCountdown = pending.min()
        leaveStatus = pending.isEmpty ? "已离开 \(t) 秒" : "已离开 \(t) 秒，\(pending.min()!) 秒后执行下一个动作"
    }

    func performLeave(test: Bool = false) {
        log("leave (test=\(test) linked=\(phoneLinked) rssi=\(Int(rssi)) radar=\(radarStatus))")
        if pauseMediaOnLeave { pauseEverything() }
        if muteOnLeave && !SystemControl.isMuted { SystemControl.setMuted(true); mutedByUs = true }
        lastLeave = Date()
        if autoLock { SystemControl.lockScreen() }
        if sleepDisplayOnLeave { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { SystemControl.sleepDisplay() } }
    }

    func performReturn() {
        log("return (wake=\(wakeOnReturn))")
        if mutedByUs && unmuteOnReturn { SystemControl.setMuted(false) }
        mutedByUs = false
        lastReturn = Date()
        resetLeave()
        if wakeOnReturn { SystemControl.wakeDisplay() }
    }

    // sensor-side settings (written to the radar through the gateway)
    func writeRadar(_ siid: Int, _ piid: Int, _ value: Int) { radar.set(siid: siid, piid: piid, value: value) }

    /// Keep the sensor's own "no one" time equal to the chosen leave seconds (radar mode).
    private var lastRadarSync = Date.distantPast
    func syncRadarDelay(force: Bool = false) {
        guard radarEnabled, radarConfig != nil, let cur = radarReading?.noOneSeconds else { return }
        let want = max(leaveSeconds - MiRadar.sensorLag, 2)      // the sensor reports ~4 s later than its own setting
        guard cur != want, force || Date().timeIntervalSince(lastRadarSync) > 60 else { return }
        lastRadarSync = Date(); log("radar sync no-one time \(cur) -> \(want)")
        writeRadar(2, 2, want)
    }
}
