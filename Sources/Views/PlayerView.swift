import AVKit
import SwiftUI

/// HDR/EDR 재생을 위해 AVPlayerView 사용. 컨트롤은 자체 UI로 대체하므로 숨김.
/// EditorView가 이 뷰의 frame을 원본 화면비 기준 videoRect로 잘라서 넘겨준다. 미리보기는
/// crop을 적용하지 않고 항상 전체 프레임을 렌더링하므로 컨텐츠 비율이 videoRect와 같고,
/// .resizeAspect에서 letterbox 없이 프레임을 꽉 채운다 — 그래야 crop 오버레이의 흰 박스가
/// 실제 영상 픽셀과 1:1로 맞는다.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsMagnification = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
