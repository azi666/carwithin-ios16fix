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
    /// iOS matches the accessory against the phone's current network using the SSID carried in the
    /// wireless component (group 24, parameter 1). That slot used to hold the placeholder string
    /// "WiFiCarPlay", so iOS could never match the endpoint and never dialled RTSP. Only that
    /// substitution is applied: every other group keeps the layout iOS 16 already accepted
    /// (changing groups 16/17 made iOS answer 0x1D03 with parameter 0x0011).
    public static func identification(name: String, deviceID: String, ssid: String = "") throws -> IAP2Message {
        let mac = deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard mac.count == 6 else { throw ProtocolError.malformed("accessory device ID") }
        var fields = [string(0, name), string(1, "CP-Receiver-1"), string(2, "OEM"), string(3, "SN000001"),
            string(4, "1.0.0"), string(5, "1.0.0"),
            IAP2Parameter(id: 6, value: Data([0x43, 1])), IAP2Parameter(id: 7, value: Data([0x43, 0])),
            IAP2Parameter(id: 8, value: Data([0])), IAP2Parameter(id: 9, value: Data([0, 0])),
            string(12, "en"), string(13, "en")]
        fields.append(try group(16, [IAP2Parameter(id: 0, value: Data([0, 1])), string(1, "USBHost"),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 3, value: Data([1])), IAP2Parameter(id: 4, value: Data())]))
        fields.append(try group(17, [IAP2Parameter(id: 0, value: Data([0, 2])), string(1, "Bluetooth"),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 3, value: Data(mac))]))
        // Only the SSID changes here: it is what iOS compares against the current Wi-Fi network.
        fields.append(try group(24, [IAP2Parameter(id: 0, value: Data([0, 3])), string(1, ssid),
            IAP2Parameter(id: 2, value: Data()), IAP2Parameter(id: 4, value: Data())]))
        return IAP2Message(id: 0x1d01, parameters: fields)
    }

    /// CarPlay feature subscriptions the accessory requests before iOS will bring up the session:
    /// now playing (0x5000), route guidance (0x5200), power (0xAE00), communications (0x4157)
    /// and call state (0x4154). Layout mirrors DiPlay's wireless control client.
    public static func subscriptions() throws -> [IAP2Message] {
        func void(_ id: UInt16) -> IAP2Parameter { IAP2Parameter(id: id, value: Data()) }
        func groupValue(_ params: [IAP2Parameter]) throws -> Data {
            var data = Data()
            for param in params { data.append(try param.encoded()) }
            return data
        }
        var messages: [IAP2Message] = []
        messages.append(IAP2Message(id: 0x5000, parameters: [
            IAP2Parameter(id: 0, value: try groupValue([1, 4, 6, 12, 26].map { void(UInt16($0)) })),
            IAP2Parameter(id: 1, value: try groupValue([0, 1, 7].map { void(UInt16($0)) }))
        ]))
        messages.append(IAP2Message(id: 0x5200, parameters: [
            IAP2Parameter(id: 0, value: Data([0, 42])), void(1), void(2)
        ]))
        messages.append(IAP2Message(id: 0xAE00, parameters: [void(4), void(5), void(6)]))
        messages.append(IAP2Message(id: 0x4157, parameters: [void(0), void(4), void(5)]))
        messages.append(IAP2Message(id: 0x4154, parameters: [void(0), void(1), void(2), void(3), void(4), void(11)]))
        return messages
    }

    /// Accessory Wi-Fi configuration (0x5703): tells iOS which network this receiver sits on.
    /// Field layout verified against DiPlay's AccessoryWiFiConfigurationInformation endpoint.
    /// BSSID is optional; SSID/passphrase/security/channel are what iOS matches against.
    public static func wifiConfiguration(ssid: String, password: String, channel: UInt8,
                                        security: UInt8, bssid: Data? = nil) -> IAP2Message {
        var fields: [IAP2Parameter] = []
        if let bssid, bssid.count == 6 { fields.append(IAP2Parameter(id: 0, value: bssid)) }
        fields.append(string(1, ssid))
        if !password.isEmpty { fields.append(string(2, password)) }
        fields.append(IAP2Parameter(id: 3, value: Data([security])))
        fields.append(IAP2Parameter(id: 4, value: Data([channel])))
        return IAP2Message(id: 0x5703, parameters: fields)
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
