import Foundation

/// 화면과 모델이 같은 값을 읽어야 하는 설정. 두 곳에서 각자 기본값을 적으면
/// 어긋난다 — 실제로 어긋났다: 화면의 최소 선택지는 1GB인데 스캐너 기본값은
/// 300MB여서, 코드가 의도한 기준을 사용자가 고를 수 없었다.
public enum UserSettings {
    /// 큰 파일로 볼 최소 크기(MB). 흔한 동영상·발표자료가 300~800MB라서
    /// 1GB를 기본으로 두면 일반 사용자에게는 아무것도 걸리지 않는다.
    public static let defaultLargeFileMB = 500

    public static var largeFileMB: Int {
        let defaults = UserDefaults.standard
        if let mb = defaults.object(forKey: "largeFileMB") as? Int { return mb }
        // 옛 설정(GB 단위)을 쓰던 사용자의 선택을 잃지 않는다.
        if let gb = defaults.object(forKey: "largeFileGB") as? Int { return gb * 1024 }
        return defaultLargeFileMB
    }
}
