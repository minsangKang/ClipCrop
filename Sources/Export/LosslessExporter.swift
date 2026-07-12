import AVFoundation

/// 재인코딩 없이 원본 샘플을 그대로 복사하는 무손실 저장.
/// QuickTime의 트림/클립 분리 저장과 동일한 방식 — HDR/Dolby Vision이 비트 단위로 보존된다.
enum LosslessExporter {
    static func export(sourceURL: URL, keptRanges: [CMTimeRange], to outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let source = AVMovie(url: sourceURL)
            let destination = try AVMutableMovie(settingsFrom: source, options: nil)
            destination.defaultMediaDataStorage = AVMediaDataStorage(url: outputURL, options: nil)

            for range in keptRanges {
                try destination.insertTimeRange(range, of: source, at: destination.duration, copySampleData: true)
            }
            try destination.writeHeader(to: outputURL, fileType: .mov, options: .addMovieHeaderToDestination)
        }.value
    }
}
