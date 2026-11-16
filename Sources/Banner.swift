import Cocoa
import SwiftUI

// MARK: - Notification card (top-right, floating, no permission needed)
// Native-feeling: slide/fade in & out, app icon + app name + time, bold sender, hover close button,
// hover pauses auto-dismiss, drag right to dismiss, click to expand full text, code pill, round call buttons.

struct BannerData {
    var uid: UInt32
    var appName: String
    var symbol: String
    var tint: Color
    var sender: String
    var body: String
    var code: String? = nil
    var isCall = false
    var important = false
    var sticky = false
    var date = Date()
}

func bannerStyle(forApp bundle: String, isCall: Bool) -> (String, Color) {
    if isCall { return ("phone.fill", Color(red: 0.20, green: 0.78, blue: 0.35)) }
    switch bundle {
    case "com.tencent.xin": return ("message.fill", Color(red: 0.03, green: 0.76, blue: 0.38))
    case "com.tencent.ww": return ("bubble.left.and.bubble.right.fill", Color(red: 0.16, green: 0.47, blue: 0.95))
    case "com.tencent.mqq": return ("bubble.left.fill", Color(red: 0.12, green: 0.62, blue: 0.95))
    case "com.apple.MobileSMS": return ("message.fill", Color(red: 0.20, green: 0.78, blue: 0.35))
    case "com.apple.mobilephone", "com.apple.InCallService": return ("phone.fill", Color(red: 0.20, green: 0.78, blue: 0.35))
    case "com.apple.mobilemail": return ("envelope.fill", Color(red: 0.10, green: 0.50, blue: 1.0))
    case "com.apple.mobilecal": return ("calendar", Color(red: 1.0, green: 0.27, blue: 0.23))
    case "com.alipay.iphoneclient": return ("yensign.circle.fill", Color(red: 0.08, green: 0.47, blue: 1.0))
    default: return ("app.badge.fill", Color(red: 0.45, green: 0.47, blue: 0.55))
    }
}

final class BannerState: ObservableObject {
    @Published var expanded = false
    @Published var hover = false
    @Published var dragX: CGFloat = 0
    @Published var copied = false
}

private struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .popover; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct BannerCard: View {
    let d: BannerData
    @ObservedObject var s: BannerState
    var onClose: () -> Void
    var onToggle: () -> Void
    var onCall: (Int) -> Void
    var onHistory: () -> Void

    var timeText: String {
        let secs = Date().timeIntervalSince(d.date)
        if secs < 60 { return "现在" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [d.tint.opacity(0.95), d.tint], startPoint: .top, endPoint: .bottom))
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: d.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: d.tint.opacity(0.35), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(d.appName.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        if d.important { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        Spacer(minLength: 6)
                        Text(timeText).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Text(d.sender).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if !d.body.isEmpty {
                        Text(d.body)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.78))
                            .lineLimit(s.expanded ? 30 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            if let code = d.code {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    Text(code).font(.system(size: 17, weight: .bold, design: .monospaced)).kerning(2)
                    Spacer()
                    Text(s.copied ? "已复制 ✓" : "已复制到剪贴板").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.orange.opacity(0.13)))
                .onTapGesture { AppModel.shared.copy(code); s.copied = true }
            }

            if d.isCall {
                HStack(spacing: 12) {
                    callButton("挂断", "phone.down.fill", .red) { onCall(1) }
                    callButton("接听", "phone.fill", Color(red: 0.20, green: 0.78, blue: 0.35)) { onCall(0) }
                }
            } else if s.expanded {
                HStack(spacing: 8) {
                    pill(s.copied && d.code == nil ? "已复制" : "复制", "doc.on.doc") {
                        AppModel.shared.copy([d.sender, d.body].filter { !$0.isEmpty }.joined(separator: "\n")); s.copied = true
                    }
                    pill("查看记录", "tray.full") { onHistory() }
                    Spacer()
                    pill("收起", "chevron.up") { onToggle() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(13)
        .frame(width: 356, alignment: .leading)
        .background(Blur())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(d.isCall ? Color.green.opacity(0.55) : d.important ? Color.yellow.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: d.isCall || d.important ? 1.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .overlay(alignment: .topLeading) {
            if s.hover {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: -7, y: -7)
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { if !d.isCall { onToggle() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { s.hover = h } }
        .offset(x: max(0, s.dragX))
        .opacity(1 - Double(max(0, s.dragX)) / 260)
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { s.dragX = $0.translation.width }
            .onEnded { v in
                if v.translation.width > 90 || v.predictedEndTranslation.width > 200 { onClose() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { s.dragX = 0 } }
            })
        .padding(14)   // room for shadow + close button
    }

    func callButton(_ title: String, _ icon: String, _ color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Capsule().fill(color))
        }.buttonStyle(.plain)
    }
    func pill(_ title: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(title, systemImage: icon).font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }.buttonStyle(.plain)
    }
}

final class Banner {
    static let shared = Banner()
    final class Entry {
        let data: BannerData; let state = BannerState(); let panel: NSPanel; var host: NSHostingView<AnyView>!; var closing = false
        init(_ d: BannerData, _ p: NSPanel) { data = d; panel = p }
    }
    private var entries: [Entry] = []
    var onAction: ((UInt32, Int) -> Void)?
    var onOpenHistory: (() -> Void)?
    private let margin: CGFloat = 4

    /// Generic banner (system messages, Claude, battery…)
    func show(uid: UInt32, title: String, body: String, isCall: Bool, sticky: Bool = false,
              appName: String = "PhoneNotify", symbol: String = "bell.fill", tint: Color = Color(red: 0.13, green: 0.70, blue: 0.45)) {
        present(BannerData(uid: uid, appName: appName, symbol: symbol, tint: tint, sender: title, body: body, isCall: isCall, sticky: sticky))
    }

    func present(_ d: BannerData) {
        remove(uid: d.uid, animated: false)
        // keep at most 5 cards: drop the oldest non-sticky one
        if entries.count >= 5, let old = entries.first(where: { !$0.data.sticky && !$0.data.isCall }) { remove(uid: old.data.uid) }

        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar; p.hasShadow = false
        p.backgroundColor = .clear; p.isOpaque = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let e = Entry(d, p)
        let uid = d.uid
        let view = BannerCard(d: d, s: e.state,
            onClose: { [weak self] in self?.remove(uid: uid) },
            onToggle: { [weak self, weak e] in
                guard let e else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { e.state.expanded.toggle() }
                DispatchQueue.main.async { self?.layout(animated: true) }
            },
            onCall: { [weak self] act in self?.onAction?(uid, act); self?.remove(uid: uid) },
            onHistory: { [weak self] in self?.onOpenHistory?(); self?.remove(uid: uid) })
        e.host = NSHostingView(rootView: AnyView(view))
        p.contentView = e.host
        p.setContentSize(e.host.fittingSize)
        entries.append(e)

        // start off to the right, transparent; slide in
        layout(animated: false)
        let target = p.frame
        p.setFrame(target.offsetBy(dx: 60, dy: 0), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().setFrame(target, display: true); p.animator().alphaValue = 1
        }
        layout(animated: true)
        if d.isCall || !d.sticky { scheduleDismiss(uid, after: d.isCall ? 40 : Double(AppModel.shared.bannerSeconds)) }
    }

    private func scheduleDismiss(_ uid: UInt32, after secs: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self, let e = self.entries.first(where: { $0.data.uid == uid }) else { return }
            if e.state.hover || e.state.expanded { self.scheduleDismiss(uid, after: 2) }   // keep while user looks at it
            else { self.remove(uid: uid) }
        }
    }

    func remove(uid: UInt32, animated: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.data.uid == uid }) else { return }
        let e = entries.remove(at: i)
        e.closing = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                e.panel.animator().setFrame(e.panel.frame.offsetBy(dx: 50, dy: 0), display: true)
                e.panel.animator().alphaValue = 0
            }, completionHandler: { e.panel.orderOut(nil) })
        } else { e.panel.orderOut(nil) }
        layout(animated: animated)
    }

    func layout(animated: Bool) {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        var y = vf.maxY + 4          // the card has 14pt transparent padding
        for e in entries.reversed() {
            let size = e.host.fittingSize
            y -= size.height
            let f = NSRect(x: vf.maxX - size.width + 2, y: y, width: size.width, height: size.height)
            y += margin - 14
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28; ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    e.panel.animator().setFrame(f, display: true)
                }
            } else { e.panel.setFrame(f, display: true) }
        }
    }
}
