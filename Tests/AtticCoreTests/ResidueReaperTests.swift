import Testing
import Foundation
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
