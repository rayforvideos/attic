import Foundation

/// 실행 경로를 가장 바깥 .app 번들로 접는다. 헬퍼 프로세스(Chrome Helper,
/// Electron Framework)는 앱 안쪽 경로로 뜨므로 어느 앱인지 판정하려면 이 접기가
/// 필요하다.
public enum AppGrouper {
    public static func outermostBundlePath(of execPath: String) -> String? {
        guard let range = execPath.range(of: #"^.*?/[^/]+\.app"#,
                                         options: .regularExpression) else { return nil }
        return String(execPath[range])
    }
}
