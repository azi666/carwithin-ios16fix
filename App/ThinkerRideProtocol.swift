// SPDX-License-Identifier: AGPL-3.0-only
// Swift adaptation of MOTO-HUB ThinkerRideProtocol.kt (16b14b8).
// Copyright (C) 2026 Vincenzo Buonomano and the MOTO-HUB contributors.
import Foundation

enum ThinkerRideProtocol {
    static let service = "0000e0ff-3c17-d293-8e48-14fe2e4da212"
    static let keepalive = Data([2, 1, 0, 0, 0, 0])
    static func controlJSON(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var out = Data([0xee, 0xfd]); var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body); out.append(255); return out
    }
    static var handshake: Data {
        var out = Data([1, 1, 0, 0, 0, 0, 1, 0x17, 0, 0, 0, 4, 0, 0, 0, 2, 1, 0x12, 0, 0, 1, 0])
        let name = Data("CarWithin".utf8); out.append(name); out.append(Data(repeating: 0, count: 256 - name.count))
        out.append(contentsOf: [1, 0x0e, 0, 0, 0, 0, 1, 0x11, 0, 0, 0, 0]); return out
    }
    static func videoHeader(width: Int, height: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 69)
        out.replaceSubrange(1..<8, with: Array("android".utf8)) // Wire identifier, not application platform.
        out[65] = UInt8(width >> 8); out[66] = UInt8(width & 255)
        out[67] = UInt8(height >> 8); out[68] = UInt8(height & 255)
        return Data(out)
    }
    static func byteCat(_ json: Data, sequence: inout UInt16) -> [Data] {
        let sum = json.reduce(UInt8(0), &+)
        var payload = json; payload.append(contentsOf: [(sum >> 4) | 0x80, (sum & 15) | 0x80, 0])
        return stride(from: 0, to: payload.count, by: 100).map { start in
            let part = payload.subdata(in: start..<min(payload.count, start + 100))
            var out = Data([254, UInt8(sequence >> 8), UInt8(sequence & 255)]); sequence &+= 1
            out.append(part); out.append(255); out.append(Data(repeating: 0, count: 100 - part.count)); return out
        }
    }
    /// JSON notifications may be split across ATT packets or concatenated.
    struct JSONStream {
        private var pending = Data()
        mutating func append(_ fragment: Data) -> [[String: Any]] {
            pending.append(fragment)
            let bytes = [UInt8](pending)
            var depth = 0, begin = 0, consumed = 0, quoted = false, escaped = false
            var result: [[String: Any]] = []
            for (i, b) in bytes.enumerated() {
                if escaped { escaped = false; continue }
                if b == 92 && quoted { escaped = true; continue }
                if b == 34 { quoted.toggle(); continue }
                if quoted { continue }
                if b == 123 { if depth == 0 { begin = i }; depth += 1 }
                if b == 125 && depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        if let object = try? JSONSerialization.jsonObject(with: Data(bytes[begin...i])) as? [String: Any] { result.append(object) }
                        consumed = i + 1
                    }
                }
            }
            if consumed > 0 { pending.removeFirst(consumed) }
            if pending.count > 8192 { pending.removeAll() }
            return result
        }
    }
}
