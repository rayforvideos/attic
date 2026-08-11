import AppKit
import Foundation
import AtticCore

/// 앱 화면의 언어. 앱 도메인의 `AppleLanguages`로 구현한다.
///
/// 번들 번역 테이블은 프로세스 시작 시 한 번 정해지므로 이 키는 다음 실행부터
/// 적용된다. 지금 화면은 LanguageOverride가 대신 바꾼다.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// 기기 언어를 그대로 따른다(기본).
    case system
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    /// 설정 화면에 보일 이름. 각 언어를 그 언어로 적어야 영어만 아는 사람이
    /// 한국어 화면에서도 자기 항목을 찾는다.
    var label: String {
        switch self {
        case .system: L("기기 언어 따르기")
        case .korean: "한국어"
        case .english: "English"
        }
    }

    private static let key = "AppleLanguages"

    static var current: AppLanguage {
        guard let stored = UserDefaults.standard.stringArray(forKey: key)?.first else {
            return .system
        }
        return AppLanguage(rawValue: stored) ?? .system
    }

    /// 고른 언어를 저장하고 즉시 적용한다. `.system`은 키를 지워 기기 설정으로 돌아간다.
    @MainActor static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
        LanguageOverride.set(languageCode: language == .system ? nil : language.rawValue)
    }

    /// 화면(Text·LocalizedStringKey)이 조회할 로케일. nil이면 시스템 판단을 따른다.
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// 저장된 선택을 조회 경로에 반영한다. 앱 시작 시 한 번 부른다.
    @MainActor static func restoreOnLaunch() {
        let saved = current
        LanguageOverride.set(languageCode: saved == .system ? nil : saved.rawValue)
    }
}
