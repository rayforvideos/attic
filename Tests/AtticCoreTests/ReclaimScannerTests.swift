import Testing
import Foundation
@testable import AtticCore

/// `scan(onProgress:)`의 콜백은 `@Sendable`이라 var를 직접 캡처해 mutate할 수
/// 없다 — 락으로 감싼 얇은 수집기로 테스트에서 순서대로 모은다.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanProgress] = []

    func append(_ progress: ScanProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [ScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("ReclaimScanner / Reclaimer", .serialized)
struct ReclaimScannerTests {
    /// 테스트는 임시 디렉토리에 스스로 트리를 만든다 — 실제 사용자 파일은 절대 건드리지 않는다
    static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "reclaim-\(UUID().uuidString)")
        let fm = FileManager.default
        func write(_ rel: String, bytes: Int) throws {
            let url = home.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
        }
        try write("Library/Developer/Xcode/DerivedData/App-x/big.o", bytes: 300_000)
        try write("Library/Caches/Homebrew/bottle.tar", bytes: 200_000)
        try write("Documents/일기.txt", bytes: 1000)                    // 절대 후보가 아니어야 함
        // 오래된 프로젝트: lockfile 있음
        try write("workspace/old/package-lock.json", bytes: 10)
        try write("workspace/old/node_modules/lib/index.js", bytes: 150_000)
        // 최근 프로젝트: lockfile 있지만 방금 수정
        try write("workspace/fresh/yarn.lock", bytes: 10)
        try write("workspace/fresh/node_modules/lib/index.js", bytes: 150_000)
        // lockfile 없는 프로젝트
        try write("workspace/nolock/node_modules/lib/index.js", bytes: 150_000)
        // 오래된 프로젝트의 mtime을 200일 전으로 되돌린다
        let old = home.appending(path: "workspace/old")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
                             ofItemAtPath: old.path)
        return home
    }

    @Test func findsCachesAndStaleNodeModulesOnly() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let items = await ReclaimScanner(home: home.path,
                                        projectRoots: [home.appending(path: "workspace").path],
                                        staleThresholdDays: 90).scan().items
        let paths = items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("DerivedData") })
        #expect(paths.contains { $0.hasSuffix("Caches/Homebrew") })
        #expect(paths.contains { $0.hasSuffix("workspace/old/node_modules") })
        // 최근 프로젝트·lockfile 없는 프로젝트·문서는 절대 없어야 한다
        #expect(!paths.contains { $0.contains("/fresh/") })
        #expect(!paths.contains { $0.contains("/nolock/") })
        #expect(!paths.contains { $0.contains("Documents") })
        #expect(items.allSatisfy { $0.bytes > 0 })
    }

    @Test func movesToTrashAndReportsBytes() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ReclaimScanner(home: home.path,
                                     projectRoots: [home.appending(path: "workspace").path],
                                     staleThresholdDays: 90)
        let items = await scanner.scan().items
        let target = try #require(items.first { $0.path.hasSuffix("Caches/Homebrew") })
        let result = await Reclaimer().moveToTrash([target],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        // 실제 ~/.Trash에 잔여물을 남기지 않도록, 옮겨진 위치를 정리한다.
        defer {
            for trashed in result.trashedURLs {
                try? FileManager.default.removeItem(atPath: trashed)
            }
        }
        #expect(result.movedCount == 1)
        #expect(result.movedBytes == target.bytes)
        #expect(result.refused.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))   // 휴지통으로 옮겨졌다
        #expect(result.trashedURLs.count == 1)
    }

    @Test func refusesTamperedItemAtExecutionTime() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // 스캔 결과를 손으로 조작해 보호 경로를 밀어넣는다 — 실행기가 막아야 한다
        let evil = ReclaimItem(path: home.appending(path: "Documents").path,
                               kind: .packageCache, displayName: "가짜",
                               bytes: 1, lastUsedDays: nil, note: "")
        let result = await Reclaimer().moveToTrash([evil],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        #expect(result.movedCount == 0)
        #expect(result.refused.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: home.appending(path: "Documents/일기.txt").path))   // 살아 있어야 한다
    }

    /// IMPORTANT 6 — the reclaimer must re-validate at execution time, not
    /// trust what the scanner saw. Touch the stale project's parent so its
    /// mtime is now "fresh" and confirm the item that scan() found stale is
    /// refused at execute time instead of being trashed.
    @Test func refusesAtExecutionTimeWhenProjectBecameFreshAfterScan() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ReclaimScanner(home: home.path,
                                     projectRoots: [home.appending(path: "workspace").path],
                                     staleThresholdDays: 90)
        let items = await scanner.scan().items
        let target = try #require(items.first { $0.path.hasSuffix("workspace/old/node_modules") })

        // 스캔 이후, 프로젝트가 다시 "최근에 수정됨" 상태가 되었다고 가정한다.
        let old = home.appending(path: "workspace/old")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: old.path)

        let result = await Reclaimer().moveToTrash([target],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        #expect(result.movedCount == 0)
        #expect(result.refused.count == 1)
        if let reason = result.refused.first?.reason {
            switch reason {
            case .tooRecent:
                break // expected
            default:
                Issue.record("예상치 못한 거부 이유: \(reason)")
            }
        }
        #expect(FileManager.default.fileExists(atPath: target.path))   // 살아 있어야 한다
    }

    @Test func reportsProgressWithDeterminateTotal() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ReclaimScanner(home: home.path,
                                     projectRoots: [home.appending(path: "workspace").path],
                                     staleThresholdDays: 90)
        let collector = ProgressCollector()
        let items = await scanner.scan { progress in
            collector.append(progress)
        }.items
        let reported = collector.values
        #expect(!reported.isEmpty)
        // 첫 보고는 총량이 확정되기 전이라 total 0이어야 한다.
        #expect(reported.first?.total == 0)
        // 총량이 확정된 뒤의 보고들은 done이 단조 증가하고 total을 넘지 않아야 한다.
        let determinate = reported.filter { $0.total > 0 }
        #expect(!determinate.isEmpty)
        let finalTotal = try #require(determinate.last?.total)
        #expect(determinate.allSatisfy { $0.total == finalTotal })
        let doneValues = determinate.map(\.done)
        #expect(zip(doneValues, doneValues.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(determinate.last?.done == finalTotal)
        #expect(finalTotal >= items.count)
    }

    /// find 재작성이 기존 재귀 탐색의 도달 범위를 잃지 않아야 한다:
    /// maxDepth 4는 루트 아래 5단계(중간 디렉토리 4단계 + node_modules)까지 뜻했다.
    @Test func findsNodeModulesAtOldWalkDepthLimit() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let deep = home.appending(path: "workspace/a/b/c/deep")
        try fm.createDirectory(at: deep.appending(path: "node_modules/lib"),
                               withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 150_000)
            .write(to: deep.appending(path: "node_modules/lib/index.js"))
        try Data("{}".utf8).write(to: deep.appending(path: "package-lock.json"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
                             ofItemAtPath: deep.path)

        let items = await ReclaimScanner(home: home.path,
                                         projectRoots: [home.appending(path: "workspace").path],
                                         staleThresholdDays: 90).scan().items
        #expect(items.map(\.path).contains { $0.hasSuffix("a/b/c/deep/node_modules") })
    }

    /// 프로젝트 루트 자체가 숨김 디렉토리여도(예: ~/.config 아래를 루트로 지정)
    /// 루트가 가지치기되지 않고 안이 탐색돼야 한다. 루트 *아래*의 숨김 폴더는
    /// 의도적으로 건너뛴다 — 그 안의 node_modules는 후보가 아니어야 한다.
    @Test func scansHiddenProjectRootButSkipsHiddenSubdirectories() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func makeStaleProject(_ rel: String) throws {
            let proj = home.appending(path: rel)
            try fm.createDirectory(at: proj.appending(path: "node_modules/lib"),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 150_000)
                .write(to: proj.appending(path: "node_modules/lib/index.js"))
            try Data("{}".utf8).write(to: proj.appending(path: "package-lock.json"))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
                                 ofItemAtPath: proj.path)
        }
        try makeStaleProject(".dotroot/proj")          // 숨김 루트를 직접 지정
        try makeStaleProject("workspace/.hidden/proj") // 루트 아래 숨김 폴더

        let items = await ReclaimScanner(
            home: home.path,
            projectRoots: [home.appending(path: ".dotroot").path,
                           home.appending(path: "workspace").path],
            staleThresholdDays: 90
        ).scan().items
        let paths = items.map(\.path)
        #expect(paths.contains { $0.hasSuffix(".dotroot/proj/node_modules") })
        #expect(!paths.contains { $0.contains("/.hidden/") })
    }

    /// 항목을 **아예 못 읽으면** 조용히 사라지면 안 된다 — 무엇을 못 쟀는지
    /// 이름으로 보고해야 사용자가 "비울 게 없어요"를 완전한 결과로 오독하지 않는다.
    ///
    /// 반대로 항목 **안쪽 일부**를 못 읽은 경우는 근사치를 쓴다: 빌드 중 파일이
    /// 사라지는 트리에서 그때마다 항목을 빼면 가장 큰 것이 목록에서 사라진다.
    @Test func reportsUnmeasuredItemsInsteadOfSilentlyDropping() async throws {
        let home = try Self.makeHome()
        let fm = FileManager.default
        let locked = home.appending(path: "Library/Caches/Homebrew")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: home)
        }

        let report = await ReclaimScanner(home: home.path,
                                          projectRoots: [home.appending(path: "workspace").path],
                                          staleThresholdDays: 90).scan()
        #expect(report.unmeasuredNames.contains("Homebrew 캐시"))
        #expect(!report.items.contains { $0.path.hasSuffix("Caches/Homebrew") })
    }

    /// ~/Library/Logs는 다른 캐시와 다르다 — 문제가 생겼을 때 보려던 진단 로그가
    /// 함께 사라질 수 있으므로, "다시 만들어집니다"류 문구 대신 경고를 붙인다.
    @Test func libraryLogsCarriesDiagnosticWarningNote() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let logs = home.appending(path: "Library/Logs/SomeApp")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 200_000)
            .write(to: logs.appending(path: "app.log"))

        let report = await ReclaimScanner(home: home.path,
                                          projectRoots: [home.appending(path: "workspace").path],
                                          staleThresholdDays: 90).scan()
        let logsItem = try #require(report.items.first { $0.path.hasSuffix("/Library/Logs") })
        #expect(logsItem.note.contains("진단"))
        #expect(!logsItem.note.contains("다시 만들어집니다"))
    }

    @Test func reclaimItemRoundTripsThroughJSON() throws {
        let item = ReclaimItem(path: "/tmp/x", kind: .buildCache, displayName: "x",
                               bytes: 12345, lastUsedDays: 3, note: "note")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ReclaimItem.self, from: data)
        #expect(decoded == item)
    }

    /// IMPORTANT 6 — replace the scanned directory with a symlink before
    /// execution and confirm the reclaimer refuses it as a symlink rather
    /// than trusting the scan-time snapshot.
    @Test func refusesAtExecutionTimeWhenReplacedWithSymlink() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ReclaimScanner(home: home.path,
                                     projectRoots: [home.appending(path: "workspace").path],
                                     staleThresholdDays: 90)
        let items = await scanner.scan().items
        let target = try #require(items.first { $0.path.hasSuffix("Caches/Homebrew") })

        // 스캔 이후, 그 자리를 심볼릭 링크로 바꿔치기한다.
        let fm = FileManager.default
        try fm.removeItem(atPath: target.path)
        let elsewhere = home.appending(path: "elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: elsewhere.path)

        let result = await Reclaimer().moveToTrash([target],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        #expect(result.movedCount == 0)
        #expect(result.refused.map { $0.reason } == [.symlink])
    }
}

@Suite("Reclaimer 크기 재측정", .serialized)
struct ReclaimerRemeasureTests {
    /// 스캔 값이 낡았으면 그 숫자로 성과를 보고해선 안 된다 — 스캔 때 13GB였다가
    /// 사용자가 직접 비워 200MB만 남은 폴더를 옮기고 "13GB 비웠어요"라고 말하면
    /// 누적 성과가 거짓이 된다. 이동 직전에 다시 잰다.
    @Test func reportsRemeasuredSizeNotStaleScanValue() async throws {
        let home = try ReclaimScannerTests.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appending(path: "Library/Caches/Homebrew")

        // 스캔이 본 값(과장)을 손으로 만든 항목에 심는다
        let stale = ReclaimItem(path: target.path, kind: .packageCache,
                                displayName: "Homebrew", bytes: 13_000_000_000,
                                lastUsedDays: nil, note: "")
        let result = await Reclaimer().moveToTrash([stale],
                                                   guard: ReclaimGuard(home: home.path),
                                                   staleThresholdDays: 90)
        defer {
            for trashed in result.trashedURLs {
                try? FileManager.default.removeItem(atPath: trashed)
            }
        }
        #expect(result.movedCount == 1)
        // 실제 내용은 200KB 수준이다 — 13GB를 그대로 보고하면 실패다.
        #expect(result.movedBytes < 10_000_000)
        #expect(result.movedBytes > 0)
        #expect(result.remeasured)
    }
}

@Suite("Electron 캐시 탐색", .serialized)
struct ElectronCacheScanTests {
    /// 실제 앱 이름(Slack·Notion·Figma)으로 캐시를 꾸미는 테스트다 — 실행 중
    /// 판정을 주입하지 않으면 이 맥에서 그 앱이 떠 있을 때 후보에서 빠져
    /// 테스트가 환경을 탄다(실측: Slack 실행 중에 실패).
    private let idle = ReclaimInUse(apps: [:], bundleIDs: [:], procs: [])
    /// 앱 이름을 미리 알 수 없으므로 구조로 찾는다: Application Support 아래
    /// 각 앱 폴더에서 Chromium 캐시 이름을 가진 폴더만 골라낸다.
    @Test func findsCachesAtEveryObservedDepth() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "electron-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")

        func write(_ relative: String, bytes: Int) throws {
            let url = support.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
        }
        // 실측한 세 가지 형태
        try write("Slack/Cache/data_0", bytes: 200_000)
        try write("Notion/Partitions/notion/Service Worker/x", bytes: 300_000)
        try write("Figma/DesktopProfile/v42/Code Cache/y", bytes: 150_000)
        // 캐시가 아닌 것들 — 절대 잡히면 안 된다
        try write("Slack/IndexedDB/db", bytes: 100_000)
        try write("Notion/notion.db", bytes: 100_000)
        try write("Claude/vm_bundles/image", bytes: 500_000)

        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         smallCacheThreshold: 0, inUse: idle).scan()
        let paths = report.items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("Slack/Cache") })
        #expect(paths.contains { $0.hasSuffix("Notion/Partitions/notion/Service Worker") })
        #expect(paths.contains { $0.hasSuffix("Figma/DesktopProfile/v42/Code Cache") })
        #expect(!paths.contains { $0.contains("IndexedDB") })
        #expect(!paths.contains { $0.contains("notion.db") })
        #expect(!paths.contains { $0.contains("vm_bundles") })
        // 앱 데이터 루트 자체도 없어야 한다
        #expect(!paths.contains { $0.hasSuffix("Application Support/Slack") })
    }

    /// 화면에 앱 이름과 캐시 종류가 함께 보여야 한다 — "Cache" 하나만 뜨면
    /// 어느 앱 것인지 알 수 없다.
    @Test func namesItemsByAppAndCacheKind() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "electron-name-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let cache = home.appending(path: "Library/Application Support/Slack/Code Cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 200_000).write(to: cache.appending(path: "x"))

        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         smallCacheThreshold: 0, inUse: idle).scan()
        let item = try #require(report.items.first { $0.path.hasSuffix("Slack/Code Cache") })
        #expect(item.displayName.contains("Slack"))
        #expect(item.kind == .electronCache)
    }
}

@Suite("작은 앱 캐시 생략", .serialized)
struct SmallCacheSkipTests {
    /// 자잘한 캐시는 목록에서 빼되 **생략했다는 사실은 보고한다** — 조용히 빼면
    /// 합계와 목록이 어긋나 사용자가 계산을 못 한다.
    @Test func skipsSmallCachesButReportsThem() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "small-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")
        for (app, bytes) in [("Big", 300_000), ("Tiny", 4_000)] {
            let dir = support.appending(path: "\(app)/Cache")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: dir.appending(path: "d"))
        }
        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         smallCacheThreshold: 100_000).scan()
        #expect(report.items.contains { $0.path.hasSuffix("Big/Cache") })
        #expect(!report.items.contains { $0.path.hasSuffix("Tiny/Cache") })
        #expect(report.smallCachesSkipped == 1)
        #expect(report.smallCachesBytes > 0)
    }
}

@Suite("사용자 파일 탐색", .serialized)
struct UserFileScanTests {
    /// 되돌릴 수 없는 종류라 조건을 정확히 지켜야 한다: Downloads 직속·오래된
    /// 것만. 종류(확장자)는 가리지 않는다.
    @Test func findsOldDownloadsOfAnyKindInRoot() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "userfiles-\(UUID().uuidString)")
        let downloads = home.appending(path: "Downloads")
        try fm.createDirectory(at: downloads.appending(path: "keep"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        func write(_ relative: String, days: Int) throws {
            let url = downloads.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // 1MB 미만은 목록에 올리지 않으므로 넉넉히 쓴다
            try Data(repeating: 0x41, count: 2 << 20).write(to: url)
            let old = Date().addingTimeInterval(-Double(days) * 86_400)
            try fm.setAttributes([.modificationDate: old, .creationDate: old],
                                 ofItemAtPath: url.path)
        }
        try write("old-app.dmg", days: 200)          // 후보
        try write("new-app.dmg", days: 2)            // 최근 — 제외
        try write("report.pdf", days: 200)           // 설치 파일이 아니어도 후보
        try write("회의녹화.mp4", days: 200)          // 후보
        try write("keep/nested.dmg", days: 200)      // 전부 오래된 폴더 — 폴더로 후보
        try write("mixed/old.zip", days: 200)        // 최근 파일이 섞인 폴더는
        try write("mixed/yesterday.psd", days: 1)    //   제안하지 않는다

        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90).scan()
        let names = Set(report.items.filter { $0.kind == .staleInstaller }
            .map(\.displayName))
        #expect(names == ["old-app.dmg", "report.pdf", "회의녹화.mp4", "keep"])
    }

    /// 폴더는 안에 든 것이 **전부** 오래됐을 때만 제안한다 — 폴더를 지우는 것은
    /// 파일 하나보다 결과가 크다. 나이는 가장 최근 파일 기준이다.
    @Test func offersDownloadFolderOnlyWhenEverythingInsideIsOld() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "dlfolder-\(UUID().uuidString)")
        let downloads = home.appending(path: "Downloads")
        defer { try? fm.removeItem(at: home) }
        func write(_ relative: String, days: Int) throws {
            let url = downloads.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 2 << 20).write(to: url)
            let when = Date().addingTimeInterval(-Double(days) * 86_400)
            try fm.setAttributes([.modificationDate: when, .creationDate: when],
                                 ofItemAtPath: url.path)
        }
        try write("모두오래됨/a.mp4", days: 300)
        try write("모두오래됨/깊이/b.png", days: 150)
        try write("하나만최근/a.mp4", days: 300)
        try write("하나만최근/b.png", days: 3)
        try fm.createDirectory(at: downloads.appending(path: "빈폴더"),
                               withIntermediateDirectories: true)

        let items = await ReclaimScanner(home: home.path, projectRoots: [],
                                        staleThresholdDays: 90).scan().items
        let names = Set(items.filter { $0.kind == .staleInstaller }.map(\.displayName))
        #expect(names == ["모두오래됨"])
        // 폴더 크기는 안에 든 것의 합이다
        let folder = items.first { $0.displayName == "모두오래됨" }
        #expect((folder?.bytes ?? 0) >= 4 << 20)
        // 나이는 가장 최근 파일(150일) 기준 — 가장 오래된 것으로 말하면 과장이다
        #expect((folder?.lastUsedDays ?? 0) >= 149 && (folder?.lastUsedDays ?? 0) <= 151)
    }

    /// 스크린샷은 파일명 형식으로만 고른다 — 데스크탑의 작업 파일을 건드리면 안 된다.
    @Test func findsOnlyScreenshotNamedFiles() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "shots-\(UUID().uuidString)")
        let desktop = home.appending(path: "Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        for name in ["스크린샷 2026-01-02 오후 3.04.05.png", "발표자료.png", "IMG_9999.png"] {
            let url = desktop.appending(path: name)
            try Data(repeating: 0x41, count: 2 << 20).write(to: url)   // 1MB 기준을 넘긴다
            let old = Date().addingTimeInterval(-200 * 86_400)
            try fm.setAttributes([.modificationDate: old, .creationDate: old],
                                 ofItemAtPath: url.path)
        }
        let report = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90).scan()
        let shots = report.items.filter { $0.kind == .oldScreenshot }
        #expect(shots.count == 1)
        #expect(shots.first?.displayName.hasPrefix("스크린샷") == true)
    }
}


@Suite("설정이 스캔에 반영되는지", .serialized)
struct ScannerSettingsTests {
    private func makeUserFiles() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "settings-\(UUID().uuidString)")
        let downloads = home.appending(path: "Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appending(path: "old.dmg")
        try Data(repeating: 0x41, count: 3 << 20).write(to: installer)
        let old = Date().addingTimeInterval(-200 * 86_400)
        try fm.setAttributes([.modificationDate: old, .creationDate: old],
                             ofItemAtPath: installer.path)
        return home
    }

    /// "내 파일도 찾기"를 끄면 사용자 파일이 목록에 오르지 않아야 한다.
    @Test func respectsIncludeUserFilesToggle() async throws {
        let home = try makeUserFiles()
        defer { try? FileManager.default.removeItem(at: home) }

        let withFiles = await ReclaimScanner(home: home.path, projectRoots: [],
                                            staleThresholdDays: 90,
                                            includeUserFiles: true).scan()
        #expect(withFiles.items.contains { $0.kind == .staleInstaller })

        let without = await ReclaimScanner(home: home.path, projectRoots: [],
                                           staleThresholdDays: 90,
                                           includeUserFiles: false).scan()
        #expect(!without.items.contains { $0.kind == .staleInstaller })
    }

    /// 오래된 기준을 올리면 그보다 최근인 것은 빠져야 한다.
    @Test func respectsStaleThreshold() async throws {
        let home = try makeUserFiles()
        defer { try? FileManager.default.removeItem(at: home) }
        // 200일 된 파일이므로 365일 기준에서는 후보가 아니다
        let strict = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 365).scan()
        #expect(!strict.items.contains { $0.kind == .staleInstaller })
    }
}

@Suite("스크린샷 찾기")
struct ScreenshotDiscoveryTests {
    /// 데스크탑 밖에 있는 스크린샷도 찾아야 한다. 데스크탑만 보던 탓에 이 맥에
    /// 있던 스크린샷 2개를 둘 다 놓쳤다(실측) — 사람들은 찍은 뒤 작업 폴더로
    /// 끌어다 놓고 잊는다.
    @Test func findsScreenshotsOutsideDesktop() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "shot-\(UUID().uuidString)")
        let old = Date().addingTimeInterval(-200 * 86_400)
        func put(_ rel: String) throws {
            let url = home.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // 1MB 미만은 목록에서 빼므로(잔 스크린샷은 값이 없다) 넘겨서 쓴다
            try Data(repeating: 0x41, count: 2 << 20).write(to: url)
            try fm.setAttributes([.modificationDate: old, .creationDate: old],
                                 ofItemAtPath: url.path)
        }
        defer { try? fm.removeItem(at: home) }
        try put("Desktop/스크린샷 2026-01-02 오후 3.21.44.png")
        try put("배민/스크린샷 2026-01-03 오후 4.11.02.png")        // 작업 폴더
        try put("Documents/일/Screenshot 2026-01-04 at 10.00.00.png")
        try put("Desktop/제품사진.png")                              // 스크린샷이 아니다
        try put("Desktop/스크린샷.png")                              // 날짜 없음 — 사용자가 바꾼 이름

        let items = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90).scan().items
        let shots = items.filter { $0.kind == .oldScreenshot }.map(\.path)
        #expect(shots.count == 3)
        #expect(shots.contains { $0.hasSuffix("배민/스크린샷 2026-01-03 오후 4.11.02.png") })
        #expect(shots.contains { $0.contains("Documents/일/Screenshot") })
        #expect(!items.map(\.path).contains { $0.hasSuffix("제품사진.png") })
        #expect(!items.map(\.path).contains { $0.hasSuffix("Desktop/스크린샷.png") })
    }

    /// 스크린샷이 큰 파일로 또 세지면 합계가 이중 계산된다.
    @Test func doesNotCountScreenshotAsLargeFileToo() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "shot2-\(UUID().uuidString)")
        let url = home.appending(path: "Desktop/스크린샷 2026-01-02 오후 3.21.44.png")
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2 << 20).write(to: url)
        let old = Date().addingTimeInterval(-200 * 86_400)
        try fm.setAttributes([.modificationDate: old, .creationDate: old],
                             ofItemAtPath: url.path)
        defer { try? fm.removeItem(at: home) }

        let items = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90,
                                         largeFileThreshold: 1 << 20).scan().items
        #expect(items.filter { $0.path == url.path }.count == 1)
        #expect(items.first { $0.path == url.path }?.kind == .oldScreenshot)
    }
}

@Suite("스크린샷 나이 기준")
struct ScreenshotAgeTests {
    /// 스크린샷은 한 달 기준이다 — "오래된 기준"(프로젝트·설치 파일용)이 3개월
    /// 이어도 두 달 전 스크린샷은 나와야 한다. 이 맥의 스크린샷 2개가 57·65일
    /// 이라 90일 기준으로는 하나도 걸리지 않았다.
    @Test func usesOneMonthRegardlessOfStaleSetting() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "age-\(UUID().uuidString)")
        func put(_ rel: String, daysAgo: Int) throws {
            let url = home.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 2 << 20).write(to: url)
            let when = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try fm.setAttributes([.modificationDate: when, .creationDate: when],
                                 ofItemAtPath: url.path)
        }
        defer { try? fm.removeItem(at: home) }
        try put("Desktop/스크린샷 2026-06-01 오후 3.21.44.png", daysAgo: 60)
        try put("Desktop/스크린샷 2026-08-01 오후 3.21.44.png", daysAgo: 5)

        let items = await ReclaimScanner(home: home.path, projectRoots: [],
                                         staleThresholdDays: 90).scan().items
        let shots = items.filter { $0.kind == .oldScreenshot }.map(\.path)
        #expect(shots.count == 1)
        #expect(shots.first?.contains("2026-06-01") == true)   // 60일 전 → 나온다
        // 5일 전 스크린샷은 아직 쓰는 중일 수 있다
        #expect(!shots.contains { $0.contains("2026-08-01") })
    }
}

@Suite("스크린샷 — 한글 파일명과 크기 기준")
struct ScreenshotNamingTests {
    /// macOS 파일시스템은 한글 파일명을 **NFD(분해형)**으로 준다. 내가 파이썬으로
    /// 셀 때 NFC로 쓴 정규식이 7개 중 5개를 놓쳤다 — Swift의 String 비교는 정규화
    /// 차이를 무시하므로 앱은 맞게 찾았다. 나중에 누가 바이트 비교나 NSString
    /// API로 바꾸면 조용히 깨지는 자리라 고정해 둔다.
    @Test func matchesDecomposedKoreanFilenames() {
        let nfc = "스크린샷 2026-01-16 오후 2.31.25.png"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count != nfc.unicodeScalars.count, "NFD가 실제로 달라야 한다")
        #expect(ReclaimGuard.isScreenshotName(nfc))
        #expect(ReclaimGuard.isScreenshotName(nfd))
    }

    /// 1MB 미만 스크린샷은 목록에 올리지 않는다 — 공간은 없고 위험만 있다.
    /// (이 맥에서 연말정산 폴더의 120~210KB 증빙 6개가 올라왔다.)
    @Test func skipsTinyScreenshots() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "tiny-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func put(_ rel: String, kb: Int) throws {
            let url = home.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: kb << 10).write(to: url)
            let old = Date().addingTimeInterval(-200 * 86_400)
            try fm.setAttributes([.modificationDate: old, .creationDate: old],
                                 ofItemAtPath: url.path)
        }
        try put("증빙/스크린샷 2026-01-16 오후 2.31.25.png", kb: 200)   // 작다 — 제외
        try put("Desktop/스크린샷 2026-01-16 오후 3.00.00.png", kb: 3_000) // 3MB — 후보

        let items = await ReclaimScanner(home: home.path, projectRoots: [],
                                        staleThresholdDays: 90).scan().items
        let shots = items.filter { $0.kind == .oldScreenshot }
        #expect(shots.count == 1)
        #expect(shots.first?.path.contains("Desktop") == true)
    }
}

@Suite("항목 문구의 정직성")
struct ItemNoteHonestyTests {
    /// "다시 받을 수 있어요"는 **설치 파일에만** 참이다. Downloads 전체를 보게
    /// 넓히면서 이 문구가 카톡 사진·받은 pptx까지 따라붙었다 — 대화가 지워지고
    /// 링크가 만료되면 다시 받을 수 없다. 되돌릴 수 없는 것을 되돌릴 수 있다고
    /// 말하는 것이 이 앱에서 가장 하면 안 되는 일이다.
    @Test func onlyInstallersPromiseRedownload() {
        let home = NSHomeDirectory()
        let installer = ReclaimScanner.note(for: .staleInstaller,
                                            path: "\(home)/Downloads/app.dmg")
        #expect(installer.contains("다시 받을 수 있") || installer.contains("download it again"))

        for name in ["KakaoTalk_Photo_2026-03-24.jpeg", "기획서.pptx", "회의녹화.mp4",
                     "천운강림.png", "메모.txt"] {
            let note = ReclaimScanner.note(for: .staleInstaller,
                                            path: "\(home)/Downloads/\(name)")
            #expect(!note.contains("다시 받을 수 있"),
                    "\(name): 다시 받을 수 없는 것에 그런 약속을 하면 안 된다")
            #expect(!note.contains("download it again"), "\(name)")
        }
    }

    /// 폴더는 안에 든 것까지 사라진다는 사실을 말해야 한다.
    @Test func folderNoteWarnsAboutContents() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "note-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let note = ReclaimScanner.note(for: .staleInstaller, path: dir.path)
        #expect(note.contains("안에 든 것") || note.contains("everything inside"))
    }

    /// 되돌릴 수 없는 종류는 전부 그 사실을 말한다.
    @Test func irreversibleKindsSaySo() {
        let home = NSHomeDirectory()
        for (kind, path) in [(ReclaimKind.oldScreenshot, "\(home)/Desktop/스크린샷 2026-01-01.png"),
                             (.largeFile, "\(home)/Movies/big.mov"),
                             (.staleInstaller, "\(home)/Downloads/사진.jpeg")] {
            let note = ReclaimScanner.note(for: kind, path: path)
            #expect(note.contains("되돌릴 수 없") || note.contains("cannot be undone"),
                    "\(kind)의 문구가 되돌릴 수 없음을 말하지 않는다: \(note)")
        }
    }
}

@Suite("화면 문구는 그릴 때 만든다")
struct RenderTimeTextTests {
    /// 저장된 문자열을 믿으면 언어를 바꿨을 때 그 줄만 옛 언어로 남는다.
    /// 종류와 경로만으로 이름·설명을 다시 만들 수 있어야 한다.
    @Test func rebuildsNameFromKindAndPath() {
        let home = "/Users/tester"
        #expect(ReclaimScanner.displayName(
            for: .libraryCache,
            path: "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Caches",
            fallback: "굳은 값", home: home).contains("KakaoTalkMac"))
        #expect(ReclaimScanner.displayName(
            for: .electronCache,
            path: "\(home)/Library/Application Support/Notion/Cache",
            fallback: "굳은 값", home: home) == "Notion (Cache)")
        // 번역이 없는 종류는 저장된 이름을 그대로 쓴다(경로에서 만든 파일명이다)
        #expect(ReclaimScanner.displayName(for: .oldScreenshot, path: "\(home)/a.png",
                                           fallback: "a.png", home: home) == "a.png")
    }

    /// 설명도 같은 성질을 지켜야 한다 — 저장 없이 종류·경로에서 나온다.
    @Test func rebuildsNoteFromKindAndPath() {
        #expect(!ReclaimScanner.note(for: .buildCache, path: "/x").isEmpty)
        #expect(!ReclaimScanner.note(for: .electronCache, path: "/x").isEmpty)
    }
}
