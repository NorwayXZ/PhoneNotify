import Foundation

// Desk-presence log built from the radar's occupancy readings.
// Stored in ~/Library/Application Support/PhoneNotify/presence.json as a list of [start, end] sessions.
// Only recorded while PhoneNotify is running and the radar is reachable; gaps (Mac asleep/off) are left empty.

struct DeskSession: Codable, Hashable, Identifiable {
    var start: Date
    var end: Date
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

final class PresenceLog: ObservableObject {
    static let shared = PresenceLog()
    @Published private(set) var sessions: [DeskSession] = []
    @Published private(set) var current: DeskSession?

    private let gapLimit: TimeInterval = 90          // no reading for this long → close the session
    private var lastSave = Date.distantPast
    private var url: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhoneNotify")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("presence.json")
    }

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([DeskSession].self, from: d) { sessions = s }
    }

    /// Feed every radar reading. `noOneDelay` = sensor's own "no one" judgement time, subtracted from the end.
    func update(occupied: Bool?, at now: Date = Date(), noOneDelay: Int) {
        if let c = current, now.timeIntervalSince(c.end) > gapLimit {      // Mac slept / radar lost
            close(c); current = nil
        }
        switch occupied {
        case true?:
            if current == nil { current = DeskSession(start: now, end: now) } else { current!.end = now }
        case false?:
            if var c = current { c.end = max(c.start, min(c.end, now.addingTimeInterval(-Double(noOneDelay)))); close(c); current = nil }
        default: break
        }
        if now.timeIntervalSince(lastSave) > 30 { save() }
    }

    /// Close the open session (on quit).
    func flush() { if let c = current { close(c); current = nil }; save() }

    private func close(_ c: DeskSession) {
        guard c.duration >= 1 else { return }
        sessions.append(c)
        let cutoff = Date().addingTimeInterval(-400 * 86400)
        if let f = sessions.first, f.start < cutoff { sessions.removeAll { $0.start < cutoff } }
        save()
    }

    private func save() {
        lastSave = Date()
        var all = sessions; if let c = current { all.append(c) }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: queries
    var allSessions: [DeskSession] { current.map { sessions + [$0] } ?? sessions }

    /// Sessions clipped to one calendar day; gaps shorter than `mergeGap` seconds are joined.
    func sessions(on day: Date, mergeGap: TimeInterval = 0) -> [DeskSession] {
        let cal = Calendar.current
        let s = cal.startOfDay(for: day), e = cal.date(byAdding: .day, value: 1, to: s)!
        var out: [DeskSession] = []
        for x in allSessions where x.end > s && x.start < e {
            let c = DeskSession(start: max(x.start, s), end: min(x.end, e))
            if let last = out.last, c.start.timeIntervalSince(last.end) <= mergeGap { out[out.count - 1].end = max(last.end, c.end) }
            else { out.append(c) }
        }
        return out
    }
    func total(on day: Date) -> TimeInterval { sessions(on: day).reduce(0) { $0 + $1.duration } }
    var firstRecordDay: Date? { allSessions.first.map { Calendar.current.startOfDay(for: $0.start) } }
}

func formatDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60), h = m / 60
    return h > 0 ? "\(h) 小时 \(m % 60) 分" : "\(m) 分钟"
}
