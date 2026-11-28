import Foundation

/// Erya wire format observed in KOVE Android 1.1.7. Experimental; no vehicle acceptance yet.
enum EryaProtocol {
    static let maximumPayload = 2 * 1024 * 1024
    struct Parameters: Equatable {
        let width: Int
        let height: Int
        let encoding: Int
    }
    enum Reply { case parameters(Parameters), event([String: Any]) }
    static func packet(_ function: UInt8, payload: Data = Data()) -> Data {
        precondition(payload.count <= maximumPayload)
        var data = Data([0xaa, 0xbb, 0xcc, function, 0, 0, 0, 0])
        appendLE(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }
    static func appendLE(_ value: UInt32, to data: inout Data) {
        for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }
    static func start(width: Int = 640, height: Int = 480) -> Data {
        let short = min(width, height), long = max(width, height)
        return packet(4, payload: Data([UInt8(truncatingIfNeeded: short), UInt8(truncatingIfNeeded: short >> 8),
                                       UInt8(truncatingIfNeeded: long), UInt8(truncatingIfNeeded: long >> 8)]))
    }
    static func jpeg(_ jpeg: Data, milliseconds: UInt32) throws -> Data {
        guard !jpeg.isEmpty, jpeg.count <= maximumPayload - 4 else { throw TailingError.protocolFailure("Erya JPEG 长度异常") }
        var body = Data(); appendLE(milliseconds, to: &body); body.append(jpeg)
        return packet(7, payload: body)
    }
    static func read(_ read: (Int) throws -> Data) throws -> Reply {
        let prefix = [UInt8](try read(2))
        if prefix == [0x4f, 0x4b] {
            let b = [UInt8](try read(11))
            func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
            let w = (u16(4) + 1) & ~1, h = (u16(6) + 1) & ~1
            guard (16...2560).contains(w), (16...2560).contains(h), w * h <= 4_194_304 else {
                throw TailingError.protocolFailure("Erya 仪表尺寸异常")
            }
            return .parameters(Parameters(width: w, height: h, encoding: u16(9)))
        }
        guard prefix == [0xaa, 0xbb] else { throw TailingError.protocolFailure("Erya 响应帧头不匹配（需要 OK 或 AA BB CC）") }
        let header = [UInt8](try read(10))
        guard header[0] == 0xcc, header[1] == 0x0f else { throw TailingError.protocolFailure("Erya 响应功能不匹配") }
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[6 + $1]) << (8 * $1) }
        guard length > 0, length <= 4096 else { throw TailingError.protocolFailure("Erya 响应长度异常") }
        let data = try read(Int(length))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailingError.protocolFailure("Erya 响应 JSON 异常")
        }
        return .event(json)
    }
    static func readControl(_ read: (Int) throws -> Data) throws -> [String: Any] {
        guard try read(2) == Data([0x45, 0x59]) else { throw TailingError.protocolFailure("Erya 控制帧头不匹配") }
        let h = [UInt8](try read(8))
        func be(_ offset: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(h[offset + $1]) } }
        let jsonLength = be(0), extraLength = be(4)
        guard jsonLength > 0, jsonLength <= 65536, extraLength <= maximumPayload else {
            throw TailingError.protocolFailure("Erya 控制长度异常")
        }
        let body = try read(jsonLength)
        if extraLength > 0 { _ = try read(extraLength) }
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TailingError.protocolFailure("Erya 控制 JSON 异常")
        }
        return json
    }
}
