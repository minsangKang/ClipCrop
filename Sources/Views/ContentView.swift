import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var editState: EditState?
    @State private var showImporter = false
    @State private var showProjectImporter = false
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
            Button("영상 열기…") { showImporter = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("편집 프로젝트 불러오기…") { showProjectImporter = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
            if case .success(let url) = result { open(url) }
        }
        .fileImporter(isPresented: $showProjectImporter,
                      allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { openProject(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func open(_ url: URL) {
        // fileImporter가 주는 URL은 security-scoped일 수 있음 (샌드박스 off라 no-op에 가깝지만 안전하게)
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
