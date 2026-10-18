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

    /// crop 영역이 bounds를 꽉 채우도록 확대 배치했을 때의 "전체 프레임" 사각형.
    /// 반환값 안에서 cropRect가 차지하는 부분이 정확히 bounds에 aspect-fit된 영역이 된다.
    /// bounds 밖으로 비어져 나가는 건 호출 측에서 clip 처리한다.
    static func croppedVideoRect(displaySize: CGSize, cropRect: CGRect, in bounds: CGRect) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0,
              cropRect.width > 0, cropRect.height > 0 else { return bounds }
        let cropPixelSize = CGSize(width: displaySize.width * cropRect.width,
                                   height: displaySize.height * cropRect.height)
        let visible = AVMakeRect(aspectRatio: cropPixelSize, insideRect: bounds)
        let fullWidth = visible.width / cropRect.width
        let fullHeight = visible.height / cropRect.height
        return CGRect(x: visible.minX - cropRect.minX * fullWidth,
                      y: visible.minY - cropRect.minY * fullHeight,
                      width: fullWidth, height: fullHeight)
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
