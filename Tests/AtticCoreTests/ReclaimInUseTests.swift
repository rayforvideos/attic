import Testing
import Foundation
@testable import AtticCore

/// "지금 쓰이는 중"인 후보를 가려내는 판정. 실행 중인 앱의 캐시나 살아 있는
/// 프로세스가 물고 있는 node_modules를 옮기면, 휴지통에서 "사용 중" 경고로
/// 되돌아오고 앱은 열린 핸들로 휴지통 안에 계속 쓴다 — 애초에 후보에서 뺀다.
///
/// 판정은 **누가 쓰는지 이름을 돌려준다** — "사용 중"이라고만 하면 사용자가
/// 무엇을 꺼야 할지 알 수 없다.
@Suite("ReclaimInUse — 실행 중 판정")
struct ReclaimInUseTests {
    let home = "/Users/tester"

    private func judge(apps: [String: String] = [:],
                       bundleIDs: [String: String] = [:],
                       procs: [ReclaimInUse.Proc] = []) -> ReclaimInUse {
        ReclaimInUse(apps: apps, bundleIDs: bundleIDs, procs: procs)
    }

    private func proc(_ name: String, cwd: String? = nil,
                      execPath: String = "") -> ReclaimInUse.Proc {
        ReclaimInUse.Proc(name: name, cwd: cwd, execPath: execPath)
    }

    // MARK: - node_modules

    @Test func nodeModulesCulpritIsProcessWithCwdInsideProject() {
        let j = judge(procs: [proc("node", cwd: "/Users/tester/work/shop/packages/web")])
        #expect(j.culprit(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home) == "node")
    }

    @Test func nodeModulesCulpritIsBinaryRunningFromIt() {
        let j = judge(procs: [proc("vite",
                                   execPath: "/Users/tester/work/shop/node_modules/.bin/vite")])
        #expect(j.culprit(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home) == "vite")
    }

    @Test func nodeModulesFreeWhenNoProcessTouchesProject() {
        let j = judge(procs: [proc("java", cwd: "/Users/tester/work/other",
                                   execPath: "/usr/bin/java")])
        #expect(j.culprit(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home) == nil)
    }

    /// "/Users/tester/work/shop-backup"의 cwd가 "/Users/tester/work/shop"
    /// 프로젝트와 접두어만 겹친다고 사용 중이 되면 안 된다.
    @Test func nodeModulesFreeForSiblingWithSharedPrefix() {
        let j = judge(procs: [proc("node", cwd: "/Users/tester/work/shop-backup")])
        #expect(j.culprit(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home) == nil)
    }

    // MARK: - Electron 캐시

    @Test func electronCacheCulpritIsRunningAppName() {
        let j = judge(apps: ["slack": "Slack"])
        #expect(j.culprit(path: "/Users/tester/Library/Application Support/Slack/Cache",
                          kind: .electronCache, home: home) == "Slack")
    }

    @Test func electronCacheFreeWhenAppQuit() {
        let j = judge(apps: ["notion": "Notion"])
        #expect(j.culprit(path: "/Users/tester/Library/Application Support/Slack/Cache",
                          kind: .electronCache, home: home) == nil)
    }

    // MARK: - 일반 앱 캐시

    @Test func libraryCacheBundleIdCulpritIsAppName() {
        let j = judge(bundleIDs: ["com.tinyspeck.slackmacgap": "Slack"])
        #expect(j.culprit(path: "/Users/tester/Library/Caches/com.tinyspeck.slackmacgap",
                          kind: .libraryCache, home: home) == "Slack")
    }

    @Test func libraryCachePlainNameCulpritIsAppName() {
        let j = judge(apps: ["spotify": "Spotify"])
        #expect(j.culprit(path: "/Users/tester/Library/Caches/Spotify",
                          kind: .libraryCache, home: home) == "Spotify")
    }

    @Test func containersCacheCulpritIsAppName() {
        let j = judge(bundleIDs: ["com.kakao.kakaotalkmac": "KakaoTalk"])
        #expect(j.culprit(
            path: "/Users/tester/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Caches",
            kind: .libraryCache, home: home) == "KakaoTalk")
    }

    @Test func libraryCacheFreeWhenNothingMatches() {
        let j = judge(apps: ["finder": "Finder"], bundleIDs: ["com.apple.finder": "Finder"])
        #expect(j.culprit(path: "/Users/tester/Library/Caches/Spotify",
                          kind: .libraryCache, home: home) == nil)
    }

    /// 실행 중 여부를 보지 않는 종류(빌드 캐시 등)는 항상 자유다 —
    /// 이 판정이 다른 종류로 번지면 스캔 결과가 통째로 사라질 수 있다.
    @Test func otherKindsAreNeverInUse() {
        let j = judge(apps: ["xcode": "Xcode"],
                      procs: [proc("Xcode", cwd: "/Users/tester",
                                   execPath: "/Applications/Xcode.app/Contents/MacOS/Xcode")])
        #expect(j.culprit(path: "/Users/tester/Library/Developer/Xcode/DerivedData",
                          kind: .buildCache, home: home) == nil)
    }

    // MARK: - 배선: 실행기·스캐너

    /// 오래된 node_modules가 든 프로젝트 홈을 만든다.
    private func makeProjectHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "inuse-\(UUID().uuidString)")
        let project = home.appending(path: "work/shop")
        let pkg = project.appending(path: "node_modules/pkg")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: pkg.appending(path: "index.js"))
        try Data("{}".utf8).write(to: project.appending(path: "package-lock.json"))
        let old = Date().addingTimeInterval(-200 * 86_400)
        for p in [pkg.path, project.appending(path: "node_modules").path, project.path] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: p)
        }
        return home
    }

    /// 실행 직전 재검증이 사용 중 항목을 **누가 쓰는지와 함께** 거부한다 —
    /// 스캔 뒤에 프로세스가 떠도 이동 시점에 다시 걸러져야 한다.
    @Test func reclaimerRefusesInUseNodeModulesNamingCulprit() async throws {
        let home = try makeProjectHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let nmPath = home.appending(path: "work/shop/node_modules").path
        let item = ReclaimItem(path: nmPath, kind: .nodeModules, displayName: "shop",
                               bytes: 1024, lastUsedDays: 200, note: "")
        let busy = judge(procs: [proc("java", cwd: home.appending(path: "work/shop").path)])

        let result = await Reclaimer().moveToTrash([item], guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90, inUse: busy)
        #expect(result.movedCount == 0)
        #expect(result.refused.first?.reason == .inUse(by: "java"))
        #expect(FileManager.default.fileExists(atPath: nmPath))
    }

    /// 스캔이 사용 중 항목을 목록에 올리지 않되, **뺐다는 사실과 누가 쓰는지**를
    /// 보고한다 — 조용히 빼면 "비울 게 없어요"가 거짓이 된다.
    @Test func scannerExcludesInUseNodeModulesAndReportsIt() async throws {
        let home = try makeProjectHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = [home.appending(path: "work").path]
        let busy = judge(procs: [proc("node", cwd: home.appending(path: "work/shop").path)])
        let idle = judge()

        let excluded = await ReclaimScanner(home: home.path, projectRoots: roots,
                                            staleThresholdDays: 90, inUse: busy).scan()
        #expect(!excluded.items.contains { $0.kind == .nodeModules })
        let skip = try #require(excluded.skippedInUse.first)
        #expect(skip.process == "node")
        #expect(!skip.name.isEmpty)

        let included = await ReclaimScanner(home: home.path, projectRoots: roots,
                                            staleThresholdDays: 90, inUse: idle).scan()
        #expect(included.items.contains { $0.kind == .nodeModules })
        #expect(included.skippedInUse.isEmpty)
    }

    /// 실제 프로세스 표본에서 이름·cwd·실행 경로를 뽑아낸다.
    @Test func derivesSignalsFromSamples() {
        let sample = ProcessSample(
            pid: 1, ppid: 0, uid: 501, startSec: 0, startUsec: 0,
            physFootprint: 0,
            execPath: "/Applications/Slack.app/Contents/MacOS/Slack",
            argv: [], cwd: "/Users/tester/work/shop",
            listeningPorts: [], cpuTimeNanos: 0)
        let j = ReclaimInUse(samples: [sample])
        #expect(j.culprit(path: "/Users/tester/Library/Application Support/Slack/Cache",
                          kind: .electronCache, home: home) == "Slack")
        #expect(j.culprit(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home) == "Slack")
    }
}
