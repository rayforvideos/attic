import Testing
import Foundation
@testable import AtticCore

/// "지금 쓰이는 중"인 후보를 가려내는 판정. 실행 중인 앱의 캐시나 살아 있는
/// 프로세스가 물고 있는 node_modules를 옮기면, 휴지통에서 "사용 중" 경고로
/// 되돌아오고 앱은 열린 핸들로 휴지통 안에 계속 쓴다 — 애초에 후보에서 뺀다.
@Suite("ReclaimInUse — 실행 중 판정")
struct ReclaimInUseTests {
    let home = "/Users/tester"

    private func judge(appNames: Set<String> = [], bundleIDs: Set<String> = [],
                       cwds: [String] = [], execPaths: [String] = []) -> ReclaimInUse {
        ReclaimInUse(appNames: appNames, bundleIDs: bundleIDs,
                     cwds: cwds, execPaths: execPaths)
    }

    // MARK: - node_modules

    @Test func nodeModulesInUseWhenProcessCwdInsideProject() {
        let j = judge(cwds: ["/Users/tester/work/shop/packages/web"])
        #expect(j.isInUse(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home))
    }

    @Test func nodeModulesInUseWhenBinaryRunsFromIt() {
        let j = judge(execPaths: ["/Users/tester/work/shop/node_modules/.bin/vite"])
        #expect(j.isInUse(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home))
    }

    @Test func nodeModulesNotInUseForUnrelatedProcess() {
        let j = judge(cwds: ["/Users/tester/work/other"],
                      execPaths: ["/usr/bin/java"])
        #expect(!j.isInUse(path: "/Users/tester/work/shop/node_modules",
                           kind: .nodeModules, home: home))
    }

    /// "/Users/tester/work/shop-backup"의 cwd가 "/Users/tester/work/shop"
    /// 프로젝트와 접두어만 겹친다고 사용 중이 되면 안 된다.
    @Test func nodeModulesNotInUseForSiblingWithSharedPrefix() {
        let j = judge(cwds: ["/Users/tester/work/shop-backup"])
        #expect(!j.isInUse(path: "/Users/tester/work/shop/node_modules",
                           kind: .nodeModules, home: home))
    }

    // MARK: - Electron 캐시

    @Test func electronCacheInUseWhenAppRunning() {
        let j = judge(appNames: ["slack"])
        #expect(j.isInUse(path: "/Users/tester/Library/Application Support/Slack/Cache",
                          kind: .electronCache, home: home))
    }

    @Test func electronCacheNotInUseWhenAppQuit() {
        let j = judge(appNames: ["notion"])
        #expect(!j.isInUse(path: "/Users/tester/Library/Application Support/Slack/Cache",
                           kind: .electronCache, home: home))
    }

    // MARK: - 일반 앱 캐시

    @Test func libraryCacheBundleIdMatchesRunningApp() {
        let j = judge(bundleIDs: ["com.tinyspeck.slackmacgap"])
        #expect(j.isInUse(path: "/Users/tester/Library/Caches/com.tinyspeck.slackmacgap",
                          kind: .libraryCache, home: home))
    }

    @Test func libraryCachePlainNameMatchesRunningApp() {
        let j = judge(appNames: ["spotify"])
        #expect(j.isInUse(path: "/Users/tester/Library/Caches/Spotify",
                          kind: .libraryCache, home: home))
    }

    @Test func containersCacheMatchesRunningApp() {
        let j = judge(bundleIDs: ["com.kakao.kakaotalkmac"])
        #expect(j.isInUse(
            path: "/Users/tester/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Caches",
            kind: .libraryCache, home: home))
    }

    @Test func libraryCacheNotInUseWhenNothingMatches() {
        let j = judge(appNames: ["finder"], bundleIDs: ["com.apple.finder"])
        #expect(!j.isInUse(path: "/Users/tester/Library/Caches/Spotify",
                           kind: .libraryCache, home: home))
    }

    /// 실행 중 여부를 보지 않는 종류(빌드 캐시 등)는 항상 "사용 중 아님"이다 —
    /// 이 판정이 다른 종류로 번지면 스캔 결과가 통째로 사라질 수 있다.
    @Test func otherKindsAreNeverInUse() {
        let j = judge(appNames: ["xcode"], cwds: ["/Users/tester"],
                      execPaths: ["/Applications/Xcode.app/Contents/MacOS/Xcode"])
        #expect(!j.isInUse(path: "/Users/tester/Library/Developer/Xcode/DerivedData",
                           kind: .buildCache, home: home))
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

    /// 실행 직전 재검증이 사용 중 항목을 거부한다 — 스캔 뒤에 프로세스가
    /// 떠도 이동 시점에 다시 걸러져야 한다.
    @Test func reclaimerRefusesInUseNodeModules() async throws {
        let home = try makeProjectHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let nmPath = home.appending(path: "work/shop/node_modules").path
        let item = ReclaimItem(path: nmPath, kind: .nodeModules, displayName: "shop",
                               bytes: 1024, lastUsedDays: 200, note: "")
        let busy = judge(cwds: [home.appending(path: "work/shop").path])

        let result = await Reclaimer().moveToTrash([item], guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90, inUse: busy)
        #expect(result.movedCount == 0)
        #expect(result.refused.first?.reason == .inUse)
        #expect(FileManager.default.fileExists(atPath: nmPath))
    }

    /// 스캔이 사용 중 항목을 애초에 목록에 올리지 않는다.
    @Test func scannerExcludesInUseNodeModules() async throws {
        let home = try makeProjectHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = [home.appending(path: "work").path]
        let busy = judge(cwds: [home.appending(path: "work/shop").path])
        let idle = judge()

        let excluded = await ReclaimScanner(home: home.path, projectRoots: roots,
                                            staleThresholdDays: 90, inUse: busy).scan()
        #expect(!excluded.items.contains { $0.kind == .nodeModules })

        let included = await ReclaimScanner(home: home.path, projectRoots: roots,
                                            staleThresholdDays: 90, inUse: idle).scan()
        #expect(included.items.contains { $0.kind == .nodeModules })
    }

    /// 실제 프로세스 표본에서 앱 이름·cwd·실행 경로를 뽑아낸다.
    @Test func derivesSignalsFromSamples() {
        let sample = ProcessSample(
            pid: 1, ppid: 0, uid: 501, startSec: 0, startUsec: 0,
            physFootprint: 0,
            execPath: "/Applications/Slack.app/Contents/MacOS/Slack",
            argv: [], cwd: "/Users/tester/work/shop",
            listeningPorts: [], cpuTimeNanos: 0)
        let j = ReclaimInUse(samples: [sample])
        #expect(j.isInUse(path: "/Users/tester/Library/Application Support/Slack/Cache",
                          kind: .electronCache, home: home))
        #expect(j.isInUse(path: "/Users/tester/work/shop/node_modules",
                          kind: .nodeModules, home: home))
    }
}
