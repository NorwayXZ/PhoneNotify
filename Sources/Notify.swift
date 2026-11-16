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

        let (sym, tint) = bannerStyle(forApp: app, isCall: isCall)
        let sender = isCall ? (title.isEmpty ? "未知号码" : title) : (title.isEmpty ? appName : title)
        let shown = isCall ? "来电" + (subtitle.isEmpty ? "" : " · \(subtitle)") : [subtitle, message].filter { !$0.isEmpty }.joined(separator: "\n")
        Banner.shared.present(BannerData(uid: uid, appName: appName, symbol: sym, tint: tint, sender: sender, body: shown,
                                         code: code, isCall: isCall, important: important, sticky: important))
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

