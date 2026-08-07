import Darwin
import Foundation

public enum ReapResult: Sendable, Equatable {
    case terminated        // SIGTERM으로 종료됨
    case killed            // SIGKILL까지 감
    case alreadyGone       // 시그널 전에 이미 죽어 있었음
    case identityMismatch  // pid 재사용 감지 — 아무것도 하지 않음
}

public struct ResidueReaper: Sendable {
    let identityOf: @Sendable (pid_t) -> ProcIdentity?

    public init(identityOf: @escaping @Sendable (pid_t) -> ProcIdentity? =
                { ProcessSampler().identity(of: $0) }) {
        self.identityOf = identityOf
    }

    public func reap(_ target: ProcIdentity,
                     gracePeriod: Duration = .seconds(3)) async -> ReapResult {
        precondition(target.pid > 0, "kill(0)/kill(-1) 방어")

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
