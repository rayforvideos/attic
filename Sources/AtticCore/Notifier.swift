import Foundation
import Observation
@preconcurrency import UserNotifications

/// 알림 전달자. 애드혹 서명 빌드는 권한 요청이 프롬프트 없이 즉시 거부되고, 안정
/// 서명이라도 사용자가 알림을 꺼 둘 수 있다. 어느 쪽이든 fallbackActive를 세워 UI가
/// 메뉴바 아이콘 강조로 대체하게 한다.
@MainActor
@Observable
public final class Notifier {
    public private(set) var fallbackActive = false
    public var authorizationFailed: Bool {
        authorized == false
    }
    private var authorized: Bool?
    private let requestAuth: () async -> Bool
    private let deliver: (String, String) -> Void

    public init(
        requestAuth: @escaping () async -> Bool = {
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
        },
        deliver: @escaping (String, String) -> Void = { title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString,
                                      content: content, trigger: nil))
        }
    ) {
        self.requestAuth = requestAuth
        self.deliver = deliver
    }

    public func notify(title: String, body: String) async {
        // 거부 상태는 캐시하지 않는다. 사용자가 나중에 시스템 설정에서 켜면 다음
        // 알림부터 배너로 복귀해야 한다.
        if authorized != true { authorized = await requestAuth() }
        if authorized == true {
            fallbackActive = false
            deliver(title, body)
        } else {
            fallbackActive = true   // UI: 메뉴바 아이콘 심볼 강조 (menuBarSymbolName)
        }
    }
}
