import AVFoundation
import Combine
import SwiftUI

/// 편집 세션 전체 상태. 재생은 항상 "남은 구간들을 이어붙인 컴포지션"을 재생하므로
/// 삭제된 구간은 미리보기와 타임라인에서 즉시 사라진다 (QuickTime과 동일).
@MainActor
final class EditState: ObservableObject {
    let sourceURL: URL
    let asset: AVURLAsset
    let player = AVPlayer()

    @Published var segments: [Segment] = []
    @Published var selectedSegmentID: UUID?
    @Published var currentTime: CMTime = .zero      // 컴포지션(미리보기) 타임라인 기준
    @Published var isPlaying = false
    @Published var isLoaded = false
    @Published var loadError: String?

    @Published var cropAspect: CropAspect = .none {
        didSet { resetCropRect() }
    }
    /// 영상 표시 영역 기준 정규화(0~1) crop 사각형. 좌상단 원점.
    @Published var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { updatePreviewVideoComposition() }
    }
    /// crop 후 물빠진 색을 보정하는 톤 조정(LumaFusion "레벨"의 입력 검은점/흰점/감마).
    /// 미리보기와 내보내기가 CropVideoComposition을 공유해서 쓰므로, 편집 화면에서
    /// 눈으로 맞춘 값이 내보내기 결과에 그대로 반영된다.
    @Published var levels = Levels() {
        didSet { updatePreviewVideoComposition() }
    }

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportMessage: String?
    @Published var exportETA: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 진행 중인 내보내기 작업. 취소 버튼이 cancel()을 호출한다.
    var exportTask: Task<Void, Never>?

    /// 회전(preferredTransform) 적용 후의 실제 표시 크기 (픽셀)
    private(set) var displaySize: CGSize = .zero
    private(set) var displayTransform: CGAffineTransform = .identity
    private(set) var sourceDuration: CMTime = .zero

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        self.sourceURL = url
        self.asset = AVURLAsset(url: url)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load() async {
        do {
            let duration = try await asset.load(.duration)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                loadError = "비디오 트랙을 찾을 수 없습니다."
                return
            }
            let (size, transform) = try await VideoGeometry.displayInfo(for: videoTrack)
            sourceDuration = duration
            displaySize = size
            displayTransform = transform
            segments = [Segment(sourceRange: CMTimeRange(start: .zero, duration: duration))]

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30), queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.currentTime = time }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isPlaying = false }
            }

            await rebuildPlayerItem(seekTo: .zero)
            isLoaded = true
        } catch {
            loadError = "영상을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 타임라인 계산

    /// 남은 구간 전체 길이
    var totalDuration: CMTime {
        segments.reduce(.zero) { CMTimeAdd($0, $1.sourceRange.duration) }
    }

    /// 컴포지션 시간 → 원본 시간
    func sourceTime(forCompositionTime t: CMTime) -> CMTime {
        var accum = CMTime.zero
        for seg in segments {
            let next = CMTimeAdd(accum, seg.sourceRange.duration)
            if CMTimeCompare(t, next) < 0 {
                return CMTimeAdd(seg.sourceRange.start, CMTimeSubtract(t, accum))
            }
            accum = next
        }
        return segments.last?.sourceRange.end ?? .zero
    }

    /// 컴포지션 시간이 속한 세그먼트
    func segment(atCompositionTime t: CMTime) -> Segment? {
        var accum = CMTime.zero
        for seg in segments {
            let next = CMTimeAdd(accum, seg.sourceRange.duration)
            if CMTimeCompare(t, next) < 0 { return seg }
            accum = next
        }
        return segments.last
    }

    /// 세그먼트의 컴포지션 타임라인 상 시작 시간
    func compositionStart(of segment: Segment) -> CMTime {
        var accum = CMTime.zero
        for seg in segments {
            if seg.id == segment.id { return accum }
            accum = CMTimeAdd(accum, seg.sourceRange.duration)
        }
        return accum
    }

    // MARK: - 되돌리기 (⌘Z) / 다시 실행 (⌘⇧Z)

    private struct UndoSnapshot {
        let segments: [Segment]
        let selectedSegmentID: UUID?
        let currentTime: CMTime
    }
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []

    private var currentSnapshot: UndoSnapshot {
        UndoSnapshot(segments: segments,
                     selectedSegmentID: selectedSegmentID,
                     currentTime: currentTime)
    }

    /// 새 편집 동작 직전에 호출. 새 동작이 생기면 redo 히스토리는 무효가 된다.
    private func pushUndoSnapshot() {
        undoStack.append(currentSnapshot)
        redoStack.removeAll()
        updateUndoFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(snapshot)
    }

    private func restore(_ snapshot: UndoSnapshot) {
        segments = snapshot.segments
        selectedSegmentID = snapshot.selectedSegmentID
        updateUndoFlags()
        Task { await rebuildPlayerItem(seekTo: snapshot.currentTime) }
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - 편집 동작

    /// 재생헤드 위치에서 클립 분리 (⌘Y)
    func splitAtPlayhead() {
        let compTime = currentTime
        guard let seg = segment(atCompositionTime: compTime),
              let index = segments.firstIndex(where: { $0.id == seg.id }) else { return }

        let srcTime = sourceTime(forCompositionTime: compTime)
        let margin = CMTime(value: 1, timescale: 30)
        // 구간 경계에 너무 가까우면 무시 (0 길이 세그먼트 방지)
        guard CMTimeCompare(CMTimeSubtract(srcTime, seg.sourceRange.start), margin) > 0,
              CMTimeCompare(CMTimeSubtract(seg.sourceRange.end, srcTime), margin) > 0 else { return }

        pushUndoSnapshot()
        let first = Segment(sourceRange: CMTimeRange(start: seg.sourceRange.start, end: srcTime))
        let second = Segment(sourceRange: CMTimeRange(start: srcTime, end: seg.sourceRange.end))
        segments.replaceSubrange(index...index, with: [first, second])
        selectedSegmentID = second.id
        Task { await rebuildPlayerItem(seekTo: compTime) }
    }

    /// 선택된 세그먼트 삭제 (Delete)
    func deleteSelectedSegment() {
        guard segments.count > 1,
              let id = selectedSegmentID,
              let index = segments.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        let deletedStart = compositionStart(of: segments[index])
        segments.remove(at: index)
        selectedSegmentID = nil
        Task { await rebuildPlayerItem(seekTo: deletedStart) }
    }

    func seek(toCompositionTime t: CMTime) {
        let clamped = CMTimeClampToRange(t, range: CMTimeRange(start: .zero, duration: totalDuration))
        currentTime = clamped
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if CMTimeCompare(currentTime, totalDuration) >= 0 {
                seek(toCompositionTime: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func resetCropRect() {
        guard let ratio = cropAspect.ratio, displaySize.width > 0 else {
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        // 영상 안에 들어가는 최대 크기의 중앙 배치 사각형 (표시 좌표 기준)
        let videoRatio = displaySize.width / displaySize.height
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > videoRatio {
            h = videoRatio / ratio          // 좌우 꽉 채우고 상하를 줄임
        } else {
            w = ratio / videoRatio          // 상하 꽉 채우고 좌우를 줄임
        }
        cropRect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    // MARK: - 프로젝트 저장/불러오기

    func makeProjectFile() -> ProjectFile {
        ProjectFile(
            sourcePath: sourceURL.path,
            segments: segments.map {
                ProjectFile.SegmentData(start: ProjectFile.TimeValue($0.sourceRange.start),
                                        duration: ProjectFile.TimeValue($0.sourceRange.duration))
            },
            cropAspect: cropAspect.rawValue,
            cropRect: ProjectFile.RectData(x: cropRect.minX, y: cropRect.minY,
                                           width: cropRect.width, height: cropRect.height)
        )
    }

    /// load() 완료 후 호출. 저장된 편집 내용을 현재 세션에 적용한다.
    func apply(project: ProjectFile) {
        let fullRange = CMTimeRange(start: .zero, duration: sourceDuration)
        let restored = project.segments
            .map { CMTimeRange(start: $0.start.cmTime, duration: $0.duration.cmTime) }
            .map { $0.intersection(fullRange) }   // 소스 범위 밖 구간 방어
            .filter { $0.duration.seconds > 0 }
            .map { Segment(sourceRange: $0) }
        if !restored.isEmpty {
            segments = restored
        }
        selectedSegmentID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()

        // cropAspect의 didSet이 cropRect를 초기화하므로 aspect를 먼저 설정한다
        cropAspect = CropAspect(rawValue: project.cropAspect) ?? .none
        if cropAspect != .none {
            cropRect = CGRect(x: project.cropRect.x, y: project.cropRect.y,
                              width: project.cropRect.width, height: project.cropRect.height)
        }
        Task { await rebuildPlayerItem(seekTo: .zero) }
    }

    // MARK: - 미리보기 컴포지션

    /// 남은 세그먼트들로 미리보기용 컴포지션을 만들어 플레이어 아이템 교체
    private func rebuildPlayerItem(seekTo compTime: CMTime?) async {
        do {
            let composition = try await Self.makeComposition(from: asset, keptRanges: segments.map(\.sourceRange))
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = try await makePreviewVideoComposition(for: composition)
            player.replaceCurrentItem(with: item)
            if let compTime {
                seek(toCompositionTime: compTime)
            }
        } catch {
            loadError = "미리보기 구성 실패: \(error.localizedDescription)"
        }
    }

    /// crop 사각형이 없으면 nil(원본 그대로 재생), 있으면 내보내기와 동일한
    /// CropVideoComposition을 적용해 crop·레벨 조정이 실제로 어떻게 나올지 미리 보여준다.
    private func makePreviewVideoComposition(for composition: AVAsset) async throws -> AVVideoComposition? {
        guard cropAspect != .none,
              let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let pixelCrop = VideoGeometry.pixelCropRect(normalized: cropRect, displaySize: displaySize)
        return try await CropVideoComposition.make(asset: composition, videoTrack: videoTrack,
                                                    pixelCrop: pixelCrop, levels: levels)
    }

    /// crop 사각형이나 감마 값만 바뀌었을 때, 플레이어 아이템을 새로 만들지 않고
    /// videoComposition만 다시 계산해 끊김 없이 미리보기에 반영한다.
    private func updatePreviewVideoComposition() {
        guard let item = player.currentItem else { return }
        let itemAsset = item.asset
        Task {
            let composition = try? await makePreviewVideoComposition(for: itemAsset)
            item.videoComposition = composition
        }
    }

    /// 남은 구간들을 이어붙인 AVMutableComposition (미리보기·재인코딩 내보내기 공용)
    static func makeComposition(from asset: AVURLAsset, keptRanges: [CMTimeRange],
                                includeAudio: Bool = true) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var trackPairs: [(source: AVAssetTrack, dest: AVMutableCompositionTrack)] = []
        if let v = videoTracks.first,
           let dest = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            dest.preferredTransform = try await v.load(.preferredTransform)
            trackPairs.append((v, dest))
        }
        if includeAudio, let a = audioTracks.first,
           let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            trackPairs.append((a, dest))
        }

        var cursor = CMTime.zero
        for range in keptRanges {
            for (source, dest) in trackPairs {
                try dest.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return composition
    }
}
