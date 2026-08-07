import Testing
@testable import AtticCore

@Suite("Notifier 폴백")
@MainActor
struct NotifierTests {
    @Test func authorizationFailedIsFalseBeforeAttempt() async {
        let notifier = Notifier(requestAuth: { false }, deliver: { _, _ in })
        #expect(notifier.authorizationFailed == false)
        #expect(notifier.fallbackActive == false)
    }

    @Test func fallsBackWhenAuthorizationFails() async {
        // 권한 요청 함수를 주입해 실패를 시뮬레이션
        let notifier = Notifier(requestAuth: { false }, deliver: { _, _ in })
        await notifier.notify(title: "t", body: "b")
        #expect(notifier.fallbackActive == true)
        #expect(notifier.authorizationFailed == true)
    }

    /// 사용자가 시스템 설정에서 나중에 알림을 켠 경우 — 거부를 캐시해 두면
    /// 앱을 재시작할 때까지 폴백에 갇힌다. 거부 상태면 매번 다시 물어봐야 한다.
    @Test func recoversAfterAuthorizationGrantedLater() async {
        var granted = false
        var delivered: [(String, String)] = []
        let notifier = Notifier(requestAuth: { granted },
                                deliver: { delivered.append(($0, $1)) })
        await notifier.notify(title: "t", body: "b")
        #expect(notifier.fallbackActive == true)

        granted = true   // 사용자가 시스템 설정에서 켰다
        await notifier.notify(title: "t2", body: "b2")
        #expect(delivered.map(\.0) == ["t2"])
        #expect(notifier.fallbackActive == false)
        #expect(notifier.authorizationFailed == false)
    }

    @Test func deliversWhenAuthorized() async {
        var delivered: [(String, String)] = []
        let notifier = Notifier(requestAuth: { true },
                                deliver: { delivered.append(($0, $1)) })
        await notifier.notify(title: "적자 경고", body: "적자가 가용의 30%를 초과")
        #expect(delivered.count == 1)
        #expect(notifier.fallbackActive == false)
        #expect(notifier.authorizationFailed == false)
    }
}
