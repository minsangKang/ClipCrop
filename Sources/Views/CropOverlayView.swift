import SwiftUI

/// 비율 고정 crop 사각형 오버레이. 내부 드래그로 이동, 코너 핸들로 크기 조절.
/// state.cropRect는 영상 표시 영역 기준 정규화(0~1) 좌표.
struct CropOverlayView: View {
    @ObservedObject var state: EditState
    let videoRect: CGRect
    /// 미리보기가 crop 영역만 꽉 채워 보여주는 상태인지. 이때는 바깥에 덮을 영상이 없어
    /// 딤 처리를 끄고, 드래그는 "박스를 옮기는" 게 아니라 "영상을 미는" 방향으로 뒤집는다.
    var fillsPreview = false

    @State private var dragStartRect: CGRect?
    /// 드래그 시작 시점의 videoRect. crop을 옮기면 미리보기도 같이 확대·이동하므로,
    /// 그때그때의 videoRect로 좌표를 환산하면 기준이 흔들려 사각형이 폭주한다.
    @State private var dragStartVideoRect: CGRect?

    private let handleSize: CGFloat = 14
    private let minSidePoints: CGFloat = 48

    var body: some View {
        let rect = viewRect(from: state.cropRect)
        ZStack(alignment: .topLeading) {
            if !fillsPreview { dimOutside(cropRect: rect) }
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.clear)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .gesture(moveGesture)
            ForEach(Corner.allCases, id: \.self) { corner in
                handle(at: corner, cropRect: rect)
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - 좌표 변환

    /// 드래그 중에는 시작 시점의 프레임으로 고정해서 환산한다.
    private var frame: CGRect { dragStartVideoRect ?? videoRect }

    private func viewRect(from normalized: CGRect) -> CGRect {
        CGRect(x: frame.minX + normalized.minX * frame.width,
               y: frame.minY + normalized.minY * frame.height,
               width: normalized.width * frame.width,
               height: normalized.height * frame.height)
    }

    private func normalizedRect(from view: CGRect) -> CGRect {
        CGRect(x: (view.minX - frame.minX) / frame.width,
               y: (view.minY - frame.minY) / frame.height,
               width: view.width / frame.width,
               height: view.height / frame.height)
    }

    private func beginDragIfNeeded() {
        guard dragStartRect == nil else { return }
        dragStartVideoRect = videoRect
        dragStartRect = viewRect(from: state.cropRect)
    }

    private func endDrag() {
        dragStartRect = nil
        dragStartVideoRect = nil
    }

    // MARK: - 이동

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginDragIfNeeded()
                guard let start = dragStartRect else { return }
                // crop 영역만 보일 땐 잡고 있는 게 박스가 아니라 영상이라, 손가락을 따라
                // 영상이 움직이도록 crop 박스는 반대로 옮긴다.
                let sign: CGFloat = fillsPreview ? -1 : 1
                var moved = start.offsetBy(dx: sign * value.translation.width,
                                           dy: sign * value.translation.height)
                moved.origin.x = min(max(moved.minX, frame.minX), frame.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, frame.minY), frame.maxY - moved.height)
                state.cropRect = normalizedRect(from: moved)
                state.syncCropVerticalPosition()
            }
            .onEnded { _ in endDrag() }
    }

    // MARK: - 코너 핸들

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func anchorPoint(for corner: Corner, in rect: CGRect) -> CGPoint {
        // 드래그하는 코너의 반대편 코너가 고정점
        switch corner {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    private func handlePosition(for corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func handle(at corner: Corner, cropRect: CGRect) -> some View {
        let pos = handlePosition(for: corner, in: cropRect)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .frame(width: handleSize, height: handleSize)
            .position(pos)
            .gesture(resizeGesture(corner: corner))
    }

    private func resizeGesture(corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginDragIfNeeded()
                guard let start = dragStartRect,
                      let ratio = state.cropAspect.ratio else { return }

                let anchor = anchorPoint(for: corner, in: start)
                let dragged = value.location

                // 고정점 기준 사용 가능한 최대 폭/높이 (영상 영역 안으로 제한)
                let maxW = dragged.x > anchor.x ? frame.maxX - anchor.x : anchor.x - frame.minX
                let maxH = dragged.y > anchor.y ? frame.maxY - anchor.y : anchor.y - frame.minY

                // 드래그 거리에서 비율 고정 크기 결정 (폭 기준, 높이 제한 반영)
                var w = min(abs(dragged.x - anchor.x), maxW)
                var h = w / ratio
                if h > maxH { h = maxH; w = h * ratio }
                w = max(w, minSidePoints)
                h = max(h, minSidePoints / ratio)

                let x = dragged.x > anchor.x ? anchor.x : anchor.x - w
                let y = dragged.y > anchor.y ? anchor.y : anchor.y - h
                var rect = CGRect(x: x, y: y, width: w, height: h)
                rect.origin.x = min(max(rect.minX, frame.minX), frame.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, frame.minY), frame.maxY - rect.height)
                state.cropRect = normalizedRect(from: rect)
                state.syncCropVerticalPosition()
            }
            .onEnded { _ in endDrag() }
    }

    // MARK: - 바깥 딤 처리

    private func dimOutside(cropRect: CGRect) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(cropRect)
            context.fill(path, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}
