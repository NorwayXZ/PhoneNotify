import SwiftUI
import CoreBluetooth

let MAC_SERVICE = CBUUID(string: "B7A6E5C4-1D2E-4F30-9A8B-0C1D2E3F4A5B")
let MAC_CHAR    = CBUUID(string: "B7A6E5C4-1D2E-4F30-9A8B-0C1D2E3F4A5C")

/// iPhone connects (as central) to the Mac's advertised service and reads an encrypted
/// characteristic → new bond; the Mac then reads ANCS over that link.
final class Link: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "启动中…"
    @Published var lines: [String] = []
    private var cm: CBCentralManager!
    private var mac: CBPeripheral?

    override init() {
        super.init()
        cm = CBCentralManager(delegate: self, queue: .main,
                              options: [CBCentralManagerOptionRestoreIdentifierKey: "macnotify.central"])
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        print("[iOS] \(s)"); lines.insert("\(f.string(from: Date())) \(s)", at: 0)
        if lines.count > 80 { lines.removeLast() }
        status = s
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first { mac = p; p.delegate = self }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { log("蓝牙不可用 \(c.state.rawValue)"); return }
        if let p = mac, p.state == .connected { p.discoverServices([MAC_SERVICE]); return }
        if let id = UserDefaults.standard.string(forKey: "esp"), let u = UUID(uuidString: id),
           let p = c.retrievePeripherals(withIdentifiers: [u]).first { attachESP(p); return }
        log("扫描 ESP32（MacNotify）…")
        c.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name == "MacNotify" else { return }
        c.stopScan(); attachESP(p)
    }
    func attachESP(_ p: CBPeripheral) {
        mac = p; p.delegate = self
        UserDefaults.standard.set(p.identifier.uuidString, forKey: "esp")
        log("连接 ESP32…（iPhone 弹出配对请求请点“配对”，再点“允许”通知）")
        cm.connect(p, options: [CBConnectPeripheralOptionEnableTransportBridgingKey: false])
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("✅ 已连接 ESP32，等待配对…（之后保持此 App 在后台即可）"); p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败 \(error?.localizedDescription ?? "")"); c.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("断开 \(error?.localizedDescription ?? "")，自动重连…"); c.connect(p, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("服务：\((p.services ?? []).map { $0.uuid.uuidString }.joined(separator: ","))")
        if let s = p.services?.first(where: { $0.uuid == MAC_SERVICE }) { p.discoverCharacteristics([MAC_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == MAC_CHAR }) else { return }
        p.readValue(for: ch); p.setNotifyValue(true, for: ch)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error {
            log("配对未完成：\(error.localizedDescription)，5 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if p.state == .connected { p.readValue(for: ch) } }
            return
        }
        log("✅ 已与 ESP32 配对（保持此 App 在后台即可）")
    }
}

@main
struct CompanionApp: App {
    @StateObject var link = Link()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("状态") { Text(link.status).font(.headline) }
                    Section("日志") { ForEach(link.lines, id: \.self) { Text($0).font(.caption.monospaced()) } }
                }.navigationTitle("Mac 通知")
            }
        }
    }
}
