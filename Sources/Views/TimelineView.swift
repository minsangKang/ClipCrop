import AppKit
import CoreMedia
import SwiftUI

/// 남은 세그먼트들을 비례 폭의 블록으로 표시하는 타임라인.
/// 클릭: 해당 위치로 시크 + 세그먼트 선택. 드래그: 스크럽.
/// 선택된 구간의 양 끝을 드래그하면 잘려 나간 원본까지 늘이거나 줄일 수 있다(트림).
/// 구간을 꾹 누른 채 드래그하면 순서를 바꿀 수 있다.
/// 확대/축소: 세로 스크롤(위로 = 확대), ⌘= / ⌘-, 슬라이더. ⌘0은 전체 보기. 가로 스크롤은 이동.
struct TimelineView: View {
    @ObservedObject var state: EditState

    private let barHeight: CGFloat = 56
    private let rulerHeight: CGFloat = 18
    private let gap: CGFloat = 2
    /// 최대 확대 시 1초가 차지하는 폭 — 30fps 기준 프레임 하나가 5pt 정도
    private let maxPointsPerSecond: CGFloat = 150

    @State private var zoom: CGFloat = 1
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollOffsetX: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var isScrubbing = false
    @State private var trimDrag: TrimDrag?
    @State private var reorder: ReorderDrag?
    /// 뷰포트 기준 커서 x. 자동 스크롤로 콘텐츠만 움직일 때도 블록이 커서 아래에 머물도록 뷰포트 기준으로 둔다.
    @State private var reorderPointerX: CGFloat = 0
    @State private var pressStart: CGPoint?
    @State private var pressTask: Task<Void, Never>?
    @State private var autoScrollTask: Task<Void, Never>?

    /// 진행 중인 트림 드래그. 드래그 동안은 1초당 폭을 고정해서, 구간이 길어져도
    /// 타임라인 전체가 다시 축소되며 손잡이가 커서에서 도망가지 않게 한다.
    private struct TrimDrag {
        let segmentID: UUID
        let edge: EditState.TrimEdge
        let originalRange: CMTimeRange
        let pointsPerSecond: CGFloat
    }

    var body: some View {
        VStack(spacing: 4) {
            zoomBar
            GeometryReader { geo in
                let viewport = geo.size.width
                let total = state.totalDuration.seconds
                let contentWidth = trimDrag.map { CGFloat(total) * $0.pointsPerSecond } ?? viewport * zoom
                let shift = trimShift
                VStack(spacing: 0) {
                    ruler(viewport: viewport, contentWidth: contentWidth, total: total,
                          offsetX: scrollOffsetX - shift)
                    ScrollView(.horizontal) {
                        track(contentWidth: contentWidth, total: total)
                            .offset(x: shift)
                    }
                    .scrollIndicators(zoom > 1 ? .visible : .hidden)
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                        scrollOffsetX = x
                    }
                }
                .background(
                    VerticalScrollZoomCatcher { factor, anchorX in
                        setZoom(zoom * factor, anchorX: anchorX)
                    }
                )
                .onAppear { viewportWidth = viewport }
                .onChange(of: viewport) { _, new in viewportWidth = new }
            }
            .frame(height: rulerHeight + barHeight + 10)
        }
        .onChange(of: state.currentTime) { _, _ in followPlayhead() }
        .onChange(of: state.totalDuration) { _, _ in
            if trimDrag == nil { setZoom(zoom, anchorX: nil) }
        }
    }

    // MARK: - 확대/축소 컨트롤

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Spacer()
            Button {
                setZoom(zoom / 1.5, anchorX: nil)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1)
            .help("타임라인 축소 (⌘-)")

            Slider(value: Binding(
                get: { log(zoom) },
                set: { setZoom(exp($0), anchorX: nil) }
            ), in: 0...log(maxZoom))
            .frame(width: 140)
            .disabled(maxZoom <= 1)

            Button {
                setZoom(zoom * 1.5, anchorX: nil)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= maxZoom)
            .help("타임라인 확대 (⌘=)")

            Button {
                setZoom(1, anchorX: nil)
            } label: {
                Image(systemName: "arrow.left.and.right.square")
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom <= 1)
            .help("전체 보기 (⌘0)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    /// 영상 길이와 창 폭에 따라 달라지는 최대 배율. 최소 1(전체 보기).
    private var maxZoom: CGFloat {
        let total = state.totalDuration.seconds
        guard total > 0, viewportWidth > 0 else { return 1 }
        return max(1, CGFloat(total) * maxPointsPerSecond / viewportWidth)
    }

    /// 배율을 바꾸면서 anchorX(뷰포트 기준 x) 아래의 시간이 그 자리에 머물도록 스크롤을 맞춘다.
    /// anchorX가 nil이면 재생헤드가 화면에 보일 땐 재생헤드를, 아니면 화면 가운데를 기준으로 한다.
    private func setZoom(_ newValue: CGFloat, anchorX: CGFloat?) {
        let clamped = min(max(newValue, 1), maxZoom)
        guard viewportWidth > 0 else { zoom = clamped; return }

        let oldContent = viewportWidth * zoom
        let anchor = anchorX ?? defaultAnchorX(contentWidth: oldContent)
        let fraction = oldContent > 0 ? (scrollOffsetX + anchor) / oldContent : 0
        let newContent = viewportWidth * clamped
        let newOffset = min(max(fraction * newContent - anchor, 0), max(newContent - viewportWidth, 0))

        zoom = clamped
        // 스크롤 이벤트가 연달아 들어올 때 실제 스크롤 반영을 기다리지 않고 다음 계산에 쓰도록 미리 갱신
        scrollOffsetX = newOffset
        // 콘텐츠 폭이 먼저 반영된 뒤에 스크롤해야 이전 폭 기준으로 잘리지 않는다.
        DispatchQueue.main.async {
            scrollPosition.scrollTo(x: newOffset)
        }
    }

    private func defaultAnchorX(contentWidth: CGFloat) -> CGFloat {
        let total = state.totalDuration.seconds
        guard total > 0 else { return viewportWidth / 2 }
        let playheadX = contentWidth * CGFloat(state.currentTime.seconds / total) - scrollOffsetX
        return (0...viewportWidth).contains(playheadX) ? playheadX : viewportWidth / 2
    }

    /// 재생 중 재생헤드가 화면 밖으로 나가면 한 화면씩 넘겨 따라간다.
    private func followPlayhead() {
        guard zoom > 1, !isScrubbing, trimDrag == nil, reorder == nil, viewportWidth > 0 else { return }
        let total = state.totalDuration.seconds
        guard total > 0 else { return }
        let contentWidth = viewportWidth * zoom
        let playheadX = contentWidth * CGFloat(state.currentTime.seconds / total)
        guard playheadX < scrollOffsetX || playheadX > scrollOffsetX + viewportWidth else { return }
        let target = min(max(playheadX - viewportWidth * 0.1, 0), contentWidth - viewportWidth)
        scrollPosition.scrollTo(x: target)
    }

    // MARK: - 눈금자

    /// 보이는 구간만 그린다 — 크게 확대했을 때 전체 폭의 Canvas를 만들지 않기 위해.
    private func ruler(viewport: CGFloat, contentWidth: CGFloat, total: Double,
                       offsetX: CGFloat) -> some View {
        Canvas { context, size in
            guard total > 0, contentWidth > 0 else { return }
            let pointsPerSecond = contentWidth / CGFloat(total)
            let major = Self.tickInterval(pointsPerSecond: pointsPerSecond)
            let minor = major / 5
            let startTime = Double(offsetX / pointsPerSecond)
            let endTime = Double((offsetX + size.width) / pointsPerSecond)

            var t = (startTime / minor).rounded(.down) * minor
            while t <= min(endTime, total) + minor / 2 {
                let x = CGFloat(t) * pointsPerSecond - offsetX
                let isMajor = abs((t / major).rounded() * major - t) < minor / 2
                let tickHeight: CGFloat = isMajor ? 7 : 3
                context.fill(Path(CGRect(x: x, y: size.height - tickHeight, width: 1, height: tickHeight)),
                             with: .color(.secondary.opacity(isMajor ? 0.8 : 0.4)))
                if isMajor {
                    let label = Text(Self.rulerLabel(t, interval: major))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 0), anchor: .topLeading)
                }
                t += minor
            }
        }
        .frame(width: viewport, height: rulerHeight)
        .allowsHitTesting(false)
    }

    /// 라벨 간격이 80pt 이상 벌어지는 가장 작은 단위를 고른다.
    private static func tickInterval(pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        return candidates.first { CGFloat($0) * pointsPerSecond >= 80 } ?? 3600
    }

    private static func rulerLabel(_ t: Double, interval: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        if interval < 1 {
            return String(format: "%d:%04.1f", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }

    // MARK: - 트랙

    /// 클릭은 시크, 바로 드래그하면 스크럽, 꾹 누르고 있다가 드래그하면 구간 순서 변경.
    /// 길게 누르기를 별도 제스처로 두면 스크럽과 서로 이벤트를 다투므로 하나의 드래그 안에서 구분한다.
    private func track(contentWidth: CGFloat, total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            segmentBlocks(width: contentWidth, total: total)
            playhead(width: contentWidth, total: total)
        }
        .frame(width: contentWidth, height: barHeight, alignment: .leading)
        .contentShape(Rectangle())
        .pointerStyle(reorder != nil ? .grabActive : nil)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard total > 0, trimDrag == nil else { return }
                    if reorder != nil {
                        reorderPointerX = value.location.x - scrollOffsetX
                        updateReorderTarget(width: contentWidth, total: total)
                        return
                    }
                    if pressStart == nil {
                        pressStart = value.location
                        schedulePressLift(at: value.location, width: contentWidth, total: total)
                    } else if let start = pressStart, !isScrubbing,
                              hypot(value.location.x - start.x, value.location.y - start.y) > 4 {
                        // 길게 누르기 전에 움직였으면 스크럽으로 확정
                        pressTask?.cancel()
                        isScrubbing = true
                    }
                    scrub(to: value.location.x, width: contentWidth, total: total)
                }
                .onEnded { _ in
                    pressTask?.cancel()
                    pressStart = nil
                    isScrubbing = false
                    if reorder != nil { dropReorder() }
                }
        )
    }

    private func scrub(to x: CGFloat, width: CGFloat, total: Double) {
        let fraction = min(max(x / width, 0), 1)
        let t = CMTime(seconds: fraction * total, preferredTimescale: 600)
        state.seek(toCompositionTime: t)
        if let seg = state.segment(atCompositionTime: t) {
            state.selectedSegmentID = seg.id
        }
    }

    // MARK: - 구간 순서 변경 (꾹 눌러 드래그)

    /// 들어 올린 구간. 나머지 구간들은 targetIndex 자리에 빈칸을 두고 배치된다.
    private struct ReorderDrag {
        let segmentID: UUID
        /// 잡은 지점과 블록 왼쪽 끝의 거리 — 블록이 커서에 붙어 같이 움직이도록
        let grabOffset: CGFloat
        var targetIndex: Int
    }

    private func schedulePressLift(at location: CGPoint, width: CGFloat, total: Double) {
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, pressStart != nil, !isScrubbing, state.segments.count > 1,
                  let frame = blockFrames(width: width, total: total)
                      .first(where: { location.x >= $0.x && location.x < $0.x + $0.width }),
                  let index = state.segments.firstIndex(where: { $0.id == frame.segment.id }) else { return }
            state.selectedSegmentID = frame.segment.id
            reorderPointerX = location.x - scrollOffsetX
            withAnimation(.spring(duration: 0.25)) {
                reorder = ReorderDrag(segmentID: frame.segment.id,
                                      grabOffset: location.x - frame.x,
                                      targetIndex: index)
            }
            startReorderAutoScroll(width: width, total: total)
        }
    }

    /// 들어 올린 블록의 왼쪽 끝에 가장 가까운 빈칸 자리를 고른다. 나머지 구간만으로 계산한
    /// 경계를 쓰므로, 빈칸이 움직여도 기준이 흔들리지 않아 자리가 왔다 갔다 하지 않는다.
    private func updateReorderTarget(width: CGFloat, total: Double) {
        guard let drag = reorder else { return }
        let pps = width / CGFloat(total)
        let draggedLeft = reorderPointerX + scrollOffsetX - drag.grabOffset
        var boundaries: [CGFloat] = [0]
        for seg in state.segments where seg.id != drag.segmentID {
            boundaries.append(boundaries.last! + CGFloat(seg.sourceRange.duration.seconds) * pps)
        }
        let target = boundaries.indices.min { abs(boundaries[$0] - draggedLeft) < abs(boundaries[$1] - draggedLeft) } ?? 0
        if target != drag.targetIndex {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                reorder?.targetIndex = target
            }
        }
    }

    private func dropReorder() {
        guard let drag = reorder else { return }
        autoScrollTask?.cancel()
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            reorder = nil
            state.moveSegment(id: drag.segmentID, toIndex: drag.targetIndex)
        }
    }

    /// 확대 상태에서 블록을 화면 가장자리로 끌고 가면 그 방향으로 계속 스크롤한다.
    /// 마우스가 멈춰 있으면 드래그 이벤트가 오지 않으므로 별도 루프로 돌린다.
    private func startReorderAutoScroll(width: CGFloat, total: Double) {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled, reorder != nil {
                let edge: CGFloat = 32
                var step: CGFloat = 0
                if reorderPointerX < edge {
                    step = -(edge - reorderPointerX) / 3
                } else if reorderPointerX > viewportWidth - edge {
                    step = (reorderPointerX - (viewportWidth - edge)) / 3
                }
                let maxOffset = max(width - viewportWidth, 0)
                let next = min(max(scrollOffsetX + step, 0), maxOffset)
                if next != scrollOffsetX {
                    scrollOffsetX = next
                    scrollPosition.scrollTo(x: next)
                    updateReorderTarget(width: width, total: total)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: - 구간 블록

    private struct BlockFrame {
        let segment: Segment
        let x: CGFloat
        let width: CGFloat
    }

    /// 각 구간 블록의 위치. 순서 변경 중이면 들어 올린 블록은 커서를 따르고,
    /// 나머지는 targetIndex에 그 블록 폭만큼 빈칸을 두고 줄을 선다.
    private func blockFrames(width: CGFloat, total: Double) -> [BlockFrame] {
        guard total > 0 else { return [] }
        let pps = width / CGFloat(total)
        let widthOf = { (seg: Segment) in CGFloat(seg.sourceRange.duration.seconds) * pps }

        guard let drag = reorder, let dragged = state.segments.first(where: { $0.id == drag.segmentID }) else {
            var x: CGFloat = 0
            return state.segments.map { seg in
                defer { x += widthOf(seg) }
                return BlockFrame(segment: seg, x: x, width: widthOf(seg))
            }
        }

        var frames: [BlockFrame] = []
        var x: CGFloat = 0
        for (i, seg) in state.segments.filter({ $0.id != drag.segmentID }).enumerated() {
            if i == drag.targetIndex { x += widthOf(dragged) }
            frames.append(BlockFrame(segment: seg, x: x, width: widthOf(seg)))
            x += widthOf(seg)
        }
        let draggedX = reorderPointerX + scrollOffsetX - drag.grabOffset
        frames.append(BlockFrame(segment: dragged, x: draggedX, width: widthOf(dragged)))
        return frames
    }

    private func segmentBlocks(width: CGFloat, total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(blockFrames(width: width, total: total), id: \.segment.id) { frame in
                let seg = frame.segment
                let isSelected = state.selectedSegmentID == seg.id
                let isLifted = reorder?.segmentID == seg.id
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.6),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                    .frame(width: max(4, frame.width - gap), height: barHeight)
                    .overlay(alignment: .leading) {
                        if isSelected && reorder == nil { trimHandle(for: seg, edge: .start) }
                    }
                    .overlay(alignment: .trailing) {
                        if isSelected && reorder == nil { trimHandle(for: seg, edge: .end) }
                    }
                    .scaleEffect(isLifted ? 1.04 : 1)
                    .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 8 : 0, y: isLifted ? 3 : 0)
                    .opacity(isLifted ? 0.9 : 1)
                    .animation(.spring(duration: 0.25), value: isLifted)
                    .offset(x: frame.x, y: isLifted ? -3 : 0)
                    // 들어 올린 블록은 커서를 그대로 따라가야 하므로 위치 변화엔 애니메이션을 끈다
                    .transaction { if isLifted { $0.animation = nil } }
                    .zIndex(isLifted ? 1 : 0)
            }
        }
        .frame(width: width, height: barHeight, alignment: .topLeading)
    }

    // MARK: - 트림 손잡이

    /// 시작점을 왼쪽으로 늘이면 구간은 오른쪽으로 자라므로, 그만큼 트랙 전체를 왼쪽으로 밀어서
    /// 잡고 있는 경계가 커서를 따라오게 한다. 놓으면 같은 양만큼 스크롤로 옮겨 화면이 튀지 않는다.
    private var trimShift: CGFloat {
        guard let trimDrag, trimDrag.edge == .start,
              let seg = state.segments.first(where: { $0.id == trimDrag.segmentID }) else { return 0 }
        let added = trimDrag.originalRange.start.seconds - seg.sourceRange.start.seconds
        return -CGFloat(added) * trimDrag.pointsPerSecond
    }

    private func trimHandle(for seg: Segment, edge: EditState.TrimEdge) -> some View {
        let isActive = trimDrag?.segmentID == seg.id && trimDrag?.edge == edge
        return ZStack {
            Color.clear
            Capsule()
                .fill(Color.white.opacity(isActive ? 1 : 0.85))
                .frame(width: 4, height: barHeight * 0.45)
        }
        .frame(width: 12, height: barHeight)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
        .help(edge == .start ? "드래그해서 시작점 조정" : "드래그해서 끝점 조정")
        .gesture(
            // 드래그하는 동안 트랙이 움직이므로 위치가 고정된 전역 좌표로 이동량을 잰다
            // minimumDistance 0으로 눌린 순간부터 손잡이가 이벤트를 가져가서 아래 스크럽이 끼어들지 않게 한다.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if trimDrag == nil {
                        // 클릭만 하고 움직이지 않으면 트림을 시작하지 않는다(미리보기 재구성 방지)
                        guard value.translation.width != 0 else { return }
                        let total = state.totalDuration.seconds
                        guard total > 0, viewportWidth > 0 else { return }
                        trimDrag = TrimDrag(segmentID: seg.id, edge: edge,
                                            originalRange: seg.sourceRange,
                                            pointsPerSecond: viewportWidth * zoom / CGFloat(total))
                        state.beginTrim()
                    }
                    guard let trimDrag else { return }
                    state.trim(segmentID: trimDrag.segmentID, edge: trimDrag.edge,
                               originalRange: trimDrag.originalRange,
                               delta: Double(value.translation.width / trimDrag.pointsPerSecond))
                }
                .onEnded { _ in finishTrim() }
        )
    }

    /// 드래그 동안 고정했던 1초당 폭을 배율로 되돌리고, 트랙을 밀어둔 만큼 스크롤로 옮긴다.
    private func finishTrim() {
        guard let drag = trimDrag else { return }
        let shift = trimShift
        let total = CGFloat(state.totalDuration.seconds)
        trimDrag = nil
        state.endTrim()
        guard viewportWidth > 0, total > 0 else { return }

        let newZoom = min(max(total * drag.pointsPerSecond / viewportWidth, 1), maxZoom)
        let newContent = viewportWidth * newZoom
        let newOffset = min(max(scrollOffsetX - shift, 0), max(newContent - viewportWidth, 0))
        zoom = newZoom
        scrollOffsetX = newOffset
        DispatchQueue.main.async {
            scrollPosition.scrollTo(x: newOffset)
        }
    }

    private func playhead(width: CGFloat, total: Double) -> some View {
        let fraction = total > 0 ? min(max(state.currentTime.seconds / total, 0), 1) : 0
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: barHeight)
            .offset(x: width * fraction - 1)
            .allowsHitTesting(false)
    }
}

/// 타임라인 위에서 들어오는 스크롤 이벤트 중 세로 성분을 가로채 확대/축소로 바꾼다.
/// 트랙패드 제스처는 시작할 때 축을 정해 끝날 때까지 유지하므로, 가로로 시작한 스크롤은
/// 그대로 ScrollView에 넘어가 이동이 되고 중간에 살짝 세로로 흔들려도 확대되지 않는다.
private struct VerticalScrollZoomCatcher: NSViewRepresentable {
    /// factor: 곱할 배율, anchorX: 이 뷰 기준 포인터 x
    let onZoom: (_ factor: CGFloat, _ anchorX: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onZoom = onZoom
    }

    final class CatcherView: NSView {
        private enum Axis { case undecided, vertical, horizontal }

        var onZoom: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?
        /// nil이면 지금 제스처는 타임라인 밖에서 시작된 것
        private var axis: Axis?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // 트랙패드 제스처 시작, 또는 마우스 휠 한 칸(phase 없음)마다 축을 새로 정한다.
            let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if event.phase.contains(.began) || isWheel {
                axis = bounds.contains(point) ? .undecided : nil
            }
            guard var current = axis else { return event }
            if current == .undecided {
                guard dx != 0 || dy != 0 else { return event }
                current = abs(dy) > abs(dx) ? .vertical : .horizontal
                axis = current
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                axis = nil
            }
            guard current == .vertical else { return event }

            // 손가락(휠)을 위로 밀면 확대 — '자연스러운 스크롤' 설정과 무관하게 같은 방향이 되도록 보정
            let physicalDY = event.isDirectionInvertedFromDevice ? -dy : dy
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            onZoom?(exp(physicalDY * sensitivity), point.x)
            return nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
