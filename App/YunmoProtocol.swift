// SPDX-License-Identifier: AGPL-3.0-only
// Swift adaptation of MOTO-HUB YunmoProtocol.kt, 16b14b80065ef0a5d58af5c77cd4aa4965267df6.
// Copyright (C) 2026 Vincenzo Buonomano and the MOTO-HUB contributors.
// Adaptation: CarWithin contributors. See App/MOTO-HUB-LICENSE.txt and THIRD_PARTY_NOTICES.txt.
import Foundation

enum YunmoProtocol {
    struct Frame { let command: UInt8; let payload: Data }
    static func simple(_ command: UInt8, _ payload: Data) -> Data {
        precondition(payload.count <= 10240)
        let hi = UInt8(payload.count >> 8), lo = UInt8(payload.count & 255)
        var out = Data([254, 254, 254, 254, command, hi, lo, hi &+ lo])
        out.append(payload)
        out.append(out.dropFirst(4).reduce(UInt8(0), &+))
        return out
    }
    static func jpeg(_ image: Data, id: UInt32) throws -> Data {
        guard !image.isEmpty, image.count <= (65535 - 1) * 32 else { throw TailingError.protocolFailure("Yunmo JPEG 长度异常") }
        let padded = (image.count + 31) / 32 * 32
        let blocks = (padded + 32) / 32
        var header = [UInt8](repeating: 0, count: 40)
        header.replaceSubrange(0..<5, with: [254, 254, 254, 254, 0x1d])
        header[5] = UInt8(blocks >> 8); header[6] = UInt8(blocks & 255); header[7] = header[5] &+ header[6]
        func little(_ value: UInt32, _ offset: Int, _ count: Int) {
            for i in 0..<count { header[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        little(UInt32(image.count), 8, 4)
        little(image.reduce(UInt32(0)) { ($0 + UInt32($1)) & 0xffff }, 12, 2)
        little(id, 16, 4) // media type 0 (JPEG), frame ID echoed by dashboard.
        var out = Data(header); out.append(image); out.append(Data(repeating: 0, count: padded - image.count))
        return out
    }
    static func read(diagnostic: (String) -> Void = { _ in }, _ read: (Int) throws -> Data) throws -> Frame {
        var header = [UInt8](try read(8))
        var slips = 0
        // Match the upstream sliding window, including a run of more than four FE bytes.
        while !(header.prefix(4).allSatisfy { $0 == 254 } && header[4] != 254) {
            guard slips < 4096 else { throw TailingError.protocolFailure("Yunmo 同步失败") }
            header.removeFirst(); header.append(try read(1)[0]); slips += 1
        }
        let h = Array(header[4..<8])
        let length = Int(h[1]) << 8 | Int(h[2])
        let headerHex = header.map { String(format: "%02x", $0) }.joined()
        guard length <= 10240, h[3] == h[1] &+ h[2] else {
            diagnostic("Yunmo invalid length header=\(headerHex) payloadBytes=\(length) skipped=\(slips)")
            throw TailingError.protocolFailure("Yunmo 长度校验失败")
        }
        let body = try read(length), checksum = try read(1)[0]
        let sum = (Data(h) + body).reduce(UInt8(0), &+)
        guard sum == checksum else {
            diagnostic(String(format: "Yunmo checksum mismatch header=%@ payloadBytes=%d calculated=%02x received=%02x skipped=%d", headerHex, length, sum, checksum, slips))
            throw TailingError.protocolFailure("Yunmo 校验失败")
        }
        if slips > 0 { diagnostic("Yunmo resynchronized after \(slips) bytes") }
        return Frame(command: h[0], payload: body)
    }
    static func dimensions(_ data: Data) -> (Int, Int)? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        let w = Int(b[4]) << 8 | Int(b[5]), h = Int(b[6]) << 8 | Int(b[7])
        guard (16...1920).contains(w), (16...1080).contains(h) else { return nil }
        return (w & ~1, h & ~1)
    }
    static func ack(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] == 0 else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1 + 1]) << ($1 * 8) }
    }
}
