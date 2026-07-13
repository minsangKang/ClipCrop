import CoreGraphics
import Foundation

/// 고정 위치 모자이크 블록. 좌표계는 EditState.cropRect와 동일하게
/// "영상 표시 영역 기준 정규화(0~1), 좌상단 원점"을 쓴다 — crop을 켜지 않아도 독립적으로 동작한다.
struct MosaicRegion: Identifiable, Equatable {
    let id: UUID
    /// 정규화 위치/크기 (0~1)
    var rect: CGRect
    /// 불투명도. 0이면 안 보이고, 1이면 완전히 모자이크로 덮인다.
    var opacity: Double
    /// 모서리 둥글기. 0 = 각진 사각형, 1 = 짧은 변 기준 최대 라운드(알약 모양).
    var cornerRadius: Double

    init(id: UUID = UUID(), rect: CGRect, opacity: Double = 1.0, cornerRadius: Double = 0.15) {
        self.id = id
        self.rect = rect
        self.opacity = opacity
        self.cornerRadius = cornerRadius
    }
}
