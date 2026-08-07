import SwiftUI
import AppKit
import AtticCore

@main
struct AtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: DiagnosticsModel { DiagnosticsModel.shared }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                // SwiftUI의 Text(LocalizedStringKey)는 environment의 locale로 조회한다 —
                // 설정에서 고른 언어를 여기 꽂아야 재시작 없이 화면이 바뀐다.
                .environment(\.locale, model.languageCode.map(Locale.init(identifier:))
                             ?? Locale.autoupdatingCurrent)
        } label: {
            // 이 라벨은 **순수 Image여야 한다.** 여기에 .task 같은 수정자를 붙이면
            // 라벨이 Image가 아닌 합성 뷰가 되고, 시스템은 그것을 비트맵으로 래스터화해
            // 템플릿 틴팅을 잃는다. 실측(2026-08-04): 그 상태에서 상태 항목의 불투명 픽셀
            // 311개가 전부 흰색으로 찍혀 라이트 모드 메뉴바에서 아이콘이 보이지 않았다.
            // 그래서 샘플링 시작은 AppDelegate로 옮겼다(팝오버는 지연 생성되므로 거기
            // 붙이면 클릭 전까지 측정이 시작되지 않는다).
            Image(systemName: model.menuBarSymbolName)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        Window("Attic 설정", id: "settings") {
            SettingsView().environment(model)
                .environment(\.locale, model.languageCode.map(Locale.init(identifier:))
                             ?? Locale.autoupdatingCurrent)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// 실행 직후 샘플링을 시작한다 — 메뉴바를 클릭하지 않아도 측정과 알림이 돌아야 한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 저장된 언어 선택을 조회 경로에 먼저 반영한다 — 안 하면 저장은
            // 됐는데 모델·코어 문구만 시스템 언어로 나오는 어긋남이 생긴다.
            AppLanguage.restoreOnLaunch()
            DiagnosticsModel.shared.startSampling()
            // 첫 실행이면 팝오버를 한 번 열어 준다 — 메뉴바 전용 앱이라 아무
            // 안내 없이 작은 아이콘만 생기면 실행된 줄도 모른다(검수에서 확인).
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))   // 메뉴바 아이콘 생성 대기
                    Self.openMenuBarPopover()
                }
            }
        }
    }

    /// Finder·Launchpad에서 이미 실행 중인 앱을 다시 열면 아무 일도 안 일어나
    /// 고장처럼 보인다 — 재열기 신호를 받아 팝오버를 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard !DiagnosticsModel.shared.isPopoverOpen else { return }
            Self.openMenuBarPopover()
        }
        return false
    }

    /// MenuBarExtra는 팝오버를 여는 공개 API가 없다 — 상태 항목의 버튼을 찾아
    /// 클릭을 재생한다(팝오버 캡처 검증에서 동작 확인한 방식).
    @MainActor private static func openMenuBarPopover() {
        for window in NSApp.windows
        where String(describing: type(of: window)).contains("StatusBar") {
            var button: NSButton?
            func walk(_ view: NSView) {
                if let found = view as? NSButton, button == nil { button = found }
                view.subviews.forEach(walk)
            }
            if let contentView = window.contentView { walk(contentView) }
            if let button {
                button.performClick(nil)
                return
            }
        }
    }
}
