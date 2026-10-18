import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var editState: EditState?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let editState {
                EditorView(state: editState,
                           onClose: { self.editState = nil },
                           onOpenProject: { openProject($0) })
                .id(ObjectIdentifier(editState))
            } else {
                openPrompt
            }
        }
    }

    private var openPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("영상을 여기에 드래그하거나")
                .font(.title3)
            Button("영상 열기…") { openVideoPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("편집 프로젝트 불러오기…") { openProjectImportPanel() }
            Text("ClipCrop \(AppInfo.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func openProjectImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    private func open(_ url: URL) {
        // 열기 패널/드롭이 주는 URL은 security-scoped일 수 있음 (샌드박스 off라 no-op에 가깝지만 안전하게)
        _ = url.startAccessingSecurityScopedResource()
        let state = EditState(url: url)
        editState = state
        Task { await state.load() }
    }

    /// 편집 프로젝트(JSON) 열기: 원본 영상을 로드한 뒤 저장된 편집 내용을 적용
    private func openProject(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        do {
            let project = try ProjectFile.read(from: url)
            let sourceURL = URL(fileURLWithPath: project.sourcePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                showError("원본 영상을 찾을 수 없습니다:\n\(project.sourcePath)")
                return
            }
            let state = EditState(url: sourceURL)
            editState = state
            Task {
                await state.load()
                if state.isLoaded { state.apply(project: project) }
            }
        } catch {
            showError("프로젝트 파일을 읽을 수 없습니다: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "불러오기 실패"
        alert.informativeText = message
        alert.runModal()
    }
}
