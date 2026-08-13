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
    /// 신호를 보내고 성공이면 0, 실패면 errno를 돌려준다. 테스트에서 kill 실패를
    /// 재현할 수 있도록 주입 가능하게 둔다.
    let sendSignal: @Sendable (pid_t, Int32) -> Int32

    public init(identityOf: @escaping @Sendable (pid_t) -> ProcIdentity? =
                { ProcessSampler().identity(of: $0) },
                sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 =
                { kill($0, $1) == 0 ? 0 : errno }) {
        self.identityOf = identityOf
        self.sendSignal = sendSignal
    }

    public func reap(_ target: ProcIdentity,
                     gracePeriod: Duration = .seconds(3)) async -> ReapResult {
        // kill(0, …)은 프로세스 그룹 전체를, kill(-1, …)은 이 사용자의 모든 프로세스를
        // 죽인다. 공개 API라 크래시 대신 거부로 막는다.
        guard target.pid > 0 else { return .refused }

        // 1) SIGTERM 직전 재검증
        guard let current = identityOf(target.pid) else { return .alreadyGone }
        guard current == target else { return .identityMismatch }

        // 2) SIGTERM
        let termError = sendSignal(target.pid, SIGTERM)
        if termError != 0 {
            return termError == ESRCH ? .alreadyGone : .identityMismatch  // EPERM = 재사용
        }

        // 3) grace period 동안 100ms 간격 생존 확인
        let deadline = ContinuousClock.now + gracePeriod
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                guard identityOf(target.pid) == target else { return .terminated }
                let killError = sendSignal(target.pid, SIGKILL)
                if killError != 0 {
                    return killError == ESRCH ? .terminated : .identityMismatch  // EPERM = 재사용
                }
                return .killed
            }
            if !isAlive(target.pid) { return .terminated }
        }

        // 4) SIGKILL 직전 재검증. grace period 사이의 pid 재사용을 막는다.
        guard identityOf(target.pid) == target else { return .terminated }
        let killError = sendSignal(target.pid, SIGKILL)
        if killError != 0 {
            return killError == ESRCH ? .terminated : .identityMismatch  // EPERM = 재사용
        }
        return .killed
    }

    func isAlive(_ pid: pid_t) -> Bool {
        // kill(pid, 0)은 좀비에도 성공하므로 상태를 따로 확인한다.
        if kill(pid, 0) != 0 {
            return false
        }

        guard let bsd = ProcessSampler.bsdInfo(pid) else {
            // proc_pidinfo가 EPERM이면 프로세스는 존재한다.
            return errno == EPERM
        }

        if bsd.pbi_status == SZOMB { return false }

        return true
    }
}
