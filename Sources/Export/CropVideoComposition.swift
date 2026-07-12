import AVFoundation
import CoreImage

/// crop 후 물빠진 색을 보정하는 톤 조정. 감마(중간톤 밝기 커브)만 남겨뒀다 —
/// 하이라이트/그림자(5점 톤 커브, CIToneCurve 기반)는 검증까지 마쳤지만 실제 사용감이
/// 기대와 달라 빠졌다.
struct Levels: Equatable {
    /// 감마: 1이면 조정 없음. 1보다 크면 어둡게, 작으면 밝게(중간톤). CIGammaAdjust 그대로.
    var gamma: Double = 1.0     // 0.5...2.0

    var isNeutral: Bool { gamma == 1.0 }
}

/// crop과 감마 조정을 함께 적용하는 AVVideoComposition을 만든다.
/// 미리보기(AVPlayerItem)와 내보내기(AVAssetExportSession) 양쪽에서 이 함수를 그대로 써서,
/// 편집 화면에서 본 색감이 내보내기 결과에 그대로 반영되게 한다(WYSIWYG).
///
/// `applyingCIFiltersWithHandler`는 애플이 HDR 영상에 필터를 적용할 때 쓰라고 제공하는 경로라
/// 색공간 변환을 내부적으로 처리해준다 — 직접 CIContext/색공간을 다루는 커스텀 컴포지터보다 안전하다.
/// (실측: 조정값이 중립일 때 기존 검증된 crop 결과와 0% 차이, dvvC 태그도 유지됨)
enum CropVideoComposition {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// - Parameters:
    ///   - asset: crop을 적용할 대상(미리보기의 트림된 컴포지션, 또는 내보내기의 트림된 컴포지션)
    ///   - videoTrack: asset의 비디오 트랙 (색 속성을 읽어온다)
    ///   - pixelCrop: 표시 좌표계 기준 crop 사각형. asset의 preferredTransform이 이미 적용된
    ///     좌표계이므로 회전을 별도로 보정할 필요가 없다.
    ///   - levels: 감마 톤 조정. isNeutral이면 필터를 아예 적용하지 않는다.
    static func make(asset: AVAsset, videoTrack: AVAssetTrack,
                     pixelCrop: CGRect, levels: Levels) async throws -> AVMutableVideoComposition {
        var colorPrimaries: String?
        var colorTransfer: String?
        var colorMatrix: String?
        if let formatDesc = try await videoTrack.load(.formatDescriptions).first {
            let ext = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
            colorPrimaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            colorTransfer = ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            colorMatrix = ext?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        }

        let translation = CGAffineTransform(translationX: -pixelCrop.minX, y: -pixelCrop.minY)
        let croppedExtent = CGRect(origin: .zero, size: pixelCrop.size)

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            var image = request.sourceImage.transformed(by: translation).cropped(to: croppedExtent)
            if !levels.isNeutral {
                image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": levels.gamma])
            }
            request.finish(with: image, context: nil)
        }
        videoComposition.renderSize = pixelCrop.size
        if let colorPrimaries { videoComposition.colorPrimaries = colorPrimaries }
        if let colorTransfer { videoComposition.colorTransferFunction = colorTransfer }
        if let colorMatrix { videoComposition.colorYCbCrMatrix = colorMatrix }
        return videoComposition
    }
}
