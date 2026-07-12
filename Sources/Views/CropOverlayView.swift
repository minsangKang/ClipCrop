import SwiftUI

/// 비율 고정 crop 사각형 오버레이. 내부 드래그로 이동, 코너 핸들로 크기 조절.
/// state.cropRect는 영상 표시 영역 기준 정규화(0~1) 좌표.
struct CropOverlayView: View {
    @ObservedObject var state: EditState
    let videoRect: CGRect

    @State private var dragStartRect: CGRect?

    private let handleSize: CGFloat = 14
    private let minSidePoints: CGFloat = 48

    var body: some View {
        let rect = viewRect(from: state.cropRect)
        ZStack(alignment: .topLeading) {
            dimOutside(cropRect: rect)
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

    private func viewRect(from normalized: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + normalized.minX * videoRect.width,
               y: videoRect.minY + normalized.minY * videoRect.height,
               width: normalized.width * videoRect.width,
               height: normalized.height * videoRect.height)
    }

    private func normalizedRect(from view: CGRect) -> CGRect {
        CGRect(x: (view.minX - videoRect.minX) / videoRect.width,
               y: (view.minY - videoRect.minY) / videoRect.height,
               width: view.width / videoRect.width,
               height: view.height / videoRect.height)
    }

    // MARK: - 이동

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = viewRect(from: state.cropRect) }
                guard let start = dragStartRect else { return }
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.minX, videoRect.minX), videoRect.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, videoRect.minY), videoRect.maxY - moved.height)
                state.cropRect = normalizedRect(from: moved)
            }
            .onEnded { _ in dragStartRect = nil }
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
                if dragStartRect == nil { dragStartRect = viewRect(from: state.cropRect) }
                guard let start = dragStartRect,
                      let ratio = state.cropAspect.ratio else { return }

                let anchor = anchorPoint(for: corner, in: start)
                let dragged = value.location

                // 고정점 기준 사용 가능한 최대 폭/높이 (영상 영역 안으로 제한)
                let maxW = dragged.x > anchor.x ? videoRect.maxX - anchor.x : anchor.x - videoRect.minX
                let maxH = dragged.y > anchor.y ? videoRect.maxY - anchor.y : anchor.y - videoRect.minY

                // 드래그 거리에서 비율 고정 크기 결정 (폭 기준, 높이 제한 반영)
                var w = min(abs(dragged.x - anchor.x), maxW)
                var h = w / ratio
                if h > maxH { h = maxH; w = h * ratio }
                w = max(w, minSidePoints)
                h = max(h, minSidePoints / ratio)

                let x = dragged.x > anchor.x ? anchor.x : anchor.x - w
                let y = dragged.y > anchor.y ? anchor.y : anchor.y - h
                var rect = CGRect(x: x, y: y, width: w, height: h)
                rect.origin.x = min(max(rect.minX, videoRect.minX), videoRect.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, videoRect.minY), videoRect.maxY - rect.height)
                state.cropRect = normalizedRect(from: rect)
            }
            .onEnded { _ in dragStartRect = nil }
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
