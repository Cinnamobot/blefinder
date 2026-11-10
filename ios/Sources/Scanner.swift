import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable {
    let id: UUID
    var name: String
    var smoothedRSSI: Double
    var lastSeen: Date
}

/// Foreground BLE scanner. Reads advertisement RSSI only; never connects.
final class Scanner: NSObject, ObservableObject {
    @Published var devices: [BLEDevice] = []
    @Published var stateText: String = "Bluetooth初期化中…"
    @Published var isScanning = false
    @Published var targetID: UUID?
    /// Latest smoothed RSSI of the selected target (nil when not seen recently).
    @Published var targetRSSI: Double?
    /// When true, the published device list is frozen so rows stop jumping
    /// around while the user aims for one. Scanning and target RSSI keep
    /// running underneath; only the list display is held.
    @Published var listFrozen = false

    /// Called with the target's smoothed RSSI on every advertisement.
    var onTargetSample: ((Double) -> Void)?

    private var central: CBCentralManager!
    private var byID: [UUID: BLEDevice] = [:]
    private var history: [UUID: [Int]] = [:]
    private var lastPublish = Date.distantPast

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func selectTarget(_ id: UUID?) {
        targetID = id
        targetRSSI = nil
    }

    func toggleListFreeze() {
        listFrozen.toggle()
        if !listFrozen { publishDevices() }
    }

    private func publishDevices() {
        let now = Date()
        lastPublish = now
        devices = byID.values
            .filter { now.timeIntervalSince($0.lastSeen) < 30 }
            .sorted { $0.smoothedRSSI > $1.smoothedRSSI }
    }

    private func median(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[mid]) }
        return (Double(sorted[mid - 1]) + Double(sorted[mid])) / 2.0
    }
}

extension Scanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateText = "スキャン中（画面を開いている間だけ受信します）"
            startScan()
        case .poweredOff:
            stateText = "Bluetoothがオフです"
            isScanning = false
        case .unauthorized:
            stateText = "Bluetoothの許可が必要です（設定アプリで許可してください）"
        case .unsupported:
            stateText = "この端末はBLEに対応していません"
        default:
            stateText = "Bluetooth初期化中…"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi != 127, rssi < 0 else { return }  // 127 = unavailable
        let id = peripheral.identifier
        var hist = history[id] ?? []
        hist.append(rssi)
        if hist.count > 7 { hist.removeFirst(hist.count - 7) }
        history[id] = hist
        let smoothed = median(hist)

        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "名称不明"
        byID[id] = BLEDevice(id: id, name: name, smoothedRSSI: smoothed, lastSeen: Date())

        if id == targetID {
            targetRSSI = smoothed
            onTargetSample?(smoothed)
        }

        if !listFrozen, Date().timeIntervalSince(lastPublish) > 0.3 {
            publishDevices()
        }
    }
}
