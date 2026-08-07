import Testing
import Foundation
@testable import AtticCore

@Suite("DiskAlertJudge")
struct DiskAlertJudgeTests {
    let gb = UInt64(1 << 30)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstDropBelowThresholdAlerts() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb)
        let fired = judge.shouldAlert(freeBytes: 19 * gb, at: t0)
        #expect(fired)
    }

    @Test func stayingBelowThresholdStaysSilent() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb)
        let first = judge.shouldAlert(freeBytes: 19 * gb, at: t0)
        // 5분 뒤에도 여전히 부족 — 다시 알리면 스팸이다
        let second = judge.shouldAlert(freeBytes: 18 * gb, at: t0.addingTimeInterval(300))
        let third = judge.shouldAlert(freeBytes: 10 * gb, at: t0.addingTimeInterval(600))
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test func aboveThresholdNeverAlerts() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb)
        let a = judge.shouldAlert(freeBytes: 21 * gb, at: t0)
        let b = judge.shouldAlert(freeBytes: 200 * gb, at: t0)
        #expect(!a)
        #expect(!b)
    }

    /// 히스테리시스: 임계치를 살짝 넘었다가 다시 떨어지는 진동에는 반응하지 않고,
    /// 확실히 회복(임계치+5GB)한 뒤 다시 떨어져야 새 사건으로 친다.
    @Test func realertsOnlyAfterRecoveryBeyondHysteresis() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb)
        let first = judge.shouldAlert(freeBytes: 19 * gb, at: t0)
        #expect(first)

        // 임계치 바로 위로 찔끔 회복 → 다시 하락: 같은 사건, 무음
        _ = judge.shouldAlert(freeBytes: 21 * gb, at: t0.addingTimeInterval(60))
        let afterWobble = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(120))
        #expect(!afterWobble)

        // 25GB(임계치+5GB) 이상으로 확실히 회복 → 다시 하락: 새 사건, 알림
        _ = judge.shouldAlert(freeBytes: 26 * gb, at: t0.addingTimeInterval(180))
        let afterRecovery = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(240))
        #expect(afterRecovery)
    }

    @Test func realertsAfterTwentyFourHours() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb)
        let first = judge.shouldAlert(freeBytes: 19 * gb, at: t0)
        let at23h = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(23 * 3600))
        let at25h = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(25 * 3600))
        #expect(first)
        #expect(!at23h)
        #expect(at25h)
    }
}

@Suite("DiskAlertJudge 영속 상태")
struct DiskAlertJudgePersistenceTests {
    let gb = UInt64(1 << 30)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// 앱 재시작·임계치 변경으로 judge를 새로 만들 때 마지막 알림 시각을 이월해야
    /// 한다 — 안 그러면 켤 때마다 즉시 또 알려 24시간 규칙이 무효가 된다.
    @Test func carriedLastAlertKeepsQuiet() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb, lastAlertAt: t0)
        let soon = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(600))
        #expect(!soon)
        var later = DiskAlertJudge(thresholdBytes: 20 * gb, lastAlertAt: t0)
        let nextDay = later.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(25 * 3600))
        #expect(nextDay)
    }

    /// 시계가 되돌아가도 영구 침묵에 빠지지 않는다.
    @Test func clockGoingBackwardsDoesNotSilenceForever() {
        var judge = DiskAlertJudge(thresholdBytes: 20 * gb, lastAlertAt: t0)
        let backwards = judge.shouldAlert(freeBytes: 19 * gb, at: t0.addingTimeInterval(-7200))
        #expect(backwards)
    }
}
