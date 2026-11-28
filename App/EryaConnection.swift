import Foundation

/// Independent Erya JPEG session; deliberately does not probe Yunmo/OTA ports.
final class EryaConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private var control: TailingSocket?
    private var video: TailingSocket?
    private var closed = false
    private var failure: Error?
    private var parameters: EryaProtocol.Parameters?
    private var permit = false
    private var lastReply = ProcessInfo.processInfo.systemUptime
    private var began = ProcessInfo.processInfo.systemUptime
    private var frames = 0
    private let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }

    func start(local: String, target: String, videoPort: UInt16 = 11111, controlPort: UInt16 = 11113) throws -> (Int, Int) {
        do {
            let c = try connect(local: local, target: target, port: controlPort, isControl: true)
            DispatchQueue.global(qos: .utility).async { [self] in receiveControl(c) }
            let v = try connect(local: local, target: target, port: videoPort, isControl: false)
            condition.lock(); began = ProcessInfo.processInfo.systemUptime; lastReply = began; condition.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in receiveVideo(v) }
            for attempt in 1...16 {
                try v.write(EryaProtocol.start())
                log("Erya start request \(attempt); awaiting OK parameters")
                condition.lock()
                let deadline = Date().addingTimeInterval(0.5)
                while !closed && failure == nil && parameters == nil {
                    if !condition.wait(until: deadline) { break }
                }
                let ready = parameters; let error = failure; let stopped = closed
                condition.unlock()
                if stopped { throw TailingError.closed }
                if let error { throw error }
                if let ready {
                    log("Erya negotiated \(ready.width)×\(ready.height) encoding=\(ready.encoding); JPEG ACK pacing")
                    return (ready.width, ready.height)
                }
            }
            throw TailingError.timeout("Erya 未返回 OK 参数，请核对仪表互联页面、IP 和端口")
        } catch { close(); throw error }
    }
    private func connect(local: String, target: String, port: UInt16, isControl: Bool) throws -> TailingSocket {
        let channel = isControl ? "control" : "video"
        for attempt in 1...3 {
            let socket = try TailingSocket.create()
            condition.lock()
            if closed { condition.unlock(); socket.close(); throw TailingError.closed }
            if isControl { control = socket } else { video = socket }
            condition.unlock()
            log("Erya \(channel) TCP \(local) → \(target):\(port) attempt=\(attempt)/3")
            do {
                try socket.connect(localIP: local, remoteIP: target, port: port)
                log("Erya \(channel) connected")
                return socket
            } catch {
                socket.close()
                // Only retry an explicitly refused connection; preserve other network errors.
                guard case TailingError.system(_, let code) = error, code == 61 else { throw error }
                log("Erya \(channel) TCP\(port) refused (61)")
                if attempt == 3 {
                    throw TailingError.protocolFailure("Erya \(isControl ? "控制" : "画面")端口 \(port) 拒绝连接；请核对仪表二维码端口、互联页面及官方 App 是否仍占用连接")
                }
                condition.lock()
                _ = condition.wait(until: Date().addingTimeInterval(0.5))
                let stopped = closed, problem = failure
                condition.unlock()
                if stopped { throw TailingError.closed }
                if let problem { throw problem }
            }
        }
        throw TailingError.closed
    }
    private func receiveControl(_ socket: TailingSocket) {
        do {
            while true {
                // An idle control channel is valid while video ACKs keep arriving.
                let first: Data
                do { first = try socket.readExactly(1, timeout: 1) }
                catch TailingError.timeout(_) { continue }
                var pending = first
                let event = try EryaProtocol.readControl { count in
                    if !pending.isEmpty {
                        let prefix = pending; pending.removeAll()
                        return prefix + (count > prefix.count ? try socket.readExactly(count - prefix.count, timeout: 5) : Data())
                    }
                    return try socket.readExactly(count, timeout: 5)
                }
                if let fun = event["fun"] as? String,
                   ["mirrorControl", "closeHeart", "funSwitch", "active"].contains(fun) {
                    log("Erya control event=\(fun)")
                } else { log("Erya control message received (content omitted)") }
                // Never log raw JSON: it may contain user, location or authentication data.
                if event["fun"] as? String == "mirrorControl", String(describing: event["type"] ?? "") == "0" {
                    throw TailingError.protocolFailure("Erya 仪表请求停止投屏")
                }
            }
        } catch { fail(error) }
    }
    private func receiveVideo(_ socket: TailingSocket) {
        do {
            while true {
                let reply = try EryaProtocol.read { try socket.readExactly($0, timeout: 15) }
                condition.lock()
                switch reply {
                case .parameters(let p):
                    if p.encoding != 420 { failure = TailingError.protocolFailure("Erya 当前实验仅支持 JPEG 420，仪表返回 \(p.encoding)") }
                    else if let old = parameters, old != p { failure = TailingError.protocolFailure("Erya 参数改变，请重新连接") }
                    else { parameters = p }
                case .event(let json):
                    if json["ack"] != nil { permit = true }
                    if json["ack"] != nil || json["ver"] != nil { lastReply = ProcessInfo.processInfo.systemUptime }
                }
                condition.broadcast(); let failed = failure != nil; condition.unlock()
                if failed { return }
            }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        condition.lock(); if !closed && failure == nil { failure = error }; condition.broadcast(); condition.unlock()
    }
    private func checkLocked() throws {
        if closed { throw TailingError.closed }
        if let failure { throw failure }
        if ProcessInfo.processInfo.systemUptime - lastReply > 12 { throw TailingError.timeout("Erya 等待仪表心跳或 ACK") }
    }
    func checkHealth() throws { condition.lock(); defer { condition.unlock() }; try checkLocked() }
    func waitWritable() throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(12)
        while !permit {
            try checkLocked()
            if !condition.wait(until: deadline) { throw TailingError.timeout("Erya 等待图片 ACK") }
        }
        try checkLocked()
    }
    func send(_ jpeg: Data) throws {
        condition.lock()
        do { try checkLocked() } catch { condition.unlock(); throw error }
        guard permit, let socket = video else { condition.unlock(); throw TailingError.protocolFailure("Erya 未取得发送许可") }
        permit = false
        let elapsed = UInt32(truncatingIfNeeded: UInt64(max(0, ProcessInfo.processInfo.systemUptime - began) * 1000))
        frames += 1; let count = frames
        condition.unlock()
        try socket.write(EryaProtocol.jpeg(jpeg, milliseconds: elapsed))
        if count == 1 || count % 100 == 0 { log("Erya JPEG sent frame=\(count) bytes=\(jpeg.count)") }
    }
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true; let c = control, v = video; control = nil; video = nil; permit = false
        condition.broadcast(); condition.unlock()
        if let v { try? v.write(EryaProtocol.packet(5), timeout: 0.15); v.close() }
        c?.close()
    }
}
