import Darwin
import Foundation

public enum ReapResult: Sendable, Equatable {
    case terminated        // SIGTERM으로 종료됨
    case killed            // SIGKILL까지 감
    case alreadyGone       // 시그널 전에 이미 죽어 있었음
    case identityMismatch  // pid 재사용 감지 — 아무것도 하지 않음
    /// 신호를 보낼 수 없는 대상(pid <= 0). 거부하고 아무것도 하지 않는다.
    case refused
}

public struct ResidueReaper: Sendable {
    let identityOf: @Sendable (pid_t) -> ProcIdentity?

    public init(identityOf: @escaping @Sendable (pid_t) -> ProcIdentity? =
                { ProcessSampler().identity(of: $0) }) {
        self.identityOf = identityOf
    }

    public func reap(_ target: ProcIdentity,
                     gracePeriod: Duration = .seconds(3)) async -> ReapResult {
        // kill(0, …)은 프로세스 그룹 전체를, kill(-1, …)은 이 사용자의 모든
        // 프로세스를 죽인다 — 절대 통과시키면 안 되는 값이다.
        //
        // 예전에는 precondition이었는데, 그건 릴리스에서도 **앱을 죽인다**.
        // 지금은 allPids()가 pid > 0을 이미 거르지만, reap()은 공개 API라
        // 다른 호출자가 생기면 방어가 크래시가 된다. 거부하고 살아 있는 편이
        // 언제나 낫다 — 안전 성질은 그대로 지켜진다.
        guard target.pid > 0 else { return .refused }

        // 1) SIGTERM 직전 재검증
        guard let current = identityOf(target.pid) else { return .alreadyGone }
        guard current == target else { return .identityMismatch }

        // 2) SIGTERM
        if kill(target.pid, SIGTERM) != 0 {
            return errno == ESRCH ? .alreadyGone : .identityMismatch  // EPERM = 재사용
        }

        // 3) grace period 동안 100ms 간격 생존 확인 (cancellation 처리)
        let deadline = ContinuousClock.now + gracePeriod
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Task 취소됨 → 즉시 검증 후 SIGKILL 시도
                guard identityOf(target.pid) == target else { return .terminated }
                if kill(target.pid, SIGKILL) != 0 {
                    return errno == ESRCH ? .terminated : .terminated
                }
                return .killed
            }
            if !isAlive(target.pid) { return .terminated }
        }

        // 4) SIGKILL 직전 재재검증 (3초 사이 pid 재사용 방어)
        guard identityOf(target.pid) == target else { return .terminated }
        if kill(target.pid, SIGKILL) != 0 {
            return errno == ESRCH ? .terminated : .terminated
        }
        return .killed
    }

    func isAlive(_ pid: pid_t) -> Bool {
        // kill(pid, 0)은 좀비도 참을 반환하므로, 좀비 여부를 명시적으로 확인
        if kill(pid, 0) != 0 {
            return false  // ESRCH: 프로세스 없음
        }

        // 프로세스가 존재함 (kill 성공 또는 EPERM)
        // 좀비 여부 확인: pbi_status == SZOMB면 죽음 (단, exit 미수확)
        guard let bsd = ProcessSampler.bsdInfo(pid) else {
            // proc_pidinfo 실패 = ESRCH (프로세스 없음) 또는 권한 문제
            // EPERM인 경우 프로세스는 존재하므로 alive 취급
            return errno == EPERM
        }

        // 좀비 상태 = 죽음으로 취급
        if bsd.pbi_status == SZOMB { return false }

        // 정상 프로세스 또는 다른 상태
        return true
    }
}
