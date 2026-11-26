import Foundation

/// iAP2 accessory identification and wireless session request fields.
public enum AccessoryMessages {
    public struct WiFi {
        public let ssid: String
        public let password: String
        public let channel: UInt8
        public init(ssid: String, password: String, channel: UInt8 = 36) throws {
            guard (1...32).contains(ssid.utf8.count), !ssid.contains("\0"),
                  password.isEmpty || ((8...63).contains(password.utf8.count) && !password.contains("\0")),
                  (1...196).contains(channel) else {
                throw ProtocolError.malformed("Wi-Fi name, password or channel")
            }
            self.ssid = ssid; self.password = password; self.channel = channel
        }
    }
    private static func string(_ id: UInt16, _ value: String) -> IAP2Parameter {
        IAP2Parameter(id: id, value: Data(value.utf8) + Data([0]))
    }
    private static func group(_ id: UInt16, _ values: [IAP2Parameter]) throws -> IAP2Parameter {
        IAP2Parameter(id: id, value: try values.reduce(into: Data()) { $0.append(try $1.encoded()) })
    }
    /// Big-endian u16 list used for the sent/received message catalogues (parameters 6 and 7).
    private static func u16List(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values { data.append(UInt8(truncatingIfNeeded: value >> 8)); data.append(UInt8(truncatingIfNeeded: value)) }
        return data
    }

    /// Accessory identification (0x1D01).
    ///
    /// The wireless component (group 24) must carry the access point SSID in parameter 1: iOS uses
    /// it to match the accessory against the network the phone is on. This used to hold a placeholder
    /// name ("WiFiCarPlay"), which left iOS unable to match the endpoint and it never dialled RTSP.
    /// The message catalogues also have to advertise 0x5703 / 0x4E0D / 0x4E0E, the wireless CarPlay
    /// transport notifications (layout verified against DiPlay's wireless identification client).
    public static func identification(name: String, deviceID: String, ssid: String = "") throws -> IAP2Message {
        let mac = deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard mac.count == 6 else { throw ProtocolError.malformed("accessory device ID") }
        var fields = [string(0, name), string(1, "CP-Receiver-1"), string(2, "OEM"), string(3, "SN000001"),
            string(4, "1.0.0"), string(5, "1.0.0"),
            IAP2Parameter(id: 6, value: u16List([0x4301, 0x5703])),
            IAP2Parameter(id: 7, value: u16List([0x4300, 0x4E0D, 0x4E0E, 0x5702])),
            IAP2Parameter(id: 8, value: Data([0])), IAP2Parameter(id: 9, value: Data([0, 0])),
            string(12, "en"), string(13, "en")]
        fields.append(try group(16, [IAP2Parameter(id: 0, value: Data([0, 0])), string(1, "USBHostTransport"),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 3, value: Data([1])), IAP2Parameter(id: 4, value: Data())]))
        fields.append(try group(17, [IAP2Parameter(id: 0, value: Data([0, 0])), string(1, "blue"),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 3, value: Data(mac)), string(4, "blue"),
            IAP2Parameter(id: 5, value: Data())]))
        fields.append(try group(24, [IAP2Parameter(id: 0, value: Data([0, 1])), string(1, ssid),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 3, value: Data([0, 1])),
            IAP2Parameter(id: 4, value: Data()), IAP2Parameter(id: 5, value: Data())]))
        return IAP2Message(id: 0x1d01, parameters: fields)
    }
    /// Source version echoed inside StartSession. Real head units advertise 9xx; iOS 18+ appears
    /// to gate the session on it, while iOS 16 was verified with the original value.
    private static var sessionSourceVersion: String {
        if #available(iOS 18.0, *) { return "950.7.1" }
        return "509.11"
    }
    public static func startSession(address: String, port: UInt16, deviceID: String, wifi: WiFi? = nil,
                                    publicKey: String = "") throws -> IAP2Message {
        // sendCarPlayStartSessionManual calls appendU32TLV for parameter 2.
        let portBytes = Data([0, 0, UInt8(truncatingIfNeeded: port >> 8), UInt8(truncatingIfNeeded: port)])
        var fields = [try group(0, [string(0, address)])]
        if let wifi {
            // Wireless group with single-byte channel and security fields.
            fields.append(try group(1, [string(0, wifi.ssid), string(1, wifi.password),
                IAP2Parameter(id: 2, value: Data([wifi.channel])), string(3, address),
                IAP2Parameter(id: 4, value: Data([wifi.password.isEmpty ? 0 : 2]))]))
        }
        // Parameter 4 carries the AirPlay receiver public key (hex). DiPlay always sends it;
        // leaving it empty means iOS has no key to match against the mDNS pk and it never
        // opens the RTSP connection.
        fields += [IAP2Parameter(id: 2, value: portBytes), string(3, deviceID),
                   string(4, publicKey), string(5, sessionSourceVersion)]
        // Parameter 8 declares mutual authentication support, which DiPlay always sets.
        // Without it iOS may treat the endpoint as unauthenticated and never dial RTSP.
        fields.append(IAP2Parameter(id: 8, value: Data([1])))
        return IAP2Message(id: 0x4301, parameters: fields)
    }
}
