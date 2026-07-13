import SwiftUI

/// 자유 크기 모자이크 블록 오버레이. 여러 개를 동시에 표시하고, 탭으로 선택,
/// 드래그로 이동, 코너 핸들로 리사이즈(비율 고정 없음)한다. 선택된 블록에는 삭제 배지가 뜬다.
/// 좌표계는 CropOverlayView와 동일 — 영상 표시 영역 기준 정규화(0~1), 좌상단 원점.
struct MosaicOverlayView: View {
    @ObservedObject var state: EditState
    let videoRect: CGRect

    @State private var dragStartRect: CGRect?

    private let handleSize: CGFloat = 12
    private let minSidePoints: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.mosaicRegions) { region in
                let rect = viewRect(from: region.rect)
                let isSelected = state.selectedMosaicID == region.id
                regionShape(region, rect: rect, isSelected: isSelected)
                if isSelected {
                    deleteBadge(region: region, rect: rect)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(at: corner, region: region, rect: rect)
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - 블록 본체

    private func regionShape(_ region: MosaicRegion, rect: CGRect, isSelected: Bool) -> some View {
        let radius = region.cornerRadius * min(rect.width, rect.height) / 2
        return RoundedRectangle(cornerRadius: radius)
            .fill(Color.yellow.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isSelected ? Color.yellow : Color.yellow.opacity(0.55),
                                 style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1,
                                                    dash: isSelected ? [] : [4, 3]))
            )
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { state.selectedMosaicID = region.id })
            .gesture(moveGesture(for: region))
    }

    private func deleteBadge(region: MosaicRegion, rect: CGRect) -> some View {
        Button {
            state.removeMosaicRegion(id: region.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .position(x: rect.maxX, y: rect.minY)
        .help("이 모자이크 블록 삭제")
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

    private func update(_ id: UUID, _ transform: (inout MosaicRegion) -> Void) {
        guard let index = state.mosaicRegions.firstIndex(where: { $0.id == id }) else { return }
        transform(&state.mosaicRegions[index])
    }

    // MARK: - 이동

    private func moveGesture(for region: MosaicRegion) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                state.selectedMosaicID = region.id
                if dragStartRect == nil { dragStartRect = viewRect(from: region.rect) }
                guard let start = dragStartRect else { return }
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.minX, videoRect.minX), videoRect.maxX - moved.width)
                moved.origin.y = min(max(moved.minY, videoRect.minY), videoRect.maxY - moved.height)
                update(region.id) { $0.rect = normalizedRect(from: moved) }
            }
            .onEnded { _ in dragStartRect = nil }
    }

    // MARK: - 코너 핸들 (자유 리사이즈, 비율 고정 없음)

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func anchorPoint(for corner: Corner, in rect: CGRect) -> CGPoint {
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

    private func handle(at corner: Corner, region: MosaicRegion, rect: CGRect) -> some View {
        let pos = handlePosition(for: corner, in: rect)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .frame(width: handleSize, height: handleSize)
            .position(pos)
            .gesture(resizeGesture(corner: corner, region: region))
    }

    private func resizeGesture(corner: Corner, region: MosaicRegion) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = viewRect(from: region.rect) }
                guard let start = dragStartRect else { return }
                let anchor = anchorPoint(for: corner, in: start)
                let dragged = value.location

                var minX = max(min(anchor.x, dragged.x), videoRect.minX)
                var maxX = min(max(anchor.x, dragged.x), videoRect.maxX)
                var minY = max(min(anchor.y, dragged.y), videoRect.minY)
                var maxY = min(max(anchor.y, dragged.y), videoRect.maxY)
                if maxX - minX < minSidePoints {
                    if dragged.x < anchor.x { minX = maxX - minSidePoints } else { maxX = minX + minSidePoints }
                }
                if maxY - minY < minSidePoints {
                    if dragged.y < anchor.y { minY = maxY - minSidePoints } else { maxY = minY + minSidePoints }
                }
                let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                update(region.id) { $0.rect = normalizedRect(from: rect) }
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
