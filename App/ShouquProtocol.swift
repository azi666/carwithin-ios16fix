import Foundation

/// Wire facts from the user-provided Shouqu protocol/capture package (2026-11-27).
/// No captured device identifier, RSA proof, app assets or reference source is bundled.
enum ShouquProtocol {
    static let width = 480, height = 208
    static let maximumJPEGBytes = 40 * 1024
    static let package = "com.skymotor.wujie" // Instrument client protocol identifier.
    static var hello: Data {
        get throws {
            let body = Data("{\n  \"packageName\" : \"com.skymotor.wujie\",\n  \"phoneType\" : \"iOS\"\n}".utf8)
            return try TailingProtocol.control(0x70000010, payload: body)
        }
    }
    static func viewHandshake(_ request: Data) throws -> Data {
        // These four bytes are an echoed handshake field, not a proven resolution declaration.
        guard request.count >= 4 else {
            throw TailingError.protocolFailure("首驱握手回显字段不足4字节")
        }
        var result = Data([1,0,0,0]); result.append(request.prefix(4)); result.append(contentsOf: [1,0,0,0])
        return result
    }
    static func validateViewArea(_ payload: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let config = object["viewAreaConfig"] as? [String: Any],
              let areas = config["viewAreas"] as? [[String: Any]], let area = areas.first,
              (area["width"] as? NSNumber)?.intValue == width,
              (area["height"] as? NSNumber)?.intValue == height else {
            throw TailingError.protocolFailure(CWL("首驱视区配置缺失或分辨率与当前 Profile 不符。"))
        }
    }
    static func viewAccepted() -> Data { Data("{\"viewAreaConfig\":{\"state\":0}}".utf8) }
    static func imageResponse(_ jpeg: Data?) throws -> Data {
        var result = Data()
        if let jpeg {
            guard jpeg.count >= 4, jpeg.count <= maximumJPEGBytes,
                  jpeg.starts(with: [255,216]), jpeg.suffix(2) == Data([255,217]) else {
                throw TailingError.protocolFailure(CWL("首驱 JPEG 不完整或超过 40 KiB。"))
            }
            result.appendLE(UInt32(jpeg.count)); result.append(jpeg)
        } else { result.appendLE(UInt32(0)) }
        return result
    }
}

struct ShouquPorts {
    var control: UInt16 = 10922
    var view: UInt16 = 10711
    var image: UInt16 = 10710
    var hello: UInt16 = 10930
}
