import Foundation

/// Stable IDs are saved independently of menu order. All added profiles await CarWithin road tests.
enum MotorcycleProfile: String, CaseIterable {
    case cfmoto700MT, cfmoto800MT, cfmoto675SRR, benelliTRK, vogeDS800X, zontes368E, zontes368G, zontes703RR, qjSRT550
    case kove625X, moriniXCape1200, kove450Rally, kove800X, shouqu, koveInstrument

    enum Transport { case easyConn, yunmo, thinkerRide, shouqu, erya }
    var transport: Transport {
        switch self {
        case .koveInstrument: return .erya
        case .shouqu: return .shouqu
        case .kove625X, .moriniXCape1200: return .yunmo
        case .kove450Rally, .kove800X: return .thinkerRide
        default: return .easyConn
        }
    }
    var title: String {
        let names: [Self: String] = [
            .cfmoto700MT: "春风 700MT-ADV", .cfmoto800MT: "春风 800MT", .cfmoto675SRR: "春风 675SRR",
            .benelliTRK: "贝纳利 TRK 502/702/702X", .vogeDS800X: "无极 DS800X", .zontes368E: "升仕 368E",
            .zontes368G: "升仕 368G", .zontes703RR: "升仕 703RR", .qjSRT550: "钱江 SRT550",
            .kove625X: "凯越 625X", .moriniXCape1200: "摩托莫里尼 X-Cape 1200",
            .kove450Rally: "凯越 450 Rally", .kove800X: "凯越 800X", .shouqu: "首驱 480×208", .koveInstrument: "凯越仪表"]
        return CWL(names[self]!)
    }
    var menuTitle: String { self == .shouqu ? title : title + CWL("（实验）") }
    var width: Int {
        switch self { case .shouqu: return 960; case .kove625X, .koveInstrument: return 640; case .moriniXCape1200: return 1024
        case .kove450Rally: return 1280; case .kove800X: return 600; default: return 1280 }
    }
    var height: Int {
        switch self { case .shouqu: return 416; case .kove625X, .koveInstrument: return 480; case .moriniXCape1200: return 464
        case .kove450Rally: return 640; case .kove800X: return 1024; default: return 720 }
    }
    var fps: Int { transport == .shouqu ? 5 : (transport == .yunmo || transport == .erya) ? 10 : 30 }
    var defaultAddress: String { transport == .yunmo ? "192.168.4.1" : "" }
    var byteCatBLE: Bool { self == .kove450Rally }
    var detail: String {
        switch transport {
        case .erya: return CWL("Erya · JPEG · 目标 10 FPS · 尺寸由仪表协商")
        case .shouqu: return CWL("480×208 · JPEG · 目标 5 FPS · 仪表逐帧拉取")
        case .easyConn: return CWL("EasyConn / PXC · H.264 · 尺寸由仪表协商")
        case .yunmo: return CWL("Yunmo · JPEG · 目标 10 FPS · 尺寸由仪表协商")
        case .thinkerRide: return "ThinkerRide · H.264 · \(width)×\(height) · 30 FPS"
        }
    }
    var instructions: String {
        var text = self == .shouqu ? CWL("首驱 480×208 已收到实车投屏成功反馈。先让 iPhone 加入仪表 Wi-Fi，启动仪表互联页面，再在这里启动 CarPlay。声音沿用 iPhone 或蓝牙。") : CWL("此车型尚未通过 CarWithin 实车验证。先让 iPhone 加入仪表 Wi-Fi，启动仪表互联页面，再在这里启动 CarPlay。声音沿用 iPhone 或蓝牙。")
        if self == .koveInstrument {
            text += "\n" + CWL("适用于官方凯越 App 的 Wi-Fi 仪表方案，尚未确认具体车型。先手动加入仪表 Wi-Fi，IP 与端口按仪表二维码填写；默认画面端口 11111、控制端口 11113。仅支持 JPEG 420，暂不包含蓝牙配网、二维码扫描和车把控制。测试后请导出诊断日志，并反馈车型、仪表固件及官方 App 是否能投屏。")
        }
        if self == .shouqu {
            text += "\n" + CWL("在系统设置加入 DIRECT-WJMT_ 开头的仪表 Wi-Fi，并核对 Wi-Fi 预设。IP 留空尝试本机网段 .1，失败时填写仪表实际地址。首次先前台测试；480×208 是投屏区域，仪表英寸数尚待确认。")
        }
        if transport == .thinkerRide { text += "\n" + CWL("先扫描并选择自己的仪表蓝牙。连接会执行配对和投屏启停，请按仪表提示确认。") }
        if self == .kove450Rally { text += "\n" + CWL("连接过程中，在仪表上长按向上键开启投屏。") }
        if self == .cfmoto675SRR { text += "\n" + CWL("部分固件使用 Wi-Fi Direct；需先确认 iPhone 能加入仪表网络，不能保证所有固件可用。") }
        if self == .zontes368G || self == .zontes703RR || self == .kove800X { text += "\n" + CWL("上游仍有部分功能或车型兼容性未确认，车把控制尚未接入。") }
        return text
    }
    var pxcProfile: CfmotoProfile {
        .init(width: width, height: height, fps: 30, bitrate: 3_500_000, label: title, discoversEasyConn: true)
    }
}
