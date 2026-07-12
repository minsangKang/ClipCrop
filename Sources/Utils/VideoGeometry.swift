import AVFoundation
import CoreGraphics

enum VideoGeometry {
    /// preferredTransform(회전)을 적용한 실제 표시 크기와,
    /// 콘텐츠를 (0,0) 원점의 표시 공간으로 옮기는 보정된 변환을 반환.
    static func displayInfo(for track: AVAssetTrack) async throws -> (size: CGSize, transform: CGAffineTransform) {
        let naturalSize = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let mapped = CGRect(origin: .zero, size: naturalSize).applying(t)
        let fix = CGAffineTransform(translationX: -mapped.minX, y: -mapped.minY)
        return (CGSize(width: abs(mapped.width), height: abs(mapped.height)), t.concatenating(fix))
    }

    /// aspect-fit으로 뷰 안에 배치된 영상 영역 (AVMakeRect과 동일)
    static func videoRect(displaySize: CGSize, in bounds: CGRect) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
    }

    /// 정규화 crop 사각형 → 픽셀 crop 사각형 (짝수 정렬, 표시 좌표계 기준)
    static func pixelCropRect(normalized: CGRect, displaySize: CGSize) -> CGRect {
        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v / 2) * 2) }
        var x = even(normalized.minX * displaySize.width)
        var y = even(normalized.minY * displaySize.height)
        var w = even(normalized.width * displaySize.width)
        var h = even(normalized.height * displaySize.height)
        w = max(2, min(w, even(displaySize.width)))
        h = max(2, min(h, even(displaySize.height)))
        x = max(0, min(x, displaySize.width - w))
        y = max(0, min(y, displaySize.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
