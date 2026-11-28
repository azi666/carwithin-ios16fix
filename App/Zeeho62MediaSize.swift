import Foundation

/// Keep 480/488 instruments on their original 480-line output. AE6 negotiates 484.
struct Zeeho62MediaSize: Equatable {
    let width: Int
    let height: Int
    static let standard = Self(width: 1024, height: 480)

    static func negotiate(width: Int, height: Int) throws -> Self {
        guard width == 1024 else { throw TailingError.protocolFailure("极核 6.2 寸不支持尺寸：\(width)×\(height)") }
        switch height {
        case 480, 488: return .standard
        case 484: return Self(width: 1024, height: 484)
        default: throw TailingError.protocolFailure("极核 6.2 寸不支持尺寸：\(width)×\(height)")
        }
    }
}
