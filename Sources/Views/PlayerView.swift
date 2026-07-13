import AVKit
import SwiftUI

/// HDR/EDR 재생을 위해 AVPlayerView 사용. 컨트롤은 자체 UI로 대체하므로 숨김.
/// EditorView가 이 뷰의 frame을 원본 화면비 기준 videoRect로 잘라서 넘겨준다. 다만 crop이
/// 활성화되면 실제로 재생되는 컨텐츠 자체가 이미 crop 비율로 렌더링되어(renderSize가
/// pixelCrop 크기) videoRect(원본 비율)와 화면비가 달라질 수 있다 — .resize(꽉 채우기)를 쓰면
/// 그 경우 영상이 눌리거나 늘어나 보이므로, 항상 .resizeAspect로 비율을 지켜 letterbox한다.
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
