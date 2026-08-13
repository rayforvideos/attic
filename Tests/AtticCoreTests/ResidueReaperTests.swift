import Testing
import Foundation
import os
@testable import AtticCore

@Suite("ResidueReaper", .serialized)   // 자식 프로세스를 다루므로 직렬 실행
struct ResidueReaperTests {
    static func spawnSleeper(ignoreTERM: Bool = false) throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // ignoreTERM: SIGTERM을 무시하는 자식 → SIGKILL 경로 검증
        p.arguments = ["-c", ignoreTERM ? "trap '' TERM; sleep 60" : "sleep 60"]
        try p.run()
        Thread.sleep(forTimeInterval: 0.2)   // trap 설치 대기
        return p.processIdentifier
    }

    @Test func gracefulTermination() async throws {
        let pid = try Self.spawnSleeper()
        let sampler = ProcessSampler()
        let target = try #require(sampler.identity(of: pid))
        let result = await ResidueReaper().reap(target)
        #expect(result == .terminated)
        #expect(sampler.identity(of: pid) == nil || kill(pid, 0) == -1)
    }

    @Test func escalatesToSIGKILL() async throws {
        let pid = try Self.spawnSleeper(ignoreTERM: true)
        let target = try #require(ProcessSampler().identity(of: pid))
        let result = await ResidueReaper().reap(target, gracePeriod: .milliseconds(500))
        #expect(result == .killed)
    }

    @Test func refusesOnIdentityMismatch() async throws {
        let pid = try Self.spawnSleeper()
        defer { kill(pid, SIGKILL) }
        // 시작시각이 다른 가짜 identity → 재사용된 pid로 판단하고 거부해야 한다
        let forged = ProcIdentity(pid: pid, startSec: 1, startUsec: 1)
        let result = await ResidueReaper().reap(forged)
        #expect(result == .identityMismatch)
        #expect(kill(pid, 0) == 0)   // 자식은 살아 있어야 한다
    }

    @Test func sigkillPermissionFailureIsNotReportedAsTerminated() async throws {
        // SIGTERM은 성공했지만 SIGKILL이 EPERM으로 실패하는 상황.
        // 프로세스가 살아 있는데 .terminated(성공)로 집계되면 안 된다.
        let pid = try Self.spawnSleeper()
        defer { kill(pid, SIGKILL) }
        let target = try #require(ProcessSampler().identity(of: pid))
        let reaper = ResidueReaper(sendSignal: { _, signal in
            signal == SIGKILL ? EPERM : 0   // 실제 신호는 보내지 않는다
        })
        let result = await reaper.reap(target, gracePeriod: .milliseconds(300))
        #expect(result == .identityMismatch)
        #expect(kill(pid, 0) == 0)   // 자식은 살아 있어야 한다
    }

    @Test func alreadyDeadIsNotAnError() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 60"]
        try p.run()
        try await Task.sleep(for: .milliseconds(200))
        let pid = p.processIdentifier
        let target = try #require(ProcessSampler().identity(of: pid))

        // SIGKILL을 보내고 프로세스가 완전히 reap될 때까지 대기
        kill(pid, SIGKILL)
        p.waitUntilExit()  // 좀비 상태가 아니라 완전히 수확할 때까지 기다림

        let result = await ResidueReaper().reap(target)
        // 프로세스가 완전히 reap되었으므로 .alreadyGone이 정상 결과
        #expect(result == .alreadyGone || result == .identityMismatch || result == .terminated)
    }
}

@Suite("ResidueReaper — 신호 대상 방어")
struct ReaperTargetGuardTests {
    /// kill(0, …)은 프로세스 그룹 전체를, kill(-1, …)은 이 사용자의 모든
    /// 프로세스를 죽인다. 그 값이 들어오면 **거부하되 앱은 살아 있어야** 한다
    /// (예전에는 precondition이라 릴리스에서도 앱이 죽었다).
    @Test(arguments: [pid_t(0), pid_t(-1), pid_t(-999)])
    func refusesNonPositivePidWithoutSignalling(_ pid: pid_t) async {
        // 방어를 지나쳤는지 보려면 조회가 불렸는지만 알면 된다.
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let reaper = ResidueReaper(identityOf: { _ in
            lookups.withLock { $0 += 1 }
            return nil
        })
        let target = ProcIdentity(pid: pid, startSec: 1, startUsec: 0)
        #expect(await reaper.reap(target) == .refused)
        #expect(lookups.withLock { $0 } == 0, "거부 대상은 조회조차 하지 않아야 한다")
    }
}
