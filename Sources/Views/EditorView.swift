import AVFoundation
import SwiftUI

struct EditorView: View {
    @ObservedObject var state: EditState
    let onClose: () -> Void
    let onOpenProject: (URL) -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            transportBar
            levelsBar
            mosaicBar
            TimelineView(state: state)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($editorFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            state.togglePlayback()
            return .handled
        }
        .onDeleteCommand { state.deleteSelectedSegment() }
        .onAppear { editorFocused = true }
        .toolbar { toolbarContent }
        .navigationTitle(state.sourceURL.lastPathComponent)
        .overlay { exportOverlay }
        .alert("오류", isPresented: .constant(state.loadError != nil)) {
            Button("확인") { state.loadError = nil }
        } message: {
            Text(state.loadError ?? "")
        }
    }

    // MARK: - 플레이어 + crop 오버레이

    private var playerArea: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let videoRect = VideoGeometry.videoRect(displaySize: state.displaySize, in: bounds)
            ZStack(alignment: .topLeading) {
                // PlayerView 프레임을 videoRect에 정확히 맞춘다 — AVPlayerView가 내부적으로
                // 따로 letterbox 계산을 하게 두면(.resizeAspect) 창 크기가 실시간으로 바뀔 때
                // 그 계산이 SwiftUI 쪽 오버레이 좌표 계산과 다른 렌더 타이밍에 갱신되면서
                // crop/모자이크 사각형이 비디오와 따로 노는 것처럼 어긋나 보인다. 여기서 프레임을
                // 직접 videoRect로 잘라주면 두 계산이 완전히 같은 값을 공유해 어긋날 수가 없다.
                PlayerView(player: state.player)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .offset(x: videoRect.minX, y: videoRect.minY)
                if state.cropAspect != .none {
                    CropOverlayView(state: state, videoRect: videoRect)
                        // 모자이크 블록이 있을 땐 crop 드래그가 그 위 터치를 가로채지 않도록 완전히 끈다.
                        .allowsHitTesting(state.mosaicRegions.isEmpty)
                }
                if !state.mosaicRegions.isEmpty {
                    MosaicOverlayView(state: state, videoRect: videoRect)
                }
            }
        }
        .background(Color.black)
        .padding(.bottom, 8)
    }

    // MARK: - 재생 컨트롤 바

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button {
                state.togglePlayback()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)

            Text("\(format(state.currentTime)) / \(format(state.totalDuration))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if state.cropAspect != .none {
                let crop = VideoGeometry.pixelCropRect(normalized: state.cropRect,
                                                       displaySize: state.displaySize)
                Text("Crop: \(Int(crop.width))×\(Int(crop.height))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 레벨(톤 보정) 바

    /// crop이 HDR 색을 물빠지게 만드는 걸 눈으로 보면서 보정하는, 애플 사진 앱 스타일 슬라이더 7종.
    /// 미리보기와 내보내기가 같은 CropVideoComposition을 쓰므로 여기서 맞춘 값이 그대로 내보내진다.
    private static let levelsGridColumns = [
        GridItem(.flexible(), spacing: 24, alignment: .leading),
        GridItem(.flexible(), spacing: 24, alignment: .leading)
    ]

    @ViewBuilder
    private var levelsBar: some View {
        if state.cropAspect != .none {
            LazyVGrid(columns: Self.levelsGridColumns, alignment: .leading, spacing: 6) {
                levelsSlider(title: "노출", value: $state.levels.exposure, range: -1...1, resetValue: 0)
                levelsSlider(title: "하이라이트", value: $state.levels.highlights, range: -1...1, resetValue: 0)
                levelsSlider(title: "그림자", value: $state.levels.shadows, range: -1...1, resetValue: 0)
                levelsSlider(title: "대비", value: $state.levels.contrast, range: -1...1, resetValue: 0)
                levelsSlider(title: "밝기", value: $state.levels.brightness, range: -1...1, resetValue: 0)
                levelsSlider(title: "블랙 포인트", value: $state.levels.blackPoint, range: -1...1, resetValue: 0)
                levelsSlider(title: "휘도", value: $state.levels.brilliance, range: -1...1, resetValue: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func levelsSlider(title: String, value: Binding<Double>,
                              range: ClosedRange<Double>, resetValue: Double) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Button {
                value.wrappedValue = resetValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(value.wrappedValue == resetValue ? .tertiary : .secondary)
            .disabled(value.wrappedValue == resetValue)
            .help("기본값으로 초기화")
            Slider(value: value, in: range)
                .onTapGesture(count: 2) { value.wrappedValue = resetValue }
                .help("더블클릭하면 기본값으로 초기화")
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    // MARK: - 모자이크 바

    /// 선택된 모자이크 블록의 불투명도/코너 라운드를 조절하고 삭제할 수 있는 바.
    /// 여러 블록이 있어도 한 번에 하나씩만 편집 — 플레이어 위에서 탭해 선택을 바꾼다.
    @ViewBuilder
    private var mosaicBar: some View {
        if let id = state.selectedMosaicID,
           let index = state.mosaicRegions.firstIndex(where: { $0.id == id }) {
            let region = $state.mosaicRegions[index]
            HStack(spacing: 16) {
                Text("모자이크 \(index + 1)/\(state.mosaicRegions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                levelsSlider(title: "불투명도", value: region.opacity, range: 0...1, resetValue: 1.0)
                levelsSlider(title: "코너 라운드", value: region.cornerRadius, range: 0...1, resetValue: 0.15)
                Spacer()
                Button(role: .destructive) {
                    state.removeMosaicRegion(id: id)
                } label: {
                    Label("삭제", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("이 모자이크 블록 삭제")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("다른 영상 열기…") { onClose() }
                Divider()
                Button("편집 내용 저장…") { saveProject() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!state.isLoaded)
                Button("편집 내용 불러오기…") { openProjectPanel() }
            } label: {
                Label("파일", systemImage: "doc")
            }

            Picker("비율", selection: $state.cropAspect) {
                ForEach(CropAspect.allCases) { aspect in
                    Text(aspect.rawValue).tag(aspect)
                }
            }
            .pickerStyle(.segmented)
            .help("crop 비율 선택")

            Button {
                state.addMosaicRegion()
            } label: {
                Label("모자이크 추가", systemImage: "checkerboard.rectangle")
            }
            .help("고정 위치 모자이크 블록 추가 (여러 개 추가 가능)")

            Button {
                state.undo()
            } label: {
                Label("되돌리기", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!state.canUndo)
            .help("되돌리기 (⌘Z)")

            Button {
                state.redo()
            } label: {
                Label("다시 실행", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!state.canRedo)
            .help("다시 실행 (⌘⇧Z)")

            Button {
                state.splitAtPlayhead()
            } label: {
                Label("클립 분리", systemImage: "scissors")
            }
            .keyboardShortcut("y", modifiers: .command)
            .help("재생헤드 위치에서 클립 분리 (⌘Y)")

            Button {
                save()
            } label: {
                Label("저장", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!state.isLoaded || state.isExporting)
        }
    }

    // MARK: - 저장

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        let baseName = state.sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = baseName + " 편집본.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let keptRanges = state.segments.map(\.sourceRange)
        let useEffects = state.cropAspect != .none || !state.mosaicRegions.isEmpty
        state.isExporting = true
        state.exportProgress = 0
        state.exportETA = nil
        state.exportMessage = useEffects ? "HDR 보존 재인코딩 중…" : "무손실 저장 중…"

        let exportStart = Date()
        state.exportTask = Task {
            do {
                if useEffects {
                    try await ReencodeExporter.export(
                        asset: state.asset,
                        keptRanges: keptRanges,
                        cropRectNormalized: state.cropRect,
                        displaySize: state.displaySize,
                        levels: state.levels,
                        mosaicRegions: state.mosaicRegions,
                        to: outputURL
                    ) { progress in
                        Task { @MainActor in
                            state.exportProgress = progress
                            if progress > 0.02 {
                                let elapsed = Date().timeIntervalSince(exportStart)
                                let remaining = elapsed * (1 - progress) / progress
                                state.exportETA = Self.formatETA(remaining)
                            }
                        }
                    }
                } else {
                    try await LosslessExporter.export(
                        sourceURL: state.sourceURL,
                        keptRanges: keptRanges,
                        to: outputURL
                    )
                }
                state.exportMessage = nil
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch {
                state.exportMessage = nil
                if isCancellation(error) {
                    try? FileManager.default.removeItem(at: outputURL)   // 미완성 파일 정리
                } else {
                    state.loadError = "저장 실패: \(error.localizedDescription)"
                }
            }
            state.exportETA = nil
            state.isExporting = false
            state.exportTask = nil
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == AVFoundationErrorDomain
            && nsError.code == AVError.operationCancelled.rawValue
    }

    private static func formatETA(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "약 \(total / 3600)시간 \((total % 3600) / 60)분 남음"
        } else if total >= 60 {
            return "약 \(total / 60)분 \(total % 60)초 남음"
        }
        return "약 \(total)초 남음"
    }

    // MARK: - 편집 프로젝트 저장/불러오기

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let baseName = state.sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = baseName + " 편집.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.makeProjectFile().write(to: url)
        } catch {
            state.loadError = "편집 내용 저장 실패: \(error.localizedDescription)"
        }
    }

    private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onOpenProject(url)
    }

    /// crop이나 모자이크 중 하나라도 있으면 재인코딩 경로(ReencodeExporter)를 타므로
    /// 퍼센트 진행률/취소가 의미 있다. 둘 다 없으면 무손실 스트림 복사라 진행률을 알 수 없다.
    private var usesReencodePath: Bool {
        state.cropAspect != .none || !state.mosaicRegions.isEmpty
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if state.isExporting {
            VStack(spacing: 12) {
                if usesReencodePath {
                    ProgressView(value: state.exportProgress)
                        .frame(width: 240)
                    HStack(spacing: 8) {
                        Text("\(Int(state.exportProgress * 100))%")
                            .font(.system(.body, design: .monospaced))
                        if let eta = state.exportETA, !eta.isEmpty {
                            Text(eta)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                }
                Text(state.exportMessage ?? "저장 중…")
                    .foregroundStyle(.secondary)
                if usesReencodePath {
                    Button("중단", role: .destructive) {
                        state.exportTask?.cancel()
                    }
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
        }
    }

    private func format(_ time: CMTime) -> String {
        guard time.isNumeric else { return "0:00.00" }
        let total = time.seconds
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let hundredths = Int((total - Double(Int(total))) * 100)
        return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
    }
}
