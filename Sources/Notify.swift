import Cocoa
import UserNotifications

let categoryNames = [0: "其他", 1: "来电", 2: "未接来电", 3: "语音留言", 4: "社交", 5: "日程",
                     6: "邮件", 7: "新闻", 8: "健康", 9: "商务", 10: "位置", 11: "娱乐"]
let appNames = ["com.tencent.xin": "微信", "com.apple.MobileSMS": "信息", "com.apple.mobilephone": "电话",
                "com.apple.InCallService": "电话", "com.tencent.mqq": "QQ", "com.apple.facetime": "FaceTime",
                "com.apple.mobilemail": "邮件", "com.apple.mobilecal": "日历", "com.tencent.ww": "企业微信",
                "com.alipay.iphoneclient": "支付宝", "com.ss.iphone.ugc.Aweme": "抖音", "com.taobao.taobao4iphone": "淘宝"]
func appDisplayName(_ bundle: String) -> String {
    appNames[bundle] ?? bundle.split(separator: ".").last.map(String.init) ?? "iPhone"
}
func appSymbol(_ bundle: String, isCall: Bool) -> String {
    if isCall { return "phone.fill" }
    switch bundle {
    case "com.tencent.xin", "com.tencent.ww", "com.tencent.mqq": return "bubble.left.and.bubble.right.fill"
    case "com.apple.MobileSMS": return "message.fill"
    case "com.apple.mobilephone", "com.apple.InCallService": return "phone.fill"
    case "com.apple.mobilemail": return "envelope.fill"
    case "com.apple.mobilecal": return "calendar"
    default: return "app.badge.fill"
    }
}

// MARK: - Verification code detection
func extractCode(_ text: String) -> String? {
    let keywords = ["验证码", "校验码", "动态码", "确认码", "安全码", "驗證碼", "动态密码", "口令",
                    "code", "Code", "CODE", "verification", "OTP", "passcode"]
    guard keywords.contains(where: { text.contains($0) }) else { return nil }
    guard let re = try? NSRegularExpression(pattern: "(?<![0-9A-Za-z])([0-9]{4,8})(?![0-9A-Za-z])") else { return nil }
    let ns = text as NSString
    let hits = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    guard !hits.isEmpty else { return nil }
    if let kw = keywords.compactMap({ text.range(of: $0) }).first {
        let after = String(text[kw.upperBound...])
        if let m = re.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
            return (after as NSString).substring(with: m.range(at: 1))
        }
    }
    return hits.first
}

// MARK: - System notifications (used when macOS allows them) + own banner
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPoster()
    let center = UNUserNotificationCenter.current()
    var onAction: ((UInt32, Int) -> Void)?

    func setup() {
        center.delegate = self
        let answer = UNNotificationAction(identifier: "answer", title: "接听", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "挂断", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "call", actions: [answer, decline], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in log("notif auth=\(ok)") }
    }

    func post(uid: UInt32, app: String, isCall: Bool, title: String, subtitle: String, message: String, code: String?, important: Bool = false) {
        let appName = appDisplayName(app)
        var head = isCall ? "📞 来电：\(title)" : (title.isEmpty ? appName : "\(appName) · \(title)")
        if important { head = "⭐️ " + head }
        if let code { head = "🔑 验证码 \(code) 已复制  ·  \(title.isEmpty ? appName : title)" }
        let body = [subtitle, message].filter { !$0.isEmpty }.joined(separator: " — ")

        let c = UNMutableNotificationContent()
        c.title = head; c.body = body
        c.categoryIdentifier = isCall ? "call" : ""
        c.userInfo = ["uid": uid]
        center.add(UNNotificationRequest(identifier: "ancs-\(uid)", content: c, trigger: nil))

        Banner.shared.show(uid: uid, title: head, body: body, isCall: isCall, sticky: important)
        if AppModel.shared.playSound { NSSound(named: isCall ? "Glass" : important ? "Hero" : "Tink")?.play() }
    }
    func remove(uid: UInt32) {
        center.removeDeliveredNotifications(withIdentifiers: ["ancs-\(uid)"])
        Banner.shared.remove(uid: uid)
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([]) }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        if let uid = r.notification.request.content.userInfo["uid"] as? UInt32 {
            if r.actionIdentifier == "answer" { onAction?(uid, 0) }
            if r.actionIdentifier == "decline" { onAction?(uid, 1) }
        }
        h()
    }
}

// MARK: - Own banner (no permission needed; always on top)
// Click a message banner → it expands to show the full text, stays open, and offers 复制 / 查看记录 / 关闭.
final class Banner {
    static let shared = Banner()
    struct Item { let uid: UInt32; let title: String; let body: String; let isCall: Bool; var sticky: Bool; var expanded: Bool; let panel: NSPanel }
    var items: [Item] = []
    var onAction: ((UInt32, Int) -> Void)?
    var onOpenHistory: (() -> Void)?
    let width: CGFloat = 380

    func show(uid: UInt32, title: String, body: String, isCall: Bool, sticky: Bool = false) {
        remove(uid: uid)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar; p.hasShadow = true
        p.backgroundColor = .clear; p.isOpaque = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let item = Item(uid: uid, title: title, body: body, isCall: isCall, sticky: sticky, expanded: false, panel: p)
        items.append(item)
        render(item)
        p.orderFrontRegardless()
        if isCall || !sticky {
            let secs = isCall ? 40.0 : Double(AppModel.shared.bannerSeconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                guard let self, let it = self.items.first(where: { $0.uid == uid }), !it.expanded else { return }
                self.remove(uid: uid)
            }
        }
    }

    private func render(_ it: Item) {
        let w = width
        let bodyFont = NSFont.systemFont(ofSize: 13)
        // measure body height when expanded
        let textW = w - 28
        var bodyH: CGFloat = 36
        if it.expanded {
            let rect = (it.body as NSString).boundingRect(with: NSSize(width: textW, height: 2000),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: [.font: bodyFont])
            bodyH = min(max(ceil(rect.height) + 6, 20), 420)
        }
        let buttonsH: CGFloat = (it.isCall || it.expanded) ? 40 : 0
        let h = 36 + bodyH + buttonsH + 8

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true
        bg.layer?.cornerRadius = 14; bg.layer?.masksToBounds = true
        if it.isCall { bg.layer?.borderWidth = 2; bg.layer?.borderColor = NSColor.systemRed.cgColor }
        else if it.sticky { bg.layer?.borderWidth = 2; bg.layer?.borderColor = NSColor.systemYellow.cgColor }

        if !it.isCall && !it.expanded {   // whole banner clickable → expand
            bg.addSubview(ClickView(frame: bg.bounds) { [weak self] in self?.expand(it.uid) })
        }
        let t = NSTextField(labelWithString: it.title); t.font = .boldSystemFont(ofSize: 14)
        t.frame = NSRect(x: 14, y: h - 30, width: w - 28, height: 20); t.lineBreakMode = .byTruncatingTail
        bg.addSubview(t)

        if it.expanded {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textW, height: bodyH))
            tv.string = it.body; tv.font = bodyFont; tv.isEditable = false; tv.isSelectable = true
            tv.drawsBackground = false; tv.textColor = .labelColor; tv.textContainerInset = .zero
            let sv = NSScrollView(frame: NSRect(x: 14, y: buttonsH + 8, width: textW, height: bodyH))
            sv.documentView = tv; sv.drawsBackground = false; sv.hasVerticalScroller = bodyH >= 420; sv.borderType = .noBorder
            bg.addSubview(sv)
        } else {
            let b = NSTextField(wrappingLabelWithString: it.body); b.font = bodyFont
            b.frame = NSRect(x: 14, y: buttonsH + 6, width: textW, height: bodyH); b.maximumNumberOfLines = 2
            b.lineBreakMode = .byTruncatingTail
            bg.addSubview(b)
        }

        if it.isCall {
            let a = Btn("接听") { [weak self] in self?.onAction?(it.uid, 0); self?.remove(uid: it.uid) }
            a.frame = NSRect(x: 14, y: 8, width: 168, height: 28); a.bezelColor = .systemGreen
            let d = Btn("挂断") { [weak self] in self?.onAction?(it.uid, 1); self?.remove(uid: it.uid) }
            d.frame = NSRect(x: w - 182, y: 8, width: 168, height: 28); d.bezelColor = .systemRed
            bg.addSubview(a); bg.addSubview(d)
        } else if it.expanded {
            let bw = (w - 28 - 16) / 3
            let copy = Btn("复制内容") { AppModel.shared.copy(it.body) }
            copy.frame = NSRect(x: 14, y: 8, width: bw, height: 28)
            let hist = Btn("查看记录") { [weak self] in self?.onOpenHistory?(); self?.remove(uid: it.uid) }
            hist.frame = NSRect(x: 14 + bw + 8, y: 8, width: bw, height: 28)
            let close = Btn("关闭") { [weak self] in self?.remove(uid: it.uid) }
            close.frame = NSRect(x: 14 + (bw + 8) * 2, y: 8, width: bw, height: 28)
            bg.addSubview(copy); bg.addSubview(hist); bg.addSubview(close)
        }
        it.panel.setContentSize(NSSize(width: w, height: h))
        it.panel.contentView = bg
        layout()
    }

    func expand(_ uid: UInt32) {
        guard let i = items.firstIndex(where: { $0.uid == uid }) else { return }
        items[i].expanded = true; items[i].sticky = true
        render(items[i])
    }
    func remove(uid: UInt32) {
        items.filter { $0.uid == uid }.forEach { $0.panel.orderOut(nil) }
        items.removeAll { $0.uid == uid }; layout()
    }
    func layout() {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        var y = vf.maxY - 10
        for it in items.reversed() {
            y -= it.panel.frame.height
            it.panel.setFrameOrigin(NSPoint(x: vf.maxX - it.panel.frame.width - 12, y: y)); y -= 8
        }
    }
    final class Btn: NSButton {
        let cb: () -> Void
        init(_ title: String, _ cb: @escaping () -> Void) {
            self.cb = cb; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; action = #selector(fire)
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc func fire() { cb() }
    }
    final class ClickView: NSView {
        let cb: () -> Void
        init(frame: NSRect, cb: @escaping () -> Void) { self.cb = cb; super.init(frame: frame) }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with e: NSEvent) { cb() }
    }
}
