import SwiftUI
import AppKit
import AtticCore
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "app")

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

        // Window(id:)가 아니라 Settings scene을 쓴다. SwiftUI의 openWindow는 뷰
        // 안에서만 부를 수 있어서, 도커 메뉴(AppKit)에서 열 길이 없었다 —
        // 팝오버를 한 번도 열지 않았으면 설정이 아예 열리지 않았다(사용자 신고).
        // Settings scene은 표준 액션(showSettingsWindow:)이 있어 어디서든 열린다.
        Settings {
            SettingsView().environment(model)
                .environment(\.locale, model.languageCode.map(Locale.init(identifier:))
                             ?? Locale.autoupdatingCurrent)
        }
    }
}

/// 실행 직후 샘플링을 시작한다 — 메뉴바를 클릭하지 않아도 측정과 알림이 돌아야 한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 저장된 언어 선택을 조회 경로에 먼저 반영한다 — 안 하면 저장은
            // 됐는데 모델·코어 문구만 시스템 언어로 나오는 어긋남이 생긴다.
            AppLanguage.restoreOnLaunch()
            Self.applyDockVisibility()
            DiagnosticsModel.shared.startSampling()
            // 실행할 때는 간격과 무관하게 확인한다. 팝오버 열 때만 확인하면
            // 릴리스 직전에 확인이 돌았을 때 다음 확인까지 오래 기다린다.
            DiagnosticsModel.shared.checkForUpdateNow()
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

    /// 도커에 아이콘을 보일지. 기본은 숨김(메뉴바 전용 앱이다).
    ///
    /// 왜 설정이 필요한가: `LSUIElement` 앱을 도커에 **고정**해도 그 아이콘은
    /// 실행 아이콘일 뿐이라, 실행 중에도 도커에 떠 있는 앱이 아니어서 macOS가
    /// 우클릭 메뉴에 종료를 넣어주지 않는다(사용자 신고). 도커 메뉴를 쓰려면
    /// 도커에 표시되는 앱이 되어야 한다 — 그건 취향이라 사용자가 고르게 한다.
    static let showInDockKey = "showInDock"

    @MainActor static func applyDockVisibility() {
        let show = UserDefaults.standard.bool(forKey: showInDockKey)
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    /// 도커 아이콘 우클릭 메뉴 — 도커에 표시하는 설정을 켰을 때만 나타난다.
    ///
    /// 문구는 **시스템 언어**로 만든다(SystemLanguage). 이 메뉴의 절반은 macOS
    /// Dock이 그리고 항상 시스템 언어라, 우리 항목만 앱 언어를 따르면 한 메뉴에
    /// 두 언어가 섞인다 — 손댈 수 있는 쪽을 맞추는 것이 유일한 해결이다.
    ///
    /// 종료는 넣지 않는다: macOS가 이미 붙여준다. 직접 넣으면 두 개가 된다.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(SystemLanguage.text("설정…"), #selector(openSettingsFromDock)),
                                (SystemLanguage.text("찾아보기"), #selector(scanFromDock))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openSettingsFromDock() {
        MainActor.assumeIsolated { AppDelegate.openSettings() }
    }

    /// 설정 창을 연다.
    ///
    /// `sendAction(..., to: nil)`은 도커 메뉴에서 동작하지 않았다(사용자 확인) —
    /// responder 체인에 받는 곳이 없다. 앱 메뉴에 있는 항목은 눌리면 확실히
    /// 열리므로(확인함), **그 항목의 target/action을 그대로 실행한다**.
    @MainActor static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)   // 없으면 창이 다른 앱 뒤에 뜬다
        let selector = Selector(("showSettingsWindow:"))
        if let item = NSApp.mainMenu?.items.compactMap(\.submenu)
            .flatMap(\.items).first(where: { $0.action == selector }) {
            let handled = NSApp.sendAction(selector, to: item.target, from: item)
            logger.info("dock settings via menu item, handled=\(handled, privacy: .public)")
            if handled { return }
        }
        let handled = NSApp.sendAction(selector, to: nil, from: nil)
        logger.info("dock settings via responder chain, handled=\(handled, privacy: .public)")
    }

    @objc private func scanFromDock() {
        MainActor.assumeIsolated {
            Self.openMenuBarPopover()
            Task { await DiagnosticsModel.shared.scanSpace() }
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
