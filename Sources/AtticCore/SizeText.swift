import Foundation

/// 바이트를 사람이 읽는 크기로. Core에 두는 이유는 테스트다 — 1MB 미만을
/// 문자 그대로 `"0"`으로 내보내던 버그가 눈으로 볼 때까지 남아 있었다.
public enum SizeText {
    /// 목록·문장에 넣는 짧은 표기.
    ///
    /// **0을 내보내지 않는다.** 예전에는 1MB 미만이면 "0"을 돌려줬는데, 이 앱은
    /// 크기를 정직하게 말하는 것이 전부인 도구다. 수백 KB짜리 스크린샷이 목록에
    /// "0"으로 뜨면 값을 못 재서 0인지, 정말 빈 파일인지 구별할 수 없다.
    public static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 1 { return String(format: "%.1fGB", gb) }
        let mb = Double(bytes) / Double(1 << 20)
        if mb >= 1 { return String(format: "%.0fMB", mb) }
        let kb = Double(bytes) / Double(1 << 10)
        if kb >= 1 { return String(format: "%.0fKB", kb) }
        return "\(bytes)B"
    }

    /// 히어로 숫자용 — 값과 단위를 따로 준다(단위는 작게 깔아 둔다).
    public static func split(_ bytes: UInt64) -> (value: String, unit: String) {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 1 { return (String(format: "%.1f", gb), "GB") }
        let mb = Double(bytes) / Double(1 << 20)
        if mb >= 1 { return (String(format: "%.0f", mb), "MB") }
        let kb = Double(bytes) / Double(1 << 10)
        if kb >= 1 { return (String(format: "%.0f", kb), "KB") }
        return ("\(bytes)", "B")
    }
}
