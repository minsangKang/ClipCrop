import Foundation

/// 번들에 박힌 앱 버전. 기능이 추가되면 project.yml의 CFBundleShortVersionString에서
/// 마이너 버전을 올린다 (Info.plist는 xcodegen이 project.yml을 보고 다시 만든다).
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}
