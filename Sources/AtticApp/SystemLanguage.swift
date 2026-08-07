import Foundation

/// **시스템 언어**로 문자열을 찾는다 — 앱의 언어 설정을 무시한다.
///
/// 왜 필요한가: 도커 메뉴는 시스템 UI다. macOS가 자동으로 붙이는 항목(옵션·
/// Finder에서 보기·종료)은 시스템 언어를 쓰는데, 앱이 넣은 항목이 앱의 언어
/// 설정을 따르면 한 메뉴에 두 언어가 섞인다(실제로 그렇게 보였다).
///
/// 앱 안(팝오버·설정 창)은 사용자가 고른 언어를 따르는 것이 맞다. 시스템이
/// 그리는 자리에 우리 항목을 끼워 넣을 때만 이쪽을 쓴다.
enum SystemLanguage {
    /// `L()`이 쓰는 번들과 다르다: 언어 설정은 앱 도메인의 AppleLanguages로
    /// 구현돼 있어 Bundle.main도 그걸 따른다 — 그래서 시스템 도메인을 직접 읽는다.
    private static let bundle: Bundle = {
        // UserDefaults(suiteName: "NSGlobalDomain")은 nil을 준다 — macOS가 "말이
        // 안 되는 suite"라고 로그까지 남긴다(실측). 그러면 Bundle.main으로 떨어져
        // 앱 언어 설정을 따라가고, 결국 시스템 항목과 언어가 어긋난다.
        // 전역 도메인은 CFPreferences로 읽어야 한다.
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
