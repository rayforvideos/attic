import Foundation

/// 실행 경로를 **가장 바깥 .app 번들**로 접는다. 헬퍼 프로세스(Chrome Helper,
/// Electron Framework)가 앱 안쪽 경로로 뜨기 때문에, "이게 어느 앱인가"를
/// 판정할 때 이 접기가 필요하다.
///
/// 앱별 메모리 합산(AppGroup)은 성능 진단용이라 걷어냈다 — 지금 이 함수를 쓰는
/// 곳은 잔여 프로세스 판정에서 조상이 IDE 번들인지 보는 부분뿐이다.
public enum AppGrouper {
    public static func outermostBundlePath(of execPath: String) -> String? {
        guard let range = execPath.range(of: #"^.*?/[^/]+\.app"#,
                                         options: .regularExpression) else { return nil }
        return String(execPath[range])
    }
}
