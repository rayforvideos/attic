import Foundation

/// **시스템 언어**로 문구를 찾는다 — 앱의 언어 설정을 따르지 않는다.
///
/// 왜 이런 것이 필요한가: 도커 우클릭 메뉴에는 두 주인의 항목이 함께 있다.
/// 우리가 넣는 항목과, macOS Dock이 자동으로 붙이는 항목(옵션·Finder에서
/// 보기·종료)이다. **뒤쪽은 Dock 프로세스가 그리므로 항상 시스템 언어이고 앱이
/// 바꿀 수 없다.** 그래서 앱 언어 설정(예: 영어)이 시스템 언어(한국어)와 다르면
/// 한 메뉴에 두 언어가 섞인다 — 사용자가 두 번 지적한 문제다.
///
/// 손댈 수 있는 쪽은 우리 항목뿐이므로, 그쪽을 시스템 언어에 맞춘다. 앱 안
/// (팝오버·설정 창)은 그대로 사용자가 고른 언어를 따른다 — 설정의 목적은 앱
/// 화면을 바꾸는 것이고, 시스템이 그리는 메뉴까지 바꾸겠다는 뜻은 아니다.
enum SystemLanguage {
    /// `L()`이 쓰는 번들과 다르다: 언어 설정은 앱 도메인의 `AppleLanguages`로
    /// 구현돼 있어 `Bundle.main`도 그걸 따른다 — 그래서 전역 도메인을 직접 읽는다.
    private static let bundle: Bundle = {
        // UserDefaults(suiteName: "NSGlobalDomain")은 nil을 준다 — macOS가 "말이
        // 안 되는 suite"라고 로그까지 남긴다(실측). 그러면 Bundle.main으로 떨어져
        // 앱 언어를 따라가고, 고치려던 문제가 그대로 남는다.
        let preferred = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let available = Bundle.main.localizations
        for language in preferred {
            let code = String(language.prefix(2))
            guard let match = available.first(where: { $0.hasPrefix(code) }),
                  let path = Bundle.main.path(forResource: match, ofType: "lproj"),
                  let found = Bundle(path: path) else { continue }
            return found
        }
        return .main
    }()

    /// 번역이 없으면 키(= 한국어 원문)를 그대로 돌려준다.
    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
