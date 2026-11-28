// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from MOTO-HUB YunmoTransport.kt (16b14b8); Copyright (C) 2026 Vincenzo Buonomano and contributors.
import Foundation

final class YunmoConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private var socket: TailingSocket?
    private var closed = false
    private var error: Error?
    private var size: (Int, Int)?
    private var confirmed = false
    private var sent: Int64 = -1
    private var acked: Int64 = -1
    private var lastAck = ProcessInfo.processInfo.systemUptime
    private let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
    func start(local: String, target: String) throws -> (Int, Int) {
        let sock = try TailingSocket.create()
        condition.lock()
        if closed { condition.unlock(); sock.close(); throw TailingError.closed }
        socket = sock; condition.unlock()
        do {
            log("Yunmo TCP connect \(local) → \(target):8200")
            try sock.connect(localIP: local, remoteIP: target, port: 8200)
            log("Yunmo TCP connected; requesting canvas B0 and display A0/06")
            DispatchQueue.global(qos: .userInitiated).async { [self] in receive(sock) }
            try sock.write(YunmoProtocol.simple(0xb0, Data([1, 0, 1])))
            // The dash may report dimensions only after the display mode has been requested.
            for _ in 0..<3 {
                try sock.write(YunmoProtocol.simple(0xa0, Data([6])))
                condition.lock()
                let deadline = Date().addingTimeInterval(2)
                while !closed && error == nil && !confirmed { if !condition.wait(until: deadline) { break } }
                let done = confirmed
                condition.unlock()
                if done { break }
            }
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(3)
            while !closed && error == nil && size == nil { if !condition.wait(until: deadline) { break } }
            try checkLocked()
            log("Yunmo handshake state modeConfirmed=\(confirmed) dimensions=\(size.map { "\($0.0)×\($0.1)" } ?? "missing")")
            guard confirmed, let size else { throw TailingError.timeout("Yunmo 仪表未确认显示模式或尺寸，请确认仪表处于互联页面") }
            log("Yunmo 协商 \(size.0)×\(size.1)，JPEG，发送窗口2")
            return size
        } catch { close(); throw error }
    }
    private func receive(_ sock: TailingSocket) {
        do {
            while true {
                let f = try YunmoProtocol.read(diagnostic: log) { try sock.readExactly($0, timeout: 15) }
                if f.command != 0xa0 || f.payload.first != 0 {
                    log(String(format: "Yunmo RX cmd=%02x payloadBytes=%d opcode=%02x", f.command, f.payload.count, f.payload.first ?? 0))
                }
                condition.lock()
                switch f.command {
                case 0x32, 0x33:
                    if let next = YunmoProtocol.dimensions(f.payload) {
                        if let old = size, old != next { error = TailingError.protocolFailure("Yunmo 会话内尺寸改变，请重新启动") }
                        else { size = next }
                    }
                case 0xa0:
                    if f.payload.first == 6 { confirmed = true }
                    else if f.payload.first == 5 || f.payload.first == 2 { error = TailingError.protocolFailure("仪表已退出画面投屏") }
                    else if let id = YunmoProtocol.ack(f.payload), Int64(id) <= sent, Int64(id) > acked {
                        acked = Int64(id); lastAck = ProcessInfo.processInfo.systemUptime
                    }
                case 0x34: error = TailingError.protocolFailure("Yunmo 仪表拒绝显示请求")
                default: break
                }
                condition.broadcast(); let failed = error != nil; condition.unlock()
                if failed { return }
            }
        } catch {
            condition.lock(); if !closed { self.error = error }; condition.broadcast(); condition.unlock()
        }
    }
    func send(_ jpeg: Data) throws {
        let reservation: (TailingSocket, UInt32) = try reserve()
        try reservation.0.write(YunmoProtocol.jpeg(jpeg, id: reservation.1))
    }
    func checkHealth() throws { condition.lock(); defer { condition.unlock() }; try checkLocked() }
    func waitWritable() throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(6)
        while !closed && error == nil && sent - acked >= 2 {
            if !condition.wait(until: deadline) { throw TailingError.timeout("Yunmo 等待图片确认") }
        }
        try checkLocked()
    }
    private func reserve() throws -> (TailingSocket, UInt32) {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(6)
        while !closed && error == nil && sent - acked >= 2 {
            if !condition.wait(until: deadline) { throw TailingError.timeout("Yunmo 等待图片确认") }
        }
        try checkLocked()
        if sent >= 0 && sent > acked && ProcessInfo.processInfo.systemUptime - lastAck > 6 {
            throw TailingError.timeout("Yunmo 图片确认超时")
        }
        guard let socket, sent < Int64(UInt32.max) else { throw TailingError.closed }
        if sent < 0 { lastAck = ProcessInfo.processInfo.systemUptime }
        sent += 1
        return (socket, UInt32(sent))
    }
    private func checkLocked() throws { if closed { throw TailingError.closed }; if let error { throw error } }
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true; let sock = socket; socket = nil; condition.broadcast(); condition.unlock()
        // Closing the socket promptly wakes pending I/O. Teardown is best effort and bounded.
        if let sock {
            try? sock.write(YunmoProtocol.simple(0xa0, Data([2])), timeout: 0.15)
            try? sock.write(YunmoProtocol.simple(0xa0, Data([5])), timeout: 0.15)
            sock.close()
        }
    }
}
