import AppKit
import Foundation
import AtticCore

/// 앱 화면의 언어. macOS의 앱별 언어 설정(시스템 설정 → 일반 → 언어 및 지역)은
/// 깊숙히 숨어 있고, 시스템은 한국어로 쓰면서 이 앱만 영어로 보고 싶은 경우가
/// 있어 설정에 직접 둔다.
///
/// 방식: 앱 도메인의 `AppleLanguages`를 쓴다(실측 2026-08-06: `defaults write`로
/// 같은 키를 넣었을 때 화면이 영어로 바뀌는 것을 확인했다). **다음 실행부터**
/// 적용되므로 바꾼 뒤 다시 시작해야 한다 — 번역 테이블은 프로세스 시작 시 한 번
/// 정해지고, 이미 그려진 화면을 바꿔치기하는 우회는 취약하다.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// 기기 언어를 그대로 따른다(기본).
    case system
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    /// 설정 화면에 보일 이름. 각 언어를 **그 언어로** 적는다 — 영어만 아는
    /// 사람이 한국어 화면에서도 "English"를 찾을 수 있어야 한다.
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

    /// 고른 언어를 저장하고 **즉시** 적용한다. `.system`은 키를 지워 기기 설정으로
    /// 되돌린다. 저장은 다음 실행을 위한 것이고, 지금 화면은 LanguageOverride가 바꾼다.
    @MainActor static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
        LanguageOverride.set(languageCode: language == .system ? nil : language.rawValue)
    }

    /// 화면(SwiftUI Text·LocalizedStringKey)이 조회할 로케일. 기기 언어를 따를
    /// 때는 시스템 판단을 그대로 쓴다.
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// 앱 시작 시 저장된 선택을 조회 경로에 반영한다 — 저장은 됐는데 화면은
    /// 시스템 언어로 뜨는 어긋남을 막는다.
    @MainActor static func restoreOnLaunch() {
        let saved = current
        LanguageOverride.set(languageCode: saved == .system ? nil : saved.rawValue)
    }
}
