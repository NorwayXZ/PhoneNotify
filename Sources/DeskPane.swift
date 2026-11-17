import SwiftUI
import Charts

struct DeskPane: View {
    @ObservedObject var log = PresenceLog.shared
    @EnvironmentObject var m: AppModel
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var range = 14
    private let cal = Calendar.current
    private let merge: TimeInterval = 120      // short breaks under 2 min are joined in the list

    var body: some View {
        let sessions = log.sessions(on: day, mergeGap: merge)
        let total = log.total(on: day)
        HStack(alignment: .firstTextBaseline) {
            Text("在座记录").font(.largeTitle.bold())
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Text(dayTitle(day)).font(.headline).frame(minWidth: 130)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.disabled(cal.isDateInToday(day))
            if !cal.isDateInToday(day) { Button("今天") { day = cal.startOfDay(for: Date()) } }
        }
        Text("根据人在雷达记录你坐在电脑前的时间，按天（0 点到 24 点）统计。Mac 关机或睡眠期间不记录。")
            .font(.caption).foregroundStyle(.secondary)

        Card(title: "这一天", icon: "clock.fill") {
            HStack(spacing: 0) {
                stat("在电脑前", total > 0 ? formatDuration(total) : "—", big: true)
                stat("第一次坐下", sessions.first.map { time($0.start) } ?? "—")
                stat("最后离开", sessions.last.map { log.current != nil && cal.isDateInToday(day) && $0 == sessions.last ? "现在仍在座" : time($0.end) } ?? "—")
                stat("连续最长", sessions.map(\.duration).max().map(formatDuration) ?? "—")
                stat("离开次数", sessions.count > 1 ? "\(sessions.count - 1) 次" : "—")
            }
            DayTimeline(sessions: log.sessions(on: day), day: day)
        }

        Card(title: "时间段", icon: "list.bullet") {
            if sessions.isEmpty { Text("这一天没有记录。").foregroundStyle(.secondary) }
            ForEach(sessions.reversed()) { s in
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(time(s.start)) – \(log.current != nil && s == sessions.last && cal.isDateInToday(day) ? "现在" : time(s.end))").monospacedDigit()
                    Spacer()
                    Text(formatDuration(s.duration)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !sessions.isEmpty { Text("离开不到 2 分钟的会合并成一段。").font(.caption).foregroundStyle(.tertiary) }
        }

        Card(title: "每天在电脑前的时长", icon: "chart.bar.fill") {
            Picker("", selection: $range) { Text("近 7 天").tag(7); Text("近 14 天").tag(14); Text("近 30 天").tag(30) }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            let days = (0..<range).reversed().map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date()))! }
            let pts = days.map { (day: $0, hours: log.total(on: $0) / 3600) }
            let recorded = pts.filter { $0.hours > 0 }
            let avg = recorded.isEmpty ? 0 : recorded.map(\.hours).reduce(0, +) / Double(recorded.count)
            Chart {
                ForEach(pts, id: \.day) { p in
                    BarMark(x: .value("日期", p.day, unit: .day), y: .value("小时", p.hours))
                        .foregroundStyle(cal.isDate(p.day, inSameDayAs: day) ? Color.accentColor : Color.accentColor.opacity(0.45))
                        .cornerRadius(3)
                }
                if avg > 0 {
                    RuleMark(y: .value("平均", avg)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) { Text(String(format: "平均 %.1f 小时", avg)).font(.caption).foregroundStyle(.orange) }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: range > 14 ? 5 : range > 7 ? 2 : 1)) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } } } }
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { loc in
                        if let d: Date = proxy.value(atX: loc.x - g[proxy.plotAreaFrame].origin.x) { day = cal.startOfDay(for: d) }
                    }
                }
            }
            .frame(height: 180)
            HStack {
                Text("合计 \(formatDuration(pts.map(\.hours).reduce(0, +) * 3600))").font(.caption)
                Text("· 有记录 \(recorded.count) 天").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("点柱子可查看那一天").font(.caption).foregroundStyle(.tertiary)
            }
        }
        if m.radarConfig == nil {
            Text("还没接入人在雷达，暂时无法记录。").foregroundStyle(.orange)
        }
    }

    private func shift(_ d: Int) { day = cal.date(byAdding: .day, value: d, to: day)! }
    private func time(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    private func dayTitle(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "今天 · " + d.formatted(.dateTime.month().day()) }
        if cal.isDateInYesterday(d) { return "昨天 · " + d.formatted(.dateTime.month().day()) }
        return d.formatted(.dateTime.month().day().weekday(.abbreviated))
    }
    @ViewBuilder private func stat(_ t: String, _ v: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(big ? .title2.bold().monospacedDigit() : .headline.monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 0–24 h bar with the occupied segments in green.
struct DayTimeline: View {
    let sessions: [DeskSession]
    let day: Date
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                    ForEach(sessions) { s in
                        let x0 = s.start.timeIntervalSince(day) / 86400 * w
                        let x1 = s.end.timeIntervalSince(day) / 86400 * w
                        RoundedRectangle(cornerRadius: 2).fill(.green).frame(width: max(1.5, x1 - x0)).offset(x: x0)
                            .help("\(s.start.formatted(date: .omitted, time: .shortened)) – \(s.end.formatted(date: .omitted, time: .shortened))")
                    }
                    if Calendar.current.isDateInToday(day) {
                        Rectangle().fill(.orange).frame(width: 1.5).offset(x: Date().timeIntervalSince(day) / 86400 * w)
                    }
                }
            }.frame(height: 26)
            HStack {
                ForEach([0, 3, 6, 9, 12, 15, 18, 21, 24], id: \.self) { h in
                    Text("\(h)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: h == 0 ? .leading : h == 24 ? .trailing : .center)
                }
            }
        }
    }
}
