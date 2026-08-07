import Foundation

/// 사람에게 보여줄 문구를 기기 언어로 옮긴다.
///
/// **키는 한국어 원문이다.** 이 앱은 한국어로 먼저 쓰였고, 의미 기반 키
/// (`cpu.yield.button`)로 바꾸면 코드에서 문구를 읽을 수 없게 된다 — 리뷰할 때
/// 화면에 무엇이 나오는지 코드만 보고 알 수 있는 편이 낫다. 영어는
/// `en.lproj/Localizable.strings`가 채운다. 번역이 없으면 키(한국어)가 그대로
/// 나오므로, 누락이 크래시가 되지 않는다.
///
/// SwiftUI의 `Text("한국어")`는 이 함수를 부르지 않아도 자동으로 같은 테이블을
/// 조회한다(LocalizedStringKey). 이 함수가 필요한 곳은 **모델·코어가 String을
/// 만들어 돌려주는 경로**다 — 그건 SwiftUI가 이미 String으로 받아 번역 기회가 없다.
/// 사용자가 설정에서 고른 언어. 기기 언어를 따를 때는 nil이고, 그때는
/// `Bundle.main`이 시스템 판단대로 조회한다.
///
/// 재시작을 요구하지 않기 위해 존재한다 — `AppleLanguages`만 쓰면 다음 실행부터
/// 적용되는데, 사용자는 고른 즉시 바뀔 것으로 기대한다(실측으로 확인: 설정만
/// 바꾸고 재시작하지 않으면 화면이 그대로다).
public enum LanguageOverride {
    /// 화면 갱신은 앱 쪽 @Observable 상태가 맡고, 이 값은 조회 경로만 바꾼다.
    /// 읽기가 압도적으로 많고 쓰기는 사용자가 언어를 고를 때 한 번이라
    /// 락 없이 두되, 쓰기는 반드시 메인 스레드에서 한다.
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

/// 값이 끼어드는 문구. 키에는 `%@`(문자열)·`%lld`(정수) 같은 자리표시자를 쓴다 —
/// 언어마다 값의 위치가 달라지므로(영어는 "N GB freed", 한국어는 "N GB 비웠어요")
/// 보간으로 조립한 문장은 번역할 수 없다.
public func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: LanguageOverride.current.localizedString(forKey: key, value: nil, table: nil),
           arguments: arguments)
}
