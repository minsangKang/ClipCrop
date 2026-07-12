import AVFoundation

/// crop 저장: 영상만 Apple HEVC 파이프라인으로 재인코딩하고,
/// 오디오는 원본에서 비트 그대로 무손실 복사한 뒤 한 파일로 합친다.
/// - 기하 변환만 쓰는 videoComposition은 built-in compositor가 HDR을 그대로 통과시키며,
///   소스가 Dolby Vision 8.4이면 HEVC 프리셋 출력도 DV 8.4로 유지된다.
/// - 오디오를 재인코딩하지 않으므로 음질 손실·글리치가 없고 공간 음향 트랙도 전부 보존된다.
enum ReencodeExporter {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func export(asset: AVURLAsset,
                       keptRanges: [CMTimeRange],
                       cropRectNormalized: CGRect,
                       displaySize: CGSize,
                       displayTransform: CGAffineTransform,
                       to outputURL: URL,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipCrop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 1) 영상 트랙만 crop 재인코딩 → 임시 파일 (전체 진행률의 ~95%)
        try await exportCroppedVideo(asset: asset,
                                     keptRanges: keptRanges,
                                     cropRectNormalized: cropRectNormalized,
                                     displaySize: displaySize,
                                     displayTransform: displayTransform,
                                     to: tempURL) { progress in
            onProgress(progress * 0.95)
        }

        // 2) 인코딩된 영상 + 원본 오디오(무손실 복사)를 한 파일로 합치기
        try Task.checkCancellation()
        try await mux(videoURL: tempURL, sourceURL: asset.url, keptRanges: keptRanges, to: outputURL)
        onProgress(1.0)
    }

    // MARK: - 영상 crop 재인코딩

    private static func exportCroppedVideo(asset: AVURLAsset,
                                           keptRanges: [CMTimeRange],
                                           cropRectNormalized: CGRect,
                                           displaySize: CGSize,
                                           displayTransform: CGAffineTransform,
                                           to outputURL: URL,
                                           onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let composition = try await EditState.makeComposition(from: asset, keptRanges: keptRanges,
                                                              includeAudio: false)
        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "비디오 트랙이 없습니다.")
        }

        let pixelCrop = VideoGeometry.pixelCropRect(normalized: cropRectNormalized, displaySize: displaySize)

        // 회전 보정 변환 뒤에 crop 원점 이동을 이어붙여, crop 영역이 출력 원점에 오도록 한다
        let cropTransform = displayTransform.concatenating(
            CGAffineTransform(translationX: -pixelCrop.minX, y: -pixelCrop.minY)
        )

        // propertiesOf:가 프레임레이트·색 속성(HDR 포함)을 소스에서 그대로 가져온다
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        videoComposition.renderSize = pixelCrop.size

        // 색 공간을 소스와 동일하게 명시하지 않으면 컴포지터가 BT.709(SDR) 작업 색공간으로
        // 렌더링해 HDR 색이 물빠져 보인다 — 원본 트랙의 색 속성을 그대로 강제한다
        if let sourceTrack = try await asset.loadTracks(withMediaType: .video).first,
           let formatDesc = try await sourceTrack.load(.formatDescriptions).first {
            let ext = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
            if let primaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
                videoComposition.colorPrimaries = primaries
            }
            if let transfer = ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                videoComposition.colorTransferFunction = transfer
            }
            if let matrix = ext?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
                videoComposition.colorYCbCrMatrix = matrix
            }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(cropTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError(message: "내보내기 세션을 만들 수 없습니다.")
        }
        session.videoComposition = videoComposition

        // 진행률 감시는 자식 태스크로, export는 현재 태스크에서 실행해
        // 바깥 Task.cancel()이 세션 취소로 이어지게 한다
        let monitorTask = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { monitorTask.cancel() }
        try await session.export(to: outputURL, as: .mov)
    }

    // MARK: - 오디오 무손실 합치기

    /// 인코딩된 영상 파일을 그대로 복사하고, 원본의 모든 오디오 트랙에서
    /// 남은 구간들을 샘플 데이터 그대로(재인코딩 없이) 이어붙인다.
    private static func mux(videoURL: URL, sourceURL: URL,
                            keptRanges: [CMTimeRange], to outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let videoMovie = AVMovie(url: videoURL)
            let sourceMovie = AVMovie(url: sourceURL)

            let destination = try AVMutableMovie(settingsFrom: videoMovie, options: nil)
            destination.defaultMediaDataStorage = AVMediaDataStorage(url: outputURL, options: nil)

            // 인코딩된 영상 전체를 무손실 복사
            let videoDuration = videoMovie.duration
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                            of: videoMovie, at: .zero, copySampleData: true)

            // 원본의 모든 오디오 트랙을 구간별로 무손실 복사 (공간 음향 등 포함)
            for sourceTrack in sourceMovie.tracks(withMediaType: .audio) {
                guard let destTrack = destination.addMutableTrack(withMediaType: .audio,
                                                                  copySettingsFrom: sourceTrack,
                                                                  options: nil) else {
                    throw ExportError(message: "오디오 트랙을 만들 수 없습니다.")
                }
                var cursor = CMTime.zero
                for range in keptRanges {
                    try destTrack.insertTimeRange(range, of: sourceTrack, at: cursor, copySampleData: true)
                    cursor = CMTimeAdd(cursor, range.duration)
                }
            }

            try destination.writeHeader(to: outputURL, fileType: .mov, options: .addMovieHeaderToDestination)
        }.value
    }
}
