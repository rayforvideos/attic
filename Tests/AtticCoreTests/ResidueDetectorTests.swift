import Testing
import Foundation
@testable import AtticCore

@Suite("ResidueDetector")
struct ResidueDetectorTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func context(
        ancestry: [pid_t: AncestorInfo] = [:],
        protectedPaths: [String] = [],
        previousCPUTimes: [ProcIdentity: UInt64] = [:],
        mtime: Date? = nil
    ) -> DetectionContext {
        DetectionContext(now: now, ancestry: ancestry,
                         protectedPaths: protectedPaths,
                         previousCPUTimes: previousCPUTimes,
                         previousObservedAt: now.addingTimeInterval(-1800),
                         projectMTime: { _ in mtime },
                         ideBundleNames: ["IntelliJ IDEA", "Xcode", "Code"])
    }

    /// 18시간 된 vite dev 서버 — 설계 §8의 실제 사례
    static func staleVite(pid: pid_t = 500, ppid: pid_t = 1,
                          cwd: String = "/Users/ray/workspace/arch-test-app") -> ProcessSample {
        .fixture(pid: pid, ppid: ppid,
                 startSec: UInt64(now.timeIntervalSince1970) - 18 * 3600,
                 execPath: "/usr/local/bin/node",
                 argv: ["node", "/p/node_modules/.bin/vite"],
                 cwd: cwd, listeningPorts: [5199])
    }

    @Test func detectsDevServerWithAllSignals() throws {
        let vite = Self.staleVite()
        let ctx = Self.context(
            previousCPUTimes: [vite.identity: vite.cpuTimeNanos],  // CPU 증가 0 → 유휴
            mtime: Self.now.addingTimeInterval(-3 * 86_400))       // 프로젝트 3일 방치
        let groups = ResidueDetector(context: ctx).detect([vite])
        let g = try #require(groups.first)
        #expect(g.projectPath == "/Users/ray/workspace/arch-test-app")
        #expect(g.candidates[0].signals.contains(.orphaned))       // ppid == 1
        #expect(g.candidates[0].signals.contains(.holdsPorts([5199])))
        #expect(g.candidates[0].signals.contains(where: {
            if case .longLived(let h) = $0 { return h > 17 } ; return false
        }))
        #expect(g.candidates[0].signals.contains(where: {
            if case .cpuIdle = $0 { return true } ; return false
        }))
        #expect(g.candidates[0].signals.contains(where: {
            if case .staleProject(let d) = $0 { return d >= 3 } ; return false
        }))
    }

    @Test func groupsByCwd() {
        let a1 = Self.staleVite(pid: 500, cwd: "/proj/a")
        let a2 = Self.staleVite(pid: 501, cwd: "/proj/a")
        let b = Self.staleVite(pid: 502, cwd: "/proj/b")
        let groups = ResidueDetector(context: Self.context()).detect([a1, a2, b])
        #expect(groups.count == 2)
        #expect(groups.first { $0.projectPath == "/proj/a" }?.candidates.count == 2)
    }

    @Test func detectsDuplicateMCPServers() throws {
        // 동일 실행 경로·인자 조합 2개 이상 → 중복 신호
        let m1 = ProcessSample.fixture(pid: 600,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            execPath: "/usr/local/bin/node",
            argv: ["node", "/x/mcp-server.js"], cwd: "/proj/mc")
        let m2 = ProcessSample.fixture(pid: 601,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            execPath: "/usr/local/bin/node",
            argv: ["node", "/x/mcp-server.js"], cwd: "/proj/mc")
        let groups = ResidueDetector(context: Self.context()).detect([m1, m2])
        let g = try #require(groups.first)
        #expect(g.candidates.allSatisfy { $0.signals.contains(.duplicate(count: 2)) })
    }

    @Test func protectsIDEChildProcesses() {
        // ppid 체인이 IntelliJ에 닿으면 절대 대상이 아니다 (설계 §7 보호 규칙)
        let idea = ProcessSample.fixture(pid: 700, ppid: 1,
            execPath: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea",
            argv: ["idea"], cwd: nil)
        let langServer = Self.staleVite(pid: 701, ppid: 700,
                                        cwd: "/Users/ray/workspace/forceteller-event-vue")
        let ctx = Self.context(ancestry: [700: AncestorInfo(ppid: 1, execPath: idea.execPath)])
        let groups = ResidueDetector(context: ctx).detect([idea, langServer])
        #expect(groups.isEmpty)
    }

    @Test func hardExclusions() {
        let systemProc = ProcessSample.fixture(pid: 800,
            execPath: "/System/Library/CoreServices/x", argv: ["x"])
        let protected = Self.staleVite(pid: 801, cwd: "/proj/keep")
        let notADevTool = ProcessSample.fixture(pid: 802,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 100 * 3600,
            execPath: "/opt/homebrew/bin/fish", argv: ["fish"],
            cwd: "/Users/ray")
        let ctx = Self.context(protectedPaths: ["/proj/keep"])
        let groups = ResidueDetector(context: ctx).detect([systemProc, protected, notADevTool])
        #expect(groups.isEmpty)   // /System/ 제외, 보호 경로 제외, 대상 패턴 아님 제외
    }

    @Test func freshDevServerProducesNoGroup() {
        // 방금 띄운 vite (30분): 부모가 살아있고(ppid != 1, 조상 체인 완전) 포트도
        // 열지 않아 근거(signal)가 전혀 없다. §10: 근거 없는 프로세스는 정리 제안에
        // 올리지 않으므로, 후보 자체가 걸러지고 cwd에 대한 그룹도 생기지 않아야 한다.
        let fresh = ProcessSample.fixture(pid: 900, ppid: 300,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 1800,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/fresh")
        let ctx = Self.context(ancestry: [300: AncestorInfo(ppid: 1, execPath: "/bin/zsh")])
        let groups = ResidueDetector(context: ctx).detect([fresh])
        #expect(groups.isEmpty)
    }

    @Test func groupExcludesZeroSignalSiblingButKeepsEvidencedOne() throws {
        // 같은 cwd에 근거 있는(18시간 stale) 프로세스와 근거 없는(방금 뜬, 부모 생존)
        // 프로세스가 섞여 있으면, 그룹은 근거 있는 후보만 담아야 한다 — 그룹 단위로
        // 통째로 제외/포함하면 근거 없는 형제가 묻어간다(§10).
        let stale = Self.staleVite(pid: 500, cwd: "/proj/mixed")
        // argv를 stale과 다르게 둔다: 같으면 duplicate 신호가 붙어 "근거 0개" 전제가 깨진다
        let fresh = ProcessSample.fixture(pid: 900, ppid: 300,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 1800,
            argv: ["node", "/other/node_modules/.bin/vite"],
            cwd: "/proj/mixed")
        let ctx = Self.context(ancestry: [300: AncestorInfo(ppid: 1, execPath: "/bin/zsh")])
        let groups = ResidueDetector(context: ctx).detect([stale, fresh])
        let g = try #require(groups.first { $0.projectPath == "/proj/mixed" })
        #expect(g.candidates.count == 1)
        #expect(g.candidates[0].sample.pid == 500)
    }

    @Test func noGroupWhenAllCandidatesInCwdHaveZeroSignals() {
        // cwd 안의 모든 후보가 근거 0개면, 그 cwd에 대한 그룹 자체가 없어야 한다.
        // 두 후보의 argv를 서로 다르게 둔다: 동일하면 duplicate 신호가 생겨 전제가 깨진다
        let fresh1 = ProcessSample.fixture(pid: 900, ppid: 300,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 1800,
            argv: ["node", "/a/node_modules/.bin/vite"],
            cwd: "/proj/allfresh")
        let fresh2 = ProcessSample.fixture(pid: 901, ppid: 300,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 1800,
            argv: ["node", "/b/node_modules/.bin/vitest"],
            cwd: "/proj/allfresh")
        let ctx = Self.context(ancestry: [300: AncestorInfo(ppid: 1, execPath: "/bin/zsh")])
        let groups = ResidueDetector(context: ctx).detect([fresh1, fresh2])
        #expect(groups.isEmpty)
    }

    @Test func sortingAndScoreHoldWithZeroSignalFilterInPlace() throws {
        // 3-signal 그룹이 1-signal 그룹보다 위에 와야 하며, 필터링이 점수/정렬
        // 로직 자체를 깨뜨리지 않아야 한다.
        // longLived + orphaned(ppid 1) + holdsPorts = 3
        let threeSignal = Self.staleVite(pid: 500, cwd: "/proj/three")
        // longLived만 = 1 (부모 생존 → orphaned 없음, 포트 없음, argv가 달라 duplicate 없음)
        let oneSignalStrong = ProcessSample.fixture(pid: 501, ppid: 2,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 18 * 3600,
            execPath: "/usr/local/bin/node",
            argv: ["node", "/other/node_modules/.bin/vite"],
            cwd: "/proj/one", listeningPorts: [])
        let ctx = Self.context(
            ancestry: [2: AncestorInfo(ppid: 1, execPath: "/bin/zsh")])
        let groups = ResidueDetector(context: ctx).detect([threeSignal, oneSignalStrong])
        #expect(groups.count == 2)
        #expect(groups[0].projectPath == "/proj/three")
        #expect(groups[0].score == 3)
        #expect(groups[1].projectPath == "/proj/one")
        #expect(groups[1].score == 1)
    }

    @Test func excludesProcessWhenAncestorMissingFromSamples() {
        // Fix 1: Incomplete chain data must not feed kill decisions.
        // Child process ppid points to ancestor not in ancestry → excluded (fail-closed).
        let child = ProcessSample.fixture(pid: 1000, ppid: 999,  // 999 not in ancestry
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/orphan")
        let ctx = Self.context()  // empty ancestry — 999 absent
        let groups = ResidueDetector(context: ctx).detect([child])
        #expect(groups.isEmpty)  // Child excluded due to incomplete ppid chain
    }

    @Test func excludesOwnProcess() {
        // Fix 2a: Sample whose pid matches ownPid (injected) is excluded.
        let own = ProcessSample.fixture(pid: 2000,
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/self")
        let ctx = DetectionContext(now: Self.now, ancestry: [:], protectedPaths: [],
                                   previousCPUTimes: [:], previousObservedAt: nil,
                                   projectMTime: { _ in nil },
                                   ideBundleNames: [],
                                   ownPid: 2000, ownUid: 501)
        let groups = ResidueDetector(context: ctx).detect([own])
        #expect(groups.isEmpty)
    }

    @Test func excludesDifferentUid() {
        // Fix 2b: Sample whose uid != ownUid (injected) is excluded.
        let other = ProcessSample.fixture(pid: 2001, uid: 502,  // uid != ownUid
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/other")
        let ctx = DetectionContext(now: Self.now, ancestry: [:], protectedPaths: [],
                                   previousCPUTimes: [:], previousObservedAt: nil,
                                   projectMTime: { _ in nil },
                                   ideBundleNames: [],
                                   ownPid: 1, ownUid: 501)
        let groups = ResidueDetector(context: ctx).detect([other])
        #expect(groups.isEmpty)
    }

    @Test func wordBoundaryMatchesViteCorrectly() {
        // Fix 3a: "vite" matches in "/node_modules/.bin/vite" (. / are boundaries).
        let proc = ProcessSample.fixture(
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/test")
        let groups = ResidueDetector(context: Self.context()).detect([proc])
        #expect(groups.count == 1)  // Should be detected as target
    }

    @Test func wordBoundaryRejectsMcparthu() {
        // Fix 3b: "mcp" does NOT match in "mcparthur-tool" (word boundary prevents false positive).
        let proc = ProcessSample.fixture(
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["mcparthur-tool", "arg1"],
            cwd: "/proj/test")
        let groups = ResidueDetector(context: Self.context()).detect([proc])
        #expect(groups.isEmpty)  // Should NOT be detected as target
    }

    @Test func wordBoundaryRejectsNextDevelopment() {
        // Fix 3c: "next dev" does NOT match in "next development-server" (word boundary).
        let proc = ProcessSample.fixture(
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["next", "development-server"],
            cwd: "/proj/test")
        let groups = ResidueDetector(context: Self.context()).detect([proc])
        #expect(groups.isEmpty)  // Should NOT be detected as target
    }

    @Test func wordBoundaryMatchesMcpServer() {
        // Fix 3d: "mcp" matches in "node /x/mcp-server.js" (- is a boundary).
        let proc = ProcessSample.fixture(
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/x/mcp-server.js"],
            cwd: "/proj/test")
        let groups = ResidueDetector(context: Self.context()).detect([proc])
        #expect(groups.count == 1)  // Should be detected as target
    }

    // MARK: - Live defect regression (root-owned ancestor structurally absent from `samples`)

    @Test func regressionTerminalDescendantThroughRootLoginIsNotExcluded() {
        // Reproduces the live-verified bug: ProcessSampler.sample() is same-uid only,
        // so an interactive terminal session's ppid chain — which descends through
        // root-owned /usr/bin/login — always hit the old fail-closed rule and got
        // excluded, even though the *ancestor itself* is legitimately queryable via
        // proc_bsdshortinfo/proc_pidpath (NO_CHECK_SAME_USER). Modelled after the
        // live trace: child → zsh → login(uid 0) → launchd(pid 1).
        let zshPid: pid_t = 28482
        let loginPid: pid_t = 91115
        let child = Self.staleVite(pid: 9000, ppid: zshPid, cwd: "/Users/ray/workspace/proj")
        let ancestry: [pid_t: AncestorInfo] = [
            zshPid: AncestorInfo(ppid: loginPid, execPath: "/bin/zsh"),
            loginPid: AncestorInfo(ppid: 1, execPath: "/usr/bin/login"),
        ]
        // Note: neither zsh nor login appear in `samples` — only the target child does,
        // exactly as ProcessSampler.sample() (same-uid only) would report them.
        let ctx = Self.context(ancestry: ancestry)
        let groups = ResidueDetector(context: ctx).detect([child])
        #expect(!groups.isEmpty)  // Must NOT be excluded — this is the fix under test
    }

    @Test func ideProtectionHoldsViaAncestryEvenWhenIdeAbsentFromSamples() {
        // The IDE-child protection rule must still work when resolved purely through
        // `ancestry`, without the IDE process itself appearing in `samples` (mirrors
        // how a real scan would see a same-uid IDE not fed into `detect()`'s input).
        let ideaPid: pid_t = 700
        let child = Self.staleVite(pid: 701, ppid: ideaPid, cwd: "/Users/ray/workspace/proj")
        let ancestry: [pid_t: AncestorInfo] = [
            ideaPid: AncestorInfo(ppid: 1,
                                  execPath: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
        ]
        let ctx = Self.context(ancestry: ancestry)
        let groups = ResidueDetector(context: ctx).detect([child])
        #expect(groups.isEmpty)
    }

    @Test func failClosedStillHoldsWhenAncestorTrulyAbsentFromAncestry() {
        // With the complete ancestry map, a missing entry now only means the pid
        // genuinely doesn't exist (e.g. vanished between snapshot and lookup) —
        // fail-closed must still apply in that case.
        let child = ProcessSample.fixture(pid: 1002, ppid: 55555,  // not in ancestry at all
            startSec: UInt64(Self.now.timeIntervalSince1970) - 5 * 3600,
            argv: ["node", "/p/node_modules/.bin/vite"],
            cwd: "/proj/vanished")
        let ctx = Self.context()  // empty ancestry
        let groups = ResidueDetector(context: ctx).detect([child])
        #expect(groups.isEmpty)
    }
}

@Suite("ProcessSampler.ancestrySnapshot — live integration")
struct ProcessSamplerAncestryLiveTests {
    @Test func coversProcessesOutsideOwnUid() {
        // Proves other-uid coverage: proc_bsdshortinfo/proc_pidpath are
        // NO_CHECK_SAME_USER, so ancestrySnapshot() must see pids that
        // same-uid-only sample() cannot.
        let sampler = ProcessSampler()
        let ancestry = sampler.ancestrySnapshot()
        let sameUidPids = Set(sampler.sample().map(\.pid))
        #expect(ancestry.keys.contains { !sameUidPids.contains($0) })
    }

    @Test func ownProcessChainReachesPid1WithoutGaps() {
        // Walking the ppid chain from our own pid through ancestry must reach
        // pid 1 (launchd) with no missing hop — the structural guarantee the
        // fail-closed rule in ResidueDetector now depends on.
        let sampler = ProcessSampler()
        let ancestry = sampler.ancestrySnapshot()
        var cursor = getpid()
        var hops = 0
        while cursor > 1, hops < 64 {
            guard let ancestor = ancestry[cursor] else {
                Issue.record("gap in live ancestry chain at pid \(cursor)")
                return
            }
            cursor = ancestor.ppid
            hops += 1
        }
        #expect(cursor == 1)
    }
}

@Suite("보호 경로 매칭")
struct ProtectedPathMatchingTests {
    /// `hasPrefix`만 쓰면 형제 디렉토리까지 보호되고, 틸드가 확장되지 않으면
    /// 아무것도 보호하지 못한다.
    @Test func anchorsOnComponentsAndExpandsTilde() {
        #expect(ResidueDetector.isUnder("/Users/ray/work/app", root: "/Users/ray/work"))
        #expect(ResidueDetector.isUnder("/Users/ray/work", root: "/Users/ray/work"))
        #expect(!ResidueDetector.isUnder("/Users/ray/work-other/app", root: "/Users/ray/work"))
        #expect(ResidueDetector.isUnder("/Users/ray/WORK/app", root: "/Users/ray/work"))
        let home = NSHomeDirectory()
        #expect(ResidueDetector.isUnder("\(home)/work/app", root: "~/work"))
        #expect(!ResidueDetector.isUnder("/Users/ray/work", root: ""))
    }
}
