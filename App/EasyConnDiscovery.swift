import Foundation
import Darwin

/// New profiles only. Existing CFMOTO presets retain their fixed 10930 startup behavior.
final class EasyConnDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Endpoint { let address: String; let port: UInt16; let package: String }
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var result: Endpoint?
    private let completed = DispatchSemaphore(value: 0)
    private let expected: String?
    init(expected: String?) { self.expected = expected }
    static func find(expected: String?, timeout: Double = 4) -> Endpoint? {
        precondition(!Thread.isMainThread)
        let search = EasyConnDiscovery(expected: expected)
        DispatchQueue.main.async { search.browser.delegate = search; search.browser.searchForServices(ofType: "_EasyConn._tcp.", inDomain: "local.") }
        _ = search.completed.wait(timeout: .now() + timeout)
        var endpoint: Endpoint?
        DispatchQueue.main.sync {
            endpoint = search.result
            search.browser.stop(); search.browser.delegate = nil
            search.services.forEach { $0.stop(); $0.delegate = nil }
        }
        return endpoint
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 3)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard result == nil, (1...65535).contains(sender.port) else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard let data = txt["packagename"], let package = String(data: data, encoding: .utf8), !package.isEmpty else { return }
        for data in sender.addresses ?? [] {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ip: String? = data.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size, let base = raw.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == sa_family_t(AF_INET),
                      getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            guard let ip, !ip.hasPrefix("127."), expected == nil || expected == ip else { continue }
            result = Endpoint(address: ip, port: UInt16(sender.port), package: package); completed.signal(); return
        }
    }
}
