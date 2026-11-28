// SPDX-License-Identifier: AGPL-3.0-only
// Protocol sequence adapted from MOTO-HUB ThinkerRideBleLink.kt (16b14b8).
// Copyright (C) 2026 Vincenzo Buonomano and the MOTO-HUB contributors.
import CoreBluetooth
import Foundation

/// Uses only a peripheral explicitly selected by the user. No first-device auto pairing.
final class ThinkerRideBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device { let id: UUID; let name: String }
    private let queue = DispatchQueue(label: "CarWithin.thinker.ble")
    private var central: CBCentralManager!
    private var devices: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var selected: UUID?
    private var byteCat = false
    private var sequence: UInt16 = 0
    private var pending: [Data] = []
    private var pumping = false
    private var stopped = false
    private var scanRequested = false
    private var generation = 0
    private var confirmed = false
    private var assembler = ThinkerRideProtocol.JSONStream()
    private var heartbeat: DispatchSourceTimer?
    private var onDevice: ((Device) -> Void)?
    private var onReady: (() -> Void)?
    private var onFailure: ((String) -> Void)?
    override init() { super.init(); central = CBCentralManager(delegate: self, queue: queue) }
    func scan(found: @escaping (Device) -> Void, failure: @escaping (String) -> Void) {
        queue.async { self.stopped = false; self.scanRequested = true; self.onDevice = found; self.onFailure = failure; self.beginScan() }
    }
    func connect(id: UUID, byteCat: Bool, ready: @escaping () -> Void, failure: @escaping (String) -> Void) {
        queue.async {
            self.stopped = false; self.selected = id; self.byteCat = byteCat; self.onReady = ready; self.onFailure = failure
            self.scanRequested = true; self.beginScan()
            let token = self.generation
            self.queue.asyncAfter(deadline: .now() + 35) { [weak self] in
                guard let self, !self.stopped, token == self.generation, !self.confirmed else { return }
                self.fail(CWL("仪表蓝牙配对未确认，请在仪表上确认并重试。"))
            }
        }
    }
    private func beginScan() {
        guard !stopped, scanRequested else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { fail(CWL("请开启蓝牙并允许 CarWithin 使用蓝牙。")) }; return
        }
        if let selected, let p = central.retrievePeripherals(withIdentifiers: [selected]).first {
            connectPeripheral(p); return
        }
        central.scanForPeripherals(withServices: [CBUUID(string: ThinkerRideProtocol.service)])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { beginScan() }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        devices[p.identifier] = p
        if let selected {
            if p.identifier == selected { connectPeripheral(p) }
        } else {
            let item = Device(id: p.identifier, name: p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "ThinkerRide")
            let callback = onDevice
            DispatchQueue.main.async { callback?(item) }
        }
    }
    private func connectPeripheral(_ p: CBPeripheral) {
        guard peripheral == nil, !stopped else { return }
        central.stopScan(); peripheral = p; p.delegate = self; central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([CBUUID(string: ThinkerRideProtocol.service)]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { fail(CWL("仪表蓝牙连接失败。")) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if !stopped { fail(CWL("仪表蓝牙已断开，请重新启动投屏。")) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = p.services?.first(where: { $0.uuid == CBUUID(string: ThinkerRideProtocol.service) }) else { fail(CWL("未找到仪表投屏蓝牙服务。")); return }
        p.discoverCharacteristics(nil, for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "FFE1") }),
              let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "FFE2") }) else { fail(CWL("仪表蓝牙通道不完整。")); return }
        writeCharacteristic = write; p.setNotifyValue(true, for: notify)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { fail(CWL("无法订阅仪表蓝牙通知。")); return }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        ["{\"msg_id\":27,\"func\":\"PAIR\",\"act\":\"get_pairinfo\"}", "{\"msg_id\":13}",
         "{\"msg_id\":25,\"msg_type\":18,\"msg_source\":2,\"language\":2}",
         "{\"msg_id\":11,\"time\":\"\(date.string(from: Date()))\",\"tag\":-1}"].forEach(enqueue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.enqueue("{\"msg_id\":25,\"msg_type\":24,\"msg_source\":2,\"status\":1}") }
        heartbeat = timer; timer.resume()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        for message in assembler.append(data) {
            if message["act"] as? String == "send_pairresult", (message["result"] as? NSNumber)?.intValue == 1, !confirmed {
                confirmed = true; mirror(true)
                let ready = onReady; queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in if self?.stopped == false { ready?() } }
            }
        }
    }
    private func mirror(_ active: Bool) {
        for type in [23, 21] { enqueue("{\"msg_id\":25,\"msg_type\":\(type),\"msg_source\":2,\"status\":\(active ? 1 : 0)}") }
    }
    private func enqueue(_ json: String) {
        let data = Data(json.utf8)
        pending += byteCat ? ThinkerRideProtocol.byteCat(data, sequence: &sequence) : [data]
        pump()
    }
    private func pump() {
        guard !pumping, !pending.isEmpty, !stopped, let p = peripheral, let c = writeCharacteristic else { return }
        guard c.properties.contains(.writeWithoutResponse), p.canSendWriteWithoutResponse else { return }
        let data = pending.removeFirst()
        guard data.count <= p.maximumWriteValueLength(for: .withoutResponse) else { fail(CWL("仪表蓝牙写入长度不足，当前固件暂不兼容。")); return }
        pumping = true; p.writeValue(data, for: c, type: .withoutResponse)
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.pumping = false; self?.pump() }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pump() }
    private func fail(_ message: String) { let callback = onFailure; stopInternal(); DispatchQueue.main.async { callback?(message) } }
    func stop() {
        queue.async {
            if self.confirmed { self.mirror(false) }
            let token = self.generation
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in if self?.generation == token { self?.stopInternal() } }
        }
    }
    private func stopInternal() {
        generation += 1; stopped = true; scanRequested = false; central.stopScan(); heartbeat?.cancel(); heartbeat = nil
        pending.removeAll(); pumping = false; sequence = 0; assembler = .init(); confirmed = false
        if let peripheral { peripheral.delegate = nil; central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; writeCharacteristic = nil; onReady = nil; onDevice = nil; onFailure = nil
    }
}
