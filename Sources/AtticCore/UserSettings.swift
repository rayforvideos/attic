import Foundation

/// 화면과 모델이 같은 값을 읽어야 하는 설정. 두 곳에서 각자 기본값을 적으면 화면의
/// 선택지와 스캐너 기준이 조용히 어긋난다.
public enum UserSettings {
    /// 큰 파일로 볼 최소 크기(MB). 흔한 동영상·발표자료가 300~800MB라 1GB를 기본으로
    /// 두면 일반 사용자에게는 아무것도 걸리지 않는다.
    public static let defaultLargeFileMB = 500

    public static var largeFileMB: Int {
        let defaults = UserDefaults.standard
        if let mb = defaults.object(forKey: "largeFileMB") as? Int { return mb }
        // GB 단위로 저장하던 옛 설정도 읽어 사용자의 선택을 잃지 않는다.
        if let gb = defaults.object(forKey: "largeFileGB") as? Int { return gb * 1024 }
        return defaultLargeFileMB
    }
}
