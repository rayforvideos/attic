import Foundation

/// 사용자가 고른 언어로 문구를 조회한다. 기기 언어를 따를 때는 nil이고 그때는
/// `Bundle.main`이 시스템 판단대로 조회한다.
///
/// 번들을 갈아끼우는 이유는 재시작을 요구하지 않기 위해서다. `AppleLanguages`만
/// 바꾸면 다음 실행부터 적용된다.
///
/// 키는 한국어 원문이다. 번역이 없으면 키가 그대로 나오므로 누락이 크래시가 되지
/// 않는다. 영어는 `en.lproj/Localizable.strings`가 채운다.
public enum LanguageOverride {
    /// 읽기가 압도적으로 많고 쓰기는 언어를 고를 때 한 번이라 락 없이 두되,
    /// 쓰기는 반드시 메인 스레드에서 한다.
    nonisolated(unsafe) private static var bundle: Bundle?

    /// nil이면 기기 언어를 따른다.
    @MainActor public static func set(languageCode: String?) {
        guard let languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else {
            bundle = nil
            return
        }
        bundle = localized
    }

    static var current: Bundle { bundle ?? .main }
}

public func L(_ key: String) -> String {
    LanguageOverride.current.localizedString(forKey: key, value: nil, table: nil)
}

/// 값이 끼어드는 문구. 언어마다 값의 위치가 달라 보간으로 조립한 문장은 번역할 수
/// 없으므로 키에 `%@`·`%lld` 자리표시자를 쓴다. `String(format:)`에 locale을 넘기면
/// 언어 오버라이드가 무시되므로 넘기지 않는다.
public func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: LanguageOverride.current.localizedString(forKey: key, value: nil, table: nil),
           arguments: arguments)
}
