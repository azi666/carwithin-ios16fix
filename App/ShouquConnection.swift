import Foundation

/// Separate CarBit/PXC JPEG session. Existing ZEEHO/CFMOTO state machines are untouched.
final class ShouquConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private let local: String, target: String
    private let ports: ShouquPorts
    private let identityProvider: () throws -> TailingIdentity
    private let log: (String) -> Void
    private var resources: [TailingSocket] = []
    private var closed = false
    private var error: Error?
    private var identity: TailingIdentity?
    private var huid: String?
    private var session: TailingSocket?
    private var confirmed = false, viewReady = false, imageReady = false, configReady = false
    private var sequence: UInt32 = 0
    private var pending: Data?, lastFrame: Data?
    private var polls = 0, sent = 0
    private var ping: DispatchSourceTimer?

    init(local: String, target: String, ports: ShouquPorts = ShouquPorts(),
         identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
         log: @escaping (String) -> Void) {
        self.local = local; self.target = target; self.ports = ports
        self.identityProvider = identityProvider; self.log = log
    }
    private func tracked(_ socket: TailingSocket) throws -> TailingSocket {
        condition.lock(); defer { condition.unlock() }
        guard !closed, resources.count < 24 else { socket.close(); throw TailingError.closed }
        resources.append(socket); return socket
    }
    func start() throws -> (Int, Int) {
        do {
            let loaded = try identityProvider()
            condition.lock(); identity = loaded; condition.unlock()
            for port in [ports.control, ports.view, ports.image] {
                let listener = try tracked(TailingSocket.listening(localIP: local, port: port))
                DispatchQueue.global(qos: .userInitiated).async { [self] in accept(listener, port: port) }
            }
            log("首驱监听已就绪：\(local) · \(ports.control)/\(ports.view)/\(ports.image)")
            let probe = try tracked(TailingSocket.create())
            defer { release(probe) }
            try probe.connect(localIP: local, remoteIP: target, port: ports.hello, timeout: 4)
            try probe.write(ShouquProtocol.hello)
            let reply = try TailingProtocol.readControl { try probe.readExactly($0, timeout: 4) }
            guard reply.command == 0x70000011,
                  (try TailingProtocol.object(reply.payload)["status"] as? Bool) == true else {
                throw TailingError.protocolFailure(CWL("首驱仪表未接受 hello，请确认热点和投屏页面。"))
            }
            log("首驱 hello 已确认，等待仪表反向连接")
            // The hello connection must end promptly, before waiting for reverse channels.
            release(probe)
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(20)
            while !closed && error == nil && !(session != nil && viewReady && configReady && imageReady) {
                if !condition.wait(until: deadline) {
                    throw TailingError.timeout("首驱握手未完成：控制=\(session != nil) 10711身份=\(viewReady) 视区=\(configReady) 图像=\(imageReady)")
                }
            }
            try checkLocked()
            return (ShouquProtocol.width, ShouquProtocol.height)
        } catch { close(); throw error }
    }
    private func accept(_ listener: TailingSocket, port: UInt16) {
        do {
            while true {
                let socket = try tracked(listener.accept(remoteIP: target))
                log("首驱仪表回连 TCP\(port)")
                if port == ports.image {
                    condition.lock(); let duplicate = imageReady; imageReady = true; condition.broadcast(); condition.unlock()
                    if duplicate { release(socket); continue }
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        if port == ports.control { try control(socket) }
                        else if port == ports.view { try view(socket) }
                        else { try image(socket) }
                    } catch {
                        condition.lock(); let critical = port != ports.control || session === socket; condition.unlock()
                        if critical { fail(error) }
                        else { log("首驱辅助控制连接结束：\(error.localizedDescription)；等待其他控制连接") }
                    }
                    release(socket)
                }
            }
        } catch { fail(error) }
    }
    private func release(_ socket: TailingSocket) {
        socket.close()
        condition.lock(); resources.removeAll { $0 === socket }; condition.unlock()
    }
    private func nextSequence() -> UInt32 {
        condition.lock(); defer { condition.unlock() }; sequence &+= 1; return sequence
    }
    private func send(_ socket: TailingSocket, _ command: UInt32, _ object: [String: Any]? = nil, seq: UInt32? = nil) throws {
        let data = try object.map(TailingProtocol.json) ?? Data()
        try socket.write(TailingProtocol.control(command, identifier: seq ?? nextSequence(), payload: data))
    }
    private func control(_ socket: TailingSocket) throws {
        var capsSent = false
        while true {
            let request = try TailingProtocol.readControl { try socket.readExactly($0, timeout: 15) }
            switch request.command {
            case 0x10000, 0x10040, 0x70000000:
                try send(socket, request.command &+ 1, seq: request.identifier)
            case 0x10010:
                let object = try TailingProtocol.object(request.payload)
                guard let newHUID = object["HUID"] as? String, !newHUID.isEmpty, newHUID.utf8.count <= 128 else {
                    throw TailingError.protocolFailure(CWL("首驱仪表未提供有效身份。"))
                }
                condition.lock()
                let mismatch = huid != nil && huid != newHUID
                let first = !confirmed; confirmed = true; huid = newHUID
                let identity = self.identity
                condition.broadcast()
                condition.unlock()
                guard !mismatch, let identity else { throw TailingError.protocolFailure(CWL("首驱会话内仪表身份改变。")) }
                if first { try send(socket, 0x70000020, seq: request.identifier) }
                if !capsSent {
                    capsSent = true
                    // Fresh local RSA identity, bound to the actual peer HUID; no captured proof.
                    let caps: [String: Any] = ["bluetoothAddress":"", "pxcVersion":"1.0.2", "bluetoothName":"iPhone",
                        "supportFunctionEx":0, "phoneBrand":"iPhone", "currentHUTime":Int64(Date().timeIntervalSince1970 * 1000),
                        "phoneUUID":identity.phoneID, "supportH264IFrame":true, "token":0, "versionCode":204,
                        "pubkey":try identity.publicKey().base64EncodedString(), "phoneOs":"iOS", "package":ShouquProtocol.package,
                        "supportFunction":128, "phoneModel":"iPhone12,1", "encryptedHUID":try identity.sign(newHUID).base64EncodedString(),
                        "phoneOsVersion":"16.2", "mirrorRequestReconnect":true]
                    try send(socket, 0x10011, caps, seq: request.identifier)
                    log("首驱手机能力已发送（本机RSA身份；兼容性待实车确认）")
                }
            case 0x10450:
                let now = Date(), ms = Int64(Date().timeIntervalSince1970 * 1000)
                let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX")
                format.timeZone = TimeZone(identifier:"Asia/Shanghai"); format.dateFormat = "dd.MM.yyyy HH:mm:ss:SSS"
                try send(socket, 0x10451, ["currentTimeZone":"Asia/Shanghai", "dateTime":format.string(from:now), "time":ms, "currentTime":ms + 28_800_000], seq:request.identifier)
            case 0x20000:
                try send(socket, 0x20001, seq:request.identifier)
                condition.lock()
                let duplicate = session != nil
                if !duplicate { session = socket; lastFrame = nil; pending = nil; condition.broadcast() }
                condition.unlock()
                if !duplicate { initializeSession(socket) }
            case 0x80000010, 0x70000001: break
            case 0x20110, 0x201e0: try send(socket, request.command &+ 1, seq:request.identifier)
            default:
                if request.command & 0xffff0000 == 0x20000 { try send(socket, 0x80000010, seq:request.identifier) }
            }
        }
    }
    private func initializeSession(_ socket: TailingSocket) {
        let steps: [(Double, UInt32, [String:Any])] = [(0,0x204c0,["state":0,"msg":""]),
            (0.5,0x20490,["status":0]), (1.3,0x20020,["height":896,"width":414,"mode":2,"displayRotation":0]),
            (1.9,0x20210,["sendPlayEvent":false]), (1.9,0x201e0,["status":true]), (2.9,0x200e0,["type":1])]
        let scheduler = DispatchQueue(label:"CarWithin.shouqu.control")
        for (delay, cmd, body) in steps {
            scheduler.asyncAfter(deadline:.now()+delay) { [self] in
                condition.lock(); let active = !closed && session === socket; condition.unlock()
                guard active else { return }
                do { try send(socket,cmd,body) } catch { fail(error) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue:scheduler)
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.send(socket,0x70000000) } catch { self.fail(error) }
        }
        condition.lock()
        if closed { condition.unlock(); timer.cancel(); timer.resume(); return }
        ping = timer; timer.resume(); condition.unlock()
    }
    private func view(_ socket: TailingSocket) throws {
        var accepted = false
        while true {
            let request = try TailingProtocol.readAuxiliary { try socket.readExactly($0, timeout:15) }
            guard request.payload.count <= 4096 else { throw TailingError.protocolFailure("首驱10711载荷超出4096字节") }
            switch request.command {
            case 0x10:
                let payload = try ShouquProtocol.viewHandshake(request.payload)
                condition.lock()
                let deadline = Date().addingTimeInterval(4)
                while !closed && error == nil && huid == nil { if !condition.wait(until: deadline) { break } }
                let id = identity; let peer = huid
                condition.unlock()
                guard let id, let peer, request.payload.count >= 376,
                      let signature = Data(base64Encoded:Data(request.payload.dropFirst(32).prefix(344))) else {
                    throw TailingError.protocolFailure(CWL("首驱10711缺少完整的身份回显。"))
                }
                try id.verify(signature,huid:peer)
                try socket.write(TailingProtocol.auxiliary(0x11,token:request.token,payload:payload))
                condition.lock(); viewReady = true; condition.broadcast(); condition.unlock(); accepted = true
                log("首驱10711：0x0010 → 0x0011，身份握手完成（前4字节已原样回显，视区待单独确认）")
            case 0x60:
                guard accepted else { throw TailingError.protocolFailure(CWL("首驱视区配置早于身份握手。")) }
                try ShouquProtocol.validateViewArea(request.payload)
                try socket.write(TailingProtocol.auxiliary(0x61,token:request.token,payload:ShouquProtocol.viewAccepted()))
                condition.lock(); configReady = true; condition.broadcast(); condition.unlock()
                log("首驱10711：视区已确认，等待JPEG轮询")
            case 0x40, 0x70:
                try socket.write(TailingProtocol.auxiliary(request.command &+ 1,token:request.token))
            default: log(String(format:"首驱10711未处理命令0x%04x（%d字节）",request.command,request.payload.count))
            }
        }
    }
    private func image(_ socket: TailingSocket) throws {
        while true {
            let request = try TailingProtocol.readAuxiliary { try socket.readExactly($0,timeout:15) }
            guard request.command == 0x72, request.payload.isEmpty else { throw TailingError.protocolFailure(CWL("首驱图像轮询报文不正确。")) }
            condition.lock()
            let frame = viewReady && configReady && session != nil ? pending : nil
            if frame != nil { pending = nil; sent += 1 }; polls += 1
            let report = polls == 1 || polls % 125 == 0; let count = polls, sentCount = sent
            condition.unlock()
            try socket.write(ShouquProtocol.imageResponse(frame))
            if report { log("首驱JPEG：轮询\(count)，发送\(sentCount)，最新帧\(frame?.count ?? 0)字节") }
        }
    }
    func send(_ jpeg: Data) throws {
        _ = try ShouquProtocol.imageResponse(jpeg)
        condition.lock(); defer { condition.unlock() }; try checkLocked()
        if lastFrame != jpeg { pending = jpeg; lastFrame = jpeg }
    }
    func checkHealth() throws { condition.lock(); defer { condition.unlock() }; try checkLocked() }
    private func checkLocked() throws { if closed { throw TailingError.closed }; if let error { throw error } }
    private func fail(_ error: Error) {
        condition.lock(); if !closed && self.error == nil { self.error = error }; condition.broadcast(); condition.unlock()
    }
    func close() {
        condition.lock(); guard !closed else { condition.unlock(); return }
        closed = true; let sockets = resources; resources.removeAll(); let timer = ping; ping = nil
        let activeSession = session; session = nil; pending = nil; lastFrame = nil; condition.broadcast(); condition.unlock()
        timer?.cancel()
        if let activeSession, let packet = try? TailingProtocol.control(0x201e0,payload:Data("{\"status\":false}".utf8)) {
            try? activeSession.write(packet,timeout:0.15)
        }
        sockets.forEach { $0.close() }
    }
}
