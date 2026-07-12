import AVFoundation
import CoreImage

/// crop 후 물빠진 색을 보정하는 톤 조정. 애플 사진 앱의 "라이트" 패널 슬라이더 7종을
/// 최대한 비슷하게 흉내낸다. 애플의 실제 알고리즘(특히 휘도)은 비공개라 픽셀 단위로
/// 동일하게 재현할 수는 없고, Core Image 표준 필터로 육안상 근접한 결과를 낸다.
struct Levels: Equatable {
    var exposure: Double = 0        // -1...1, 0 = 조정 없음. 선형 라이트 공간에서 2^EV 배.
    var blackPoint: Double = 0      // -1...1, 0 = 조정 없음. +: 블랙 크러시, -: 블랙 페이드.
    var shadows: Double = 0         // -1...1, 0 = 조정 없음. +: 그림자를 밝게 들어올림.
    var highlights: Double = 0      // -1...1, 0 = 조정 없음. +: 하이라이트를 눌러 디테일 복원.
    var contrast: Double = 0        // -1...1, 0 = 조정 없음.
    var brightness: Double = 0      // -1...1, 0 = 조정 없음. +면 밝게, -면 어둡게. (CIColorControls 가산형)
    var brilliance: Double = 0      // -1...1, 0 = 조정 없음. 그림자/하이라이트에 소량 얹는 근사치.

    var isNeutral: Bool {
        exposure == 0 && blackPoint == 0 && shadows == 0 && highlights == 0
            && contrast == 0 && brightness == 0 && brilliance == 0
    }
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
    ///   - levels: 애플 사진 앱 스타일 톤 조정. isNeutral이면 필터를 아예 적용하지 않는다.
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
                image = applyLevels(levels, to: image)
            }
            request.finish(with: image, context: nil)
        }
        videoComposition.renderSize = pixelCrop.size
        if let colorPrimaries { videoComposition.colorPrimaries = colorPrimaries }
        if let colorTransfer { videoComposition.colorTransferFunction = colorTransfer }
        if let colorMatrix { videoComposition.colorYCbCrMatrix = colorMatrix }
        return videoComposition
    }

    /// 애플 사진 앱 "라이트" 패널 순서(노출→블랙 포인트→그림자/하이라이트→대비→밝기→휘도)를 따라
    /// 필터를 순차 적용한다. 전부 표준 CIFilter만 쓰고 값을 0~1 사이로 강제 클램프하지 않아서
    /// (블랙 포인트의 하한 클램프만 예외) Dolby Vision의 1.0 이상 확장 범위 하이라이트가 유지된다.
    private static func applyLevels(_ levels: Levels, to source: CIImage) -> CIImage {
        var image = source

        // 1. 노출 — 선형 라이트 공간에서 2^EV 배. CIExposureAdjust는 애플이 HDR 대응까지
        //    검증해서 제공하는 필터라 확장 범위 값도 그대로 스케일된다.
        if levels.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": levels.exposure * 2.0])
        }

        // 2. 블랙 포인트 — 레벨 조정의 입력 검은점 이동. CIColorMatrix로 전체 범위를 선형
        //    스트레치한 뒤(크러시 쪽) 0 미만만 클램프해서 하이라이트 쪽은 클리핑하지 않는다.
        if levels.blackPoint != 0 {
            image = applyBlackPoint(levels.blackPoint, to: image)
        }

        // 3. 그림자 / 하이라이트 — 애플이 정확히 이 용도로 제공하는 CIHighlightShadowAdjust.
        //    inputShadowAmount는 native range가 0...1(들어올리는 방향)뿐이라 +쪽만 이걸로 처리하고,
        //    (예전엔 *0.6로 눌러놔서 효과가 약했다 — 이제 pow 커브로 슬라이더 중간 구간부터도
        //    체감되게 하고 최대치도 1.0까지 그대로 쓴다)
        //    -쪽(그림자를 더 어둡게)은 이 필터로 표현이 안 돼서, 블랙 포인트의 "크러시" 로직을
        //    좁고 약하게 재사용해 그림자만 눌러 어둡게 만든다.
        //    휘도(+ 쪽)도 소량 얹어 그림자를 살짝 들어올리고 하이라이트를 살짝 복원한다.
        let shadowLift = (levels.shadows > 0 ? pow(levels.shadows, 0.6) : 0) + max(0, levels.brilliance) * 0.25
        let highlightAmount = 1.0 - levels.highlights * 0.6 - max(0, levels.brilliance) * 0.2
        if shadowLift != 0 || highlightAmount != 1.0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": max(0, min(1, shadowLift)),
                "inputHighlightAmount": max(0, min(1, highlightAmount))
            ])
        }
        if levels.shadows < 0 {
            image = applyBlackPoint(-levels.shadows * 0.5, to: image)
        }

        // 4. 대비
        if levels.contrast != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1.0 + levels.contrast * 0.5
            ])
        }

        // 5. 밝기 — 처음엔 CIGammaAdjust(감마 커브)를 재사용했는데, pow(x, power)가 0~1 구간에서는
        //    밝아지지만 1.0을 넘는 HDR 확장 범위 값에서는 방향이 반대로 뒤집혀(예: 2.0^0.7≈1.62로
        //    더 어두워짐) 하이라이트가 있는 장면에서 "밝기를 올렸는데 하이라이트는 눌리는" 모순된
        //    느낌이 났다. CIColorControls의 가산형 inputBrightness는 범위에 관계없이 전 채널에
        //    상수를 더하기만 해서 방향이 항상 일관된다.
        if levels.brightness != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": levels.brightness * 0.4
            ])
        }

        // 6. 휘도 — 로컬 대비/디테일 복원까지 섞는 애플의 실제 알고리즘은 비공개라 재현이
        //    불가능하다. 채도는 건드리지 않고 아주 약한 전역 대비만 얹어 "생기"를 흉내낸다.
        if levels.brilliance != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1.0 + levels.brilliance * 0.08
            ])
        }

        return image
    }

    private static func applyBlackPoint(_ blackPoint: Double, to image: CIImage) -> CIImage {
        if blackPoint > 0 {
            // 크러시: 입력 blackPoint*0.25 지점을 새 검은점으로 삼아 전체를 위로 스트레치.
            // 스트레치는 1.0 이상(HDR 하이라이트)도 함께 밀어 올리므로, 아래쪽만 0에서 클램프한다.
            let t = blackPoint * 0.25
            let scale = 1.0 / (1.0 - t)
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                    "inputBiasVector": CIVector(x: -t * scale, y: -t * scale, z: -t * scale, w: 0)
                ])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)
                ])
        } else {
            // 페이드: 검은색을 회색 쪽으로 들어올려 블랙이 옅어지게 한다.
            let lift = -blackPoint * 0.25
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - lift, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - lift, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - lift, w: 0),
                "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
            ])
        }
    }
}
