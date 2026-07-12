import SwiftUI

@main
struct ClipCropApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)   // 검은 영상 배경 위에서 툴바 텍스트가 흰색으로 보이도록
        }
        .windowResizability(.contentSize)
        .commands {
            // 기본 Edit 메뉴의 Undo(⌘Z)가 툴바 되돌리기 버튼과 충돌하지 않도록 제거
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}
