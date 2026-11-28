// SPDX-License-Identifier: AGPL-3.0-only
// Protocol flow adapted from MOTO-HUB ThinkerRideTransport.kt (16b14b8).
// Copyright (C) 2026 Vincenzo Buonomano and the MOTO-HUB contributors.
import Foundation

final class ThinkerRideConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var error: Error?
    private var resources: [TailingSocket] = []
    private var video: TailingSocket?
    private var paired = false
    private var timers: [DispatchSourceTimer] = []
    private let ble = ThinkerRideBLE()
    private let profile: MotorcycleProfile
    private let log: (String) -> Void
    init(profile: MotorcycleProfile, log: @escaping (String) -> Void) { self.profile = profile; self.log = log }
    private func track(_ sock: TailingSocket) throws -> TailingSocket {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { sock.close(); throw TailingError.closed }
        resources.append(sock); return sock
    }
    func start(local: String, target: String, device: UUID) throws -> (Int, Int) {
        do {
            // All listeners must be ready before BLE mirror-start makes the dash dial in.
            for port: UInt16 in [17818, 15457, 15456] {
                let listener = try track(TailingSocket.listening(localIP: local, port: port))
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let socket = try track(listener.accept(remoteIP: target))
                        listener.close()
                        switch port {
                        case 17818: try control(socket)
                        case 15457: pulse(socket, interval: 0.2)
                        default:
                            try socket.write(ThinkerRideProtocol.videoHeader(width: profile.width, height: profile.height))
                            pulse(socket, interval: 2)
                            condition.lock(); video = socket; condition.broadcast(); condition.unlock()
                        }
                    } catch { fail(error) }
                }
            }
            ble.connect(id: device, byteCat: profile.byteCatBLE, ready: { [weak self] in
                guard let self else { return }
                self.condition.lock(); self.paired = true; self.condition.broadcast(); self.condition.unlock()
                self.log("ThinkerRide 蓝牙已确认配对并请求投屏")
            }, failure: { [weak self] message in self?.fail(ConfigurationError(message)) })
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(90)
            while !closed && error == nil && (video == nil || !paired) {
                if !condition.wait(until: deadline) { throw TailingError.timeout("等待仪表回连视频；450 Rally 请在仪表上长按向上键") }
            }
            try checkLocked(); return (profile.width, profile.height)
        } catch { close(); throw error }
    }
    private func control(_ socket: TailingSocket) throws {
        try socket.write(ThinkerRideProtocol.controlJSON(["msg_id": 27, "func": "TUC", "act": "GET"]))
        var first = true
        while true {
            let head = [UInt8](try socket.readExactly(2, timeout: 15))
            let lengthBytes = [UInt8](try socket.readExactly(4))
            let count = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
            guard count <= 65536 else { throw TailingError.protocolFailure("ThinkerRide 控制长度异常") }
            if head == [0xee, 0xfd] {
                let payload = try socket.readExactly(count)
                guard try socket.readExactly(1)[0] == 255 else { throw TailingError.protocolFailure("ThinkerRide 控制尾标记异常") }
                if let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                   object["func"] as? String == "TUC", let active = object["tucs"] as? NSNumber, active.intValue != 1 {
                    throw TailingError.protocolFailure("仪表互联尚未激活，请先通过官方应用完成激活")
                }
            } else if head == [2, 1], count == 0 {
                try socket.write(ThinkerRideProtocol.keepalive)
            } else if head.first == 1 {
                _ = try socket.readExactly(count)
            } else { throw TailingError.protocolFailure("ThinkerRide 未知控制帧") }
            if first {
                first = false; Thread.sleep(forTimeInterval: 0.1)
                try socket.write(ThinkerRideProtocol.handshake)
                for query in [2, 1] { try socket.write(ThinkerRideProtocol.controlJSON(["msg_id": 27, "func": "INSIDENAVI", "query": query])) }
            }
        }
    }
    private func pulse(_ socket: TailingSocket, interval: Double) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            do { try socket.write(ThinkerRideProtocol.keepalive, timeout: 2) } catch { self?.fail(error) }
        }
        condition.lock()
        if closed { condition.unlock(); timer.cancel(); timer.resume(); return }
        timers.append(timer); timer.resume(); condition.unlock()
    }
    func checkHealth() throws { condition.lock(); defer { condition.unlock() }; try checkLocked() }
    func send(_ frame: Data) throws {
        condition.lock()
        let socket = video
        do { try checkLocked(); condition.unlock() } catch { condition.unlock(); throw error }
        guard let socket else { throw TailingError.closed }
        try socket.write(frame)
    }
    private func checkLocked() throws { if closed { throw TailingError.closed }; if let error { throw error } }
    private func fail(_ error: Error) {
        condition.lock(); if !closed { self.error = error }; condition.broadcast(); condition.unlock()
    }
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true; let sockets = resources; resources.removeAll(); video = nil
        let activeTimers = timers; timers.removeAll(); condition.broadcast(); condition.unlock()
        activeTimers.forEach { $0.cancel() }; sockets.forEach { $0.close() }; ble.stop()
    }
}
