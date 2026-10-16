import AVFoundation

/// crop 저장: 영상만 Apple HEVC 파이프라인으로 재인코딩하고,
/// 오디오는 원본에서 비트 그대로 무손실 복사한 뒤 한 파일로 합친다.
/// (예외 — 배속을 쓰면 오디오도 같이 늘이거나 줄여야 해서 샘플 복사가 불가능하다.
///  이때만 영상+오디오를 한 세션에서 함께 재인코딩한다.)
/// - crop(+레벨 보정)은 CropVideoComposition으로 렌더링한다 — 미리보기 플레이어도 동일한
///   함수를 쓰므로 편집 화면에서 본 색감이 내보내기 결과에 그대로 반영된다(WYSIWYG).
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
                       levels: Levels,
                       mosaicRegions: [MosaicRegion],
                       speed: Double = 1,
                       to outputURL: URL,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // 배속: 오디오 무손실 복사가 불가능하므로 영상·오디오를 한 번에 인코딩해 바로 출력한다.
        if speed != 1 {
            try await exportVideo(asset: asset,
                                  keptRanges: keptRanges,
                                  cropRectNormalized: cropRectNormalized,
                                  displaySize: displaySize,
                                  levels: levels,
                                  mosaicRegions: mosaicRegions,
                                  speed: speed,
                                  includeAudio: true,
                                  to: outputURL,
                                  onProgress: onProgress)
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipCrop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 1) 영상 트랙만 crop 재인코딩 → 임시 파일 (전체 진행률의 ~95%)
        try await exportVideo(asset: asset,
                              keptRanges: keptRanges,
                              cropRectNormalized: cropRectNormalized,
                              displaySize: displaySize,
                              levels: levels,
                              mosaicRegions: mosaicRegions,
                              speed: 1,
                              includeAudio: false,
                              to: tempURL) { progress in
            onProgress(progress * 0.95)
        }

        // 2) 인코딩된 영상 + 원본 오디오(무손실 복사)를 한 파일로 합치기
        try Task.checkCancellation()
        try await mux(videoURL: tempURL, sourceURL: asset.url, keptRanges: keptRanges, to: outputURL)
        onProgress(1.0)
    }

    // MARK: - crop 재인코딩

    /// includeAudio가 false면 영상 트랙만 인코딩해 뒤에서 원본 오디오를 무손실로 붙이고,
    /// true면(=배속) 스케일된 오디오까지 같은 세션에서 인코딩한다.
    private static func exportVideo(asset: AVURLAsset,
                                    keptRanges: [CMTimeRange],
                                    cropRectNormalized: CGRect,
                                    displaySize: CGSize,
                                    levels: Levels,
                                    mosaicRegions: [MosaicRegion],
                                    speed: Double,
                                    includeAudio: Bool,
                                    to outputURL: URL,
                                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let composition = try await EditState.makeComposition(from: asset, keptRanges: keptRanges,
                                                              includeAudio: includeAudio,
                                                              speed: speed)
        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "비디오 트랙이 없습니다.")
        }

        let pixelCrop = VideoGeometry.pixelCropRect(normalized: cropRectNormalized, displaySize: displaySize)
        let videoComposition = try await CropVideoComposition.make(asset: composition, videoTrack: videoTrack,
                                                                    pixelCrop: pixelCrop, displaySize: displaySize,
                                                                    levels: levels, mosaicRegions: mosaicRegions)

        // 배속을 걸어도 소스 프레임을 솎아내지 않는다 — sourceTrackIDForFrameTiming이 소스
        // 트랙에 걸린 기본 상태를 그대로 두면 소스 프레임 하나당 출력 프레임 하나가 나가고,
        // 간격만 배속만큼 균일하게 좁아진다(30fps 소스 1.1배속 → 33fps). 반대로 출력을 30fps로
        // 고정하면 33프레임 중 3장을 버려야 해서 11프레임마다 모션이 튀는 울렁거림이 생긴다.

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ExportError(message: "내보내기 세션을 만들 수 없습니다.")
        }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        // 배속을 걸어도 음정이 변하지 않게 — 미리보기 플레이어와 같은 알고리즘.
        session.audioTimePitchAlgorithm = .spectral

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
