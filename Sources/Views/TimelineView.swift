import AppKit
import CoreMedia
import SwiftUI

/// 남은 세그먼트들을 비례 폭의 블록으로 표시하는 타임라인.
/// 클릭: 해당 위치로 시크 + 세그먼트 선택. 드래그: 스크럽.
/// 선택된 구간의 양 끝을 드래그하면 잘려 나간 원본까지 늘이거나 줄일 수 있다(트림).
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
        guard zoom > 1, !isScrubbing, trimDrag == nil, viewportWidth > 0 else { return }
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

    private func track(contentWidth: CGFloat, total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            segmentBlocks(width: contentWidth, total: total)
            playhead(width: contentWidth, total: total)
        }
        .frame(width: contentWidth, height: barHeight, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard total > 0, trimDrag == nil else { return }
                    isScrubbing = true
                    let fraction = min(max(value.location.x / contentWidth, 0), 1)
                    let t = CMTime(seconds: fraction * total, preferredTimescale: 600)
                    state.seek(toCompositionTime: t)
                    if let seg = state.segment(atCompositionTime: t) {
                        state.selectedSegmentID = seg.id
                    }
                }
                .onEnded { _ in isScrubbing = false }
        )
    }

    private func segmentBlocks(width: CGFloat, total: Double) -> some View {
        HStack(spacing: gap) {
            ForEach(state.segments) { seg in
                let fraction = total > 0 ? seg.sourceRange.duration.seconds / total : 0
                let isSelected = state.selectedSegmentID == seg.id
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.6),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                    .frame(width: max(4, width * fraction - gap))
                    .overlay(alignment: .leading) {
                        if isSelected { trimHandle(for: seg, edge: .start) }
                    }
                    .overlay(alignment: .trailing) {
                        if isSelected { trimHandle(for: seg, edge: .end) }
                    }
            }
        }
        .frame(height: barHeight)
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
