import CoreMedia
import Foundation

/// 타임라인의 한 구간. 원본 영상 기준 시간 범위를 가진다.
/// segments 배열에는 "남아 있는" 구간만 존재하며, 삭제된 구간은 배열에서 제거된다.
struct Segment: Identifiable, Equatable {
    let id: UUID
    var sourceRange: CMTimeRange

    init(sourceRange: CMTimeRange) {
        self.id = UUID()
        self.sourceRange = sourceRange
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case none = "없음"
    case ratio2to1 = "2:1"
    case ratioiPhone = "19.5:9"
    case ratio16to9 = "16:9"

    var id: String { rawValue }

    /// 가로/세로 비율. none이면 nil.
    var ratio: CGFloat? {
        switch self {
        case .none: return nil
        case .ratio2to1: return 2.0
        case .ratioiPhone: return 19.5 / 9.0
        case .ratio16to9: return 16.0 / 9.0
        }
    }
}
