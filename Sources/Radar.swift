import Foundation
import CryptoKit
import CommonCrypto

// Mi Home presence radar (e.g. Linptech linp.sensor_occupy.hb01, BLE Mesh) read locally
// through a Xiaomi gateway with the miIO UDP protocol. No cloud traffic after setup.
// Config lives in ~/Library/Application Support/PhoneNotify/radar.json (0600), never in the repo.

struct RadarConfig: Codable, Equatable {
    var gatewayIP: String
    var gatewayToken: String      // 32 hex chars
    var gatewayDid: String
    var sensorDid: String
    var name: String = "人体存在传感器"
}

struct RadarReading: Equatable {
    var occupied: Bool?           // siid 2 piid 1
    var presentMinutes: Int?      // 2.3
    var absentMinutes: Int?       // 2.4
    var lux: Double?              // 2.5
    var distance: Double?         // 3.3 metres
    var approach: Int?            // 3.1  0 stop 1 approach 2 aloof
    var noOneSeconds: Int?        // 2.2 sensor's own "no one" judgement time
    var rangeMeters: Int?         // 3.4 detection range 1-5 m
    var at = Date()
}

final class MiRadar {
    static var configURL: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhoneNotify")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("radar.json")
    }
    static func loadConfig() -> RadarConfig? {
        guard let d = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(RadarConfig.self, from: d)
    }
    static func saveConfig(_ c: RadarConfig?) {
        guard let c else { try? FileManager.default.removeItem(at: configURL); return }
        if let d = try? JSONEncoder().encode(c) {
            FileManager.default.createFile(atPath: configURL.path, contents: d, attributes: [.posixPermissions: 0o600])
        }
    }

    var config: RadarConfig? { didSet { q.async { self.resetSession() } } }
    var onReading: ((RadarReading) -> Void)?
    var onError: ((String) -> Void)?

    private let q = DispatchQueue(label: "radar")
    private var timer: DispatchSourceTimer?
    private var sock: Int32 = -1
    private var devId = Data(), stamp: UInt32 = 0, stampAt = Date(), msgId = 1
    private var key = Data(), iv = Data(), token = Data()
    private var failures = 0

    func start(interval: Double = 1.0) {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume(); timer = t
    }

    /// Write one MIoT property on the sensor (through the gateway).
    func set(siid: Int, piid: Int, value: Int) {
        q.async {
            guard let c = self.config else { return }
            do {
                if self.devId.isEmpty { try self.handshake(c) }
                let r = try self.send(method: "set_properties", params: [["did": c.sensorDid, "siid": siid, "piid": piid, "value": value]])
                log("radar set \(siid).\(piid)=\(value) -> \(r["result"] ?? "?")")
            } catch { log("radar set failed: \(error)") }
        }
    }

    private func resetSession() { devId = Data(); failures = 0 }

    private func poll() {
        guard let c = config, c.gatewayToken.count == 32 else { return }
        do {
            if devId.isEmpty { try handshake(c) }
            let props: [(Int, Int)] = [(2, 1), (2, 2), (2, 3), (2, 4), (2, 5), (3, 1), (3, 3), (3, 4)]
            let params = props.map { ["did": c.sensorDid, "siid": $0.0, "piid": $0.1] as [String: Any] }
            let r = try send(method: "get_properties", params: params)
            guard let list = r["result"] as? [[String: Any]] else { throw err("网关返回异常") }
            var rd = RadarReading()
            for x in list where (x["code"] as? Int ?? -1) == 0 {
                let v = x["value"]; let key = "\(x["siid"] ?? 0).\(x["piid"] ?? 0)"
                switch key {
                case "2.1": if let n = v as? Int { rd.occupied = n == 1 ? true : n == 0 ? false : nil }
                case "2.2": rd.noOneSeconds = v as? Int
                case "3.4": rd.rangeMeters = v as? Int
                case "2.3": rd.presentMinutes = v as? Int
                case "2.4": rd.absentMinutes = v as? Int
                case "2.5": rd.lux = (v as? NSNumber)?.doubleValue
                case "3.1": rd.approach = v as? Int
                case "3.3": rd.distance = (v as? NSNumber)?.doubleValue
                default: break
                }
            }
            failures = 0
            DispatchQueue.main.async { self.onReading?(rd) }
        } catch {
            failures += 1; devId = Data()
            if failures == 3 || failures % 30 == 0, let ip = discover(c.gatewayDid), ip != c.gatewayIP {
                log("radar: gateway moved \(c.gatewayIP) -> \(ip)")
                var n = c; n.gatewayIP = ip; config = n; MiRadar.saveConfig(n)
            }
            let msg = (error as? RadarError)?.msg ?? "\(error)"
            DispatchQueue.main.async { self.onError?(msg) }
        }
    }

    // MARK: miIO protocol
    struct RadarError: Error { let msg: String }
    private func err(_ s: String) -> RadarError { RadarError(msg: s) }

    private func openSocket() throws {
        if sock >= 0 { return }
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw err("socket 失败") }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    private func addr(_ ip: String) -> sockaddr_in {
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(54321).bigEndian
        inet_pton(AF_INET, ip, &a.sin_addr); return a
    }
    private func sendRaw(_ d: Data, to ip: String) {
        var a = addr(ip)
        _ = d.withUnsafeBytes { b in withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, b.baseAddress, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    }
    private func recvRaw() -> (Data, String)? {
        var buf = [UInt8](repeating: 0, count: 4096); var a = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &len) } }
        guard n > 0 else { return nil }
        var ipb = [CChar](repeating: 0, count: 32); inet_ntop(AF_INET, &a.sin_addr, &ipb, 32)
        return (Data(buf[0..<n]), String(cString: ipb))
    }
    private static let hello = Data([0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xff, count: 28))

    private func handshake(_ c: RadarConfig) throws {
        try openSocket()
        token = Data(hex: c.gatewayToken)
        key = Data(Insecure.MD5.hash(data: token)); iv = Data(Insecure.MD5.hash(data: key + token))
        sendRaw(Self.hello, to: c.gatewayIP)
        guard let (h, _) = recvRaw(), h.count >= 32 else { throw err("网关无响应（\(c.gatewayIP)）") }
        devId = h.subdata(in: 8..<12)
        stamp = h.subdata(in: 12..<16).reduce(0) { $0 << 8 | UInt32($1) }; stampAt = Date()
    }

    private func discover(_ did: String) -> String? {
        guard (try? openSocket()) != nil, let want = UInt32(did) else { return nil }
        for _ in 0..<2 { sendRaw(Self.hello, to: "255.255.255.255") }
        let end = Date().addingTimeInterval(3)
        while Date() < end, let (h, ip) = recvRaw() {
            if h.count >= 16, h.subdata(in: 8..<12).reduce(0, { $0 << 8 | UInt32($1) }) == want { return ip }
        }
        return nil
    }

    private func send(method: String, params: Any) throws -> [String: Any] {
        msgId += 1
        let body = try JSONSerialization.data(withJSONObject: ["id": msgId, "method": method, "params": params])
        let ct = try aes(body, encrypt: true)
        var hdr = Data([0x21, 0x31]); hdr.append(be16(UInt16(32 + ct.count))); hdr.append(Data(count: 4)); hdr.append(devId)
        hdr.append(be32(stamp &+ UInt32(Date().timeIntervalSince(stampAt))))
        let sum = Data(Insecure.MD5.hash(data: hdr + token + ct))
        sendRaw(hdr + sum + ct, to: config?.gatewayIP ?? "")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let (r, _) = recvRaw() else { break }
            guard r.count > 32, let pt = try? aes(r.subdata(in: 32..<r.count), encrypt: false) else { continue }
            let trimmed = pt.prefix { $0 != 0 }
            guard let j = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else { continue }
            if (j["id"] as? Int) == msgId { return j }
        }
        throw err("网关读取超时")
    }

    private func aes(_ d: Data, encrypt: Bool) throws -> Data {
        var out = Data(count: d.count + kCCBlockSizeAES128); var moved = 0
        let st = out.withUnsafeMutableBytes { o in d.withUnsafeBytes { i in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, kCCKeySizeAES128, v.baseAddress, i.baseAddress, d.count, o.baseAddress, o.count, &moved) } } } }
        guard st == kCCSuccess else { throw err("解密失败（token 不对？）") }
        return out.prefix(moved)
    }
    private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
}

extension Data {
    init(hex: String) {
        var d = Data(); var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
            if let b = UInt8(hex[i..<j], radix: 16) { d.append(b) }; i = j
        }
        self = d
    }
}
