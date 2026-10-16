import Foundation

/// 재생/내보내기 배속 프리셋. 30fps 소스를 기준으로 출력 프레임레이트가 정수(30~36fps)가
/// 되도록 값을 잡았다.
///
/// 배속을 걸어도 소스 프레임을 하나도 버리지 않는다 — 프레임 간격만 배속만큼 균일하게
/// 좁아지고(1.1배속 = 30fps → 33fps), 그래서 모션이 튀지 않는다. 출력을 30fps로 고정하면
/// 33프레임 중 3장을 버려야 해서 11프레임마다 화면이 딸꾹질하듯 울렁거린다.
enum PlaybackSpeed: String, CaseIterable, Identifiable {
    case normal = "1x"
    case f31 = "1.03x"
    case f32 = "1.07x"
    case f33 = "1.10x"
    case f34 = "1.13x"
    case f35 = "1.17x"
    case f36 = "1.20x"

    var id: String { rawValue }

    /// 30fps 소스를 이 배속으로 내보냈을 때의 출력 프레임레이트.
    var outputFPSFor30: Int {
        switch self {
        case .normal: return 30
        case .f31: return 31
        case .f32: return 32
        case .f33: return 33
        case .f34: return 34
        case .f35: return 35
        case .f36: return 36
        }
    }

    /// 원본 대비 재생 속도 배수.
    var value: Double { Double(outputFPSFor30) / 30 }

    /// 저장된 프로젝트에서 복원할 때 사용. 모르는 값이면 1x.
    init(value: Double) {
        self = Self.allCases.first { abs($0.value - value) < 0.0005 } ?? .normal
    }
}
