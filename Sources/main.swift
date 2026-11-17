import Cocoa
import SwiftUI
import Combine

// PhoneNotify: menu bar bell + dashboard window. ESP32-S3 (USB) bridges iPhone ANCS/AMS.

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var window: NSWindow?
    let m = AppModel.shared
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        log("=== PhoneNotify start \(CommandLine.arguments.dropFirst().joined(separator: " ")) ===")
        NotificationPoster.shared.setup()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        m.$link.receive(on: RunLoop.main).sink { [weak self] l in self?.setIcon(connected: l == .connected) }.store(in: &bag)
        m.start()
        Banner.shared.onOpenHistory = { [weak self] in self?.m.requestedPane = "通知记录"; self?.showDashboard() }
        if LoginItem.enabled { LoginItem.enabled = true }   // refresh agent to the "--login" form
        if let i = CommandLine.arguments.firstIndex(of: "--pane"), i + 1 < CommandLine.arguments.count { m.requestedPane = CommandLine.arguments[i + 1] }
        if !CommandLine.arguments.contains("--login") { showDashboard() }
    }

    func applicationWillTerminate(_ n: Notification) { PresenceLog.shared.flush() }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showDashboard(); return true }

    func setIcon(connected: Bool) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [connected ? .systemGreen : .white]))
        let img = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = false
        item.button?.image = img
        item.button?.toolTip = connected ? "手机通知：已连接 iPhone" : "手机通知：未连接"
    }

    // Menu rebuilt each time it opens, so it always shows live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func act(_ t: String, _ sel: Selector, _ key: String = "", tag: Int = 0) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self; i.tag = tag; menu.addItem(i)
        }
        info(m.link == .connected ? "● 已连接 iPhone" : "○ \(m.statusText)")
        if let b = m.battery { info("iPhone 电量 \(b)%") }
        if m.radarConfig != nil { info("座位：\(m.radarStatus)\(m.radarReading?.distance.map { String(format: " · %.2f 米", $0) } ?? "")") }
        if let last = m.history.first { info("最近：\(last.appName) · \(last.title)") }
        menu.addItem(.separator())
        info(m.mTitle.isEmpty ? "♪ 未在播放" : "♪ \(m.mTitle)\(m.mArtist.isEmpty ? "" : " — \(m.mArtist)")")
        act(m.mPlaying ? "暂停" : "播放", #selector(media(_:)), tag: 2)
        act("下一首", #selector(media(_:)), tag: 3)
        menu.addItem(.separator())
        act("离开检测（暂停 / 静音 / 锁屏）", #selector(toggleLock)); menu.items.last?.state = m.leaveEnabled ? .on : .off
        act("打开控制面板…", #selector(openDashboard), ",")
        menu.addItem(.separator())
        let q = NSMenuItem(title: "退出", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"); q.target = NSApp; menu.addItem(q)
    }
    @objc func media(_ s: NSMenuItem) { m.media(s.tag) }
    @objc func toggleLock() { m.leaveEnabled.toggle() }
    @objc func openDashboard() { showDashboard() }

    func showDashboard() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "手机通知"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView().environmentObject(m))
            w.center(); w.setFrameAutosaveName("Dashboard"); w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
