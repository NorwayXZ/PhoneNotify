import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview = "概览", history = "通知记录", rules = "规则与播报", leave = "离开与返回",
         buttons = "按键与快捷键", claude = "Claude Code", forward = "离线转发", device = "设备与设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .history: return "tray.full.fill"
        case .leave: return "figure.walk.departure"
        case .rules: return "line.3.horizontal.decrease.circle.fill"
        case .buttons: return "button.programmable"
        case .claude: return "sparkles"
        case .forward: return "paperplane.fill"
        case .device: return "gearshape.fill"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var m: AppModel
    @State private var pane: Pane? = .overview
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
            .safeAreaInset(edge: .bottom) { LinkPill().padding(10) }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch pane ?? .overview {
                    case .overview: OverviewPane()
                    case .history: HistoryPane()
                    case .leave: LeavePane()
                    case .rules: RulesPane()
                    case .buttons: ButtonsPane()
                    case .claude: ClaudePane()
                    case .forward: ForwardPane()
                    case .device: DevicePane()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onReceive(m.$requestedPane) { p in
            if let p, let target = Pane(rawValue: p) { pane = target; m.requestedPane = nil }
        }
    }
}

// MARK: - building blocks
struct Card<Content: View>: View {
    let title: String; var icon: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }
}

struct LinkPill: View {
    @EnvironmentObject var m: AppModel
    var color: Color { m.link == .connected ? .green : (m.link == .noBoard ? .gray : .white) }
    var text: String {
        switch m.link { case .connected: return "已连接 iPhone"; case .pairing: return "正在连接…"
                        case .waiting: return "等待 iPhone"; case .noBoard: return "未插 ESP32" }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9).shadow(color: color.opacity(0.8), radius: m.link == .connected ? 4 : 0)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

struct SignalBars: View {
    let rssi: Double, threshold: Int
    var level: Int { rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -78 ? 2 : rssi > -88 ? 1 : 0 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < level ? (rssi < Double(threshold) ? Color.orange : Color.green) : Color.primary.opacity(0.15))
                    .frame(width: 6, height: CGFloat(8 + i * 6))
            }
        }
    }
}

struct NotifRow: View {
    @EnvironmentObject var m: AppModel
    let n: NotifItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: appSymbol(n.app, isCall: n.isCall))
                .font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(n.isCall ? Color.red : (n.app == "com.tencent.xin" ? Color.green : Color.blue)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(n.title.isEmpty ? n.appName : n.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(n.appName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(n.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                Text(n.msg).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if let code = n.code {
                    Button { m.copy(code) } label: { Label("验证码 \(code)  点击复制", systemImage: "key.fill").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if !n.title.isEmpty {
                Button("把「\(n.title)」设为重要") { m.addRule(.sender, n.title, .important) }
                Button("静默「\(n.title)」") { m.addRule(.sender, n.title, .silent) }
            }
            Button("静默所有「\(n.appName)」通知") { m.addRule(.app, n.app, .silent) }
            if let code = n.code { Button("复制验证码 \(code)") { m.copy(code) } }
        }
        .overlay(alignment: .topTrailing) {
            if n.level == "important" { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
            else if n.level == "silent" { Image(systemName: "bell.slash.fill").foregroundStyle(.secondary).font(.caption) }
        }
    }
}

// MARK: - panes
struct OverviewPane: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Text("概览").font(.largeTitle.bold())
        HStack(spacing: 16) {
            Card(title: "连接", icon: "antenna.radiowaves.left.and.right") {
                LinkPill()
                Text(m.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Card(title: "iPhone 电量", icon: "battery.75percent") {
                if let b = m.battery {
                    Gauge(value: Double(b), in: 0...100) { EmptyView() } currentValueLabel: { Text("\(b)%") }
                        .gaugeStyle(.accessoryCircularCapacity).tint(b <= 20 ? .red : .green).scaleEffect(1.3).frame(height: 56)
                } else { Text("—").font(.title) }
            }
            Card(title: "信号", icon: "dot.radiowaves.right") {
                HStack(alignment: .bottom, spacing: 10) {
                    SignalBars(rssi: m.rssi, threshold: m.lockThreshold)
                    Text(m.link == .connected ? "\(Int(m.rssi)) dBm" : "—").font(.title3.monospacedDigit())
                }.frame(height: 56)
            }
        }
        MediaCard()
        Card(title: "最近通知", icon: "bell.fill") {
            if m.history.isEmpty { Text("还没有收到通知").foregroundStyle(.secondary) }
            ForEach(m.history.prefix(5)) { n in NotifRow(n: n); if n.id != m.history.prefix(5).last?.id { Divider() } }
        }
    }
}

struct MediaCard: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Card(title: "iPhone 正在播放", icon: "music.note") {
            HStack(spacing: 14) {
                Image(systemName: m.mPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 22)).foregroundStyle(.white).frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.mTitle.isEmpty ? "未在播放" : m.mTitle).font(.headline).lineLimit(1)
                    Text([m.mArtist, m.mPlayer].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    ctl("speaker.wave.1.fill", 6); ctl("backward.fill", 4)
                    ctl(m.mPlaying ? "pause.circle.fill" : "play.circle.fill", 2, big: true)
                    ctl("forward.fill", 3); ctl("speaker.wave.3.fill", 5)
                }
            }
        }
    }
    func ctl(_ icon: String, _ cmd: Int, big: Bool = false) -> some View {
        Button { m.media(cmd) } label: { Image(systemName: icon).font(.system(size: big ? 30 : 15)).frame(width: big ? 38 : 26, height: 34) }
            .buttonStyle(.borderless).disabled(m.link != .connected)
    }
}

struct HistoryPane: View {
    @EnvironmentObject var m: AppModel
    @State private var q = ""
    @State private var onlyCodes = false
    var items: [NotifItem] {
        m.history.filter { n in
            (!onlyCodes || n.code != nil) &&
            (q.isEmpty || n.title.localizedCaseInsensitiveContains(q) || n.msg.localizedCaseInsensitiveContains(q) || n.appName.contains(q))
        }
    }
    var body: some View {
        HStack {
            Text("通知记录").font(.largeTitle.bold())
            Spacer()
            Button(role: .destructive) { m.clearHistory() } label: { Label("清空", systemImage: "trash") }.disabled(m.history.isEmpty)
        }
        HStack {
            TextField("搜索联系人、内容、App…", text: $q).textFieldStyle(.roundedBorder)
            Toggle("只看验证码", isOn: $onlyCodes).toggleStyle(.checkbox)
        }
        Card(title: "共 \(items.count) 条") {
            if items.isEmpty { Text("没有记录").foregroundStyle(.secondary) }
            ForEach(items) { n in NotifRow(n: n); Divider() }
        }
    }
}

/// A number you can type or nudge: "label  [ 12 ] unit  (−|+)"
struct NumField: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String
    var note: String? = nil
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading)
            Stepper("", value: $value, in: range).labelsHidden()
        }
        if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
    }
}

struct LeavePane: View {
    @EnvironmentObject var m: AppModel
    @State private var sensorNoOne = 30
    @State private var sensorRange = 3
    @State private var loadedSensor = false
    var farBinding: Binding<Int> { Binding(get: { Int((m.radarFarMeters * 10).rounded()) }, set: { m.radarFarMeters = Double($0) / 10 }) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("离开与返回").font(.largeTitle.bold())
            Spacer()
            Toggle("", isOn: $m.leaveEnabled).toggleStyle(.switch).controlSize(.large).labelsHidden()
                .help(m.leaveEnabled ? "点击关闭整个离开检测" : "点击开启离开检测")
        }
        Text(m.leaveEnabled ? summary : "已关闭：不会因为你离开而暂停、静音或锁屏。").foregroundStyle(m.leaveEnabled ? .secondary : Color.orange)
        Group {

        // ---- live status
        Card(title: "当前状态", icon: "waveform.path.ecg") {
            HStack {
                Text(m.leaveStatus.isEmpty ? "—" : m.leaveStatus).font(.headline)
                Spacer()
                if let c = m.awayCountdown { Text("\(c) 秒后执行").foregroundStyle(.orange).font(.headline.monospacedDigit()) }
            }
            if m.phoneEnabled && m.radarEnabled {
                Picker("两种检测同时开启时", selection: $m.combineMode) {
                    Text("都判定离开才执行（更稳）").tag(0); Text("任意一个判定离开就执行（更快）").tag(1)
                }
                Text(m.combineMode == 0 ? "回来时：任意一个判定你回来了，就算回来。" : "回来时：两个都判定你回来了，才算回来。").font(.caption).foregroundStyle(.secondary)
            }
        }

        // ---- iPhone signal
        Card(title: "iPhone 信号检测", icon: "iphone.radiowaves.left.and.right") {
            Toggle("启用 iPhone 信号检测", isOn: $m.phoneEnabled)
            if m.phoneEnabled {
                HStack(spacing: 14) {
                    SignalBars(rssi: m.rssi, threshold: m.lockThreshold)
                    Text(m.link == .connected ? "当前信号 \(Int(m.rssi)) dBm" : "iPhone 未连接").font(.headline.monospacedDigit())
                    Spacer()
                    if let s = m.phoneAwayFor { Text("已判定远离 \(s) 秒").foregroundStyle(.orange).font(.subheadline.monospacedDigit()) }
                }
                NumField(label: "信号低于此值视为离开", value: $m.lockThreshold, range: -110 ... -40, unit: "dBm",
                         note: "数值越小越远：约 -65 贴身 · -75 两三米 · -85 隔一个房间。")
                NumField(label: "持续多少秒才判定离开", value: $m.awayDelay, range: 0...600, unit: "秒")
                NumField(label: "信号高于此值视为回来", value: $m.phoneReturnRSSI, range: -110 ... -40, unit: "dBm",
                         note: "建议比「离开」值高 5–10，避免在边界来回跳。")
                Toggle("蓝牙断开也算离开", isOn: $m.phoneDisconnectIsAway)
            }
        }

        // ---- radar
        Card(title: "人在雷达检测", icon: "sensor.fill") {
            if m.radarConfig == nil {
                Text("未配置人在雷达。可在「设备与设置」里接入米家人体存在传感器。").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("启用雷达检测", isOn: $m.radarEnabled)
                if m.radarEnabled {
                    RadarStatusRow()
                    if !m.radarFresh { Text("雷达暂时读不到数据。").font(.caption).foregroundStyle(.orange) }
                    if let s = m.radarAwayFor { Text("雷达已判定无人 \(s) 秒").foregroundStyle(.orange).font(.subheadline.monospacedDigit()) }
                    NumField(label: "雷达报「无人」后再等", value: $m.radarLeaveSeconds, range: 0...600, unit: "秒",
                             note: "传感器自己要先确认一段时间才会报「无人」（见下方）。这里是在那之后额外等待的时间，0 表示立即。")
                    NumField(label: "距离超过此值也算离开（0 = 不用）", value: farBinding, range: 0...60, unit: "×0.1 米",
                             note: m.radarFarMeters > 0 ? String(format: "当前：离雷达超过 %.1f 米即开始计时。", m.radarFarMeters) : "例如填 15 表示 1.5 米：你起身走远时比等「无人」更快。")
                    Divider()
                    Text("传感器自身设置（写入雷达，米家里也会同步改变）").font(.subheadline.bold())
                    NumField(label: "无人判定时间", value: $sensorNoOne, range: 5...1800, unit: "秒",
                             note: "多久没检测到人，雷达才报「无人」。当前雷达：\(m.radarReading?.noOneSeconds.map { "\($0) 秒" } ?? "未知")")
                    NumField(label: "检测距离", value: $sensorRange, range: 1...5, unit: "米",
                             note: "当前雷达：\(m.radarReading?.rangeMeters.map { "\($0) 米" } ?? "未知")")
                    HStack {
                        Button("写入雷达") { m.writeRadar(2, 2, sensorNoOne); m.writeRadar(3, 4, sensorRange) }
                        Text("约 1–2 秒后生效").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(m.$radarReading) { r in
            guard !loadedSensor, let r else { return }
            if let v = r.noOneSeconds { sensorNoOne = v }; if let v = r.rangeMeters { sensorRange = v }
            loadedSensor = r.noOneSeconds != nil
        }

        // ---- actions
        Card(title: "离开时执行（从判定离开那一刻起计时）", icon: "figure.walk.departure") {
            ActionRow(title: "暂停 Mac 上的视频、直播、音乐", on: $m.pauseMediaOnLeave, delay: $m.pauseDelay)
            ActionRow(title: "Mac 静音", on: $m.muteOnLeave, delay: $m.muteDelay)
            ActionRow(title: "锁定屏幕", on: $m.autoLock, delay: $m.lockDelay)
            HStack {
                Button { m.performLeave(test: true) } label: { Label("立即模拟一次离开", systemImage: "play.fill") }
                if m.autoLock { Text("会真的锁屏").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let t = m.lastLeave { Text("上次离开：\(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }
        }

        Card(title: "回来时", icon: "figure.walk.arrival") {
            NumField(label: "判定回来后再等", value: $m.returnConfirmSeconds, range: 0...120, unit: "秒", note: "0 表示一检测到你就算回来。")
            Toggle("自动点亮屏幕（等你输入密码）", isOn: $m.wakeOnReturn)
            Toggle("恢复声音（仅限离开时由本程序静音的情况）", isOn: $m.unmuteOnReturn).disabled(!m.muteOnLeave)
            if let t = m.lastReturn { Text("上次回来：\(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
        }
        }
        .disabled(!m.leaveEnabled)
        .opacity(m.leaveEnabled ? 1 : 0.45)
    }

    var summary: String {
        let radar = m.radarEnabled && m.radarConfig != nil
        switch (m.phoneEnabled, radar) {
        case (true, true): return m.combineMode == 0 ? "已开启：iPhone 信号和雷达都判定你离开时，执行下面的动作。" : "已开启：iPhone 信号或雷达任意一个判定你离开，就执行下面的动作。"
        case (true, false): return "已开启：只用 iPhone 信号判断是否离开。"
        case (false, true): return "已开启：只用人在雷达判断是否离开。"
        default: return "已开启，但没有启用任何检测方式——请在下面打开 iPhone 信号或雷达。"
        }
    }
}

struct ActionRow: View {
    let title: String
    @Binding var on: Bool
    @Binding var delay: Int
    var body: some View {
        HStack {
            Toggle(title, isOn: $on)
            Spacer()
            if on {
                Text("离开后")
                TextField("", value: Binding(get: { delay }, set: { delay = min(max($0, 0), 3600) }), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                Text("秒")
                Stepper("", value: $delay, in: 0...3600).labelsHidden()
            }
        }
    }
}

struct DevicePane: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmUnpair = false
    var body: some View {
        Text("设备与设置").font(.largeTitle.bold())
        Card(title: "通知", icon: "bell.badge.fill") {
            Toggle("收到验证码自动复制到剪贴板", isOn: $m.copyCodes)
            Toggle("弹窗时播放提示音", isOn: $m.playSound)
            Stepper("普通弹窗显示 \(m.bannerSeconds) 秒（来电固定 40 秒）", value: $m.bannerSeconds, in: 3...30)
            HStack {
                Button { NotificationPoster.shared.post(uid: 0xFFFFF000, app: "com.tencent.xin", isCall: false, title: "张三", subtitle: "", message: "晚上一起吃饭吗？我在公司楼下那家火锅店订了位，七点见，不见不散。顺便把上次借你的书带过来。", code: nil) } label: { Label("测试：微信", systemImage: "message") }
                Button { NotificationPoster.shared.post(uid: 0xFFFFF001, app: "com.apple.MobileSMS", isCall: false, title: "106550", subtitle: "", message: "【淘宝】验证码 384921，5 分钟内有效，请勿泄露。", code: "384921") } label: { Label("测试：验证码", systemImage: "key") }
                Button { NotificationPoster.shared.post(uid: 0xFFFFF002, app: "com.apple.mobilephone", isCall: true, title: "妈妈", subtitle: "", message: "", code: nil) } label: { Label("测试：来电", systemImage: "phone") }
            }
        }
        RadarSetupCard()
        Card(title: "ESP32 板子", icon: "cpu") {
            LabeledContent("USB 端口", value: m.port ?? "未检测到")
            LabeledContent("状态", value: m.statusText)
            HStack {
                Text("彩灯测试：")
                Button("红") { m.ledTest(60, 0, 0) }; Button("绿") { m.ledTest(0, 40, 0) }
                Button("蓝") { m.ledTest(0, 0, 50) }; Button("恢复自动") { m.ledTest(0, 0, 0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("板载按键（BOOT）").font(.subheadline.bold())
                Text("单击：熄灭未读提醒灯　·　双击：下一首　·　长按：挂断来电 / 播放暂停").font(.caption).foregroundStyle(.secondary)
                Text("彩灯：微信绿 · 短信蓝 · 其他白（呼吸）· 来电红色快闪 · 等待连接蓝色短闪").font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { confirmUnpair = true } label: { Label("清除板子上的配对信息", systemImage: "link.badge.plus") }
                .confirmationDialog("清除后需要用 iPhone 上的「Mac通知」App 重新配对。", isPresented: $confirmUnpair) {
                    Button("清除配对", role: .destructive) { m.unpair() }
                }
        }
        Card(title: "程序", icon: "macwindow") {
            Toggle("开机自动启动（后台运行，不弹出此窗口）", isOn: $m.launchAtLogin)
            HStack {
                Button { NSWorkspace.shared.open(logURL) } label: { Label("打开日志", systemImage: "doc.text") }
                Button(role: .destructive) { NSApp.terminate(nil) } label: { Label("退出程序", systemImage: "power") }
            }
        }
    }
}


// MARK: - Rules & speech
struct RulesPane: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Text("规则与播报").font(.largeTitle.bold())
        Text("提示：在「通知记录」里右键某条通知，可一键设为重要或静默。").foregroundStyle(.secondary)
        Card(title: "规则（从上到下匹配；忽略 > 重要 > 静默）", icon: "list.bullet.rectangle") {
            if m.rules.isEmpty { Text("还没有规则").foregroundStyle(.secondary) }
            ForEach($m.rules) { $r in
                HStack(spacing: 10) {
                    Toggle("", isOn: $r.enabled).labelsHidden()
                    Picker("", selection: $r.field) { ForEach(Rule.Field.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                    TextField(r.field == .app ? "如：币安 或 com.czzhao.binance" : r.field == .sender ? "如：老板、家人群" : "如：紧急、到账", text: $r.pattern)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $r.action) { ForEach(Rule.Action.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 80)
                    Button { m.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button { m.addRule(.sender, "", .important) } label: { Label("添加规则", systemImage: "plus") }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Rule.Action.allCases) { a in Text("\(a.rawValue)：\(a.help)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        Card(title: "免打扰时段", icon: "moon.fill") {
            Toggle("开启（期间普通通知只记录不弹窗；来电和「重要」照常提醒）", isOn: $m.quietEnabled)
            HStack {
                Picker("从", selection: $m.quietStart) { ForEach(0..<24) { Text("\($0):00").tag($0) } }.frame(width: 140)
                Picker("到", selection: $m.quietEnd) { ForEach(0..<24) { Text("\($0):00").tag($0) } }.frame(width: 140)
                if m.inQuietHours { Text("现在处于免打扰").foregroundStyle(.orange).font(.caption) }
            }.disabled(!m.quietEnabled)
        }
        Card(title: "语音播报", icon: "speaker.wave.2.fill") {
            Picker("播报", selection: $m.speakMode) {
                Text("关闭").tag(0); Text("只播来电").tag(1); Text("来电 + 重要").tag(2); Text("全部").tag(3)
            }.pickerStyle(.segmented)
            Text("Mac 静音、离开状态、免打扰时段不会播报。").font(.caption).foregroundStyle(.secondary)
            Button { Speaker.shared.say("微信，张三：今晚一起吃饭吗") } label: { Label("试听", systemImage: "play.circle") }
        }
    }
}

// MARK: - Buttons
struct ButtonsPane: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Text("按键与快捷键").font(.largeTitle.bold())
        Text("板子上的 BOOT 键。快捷键由板子以 USB 键盘身份发送，无需辅助功能权限。程序没运行时按键按默认方式工作。").foregroundStyle(.secondary)
        Card(title: "手势", icon: "hand.tap.fill") {
            row("单击", "single", $m.btnSingle)
            row("双击", "double", $m.btnDouble)
            row("三击", "triple", $m.btnTriple)
            row("长按", "long", $m.btnLong)
            if let b = m.lastButton { Text("最近一次：\(["single": "单击", "double": "双击", "triple": "三击", "long": "长按"][b] ?? b)").font(.caption).foregroundStyle(.secondary) }
        }
    }
    func row(_ name: String, _ key: String, _ sel: Binding<ButtonAction>) -> some View {
        HStack {
            Text(name).frame(width: 40, alignment: .leading)
            Picker("", selection: sel) { ForEach(ButtonAction.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 300)
            if sel.wrappedValue == .custom {
                TextField("如 cmd+shift+4、ctrl+up、f5", text: Binding(get: { m.customKeys[key] ?? "" }, set: { m.customKeys[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                if let c = m.customKeys[key], !c.isEmpty, parseShortcut(c) == nil { Text("无法识别").foregroundStyle(.red).font(.caption) }
            }
            Spacer()
            Button("试一下") { m.runButton(sel.wrappedValue, gesture: key) }.controlSize(.small)
        }
    }
}

// MARK: - Claude Code
struct ClaudePane: View {
    @EnvironmentObject var m: AppModel
    var label: (String, Color) {
        switch m.claudeState {
        case "working": return ("工作中", .cyan)
        case "waiting": return ("等你确认", .purple)
        case "done": return ("已完成，未查看", .purple)
        default: return ("空闲", .secondary)
        }
    }
    var body: some View {
        Text("Claude Code").font(.largeTitle.bold())
        Card(title: "当前状态", icon: "sparkles") {
            HStack {
                Circle().fill(label.1).frame(width: 12, height: 12)
                Text(label.0).font(.title3.bold())
                if !m.claudeDetail.isEmpty { Text(m.claudeDetail).foregroundStyle(.secondary) }
            }
            Text("板子彩灯：工作中 = 青色慢呼吸 · 等你确认 = 紫色闪烁 · 完成 = 紫色呼吸（单击板子按键熄灭）").font(.caption).foregroundStyle(.secondary)
        }
        Card(title: "设置", icon: "slider.horizontal.3") {
            Toggle("启用 Claude Code 提醒", isOn: $m.claudeEnabled)
            Toggle("完成时弹窗", isOn: $m.claudeBannerDone)
            Toggle("语音播报「Claude 需要你确认 / 完成了」", isOn: $m.claudeSpeak)
            HStack {
                Button("模拟：工作中") { m.claudeEvent("working", ["session_id": "test", "cwd": "/测试项目"]) }
                Button("模拟：等你确认") { m.claudeEvent("waiting", ["session_id": "test", "cwd": "/测试项目", "message": "Claude 需要你的许可才能运行命令"]) }
                Button("模拟：完成") { m.claudeEvent("done", ["session_id": "test", "cwd": "/测试项目"]) }
                Button("清除") { m.claudeEvent("end", ["session_id": "test"]) }
            }.controlSize(.small)
            Text("已在 ~/.claude/settings.json 配置钩子：提交指令 → 工作中，需要确认 → 等你确认，回答结束 → 完成。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Offline forwarding
struct ForwardPane: View {
    @EnvironmentObject var m: AppModel
    @State private var ssid = ""
    @State private var pass = ""
    @State private var token = ""
    @State private var chat = ""
    var body: some View {
        Text("离线转发").font(.largeTitle.bold())
        Text("本程序 30 秒没响应（Mac 睡眠、程序退出）时，板子通过 Wi-Fi 把通知发到 Telegram。被「静默/忽略」的 App 不转发。密码和 Token 只保存在板子里。").foregroundStyle(.secondary)
        Card(title: "Wi-Fi（仅支持 2.4GHz）", icon: "wifi") {
            LabeledContent("状态", value: m.wifiStatus)
            HStack {
                TextField("Wi-Fi 名称", text: $ssid).textFieldStyle(.roundedBorder)
                SecureField("密码", text: $pass).textFieldStyle(.roundedBorder)
                Button("保存到板子") { m.saveWifi(ssid: ssid, pass: pass); pass = "" }.disabled(ssid.isEmpty)
            }
        }
        Card(title: "Telegram 机器人", icon: "paperplane.fill") {
            LabeledContent("板子上已配置", value: m.boardHasTelegram ? "是（Chat \(m.tgChat)）" : "否")
            HStack {
                SecureField("Bot Token（找 @BotFather 创建机器人获得）", text: $token).textFieldStyle(.roundedBorder)
                TextField("Chat ID（找 @userinfobot 获得）", text: $chat).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("保存到板子") { m.saveTelegram(token: token, chat: chat); token = "" }.disabled(token.isEmpty || chat.isEmpty)
            }
            HStack {
                Button { m.testTelegram() } label: { Label("发送测试消息", systemImage: "paperplane") }
                Text(m.lastForward).font(.caption).foregroundStyle(.secondary)
            }
            Text("记得先在 Telegram 里给你的机器人发一句话（/start），它才能给你发消息。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { ssid = m.wifiSSID; chat = m.tgChat }
    }
}

struct RadarStatusRow: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let r = m.radarReading
        HStack(spacing: 14) {
            Image(systemName: r?.occupied == true ? "person.fill.checkmark" : r?.occupied == false ? "person.fill.xmark" : "person.fill.questionmark")
                .font(.system(size: 26)).foregroundStyle(r?.occupied == true ? .green : r?.occupied == false ? .orange : .secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.radarConfig?.name ?? "人在雷达").font(.headline)
                Text(m.radarStatus + (r?.occupied == true ? (r?.presentMinutes).map { " · 已在座 \($0) 分钟" } ?? "" : r?.occupied == false ? (r?.absentMinutes).map { " · 已离开 \($0) 分钟" } ?? "" : ""))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = r?.distance { VStack(alignment: .trailing) { Text(String(format: "%.2f 米", d)).font(.title3.monospacedDigit()); Text("距离").font(.caption).foregroundStyle(.secondary) } }
            if let l = r?.lux { VStack(alignment: .trailing) { Text("\(Int(l)) lx").font(.title3.monospacedDigit()); Text("光照").font(.caption).foregroundStyle(.secondary) } }
        }
    }
}

struct RadarSetupCard: View {
    @EnvironmentObject var m: AppModel
    @State private var ip = ""
    @State private var token = ""
    @State private var gw = ""
    @State private var sensor = ""
    @State private var name = ""
    var body: some View {
        Card(title: "人在雷达（米家）", icon: "sensor.fill") {
            if m.radarConfig != nil { RadarStatusRow() }
            Text("通过米家网关在本地读取人体存在传感器，不经过云端。网关 IP、token 和设备 did 可从小米云端设备清单获得。").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("网关 IP"); TextField("192.168.1.10", text: $ip) }
                GridRow { Text("网关 token"); SecureField("32 位十六进制", text: $token) }
                GridRow { Text("网关 did"); TextField("例如 123456789", text: $gw) }
                GridRow { Text("传感器 did"); TextField("例如 1000000001", text: $sensor) }
                GridRow { Text("名称"); TextField("人体存在传感器", text: $name) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    m.radarConfig = RadarConfig(gatewayIP: ip.trimmingCharacters(in: .whitespaces), gatewayToken: token.trimmingCharacters(in: .whitespaces).lowercased(),
                                                gatewayDid: gw.trimmingCharacters(in: .whitespaces), sensorDid: sensor.trimmingCharacters(in: .whitespaces),
                                                name: name.isEmpty ? "人体存在传感器" : name)
                }.disabled(ip.isEmpty || token.count != 32 || sensor.isEmpty)
                if m.radarConfig != nil { Button("移除雷达", role: .destructive) { m.radarConfig = nil } }
                Spacer()
                Text(m.radarStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let c = m.radarConfig { ip = c.gatewayIP; token = c.gatewayToken; gw = c.gatewayDid; sensor = c.sensorDid; name = c.name }
        }
    }
}
