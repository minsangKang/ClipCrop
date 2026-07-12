import CoreMedia
import SwiftUI

/// 남은 세그먼트들을 비례 폭의 블록으로 표시하는 타임라인.
/// 클릭: 해당 위치로 시크 + 세그먼트 선택. 드래그: 스크럽.
struct TimelineView: View {
    @ObservedObject var state: EditState

    private let barHeight: CGFloat = 56
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = state.totalDuration.seconds
            ZStack(alignment: .topLeading) {
                segmentBlocks(width: width, total: total)
                playhead(width: width, total: total)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard total > 0 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        let t = CMTime(seconds: fraction * total, preferredTimescale: 600)
                        state.seek(toCompositionTime: t)
                        if let seg = state.segment(atCompositionTime: t) {
                            state.selectedSegmentID = seg.id
                        }
                    }
            )
        }
        .frame(height: barHeight)
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
            }
        }
        .frame(height: barHeight)
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
