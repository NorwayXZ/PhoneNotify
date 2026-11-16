import Foundation
import Darwin

// MARK: - Serial bridge to ESP32
final class SerialBridge {
    var fd: Int32 = -1
    var source: DispatchSourceRead?
    var buffer = Data()
    var port: String?
    var onLine: ((String) -> Void)?
    var onState: ((String) -> Void)?
    let q = DispatchQueue(label: "serial")

    func start() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.ensureOpen() }
        ensureOpen()
    }

    func findPort() -> String? {
        let ports = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return ports.filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.wchusbserial") || $0.hasPrefix("cu.usbserial") }
            .sorted().first.map { "/dev/" + $0 }
    }

    func ensureOpen() {
        guard fd < 0 else { return }
        guard let p = findPort() else { onState?("未检测到 ESP32（请插上 USB）"); return }
        let f = open(p, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { onState?("无法打开 \(p)"); return }
        var t = termios(); tcgetattr(f, &t); cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(f, TCSANOW, &t)
        // Native USB (TinyUSB CDC) only sends data while DTR is asserted; the CH343 COM port must have
        // DTR/RTS released or its auto-reset circuit holds the chip in reset / BOOT.
        if SerialBridge.nativeUSBPresent() {
            var dtr: Int32 = TIOCM_DTR; _ = ioctl(f, TIOCMBIS, &dtr)
            var rts: Int32 = TIOCM_RTS; _ = ioctl(f, TIOCMBIC, &rts)
        } else {
            var bits: Int32 = TIOCM_DTR | TIOCM_RTS; _ = ioctl(f, TIOCMBIC, &bits)
        }
        fd = f; port = p
        log("serial open \(p)")
        onState?("已连接 ESP32，等待 iPhone…")
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: q)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { close(f) }
        source = src; src.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.send("PING") }
    }

    /// Espressif VID 0x303A on the USB bus → board is on its native USB port.
    static func nativeUSBPresent() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-p", "IOUSB", "-l", "-w0"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.contains("\"idVendor\" = 12346")
    }

    func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { DispatchQueue.main.async { self.closePort() } }
            return
        }
        buffer.append(contentsOf: tmp[0..<n])
        while let i = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("{") { DispatchQueue.main.async { self.onLine?(line) } }
        }
    }

    func closePort() {
        guard fd >= 0 else { return }
        log("serial closed"); source?.cancel(); source = nil; fd = -1; buffer.removeAll()
        onState?("ESP32 已断开，等待重新插入…")
    }

    func send(_ s: String) {
        guard fd >= 0 else { return }
        let d = Array((s + "\n").utf8)
        _ = d.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

