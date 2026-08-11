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
                // Text(LocalizedStringKey)는 environment의 locale로 조회하므로,
                // 고른 언어를 꽂아야 재시작 없이 화면이 바뀐다.
                .environment(\.locale, model.languageCode.map(Locale.init(identifier:))
                             ?? Locale.autoupdatingCurrent)
        } label: {
            // 라벨은 순수 Image여야 한다. .task 같은 수정자를 붙이면 합성 뷰가 되어
            // 시스템이 비트맵으로 래스터화하고, 템플릿 틴팅을 잃어 라이트 모드
            // 메뉴바에서 아이콘이 흰색으로 사라진다.
            Image(systemName: model.menuBarSymbolName)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        // Window(id:)가 아니라 Settings scene을 쓴다. openWindow는 뷰 안에서만
        // 부를 수 있어 도커 메뉴(AppKit)에서 열 길이 없지만, Settings scene은
        // 표준 액션(showSettingsWindow:)이 있어 어디서든 열린다.
        Settings {
            SettingsView().environment(model)
                .environment(\.locale, model.languageCode.map(Locale.init(identifier:))
                             ?? Locale.autoupdatingCurrent)
        }
    }
}

/// 실행 직후 샘플링을 시작한다. 메뉴바를 클릭하지 않아도 측정과 알림이 돌아야 한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 저장된 언어를 조회 경로에 먼저 반영해야 모델·코어 문구가
            // 시스템 언어로 어긋나지 않는다.
            AppLanguage.restoreOnLaunch()
            Self.applyDockVisibility()
            DiagnosticsModel.shared.startSampling()
            DiagnosticsModel.shared.checkForUpdateNow()
            // 메뉴바 전용 앱이라 첫 실행에 안내가 없으면 실행된 줄도 모른다.
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
    /// `LSUIElement` 앱은 도커에 고정해도 실행 중인 앱으로 취급되지 않아
    /// macOS가 우클릭 메뉴에 종료를 넣어주지 않는다. 도커 메뉴를 쓰려면
    /// 도커에 표시되는 앱이 되어야 한다.
    static let showInDockKey = "showInDock"

    @MainActor static func applyDockVisibility() {
        let show = UserDefaults.standard.bool(forKey: showInDockKey)
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    /// 도커 아이콘 우클릭 메뉴.
    ///
    /// 문구는 시스템 언어로 만든다. 이 메뉴의 나머지 절반은 Dock이 그리고 항상
    /// 시스템 언어라, 우리 항목만 앱 언어를 따르면 두 언어가 섞인다.
    /// 종료는 macOS가 이미 붙여주므로 넣지 않는다.
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
    /// 도커 메뉴에서는 responder 체인에 받는 곳이 없어 `sendAction(..., to: nil)`이
    /// 동작하지 않는다. 앱 메뉴 항목의 target/action을 찾아 그대로 실행한다.
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


    /// 이미 실행 중인 앱을 Finder·Launchpad에서 다시 열면 아무 일도 안 일어나
    /// 고장처럼 보인다. 재열기 신호를 받아 팝오버를 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard !DiagnosticsModel.shared.isPopoverOpen else { return }
            Self.openMenuBarPopover()
        }
        return false
    }

    /// MenuBarExtra는 팝오버를 여는 공개 API가 없어, 상태 항목의 버튼을 찾아
    /// 클릭을 재생한다.
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
